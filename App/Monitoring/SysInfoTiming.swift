import Foundation
import os.log

/// Dev-only wall-clock instrumentation for the 系统信息 probe chain
/// (socket-gate wait → ssh spawn + mux channel + remote exec → parse).
/// OFF by default; set `HARBOR_SYSINFO_TIMING=1` in the run environment to
/// turn it on. Emits one summary line per probe (plus cache-hit lines) to
/// both os_log (subsystem dev.zero.Harbor, category SysInfoTiming) and
/// stdout, so numbers are readable from Console.app, `log stream`, or the
/// Xcode run console:
///
///   log stream --predicate 'subsystem == "dev.zero.Harbor"' --info
///
/// All `mark`/`finish` calls go through an optional (`timing?.mark(…)`), so
/// the disabled path costs one nil check per segment — nothing is allocated
/// or formatted unless the env var is set.
final class SysInfoTiming: @unchecked Sendable {
    private static let log = OSLog(subsystem: "dev.zero.Harbor", category: "SysInfoTiming")

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["HARBOR_SYSINFO_TIMING"] != nil
    }

    private let label: String
    private let t0: CFAbsoluteTime
    private var last: CFAbsoluteTime
    private let lock = NSLock()
    private var segments: [String] = []

    /// Returns nil when timing is disabled, so call sites read `timing?.mark(…)`.
    init?(label: String) {
        guard SysInfoTiming.enabled else { return nil }
        self.label = label
        let now = CFAbsoluteTimeGetCurrent()
        self.t0 = now
        self.last = now
    }

    /// Records a segment boundary: `name=<ms since previous mark>`.
    func mark(_ name: String) {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        segments.append("\(name)=\(Self.ms(now - last))ms")
        last = now
        lock.unlock()
    }

    /// Emits the one-line summary for the whole probe.
    func finish(_ outcome: String) {
        lock.lock()
        let total = Self.ms(CFAbsoluteTimeGetCurrent() - t0)
        let detail = segments.joined(separator: " ")
        lock.unlock()
        Self.emit("sysinfo [\(label)] \(outcome) total=\(total)ms | \(detail)")
    }

    /// Emits a cache-hit line (`age` = snapshot age, `load` = disk read time).
    static func cacheHit(label: String, age: TimeInterval, load: TimeInterval) {
        guard enabled else { return }
        emit("sysinfo [\(label)] cache-hit age=\(ms(age))ms load=\(ms(load))ms")
    }

    static func cacheMiss(label: String) {
        guard enabled else { return }
        emit("sysinfo [\(label)] cache-miss")
    }

    /// Free-form one-liner on the same channel (e.g. cache-write failures).
    static func note(_ message: String) {
        guard enabled else { return }
        emit(message)
    }

    private static func ms(_ interval: CFAbsoluteTime) -> Int {
        Int((interval * 1000).rounded())
    }

    private static func emit(_ message: String) {
        os_log(.default, log: log, "%{public}@", message)
        print(message)
    }
}
