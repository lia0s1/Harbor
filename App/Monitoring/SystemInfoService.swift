import Foundation
import HarborKit

/// One-shot detailed system report for a session (FinalShell's 系统信息 button).
/// Unlike `MonitorService` this does NOT poll: it runs a single richer probe
/// over the session's own ControlMaster socket (BatchMode — never prompts) on
/// demand and publishes the parsed `SystemInfo`. Linux-first; a non-Linux host
/// reports `.unsupported` so the view shows a graceful notice.
///
/// Stale-while-revalidate: the last good probe is persisted per host
/// (`SystemInfoCacheStore`), so opening the sheet renders the previous
/// snapshot instantly — marked with its age — while a fresh probe runs in
/// the background and replaces it in place. On a high-RTT host this takes
/// the perceived load time from seconds to zero.
@MainActor
final class SystemInfoService: ObservableObject {
    enum State: Equatable {
        case idle
        /// First-ever probe with nothing to show yet (no disk snapshot).
        case loading
        /// Disk snapshot on screen; a background refresh may be in flight
        /// (`isRefreshing`). Fields that drift (uptime, memory, disk) are
        /// from the snapshot moment — the view marks them as such.
        case cached(SystemInfo, fetchedAt: Date)
        /// This session's probe succeeded; `fetchedAt` is when it landed.
        case loaded(SystemInfo, fetchedAt: Date)
        /// Remote `uname -s` is not Linux; the detailed report is Linux-first.
        case unsupported(os: String)
        /// Socket dead / probe failed / timed out AND no snapshot to show;
        /// the view offers a retry.
        case failed(reason: String)

        /// True while the on-screen report is a disk snapshot (drifting
        /// fields are from the snapshot moment). Lets the view merge the
        /// cached/loaded branches into ONE view-identity branch, so a
        /// background refresh landing does not reset the user's scroll.
        var isSnapshot: Bool {
            if case .cached = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .idle
    /// A probe is running in the background while cached/loaded content stays
    /// on screen. Drives the view's subtle "正在刷新…" affordance; false while
    /// the first-ever `.loading` probe runs (that state already shows a
    /// full-pane spinner).
    @Published private(set) var isRefreshing = false

    private let exec: RemoteExec
    /// Shared connect-time socket gate (one `ssh -O check` loop for all of this
    /// session's services, instead of each polling its own).
    private let readiness: SocketReadiness
    /// Cache identity: `user@host:port` (per-user — mounts/addresses differ).
    private let hostID: String
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
        self.hostID = SystemInfoCacheStore.hostID(destination: destination, port: port)
    }

    /// Runs the probe once. The previous probe (if any) is cancelled, so a fast
    /// 刷新 tap never races a stale result onto the view. When the screen
    /// already shows a snapshot/result, that content is PRESERVED while the
    /// new probe runs (and even if it fails) — a refresh must never blank a
    /// readable report. Safe to call from the button: the actual ssh runs
    /// off-main inside the task; the result lands back on MainActor.
    func fetch() {
        guard !exec.destination.isEmpty else {
            state = .failed(reason: L("无法在服务器上执行命令。"))
            return
        }
        fetchTask?.cancel()
        let preserved: State?
        switch state {
        case .cached, .loaded:
            preserved = state
        case .idle, .loading, .unsupported, .failed:
            preserved = nil
            state = .loading
        }
        isRefreshing = true
        let exec = self.exec
        let readiness = self.readiness
        let timing = SysInfoTiming(label: exec.destination)
        fetchTask = Task { [weak self] in
            // Share the connect-time `ssh -O check` poll with the monitor/file
            // services (prefetch happens right as the session connects, when the
            // master may not be up yet) instead of running a third poll loop.
            let alive = await readiness.waitUntilReady(
                deadline: Date().addingTimeInterval(Self.socketWaitDeadline))
            timing?.mark("socket-gate")
            guard !Task.isCancelled else { return }
            guard alive else {
                self?.ingestFailure(
                    L("无法复用 SSH 连接（ControlMaster 套接字不可用）。"),
                    preserved: preserved, timing: timing, outcome: "gate-dead")
                return
            }
            let result = await exec.run(SystemInfoParser.remoteScript, timeout: Self.timeout)
            timing?.mark("ssh-spawn+mux+remote")
            guard !Task.isCancelled else { return }
            self?.ingest(result, preserved: preserved, timing: timing)
        }
    }

    /// Fetches only if nothing usable is on screen yet — used to PREFETCH the
    /// report in the background the moment a session connects, so opening
    /// 系统信息 is instant (FinalShell-style). The disk snapshot (when present)
    /// renders first and the probe refreshes it in place; with no snapshot
    /// this is a plain first fetch.
    ///
    /// A `.failed` state also re-enters: a failed PREFETCH (socket gate
    /// outlived its deadline right after connect) must not hide a usable
    /// disk snapshot behind an error page, and opening the sheet IS the
    /// user's retry intent anyway.
    func fetchIfNeeded() {
        switch state {
        case .idle, .failed:
            break
        case .loading, .cached, .loaded, .unsupported:
            return
        }
        let started = CFAbsoluteTimeGetCurrent()
        if let snapshot = SystemInfoCacheStore.load(hostID: hostID) {
            state = .cached(snapshot.info, fetchedAt: snapshot.fetchedAt)
            SysInfoTiming.cacheHit(
                label: exec.destination,
                age: Date().timeIntervalSince(snapshot.fetchedAt),
                load: CFAbsoluteTimeGetCurrent() - started)
        } else {
            SysInfoTiming.cacheMiss(label: exec.destination)
        }
        fetch()
    }

    /// Drops any in-flight probe and the in-memory report. Session teardown
    /// calls this so a closed tab cannot keep the parsed dump in RAM. The
    /// DISK snapshot deliberately survives — it is what makes the next
    /// session's first open instant.
    func stop() {
        fetchTask?.cancel()
        fetchTask = nil
        isRefreshing = false
        state = .idle
    }

    /// Alias for `stop()` — SessionManager already calls `cancel()` on detach.
    func cancel() {
        stop()
    }

    private func ingest(_ result: AuxProcess.Output, preserved: State?, timing: SysInfoTiming?) {
        guard !result.timedOut else {
            ingestFailure(L("操作超时"), preserved: preserved, timing: timing, outcome: "timeout")
            return
        }
        guard result.exitCode == 0 else {
            ingestFailure(
                Self.failureText(result),
                preserved: preserved, timing: timing, outcome: "exit=\(result.exitCode)")
            return
        }
        let info = SystemInfoParser.parse(result.stdoutText)
        timing?.mark("parse")
        isRefreshing = false
        guard info.isLinux else {
            // Genuine state change (host no longer Linux?) — surface it rather
            // than a stale Linux snapshot. The disk cache keeps the last good
            // Linux report for next time.
            state = .unsupported(os: info.os.isEmpty ? L("未知") : info.os)
            timing?.finish("unsupported")
            return
        }
        let now = Date()
        state = .loaded(info, fetchedAt: now)
        SystemInfoCacheStore.save(CachedSystemInfo(hostKey: hostID, fetchedAt: now, info: info))
        timing?.finish("ok")
    }

    /// A failed refresh keeps whatever content was already on screen (the
    /// snapshot stays, silently — its age label is the honest signal); only a
    /// first-ever failure lands on the retry page.
    private func ingestFailure(
        _ reason: String, preserved: State?, timing: SysInfoTiming?, outcome: String
    ) {
        isRefreshing = false
        state = preserved ?? .failed(reason: reason)
        timing?.finish(preserved == nil ? outcome : "\(outcome) (kept snapshot)")
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
