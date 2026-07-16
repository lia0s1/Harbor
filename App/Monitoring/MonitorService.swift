import Foundation
import UserNotifications
import HarborKit

/// User-configurable monitoring limits. The values live in UserDefaults so
/// every session observes the same policy, while each MonitorService evaluates
/// it against its own remote snapshot.
enum MonitorAlertPreference {
    static let cpuThresholdKey = "monitorAlertCPUThreshold"
    static let memoryThresholdKey = "monitorAlertMemoryThreshold"
    static let diskThresholdKey = "monitorAlertDiskThreshold"
    static let loadThresholdKey = "monitorAlertLoadThreshold"
    static let systemNotificationsKey = "monitorAlertSystemNotifications"

    static let defaultCPUPercent = 90.0
    static let defaultMemoryPercent = 90.0
    static let defaultDiskPercent = 90.0
    static let defaultLoad = 4.0

    static func thresholds() -> (cpu: Double, memory: Double, disk: Double, load: Double) {
        let defaults = UserDefaults.standard
        return (
            percent(defaults.object(forKey: cpuThresholdKey) as? Double, fallback: defaultCPUPercent),
            percent(defaults.object(forKey: memoryThresholdKey) as? Double, fallback: defaultMemoryPercent),
            percent(defaults.object(forKey: diskThresholdKey) as? Double, fallback: defaultDiskPercent),
            min(max(defaults.object(forKey: loadThresholdKey) as? Double ?? defaultLoad, 0.5), 1_000)
        )
    }

    private static func percent(_ value: Double?, fallback: Double) -> Double {
        min(max(value ?? fallback, 50), 100)
    }
}

enum MonitorAlertKind: String, Identifiable {
    case cpu
    case memory
    case disk
    case load

    var id: String { rawValue }
}

struct MonitorAlert: Identifiable, Equatable {
    let kind: MonitorAlertKind
    let title: String
    let detail: String

    var id: String { kind.id }
}

/// Agentless monitoring for one terminal session, FinalShell-style: every
/// 2 seconds a single remote script reads /proc over the session's own
/// ControlMaster socket (no re-auth, no extra TCP connection, never a
/// prompt). Pure parsing lives in HarborKit (`MonitorParsers`); this class
/// owns lifecycle, scheduling and the derived series buffers.
@MainActor
final class MonitorService: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case active
        /// Remote `uname -s` is not Linux; monitoring is Linux-first.
        case unsupported(os: String)
        /// Sampling failed repeatedly; retried every `retryInterval`.
        case unavailable(reason: String)
    }

    @Published private(set) var status: Status = .idle
    /// Current threshold breaches, rendered in the monitor rail even when
    /// system notifications are disabled or the user declined permission.
    @Published private(set) var activeAlerts: [MonitorAlert] = []

    /// All per-tick sample data, published as ONE value so a single 2s tick
    /// (which derives a snapshot + 5 series) fires `objectWillChange` exactly
    /// once instead of 5–6 times. Each separate `@Published` would otherwise
    /// re-render the monitor panel (and its two Swift Charts) several times per
    /// tick — a measurable jank source. `ingest` folds a snapshot into a local
    /// copy and assigns it back to `frame` once (guarded by Equatable).
    struct Frame: Equatable {
        var snapshot: SystemSnapshot?
        /// Derived series, capped at `maxSamples` (~3 minutes at 2s ticks).
        var cpuSeries: [Double] = []
        var memSeries: [Double] = []
        var swapSeries: [Double] = []
        /// Per-interface throughput series in bytes/second.
        var rxSpeedSeries: [String: [Double]] = [:]
        var txSpeedSeries: [String: [Double]] = [:]
        /// Latest per-core busy %, in core order (for the CPU detail panel).
        var cpuCorePercents: [Double] = []
        /// Latest CPU component split (user/system/iowait/…), for the detail.
        var cpuBreakdown: MonitorParsers.CPUBreakdown?
        /// Current read/write speed for the busiest whole-disk device (bytes/sec).
        /// Both are 0 until the second sample (first delta) arrives.
        var diskReadBytesPerSec: Double = 0
        var diskWriteBytesPerSec: Double = 0
        /// Interface names for the 网络 picker (alphabetical, loopback last),
        /// derived once per tick so the view never sorts during a body pass.
        var interfaceNames: [String] = []
        /// Live non-loopback interfaces with a throughput sample, busiest-first.
        /// Cached per tick for the 活动网卡 card so it never re-sorts (and re-sums
        /// rx+tx per comparison) on every SwiftUI body evaluation.
        var activeInterfaceNames: [String] = []
    }
    @Published private(set) var frame = Frame()

    // Convenience accessors so existing call sites stay readable.
    var snapshot: SystemSnapshot? { frame.snapshot }
    var cpuSeries: [Double] { frame.cpuSeries }
    var memSeries: [Double] { frame.memSeries }
    var swapSeries: [Double] { frame.swapSeries }
    var rxSpeedSeries: [String: [Double]] { frame.rxSpeedSeries }
    var txSpeedSeries: [String: [Double]] { frame.txSpeedSeries }
    var cpuCorePercents: [Double] { frame.cpuCorePercents }
    var cpuBreakdown: MonitorParsers.CPUBreakdown? { frame.cpuBreakdown }
    var diskReadBytesPerSec: Double { frame.diskReadBytesPerSec }
    var diskWriteBytesPerSec: Double { frame.diskWriteBytesPerSec }
    var interfaceNames: [String] { frame.interfaceNames }
    var activeInterfaceNames: [String] { frame.activeInterfaceNames }

    /// Interface the UI should chart. Auto-picked (busiest non-lo) until the
    /// user chooses one explicitly. Low frequency (user- or auto-selected once),
    /// so it stays a standalone `@Published`.
    @Published var selectedInterface: String?

    /// Last process-action error (kill/signal failed), surfaced as a transient
    /// banner by the process detail view and cleared on the next success or by
    /// the UI after it is shown. Low frequency, so a standalone `@Published`.
    @Published var lastActionError: String?

    private let exec: RemoteExec
    /// Shared connect-time socket gate (one `ssh -O check` loop for all of this
    /// session's services, instead of each polling its own).
    private let readiness: SocketReadiness

    private var loopTask: Task<Void, Never>?
    private var isTicking = false
    private var socketVerified = false
    /// True once monitoring has been `.active` at least once this run. After
    /// that, a failing socket check is a real disconnect (escalate to
    /// `.unavailable`), not the first-connect socket wait.
    private var everActive = false
    private var consecutiveFailures = 0
    private var previousTicks: CPUTicks?
    private var previousPerCore: [CPUTicks] = []
    private var previousNet: (date: Date, counters: [String: (rx: UInt64, tx: UInt64)])?
    private var previousDisk: (date: Date, counters: [String: (read: UInt64, write: UInt64)])?

    private static let maxSamples = 90
    private static let initialDelay: TimeInterval = 0.4
    private static let sampleInterval: TimeInterval = 2
    private static let retryInterval: TimeInterval = 15
    private static let failureThreshold = 3
    private static let commandTimeout: TimeInterval = 5
    private static let socketWaitDeadline: TimeInterval = 600
    /// A sustained condition is re-notified at most once in this interval.
    /// This is shared by sessions so two tabs to the same target do not emit
    /// duplicate alerts at the two-second sampling cadence.
    private static let notificationCooldown: TimeInterval = 10 * 60
    private static var notificationDates: [String: Date] = [:]

    init(destination: String, controlSocketPath: String, port: Int, readiness: SocketReadiness) {
        self.exec = RemoteExec(
            destination: destination,
            controlSocketPath: controlSocketPath,
            port: port
        )
        self.readiness = readiness
    }

    /// Begins polling: waits 1s for ssh to create the mux socket, verifies it
    /// with `-O check`, then samples every 2s. Ticks are strictly serial (the
    /// loop awaits each sample), so a slow tick delays — never overlaps — the
    /// next one. Call again only after `stop()`.
    func start() {
        guard loopTask == nil, !exec.destination.isEmpty else { return }
        status = .checking
        consecutiveFailures = 0
        socketVerified = false
        everActive = false
        loopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.initialDelay * 1_000_000_000))
            // Share the connect-time `ssh -O check` poll with the file/info
            // services instead of racing our own. On success the first tick goes
            // straight to sampling; if it times out, tick() falls back to its own
            // check (the mid-session re-verify path below stays on our exec).
            if let readiness = self?.readiness {
                let ready = await readiness.waitUntilReady(
                    deadline: Date().addingTimeInterval(Self.socketWaitDeadline))
                if Task.isCancelled { return }
                if ready {
                    self?.socketVerified = true
                    self?.consecutiveFailures = 0
                }
            }
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.tick()
                guard delay > 0 else { return } // unsupported OS: park until restart
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Stops polling. The in-flight auxiliary ssh (if any) is terminated via
    /// task cancellation; the watchdog reaps stragglers within seconds.
    func stop() {
        loopTask?.cancel()
        loopTask = nil
        status = .idle
        socketVerified = false
        everActive = false
        consecutiveFailures = 0
        // Forget delta-computation state so the first tick after resuming
        // doesn't derive a bogus CPU/network spike from a stale baseline.
        // Frame data is intentionally kept: the panel shows the last-known
        // stats instantly on tab switch instead of a spinner.
        previousTicks = nil
        previousPerCore = []
        previousNet = nil
        previousDisk = nil
        activeAlerts = []
    }

    // MARK: - Sampling

    /// One serial tick. Returns the delay until the next tick; <= 0 stops the loop.
    private func tick() async -> TimeInterval {
        guard !isTicking else { return Self.sampleInterval }
        isTicking = true
        defer { isTicking = false }
        if !socketVerified {
            guard await exec.checkSocket(timeout: Self.commandTimeout) else {
                if Task.isCancelled { return 0 }
                // If monitoring was ALREADY active and the master later died
                // (network drop, server reboot, `ssh -O exit` elsewhere), this
                // is a genuine disconnect: escalate through registerFailure to
                // `.unavailable` + the slow retry. Previously this branch always
                // reverted to `.checking` and early-returned, so a once-live but
                // now-dead socket spun on the spinner forever and never surfaced
                // the error.
                if everActive { return registerFailure(L("监控连接已断开")) }
                // First connect: the mux socket only appears AFTER auth succeeds
                // (for a password/2FA host, after the user finishes typing). Keep
                // the fast 2s poll and show .checking so stats appear within ~2s.
                if status != .checking { status = .checking }
                return Self.sampleInterval
            }
            // A stop()/tab-switch may have landed while we were suspended in the
            // await above. Cancellation does not interrupt an in-flight tick(),
            // so bail here rather than resurrecting state stop() just cleared.
            if Task.isCancelled { return 0 }
            socketVerified = true
            consecutiveFailures = 0
        }

        let result = await exec.run(MonitorParsers.remoteScript, timeout: Self.commandTimeout)
        if Task.isCancelled { return 0 }
        guard !result.timedOut, result.exitCode == 0 else {
            return registerFailure(L("监控命令执行失败"))
        }

        let snap = MonitorParsers.parseSnapshot(result.stdoutText)
        guard snap.isLinux else {
            status = .unsupported(os: snap.os.isEmpty ? L("未知") : snap.os)
            return 0
        }

        ingest(snap)
        consecutiveFailures = 0
        if status != .active { status = .active }
        everActive = true
        return Self.sampleInterval
    }

    private func registerFailure(_ reason: String) -> TimeInterval {
        consecutiveFailures += 1
        if consecutiveFailures >= Self.failureThreshold {
            status = .unavailable(reason: reason)
            socketVerified = false
            // Reset the shared gate so FileService / DockerService re-verify
            // the socket on their next waitUntilReady call, instead of
            // trusting a stale "ready" latch on a dead connection.
            readiness.reset()
            return Self.retryInterval
        }
        return Self.sampleInterval
    }

    // MARK: - Process actions

    /// Signals an allow-listed name maps to its `kill` argument. Only these two
    /// are ever sent, so the signal can never carry arbitrary shell text.
    enum KillSignal: String {
        case term = "TERM"
        case kill = "KILL"
    }

    /// Sends `kill -<signal> <pid>` to a remote process over the SAME
    /// multiplexed socket every probe uses. The pid is validated as a positive
    /// integer and the signal comes from a fixed allow-list, so the command is
    /// built from trusted numeric/literal tokens only (no shell injection).
    /// On success a tick is kicked off so the process list reflects the change;
    /// on failure `lastActionError` is set for the UI to surface.
    /// Returns true when the remote `kill` exited 0.
    @discardableResult
    func terminate(pid: Int32, signal: KillSignal) async -> Bool {
        guard pid > 0 else {
            lastActionError = L("无效的进程 ID")
            return false
        }
        // pid is a validated Int32; signal.rawValue is "TERM"/"KILL" — both
        // safe to interpolate into the single remote command string.
        let script = "kill -\(signal.rawValue) \(pid)"
        let result = await exec.run(script, timeout: Self.commandTimeout)
        if Task.isCancelled { return false }
        guard !result.timedOut, result.exitCode == 0 else {
            // Prefer the remote stderr (e.g. "No such process", "Operation not
            // permitted") when present; fall back to a generic message.
            let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            lastActionError = stderr.isEmpty ? L("结束进程失败") : stderr
            return false
        }
        lastActionError = nil
        // Refresh the process list immediately so the killed process disappears
        // rather than waiting up to 2s for the next scheduled tick. Run as a
        // direct sample (bypassing `isTicking`) so it never no-ops when the
        // loop's tick is concurrently suspended inside its own `exec.run`.
        let refreshResult = await exec.run(MonitorParsers.remoteScript, timeout: Self.commandTimeout)
        if !refreshResult.timedOut, refreshResult.exitCode == 0 {
            let snap = MonitorParsers.parseSnapshot(refreshResult.stdoutText)
            if snap.isLinux { ingest(snap) }
        }
        return true
    }

    /// Fetches rich detail for one process on demand (the 进程详情 inspector):
    /// parent, state, threads, priority, RSS/VSZ split, start time and the full
    /// command line — none of which the 2s top-list probe collects. Three
    /// `ps`/cmdline reads in one round-trip over the shared socket, each its own
    /// `@@HARBOR@@` section so the space-bearing lstart/args survive splitting.
    /// Returns nil when the process is gone or `ps` produced nothing usable.
    func fetchDetail(pid: Int32) async -> ProcessDetail? {
        guard pid > 0 else { return nil }
        let sep = MonitorParsers.sectionSeparator
        let p = Int(pid)
        let script = "LC_ALL=C ps -p \(p) -o pid=,ppid=,user=,stat=,nice=,pri=,pcpu=,pmem=,rss=,vsz=,nlwp=,etimes= | head -1"
            + "; echo \(sep); LC_ALL=C ps -p \(p) -o lstart= | head -1"
            + "; echo \(sep); LC_ALL=C ps -p \(p) -o args= | head -1"
        let result = await exec.run(script, timeout: Self.commandTimeout)
        guard !result.timedOut, result.exitCode == 0 else { return nil }
        return MonitorParsers.parseProcessDetail(result.stdoutText)
    }

    // MARK: - Listening ports

    /// On-demand `ss -tulnpH` over the shared socket — the "谁占了 8080" lookup.
    /// Kept off the 2s loop (it's a deliberate user action, not a constant
    /// probe). Process attribution needs root for *other* users' sockets; without
    /// it the ports still list, just without owner names. Returns nil only when
    /// the command itself failed (socket dead / `ss` absent) so the UI can tell
    /// "nothing listening" (empty) apart from "couldn't ask" (nil).
    func fetchListeningPorts() async -> [ListeningPort]? {
        let result = await exec.run(ListeningPortsParser.command, timeout: Self.commandTimeout)
        if Task.isCancelled { return nil }
        // `ss` exits 0 even with no rows; a non-zero exit means ss is missing or
        // the socket died. An empty stdout with exit 0 is a legitimate "nothing
        // listening" and parses to [].
        guard !result.timedOut, result.exitCode == 0 else { return nil }
        return ListeningPortsParser.parse(result.stdoutText)
    }

    // MARK: - Derived series

    /// Folds one snapshot into a working copy of the frame and republishes it
    /// in a single assignment, so the panel re-renders once per tick.
    private func ingest(_ snap: SystemSnapshot) {
        var next = frame
        next.snapshot = snap
        var cpuPercent: Double?

        if let ticks = snap.cpuTicks {
            if let previous = previousTicks {
                if let percent = MonitorParsers.cpuPercent(previous: previous, current: ticks) {
                    append(percent, to: &next.cpuSeries)
                    cpuPercent = percent
                }
                if let breakdown = MonitorParsers.cpuBreakdown(previous: previous, current: ticks) {
                    next.cpuBreakdown = breakdown
                }
            }
            // Only advance the baseline if this sample is actually newer.
            // A terminate() refresh can call ingest() while tick() is suspended
            // in exec.run(); when tick() resumes with the older snapshot, naively
            // overwriting previousTicks would regress it and inflate the next delta.
            if previousTicks.map({ ticks.total > $0.total }) ?? true {
                previousTicks = ticks
            }
        }

        // Per-core busy %, derived against the matching previous sample (core
        // count can change on hotplug/containers, so only zip when it matches).
        if !snap.perCoreTicks.isEmpty {
            if previousPerCore.count == snap.perCoreTicks.count {
                next.cpuCorePercents = zip(previousPerCore, snap.perCoreTicks).map {
                    MonitorParsers.cpuPercent(previous: $0, current: $1) ?? 0
                }
            }
            previousPerCore = snap.perCoreTicks
        }

        if snap.memTotalKB > 0 {
            append(snap.memUsedFraction * 100, to: &next.memSeries)
        }
        if snap.swapTotalKB > 0 {
            append(snap.swapUsedFraction * 100, to: &next.swapSeries)
        }

        ingestNetwork(snap.interfaces, into: &next)
        if !snap.diskIOCounters.isEmpty {
            ingestDisk(snap.diskIOCounters, into: &next)
        }

        // Precompute the two interface orderings the rail draws, so the SwiftUI
        // cards read a ready-made array instead of sorting on every body pass.
        next.interfaceNames = Self.sortedInterfaceNames(snap.interfaces)
        next.activeInterfaceNames = Self.busiestInterfaceNames(in: next)

        // Equatable guard: an idle host (flat series cap reached, same values)
        // can produce a frame identical to the last one — skip the publish.
        if next != frame { frame = next }
        updateAlerts(snapshot: snap, cpuPercent: cpuPercent ?? next.cpuSeries.last)
    }

    // MARK: - Threshold alerts

    /// Requests notification permission only from the explicit panel setting;
    /// sampling itself never raises a system permission prompt.
    func enableSystemNotifications() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let granted: Bool
        if settings.authorizationStatus == .authorized {
            granted = true
        } else if settings.authorizationStatus == .notDetermined {
            granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        } else {
            granted = false
        }
        UserDefaults.standard.set(granted, forKey: MonitorAlertPreference.systemNotificationsKey)
        return granted
    }

    private func updateAlerts(snapshot: SystemSnapshot, cpuPercent: Double?) {
        let limits = MonitorAlertPreference.thresholds()
        var alerts: [MonitorAlert] = []

        if let cpuPercent, cpuPercent >= limits.cpu {
            alerts.append(MonitorAlert(
                kind: .cpu,
                title: L("CPU 使用率过高"),
                detail: L("当前 %@，阈值 %@", MonitorFormat.percent(cpuPercent), MonitorFormat.percent(limits.cpu))
            ))
        }
        let memoryPercent = snapshot.memUsedFraction * 100
        if snapshot.memTotalKB > 0, memoryPercent >= limits.memory {
            alerts.append(MonitorAlert(
                kind: .memory,
                title: L("内存使用率过高"),
                detail: L("当前 %@，阈值 %@", MonitorFormat.percent(memoryPercent), MonitorFormat.percent(limits.memory))
            ))
        }
        let fullDisks = snapshot.disks.filter { $0.usedFraction * 100 >= limits.disk }
        if !fullDisks.isEmpty {
            let mounts = fullDisks.map { disk in
                "\(disk.mount) \(MonitorFormat.percent(disk.usedFraction * 100))"
            }.joined(separator: " · ")
            alerts.append(MonitorAlert(
                kind: .disk,
                title: L("磁盘使用率过高"),
                detail: L("%@（阈值 %@）", mounts, MonitorFormat.percent(limits.disk))
            ))
        }
        if snapshot.load1 >= limits.load {
            alerts.append(MonitorAlert(
                kind: .load,
                title: L("系统负载过高"),
                detail: L("1 分钟负载 %.2f，阈值 %.2f", snapshot.load1, limits.load)
            ))
        }

        if alerts != activeAlerts { activeAlerts = alerts }
        queueSystemNotifications(for: alerts)
    }

    private func queueSystemNotifications(for alerts: [MonitorAlert]) {
        guard UserDefaults.standard.bool(forKey: MonitorAlertPreference.systemNotificationsKey) else { return }
        for alert in alerts {
            let key = "\(exec.destination):\(exec.port):\(alert.kind.rawValue)"
            Task {
                let center = UNUserNotificationCenter.current()
                guard (await center.notificationSettings()).authorizationStatus == .authorized else { return }
                // The condition may have cleared while waiting for the
                // notification service, especially on the first permission
                // request. Do not deliver a stale alert.
                guard activeAlerts.contains(alert) else { return }
                let now = Date()
                if let last = Self.notificationDates[key], now.timeIntervalSince(last) < Self.notificationCooldown {
                    return
                }
                Self.notificationDates[key] = now
                let content = UNMutableNotificationContent()
                content.title = L("Harbor：%@", alert.title)
                content.body = alert.detail
                content.sound = .default
                let request = UNNotificationRequest(identifier: "harbor.monitor.\(key)", content: content, trigger: nil)
                try? await center.add(request)
            }
        }
    }

    private func ingestNetwork(_ interfaces: [NetworkInterfaceCounters], into next: inout Frame) {
        let now = Date()
        var counters: [String: (rx: UInt64, tx: UInt64)] = [:]
        for interface in interfaces {
            counters[interface.name] = (interface.rxBytes, interface.txBytes)
        }
        defer { previousNet = (now, counters) }

        // Container hosts churn veth/cali interfaces constantly; drop series
        // for interfaces gone from this snapshot so they never accumulate
        // over a long session. Skipped when the snapshot is empty (transient
        // /proc read glitch) so existing history is not wiped.
        let live = Set(counters.keys)
        if !live.isEmpty {
            if next.rxSpeedSeries.contains(where: { !live.contains($0.key) }) {
                next.rxSpeedSeries = next.rxSpeedSeries.filter { live.contains($0.key) }
            }
            if next.txSpeedSeries.contains(where: { !live.contains($0.key) }) {
                next.txSpeedSeries = next.txSpeedSeries.filter { live.contains($0.key) }
            }
        }

        guard let previous = previousNet else { return }
        let elapsed = now.timeIntervalSince(previous.date)
        guard elapsed > 0 else { return }

        var latest: [String: (rx: Double, tx: Double)] = [:]
        for (name, current) in counters {
            guard let before = previous.counters[name] else { continue }
            let rx = MonitorParsers.netSpeed(
                previousBytes: before.rx, currentBytes: current.rx, seconds: elapsed
            )
            let tx = MonitorParsers.netSpeed(
                previousBytes: before.tx, currentBytes: current.tx, seconds: elapsed
            )
            append(rx, to: &next.rxSpeedSeries[name, default: []])
            append(tx, to: &next.txSpeedSeries[name, default: []])
            latest[name] = (rx, tx)
        }
        autoPickInterface(latest: latest)
    }

    /// Computes disk read/write bytes/sec for the busiest whole-disk device
    /// by diffing consecutive `/proc/diskstats` sector counts. Mirrors the
    /// same delta-then-defer pattern used by `ingestNetwork`.
    private func ingestDisk(_ diskCounters: [DiskIOCounters], into next: inout Frame) {
        let now = Date()
        var current: [String: (read: UInt64, write: UInt64)] = [:]
        for c in diskCounters { current[c.device] = (c.sectorsRead, c.sectorsWritten) }
        defer { previousDisk = (now, current) }

        guard let previous = previousDisk else { return }
        let elapsed = now.timeIntervalSince(previous.date)
        guard elapsed > 0 else { return }

        // Pick the device with the highest combined read+write activity.
        var bestRead: Double = 0
        var bestWrite: Double = 0
        var bestActivity: Double = -1

        for (name, cur) in current {
            guard let prev = previous.counters[name] else { continue }
            let readDelta  = cur.read  >= prev.read  ? cur.read  - prev.read  : 0
            let writeDelta = cur.write >= prev.write ? cur.write - prev.write : 0
            let readBps  = Double(readDelta)  * 512.0 / elapsed
            let writeBps = Double(writeDelta) * 512.0 / elapsed
            let activity = readBps + writeBps
            if activity > bestActivity {
                bestActivity = activity
                bestRead  = readBps
                bestWrite = writeBps
            }
        }

        if bestActivity >= 0 {
            next.diskReadBytesPerSec  = bestRead
            next.diskWriteBytesPerSec = bestWrite
        }
    }

    /// Picks the busiest non-loopback interface when nothing valid is selected.
    private func autoPickInterface(latest: [String: (rx: Double, tx: Double)]) {
        if let selected = selectedInterface, latest[selected] != nil { return }
        let best = latest
            .filter { $0.key != "lo" }
            .max { ($0.value.rx + $0.value.tx, $1.key) < ($1.value.rx + $1.value.tx, $0.key) }?
            .key
        selectedInterface = best ?? latest.keys.sorted().first
    }

    /// Alphabetical, loopback last (it is rarely what the user wants). Cached
    /// into the frame so the 网络 picker never sorts during a SwiftUI body pass.
    private static func sortedInterfaceNames(_ interfaces: [NetworkInterfaceCounters]) -> [String] {
        interfaces.map(\.name).sorted { a, b in
            if (a == "lo") != (b == "lo") { return b == "lo" }
            return a < b
        }
    }

    /// Live, non-loopback interfaces that still have a throughput sample, ordered
    /// busiest-first by current RX+TX (ties broken by name). Mirrors the
    /// loopback/stale filtering `ingestNetwork` uses to evict churned interfaces.
    private static func busiestInterfaceNames(in frame: Frame) -> [String] {
        let live = Set(frame.snapshot?.interfaces.map(\.name) ?? [])
        return frame.rxSpeedSeries.keys
            .filter { $0 != "lo" && live.contains($0) }
            .sorted { a, b in
                let aSpeed = (frame.rxSpeedSeries[a]?.last ?? 0) + (frame.txSpeedSeries[a]?.last ?? 0)
                let bSpeed = (frame.rxSpeedSeries[b]?.last ?? 0) + (frame.txSpeedSeries[b]?.last ?? 0)
                if aSpeed != bSpeed { return aSpeed > bSpeed }
                return a < b
            }
    }

    private func append(_ value: Double, to series: inout [Double]) {
        series.append(value)
        if series.count > Self.maxSamples {
            series.removeFirst(series.count - Self.maxSamples)
        }
    }
}
