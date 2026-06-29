import Foundation
import Shared
import Combine
import Darwin

/// Orchestrates disk detection, VM-based mounting, and unmounting.
/// Must be used on the main actor (SwiftUI-compatible ObservableObject).
@available(macOS 14.0, *)
@MainActor
public final class MountManager: ObservableObject {

    // MARK: - Published state

    @Published public var disks: [Ext4Disk] = []

    // MARK: - Private

    private let diskMonitor = DiskMonitor()
    /// One VZEngine per active (mounting or mounted) disk, keyed by bsdName.
    private var engines: [String: VZEngine] = [:]

    /// オートマウントの直列化キュー。
    /// 複数ディスクが同時に接続された場合でも1枚ずつ順番にマウントする。
    /// これにより authopen (Touch ID) ダイアログが同時に複数出ることを防ぐ。
    private var autoMountQueue: [String] = []
    private var isAutoMounting = false
    private var mountStateTimer: Timer?
    private var reconcilingUnmounts = Set<String>()

    // MARK: - Init / Lifecycle

    public init() {}

    public func start() {
        diskMonitor.onDiskAppeared    = { [weak self] disk in self?.handleAppeared(disk)    }
        diskMonitor.onDiskDisappeared = { [weak self] disk in self?.handleDisappeared(disk) }
        diskMonitor.start()
        startMountStateMonitor()
        elog("[MountManager] started")
    }

    public func stop() {
        mountStateTimer?.invalidate()
        mountStateTimer = nil
        diskMonitor.stop()
        elog("[MountManager] stopped")
    }

    // MARK: - Disk events (called on main from DiskMonitor)

    private func handleAppeared(_ disk: Ext4Disk) {
        if let idx = disks.firstIndex(where: { $0.bsdName == disk.bsdName }) {
            // DA が提供する名前で常に上書きする。
            // IOKit 初回スキャンが "disk" 等の汎用名をセットすることがある。
            // DA はその後 ~0.8s で正確な GPT 名を提供するため、常に DA を優先する。
            if let newName = disk.volumeName, !newName.isEmpty, newName != disks[idx].volumeName {
                let existing = disks[idx]
                let updated = Ext4Disk(id: existing.id, bsdName: existing.bsdName,
                                       devicePath: existing.devicePath, volumeName: newName,
                                       size: existing.size, mountPoint: existing.mountPoint,
                                       status: existing.status, preflight: existing.preflight,
                                       activityNote: existing.activityNote)
                disks[idx] = updated
            }
            return
        }
        disks.append(disk)
        elog("[MountManager] ✅ appeared: \(disk.bsdName) vol='\(disk.volumeName ?? "-")'")
        startPreflight(for: disk)

        // Auto-mount: wait 1.5 s so IOKit finishes enumerating the device.
        // キューに追加して直列化する（複数ディスク同時接続時に authopen が重複しないようにする）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            guard let current = self.disks.first(where: { $0.bsdName == disk.bsdName }),
                  current.status == .unmounted else { return }
            self.enqueueAutoMount(bsdName: disk.bsdName)
        }
    }

    private func handleDisappeared(_ disk: Ext4Disk) {
        // ⑤修正: マウント中の場合はアンマウント完了後に削除する（完了前の削除を防ぐ）
        if let d = disks.first(where: { $0.bsdName == disk.bsdName }),
           (d.status == .mounted || d.status == .mounting),
           let mp = d.mountPoint {
            elog("[MountManager] ⚠️ disappeared while mounted — forcing unmount: \(disk.bsdName)")
            // FD キャッシュを無効化
            let rawPathD = disk.devicePath.hasPrefix("/dev/rdisk")
                ? disk.devicePath
                : disk.devicePath.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
            VZEngine.invalidateFDCache(for: rawPathD)
            replace(bsdName: disk.bsdName, status: .unmounting, mountPoint: mp, activityNote: nil)
            let engine = engines[disk.bsdName] ?? VZEngine()
            engine.unmount(mountPoint: mp) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.engines.removeValue(forKey: disk.bsdName)
                    self?.disks.removeAll { $0.bsdName == disk.bsdName }
                    elog("[MountManager] ❌ disappeared + unmounted: \(disk.bsdName)")
                }
            }
            return
        }
        // FD キャッシュを無効化（ドライブ抜去 → 次回は再認証が必要）
        let rawPath = disk.devicePath.hasPrefix("/dev/rdisk")
            ? disk.devicePath
            : disk.devicePath.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
        VZEngine.invalidateFDCache(for: rawPath)

        disks.removeAll { $0.bsdName == disk.bsdName }
        elog("[MountManager] ❌ disappeared: \(disk.bsdName)")
    }

    // MARK: - Auto-mount queue (serialized)

    private func enqueueAutoMount(bsdName: String) {
        guard !autoMountQueue.contains(bsdName) else { return }
        autoMountQueue.append(bsdName)
        elog("[MountManager] 📋 enqueued auto-mount: \(bsdName) (queue=\(autoMountQueue))")
        drainAutoMountQueue()
    }

    private func drainAutoMountQueue() {
        guard !isAutoMounting, !autoMountQueue.isEmpty else { return }
        let bsdName = autoMountQueue.removeFirst()
        guard let current = disks.first(where: { $0.bsdName == bsdName }),
              current.status == .unmounted else {
            // already mounted or gone — try next
            drainAutoMountQueue(); return
        }
        isAutoMounting = true
        elog("[MountManager] 🔄 auto-mount start: \(bsdName)")
        mount(bsdName: bsdName, completion: { [weak self] in
            guard let self else { return }
            self.isAutoMounting = false
            self.drainAutoMountQueue()
        })
    }

    // MARK: - Public mount / unmount

    public func mount(bsdName: String) {
        mount(bsdName: bsdName, completion: nil)
    }

    private func mount(bsdName: String, completion: (() -> Void)?) {
        guard let disk = disks.first(where: { $0.bsdName == bsdName }),
              disk.status == .unmounted || disk.status == .error else {
            completion?(); return
        }

        replace(bsdName: bsdName, status: .mounting, mountPoint: disk.mountPoint, activityNote: nil)

        let engine = VZEngine()
        engines[bsdName] = engine

        engine.onAbnormalStop = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                elog("[MountManager] ⚠️ abnormal stop \(bsdName): \(error.localizedDescription)")
                self.engines.removeValue(forKey: bsdName)
                self.replace(bsdName: bsdName, status: .error, mountPoint: nil, activityNote: nil)
                completion?()
            }
        }

        engine.mount(disk: disk) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let mp):
                    let volName = (mp as NSString).lastPathComponent
                    self.replace(bsdName: bsdName, status: .mounted,
                                 mountPoint: mp, volumeName: volName, activityNote: nil)
                    elog("[MountManager] ✅ mounted \(bsdName) → \(mp) (label='\(volName)')")
                case .failure(let err):
                    elog("[MountManager] ❌ mount error \(bsdName): \(err.localizedDescription)")
                    self.engines.removeValue(forKey: bsdName)
                    self.replace(bsdName: bsdName, status: .error, mountPoint: nil, activityNote: nil)
                }
                completion?()
            }
        }
    }

    public func unmount(bsdName: String) {
        guard let disk = disks.first(where: { $0.bsdName == bsdName }),
              let mp = disk.mountPoint else { return }
        performUnmount(bsdName: bsdName, mountPoint: mp)
    }

    /// Unmount all currently active disks.
    /// `completion` is called on the main queue when all unmounts finish (or immediately
    /// if there is nothing to unmount). Used for graceful app termination.
    public func unmountAll(completion: @escaping () -> Void = {}) {
        let active = disks.filter {
            ($0.status == .mounted || $0.status == .mounting || $0.status == .starting)
                && $0.mountPoint != nil
        }
        guard !active.isEmpty else {
            completion()
            return
        }

        let group = DispatchGroup()
        for disk in active {
            guard let mp = disk.mountPoint else { continue }
            group.enter()
            replace(bsdName: disk.bsdName, status: .unmounting, mountPoint: mp, activityNote: nil)
            let engine = engines[disk.bsdName] ?? VZEngine()
            engine.unmount(mountPoint: mp) { [weak self] _ in
                // Always leave the group regardless of success/failure
                DispatchQueue.main.async {
                    self?.engines.removeValue(forKey: disk.bsdName)
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            elog("[MountManager] unmountAll complete")
            completion()
        }
    }

    // MARK: - Internal unmount

    private func performUnmount(bsdName: String, mountPoint: String) {
        replace(bsdName: bsdName, status: .unmounting, mountPoint: mountPoint, activityNote: nil)

        let engine = engines[bsdName] ?? VZEngine()

        engine.unmount(mountPoint: mountPoint) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.engines.removeValue(forKey: bsdName)
                self.reconcilingUnmounts.remove(bsdName)
                switch result {
                case .success:
                    self.replace(bsdName: bsdName, status: .unmounted, mountPoint: nil, activityNote: nil)
                    elog("[MountManager] ✅ unmounted \(bsdName)")
                case .failure(let err):
                    elog("[MountManager] ❌ unmount error \(bsdName): \(err.localizedDescription)")
                    self.replace(bsdName: bsdName, status: .error,
                                 mountPoint: mountPoint, activityNote: nil)
                }
            }
        }
    }

    private func startMountStateMonitor() {
        mountStateTimer?.invalidate()
        mountStateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcileExternalUnmounts()
            }
        }
        RunLoop.main.add(mountStateTimer!, forMode: .common)
    }

    private func reconcileExternalUnmounts() {
        let tracked = disks.filter {
            ($0.status == .mounted || $0.status == .unmounting) && $0.mountPoint != nil
        }

        for disk in tracked {
            guard let mountPoint = disk.mountPoint else { continue }
            guard !isMountPointActive(mountPoint) else { continue }
            guard reconcilingUnmounts.insert(disk.bsdName).inserted else { continue }

            elog("[MountManager] ⚠️ external unmount detected: \(disk.bsdName) mountPoint=\(mountPoint)")
            replace(bsdName: disk.bsdName, status: .unmounting, mountPoint: mountPoint,
                    activityNote: "macOS側で解除を検出")

            let engine = engines[disk.bsdName] ?? VZEngine()
            engine.unmount(mountPoint: mountPoint) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.engines.removeValue(forKey: disk.bsdName)
                    self.reconcilingUnmounts.remove(disk.bsdName)
                    switch result {
                    case .success:
                        self.replace(bsdName: disk.bsdName, status: .unmounted, mountPoint: nil,
                                     activityNote: "macOS側でアンマウント済み")
                        elog("[MountManager] ✅ reconciled external unmount \(disk.bsdName)")
                    case .failure(let err):
                        self.replace(bsdName: disk.bsdName, status: .error, mountPoint: nil,
                                     activityNote: "外部アンマウント後の後始末に失敗")
                        elog("[MountManager] ❌ external unmount reconcile failed \(disk.bsdName): \(err.localizedDescription)")
                    }
                }
            }
        }
    }

    private func isMountPointActive(_ mountPoint: String) -> Bool {
        var mountsPtr: UnsafeMutablePointer<statfs>?
        let count = Int(getmntinfo(&mountsPtr, MNT_NOWAIT))
        guard count > 0, let mounts = mountsPtr else { return false }

        for index in 0..<count {
            let entry = mounts[index]
            let currentMount = withUnsafePointer(to: entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) {
                    String(cString: $0)
                }
            }
            if currentMount == mountPoint {
                return true
            }
        }
        return false
    }

    // MARK: - Disk array mutation helper

    private func startPreflight(for disk: Ext4Disk) {
        guard #available(macOS 15.0, *) else { return }

        let devicePath = preferredPreflightPath(for: disk.devicePath)
        let bsdName = disk.bsdName
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let info = try Ext4PreflightService.inspect(devicePath: devicePath)
                DispatchQueue.main.async {
                    self?.applyPreflight(info, to: bsdName)
                }
            } catch {
                let nsError = error as NSError
                elog("[MountManager] preflight deferred \(bsdName): \(nsError.domain) code=\(nsError.code)")
            }
        }
    }

    private func preferredPreflightPath(for devicePath: String) -> String {
        if devicePath.hasPrefix("/dev/rdisk") {
            return devicePath
        }
        let rawPath = devicePath.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
        return FileManager.default.fileExists(atPath: rawPath) ? rawPath : devicePath
    }

    private func applyPreflight(_ preflight: Ext4Preflight, to bsdName: String) {
        guard let idx = disks.firstIndex(where: { $0.bsdName == bsdName }) else { return }
        let d = disks[idx]
        let preferredName = preflight.volumeLabel ?? d.volumeName
        let incompat = preflight.incompatFeatures.joined(separator: ", ")
        let roCompat = preflight.roCompatFeatures.joined(separator: ", ")
        disks[idx] = Ext4Disk(id: d.id, bsdName: d.bsdName, devicePath: d.devicePath,
                              volumeName: preferredName, size: d.size,
                              mountPoint: d.mountPoint, status: d.status,
                              preflight: preflight, activityNote: d.activityNote)
        elog("[MountManager] preflight \(bsdName): \(preflight.summaryLine)")
        elog("[MountManager] preflight mode \(bsdName): \(preflight.compatibility.rawValue)")
        if !preflight.incompatFeatures.isEmpty {
            elog("[MountManager] preflight incompat \(bsdName): \(incompat)")
        }
        if !preflight.roCompatFeatures.isEmpty {
            elog("[MountManager] preflight ro-compat \(bsdName): \(roCompat)")
        }
    }

    /// Replace the disk entry for `bsdName` with updated status, mountPoint, and optional volumeName.
    private func replace(bsdName: String, status: MountStatus,
                         mountPoint: String?, volumeName: String? = nil,
                         activityNote: String? = nil) {
        guard let idx = disks.firstIndex(where: { $0.bsdName == bsdName }) else { return }
        let d = disks[idx]
        disks[idx] = Ext4Disk(id: d.id, bsdName: d.bsdName, devicePath: d.devicePath,
                              volumeName: volumeName ?? d.volumeName,
                              size: d.size, mountPoint: mountPoint, status: status,
                              preflight: d.preflight, activityNote: activityNote)
    }
}
