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
        var currentMs: Double?
        var averageMs: Double?
    }
    @Published private(set) var pingFrame = PingFrame()
    /// Convenience accessors — call sites that read these stay unchanged.
    var latencySeries: [Double] { pingFrame.latencySeries }
    var currentMs: Double? { pingFrame.currentMs }
    var averageMs: Double? { pingFrame.averageMs }

    @Published private(set) var isRunning = false

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

    private static let executablePath = "/usr/bin/ping"
    private static let maxSamples = 90
    private static let initialBackoff: TimeInterval = 2
    private static let maxBackoff: TimeInterval = 30

    init(hostname: String) {
        self.hostname = hostname.trimmingCharacters(in: .whitespaces)
    }

    deinit {
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
        launch()
    }

    func stop() {
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
    }

    // MARK: - Process lifecycle

    private func launch() {
        guard active, process == nil else { return }
        generation += 1
        let launchGeneration = generation

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.executablePath)
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

        do {
            try proc.run()
            process = proc
            isRunning = true
        } catch {
            scheduleRestart()
        }
    }

    private func processExited(generation: Int) {
        guard generation == self.generation else { return }
        detachPipe()
        process = nil
        isRunning = false
        lineBuffer = ""
        guard active else { return }
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
        // A successful reply proves the route works: reset the backoff.
        backoffSeconds = Self.initialBackoff
        var next = pingFrame
        next.currentMs = ms
        next.latencySeries.append(ms)
        if next.latencySeries.count > Self.maxSamples {
            next.latencySeries.removeFirst(next.latencySeries.count - Self.maxSamples)
        }
        next.averageMs = next.latencySeries.reduce(0, +) / Double(next.latencySeries.count)
        if next != pingFrame { pingFrame = next }
    }
}
