import Foundation
import os

/// One row of the full connection table from `ss -tupnH`: protocol, state,
/// both endpoints and the owning process when `ss` can attribute it (needs
/// root for other users' sockets — without it `process`/`pid` stay empty).
public struct ConnectionEntry: Equatable, Sendable, Identifiable {
    /// "tcp" or "udp" (the `tcp6`/`udp6` netids fold to the base name).
    public let proto: String
    /// `ss` state: ESTAB, TIME-WAIT, CLOSE-WAIT, LISTEN, UNCONN…
    public let state: String
    public let localAddress: String
    public let localPort: Int
    /// Peer address as printed (brackets stripped); "0.0.0.0"/"*"/"" for
    /// unconnected or listening sockets.
    public let peerAddress: String
    /// 0 for an unconnected peer (`*`).
    public let peerPort: Int
    /// First owning process name, or "" when unattributed.
    public let process: String
    /// First owning pid, or 0 when unknown.
    public let pid: Int

    public init(
        proto: String, state: String,
        localAddress: String, localPort: Int,
        peerAddress: String, peerPort: Int,
        process: String, pid: Int
    ) {
        self.proto = proto; self.state = state
        self.localAddress = localAddress; self.localPort = localPort
        self.peerAddress = peerAddress; self.peerPort = peerPort
        self.process = process; self.pid = pid
    }

    public var id: String {
        "\(proto)/\(state)/\(localAddress):\(localPort)>\(peerAddress):\(peerPort)#\(pid)"
    }

    /// Display string for the peer side; "—" when there is no peer.
    public var peerDescription: String {
        peerPort > 0 ? "\(peerAddress):\(peerPort)" : "—"
    }
}

/// One (label, count) aggregate row for the grouped summaries.
public struct ConnectionGroupCount: Equatable, Sendable, Identifiable {
    public let label: String
    public let count: Int
    public var id: String { label }
    public init(label: String, count: Int) {
        self.label = label; self.count = count
    }
}

/// Pure parser for the on-demand full connection table (`ss -tupnH`), the
/// sibling of `ListeningPortsParser` covering every state instead of just
/// listeners. Tolerates the header line (older iproute2 without `-H`),
/// IPv6 brackets, `%ifname` scopes, wildcard peers and missing process
/// attribution.
public enum SSConnectionsParser {
    /// `-t` tcp, `-u` udp, `-p` process, `-n` numeric, `-H` no header.
    /// Falls back to header-bearing `ss` on old iproute2 — the parser skips
    /// the header either way.
    public static let command =
        "LC_ALL=C ss -tupnH 2>/dev/null || LC_ALL=C ss -tupn 2>/dev/null"

    /// `users:(("name",pid=123,fd=4),…)` — first process name + pid.
    private static let procRegex: NSRegularExpression? = {
        do { return try NSRegularExpression(pattern: #"\"([^\"]+)\",pid=(\d+)"#) }
        catch {
            Logger().warning("SSConnectionsParser: procRegex compile failed: \(error.localizedDescription)")
            return nil
        }
    }()

    public static func parse(_ text: String) -> [ConnectionEntry] {
        var result: [ConnectionEntry] = []
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // Netid State Recv-Q Send-Q Local:Port Peer:Port [Process]
            guard fields.count >= 6 else { continue }
            let netid = fields[0].lowercased()
            guard netid == "tcp" || netid == "tcp6" || netid == "udp" || netid == "udp6"
            else { continue } // header ("Netid") or noise
            let proto = netid.hasPrefix("tcp") ? "tcp" : "udp"
            // Recv-Q/Send-Q must be numeric — drops any header variant that
            // happens to start with a lowercase netid-like word.
            guard UInt64(fields[2]) != nil, UInt64(fields[3]) != nil else { continue }
            guard let (localAddress, localPort) = SSInfoParser.splitEndpoint(fields[4]),
                  let (peerAddress, peerPort) = SSInfoParser.splitEndpoint(fields[5])
            else { continue }
            var process = ""
            var pid = 0
            if let procRegex {
                let nsLine = line as NSString
                if let match = procRegex.firstMatch(
                    in: line, range: NSRange(location: 0, length: nsLine.length)
                ) {
                    process = nsLine.substring(with: match.range(at: 1))
                    pid = Int(nsLine.substring(with: match.range(at: 2))) ?? 0
                }
            }
            result.append(ConnectionEntry(
                proto: proto, state: fields[1],
                localAddress: localAddress, localPort: localPort,
                peerAddress: peerAddress, peerPort: peerPort,
                process: process, pid: pid
            ))
        }
        return result
    }

    /// Per-state counts, most common first (ties alphabetical for stability).
    public static func groupByState(_ connections: [ConnectionEntry]) -> [ConnectionGroupCount] {
        var counts: [String: Int] = [:]
        for conn in connections { counts[conn.state, default: 0] += 1 }
        return counts
            .map { ConnectionGroupCount(label: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
    }

    /// Per-peer-address counts, busiest first. Unconnected/listening rows
    /// (wildcard or empty peer) are excluded — they have no conversation
    /// partner to aggregate.
    public static func groupByPeer(_ connections: [ConnectionEntry]) -> [ConnectionGroupCount] {
        var counts: [String: Int] = [:]
        for conn in connections {
            let peer = conn.peerAddress
            guard conn.peerPort > 0, !peer.isEmpty, peer != "*",
                  peer != "0.0.0.0", peer != "::"
            else { continue }
            counts[peer, default: 0] += 1
        }
        return counts
            .map { ConnectionGroupCount(label: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
    }
}
