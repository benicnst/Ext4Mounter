import Foundation

// MARK: - Ext4Disk

public struct Ext4Disk: Identifiable {
    public let id: UUID
    public let bsdName: String       // "disk4s1"
    public let devicePath: String    // "/dev/disk4s1"
    public let volumeName: String?
    public let size: UInt64          // bytes
    public let mountPoint: String?
    public let status: MountStatus

    public init(id: UUID = UUID(), bsdName: String, devicePath: String,
                volumeName: String? = nil, size: UInt64,
                mountPoint: String? = nil, status: MountStatus = .unmounted) {
        self.id = id; self.bsdName = bsdName; self.devicePath = devicePath
        self.volumeName = volumeName; self.size = size
        self.mountPoint = mountPoint; self.status = status
    }

    public var displayName: String { volumeName ?? bsdName }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// ASCII-safe name for paths / process argv
    public var safeVolumeName: String {
        let src = (volumeName?.isEmpty == false) ? volumeName! : bsdName
        let extra = CharacterSet(charactersIn: "-_.")
        let s = String(src.unicodeScalars.map { c -> Character in
            (CharacterSet.alphanumerics.contains(c) || extra.contains(c)) ? Character(c) : "_"
        })
        let compact = s.replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        let trimmed = compact.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return String((trimmed.isEmpty ? bsdName : trimmed).prefix(64))
    }
}

// MARK: - MountStatus

public enum MountStatus: String {
    case unmounted, mounting, starting, mounted, unmounting, error

    public var displayText: String {
        switch self {
        case .unmounted:  return "未マウント"
        case .mounting:   return "マウント中..."
        case .starting:   return "VM起動中..."
        case .mounted:    return "マウント完了"
        case .unmounting: return "アンマウント中..."
        case .error:      return "エラー"
        }
    }

    public var isInProgress: Bool {
        switch self { case .mounting, .starting, .unmounting: return true; default: return false }
    }
}

// MARK: - Engine Config

public struct VMEngineConfig {
    public let cpuCount: Int
    public let memorySizeMB: UInt64   // MiB
    public let kernelPath: String
    public let initrdPath: String

    public static var `default`: VMEngineConfig {
        let fm = FileManager.default
        let bundle = Bundle.main.resourcePath ?? ""
        let kn = "vmlinux-alpine-raw"
        let rn = "initramfs-alpine.gz"
        let candidates = [
            bundle,
            "\(fm.currentDirectoryPath)/../Ext4Mounter.app/Contents/Resources",
            "\(fm.currentDirectoryPath)/Ext4Mounter.app/Contents/Resources",
            "\(fm.currentDirectoryPath)/../../app/Ext4Mounter.app/Contents/Resources",
            "\(NSHomeDirectory())/Desktop/APP/Ext4Mounter/current/v1.2.5/app/Ext4Mounter.app/Contents/Resources",
        ]
        let base = candidates.first {
            fm.fileExists(atPath: "\($0)/\(kn)") && fm.fileExists(atPath: "\($0)/\(rn)")
        } ?? bundle
        // mem=4096: ページキャッシュ拡大 → 連続読み込みがキャッシュヒットで高速化
        // 2048→4096: より多くのext4データをページキャッシュに保持 → 繰り返しアクセスがRAM速度
        return VMEngineConfig(cpuCount: 4, memorySizeMB: 4096,
                              kernelPath: "\(base)/\(kn)", initrdPath: "\(base)/\(rn)")
    }

    public init(cpuCount: Int, memorySizeMB: UInt64, kernelPath: String, initrdPath: String) {
        self.cpuCount = cpuCount; self.memorySizeMB = memorySizeMB
        self.kernelPath = kernelPath; self.initrdPath = initrdPath
    }
}

// MARK: - Errors

public enum Ext4MounterError: LocalizedError {
    case deviceOpenFailed(String)
    case vmConfigFailed(String)
    case vmStartFailed(String)
    case nfsNotReady(String)
    case mountFailed(String)
    case unmountFailed(String)
    /// Catch-all for errors that don't fit a specific category.
    case general(String)
    /// Timed-out waiting for a condition.
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .deviceOpenFailed(let m): return "デバイスを開けませんでした: \(m)"
        case .vmConfigFailed(let m):   return "VM設定エラー: \(m)"
        case .vmStartFailed(let m):    return "VM起動エラー: \(m)"
        case .nfsNotReady(let m):      return "NFSサーバー起動失敗: \(m)"
        case .mountFailed(let m):      return "マウント失敗: \(m)"
        case .unmountFailed(let m):    return "アンマウント失敗: \(m)"
        case .general(let m):          return "エラー: \(m)"
        case .timeout(let m):          return "タイムアウト: \(m)"
        }
    }
}
