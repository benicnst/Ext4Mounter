import ContainerizationEXT4
import Darwin
import Foundation
import Shared

@available(macOS 15.0, *)
enum Ext4PreflightService {
    static func inspect(devicePath: String) throws -> Ext4Preflight {
        let fd = open(devicePath, O_RDONLY)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        return try inspect(fileDescriptor: fd)
    }

    static func inspect(fileDescriptor: Int32) throws -> Ext4Preflight {
        let sb = try readSuperBlock(fileDescriptor: fileDescriptor)
        return makePreflight(from: sb)
    }

    private static func makePreflight(from sb: EXT4.SuperBlock) -> Ext4Preflight {
        return Ext4Preflight(
            volumeLabel: decodeVolumeLabel(sb.volumeName),
            uuid: formatUUID(sb.uuid),
            blockSize: sb.blockSize,
            hasJournal: (sb.featureCompat & 0x4) != 0 || sb.journalInum != 0,
            compatFeatures: decodeFeatures(sb.featureCompat, map: compatFeatureNames),
            incompatFeatures: decodeFeatures(sb.featureIncompat, map: incompatFeatureNames),
            roCompatFeatures: decodeFeatures(sb.featureRoCompat, map: roCompatFeatureNames)
        )
    }

    private static func readSuperBlock(fileDescriptor: Int32) throws -> EXT4.SuperBlock {
        let byteCount = MemoryLayout<EXT4.SuperBlock>.size
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let readCount = bytes.withUnsafeMutableBytes { rawBuffer in
            pread(fileDescriptor, rawBuffer.baseAddress, byteCount, off_t(1024))
        }

        guard readCount == byteCount else {
            throw EXT4.Error.couldNotReadSuperBlock("/dev/fd/\(fileDescriptor)", 1024, byteCount)
        }
        let sb = bytes.withUnsafeBytes { $0.load(as: EXT4.SuperBlock.self) }
        guard sb.magic == EXT4.SuperBlockMagic else {
            throw EXT4.Error.invalidSuperBlock
        }
        return sb
    }

    private static let compatFeatureNames: [(UInt32, String)] = [
        (0x1, "dirPrealloc"),
        (0x2, "imagicInodes"),
        (0x4, "hasJournal"),
        (0x8, "extAttr"),
        (0x10, "resizeInode"),
        (0x20, "dirIndex"),
        (0x40, "lazyBg"),
        (0x80, "excludeInode"),
        (0x100, "excludeBitmap"),
        (0x200, "sparseSuper2"),
    ]

    private static let incompatFeatureNames: [(UInt32, String)] = [
        (0x1, "compression"),
        (0x2, "filetype"),
        (0x4, "recover"),
        (0x8, "journalDev"),
        (0x10, "metaBg"),
        (0x40, "extents"),
        (0x80, "bit64"),
        (0x100, "mmp"),
        (0x200, "flexBg"),
        (0x400, "eaInode"),
        (0x1000, "dirdata"),
        (0x2000, "csumSeed"),
        (0x4000, "largedir"),
        (0x8000, "inlineData"),
        (0x10000, "encrypt"),
    ]

    private static let roCompatFeatureNames: [(UInt32, String)] = [
        (0x1, "sparseSuper"),
        (0x2, "largeFile"),
        (0x4, "btreeDir"),
        (0x8, "hugeFile"),
        (0x10, "gdtCsum"),
        (0x20, "dirNlink"),
        (0x40, "extraIsize"),
        (0x80, "hasSnapshot"),
        (0x100, "quota"),
        (0x200, "bigalloc"),
        (0x400, "metadataCsum"),
        (0x800, "replica"),
        (0x1000, "readonly"),
        (0x2000, "project"),
    ]

    private static func decodeFeatures(_ value: UInt32, map: [(UInt32, String)]) -> [String] {
        map.compactMap { bit, name in
            (value & bit) != 0 ? name : nil
        }
    }

    private static func decodeVolumeLabel(
        _ tuple: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        )
    ) -> String? {
        let bytes = tupleBytes(tuple)
        let raw = bytes.prefix { $0 != 0 }
        guard !raw.isEmpty else { return nil }
        return String(bytes: raw, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func formatUUID(
        _ tuple: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        )
    ) -> String {
        let bytes = tupleBytes(tuple)
        let hex = bytes.map { String(format: "%02x", $0) }
        return [
            hex[0...3].joined(),
            hex[4...5].joined(),
            hex[6...7].joined(),
            hex[8...9].joined(),
            hex[10...15].joined(),
        ].joined(separator: "-")
    }

    private static func tupleBytes(
        _ tuple: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        )
    ) -> [UInt8] {
        withUnsafeBytes(of: tuple) { Array($0) }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
