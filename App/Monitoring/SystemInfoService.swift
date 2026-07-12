import Foundation
import HarborKit

/// One-shot detailed system report for a session (FinalShell's 系统信息 button).
/// Unlike `MonitorService` this does NOT poll: it runs a single richer probe
/// over the session's own ControlMaster socket (BatchMode — never prompts) on
/// demand and publishes the parsed `SystemInfo`. Linux-first; a non-Linux host
/// reports `.unsupported` so the view shows a graceful notice.
@MainActor
final class SystemInfoService: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded(SystemInfo)
        /// Remote `uname -s` is not Linux; the detailed report is Linux-first.
        case unsupported(os: String)
        /// Socket dead / probe failed / timed out; the view offers a retry.
        case failed(reason: String)
    }

    @Published private(set) var state: State = .idle

    private let exec: RemoteExec
    /// Shared connect-time socket gate (one `ssh -O check` loop for all of this
    /// session's services, instead of each polling its own).
    private let readiness: SocketReadiness
    private var fetchTask: Task<Void, Never>?

    private static let timeout: TimeInterval = 8
    private static let socketWaitDeadline: TimeInterval = 25

    init(destination: String, controlSocketPath: String, port: Int, readiness: SocketReadiness) {
        self.exec = RemoteExec(
            destination: destination,
            controlSocketPath: controlSocketPath,
            port: port
        )
        self.readiness = readiness
    }

    /// Runs the probe once. The previous probe (if any) is cancelled, so a fast
    /// 刷新 tap never races a stale result onto the view. Safe to call from the
    /// button: the actual ssh runs off-main inside the task; the result lands
    /// back on MainActor.
    func fetch() {
        guard !exec.destination.isEmpty else {
            state = .failed(reason: L("无法在服务器上执行命令。"))
            return
        }
        fetchTask?.cancel()
        state = .loading
        let exec = self.exec
        let readiness = self.readiness
        fetchTask = Task { [weak self] in
            // Share the connect-time `ssh -O check` poll with the monitor/file
            // services (prefetch happens right as the session connects, when the
            // master may not be up yet) instead of running a third poll loop.
            let alive = await readiness.waitUntilReady(
                deadline: Date().addingTimeInterval(Self.socketWaitDeadline))
            guard !Task.isCancelled else { return }
            guard alive else {
                self?.state = .failed(reason: L("无法复用 SSH 连接（ControlMaster 套接字不可用）。"))
                return
            }
            let result = await exec.run(SystemInfoParser.remoteScript, timeout: Self.timeout)
            guard !Task.isCancelled else { return }
            self?.ingest(result)
        }
    }

    /// Fetches only if nothing has been loaded yet — used to PREFETCH the report
    /// in the background the moment a session connects, so opening 系统信息 is
    /// instant (FinalShell-style) instead of a few-second on-click probe.
    func fetchIfNeeded() {
        if case .idle = state { fetch() }
    }

    /// Drops any in-flight probe and resets to idle (called when the view that
    /// owns this service goes away, e.g. the sheet is dismissed).
    func cancel() {
        fetchTask?.cancel()
        fetchTask = nil
    }

    private func ingest(_ result: AuxProcess.Output) {
        guard !result.timedOut else {
            state = .failed(reason: L("操作超时"))
            return
        }
        guard result.exitCode == 0 else {
            state = .failed(reason: Self.failureText(result))
            return
        }
        let info = SystemInfoParser.parse(result.stdoutText)
        guard info.isLinux else {
            state = .unsupported(os: info.os.isEmpty ? L("未知") : info.os)
            return
        }
        state = .loaded(info)
    }

    /// Most informative stderr line, falling back to the exit code.
    private static func failureText(_ output: AuxProcess.Output) -> String {
        let stderr = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let line = stderr.split(separator: "\n").last(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) {
            return String(line)
        }
        return L("命令执行失败（退出码 %lld）", Int(output.exitCode))
    }
}
