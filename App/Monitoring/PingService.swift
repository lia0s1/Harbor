import Foundation
import HarborKit

/// Latency probe for one session: a long-running local `/sbin/ping <host>`
/// whose reply lines feed a rolling series (FinalShell's ping sparkline).
/// Restarts with backoff if ping exits (DNS failure, network change); killed
/// when the session closes.
@MainActor
final class PingService: ObservableObject {
    /// All ping-derived values batched into one published struct so a single
    /// reply fires objectWillChange exactly once instead of three times.
    struct PingFrame: Equatable {
        var latencySeries: [Double] = []
        var latencySum: Double = 0
        var currentMs: Double?
        var averageMs: Double?
    }
    @Published private(set) var pingFrame = PingFrame()
    /// Convenience accessors — call sites that read these stay unchanged.
    var latencySeries: [Double] { pingFrame.latencySeries }
    var currentMs: Double? { pingFrame.currentMs }
    var averageMs: Double? { pingFrame.averageMs }

    @Published private(set) var isRunning = false
    /// Last fatal ping problem (binary missing / could not launch / repeated
    /// dead attempts), surfaced by the latency card. Cleared on the first
    /// successful reply and by stop().
    @Published private(set) var lastError: String?

    private let hostname: String
    // nonisolated(unsafe) so deinit can access these without dispatching to
    // the main actor — accessing from deinit after a retain-to-0 via an async
    // Task capture causes swift_deallocClassInstance.cold.1 / SIGABRT.
    // In practice PingService is always released on the main thread (SwiftUI
    // manages its lifetime), so direct deinit access is safe.
    private nonisolated(unsafe) var process: Process?
    private nonisolated(unsafe) var restartTask: Task<Void, Never>?
    private var backoffSeconds: TimeInterval = PingService.initialBackoff
    private var active = false
    private var lineBuffer = ""
    /// Increases on every (re)launch so stale pipe callbacks from a previous
    /// ping process can be ignored.
    private var generation = 0
    /// Attempts that ended without a single reply; drives `lastError`.
    private var consecutiveFailures = 0

    /// macOS ships ping in /sbin (or /usr/sbin), not /usr/bin — probe instead
    /// of hardcoding, else fork/exec throws ENOENT forever.
    private static let pingCandidates = ["/sbin/ping", "/usr/sbin/ping", "/usr/bin/ping"]
    private static let ping6Candidates = ["/sbin/ping6", "/usr/sbin/ping6"]
    private static let maxConsecutiveFailures = 3
    private static let maxSamples = 90
    private static let initialBackoff: TimeInterval = 2
    private static let maxBackoff: TimeInterval = 30

    private static func resolveExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    init(hostname: String) {
        self.hostname = hostname.trimmingCharacters(in: .whitespaces)
    }

    deinit {
        assert(Thread.isMainThread, "PingService must be deallocated on the main thread")
        restartTask?.cancel()
        process?.terminate()
    }

    func start() {
        guard !active else { return }
        // Hostnames were already validated by SSHCommandBuilder at session
        // creation; this is defense in depth for the separate ping argv.
        guard !hostname.isEmpty, !hostname.hasPrefix("-"),
              !hostname.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else { return }
        active = true
        backoffSeconds = Self.initialBackoff
        consecutiveFailures = 0
        lastError = nil
        launch()
    }

    func pause() {
        guard active || process != nil else { return }
        active = false
        restartTask?.cancel()
        restartTask = nil
        generation += 1
        detachPipe()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        isRunning = false
        lineBuffer = ""
    }

    func stop() {
        pause()
        pingFrame = PingFrame()
        lastError = nil
    }

    // MARK: - Process lifecycle

    private func launch() {
        guard active, process == nil else { return }
        // An IPv6 literal needs ping6; /sbin/ping is IPv4-only.
        let wantsPing6 = hostname.contains(":")
        guard let executablePath = Self.resolveExecutable(
            wantsPing6 ? Self.ping6Candidates : Self.pingCandidates)
        else {
            lastError = L(wantsPing6 ? "ping6 不可用：未找到可执行文件"
                                     : "ping 不可用：未找到可执行文件")
            scheduleRestart()
            return
        }
        generation += 1
        let launchGeneration = generation

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = [hostname]
        proc.standardInput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        proc.standardOutput = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.consume(text, generation: launchGeneration)
            }
        }
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.processExited(generation: launchGeneration)
            }
        }

        // Process.run() is a synchronous fork+exec — run off the main actor
        // so a heavily-loaded kernel can't stall the UI.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                try proc.run()
            } catch {
                Task { @MainActor [weak self] in
                    self?.launchFailed(error)
                }
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only install if still active AND this is still the current
                // generation (a stop() may have landed while we were in the
                // background queue).
                guard self.active, launchGeneration == self.generation else {
                    proc.terminate()
                    return
                }
                // If the child died before we could register it (e.g. DNS
                // failure that resolved faster than this main-actor hop), the
                // termination handler already scheduled the restart — don't
                // resurrect isRunning=true over a dead process.
                guard proc.isRunning else { return }
                self.process = proc
                self.isRunning = true
            }
        }
    }

    private func processExited(generation: Int) {
        guard generation == self.generation else { return }
        detachPipe()
        process = nil
        isRunning = false
        lineBuffer = ""
        guard active else { return }
        noteAttemptWithoutReply()
    }

    /// One attempt ended without a single reply (ping exited — DNS failure,
    /// unreachable host). After `maxConsecutiveFailures` in a row the latency
    /// card shows it instead of the eternal 等待 ping 响应.
    private func noteAttemptWithoutReply() {
        guard active else { return }
        consecutiveFailures += 1
        if consecutiveFailures >= Self.maxConsecutiveFailures, lastError == nil {
            lastError = L("ping 无响应，正在重试")
        }
        scheduleRestart()
    }

    /// `proc.run()` threw — a launch failure is deterministic, so surface it
    /// immediately (the restart loop keeps trying in the background).
    private func launchFailed(_ error: Error) {
        guard active else { return }
        lastError = L("无法启动 ping：%@", error.localizedDescription)
        consecutiveFailures += 1
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard active, restartTask == nil else { return }
        let delay = backoffSeconds
        backoffSeconds = min(backoffSeconds * 2, Self.maxBackoff)
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.restartTask = nil
            self.launch()
        }
    }

    private func detachPipe() {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    }

    // MARK: - Output parsing

    private func consume(_ text: String, generation: Int) {
        guard generation == self.generation else { return }
        lineBuffer += text
        while let newline = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<newline])
            lineBuffer = String(lineBuffer[lineBuffer.index(after: newline)...])
            if let ms = MonitorParsers.pingLatency(line: line) {
                record(ms)
            }
        }
    }

    private func record(_ ms: Double) {
        // A successful reply proves the route works: reset the backoff and
        // any surfaced failure.
        backoffSeconds = Self.initialBackoff
        consecutiveFailures = 0
        if lastError != nil { lastError = nil }
        var next = pingFrame
        next.currentMs = ms
        next.latencySum += ms
        next.latencySeries.append(ms)
        if next.latencySeries.count > Self.maxSamples {
            let overflow = next.latencySeries.count - Self.maxSamples
            next.latencySum -= next.latencySeries.prefix(overflow).reduce(0, +)
            next.latencySeries.removeFirst(overflow)
        }
        next.averageMs = next.latencySum / Double(next.latencySeries.count)
        if next != pingFrame { pingFrame = next }
    }
}
