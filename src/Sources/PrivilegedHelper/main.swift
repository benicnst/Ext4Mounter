import Foundation
import DiskArbitration
import Darwin
import Shared

/// UltraExt4 Privileged Helper v1.2.5
/// Adds root-level DiskArbitration approval callback to suppress the macOS
/// "unreadable disk" dialog when Linux/ext4 drives are connected.
/// Implements HelperProtocol via XPC MachService + SCM_RIGHTS FD passing.

final class HelperLog {
    static let shared = HelperLog()

    private let fileURL: URL
    private let lock = NSLock()

    private init() {
        let dir = URL(fileURLWithPath: "/Library/Logs/Ext4Mounter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("helper.log")
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func write(_ message: String) {
        let line = "[\(HelperLog.timestamp())] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
        fputs(line, stderr)
    }

    private static func timestamp() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "HH:mm:ss.SSS"
        return fmt.string(from: Date())
    }
}

@inline(__always)
func hlog(_ message: String) {
    HelperLog.shared.write(message)
}

// MARK: - Helper

final class Helper: NSObject, HelperProtocol, NSXPCListenerDelegate {

    private var listener: NSXPCListener?
    private var daSession: DASession?
    private var claimedDisks: [String: DADisk] = [:]

    func run() {
        HelperLog.shared.clear()
        listener = NSXPCListener(machServiceName: "com.ext4mounter.helper")
        listener?.delegate = self
        listener?.resume()
        setupDiskArbitration()
        hlog("[Helper] v1.2.5 started (PID: \(getpid()))")
        RunLoop.main.run()
    }

    // MARK: - DiskArbitration (root-level dialog suppression via DADiskClaim)
    //
    // DARegisterDiskMountApprovalCallback ではダイアログを抑制できない。
    // ダイアログは「マウント試行前」に DiskArbitrationAgent が表示するため。
    // 正解は DADiskClaim: ディスクをヘルパーが「所有」したと diskarbitrationd に
    // 伝えることで、DiskArbitrationAgent がダイアログを表示しなくなる。

    private func setupDiskArbitration() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            hlog("[Helper] DASessionCreate failed")
            return
        }
        daSession = session
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let ctx = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(session, nil as CFDictionary?, { disk, ctx in
            guard let ctx = ctx else { return }
            Unmanaged<Helper>.fromOpaque(ctx).takeUnretainedValue().handleDiskAppeared(disk)
        }, ctx)

        DARegisterDiskDisappearedCallback(session, nil as CFDictionary?, { disk, ctx in
            guard let ctx = ctx else { return }
            Unmanaged<Helper>.fromOpaque(ctx).takeUnretainedValue().handleDiskDisappeared(disk)
        }, ctx)

        hlog("[Helper] DiskArbitration claim session ready (uid=\(getuid()))")
    }


    private func handleDiskAppeared(_ disk: DADisk) {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { return }
        guard isLinuxPartitionCandidate(desc), !isKnownNonLinuxFS(desc) else { return }
        let bsd = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String ?? "?"
        hlog("[Helper] Linux candidate: \(bsd) — verifying in 0.5s before claim")

        // 0.5秒後に DA を再確認する:
        // - exFAT 等: VolumeKindKey に FS 名が設定される → isKnownNonLinuxFS = true → クレームしない
        // - ext4: macOS が認識できないため VolumeKindKey が空のまま → クレームする
        // authopen による magic チェックは廃止。openDiskDevice と競合してマウントが遅くなるため。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let session = self.daSession else { return }
            guard let freshDisk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd) else {
                hlog("[Helper] \(bsd) no longer exists — skip claim")
                return
            }
            guard let freshDesc = DADiskCopyDescription(freshDisk) as? [String: Any] else { return }
            guard self.isLinuxPartitionCandidate(freshDesc),
                  !self.isKnownNonLinuxFS(freshDesc) else {
                hlog("[Helper] \(bsd) re-identified as non-Linux FS — skipping claim")
                return
            }
            self.performClaim(freshDisk, bsd: bsd)
        }
    }

    private func performClaim(_ disk: DADisk, bsd: String) {
        hlog("[Helper] claiming \(bsd) to suppress 'unreadable disk' dialog")
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DADiskClaim(
            disk,
            0,     // DADiskClaimOptions: 0 = デフォルト
            nil,   // release callback: nil = 強制解放を拒否しない
            nil,   // release context
            { disk, dissenter, ctx in
                // completion callback
                guard let ctx = ctx else { return }
                let helper = Unmanaged<Helper>.fromOpaque(ctx).takeUnretainedValue()
                guard let desc = DADiskCopyDescription(disk) as? [String: Any],
                      let bsd = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String else { return }
                if dissenter == nil {
                    helper.claimedDisks[bsd] = disk
                    hlog("[Helper] ✅ claimed \(bsd) — dialog suppressed")
                } else {
                    hlog("[Helper] ⚠️ claim failed for \(bsd)")
                }
            },
            ctx
        )
    }

    private func handleDiskDisappeared(_ disk: DADisk) {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any],
              let bsd = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String else { return }
        if claimedDisks.removeValue(forKey: bsd) != nil {
            hlog("[Helper] disk \(bsd) disappeared — claim auto-released")
        }
    }

    private func isKnownNonLinuxFS(_ desc: [String: Any]) -> Bool {
        let fsType = (desc[kDADiskDescriptionVolumeKindKey as String] as? String ?? "").lowercased()
        guard !fsType.isEmpty else { return false }
        let nonLinux: Set<String> = ["exfat", "hfs", "apfs", "msdos", "fat", "fat32",
                                     "ntfs", "ufsd_ntfs", "cd9660", "udf", "ufs"]
        return nonLinux.contains(fsType)
    }

    private func isLinuxPartitionCandidate(_ desc: [String: Any]) -> Bool {
        let pt = desc[kDADiskDescriptionMediaContentKey as String] as? String ?? ""
        let pu = pt.uppercased()
        return pt.contains("Linux") || pu.contains("0FC63DAF") ||
               pu.contains("EBD0A0A2") || pt.contains("Microsoft Basic Data") ||
               pt == "0x83" || pt.lowercased().contains("ext")
    }

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject    = self
        newConnection.invalidationHandler = { hlog("[Helper] connection invalidated") }
        newConnection.resume()
        hlog("[Helper] accepted XPC connection")
        return true
    }

    // MARK: - HelperProtocol

    func getVersion(reply: @escaping (String) -> Void) {
        reply("Ext4Mounter Helper 1.2.5")
    }

    /// Open raw block device and send FD to the App via UNIX socket + SCM_RIGHTS.
    /// Prefer direct root open(2). Fall back to authopen only if direct open fails.
    func openDiskDevice(devicePath: String, reply: @escaping (Bool, String) -> Void) {
        hlog("[Helper] openDiskDevice: \(devicePath)")

        guard devicePath.hasPrefix("/dev/rdisk") || devicePath.hasPrefix("/dev/disk") else {
            reply(false, "Invalid device path (must be /dev/rdisk* or /dev/disk*)")
            return
        }

        let rawPath: String
        if devicePath.hasPrefix("/dev/disk") && !devicePath.hasPrefix("/dev/rdisk") {
            rawPath = devicePath.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
        } else {
            rawPath = devicePath
        }

        guard FileManager.default.fileExists(atPath: rawPath) else {
            reply(false, "Device not found: \(rawPath)")
            return
        }

        // ヘルパーは DADiskClaim でディスクを所有しているため、
        // そのまま Darwin.open() / authopen を呼ぶと EPERM / exit1 で失敗する。
        // 解決: DADiskClaim を一時解放してから open(2) → 成功したら FD を返す。
        // ダイアログ抑制はアプリ側の DAMountApprovalCallback が継続するため問題なし。
        let bsdShort = rawPath.replacingOccurrences(of: "/dev/rdisk", with: "disk")
                               .replacingOccurrences(of: "/dev/disk", with: "disk")
        if let claimed = claimedDisks[bsdShort] {
            hlog("[Helper] releasing DADiskClaim for \(bsdShort) to allow direct open")
            DADiskUnclaim(claimed)
            claimedDisks.removeValue(forKey: bsdShort)
        }

        var fd = openDirectWithRetry(rawPath: rawPath)
        if fd >= 0 {
            hlog("[Helper] opened \(rawPath) → fd=\(fd) (direct root open)")
        } else {
            let openCode = errno
            let openErr = String(cString: strerror(openCode))
            hlog("[Helper] direct open failed for \(rawPath): errno=\(openCode) \(openErr) — falling back to authopen")
            let roFD = open(rawPath, O_RDONLY)
            let roOpenCode = errno
            if roFD >= 0 {
                hlog("[Helper] diagnostic: O_RDONLY open succeeded for \(rawPath) → fd=\(roFD)")
                close(roFD)
            } else {
                hlog("[Helper] diagnostic: O_RDONLY open failed for \(rawPath): errno=\(roOpenCode) \(String(cString: strerror(roOpenCode)))")
            }

            var sv: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0 else {
                hlog("[Helper] socketpair failed before authopen: \(String(cString: strerror(errno)))")
                reply(false, "socketpair() failed: \(String(cString: strerror(errno)))")
                return
            }
            let parentSock = sv[0]
            let childSock = sv[1]

            let authTask = Process()
            authTask.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
            authTask.arguments = ["-stdoutpipe", "-o", "2", rawPath]
            authTask.standardOutput = FileHandle(fileDescriptor: childSock, closeOnDealloc: false)
            authTask.standardError = FileHandle.standardError
            do {
                try authTask.run()
            } catch {
                hlog("[Helper] authopen launch failed: \(error.localizedDescription)")
                close(parentSock)
                close(childSock)
                reply(false, "authopen launch failed: \(error.localizedDescription)")
                return
            }
            close(childSock)

            fd = receiveFDViaSCMRights(parentSock) ?? -1
            authTask.waitUntilExit()
            close(parentSock)

            guard fd >= 0, authTask.terminationStatus == 0 else {
                hlog("[Helper] authopen failed for \(rawPath): exit=\(authTask.terminationStatus) fd=\(fd)")
                if fd >= 0 { close(fd) }
                if openCode == EPERM && roFD < 0 && roOpenCode == EPERM {
                    let denialCode = HelperOpenDiskFailureCode.rawOpenDeniedPrefix + rawPath
                    hlog("[Helper] raw open denied in helper context — returning \(denialCode)")
                    reply(false, denialCode)
                } else {
                    reply(false, "authopen exit \(authTask.terminationStatus) for \(rawPath)")
                }
                return
            }
            hlog("[Helper] opened \(rawPath) → fd=\(fd) (via authopen fallback)")
        }

        // Create UNIX socket for FD transfer
        // ⑦修正: デバイスパスからユニークなソケット名を生成（複数同時マウント時の競合防止）
        let dir        = "/tmp/Ext4Mounter"
        let devSuffix  = rawPath.replacingOccurrences(of: "/dev/", with: "").replacingOccurrences(of: "/", with: "_")
        let socketPath = dir + "/helper_fd_\(devSuffix).sock"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        unlink(socketPath)

        let serverSock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSock >= 0 else {
            hlog("[Helper] socket() failed for FD handoff: \(String(cString: strerror(errno)))")
            close(fd); reply(false, "socket() failed"); return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: Int8.self, capacity: 104) { strcpy($0, src) }
            }
        }

        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0

        guard bindOK else {
            hlog("[Helper] bind failed for \(socketPath): \(String(cString: strerror(errno)))")
            close(fd); close(serverSock)
            reply(false, "bind(\(socketPath)) failed: \(String(cString: strerror(errno)))")
            return
        }

        listen(serverSock, 1)
        hlog("[Helper] FD socket ready at \(socketPath)")

        // Notify App that the socket is ready — it should connect within 10 s
        reply(true, socketPath)

        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(serverSock, SOL_SOCKET, SO_RCVTIMEO,
                   &timeout, socklen_t(MemoryLayout<timeval>.size))

        let clientSock = accept(serverSock, nil, nil)
        guard clientSock >= 0 else {
            hlog("[Helper] accept timed out or failed: \(String(cString: strerror(errno)))")
            close(fd); close(serverSock); return
        }

        hlog("[Helper] App connected — sending FD \(fd) via SCM_RIGHTS")
        sendFileDescriptor(fd, over: clientSock)

        close(clientSock)
        close(serverSock)
        close(fd)
        unlink(socketPath)
        hlog("[Helper] FD transfer complete")
    }

    private func openDirectWithRetry(rawPath: String) -> Int32 {
        let delaysUsec: [useconds_t] = [0, 50_000, 100_000, 150_000, 250_000]
        for (index, delay) in delaysUsec.enumerated() {
            if delay > 0 {
                usleep(delay)
            }
            let fd = open(rawPath, O_RDWR)
            if fd >= 0 {
                if index > 0 {
                    hlog("[Helper] direct open succeeded after retry \(index) for \(rawPath)")
                }
                return fd
            }
            let code = errno
            hlog("[Helper] direct open attempt \(index + 1) failed for \(rawPath): errno=\(code) \(String(cString: strerror(code)))")
        }
        return -1
    }

    private func runTool(_ launchPath: String, _ arguments: [String]) -> (exitCode: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
        } catch {
            return (127, "launch failed: \(error.localizedDescription)")
        }

        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (task.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func mountedFileSystemType(at mountPoint: String) -> String? {
        let result = runTool("/sbin/mount", [])
        guard result.exitCode == 0 else { return nil }

        let marker = " on \(mountPoint) ("
        for line in result.output.split(separator: "\n") {
            let text = String(line)
            guard let range = text.range(of: marker) else { continue }
            let suffix = text[range.upperBound...]
            guard let end = suffix.firstIndex(of: ")") else { continue }
            return String(suffix[..<end]).split(separator: ",").first.map(String.init)
        }
        return nil
    }

    private func isMounted(_ mountPoint: String) -> Bool {
        mountedFileSystemType(at: mountPoint) != nil
    }

    private func openFilesSummary(for mountPoint: String) -> String {
        let results = collectOpenFiles(on: mountPoint)
        guard !results.isEmpty else { return "no open files detected" }
        let preview = results.prefix(3).joined(separator: " | ")
        if results.count > 3 {
            return "\(results.count) open files: \(preview) | ..."
        }
        return "\(results.count) open files: \(preview)"
    }

    private func collectOpenFiles(on mountPoint: String) -> [String] {
        let result = runTool("/usr/sbin/lsof", ["-n", "-P", "-F", "pcn"])
        guard result.exitCode == 0 || !result.output.isEmpty else { return [] }

        var entries: [String] = []
        var currentCommand = ""
        var seen = Set<String>()
        for rawLine in result.output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix("c") {
                currentCommand = String(line.dropFirst())
            } else if line.hasPrefix("n") {
                let filePath = String(line.dropFirst())
                guard filePath.hasPrefix(mountPoint) else { continue }
                let entry = "\(currentCommand)  \(filePath)"
                if seen.insert(entry).inserted {
                    entries.append(entry)
                }
            }
        }
        return entries
    }

    private func waitUntilUnmounted(_ mountPoint: String, timeout: TimeInterval = 5.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isMounted(mountPoint) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return !isMounted(mountPoint)
    }

    /// Mount NFS share as root via /sbin/mount_nfs.
    func mountNFS(host: String, port: Int, exportPath: String,
                  mountPoint: String, options: String,
                  reply: @escaping (Bool, String) -> Void) {
        print("[Helper] mountNFS \(host):\(port)\(exportPath) → \(mountPoint) opts=\(options)")

        guard mountPoint.hasPrefix("/Volumes/") else {
            reply(false, "Invalid mount point: must be under /Volumes/")
            return
        }
        // 127.0.0.1/localhost: 旧 vsock プロキシ経由（後方互換）
        // 192.168.x.x / 10.x.x.x: VZ NAT 仮想ネットワーク（v11.0 以降の直接 TCP 経路）
        let isLocalhost = host == "127.0.0.1" || host == "localhost" || host == "::1"
        let isVZNAT     = host.hasPrefix("192.168.") || host.hasPrefix("10.")
        guard isLocalhost || isVZNAT else {
            reply(false, "Only localhost or VZ NAT NFS mounts are allowed")
            return
        }

        do {
            try FileManager.default.createDirectory(atPath: mountPoint,
                                                    withIntermediateDirectories: true)
        } catch {
            reply(false, "Cannot create mount point: \(error.localizedDescription)")
            return
        }

        // NFSv4 IDマッピング高速化: macOS が OWNER="root@localdomain" を
        // opendirectoryd に問い合わせず即座に UID=0 に解決できるようにする。
        // 未設定だと初回ディレクトリ表示で数秒の遅延が発生する。
        let domainTask = Process()
        domainTask.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        domainTask.arguments = ["-w", "vfs.generic.nfs.client.default_nfs4domain=localdomain"]
        domainTask.standardOutput = Pipe(); domainTask.standardError = Pipe()
        try? domainTask.run(); domainTask.waitUntilExit()
        print("[Helper] nfs4domain sysctl exit=\(domainTask.terminationStatus)")

        let fullOptions = options.isEmpty ? "port=\(port)" : "\(options),port=\(port)"
        let nfsSource   = "\(host):\(exportPath)"
        let cmd         = "/sbin/mount_nfs -o \(fullOptions) \(nfsSource) \(mountPoint)"
        print("[Helper] exec: \(cmd)")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/mount_nfs")
        task.arguments     = ["-o", fullOptions, nfsSource, mountPoint]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = pipe

        do { try task.run() } catch {
            reply(false, "Failed to launch mount_nfs: \(error.localizedDescription)")
            return
        }

        let deadline = Date().addingTimeInterval(30)
        while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }

        if task.isRunning {
            task.terminate()
            Thread.sleep(forTimeInterval: 1)
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            reply(false, "mount_nfs timed out after 30 s")
            return
        }

        let output   = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                              encoding: .utf8) ?? ""
        let exitCode = task.terminationStatus
        print("[Helper] mount_nfs exit=\(exitCode) output=[\(output.trimmingCharacters(in: .whitespacesAndNewlines))]")

        if exitCode == 0 {
            reply(true, "Mounted at \(mountPoint)")
        } else {
            // ⑧修正: マウント失敗時はマウントポイントディレクトリを削除（残留防止）
            try? FileManager.default.removeItem(atPath: mountPoint)
            reply(false, "mount_nfs exit \(exitCode): \(output)")
        }
    }

    /// Unmount NFS mount points as root.
    /// NFS mounts are not DiskArbitration disks, so `/usr/sbin/diskutil unmount` is only a fallback.
    func unmountNFS(mountPoint: String, reply: @escaping (Bool, String) -> Void) {
        hlog("[Helper] unmountNFS: \(mountPoint)")

        guard mountPoint.hasPrefix("/Volumes/") else {
            reply(false, "Invalid mount point: must be under /Volumes/")
            return
        }

        guard let fsType = mountedFileSystemType(at: mountPoint) else {
            hlog("[Helper] unmountNFS: \(mountPoint) already gone")
            try? FileManager.default.removeItem(atPath: mountPoint)
            reply(true, "Already unmounted \(mountPoint)")
            return
        }

        hlog("[Helper] unmountNFS: detected fsType=\(fsType)")

        let attempts: [(String, [String])]
        if fsType == "nfs" {
            attempts = [
                ("/usr/sbin/diskutil", ["unmount", "force", mountPoint]),
                ("/sbin/umount", ["-f", mountPoint]),
                ("/sbin/umount", [mountPoint]),
            ]
        } else {
            attempts = [
                ("/sbin/umount", ["-f", mountPoint]),
                ("/sbin/umount", [mountPoint]),
                ("/usr/sbin/diskutil", ["unmount", "force", mountPoint]),
            ]
        }

        for (tool, arguments) in attempts {
            let result = runTool(tool, arguments)
            hlog("[Helper] unmount attempt: \(tool) \(arguments.joined(separator: " ")) exit=\(result.exitCode) output=[\(result.output)]")

            if result.exitCode == 0, waitUntilUnmounted(mountPoint) {
                try? FileManager.default.removeItem(atPath: mountPoint)
                reply(true, "Unmounted \(mountPoint)")
                return
            }
        }

        let busySummary = openFilesSummary(for: mountPoint)
        let stillMounted = isMounted(mountPoint)
        hlog("[Helper] unmountNFS failed: mounted=\(stillMounted) \(busySummary)")
        reply(false, "unmount failed for \(mountPoint): \(busySummary)")
    }

    /// Helper が DADiskClaim でクレーム済みか（= ext4 確認済みか）を返す。
    func isClaimedDisk(bsdName: String, reply: @escaping (Bool) -> Void) {
        let result = claimedDisks[bsdName] != nil
        print("[Helper] isClaimedDisk \(bsdName) → \(result)")
        reply(result)
    }

    /// `lsof -n -P -F pcn` を root で実行し mountPoint 配下のオープンファイルを返す。
    /// root 権限で実行することで非 root 時のパーミッションタイムアウトを回避し高速動作する。
    func getOpenFilesOnMount(mountPoint: String, reply: @escaping ([String]) -> Void) {
        print("[Helper] getOpenFilesOnMount: \(mountPoint)")
        let results = collectOpenFiles(on: mountPoint)
        print("[Helper] getOpenFilesOnMount: found \(results.count) entries")
        reply(results)
    }

    // MARK: - SCM_RIGHTS FD Receiving (authopen → helper)

    private func receiveFDViaSCMRights(_ sockFd: CInt) -> CInt? {
        let cmsgSize    = MemoryLayout<cmsghdr>.size + MemoryLayout<CInt>.size
        let alignedSize = (cmsgSize + MemoryLayout<Int>.size - 1) & ~(MemoryLayout<Int>.size - 1)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: alignedSize,
                                                   alignment: MemoryLayout<Int>.alignment)
        defer { buf.deallocate() }
        memset(buf, 0, alignedSize)

        var dummy: UInt8 = 0
        let received: Int = withUnsafeMutablePointer(to: &dummy) { dPtr in
            var iov = iovec(iov_base: UnsafeMutableRawPointer(dPtr), iov_len: 1)
            return withUnsafeMutablePointer(to: &iov) { iovPtr in
                var msg = msghdr()
                msg.msg_iov        = iovPtr
                msg.msg_iovlen     = 1
                msg.msg_control    = buf
                msg.msg_controllen = socklen_t(alignedSize)
                return recvmsg(sockFd, &msg, 0)
            }
        }
        guard received > 0 else { return nil }
        let cmsg = buf.assumingMemoryBound(to: cmsghdr.self)
        guard cmsg.pointee.cmsg_level == SOL_SOCKET,
              cmsg.pointee.cmsg_type  == SCM_RIGHTS else { return nil }
        return buf.advanced(by: MemoryLayout<cmsghdr>.size).load(as: CInt.self)
    }

    // MARK: - SCM_RIGHTS FD Sending

    private func sendFileDescriptor(_ fd: CInt, over socket: CInt) {
        let cmsgSize        = MemoryLayout<cmsghdr>.size + MemoryLayout<CInt>.size
        let cmsgAlignedSize = (cmsgSize + MemoryLayout<Int>.size - 1) & ~(MemoryLayout<Int>.size - 1)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: cmsgAlignedSize,
                                                   alignment: MemoryLayout<Int>.alignment)
        defer { buf.deallocate() }
        memset(buf, 0, cmsgAlignedSize)

        var dummy: UInt8 = 0x42
        var iov  = iovec(iov_base: UnsafeMutableRawPointer(&dummy), iov_len: 1)
        var msg  = msghdr()
        msg.msg_iov        = UnsafeMutablePointer(&iov)
        msg.msg_iovlen     = 1
        msg.msg_control    = buf
        msg.msg_controllen = socklen_t(cmsgAlignedSize)

        let cmsg = buf.assumingMemoryBound(to: cmsghdr.self)
        cmsg.pointee.cmsg_level = SOL_SOCKET
        cmsg.pointee.cmsg_type  = SCM_RIGHTS
        cmsg.pointee.cmsg_len   = socklen_t(cmsgSize)
        buf.advanced(by: MemoryLayout<cmsghdr>.size).storeBytes(of: fd, as: CInt.self)

        let sent = sendmsg(socket, &msg, 0)
        if sent < 0 { print("[Helper] sendmsg failed: \(String(cString: strerror(errno)))") }
        else         { print("[Helper] FD \(fd) sent successfully") }
    }
}

// MARK: - Entry Point

let helper = Helper()
helper.run()
