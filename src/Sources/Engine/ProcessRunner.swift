import Foundation
import Darwin

/// Runs external processes with a hard timeout. Prevents indefinite hangs.
enum ProcessRunner {
    struct Result {
        let terminationStatus: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    static func run(executablePath: String, arguments: [String],
                    timeoutSeconds: TimeInterval) -> Result? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executablePath)
        task.arguments = arguments
        let outPipe = Pipe(); let errPipe = Pipe()
        task.standardOutput = outPipe; task.standardError = errPipe

        let sem = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in sem.signal() }
        do { try task.run() } catch { return nil }

        var timedOut = false
        if sem.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            timedOut = true; task.terminate()
            if sem.wait(timeout: .now() + 1) == .timedOut, task.isRunning {
                kill(task.processIdentifier, SIGKILL); _ = sem.wait(timeout: .now() + 1)
            }
        }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Result(terminationStatus: task.terminationStatus,
                      stdout: out, stderr: err, timedOut: timedOut)
    }
}
