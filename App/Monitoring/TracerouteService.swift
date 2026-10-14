import Foundation
import HarborKit

/// One-shot route trace to the session's host: spawns the local
/// `/usr/sbin/traceroute -n` and streams hop lines into a live table
/// (FinalShell's 路由追踪 tab). Unlike PingService this does not restart —
/// a trace is a deliberate user action; 重新追踪 runs it again.
@MainActor
final class TracerouteService: ObservableObject {
    enum Status: Equatable {
        case idle
        case running
        case finished
        /// Binary missing, launch failure, or the process died before any hop.
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    /// Hops in order; grows as traceroute streams. Replaced (not appended) per
    /// line so a late multi-address line updates its hop in place.
    @Published private(set) var hops: [TracerouteHop] = []

    let hostname: String

    // nonisolated(unsafe) so deinit can access these without dispatching to the
    // main actor — same rationale as PingService (SwiftUI releases us on the
    // main thread, so direct deinit access is safe).
    private nonisolated(unsafe) var process: Process?
    private var generation = 0
    private var lineBuffer = ""
    /// First stderr line, kept for the failure message (e.g. "unknown host").
    private var stderrLine = ""

    /// macOS ships traceroute in /usr/sbin — probe instead of hardcoding.
    private static let tracerouteCandidates = ["/usr/sbin/traceroute", "/sbin/traceroute", "/usr/bin/traceroute"]
    /// `-n` numeric (no DNS stalls), one probe per hop, 2s per-hop wait,
    /// 30 hops max — a fully blackholed path still finishes within a minute.
    private static let arguments = ["-n", "-q", "1", "-w", "2", "-m", "30"]

    init(hostname: String) {
        self.hostname = hostname.trimmingCharacters(in: .whitespaces)
    }

    deinit {
        assert(Thread.isMainThread, "TracerouteService must be deallocated on the main thread")
        process?.terminate()
    }

    /// Starts a fresh trace. Any in-flight trace is cancelled first.
    func start() {
        guard !hostname.isEmpty, !hostname.hasPrefix("-"),
              !hostname.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else { return }
        terminateProcess()
        generation += 1
        hops = []
        lineBuffer = ""
        stderrLine = ""
        guard let executablePath = Self.tracerouteCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            status = .failed(L("traceroute 不可用：未找到可执行文件"))
            return
        }
        status = .running
        launch(executablePath: executablePath)
    }

    /// Stops an in-flight trace, keeping the hops gathered so far.
    func stop() {
        guard process != nil else { return }
        generation += 1
        terminateProcess()
        if status == .running { status = hops.isEmpty ? .idle : .finished }
    }

    // MARK: - Process lifecycle

    private func terminateProcess() {
        if let process, process.isRunning {
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            process.terminate()
        }
        process = nil
    }

    private func launch(executablePath: String) {
        let launchGeneration = generation

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = Self.arguments + [hostname]
        proc.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.consume(text, generation: launchGeneration)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.consumeStderr(text, generation: launchGeneration)
            }
        }
        proc.terminationHandler = { [weak self] proc in
            let exitCode = proc.terminationStatus
            Task { @MainActor [weak self] in
                self?.processExited(exitCode: exitCode, generation: launchGeneration)
            }
        }

        // Process.run() is a synchronous fork+exec — keep it off the main actor.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                try proc.run()
            } catch {
                Task { @MainActor [weak self] in
                    self?.launchFailed(error, generation: launchGeneration)
                }
                return
            }
            Task { @MainActor [weak self] in
                guard let self, launchGeneration == self.generation else {
                    proc.terminate()
                    return
                }
                // Died before registration (unknown host resolves fast): the
                // termination handler already ran; don't resurrect it.
                guard proc.isRunning else { return }
                self.process = proc
            }
        }
    }

    private func processExited(exitCode: Int32, generation: Int) {
        guard generation == self.generation else { return }
        terminateProcess()
        guard status == .running else { return }
        if !hops.isEmpty {
            status = .finished
        } else if !stderrLine.isEmpty {
            status = .failed(L("路由追踪失败：%@", stderrLine))
        } else {
            status = .failed(L("路由追踪失败（退出码 %lld）", Int(exitCode)))
        }
    }

    private func launchFailed(_ error: Error, generation: Int) {
        guard generation == self.generation else { return }
        status = .failed(L("无法启动 traceroute：%@", error.localizedDescription))
    }

    // MARK: - Output parsing

    private func consume(_ text: String, generation: Int) {
        guard generation == self.generation else { return }
        lineBuffer += text
        while let newline = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<newline])
            lineBuffer = String(lineBuffer[lineBuffer.index(after: newline)...])
            guard let hop = TracerouteParser.parseLine(line) else { continue }
            var next = hops
            if let existing = next.firstIndex(where: { $0.number == hop.number }) {
                next[existing] = hop
            } else {
                next.append(hop)
            }
            if next != hops { hops = next }
        }
    }

    private func consumeStderr(_ text: String, generation: Int) {
        guard generation == self.generation, stderrLine.isEmpty else { return }
        let line = text.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !line.isEmpty { stderrLine = line }
    }
}
