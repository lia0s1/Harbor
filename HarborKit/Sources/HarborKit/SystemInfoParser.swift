import Foundation

// MARK: - Model

/// One network interface in the System Info report: a name plus all of its
/// addresses (IPv4 and IPv6). FinalShell's 系统信息 lists every interface with
/// its addresses; we mirror that.
public struct SystemInterface: Equatable, Sendable {
    public let name: String
    public let addresses: [String]

    public init(name: String, addresses: [String]) {
        self.name = name
        self.addresses = addresses
    }
}

/// One filesystem row for the System Info report (`df -kP`, 1024-blocks). The
/// monitor panel already has its own lean `DiskUsage`; System Info keeps the
/// device name too, so the detailed report can show "/dev/vda1 → /".
public struct SystemFilesystem: Equatable, Sendable {
    public let device: String
    public let mount: String
    public let totalKB: UInt64
    public let availableKB: UInt64

    public init(device: String, mount: String, totalKB: UInt64, availableKB: UInt64) {
        self.device = device
        self.mount = mount
        self.totalKB = totalKB
        self.availableKB = availableKB
    }

    public var usedKB: UInt64 { totalKB > availableKB ? totalKB - availableKB : 0 }
    public var usedFraction: Double { totalKB == 0 ? 0 : Double(usedKB) / Double(totalKB) }
}

/// A one-shot detailed system report (FinalShell's 系统信息 button): OS,
/// kernel + arch, hostname, CPU model / cores / clock, memory + swap, uptime,
/// every network interface with its addresses, and every real filesystem.
///
/// Pure value type produced by `SystemInfoParser` from the multi-section
/// payload of one remote probe script. Missing sections degrade to empty
/// fields rather than failing the whole report.
public struct SystemInfo: Equatable, Sendable {
    /// Raw `uname -s` ("Linux", "Darwin", …); the caller gates richer fields.
    public var os: String = ""
    /// `/etc/os-release` PRETTY_NAME ("Ubuntu 22.04.4 LTS"); empty when absent.
    public var prettyName: String = ""
    /// `uname -r`.
    public var kernel: String = ""
    /// `uname -m` ("x86_64", "aarch64").
    public var arch: String = ""
    public var hostname: String = ""
    /// First "model name" / "Hardware" line from `/proc/cpuinfo`.
    public var cpuModel: String = ""
    /// Logical core count (number of "processor" lines).
    public var cpuCores: Int = 0
    /// First "cpu MHz" value, rounded; 0 when the field is absent (common on ARM).
    public var cpuMHz: Double = 0
    public var memTotalKB: UInt64 = 0
    public var memAvailableKB: UInt64 = 0
    public var swapTotalKB: UInt64 = 0
    public var swapFreeKB: UInt64 = 0
    public var uptimeSeconds: Double = 0
    public var interfaces: [SystemInterface] = []
    public var filesystems: [SystemFilesystem] = []
    /// Cumulative received/sent bytes across all real (non-loopback) interfaces
    /// since boot, for the 入站/出站 traffic rings. 0 when unavailable.
    public var netRxTotalBytes: UInt64 = 0
    public var netTxTotalBytes: UInt64 = 0

    public init() {}

    public var isLinux: Bool { os == "Linux" }
    public var memUsedKB: UInt64 { memTotalKB > memAvailableKB ? memTotalKB - memAvailableKB : 0 }
    public var swapUsedKB: UInt64 { swapTotalKB > swapFreeKB ? swapTotalKB - swapFreeKB : 0 }
}

// MARK: - Parser

/// Pure parser for the one-shot System Info probe. Like `MonitorParsers`, the
/// remote script is a single argv element whose command outputs are separated
/// by a sentinel line; each section degrades to a default instead of failing
/// the whole report. Linux-first.
public enum SystemInfoParser {
    /// Section separator (distinct from the monitor one so the two payloads are
    /// never confused if ever logged together).
    public static let sectionSeparator = "@@HARBOR-SYS@@"

    /// The single remote script for one System Info probe. One argv element —
    /// the remote shell parses it; never fed to a local shell. Each command is
    /// wrapped so a missing file (`/etc/os-release` on minimal images) prints
    /// nothing rather than aborting the whole pipeline.
    public static let remoteScript = [
        "uname -s",
        "(cat /etc/os-release 2>/dev/null || true)",
        "uname -r",
        "uname -m",
        "(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || true)",
        "(cat /proc/cpuinfo 2>/dev/null || true)",
        "(cat /proc/meminfo 2>/dev/null || true)",
        "(cat /proc/uptime 2>/dev/null || true)",
        // `ip -o addr` is the clean source; fall back to nothing on hosts
        // without iproute2 (the parser then yields no interfaces, handled).
        "(ip -o addr show 2>/dev/null || true)",
        "(df -kP 2>/dev/null || true)",
        "(cat /proc/net/dev 2>/dev/null || true)",
    ].joined(separator: "; echo \(sectionSeparator); ")

    private enum Section: Int {
        case uname = 0, osRelease, kernel, arch, hostname, cpuinfo, meminfo, uptime, ipAddr, df, netdev
    }

    public static func parse(_ payload: String) -> SystemInfo {
        let sections = splitSections(payload)
        func section(_ s: Section) -> String {
            sections.indices.contains(s.rawValue) ? sections[s.rawValue] : ""
        }

        var info = SystemInfo()
        info.os = section(.uname).trimmingCharacters(in: .whitespacesAndNewlines)
        info.prettyName = parsePrettyName(section(.osRelease))
        info.kernel = section(.kernel).trimmingCharacters(in: .whitespacesAndNewlines)
        info.arch = section(.arch).trimmingCharacters(in: .whitespacesAndNewlines)
        info.hostname = firstNonEmptyLine(section(.hostname)) ?? ""

        let cpu = parseCPUInfo(section(.cpuinfo))
        info.cpuModel = cpu.model
        info.cpuCores = cpu.cores
        info.cpuMHz = cpu.mhz

        let mem = MonitorParsers.parseMemInfo(section(.meminfo))
        info.memTotalKB = mem.totalKB
        info.memAvailableKB = mem.availableKB
        info.swapTotalKB = mem.swapTotalKB
        info.swapFreeKB = mem.swapFreeKB

        if let uptime = MonitorParsers.parseUptime(section(.uptime)) {
            info.uptimeSeconds = uptime
        }

        info.interfaces = parseInterfaces(section(.ipAddr))
        info.filesystems = parseFilesystems(section(.df))

        // Total inbound/outbound bytes = sum over real (non-lo) interfaces.
        let counters = MonitorParsers.parseNetDev(section(.netdev))
        for counter in counters where counter.name != "lo" {
            info.netRxTotalBytes &+= counter.rxBytes
            info.netTxTotalBytes &+= counter.txBytes
        }
        return info
    }

    /// Splits the payload on lines equal to `sectionSeparator`.
    public static func splitSections(_ payload: String) -> [String] {
        ProcText.splitSections(payload, separator: sectionSeparator)
    }

    // MARK: - /etc/os-release

    /// Extracts PRETTY_NAME from `/etc/os-release` (shell key=value, the value
    /// is usually double-quoted). Empty when the file or key is absent.
    public static func parsePrettyName(_ text: String) -> String {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("PRETTY_NAME=") else { continue }
            let value = trimmed.dropFirst("PRETTY_NAME=".count)
            return unquote(String(value))
        }
        return ""
    }

    /// Strips one layer of surrounding single or double quotes, then unescapes
    /// backslash sequences per the os-release spec (`\"` → `"`, `\\` → `\`).
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let first = value.first, last = value.last
        if first == "'" && last == "'" {
            return String(value.dropFirst().dropLast())
        }
        if first == "\"" && last == "\"" {
            let inner = String(value.dropFirst().dropLast())
            return inner
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return value
    }

    // MARK: - /proc/cpuinfo

    public struct CPUInfo: Equatable, Sendable {
        public var model: String = ""
        public var cores: Int = 0
        public var mhz: Double = 0
        public init() {}
    }

    /// Parses `/proc/cpuinfo`. Core count is the number of "processor" lines.
    /// The model comes from "model name" (x86) or, failing that, "Hardware" /
    /// "model" (ARM SBCs); clock from the first "cpu MHz" (often absent on ARM,
    /// left as 0). Tolerant of any field ordering and missing fields.
    public static func parseCPUInfo(_ text: String) -> CPUInfo {
        var info = CPUInfo()
        var modelName = ""
        var hardware = ""
        var armModel = ""
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "processor":
                info.cores += 1
            case "model name":
                if modelName.isEmpty { modelName = value }
            case "Hardware":
                if hardware.isEmpty { hardware = value }
            case "model":
                if armModel.isEmpty, Double(value) == nil { armModel = value }
            case "cpu MHz":
                if info.mhz == 0, let mhz = Double(value) { info.mhz = mhz }
            default:
                break
            }
        }
        info.model = !modelName.isEmpty ? modelName
            : (!hardware.isEmpty ? hardware : armModel)
        return info
    }

    // MARK: - Interfaces (`ip -o addr`)

    /// Parses `ip -o addr show`: one line per address, e.g.
    /// "2: eth0    inet 10.0.0.5/24 brd … scope global eth0".
    /// Groups addresses by interface (preserving first-seen order), keeps
    /// inet/inet6 addresses (with their prefix length), and skips loopback
    /// unless it is the only interface. Yields an empty list when iproute2 is
    /// absent (the section is empty), which the UI handles gracefully.
    public static func parseInterfaces(_ text: String) -> [SystemInterface] {
        var order: [String] = []
        var addresses: [String: [String]] = [:]
        for line in text.split(separator: "\n") {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // index family address …  — the leading "N:" index is tokens[0].
            guard tokens.count >= 4 else { continue }
            let name = tokens[1]
            guard let familyIndex = tokens.firstIndex(where: { $0 == "inet" || $0 == "inet6" }),
                  familyIndex + 1 < tokens.count
            else { continue }
            let address = tokens[familyIndex + 1] // "10.0.0.5/24"
            if addresses[name] == nil {
                order.append(name)
                addresses[name] = []
            }
            addresses[name]?.append(address)
        }
        let interfaces = order.map { SystemInterface(name: $0, addresses: addresses[$0] ?? []) }
        // Loopback is noise when real interfaces exist; keep it only if alone.
        let nonLoopback = interfaces.filter { $0.name != "lo" }
        return nonLoopback.isEmpty ? interfaces : nonLoopback
    }

    // MARK: - Filesystems (`df -kP`)

    /// `df -kP`: same pseudo-filesystem filtering as the monitor parser (shared
    /// via `ProcText`), but keeps the device column for the detailed report.
    /// Dedupes by mount.
    public static func parseFilesystems(_ text: String) -> [SystemFilesystem] {
        var result: [SystemFilesystem] = []
        var seenMounts: Set<String> = []
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 6,
                  let totalKB = UInt64(fields[1]),
                  let availableKB = UInt64(fields[3])
            else { continue }
            let device = fields[0]
            let mount = fields[5...].joined(separator: " ")
            guard ProcText.isRealFilesystem(device: device, mount: mount),
                  !seenMounts.contains(mount)
            else { continue }
            seenMounts.insert(mount)
            result.append(SystemFilesystem(
                device: device, mount: mount, totalKB: totalKB, availableKB: availableKB
            ))
        }
        return result
    }

    // MARK: - Helpers

    private static func firstNonEmptyLine(_ text: String) -> String? {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}
