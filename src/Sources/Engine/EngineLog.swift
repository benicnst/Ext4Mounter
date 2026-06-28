import Foundation

/// Thread-safe logger that writes to both stderr and a persistent log file.
/// Log file: ~/Library/Logs/Ext4Mounter/engine.log
/// Call EngineLog.clear() on app start to begin a fresh session.
public final class EngineLog {

    public static let shared = EngineLog()

    private let fileURL: URL
    private let lock   = NSLock()
    private var handle: FileHandle?

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Ext4Mounter")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("engine.log")
    }

    // MARK: - Session

    /// Truncate the log file and write a session header.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        handle?.closeFile(); handle = nil
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
        openHandle()
        raw("=== Ext4Mounter v6.0 engine log — session start ===")
    }

    // MARK: - Write

    public func write(_ msg: String) {
        let ts   = Self.df.string(from: Date())
        let line = "[\(ts)] \(msg)"
        fputs(line + "\n", stderr); fflush(stderr)
        lock.lock(); defer { lock.unlock() }
        if handle == nil { openHandle() }
        guard let h = handle else { return }
        if let d = (line + "\n").data(using: .utf8) { h.write(d) }
    }

    // MARK: - Private

    private func raw(_ msg: String) {
        if handle == nil { openHandle() }
        guard let h = handle else { return }
        if let d = (msg + "\n").data(using: .utf8) { h.write(d) }
    }

    private func openHandle() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()
    }
}

// MARK: - Convenience

public func elog(_ msg: String) { EngineLog.shared.write(msg) }
