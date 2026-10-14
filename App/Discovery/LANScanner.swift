import Foundation
import Network
import HarborKit

/// One live host found by the LAN sweep.
struct DiscoveredHost: Identifiable, Hashable, Sendable {
    var ip: String
    var hostname: String?
    var mac: String?
    /// True when a TCP connect to port 22 succeeded during the sweep.
    var sshOpen: Bool

    var id: String { ip }
}

/// FinalShell-style LAN host discovery without BPF or root.
///
/// Strategy: a TCP connect to ANY port forces the kernel to ARP the target
/// first, so a bounded-concurrency probe of port 22 across the local /24 both
/// (a) finds SSH servers directly and (b) populates the ARP cache with every
/// live host — including ones that refuse the connection. A post-sweep
/// `arp -an` read then yields IP→MAC for the whole segment, and getnameinfo
/// fills in hostnames under a short timeout.
///
/// Everything is off-main-actor; the UI only ever sees @Published snapshots.
@MainActor
final class LANScanner: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case done
        /// User-visible reason a scan can't run or found nothing actionable.
        case failed(String)
    }

    @Published private(set) var hosts: [DiscoveredHost] = []
    @Published private(set) var phase: Phase = .idle
    /// (probed, total) while scanning — drives the progress bar.
    @Published private(set) var probeProgress: (done: Int, total: Int) = (0, 0)
    /// What is being scanned, e.g. "en0: 192.168.1.10/24". Shown in the header.
    @Published private(set) var subnetSummary = ""

    /// nonisolated(unsafe) so deinit can cancel without hopping actors — same
    /// lifetime pattern as PingService (SwiftUI always releases us on main).
    private nonisolated(unsafe) var scanTask: Task<Void, Never>?

    /// Per-probe connect timeout. Refused connections return instantly; only
    /// dead addresses burn the full window, so 1.5s keeps a /24 sweep fast.
    /// nonisolated: the probe/DNS helpers run off the main actor.
    nonisolated private static let probeTimeout: TimeInterval = 1.5
    /// Reverse-DNS budget per host. mDNS answers instantly; a slow upstream
    /// resolver must never hold the scan hostage.
    nonisolated private static let dnsTimeout: TimeInterval = 1.5
    nonisolated private static let maxConcurrentProbes = 64

    deinit {
        assert(Thread.isMainThread, "LANScanner must be deallocated on the main thread")
        scanTask?.cancel()
    }

    // MARK: - Control

    func start() {
        scanTask?.cancel()
        hosts = []
        probeProgress = (0, 0)

        let subnets = Self.localSubnets()
        guard !subnets.isEmpty else {
            phase = .failed(L("没有可用的局域网接口：Wi-Fi 或以太网未连接。"))
            return
        }
        var seen: Set<UInt32> = []
        var addresses: [String] = []
        for subnet in subnets {
            for address in subnet.scanAddresses where seen.insert(address.raw).inserted {
                addresses.append(address.dottedString)
            }
        }
        guard !addresses.isEmpty else {
            phase = .failed(L("无法根据接口掩码计算出可扫描的网段。"))
            return
        }
        subnetSummary = subnets.map {
            "\($0.interfaceName): \($0.address.dottedString)/\($0.prefixLength ?? 24)"
        }.joined(separator: "，")
        phase = .scanning
        scanTask = Task { [weak self] in
            await self?.runScan(addresses: addresses)
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        if phase == .scanning { phase = hosts.isEmpty ? .idle : .done }
    }

    // MARK: - Scan pipeline

    private func runScan(addresses: [String]) async {
        // Entries already in the cache from normal system traffic.
        let baseline = await Self.readARPTable()
        let total = addresses.count
        let openSSH = await Self.probeSSHPorts(addresses) { [weak self] done in
            Task { @MainActor [weak self] in
                self?.probeProgress = (done, total)
            }
        }
        guard !Task.isCancelled else { return }

        // Post-sweep table: the probes forced ARP resolution for every probed
        // address, so live hosts appear here even when they refused port 22.
        let swept = await Self.readARPTable()
        guard !Task.isCancelled else { return }

        let addressSet = Set(addresses)
        var found: [String: DiscoveredHost] = [:]
        for entry in baseline + swept {
            guard let mac = entry.mac,
                  mac != "FF:FF:FF:FF:FF:FF",
                  addressSet.contains(entry.ip),
                  let v4 = IPv4Address(dottedString: entry.ip),
                  !v4.isMulticast else { continue }
            var host = found[entry.ip] ?? DiscoveredHost(
                ip: entry.ip, hostname: nil, mac: nil, sshOpen: false
            )
            host.mac = mac
            if let name = entry.hostname { host.hostname = name }
            found[entry.ip] = host
        }
        for ip in openSSH {
            var host = found[ip] ?? DiscoveredHost(ip: ip, hostname: nil, mac: nil, sshOpen: false)
            host.sshOpen = true
            found[ip] = host
        }
        publishSorted(found)
        phase = .done

        // Reverse-DNS pass: rows update in place as names resolve.
        let ips = hosts.map(\.ip)
        await withTaskGroup(of: (String, String?).self) { group in
            for ip in ips {
                group.addTask { (ip, await Self.resolveHostname(ip, timeout: Self.dnsTimeout)) }
            }
            for await (ip, name) in group {
                guard !Task.isCancelled else { return }
                guard let name,
                      let index = hosts.firstIndex(where: { $0.ip == ip }),
                      hosts[index].hostname == nil else { continue }
                hosts[index].hostname = name
            }
        }
    }

    private func publishSorted(_ found: [String: DiscoveredHost]) {
        hosts = found.values.sorted {
            (IPv4Address(dottedString: $0.ip)?.raw ?? 0) < (IPv4Address(dottedString: $1.ip)?.raw ?? 0)
        }
    }

    // MARK: - Interface enumeration

    /// getifaddrs walk → IPv4 subnets of up-and-running non-loopback
    /// interfaces. Interfaces sharing a scan block (rare double-homing) are
    /// deduplicated by their effective scan base.
    nonisolated static func localSubnets() -> [LocalSubnet] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var subnets: [LocalSubnet] = []
        var seenBases: Set<UInt32> = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = ifa.pointee.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0,
                  (flags & UInt32(IFF_RUNNING)) != 0,
                  (flags & UInt32(IFF_LOOPBACK)) == 0,
                  let addr = ifa.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = ifa.pointee.ifa_netmask,
                  mask.pointee.sa_family == UInt8(AF_INET) else { continue }

            let ipRaw = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let maskRaw = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let subnet = LocalSubnet(
                interfaceName: String(cString: ifa.pointee.ifa_name),
                address: IPv4Address(raw: ipRaw),
                netmask: IPv4Address(raw: maskRaw)
            )
            guard let base = subnet.scanBlockBase, seenBases.insert(base.raw).inserted
            else { continue }
            subnets.append(subnet)
        }
        return subnets
    }

    // MARK: - Port 22 probe

    /// Probes port 22 on every address with bounded concurrency. Returns the
    /// set of IPs where the connect succeeded. Every attempt — success or
    /// refusal — also makes the kernel ARP the target, which is what the
    /// post-sweep `arp -an` harvests.
    nonisolated static func probeSSHPorts(
        _ addresses: [String],
        progress: @escaping @Sendable (Int) -> Void
    ) async -> Set<String> {
        await withTaskGroup(of: String?.self) { group in
            var open: Set<String> = []
            var next = 0
            var done = 0
            while next < addresses.count && next < maxConcurrentProbes {
                let ip = addresses[next]
                group.addTask { await probeOne(ip, timeout: probeTimeout) }
                next += 1
            }
            while let result = await group.next() {
                done += 1
                if let ip = result { open.insert(ip) }
                progress(done)
                if next < addresses.count {
                    let ip = addresses[next]
                    group.addTask { await probeOne(ip, timeout: probeTimeout) }
                    next += 1
                }
            }
            return open
        }
    }

    /// Returns the IP when port 22 accepted a TCP connection, nil otherwise
    /// (refused, filtered, or timed out).
    nonisolated private static func probeOne(_ ip: String, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            let box = ResumeBox(continuation)
            let connection = NWConnection(host: NWEndpoint.Host(ip), port: .ssh, using: .tcp)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.resume(ip)
                    connection.cancel()
                case .failed:
                    box.resume(nil)
                default:
                    // .waiting = no route yet; let the timeout decide.
                    break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                box.resume(nil)
                connection.cancel()
            }
        }
    }

    // MARK: - ARP table

    /// `-an`: numeric output — arp's own reverse lookups are unbounded and a
    /// slow resolver could eat the whole process timeout; we resolve names
    /// ourselves under a per-host budget instead.
    nonisolated static func readARPTable() async -> [ArpEntry] {
        let candidates = ["/usr/sbin/arp", "/sbin/arp"]
        guard let path = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return [] }
        let output = await AuxProcess.run(argv: [path, "-an"], timeout: 5)
        return ArpTableParser.parse(output.stdoutText)
    }

    // MARK: - Reverse DNS

    /// getnameinfo(NI_NAMEREQD) raced against a timeout. The blocking C call
    /// runs on a GCD queue (never the cooperative pool, so a stuck resolver
    /// can't starve Swift Concurrency); whichever side fires first wins.
    nonisolated static func resolveHostname(_ ip: String, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            let box = ResumeBox(continuation)
            DispatchQueue.global(qos: .utility).async {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else {
                    box.resume(nil)
                    return
                }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let rc = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        getnameinfo(
                            sa, socklen_t(MemoryLayout<sockaddr_in>.size),
                            &host, socklen_t(host.count), nil, 0, NI_NAMEREQD
                        )
                    }
                }
                guard rc == 0 else {
                    box.resume(nil)
                    return
                }
                let name = String(decoding: host.prefix(while: { $0 != 0 }).map {
                    UInt8(bitPattern: $0)
                }, as: UTF8.self)
                box.resume(name.isEmpty ? nil : name)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                box.resume(nil)
            }
        }
    }
}

/// Lock-guarded resume-once wrapper so a completion path and a timeout path
/// can race without double-resuming a continuation (which crashes). Shared by
/// the scanner and GeoIP hostname resolution.
final class ResumeBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}
