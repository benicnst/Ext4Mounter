import Foundation
import DiskArbitration
import IOKit
import Shared

/// Detects ext4 disks via DiskArbitration + IOKit. Suppresses macOS "unreadable disk" dialogs.
@available(macOS 13.0, *)
public class DiskMonitor {
    private var session: DASession?
    private var disks: [String: Ext4Disk] = [:]

    /// 専用の高優先度キュー。メインキューの詰まりに関係なく
    /// DA 承認コールバックを即座に返すことでダイアログ抑制の競合を減らす。
    private let daQueue = DispatchQueue(label: "com.ext4mounter.diskmonitor",
                                        qos: .userInteractive)

    public var onDiskAppeared: ((Ext4Disk) -> Void)?
    public var onDiskDisappeared: ((Ext4Disk) -> Void)?

    public init() {}
    deinit { stop() }

    public func start() {
        guard session == nil else { return }
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        DASessionSetDispatchQueue(session, daQueue)

        DARegisterDiskMountApprovalCallback(session, nil as CFDictionary?, { disk, ctx in
            guard let ctx = ctx else { return nil }
            return Unmanaged<DiskMonitor>.fromOpaque(ctx).takeUnretainedValue().shouldBlock(disk)
        }, Unmanaged.passUnretained(self).toOpaque())

        DARegisterDiskAppearedCallback(session, nil as CFDictionary?, { disk, ctx in
            guard let ctx = ctx else { return }
            Unmanaged<DiskMonitor>.fromOpaque(ctx).takeUnretainedValue().handleAppeared(disk)
        }, Unmanaged.passUnretained(self).toOpaque())

        DARegisterDiskDisappearedCallback(session, nil as CFDictionary?, { disk, ctx in
            guard let ctx = ctx else { return }
            Unmanaged<DiskMonitor>.fromOpaque(ctx).takeUnretainedValue().handleDisappeared(disk)
        }, Unmanaged.passUnretained(self).toOpaque())

        scanExistingDisks()
    }

    public func stop() { session = nil }

    // MARK: - DA Callbacks

    private func shouldBlock(_ disk: DADisk) -> Unmanaged<DADissenter>? {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any],
              let bsd = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String else { return nil }
        if isLinuxCandidate(desc) {
            let d = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnExclusiveAccess),
                                     "Ext4Mounter handles this disk" as CFString)
            print("[DiskMonitor] blocking macOS mount for \(bsd)")
            return Unmanaged.passRetained(d)
        }
        return nil
    }

    private func handleAppeared(_ disk: DADisk) {
        // コールバック発火直後は macOS がまだ FS を識別中のため VolumeKindKey が空。
        // exFAT が EBD0A0A2 パーティション型と一致して誤検出される。
        // Helper と同様に 0.8 秒遅延後に最新の記述を再取得して再判定する。
        guard let desc = DADiskCopyDescription(disk) as? [String: Any],
              let bsd = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String else { return }
        // 0.8秒後に DA の最新記述を再取得して判定する:
        // - exFAT/HFS+等: VolumeKindKey に FS 名が設定される → isKnownNonLinuxFS = true → スキップ
        // - ext4: macOS が認識できないため VolumeKindKey が空のまま → 処理対象
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let session = self.session else { return }
            guard let freshDisk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd),
                  let freshDesc = DADiskCopyDescription(freshDisk) as? [String: Any] else { return }
            self.processDisk(freshDesc)
        }
    }

    private func handleDisappeared(_ disk: DADisk) {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any],
              let bsd = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let d = self.disks.removeValue(forKey: bsd) else { return }
            print("[DiskMonitor] disappeared: \(bsd)")
            self.onDiskDisappeared?(d)
        }
    }

    // MARK: - IOKit Scan

    private func scanExistingDisks() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let matching = IOServiceMatching("IOMedia") else { return }
            var iter: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(iter) }

            while case let svc = IOIteratorNext(iter), svc != 0 {
                defer { IOObjectRelease(svc) }
                var cf: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(svc, &cf, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let props = cf?.takeRetainedValue() as? [String: Any] else { continue }

                let bsd     = props["BSD Name"] as? String ?? ""
                let content = props["Content"] as? String ?? ""
                let isWhole = props["Whole"] as? Bool ?? true
                let size    = props["Size"] as? UInt64 ?? 0
                let ioName  = props["Name"] as? String
                guard !isWhole, !bsd.isEmpty else { continue }

                // IORegistryEntryName はパーティション名として補完で使う
                var regNameBuf = [CChar](repeating: 0, count: 128)
                let ioRegName: String? = {
                    guard IORegistryEntryGetName(svc, &regNameBuf) == KERN_SUCCESS else { return nil }
                    let s = String(cString: regNameBuf)
                    return s.isEmpty ? nil : s
                }()
                let bestName: String? = (ioName.flatMap { $0.isEmpty ? nil : $0 }) ?? ioRegName

                let cu = content.uppercased()
                let candidate = cu.contains("EBD0A0A2") || cu.contains("0FC63DAF") ||
                                content.contains("Linux") || content.lowercased().contains("ext") ||
                                content == "0x83"
                guard candidate else { continue }

                print("[DiskMonitor] IOKit candidate: \(bsd) content='\(content)' name='\(ioName ?? "-")' regName='\(ioRegName ?? "-")'")
                let captBsd = bsd; let captSize = size; let captName = bestName
                let captContent = content
                DispatchQueue.main.async { [weak self] in
                    var desc: [String: Any] = [
                        kDADiskDescriptionMediaBSDNameKey as String: captBsd,
                        kDADiskDescriptionMediaContentKey as String: captContent,
                        kDADiskDescriptionMediaSizeKey   as String: captSize,
                        kDADiskDescriptionVolumeKindKey  as String: ""
                    ]
                    if let n = captName, !n.isEmpty {
                        desc[kDADiskDescriptionVolumeNameKey as String] = n
                    }
                    self?.processDisk(desc)
                }
            }
        }
    }

    // MARK: - Disk Processing

    private func processDisk(_ desc: [String: Any]) {
        guard let bsd = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String else { return }

        // If already tracked, check if DA is correcting a false positive from IOKit
        if let existing = disks[bsd] {
            if isKnownNonLinuxFS(desc) {
                // IOKit registered this as ext4 candidate, but DA now says it's exFAT/HFS/etc.
                disks.removeValue(forKey: bsd)
                print("[DiskMonitor] ⚠️ Revoking false positive: \(bsd) identified as non-Linux FS")
                onDiskDisappeared?(existing)
                return
            }
            // DA が提供する名前で常に上書きする。
            // IOKit スキャン（初回）は props["Name"] / IORegistryEntryGetName から
            // "disk" 等の汎用名をセットすることがある。DA はその後 0.8 秒で正確な
            // GPT パーティション名を提供するため、DA の情報を常に優先させる。
            // kDADiskDescriptionVolumeNameKey: FS固有の名前（ext4はnilになる）
            // kDADiskDescriptionMediaNameKey:  GPTパーティション名（ext4でも取得可能）
            let newName: String? = {
                if let n = desc[kDADiskDescriptionVolumeNameKey as String] as? String, !n.isEmpty { return n }
                if let n = desc[kDADiskDescriptionMediaNameKey  as String] as? String, !n.isEmpty { return n }
                return nil
            }()
            if let n = newName, !n.isEmpty, n != existing.volumeName {
                let updated = Ext4Disk(id: existing.id, bsdName: bsd, devicePath: existing.devicePath,
                                       volumeName: n, size: existing.size,
                                       mountPoint: existing.mountPoint, status: existing.status,
                                       preflight: existing.preflight,
                                       activityNote: existing.activityNote)
                disks[bsd] = updated
                onDiskAppeared?(updated)
            }
            return
        }

        guard isLinuxCandidate(desc) else { return }

        let devicePath = "/dev/\(bsd)"
        let volumeName: String? = {
            if let n = desc[kDADiskDescriptionVolumeNameKey as String] as? String, !n.isEmpty { return n }
            if let n = desc[kDADiskDescriptionMediaNameKey  as String] as? String, !n.isEmpty { return n }
            return nil
        }()
        let size       = desc[kDADiskDescriptionMediaSizeKey   as String] as? UInt64 ?? 0

        let disk = Ext4Disk(bsdName: bsd, devicePath: devicePath,
                            volumeName: volumeName, size: size)
        disks[bsd] = disk
        print("[DiskMonitor] ✅ ext4 candidate: \(bsd) vol='\(volumeName ?? "-")'")
        onDiskAppeared?(disk)
    }

    /// Returns true if the filesystem type from DiskArbitration is a known non-Linux FS.
    /// IOKit scan sets fsType to "" so this only fires when DA has real info.
    private func isKnownNonLinuxFS(_ desc: [String: Any]) -> Bool {
        let fsType = (desc[kDADiskDescriptionVolumeKindKey as String] as? String ?? "").lowercased()
        guard !fsType.isEmpty else { return false }
        let nonLinux: Set<String> = ["exfat", "hfs", "apfs", "msdos", "fat", "fat32",
                                     "ntfs", "ufsd_ntfs", "cd9660", "udf", "ufs"]
        return nonLinux.contains(fsType)
    }

    private func isLinuxCandidate(_ desc: [String: Any]) -> Bool {
        // Reject disks whose filesystem is already identified as a known non-Linux FS.
        // exFAT drives use the same "Microsoft Basic Data" (EBD0A0A2) partition type as Linux
        // ext4, so partition type alone is not sufficient.
        if isKnownNonLinuxFS(desc) { return false }

        let pt = desc[kDADiskDescriptionMediaContentKey as String] as? String ?? ""
        let pu = pt.uppercased()
        return pt.contains("Linux") || pu.contains("0FC63DAF") ||
               pu.contains("EBD0A0A2") || pt.contains("Microsoft Basic Data") ||
               pt == "0x83" || pt.lowercased().contains("ext")
    }
}
