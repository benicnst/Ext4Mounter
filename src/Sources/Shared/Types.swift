import Foundation

// MARK: - Ext4Disk

public struct Ext4Preflight {
    public let volumeLabel: String?
    public let uuid: String
    public let blockSize: UInt32
    public let hasJournal: Bool
    public let compatFeatures: [String]
    public let incompatFeatures: [String]
    public let roCompatFeatures: [String]

    public init(volumeLabel: String? = nil,
                uuid: String,
                blockSize: UInt32,
                hasJournal: Bool,
                compatFeatures: [String] = [],
                incompatFeatures: [String] = [],
                roCompatFeatures: [String] = []) {
        self.volumeLabel = volumeLabel
        self.uuid = uuid
        self.blockSize = blockSize
        self.hasJournal = hasJournal
        self.compatFeatures = compatFeatures
        self.incompatFeatures = incompatFeatures
        self.roCompatFeatures = roCompatFeatures
    }

    public var summaryLine: String {
        let label = volumeLabel ?? "-"
        let journal = hasJournal ? "journal=yes" : "journal=no"
        return "label=\(label) uuid=\(uuid) block=\(blockSize) \(journal)"
    }

    public var compatibility: Ext4Compatibility {
        let incompat = Set(incompatFeatures)
        let roCompat = Set(roCompatFeatures)

        if incompat.contains("encrypt") ||
            incompat.contains("inlineData") ||
            incompat.contains("eaInode") ||
            incompat.contains("dirdata") ||
            incompat.contains("journalDev") ||
            roCompat.contains("readonly") ||
            roCompat.contains("bigalloc") ||
            roCompat.contains("quota") ||
            roCompat.contains("project") ||
            roCompat.contains("hasSnapshot") ||
            roCompat.contains("replica") {
            return .readOnlyRecommended
        }

        if incompat.contains("mmp") || incompat.contains("largedir") {
            return .caution
        }

        return .readWriteReady
    }

    public var uiStatusLine: String {
        switch compatibility {
        case .readWriteReady:
            return "ext4 preflight: 書き込みマウント候補"
        case .caution:
            return "ext4 preflight: 注意が必要"
        case .readOnlyRecommended:
            return "ext4 preflight: 読み取り中心を推奨"
        }
    }
}

public enum Ext4Compatibility: String {
    case readWriteReady
    case caution
    case readOnlyRecommended

    public var userMessage: String {
        switch self {
        case .readWriteReady:
            return "この ext4 ボリュームは通常の書き込みマウント候補です。"
        case .caution:
            return "この ext4 ボリュームは注意が必要です。マウント前に feature を確認してください。"
        case .readOnlyRecommended:
            return "この ext4 ボリュームは読み取り中心の扱いを推奨します。"
        }
    }
}

public struct Ext4Disk: Identifiable {
    public let id: UUID
    public let bsdName: String       // "disk4s1"
    public let devicePath: String    // "/dev/disk4s1"
    public let volumeName: String?
    public let size: UInt64          // bytes
    public let mountPoint: String?
    public let status: MountStatus
    public let preflight: Ext4Preflight?
    public let activityNote: String?

    public init(id: UUID = UUID(), bsdName: String, devicePath: String,
                volumeName: String? = nil, size: UInt64,
                mountPoint: String? = nil, status: MountStatus = .unmounted,
                preflight: Ext4Preflight? = nil,
                activityNote: String? = nil) {
        self.id = id; self.bsdName = bsdName; self.devicePath = devicePath
        self.volumeName = volumeName; self.size = size
        self.mountPoint = mountPoint; self.status = status
        self.preflight = preflight
        self.activityNote = activityNote
    }

    public var displayName: String { preflight?.volumeLabel ?? volumeName ?? bsdName }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    public var preflightStatusLine: String? {
        preflight?.uiStatusLine
    }

    /// ASCII-safe name for paths / process argv
    public var safeVolumeName: String {
        let preferredName = preflight?.volumeLabel ?? volumeName
        let src = (preferredName?.isEmpty == false) ? preferredName! : bsdName
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
        let bundle = Bundle.main.resourceURL?.path ?? Bundle.main.resourcePath ?? ""
        let kn = "vmlinux-alpine-raw"
        let rn = "initramfs-alpine.gz"

        let executableResourcePath = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .path

        let candidates = [
            bundle,
            executableResourcePath,
            "\(fm.currentDirectoryPath)/../Ext4Mounter.app/Contents/Resources",
            "\(fm.currentDirectoryPath)/Ext4Mounter.app/Contents/Resources",
            "\(fm.currentDirectoryPath)/../../app/Ext4Mounter.app/Contents/Resources",
        ].compactMap { $0 }.filter { !$0.isEmpty }

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
