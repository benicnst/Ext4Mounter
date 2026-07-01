import Foundation
import Shared
import Virtualization

/// VZEngine v1.2.6 — freeze-safe Alpine Linux VM via VZ.framework.
///
/// Design goals vs v3.5:
///   • VZVirtualMachine runs on a dedicated background serial queue (no main-thread freeze).
///   • Mount orchestration runs on Thread.detachNewThread (blocking sleep is safe there).
///   • No RunLoop Timer on main thread.
///   • NFSv3 over VZ NAT direct TCP — nfsd port 2049 + mountd port 32767.
///     NFSv3 has NO grace period, eliminating the freeze source entirely.
///     macOS mount_nfs uses port=/mountport= to bypass rpcbind.
///   • Device FD obtained via /usr/libexec/authopen (setuid-root, IOKit-privileged Apple binary).
///     authopen is used because even root XPC helpers cannot open raw block devices on macOS 14+
///     without special IOKit entitlements that only Apple-signed binaries have.
public final class VZEngine: NSObject, VZVirtualMachineDelegate {

    // MARK: - Private state

    /// Serial queue on which VZVirtualMachine is created and operated.
    /// .userInitiated QoS gives the VM sufficient CPU priority for stable high-throughput I/O.
    /// Lower QoS (.utility) caused scheduler preemption that created read-speed variance.
    private let vmQueue = DispatchQueue(label: "com.ext4mounter.vm", qos: .userInitiated)

    private let lock = NSLock()
    private var _vm: VZVirtualMachine?
    private var _watchdog: CPUWatchdog?
    // NOTE: VsockProxy 廃止（v11.0）。VM の NAT IP へ直接 TCP 接続するため不要。

    /// Set to true by delegate or CPUWatchdog when VM must stop.
    private var vmDied = false

    // MARK: - FD Cache (同一ドライブの再マウント時に Touch ID をスキップ)
    //
    // authopen は macOS ユーザーセッションが必要なため Touch ID が出る。
    // 初回マウント後に dup() した FD をキャッシュし、再マウント時に再利用する。
    // ドライブが抜かれたとき MountManager が invalidateFDCache(for:) を呼ぶ。

    private static var deviceFDCache: [String: Int32] = [:]
    private static let fdCacheLock = NSLock()
    private static let helperCapabilityLock = NSLock()
    private static var helperRawOpenUnavailable = false

    /// キャッシュに保存された FD を閉じて削除する。ドライブ抜去時に MountManager から呼ぶ。
    public static func invalidateFDCache(for rawPath: String) {
        fdCacheLock.lock()
        defer { fdCacheLock.unlock() }
        if let cached = deviceFDCache[rawPath] {
            Darwin.close(cached)
            deviceFDCache.removeValue(forKey: rawPath)
            elog("[VZEngine] FD cache invalidated: \(rawPath)")
        }
    }

    // MARK: - Public API

    /// Called on a background thread if the VM is force-stopped after mounting.
    /// Set by MountManager so it can update UI state.
    public var onAbnormalStop: ((Error) -> Void)?

    public override init() { super.init() }

    // MARK: - Mount

    /// Asynchronously mount `disk`.  Calls `completion` on a background thread.
    /// Returns the NFS mount point path on success.
    public func mount(disk: Ext4Disk,
                      config: VMEngineConfig = .default,
                      completion: @escaping (Result<String, Error>) -> Void) {
        Thread.detachNewThread { [weak self] in
            // Lower thread priority so VM boot does not freeze the host UI.
            Thread.current.threadPriority = 0.3   // default is 0.5
            self?.mountSync(disk: disk, config: config, completion: completion)
        }
    }

    private func mountSync(disk: Ext4Disk,
                           config: VMEngineConfig,
                           completion: @escaping (Result<String, Error>) -> Void) {

        // Reset vmDied at the start of each fresh mount attempt.
        lock.withLock { vmDied = false }

        stage(1, 6, "Prepare directories")
        let cacheBase  = NSHomeDirectory() + "/Library/Caches/Ext4Mounter/" + disk.bsdName
        let sharedDir  = cacheBase + "/shared"
        let statusPath = sharedDir + "/status.txt"
        let mountPoint = "/Volumes/" + disk.safeVolumeName

        do {
            try FileManager.default.createDirectory(atPath: sharedDir,
                                                    withIntermediateDirectories: true)
        } catch {
            fail(completion, "Stage 1 failed — mkdir: \(error)"); return
        }
        try? FileManager.default.removeItem(atPath: statusPath)

        // GPT 名ヒントを virtiofs 共有ディレクトリに書き込む。
        // VM の init スクリプトが bind mount のパス名に使う。
        // sanitize: スペース→_ 、記号除去、64文字以内
        let hintRaw = disk.volumeName ?? disk.bsdName
        let hintSafe = String(hintRaw.unicodeScalars.map { c -> Character in
            if CharacterSet(charactersIn: " ").contains(c) { return "_" }
            let extra = CharacterSet(charactersIn: "-_.")
            return (CharacterSet.alphanumerics.contains(c) || extra.contains(c)) ? Character(c) : "_"
        }.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "_."))
        let hint = hintSafe.isEmpty ? disk.bsdName : hintSafe
        try? hint.write(toFile: sharedDir + "/volname_hint.txt", atomically: true, encoding: .utf8)
        elog("[VZEngine]   volname_hint='\(hint)'")
        // ホスト現在時刻（Unix エポック秒）を書き込む。
        // VZ は Linux ゲストに自動で時刻同期しないため、init がこのファイルを読んで
        // date -s @<epoch> でシステムクロックを合わせる（1970問題の回避）。
        let hostEpoch = String(format: "%.0f", Date().timeIntervalSince1970)
        try? hostEpoch.write(toFile: sharedDir + "/host_time.txt", atomically: true, encoding: .utf8)
        elog("[VZEngine]   host_time=\(hostEpoch)")

        // ── Check: kernel and initramfs exist ────────────────────────────────
        guard FileManager.default.fileExists(atPath: config.kernelPath) else {
            fail(completion, "Stage 1 failed — kernel not found: \(config.kernelPath)"); return
        }
        guard FileManager.default.fileExists(atPath: config.initrdPath) else {
            fail(completion, "Stage 1 failed — initramfs not found: \(config.initrdPath)"); return
        }
        stageOK(1, "sharedDir=\(sharedDir) mountPoint=\(mountPoint)")

        // ─────────────────────────────────────────────────────────────────────
        // Stage 2: デバイスオープン（2段階フォールバック）
        //   優先: XPC helper（root から authopen → パスワードなし）
        //   予備: アプリから直接 authopen（旧ヘルパーのまま or XPC 失敗時 → パスワードダイアログ）
        stage(2, 6, "Open device (via helper or authopen)")
        guard waitForHelperAvailability(timeout: 3.0) else {
            fail(completion, "Stage 2 failed — privileged helper is not running; approve the helper and retry")
            return
        }

        let rawPath = disk.devicePath.hasPrefix("/dev/disk")
                      ? disk.devicePath.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
                      : disk.devicePath

        var fd: Int32 = -1

        // 0th: FD キャッシュ確認（同ドライブ再マウント → Touch ID スキップ）
        VZEngine.fdCacheLock.lock()
        let cachedFD = VZEngine.deviceFDCache[rawPath]
        VZEngine.fdCacheLock.unlock()
        if let cached = cachedFD {
            let dupFD = dup(cached)
            if dupFD >= 0 {
                fd = dupFD
                elog("[VZEngine]   FD cache hit \(rawPath) → dup FD=\(fd) (Touch ID skipped)")
            } else {
                elog("[VZEngine]   FD cache stale (dup failed errno=\(errno)) — invalidating")
                VZEngine.invalidateFDCache(for: rawPath)
            }
        }

        // 1st: XPC helper に依頼
        let shouldTryHelperRawOpen = VZEngine.helperCapabilityLock.withLock {
            !VZEngine.helperRawOpenUnavailable
        }
        if fd < 0 && shouldTryHelperRawOpen {
            let openSem = DispatchSemaphore(value: 0)
            var helperOK = false; var helperMsg = ""
            XPCHelperClient.shared.openDiskDevice(devicePath: rawPath) { ok, msg in
                helperOK = ok; helperMsg = msg
                elog("[VZEngine]   helper openDiskDevice ok=\(ok) msg=\(msg)")
                openSem.signal()
            }
            openSem.wait()
            if helperOK {
                fd = connectAndReceiveFD(socketPath: helperMsg)
                elog("[VZEngine]   XPC path FD=\(fd)")
            } else if helperMsg.hasPrefix(HelperOpenDiskFailureCode.rawOpenDeniedPrefix) {
                VZEngine.helperCapabilityLock.withLock {
                    VZEngine.helperRawOpenUnavailable = true
                }
                let deniedPath = String(helperMsg.dropFirst(HelperOpenDiskFailureCode.rawOpenDeniedPrefix.count))
                elog("[VZEngine]   helper raw open denied by macOS for \(deniedPath) — future mounts will skip helper raw open")
            }
        } else if fd < 0 {
            elog("[VZEngine]   helper raw open previously marked unavailable — skipping helper path")
        }

        // 2nd: XPC 失敗 → アプリから直接 authopen（Touch ID ダイアログあり）
        if fd < 0 {
            elog("[VZEngine]   XPC path unavailable — falling back to local authopen")
            fd = openWithAuthopen(rawPath: rawPath)
        }

        guard fd >= 0 else {
            fail(completion, "Stage 2 failed — could not open \(rawPath)"); return
        }

        do {
            let info = try Ext4PreflightService.inspect(fileDescriptor: fd)
            if let label = info.volumeLabel, !label.isEmpty {
                let labelSafe = String(label.unicodeScalars.map { c -> Character in
                    if CharacterSet(charactersIn: " ").contains(c) { return "_" }
                    let extra = CharacterSet(charactersIn: "-_.")
                    return (CharacterSet.alphanumerics.contains(c) || extra.contains(c)) ? Character(c) : "_"
                }.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "_."))
                let preferredHint = labelSafe.isEmpty ? hint : labelSafe
                try? preferredHint.write(toFile: sharedDir + "/volname_hint.txt", atomically: true, encoding: .utf8)
                elog("[VZEngine]   ext4 label preflight='\(label)' safeHint='\(preferredHint)'")
            }
            elog("[VZEngine]   ext4 preflight \(info.summaryLine)")
            if !info.incompatFeatures.isEmpty {
                elog("[VZEngine]   ext4 incompat=\(info.incompatFeatures.joined(separator: ", "))")
            }
            if !info.roCompatFeatures.isEmpty {
                elog("[VZEngine]   ext4 ro-compat=\(info.roCompatFeatures.joined(separator: ", "))")
            }
            if info.compatibility == .readOnlyRecommended {
                fail(completion,
                     "Stage 2 failed — preflight marked this volume as read-only recommended (\(info.compatibility.userMessage))")
                return
            }
        } catch {
            elog("[VZEngine]   ext4 preflight unavailable after auth: \(error.localizedDescription)")
        }

        // 成功した FD を dup してキャッシュに保存（次回マウント時の Touch ID スキップ用）
        if cachedFD == nil {
            let cacheFD = dup(fd)
            if cacheFD >= 0 {
                VZEngine.fdCacheLock.lock()
                VZEngine.deviceFDCache[rawPath] = cacheFD
                VZEngine.fdCacheLock.unlock()
                elog("[VZEngine]   FD cached \(rawPath) cacheFD=\(cacheFD)")
            }
        }

        stageOK(2, "FD=\(fd) path=\(rawPath)")

        // ─────────────────────────────────────────────────────────────────────
        stage(3, 6, "Build VM configuration")
        let diskFH = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let vmConfig: VZVirtualMachineConfiguration
        do {
            vmConfig = try buildVMConfig(diskFileHandle: diskFH,
                                         sharedDir: sharedDir,
                                         config: config,
                                         hint: hint)
        } catch {
            fail(completion, "Stage 3 failed — VM config: \(error.localizedDescription)"); return
        }
        stageOK(3, "cpu=\(config.cpuCount) mem=\(config.memorySizeMB)MB")

        // ─────────────────────────────────────────────────────────────────────
        stage(4, 6, "Start Alpine Linux VM")
        let startSem = DispatchSemaphore(value: 0)
        var startError: Error?

        vmQueue.async { [weak self] in
            guard let self = self else { startSem.signal(); return }
            let machine = VZVirtualMachine(configuration: vmConfig, queue: self.vmQueue)
            machine.delegate = self
            self.lock.withLock { self._vm = machine }
            machine.start { result in
                switch result {
                case .success:
                    elog("[VZEngine]   VM process started")
                case .failure(let e):
                    elog("[VZEngine]   VM start error: \(e)")
                    startError = e
                }
                startSem.signal()
            }
        }

        startSem.wait()
        if let err = startError {
            fail(completion, "Stage 4 failed — VM start: \(err.localizedDescription)"); return
        }

        // Start app-process CPUWatchdog with 10s grace period (allow Alpine kernel boot).
        // Threshold 80%: only kill runaway work inside the app process.
        // 15% would fire during normal Alpine boot (50–80% CPU is expected).
        let watchdog = CPUWatchdog(thresholdPct: 80.0, consecutiveLimit: 3)
        lock.withLock { _watchdog = watchdog }
        watchdog.onExceeded = { [weak self] pct in
            guard let self = self else { return }
            elog(String(format: "[VZEngine] 🛑 CPUWatchdog triggered (%.1f%%/s) — stopping VM", pct))
            self.lock.withLock { self.vmDied = true }
            self.stopVMNow()
            self.onAbnormalStop?(Ext4MounterError.general(
                String(format: "CPU異常上昇 %.1f%%/s — VMを強制停止しました", pct)))
        }
        watchdog.start(afterDelay: 10.0)
        stageOK(4, "VM running, CPUWatchdog armed (threshold=80%/s, delay=10s)")

        // ─────────────────────────────────────────────────────────────────────
        // Stage 5: nfs_ready 待機 + VM の NAT IP 取得
        //
        // アーキテクチャ変更（v11.0）: VsockProxy + vsock_fwd を廃止。
        // VZ NAT ネットワーク経由でホストから VM の nfsd (port 2049) へ直接 TCP 接続する。
        //
        // 旧経路: NFS → TCP → VsockProxy(ユーザー空間) → vsock → vsock_fwd(ユーザー空間) → TCP → nfsd
        // 新経路: NFS → TCP → VZ NAT(カーネル) → TCP → nfsd
        //
        // VZ NAT では VM は 192.168.64.x のアドレスを DHCP で取得し、
        // ホストはその IP へ直接ルーティングできる（vmnet 仮想 L2 セグメント）。
        stage(5, 6, "NFS ready + VM NAT IP (direct TCP, no proxy)")

        var nfsReady = false
        var vmNATIP  = ""
        let vmIPPath = sharedDir + "/vm_ip.txt"

        for tick in 0..<120 {
            Thread.sleep(forTimeInterval: 1.0)
            if lock.withLock({ vmDied }) {
                fail(completion, "Stage 5 failed — VM stopped during NFS-ready wait"); return
            }
            if let txt = try? String(contentsOfFile: statusPath, encoding: .utf8),
               txt.contains("nfs_ready") {
                elog("[VZEngine]   nfs_ready at t=\(tick + 1)s")
                nfsReady = true
                // VM NAT IP を読む（init が DHCP 取得後に書き込む）
                if let ip = try? String(contentsOfFile: vmIPPath, encoding: .utf8) {
                    vmNATIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                break
            }
        }
        guard nfsReady else {
            fail(completion, "Stage 5 failed — timeout (120s) waiting for nfs_ready"); return
        }
        guard !vmNATIP.isEmpty && vmNATIP != "127.0.0.1" else {
            fail(completion, "Stage 5 failed — VM NAT IP not available (got: '\(vmNATIP)')"); return
        }
        elog("[VZEngine]   VM NAT IP: \(vmNATIP)")

        // NFSv3 では Finder がサーバー側エクスポートパスの末尾コンポーネントを
        // ボリューム名として表示する。
        // 例: server:/mnt/Extreme_Pro → Finder は "Extreme_Pro" と表示
        //
        // VM init が export_name.txt に実際のエクスポートパス名を書き出す。
        // 優先順位（init 側）: ext4 ラベル > GPT 名ヒント(volname_hint.txt) > bsdName
        // VZEngine はこの値を exportPath と mountPoint 両方に使う。
        let exportNamePath = sharedDir + "/export_name.txt"
        var exportName = hint  // フォールバック: hint（VM 起動前に決定済み）
        if let raw = try? String(contentsOfFile: exportNamePath, encoding: .utf8) {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { exportName = s }
        }
        guard isSafeExportName(exportName) else {
            fail(completion, "Stage 5 failed — unsafe export name from VM: \(exportName)")
            return
        }
        let finalMountPoint = "/Volumes/" + exportName
        elog("[VZEngine]   exportName='\(exportName)' mountPoint=\(finalMountPoint)")

        stageOK(5, "NFS ready, vmNATIP=\(vmNATIP)")

        // ─────────────────────────────────────────────────────────────────────
        stage(6, 6, "NFS mount via XPC helper (direct NAT)")
        // NFSv4.1 調査結論（2026-04-13）:
        //   Linux nfsd は OPENATTR（NFSv4 named attributes）を実装していない。
        //   macOS は NFSv4 で nonamedattr 時に AppleDouble を使わない（NFSv3 とは異なる）。
        //   → NFSv4.1 では Finder ラベル（com.apple.FinderInfo）は機能しない。
        //
        // NFSv3 に戻す理由:
        //   - NFSv3 では macOS が AppleDouble (._*) を使って xattr を保存する
        //   - _kMDItemUserTags（現代の Finder タグ）は AppleDouble 経由で書き込み可能
        //   - anonuid=0→501 修正済みのため ._* ファイルの書き込みも正しく動作するはず
        //   - この組み合わせ（NFSv3 + anonuid=501）は今まで一度もテストしていない
        //
        // noowners を削除した理由（NFSv3 でも維持）:
        //   anonuid=501 によりサーバーが uid=501 を返す → macOS が elefant (owner) と認識
        //   → ._* ファイル (mode 644) の変更・削除が可能
        //
        // locallocks: ロックをクライアントローカルで処理（rpc.statd 不要）
        //   nolocks は ENOTSUP を返すため Finder の新規フォルダ命名フェーズで
        //   ._* 書き込みロックが失敗し「認証が必要」ダイアログが出る。
        //   locallocks はロックを成功させつつサーバー通信なし。
        // mountport=32767: rpc.mountd が固定ポートで待機
        let nfsOpts = "vers=3,tcp,hard,rsize=1048576,wsize=1048576," +
                      "timeo=50,retrans=3,deadtimeout=45," +
                      "actimeo=0,nfc,locallocks," +
                      "readahead=32,port=2049,mountport=32767"
        let mountSem = DispatchSemaphore(value: 0)
        var mountOK  = false
        var mountMsg = ""
        let mountStart = Date()
        XPCHelperClient.shared.mountNFS(host: vmNATIP, port: 2049,
                                        exportPath: "/mnt/bind/\(exportName)",
                                        mountPoint: finalMountPoint,
                                        options: nfsOpts) { ok, msg in
            let elapsed = Date().timeIntervalSince(mountStart)
            elog(String(format: "[VZEngine] mount_nfs elapsed=%.1fs ok=\(ok) msg=\(msg)", elapsed))
            mountOK = ok; mountMsg = msg; mountSem.signal()
        }
        mountSem.wait()

        if mountOK {
            stageOK(6, "Mounted at \(finalMountPoint)")
            completion(.success(finalMountPoint))
        } else {
            fail(completion, "mount_nfs failed: \(mountMsg)")
        }
    }

    // MARK: - Unmount

    /// Unmount NFS, stop vsock proxy, and stop the VM.
    /// Dispatches all blocking work to a background thread — safe to call from main.
    public func unmount(mountPoint: String,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        Thread.detachNewThread { [weak self] in
            self?.unmountSync(mountPoint: mountPoint, completion: completion)
        }
    }

    private func unmountSync(mountPoint: String,
                             completion: @escaping (Result<Void, Error>) -> Void) {
        // 1. NFS unmount FIRST — VM must still be running so diskutil unmount force
        //    can talk to the NFS server and complete instantly.
        let umSem = DispatchSemaphore(value: 0)
        var umOK = false; var umMsg = ""
        XPCHelperClient.shared.unmountNFS(mountPoint: mountPoint) { ok, msg in
            umOK = ok; umMsg = msg; umSem.signal()
        }
        // ②修正: タイムアウト 20s（diskutil がハングしても無限待ちにならない）
        if umSem.wait(timeout: .now() + 20) == .timedOut {
            elog("[VZEngine] unmountNFS timed out after 20s — proceeding with VM stop")
            umOK = false; umMsg = "timeout"
        }
        if !umOK { elog("[VZEngine] unmount warning: \(umMsg)") }

        // 2. VM stop: fire-and-forget AFTER unmount (don't wait — process exits anyway)
        vmQueue.async { [weak self] in
            guard let vm = self?.lock.withLock({ self?._vm }) else { return }
            if vm.canStop { vm.stop { _ in } }
        }

        lock.withLock { _vm = nil; vmDied = false }

        if umOK {
            completion(.success(()))
        } else {
            completion(.failure(Ext4MounterError.general("unmount: \(umMsg)")))
        }
    }

    // MARK: - VZVirtualMachineDelegate  (called on vmQueue)

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        elog("[VZEngine] VM guest stopped")
        lock.withLock { vmDied = true; _watchdog?.stop() }
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine,
                               didStopWithError error: Error) {
        elog("[VZEngine] VM error: \(error.localizedDescription)")
        lock.withLock { vmDied = true; _watchdog?.stop() }
    }

    // MARK: - Force-stop VM (called by CPUWatchdog)

    private func stopVMNow() {
        lock.withLock { _watchdog?.stop() }
        let sem = DispatchSemaphore(value: 0)
        vmQueue.async { [weak self] in
            guard let vm = self?.lock.withLock({ self?._vm }) else { sem.signal(); return }
            if vm.canStop { vm.stop { _ in sem.signal() } } else { sem.signal() }
        }
        sem.wait()
        lock.withLock { _vm = nil; _watchdog = nil }
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine,
                               networkDevice: VZNetworkDevice,
                               attachmentWasDisconnectedWithError error: Error) {
        elog("[VZEngine] Network disconnected: \(error.localizedDescription)")
    }

    // MARK: - Device FD: XPC helper path + authopen fallback

    private func waitForHelperAvailability(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        while Date() < deadline {
            attempt += 1
            let sem = DispatchSemaphore(value: 0)
            var helperOK = false
            XPCHelperClient.shared.ping { ok in
                helperOK = ok
                sem.signal()
            }
            if sem.wait(timeout: .now() + 0.75) == .timedOut {
                elog("[VZEngine] helper ping attempt \(attempt) timed out before raw disk auth")
            } else if helperOK {
                return true
            } else {
                elog("[VZEngine] helper ping attempt \(attempt) failed before raw disk auth")
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        elog("[VZEngine] helper unavailable before raw disk auth")
        return false
    }

    private func isSafeExportName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        guard name != "." && name != ".." else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Open raw block device.
    /// Authorization Services API で Ext4Mounter 名義のダイアログを表示してから
    /// authopen -extauth でデバイスを開く。ダイアログに "authopen" ではなく
    /// "Ext4Mounter" が表示されるためユーザーが混乱しない。
    /// 失敗時は従来の authopen（legacy）にフォールバック。
    private func openWithAuthopen(rawPath: String) -> Int32 {
        // 1. Authorization を Ext4Mounter プロセス名義で作成
        var authRef: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authRef) == errAuthorizationSuccess,
              let auth = authRef else {
            elog("[VZEngine] AuthorizationCreate failed — falling back to legacy authopen")
            return openWithAuthopenLegacy(rawPath: rawPath)
        }
        defer { AuthorizationFree(auth, [.destroyRights]) }

        // authopen が内部で使う right と同じ名前を要求する。
        // これにより "Ext4Mounter がディスクへのアクセスを求めています" と表示される。
        let rightName = "system.openfile.readwrite.\(rawPath)"
        var extForm   = AuthorizationExternalForm()
        var authOK    = false

        rightName.withCString { cstr in
            var item   = AuthorizationItem(name: cstr, valueLength: 0, value: nil, flags: 0)
            withUnsafeMutablePointer(to: &item) { itemPtr in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                let flags  = AuthorizationFlags([.interactionAllowed, .preAuthorize, .extendRights])
                let err    = AuthorizationCopyRights(auth, &rights, nil, flags, nil)
                if err == errAuthorizationSuccess {
                    authOK = AuthorizationMakeExternalForm(auth, &extForm) == errAuthorizationSuccess
                } else {
                    elog("[VZEngine] AuthorizationCopyRights err=\(err) — falling back to legacy")
                }
            }
        }

        guard authOK else {
            return openWithAuthopenLegacy(rawPath: rawPath)
        }

        // 2. authopen -extauth で起動（認証済みのため追加ダイアログなし）
        var sv: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0 else {
            elog("[VZEngine] socketpair() failed")
            return -1
        }
        let parentSock = sv[0]; let childSock = sv[1]

        let task = Process()
        task.executableURL  = URL(fileURLWithPath: "/usr/libexec/authopen")
        task.arguments      = ["-extauth", "-stdoutpipe", "-o", "2", rawPath]
        let stdinPipe       = Pipe()
        task.standardInput  = stdinPipe
        task.standardOutput = FileHandle(fileDescriptor: childSock, closeOnDealloc: false)
        task.standardError  = FileHandle.standardError
        do { try task.run() } catch {
            elog("[VZEngine] authopen -extauth launch failed: \(error)")
            close(parentSock); close(childSock)
            return openWithAuthopenLegacy(rawPath: rawPath)
        }
        close(childSock)

        // 3. External form を authopen の stdin に書き込む
        let authData = withUnsafeBytes(of: extForm) { Data($0) }
        stdinPipe.fileHandleForWriting.write(authData)
        stdinPipe.fileHandleForWriting.closeFile()

        // 4. FD を SCM_RIGHTS で受け取る
        let fd = receiveFDViaSCMRights(parentSock) ?? -1
        task.waitUntilExit()
        close(parentSock)

        guard fd >= 0, task.terminationStatus == 0 else {
            if fd >= 0 { close(fd) }
            elog("[VZEngine] authopen -extauth exit=\(task.terminationStatus) — falling back to legacy")
            return openWithAuthopenLegacy(rawPath: rawPath)
        }
        elog("[VZEngine] authopen -extauth FD=\(fd) (Ext4Mounter名義ダイアログ)")
        return fd
    }

    /// 旧来の authopen（-extauth なし）。ダイアログに "authopen" が表示される。
    /// openWithAuthopen が失敗したときのフォールバック。
    private func openWithAuthopenLegacy(rawPath: String) -> Int32 {
        var sv: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0 else {
            elog("[VZEngine] socketpair() failed: \(String(cString: strerror(errno)))")
            return -1
        }
        let parentSock = sv[0]; let childSock = sv[1]

        let task = Process()
        task.executableURL  = URL(fileURLWithPath: "/usr/libexec/authopen")
        task.arguments      = ["-stdoutpipe", "-o", "2", rawPath]
        task.standardOutput = FileHandle(fileDescriptor: childSock, closeOnDealloc: false)
        task.standardError  = FileHandle.standardError
        do { try task.run() } catch {
            elog("[VZEngine] authopen (legacy) launch failed: \(error)")
            close(parentSock); close(childSock); return -1
        }
        close(childSock)

        let fd = receiveFDViaSCMRights(parentSock) ?? -1
        task.waitUntilExit()
        close(parentSock)

        if task.terminationStatus != 0 {
            elog("[VZEngine] authopen (legacy) exit \(task.terminationStatus)")
            if fd >= 0 { close(fd) }
            return -1
        }
        elog("[VZEngine] authopen (legacy) FD=\(fd)")
        return fd
    }

    /// Connect to the UNIX socket that the privileged helper created,
    /// and receive the device FD via SCM_RIGHTS.
    private func connectAndReceiveFD(socketPath: String) -> Int32 {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            elog("[VZEngine] connectAndReceiveFD: socket() failed")
            return -1
        }
        defer { close(sock) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: Int8.self, capacity: 104) { strcpy($0, src) }
            }
        }
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            elog("[VZEngine] connect(\(socketPath)) failed: \(String(cString: strerror(errno)))")
            return -1
        }
        let fd = receiveFDViaSCMRights(sock) ?? -1
        elog("[VZEngine] received FD=\(fd) from helper socket")
        return fd
    }

    /// recvmsg-based SCM_RIGHTS file-descriptor reception.
    /// Mirrors the sendFileDescriptor() implementation in PrivilegedHelper/main.swift.
    private func receiveFDViaSCMRights(_ sockFd: Int32) -> Int32? {
        let cmsgSize    = MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size
        let alignedSize = (cmsgSize + MemoryLayout<Int>.size - 1) & ~(MemoryLayout<Int>.size - 1)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: alignedSize,
                                                   alignment: MemoryLayout<Int>.alignment)
        defer { buf.deallocate() }
        memset(buf, 0, alignedSize)

        var dummy: UInt8 = 0
        let received: Int = withUnsafeMutablePointer(to: &dummy) { dPtr in
            var iov  = iovec(iov_base: UnsafeMutableRawPointer(dPtr), iov_len: 1)
            return withUnsafeMutablePointer(to: &iov) { iovPtr in
                var msg = msghdr()
                msg.msg_iov        = iovPtr
                msg.msg_iovlen     = 1
                msg.msg_control    = buf
                msg.msg_controllen = socklen_t(alignedSize)
                return recvmsg(sockFd, &msg, 0)
            }
        }

        guard received > 0 else {
            elog("[VZEngine] recvmsg failed: \(String(cString: strerror(errno)))")
            return nil
        }

        let cmsg = buf.assumingMemoryBound(to: cmsghdr.self)
        guard cmsg.pointee.cmsg_level == SOL_SOCKET,
              cmsg.pointee.cmsg_type  == SCM_RIGHTS else {
            elog("[VZEngine] recvmsg: unexpected control message (not SCM_RIGHTS)")
            return nil
        }

        let fd = buf.advanced(by: MemoryLayout<cmsghdr>.size).load(as: Int32.self)
        elog("[VZEngine] SCM_RIGHTS received FD=\(fd)")
        return fd
    }

    // MARK: - VM Configuration

    private func buildVMConfig(diskFileHandle: FileHandle,
                               sharedDir: String,
                               config: VMEngineConfig,
                               hint: String = "") throws -> VZVirtualMachineConfiguration {
        let vmCfg = VZVirtualMachineConfiguration()

        // Platform
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = VZGenericMachineIdentifier()
        vmCfg.platform = platform

        // Boot loader
        let boot = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: config.kernelPath))
        boot.initialRamdiskURL = URL(fileURLWithPath: config.initrdPath)
        // ext4_volname: ボリューム名ヒントをカーネル cmdline に埋め込む。
        // virtiofs ファイル経由は VM 内でキャッシュ遅延が発生する場合があるため、
        // /proc/cmdline 経由が確実。hint が空の場合はパラメータ自体を省略。
        let volnameParam = hint.isEmpty ? "" : " ext4_volname=\(hint)"
        // macOS ユーザーの UID/GID を渡す → init 側で anonuid/anongid に使う。
        // getuid()/getgid() は実行ユーザーの値（例: elefant=501, staff=20）を返す。
        let userUID = getuid()
        let userGID = getgid()
        boot.commandLine = "quiet loglevel=3\(volnameParam) nfs_uid=\(userUID) nfs_gid=\(userGID)"
        elog("[VZEngine] commandLine: \(boot.commandLine)")
        vmCfg.bootLoader = boot
        elog("[VZEngine] kernel=\(config.kernelPath) initrd=\(config.initrdPath)")

        // CPU & memory
        vmCfg.cpuCount   = config.cpuCount
        vmCfg.memorySize = UInt64(config.memorySizeMB) * 1024 * 1024
        elog("[VZEngine] cpu=\(config.cpuCount) mem=\(config.memorySizeMB) MB")

        // Block device — synchronizationMode: .none for maximum throughput
        // (ext4 journaling provides crash safety even without host-side fsync)
        let diskAttachment = try VZDiskBlockDeviceStorageDeviceAttachment(
            fileHandle: diskFileHandle,
            readOnly:   false,
            synchronizationMode: .none
        )
        vmCfg.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        // NAT network: host mounts NFS directly from the guest's VZ NAT address.
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        vmCfg.networkDevices = [net]

        // NOTE: vsock デバイス廃止（v11.0）。NAT 直接 TCP 経由のため不要。
        // virtiofs shared directory for status signaling ("ext4share" tag)
        let sharedURL  = URL(fileURLWithPath: sharedDir)
        try FileManager.default.createDirectory(at: sharedURL, withIntermediateDirectories: true)
        let sharedDirObj = VZSharedDirectory(url: sharedURL, readOnly: false)
        let fsDevice     = VZVirtioFileSystemDeviceConfiguration(tag: "ext4share")
        fsDevice.share   = VZSingleDirectoryShare(directory: sharedDirObj)
        vmCfg.directorySharingDevices = [fsDevice]

        // Entropy source (needed for Alpine's rng)
        vmCfg.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // No serial console — avoids virtio-console wakeup overhead
        vmCfg.serialPorts = []

        try vmCfg.validate()
        return vmCfg
    }

    // MARK: - Helpers

    private func stage(_ n: Int, _ total: Int, _ desc: String) {
        elog("[VZEngine] ┌── Stage \(n)/\(total): \(desc)")
    }

    private func stageOK(_ n: Int, _ detail: String) {
        elog("[VZEngine] └── Stage \(n) ✅ \(detail)")
    }

    private func fail(_ completion: (Result<String, Error>) -> Void, _ msg: String) {
        elog("[VZEngine] ❌ FAIL: \(msg)")
        completion(.failure(Ext4MounterError.general(msg)))
    }
}

// MARK: - NSLock convenience

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }; return body()
    }
}
