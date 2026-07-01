import Foundation
import Darwin

/// Monitors this app process's CPU usage every second (via getrusage).
/// If the CPU usage delta exceeds `thresholdPct` percentage points per second
/// for `consecutiveLimit` consecutive samples, calls `onExceeded` and should
/// be stopped immediately.
///
/// Usage:
///   watchdog.onExceeded = { pct in /* stop VM */ }
///   watchdog.start(afterDelay: 5.0)   // grace period before sampling starts
///   watchdog.stop()
final class CPUWatchdog {

    // MARK: - Config

    /// Delta threshold for this process: if CPU% rises more than this per second, trigger.
    let thresholdPct: Double
    /// How many consecutive over-threshold samples before triggering.
    let consecutiveLimit: Int

    // MARK: - State

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.ext4mounter.cpuwatch", qos: .utility)
    private var lastCPU: Double  = -1
    private var lastWall: Double = -1
    private var overCount: Int   = 0
    private var triggered        = false
    private var sampleCount      = 0

    // MARK: - Callback

    /// Called on the watchdog's background queue when threshold is exceeded.
    var onExceeded: ((Double) -> Void)?

    // MARK: - Init

    init(thresholdPct: Double = 15.0, consecutiveLimit: Int = 3) {
        self.thresholdPct     = thresholdPct
        self.consecutiveLimit = consecutiveLimit
    }

    // MARK: - Start / Stop

    /// Start monitoring. `afterDelay` seconds of grace period before sampling.
    func start(afterDelay delay: TimeInterval = 5.0) {
        let src = DispatchSource.makeTimerSource(queue: queue)
        src.schedule(deadline: .now() + delay, repeating: 1.0, leeway: .milliseconds(200))
        src.setEventHandler { [weak self] in self?.tick() }
        src.resume()
        timer = src
        elog("[CPUWatchdog] started threshold=\(thresholdPct)%/s consecutive=\(consecutiveLimit) delay=\(delay)s")
    }

    func stop() {
        timer?.cancel(); timer = nil
        lastCPU = -1; lastWall = -1; overCount = 0; triggered = false; sampleCount = 0
        elog("[CPUWatchdog] stopped")
    }

    // MARK: - Sampling

    private func tick() {
        guard !triggered else { return }

        // Measure cumulative CPU time (user + system) for the app process.
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        let cpu  = Double(ru.ru_utime.tv_sec)  + Double(ru.ru_utime.tv_usec)  / 1_000_000
                 + Double(ru.ru_stime.tv_sec)  + Double(ru.ru_stime.tv_usec)  / 1_000_000
        let wall = Date().timeIntervalSinceReferenceDate

        defer { lastCPU = cpu; lastWall = wall }
        guard lastCPU >= 0 else { return }   // first sample: just record baseline

        let elapsed = wall - lastWall
        guard elapsed > 0.01 else { return }

        // CPU% per second (100% = one full core)
        let pct = (cpu - lastCPU) / elapsed * 100.0
        sampleCount += 1

        if pct > thresholdPct {
            overCount += 1
            elog(String(format: "[CPUWatchdog] ⚠️  over threshold: %.1f%%/s (%d/%d)",
                        pct, overCount, consecutiveLimit))
            if overCount >= consecutiveLimit {
                triggered = true
                elog(String(format: "[CPUWatchdog] 🛑 triggering stop (%.1f%%/s)", pct))
                onExceeded?(pct)
            }
        } else {
            if sampleCount == 1 || sampleCount % 30 == 0 {
                elog(String(format: "[CPUWatchdog] cpu=%.1f%%/s", pct))
            }
            overCount = 0   // reset consecutive counter on any normal sample
        }
    }
}
