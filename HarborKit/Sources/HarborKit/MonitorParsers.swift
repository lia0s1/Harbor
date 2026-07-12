import Foundation

// MARK: - Models

/// Aggregate CPU time counters from the first line of `/proc/stat` (jiffies).
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt64
    public var nice: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var iowait: UInt64
    public var irq: UInt64
    public var softirq: UInt64
    public var steal: UInt64

    public init(
        user: UInt64 = 0,
        nice: UInt64 = 0,
        system: UInt64 = 0,
        idle: UInt64 = 0,
        iowait: UInt64 = 0,
        irq: UInt64 = 0,
        softirq: UInt64 = 0,
        steal: UInt64 = 0
    ) {
        self.user = user
        self.nice = nice
        self.system = system
        self.idle = idle
        self.iowait = iowait
        self.irq = irq
        self.softirq = softirq
        self.steal = steal
    }

    /// Sum of all eight columns. Uses SATURATING addition: a compromised or
    /// corrupt `/proc/stat` can emit columns near `UInt64.max`, and a plain `+`
    /// overflow is a hard trap in Swift — a single hostile monitoring sample
    /// would crash the whole app. Saturating to `UInt64.max` degrades to a bad
    /// reading instead (cpuPercent then just returns nil for that tick). Mirrors
    /// the inf/nan guards already on `parseUptime`/`parseLoadAvg`.
    public var total: UInt64 {
        CPUTicks.saturatingSum(user, nice, system, idle, iowait, irq, softirq, steal)
    }
    /// Idle in the broad sense: idle + iowait (matches `top`'s notion of busy).
    public var idleAll: UInt64 { CPUTicks.saturatingSum(idle, iowait) }

    /// Adds without ever trapping: on overflow the running total pins at
    /// `UInt64.max` rather than crashing.
    static func saturatingSum(_ values: UInt64...) -> UInt64 {
        var total: UInt64 = 0
        for value in values {
            let (sum, overflow) = total.addingReportingOverflow(value)
            total = overflow ? UInt64.max : sum
        }
        return total
    }
}

/// Cumulative counters for one interface from `/proc/net/dev`.
public struct NetworkInterfaceCounters: Equatable, Sendable {
    public let name: String
    public let rxBytes: UInt64
    public let txBytes: UInt64
    public let rxPackets: UInt64
    public let txPackets: UInt64
    public let rxErrors: UInt64
    public let txErrors: UInt64
    public let rxDrops: UInt64
    public let txDrops: UInt64

    public init(
        name: String,
        rxBytes: UInt64,
        txBytes: UInt64,
        rxPackets: UInt64 = 0,
        txPackets: UInt64 = 0,
        rxErrors: UInt64 = 0,
        txErrors: UInt64 = 0,
        rxDrops: UInt64 = 0,
        txDrops: UInt64 = 0
    ) {
        self.name = name
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.rxPackets = rxPackets
        self.txPackets = txPackets
        self.rxErrors = rxErrors
        self.txErrors = txErrors
        self.rxDrops = rxDrops
        self.txDrops = txDrops
    }
}

/// One real filesystem from `df -kP` (1024-byte blocks).
public struct DiskUsage: Equatable, Sendable {
    public let mount: String
    public let totalKB: UInt64
    public let availableKB: UInt64

    public init(mount: String, totalKB: UInt64, availableKB: UInt64) {
        self.mount = mount
        self.totalKB = totalKB
        self.availableKB = availableKB
    }

    public var usedKB: UInt64 { totalKB > availableKB ? totalKB - availableKB : 0 }
    public var usedFraction: Double { totalKB == 0 ? 0 : Double(usedKB) / Double(totalKB) }
}

/// One row of `ps -eo pid,user,pcpu,rss,comm --sort=-pcpu`.
public struct TopProcess: Equatable, Sendable {
    public let pid: Int
    public let user: String
    public let cpuPercent: Double
    public let rssKB: UInt64
    public let command: String

    public init(cpuPercent: Double, rssKB: UInt64, command: String, pid: Int = 0, user: String = "") {
        self.pid = pid
        self.user = user
        self.cpuPercent = cpuPercent
        self.rssKB = rssKB
        self.command = command
    }
}

/// Rich per-process detail fetched on demand for one pid (the 进程详情
/// inspector), well beyond the five columns the 2s top-list probe collects:
/// parent, state, threads, priority, memory split, start time and the full
/// command line. Every field past `pid` degrades to a zero/empty default when
/// the host's `ps` omits that column, so an old/busybox `ps` still yields what
/// it can.
public struct ProcessDetail: Equatable, Sendable {
    public let pid: Int
    public let ppid: Int
    public let user: String
    /// Raw `stat` code (e.g. "Ssl", "R", "Z"); the leading letter is mapped for display.
    public let state: String
    public let nice: Int
    public let priority: Int
    public let cpuPercent: Double
    public let memPercent: Double
    public let rssKB: UInt64
    public let vszKB: UInt64
    public let threads: Int
    public let elapsedSeconds: Int
    /// Human start time from `ps -o lstart` (e.g. "Mon Jun  9 12:34:56 2025").
    public let startTime: String
    /// Full command line from `ps -o args` (the comm-only top list never has this).
    public let command: String

    public init(pid: Int, ppid: Int, user: String, state: String, nice: Int,
                priority: Int, cpuPercent: Double, memPercent: Double,
                rssKB: UInt64, vszKB: UInt64, threads: Int, elapsedSeconds: Int,
                startTime: String, command: String) {
        self.pid = pid; self.ppid = ppid; self.user = user; self.state = state
        self.nice = nice; self.priority = priority; self.cpuPercent = cpuPercent
        self.memPercent = memPercent; self.rssKB = rssKB; self.vszKB = vszKB
        self.threads = threads; self.elapsedSeconds = elapsedSeconds
        self.startTime = startTime; self.command = command
    }
}

/// Everything one monitoring sample knows about the remote host.
public struct SystemSnapshot: Equatable, Sendable {
    public var os: String = ""
    public var uptimeSeconds: Double = 0
    public var load1: Double = 0
    public var load5: Double = 0
    public var load15: Double = 0
    public var cpuTicks: CPUTicks?
    /// Per-core counters (`cpu0`, `cpu1`, … lines of `/proc/stat`), in order.
    /// Empty on kernels/containers that don't expose them.
    public var perCoreTicks: [CPUTicks] = []
    public var memTotalKB: UInt64 = 0
    public var memAvailableKB: UInt64 = 0
    public var memFreeKB: UInt64 = 0
    public var memBuffersKB: UInt64 = 0
    public var memCachedKB: UInt64 = 0
    public var swapTotalKB: UInt64 = 0
    public var swapFreeKB: UInt64 = 0
    public var interfaces: [NetworkInterfaceCounters] = []
    public var disks: [DiskUsage] = []
    public var topProcesses: [TopProcess] = []

    public init() {}

    public var isLinux: Bool { os == "Linux" }
    public var memUsedKB: UInt64 { memTotalKB > memAvailableKB ? memTotalKB - memAvailableKB : 0 }
    public var memUsedFraction: Double { memTotalKB == 0 ? 0 : Double(memUsedKB) / Double(memTotalKB) }
    public var swapUsedKB: UInt64 { swapTotalKB > swapFreeKB ? swapTotalKB - swapFreeKB : 0 }
    public var swapUsedFraction: Double { swapTotalKB == 0 ? 0 : Double(swapUsedKB) / Double(swapTotalKB) }
}

// MARK: - Parsers

/// Pure parsers for the multi-section payload produced by the monitoring
/// remote script. Linux-first: the caller gates on `SystemSnapshot.isLinux`
/// before trusting anything beyond `os`.
public enum MonitorParsers {
    /// Section separator emitted between commands by the remote script.
    public static let sectionSeparator = "@@HARBOR@@"

    /// The single remote script run over the multiplexed connection every
    /// tick. One argv element — never fed to a local shell.
    public static let remoteScript = [
        "uname -s",
        "cat /proc/uptime",
        "cat /proc/loadavg",
        "cat /proc/stat",
        "cat /proc/meminfo",
        "cat /proc/net/dev",
        "df -kP",
        "LC_ALL=C ps -eo pid,user:16,pcpu,rss,comm --sort=-pcpu | head -16",
    ].joined(separator: "; echo \(sectionSeparator); ")

    // Section indices in the payload, matching `remoteScript` order.
    private enum Section: Int {
        case uname = 0, uptime, loadavg, stat, meminfo, netdev, df, ps
    }

    /// Parses a full payload. Missing or malformed sections degrade to
    /// defaults instead of failing the whole sample, so a partially broken
    /// host (e.g. unreadable /proc file) still reports what it can.
    public static func parseSnapshot(_ payload: String) -> SystemSnapshot {
        let sections = splitSections(payload)
        func section(_ s: Section) -> String? {
            sections.indices.contains(s.rawValue) ? sections[s.rawValue] : nil
        }

        var snap = SystemSnapshot()
        snap.os = (section(.uname) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let text = section(.uptime), let uptime = parseUptime(text) {
            snap.uptimeSeconds = uptime
        }
        if let text = section(.loadavg), let load = parseLoadAvg(text) {
            (snap.load1, snap.load5, snap.load15) = load
        }
        if let text = section(.stat) {
            snap.cpuTicks = parseCPUTicks(text)
            snap.perCoreTicks = parsePerCoreCPUTicks(text)
        }
        if let text = section(.meminfo) {
            let mem = parseMemInfo(text)
            snap.memTotalKB = mem.totalKB
            snap.memAvailableKB = mem.availableKB
            snap.memFreeKB = mem.freeKB
            snap.memBuffersKB = mem.buffersKB
            snap.memCachedKB = mem.cachedKB
            snap.swapTotalKB = mem.swapTotalKB
            snap.swapFreeKB = mem.swapFreeKB
        }
        if let text = section(.netdev) {
            snap.interfaces = parseNetDev(text)
        }
        if let text = section(.df) {
            snap.disks = parseDF(text)
        }
        if let text = section(.ps) {
            snap.topProcesses = parseTopProcesses(text)
        }
        return snap
    }

    /// Splits the payload on lines equal to `sectionSeparator`.
    public static func splitSections(_ payload: String) -> [String] {
        ProcText.splitSections(payload, separator: sectionSeparator)
    }

    /// `/proc/uptime`: "35453006.92 280412407.62" → first value, seconds.
    /// Rejects non-finite tokens ("inf"/"nan") and overflowing magnitudes
    /// ("1e400" → +∞), which `Double()` happily parses: a downstream
    /// `Int(seconds)` (MonitorFormat.uptime) would trap on a non-finite value
    /// and crash the whole app from a single hostile/corrupt remote line.
    public static func parseUptime(_ text: String) -> Double? {
        guard let first = tokens(of: text).first,
              let value = Double(first), value.isFinite, value >= 0
        else { return nil }
        return value
    }

    /// `/proc/loadavg`: "0.28 0.31 0.27 2/345 12345" → (1, 5, 15 minute).
    /// Non-finite/negative values are rejected for the same reason as uptime.
    public static func parseLoadAvg(_ text: String) -> (Double, Double, Double)? {
        let parts = tokens(of: text)
        guard parts.count >= 3,
              let l1 = Double(parts[0]), let l5 = Double(parts[1]), let l15 = Double(parts[2]),
              l1.isFinite, l5.isFinite, l15.isFinite, l1 >= 0, l5 >= 0, l15 >= 0
        else { return nil }
        return (l1, l5, l15)
    }

    /// First aggregate "cpu " line of `/proc/stat`. Tolerates old kernels with
    /// fewer columns (missing fields default to 0) and new ones with extra
    /// guest/guest_nice columns (ignored — they are already in user/nice).
    public static func parseCPUTicks(_ text: String) -> CPUTicks? {
        for line in text.split(separator: "\n") {
            let parts = tokens(of: String(line))
            guard parts.first == "cpu" else { continue }
            // Strict: every present column must be a valid integer. A garbled
            // column (corrupt or hostile /proc/stat) skips the whole sample
            // instead of silently coercing to 0, which would skew the busy/idle
            // delta in `cpuPercent` and report a bogus CPU% for that tick.
            let rawColumns = parts.dropFirst()
            guard !rawColumns.isEmpty else { return nil }
            var values: [UInt64] = []
            values.reserveCapacity(rawColumns.count)
            for token in rawColumns {
                guard let value = UInt64(token) else { return nil }
                values.append(value)
            }
            func column(_ index: Int) -> UInt64 {
                values.indices.contains(index) ? values[index] : 0
            }
            return CPUTicks(
                user: column(0), nice: column(1), system: column(2), idle: column(3),
                iowait: column(4), irq: column(5), softirq: column(6), steal: column(7)
            )
        }
        return nil
    }

    /// Per-core `cpuN` lines of `/proc/stat` (the aggregate `cpu` line is
    /// excluded), in order. A garbled column skips that one core rather than the
    /// whole sample, so one bad line never drops the others.
    public static func parsePerCoreCPUTicks(_ text: String) -> [CPUTicks] {
        var cores: [CPUTicks] = []
        for line in text.split(separator: "\n") {
            let parts = tokens(of: String(line))
            guard let label = parts.first, label.hasPrefix("cpu"), label != "cpu" else { continue }
            let index = label.dropFirst(3)
            guard !index.isEmpty, index.allSatisfy(\.isNumber) else { continue }
            let rawColumns = parts.dropFirst()
            guard !rawColumns.isEmpty else { continue }
            var values: [UInt64] = []
            var valid = true
            for token in rawColumns {
                guard let value = UInt64(token) else { valid = false; break }
                values.append(value)
            }
            guard valid else { continue }
            func column(_ i: Int) -> UInt64 { values.indices.contains(i) ? values[i] : 0 }
            cores.append(CPUTicks(
                user: column(0), nice: column(1), system: column(2), idle: column(3),
                iowait: column(4), irq: column(5), softirq: column(6), steal: column(7)
            ))
        }
        return cores
    }

    public struct MemInfo: Equatable, Sendable {
        public var totalKB: UInt64 = 0
        public var availableKB: UInt64 = 0
        public var freeKB: UInt64 = 0
        public var buffersKB: UInt64 = 0
        public var cachedKB: UInt64 = 0
        public var swapTotalKB: UInt64 = 0
        public var swapFreeKB: UInt64 = 0
        public init() {}
    }

    /// `/proc/meminfo`. Kernels before 3.14 lack MemAvailable; fall back to
    /// MemFree + Buffers + Cached.
    public static func parseMemInfo(_ text: String) -> MemInfo {
        var fields: [String: UInt64] = [:]
        for line in text.split(separator: "\n") {
            let parts = tokens(of: String(line))
            guard parts.count >= 2, parts[0].hasSuffix(":") else { continue }
            let key = String(parts[0].dropLast())
            if let value = UInt64(parts[1]) {
                fields[key] = value
            }
        }
        var info = MemInfo()
        info.totalKB = fields["MemTotal"] ?? 0
        info.freeKB = fields["MemFree"] ?? 0
        info.buffersKB = fields["Buffers"] ?? 0
        info.cachedKB = fields["Cached"] ?? 0
        if let available = fields["MemAvailable"] {
            info.availableKB = available
        } else {
            info.availableKB = CPUTicks.saturatingSum(info.freeKB, info.buffersKB, info.cachedKB)
        }
        info.swapTotalKB = fields["SwapTotal"] ?? 0
        info.swapFreeKB = fields["SwapFree"] ?? 0
        return info
    }

    /// `/proc/net/dev`. Skips the two header lines (they contain `|`).
    /// Handles arbitrary interface names and the classic quirk where large
    /// counters butt up against the colon ("eth0:123456789 …").
    public static func parseNetDev(_ text: String) -> [NetworkInterfaceCounters] {
        var result: [NetworkInterfaceCounters] = []
        for line in text.split(separator: "\n") {
            guard !line.contains("|"), let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let fields = tokens(of: String(line[line.index(after: colon)...]))
            // rx: bytes packets errs drop fifo frame compressed multicast (0-7),
            // tx: bytes packets errs drop fifo colls carrier compressed (8-15).
            // /proc/net/dev always emits 16 data columns (indices 0-15 after the colon).
            guard fields.count >= 16,
                  let rx = UInt64(fields[0]), let tx = UInt64(fields[8])
            else { continue }
            func col(_ i: Int) -> UInt64 { UInt64(fields[i]) ?? 0 }
            result.append(NetworkInterfaceCounters(
                name: name, rxBytes: rx, txBytes: tx,
                rxPackets: col(1),
                txPackets: col(9),
                rxErrors:  col(2),
                txErrors:  col(10),
                rxDrops:   col(3),
                txDrops:   col(11)
            ))
        }
        return result
    }

    /// `df -kP` (POSIX: one line per filesystem, 1024-blocks). Filters
    /// tmpfs/devtmpfs/overlay/loop pseudo-mounts and /proc-ish mount points
    /// (shared with `SystemInfoParser` via `ProcText`); dedupes by mount point
    /// (first wins). Mount points may contain spaces.
    public static func parseDF(_ text: String) -> [DiskUsage] {
        var result: [DiskUsage] = []
        var seenMounts: Set<String> = []
        for line in text.split(separator: "\n") {
            let fields = tokens(of: String(line))
            // Filesystem 1024-blocks Used Available Capacity Mounted-on…
            guard fields.count >= 6,
                  let totalKB = UInt64(fields[1]),
                  let availableKB = UInt64(fields[3])
            else { continue } // header or malformed line
            let device = fields[0]
            let mount = fields[5...].joined(separator: " ")
            guard ProcText.isRealFilesystem(device: device, mount: mount),
                  !seenMounts.contains(mount)
            else { continue }
            seenMounts.insert(mount)
            result.append(DiskUsage(mount: mount, totalKB: totalKB, availableKB: availableKB))
        }
        return result
    }

    /// `ps -eo pid,user,pcpu,rss,comm --sort=-pcpu | head -16`: header + rows.
    /// Field layout: pid user pcpu rss comm…  — the command (which may contain
    /// spaces) is everything from the fifth column on. Requires the full
    /// five-column layout the remote script always emits; the header row
    /// ("PID USER %CPU RSS COMMAND") and any line with fewer columns or a
    /// non-numeric pid are skipped.
    public static func parseTopProcesses(_ text: String) -> [TopProcess] {
        var result: [TopProcess] = []
        for line in text.split(separator: "\n") {
            let fields = tokens(of: String(line))
            guard fields.count >= 5,
                  let pid = Int(fields[0]),
                  let cpu = Double(fields[2]),
                  let rss = UInt64(fields[3])
            else { continue } // header ("PID USER %CPU RSS COMMAND") or malformed
            result.append(TopProcess(
                cpuPercent: cpu,
                rssKB: rss,
                command: fields[4...].joined(separator: " "),
                pid: pid,
                user: fields[1]
            ))
        }
        return result
    }

    /// Parses the three-section payload of `MonitorService.fetchDetail`: a
    /// scalar line (`ps -o pid,ppid,user,stat,nice,pri,pcpu,pmem,rss,vsz,nlwp,etimes`),
    /// then `lstart`, then `args` — each in its own `@@HARBOR@@` section so the
    /// space-bearing start time and command line survive splitting. Returns nil
    /// when the scalar line is absent or its pid is unreadable (process gone).
    public static func parseProcessDetail(_ payload: String) -> ProcessDetail? {
        let sections = splitSections(payload)
        guard let scalarLine = sections.first?.split(separator: "\n").first.map(String.init)
        else { return nil }
        let f = tokens(of: scalarLine)
        guard f.count >= 12, let pid = Int(f[0]) else { return nil }
        let startTime = sections.indices.contains(1)
            ? sections[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let args = sections.indices.contains(2)
            ? sections[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return ProcessDetail(
            pid: pid,
            ppid: Int(f[1]) ?? 0,
            user: f[2],
            state: f[3],
            nice: Int(f[4]) ?? 0,
            priority: Int(f[5]) ?? 0,
            cpuPercent: Double(f[6]) ?? 0,
            memPercent: Double(f[7]) ?? 0,
            rssKB: UInt64(f[8]) ?? 0,
            vszKB: UInt64(f[9]) ?? 0,
            threads: Int(f[10]) ?? 0,
            elapsedSeconds: Int(f[11]) ?? 0,
            startTime: startTime,
            command: args
        )
    }

    // MARK: - Delta helpers

    /// Busy CPU percent between two `/proc/stat` samples; nil when the
    /// counters did not advance (or wrapped/reset, e.g. across a reboot).
    public static func cpuPercent(previous: CPUTicks, current: CPUTicks) -> Double? {
        guard current.total > previous.total else { return nil }
        let totalDelta = current.total - previous.total
        let idleDelta = current.idleAll >= previous.idleAll ? current.idleAll - previous.idleAll : 0
        let busyDelta = totalDelta > idleDelta ? totalDelta - idleDelta : 0
        return min(100, max(0, Double(busyDelta) / Double(totalDelta) * 100))
    }

    /// How a CPU interval's busy time splits across components, each as a
    /// percent of the total delta (they sum to ~100). For the CPU detail panel.
    public struct CPUBreakdown: Equatable, Sendable {
        public let user: Double
        public let system: Double
        public let nice: Double
        public let iowait: Double
        public let irq: Double
        public let softirq: Double
        public let steal: Double
        public let idle: Double
        public init(
            user: Double, system: Double, nice: Double, iowait: Double,
            irq: Double, softirq: Double, steal: Double, idle: Double
        ) {
            self.user = user; self.system = system; self.nice = nice; self.iowait = iowait
            self.irq = irq; self.softirq = softirq; self.steal = steal; self.idle = idle
        }
    }

    /// Per-component split between two `/proc/stat` samples; nil when the
    /// counters did not advance (or wrapped/reset).
    public static func cpuBreakdown(previous: CPUTicks, current: CPUTicks) -> CPUBreakdown? {
        guard current.total > previous.total else { return nil }
        let totalDelta = Double(current.total - previous.total)
        func share(_ now: UInt64, _ before: UInt64) -> Double {
            let delta = now >= before ? now - before : 0
            return min(100, Double(delta) / totalDelta * 100)
        }
        return CPUBreakdown(
            user: share(current.user, previous.user),
            system: share(current.system, previous.system),
            nice: share(current.nice, previous.nice),
            iowait: share(current.iowait, previous.iowait),
            irq: share(current.irq, previous.irq),
            softirq: share(current.softirq, previous.softirq),
            steal: share(current.steal, previous.steal),
            idle: share(current.idle, previous.idle)
        )
    }

    /// Bytes per second between two cumulative counters. Counter resets
    /// (current < previous, e.g. interface re-created) report 0, not garbage.
    public static func netSpeed(previousBytes: UInt64, currentBytes: UInt64, seconds: Double) -> Double {
        guard seconds > 0, currentBytes >= previousBytes else { return 0 }
        return Double(currentBytes - previousBytes) / seconds
    }

    // MARK: - Ping

    private static let pingTimeRegex: NSRegularExpression = {
        do { return try NSRegularExpression(pattern: #"time=([0-9]+(?:\.[0-9]+)?)\s*ms"#) }
        catch { fatalError("pingTimeRegex pattern is invalid: \(error)") }
    }()

    /// Extracts the latency from one line of `ping` output
    /// ("… icmp_seq=0 ttl=56 time=12.345 ms"); nil for non-reply lines.
    public static func pingLatency(line: String) -> Double? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = pingTimeRegex.firstMatch(in: line, range: range),
              let captured = Range(match.range(at: 1), in: line)
        else { return nil }
        return Double(line[captured])
    }

    // MARK: - Helpers

    private static func tokens(of line: String) -> [String] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }
}
