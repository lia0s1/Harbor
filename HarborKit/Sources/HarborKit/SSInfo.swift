import Foundation

/// One TCP (or other IP) connection from `ss -ni`, with the kernel's
/// tcp_info metrics attached when the continuation line carries them.
/// Fields past the 4-tuple are optionals: old kernels lack `bytes_*`/`segs_*`,
/// LISTEN rows have no info line at all, and `retrans`/`bytes_retrans` are
/// only printed once they are non-zero.
public struct TCPConnectionInfo: Equatable, Sendable, Identifiable {
    /// State as `ss` prints it: "ESTAB", "TIME-WAIT", "LISTEN", "UNCONN"…
    public let state: String
    public let localAddress: String
    public let localPort: Int
    public let peerAddress: String
    /// 0 for an unconnected peer (`0.0.0.0:*`).
    public let peerPort: Int
    /// Smoothed RTT from `rtt:<rtt>/<rttvar>`, milliseconds.
    public let rttMs: Double?
    /// RTT variance (the second half of `rtt:`), milliseconds.
    public let rttVarMs: Double?
    /// Retransmission timeout from `rto:`, milliseconds.
    public let rtoMs: Double?
    /// Currently-retransmitting segments (first half of `retrans:cur/total`).
    public let retransCurrent: Int?
    /// Cumulative retransmitted segments since connect (second half of
    /// `retrans:cur/total`). Missing on connections that never retransmitted —
    /// treat as 0 for deltas (ss only prints the field once it is non-zero).
    public let retransTotal: Int?
    public let bytesSent: UInt64?
    /// From `bytes_retrans:`; like `retransTotal`, only printed when non-zero.
    public let bytesRetransmitted: UInt64?
    public let bytesAcked: UInt64?
    /// From `segs_out:` — cumulative segments sent, the denominator for the
    /// segment retransmission rate.
    public let segsOut: UInt64?
    public let congestionWindow: Int?

    public init(
        state: String,
        localAddress: String, localPort: Int,
        peerAddress: String, peerPort: Int,
        rttMs: Double? = nil, rttVarMs: Double? = nil, rtoMs: Double? = nil,
        retransCurrent: Int? = nil, retransTotal: Int? = nil,
        bytesSent: UInt64? = nil, bytesRetransmitted: UInt64? = nil,
        bytesAcked: UInt64? = nil, segsOut: UInt64? = nil,
        congestionWindow: Int? = nil
    ) {
        self.state = state
        self.localAddress = localAddress; self.localPort = localPort
        self.peerAddress = peerAddress; self.peerPort = peerPort
        self.rttMs = rttMs; self.rttVarMs = rttVarMs; self.rtoMs = rtoMs
        self.retransCurrent = retransCurrent; self.retransTotal = retransTotal
        self.bytesSent = bytesSent; self.bytesRetransmitted = bytesRetransmitted
        self.bytesAcked = bytesAcked; self.segsOut = segsOut
        self.congestionWindow = congestionWindow
    }

    public var id: String { key }

    /// Match key across the two quality samples. State is excluded on purpose:
    /// a connection flipping ESTAB → TIME-WAIT between the samples is still the
    /// same flow and its counters must keep diffing.
    public var key: String {
        "\(localAddress):\(localPort)>\(peerAddress):\(peerPort)"
    }

    /// True when the kernel attached tcp_info — i.e. this is a real TCP socket,
    /// not a UDP row or a bare LISTEN without an info line. Quality metrics are
    /// computed over these only.
    public var hasTCPInfo: Bool {
        rttMs != nil || retransTotal != nil || segsOut != nil || bytesSent != nil
    }

    /// Retrans counter with ss's print-only-when-nonzero quirk folded in.
    public var effectiveRetransTotal: Int { retransTotal ?? 0 }
    public var effectiveBytesRetransmitted: UInt64 { bytesRetransmitted ?? 0 }
}

/// Per-connection counter delta between the two `ss -ni` samples. Only emitted
/// for connections present in both samples; counter regressions (4-tuple reuse)
/// clamp to 0 instead of going negative.
public struct TCPConnectionDelta: Equatable, Sendable, Identifiable {
    public let connection: TCPConnectionInfo
    public let retransDelta: Int
    public let segsOutDelta: UInt64
    public let bytesRetransDelta: UInt64
    public let bytesSentDelta: UInt64

    public init(
        connection: TCPConnectionInfo,
        retransDelta: Int,
        segsOutDelta: UInt64,
        bytesRetransDelta: UInt64,
        bytesSentDelta: UInt64
    ) {
        self.connection = connection
        self.retransDelta = retransDelta
        self.segsOutDelta = segsOutDelta
        self.bytesRetransDelta = bytesRetransDelta
        self.bytesSentDelta = bytesSentDelta
    }

    public var id: String { connection.key }

    /// Segment retransmission rate over the sample window, percent; nil when
    /// nothing was sent (no meaningful denominator).
    public var retransRatePercent: Double? {
        guard segsOutDelta > 0 else { return nil }
        return Double(retransDelta) / Double(segsOutDelta) * 100
    }
}

/// Aggregated result of FinalShell's double-sample `ss -ni` probe: how healthy
/// the host's TCP connections are, derived from two snapshots `intervalSeconds`
/// apart.
public struct TCPQualityReport: Equatable, Sendable {
    /// Seconds between the two samples (the remote `sleep`).
    public let intervalSeconds: Double
    /// Info-bearing (real TCP) connections in the second sample.
    public let connectionCount: Int
    /// …of which ESTAB.
    public let establishedCount: Int
    /// Mean / worst smoothed RTT across connections that report one, ms.
    public let averageRttMs: Double?
    public let maxRttMs: Double?
    /// Segments retransmitted / sent during the window, summed over all
    /// connections present in both samples.
    public let retransDelta: Int
    public let segsOutDelta: UInt64
    /// 100 × retransDelta / segsOutDelta; nil when nothing was sent.
    public let retransRatePercent: Double?
    public let bytesRetransDelta: UInt64
    public let bytesSentDelta: UInt64
    /// Byte-level retransmission rate for kernels/reporting paths where segment
    /// counters exist; nil when no byte counters were seen.
    public let byteRetransRatePercent: Double?
    /// Connections whose retrans counter moved during the window, worst first.
    public let retransHotspots: [TCPConnectionDelta]

    public init(
        intervalSeconds: Double,
        connectionCount: Int,
        establishedCount: Int,
        averageRttMs: Double?,
        maxRttMs: Double?,
        retransDelta: Int,
        segsOutDelta: UInt64,
        retransRatePercent: Double?,
        bytesRetransDelta: UInt64,
        bytesSentDelta: UInt64,
        byteRetransRatePercent: Double?,
        retransHotspots: [TCPConnectionDelta]
    ) {
        self.intervalSeconds = intervalSeconds
        self.connectionCount = connectionCount
        self.establishedCount = establishedCount
        self.averageRttMs = averageRttMs
        self.maxRttMs = maxRttMs
        self.retransDelta = retransDelta
        self.segsOutDelta = segsOutDelta
        self.retransRatePercent = retransRatePercent
        self.bytesRetransDelta = bytesRetransDelta
        self.bytesSentDelta = bytesSentDelta
        self.byteRetransRatePercent = byteRetransRatePercent
        self.retransHotspots = retransHotspots
    }
}

/// Pure parser/differ for `ss -ni` (TCP sockets with tcp_info). The remote
/// command runs twice with a `sleep` between; both samples come back in one
/// `@@HARBOR@@`-separated payload, so there is exactly one aux round-trip and
/// no SFTP side-channel (FinalShell's tar.gz dance is unnecessary here).
public enum SSInfoParser {
    /// Seconds between the two samples. 3s mirrors FinalShell and is long
    /// enough for slow-path retransmits to move the counters.
    public static let sampleIntervalSeconds: Double = 3

    /// The one-shot command. `-n` numeric (no DNS stalls), `-i` tcp_info.
    /// `LC_ALL=C` keeps tokens stable. stderr dropped: a missing `ss` must
    /// yield empty stdout so the caller can tell "ss absent" from "no
    /// connections" (a live ss always prints at least its header).
    public static let command = "LC_ALL=C ss -ni 2>/dev/null"

    /// The full double-sample script: sample, remote sleep, separator, sample.
    public static func doubleSampleScript(separator: String) -> String {
        "\(command); sleep \(Int(sampleIntervalSeconds)); echo \(separator); \(command)"
    }

    /// Parses one `ss -ni` sample. Connection rows are the non-indented lines
    /// with numeric Recv-Q/Send-Q columns (this skips the header); every
    /// following indented line is that connection's tcp_info continuation.
    /// Unix-domain rows (paths, no numeric port) and other non-IP shapes drop
    /// out at the address split.
    public static func parse(_ text: String) -> [TCPConnectionInfo] {
        var result: [TCPConnectionInfo] = []
        var current: TCPConnectionInfo?
        var infoText = ""

        func flush() {
            guard var conn = current else { return }
            applyInfo(infoText, to: &conn)
            result.append(conn)
            current = nil
            infoText = ""
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.first == " " || line.first == "\t" {
                // tcp_info continuation of the current connection.
                if current != nil { infoText += " " + line }
                continue
            }
            flush()
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // State Recv-Q Send-Q Local:Port Peer:Port [Process]
            guard fields.count >= 5,
                  UInt64(fields[1]) != nil, UInt64(fields[2]) != nil,
                  let (localAddress, localPort) = splitEndpoint(fields[3]),
                  let (peerAddress, peerPort) = splitEndpoint(fields[4])
            else { continue }
            current = TCPConnectionInfo(
                state: fields[0],
                localAddress: localAddress, localPort: localPort,
                peerAddress: peerAddress, peerPort: peerPort
            )
        }
        flush()
        return result
    }

    /// Diffs two samples into a quality report. Only connections whose 4-tuple
    /// appears in both samples contribute counters; single-sample connections
    /// (new/closed in the window) still count toward the totals but have no
    /// delta.
    public static func qualityReport(
        previous: [TCPConnectionInfo],
        current: [TCPConnectionInfo],
        intervalSeconds: Double
    ) -> TCPQualityReport {
        let tcp = current.filter { $0.hasTCPInfo }
        let previousByKey = Dictionary(previous.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        var deltas: [TCPConnectionDelta] = []
        deltas.reserveCapacity(tcp.count)
        var retransDelta = 0
        var segsOutDelta: UInt64 = 0
        var bytesRetransDelta: UInt64 = 0
        var bytesSentDelta: UInt64 = 0
        var anyByteCounters = false

        for conn in tcp {
            guard let before = previousByKey[conn.key] else { continue }
            let retrans = conn.effectiveRetransTotal >= before.effectiveRetransTotal
                ? conn.effectiveRetransTotal - before.effectiveRetransTotal : 0
            retransDelta += retrans
            var segs: UInt64 = 0
            if let now = conn.segsOut, let then = before.segsOut {
                segs = now >= then ? now - then : 0
                segsOutDelta += segs
            }
            var bytesRetrans: UInt64 = 0
            var bytesSent: UInt64 = 0
            if let now = conn.bytesSent, let then = before.bytesSent {
                bytesSent = now >= then ? now - then : 0
                bytesSentDelta += bytesSent
                anyByteCounters = true
            }
            let nowR = conn.effectiveBytesRetransmitted
            let thenR = before.effectiveBytesRetransmitted
            bytesRetrans = nowR >= thenR ? nowR - thenR : 0
            bytesRetransDelta += bytesRetrans
            if conn.bytesRetransmitted != nil || before.bytesRetransmitted != nil { anyByteCounters = true }

            deltas.append(TCPConnectionDelta(
                connection: conn,
                retransDelta: retrans,
                segsOutDelta: segs,
                bytesRetransDelta: bytesRetrans,
                bytesSentDelta: bytesSent
            ))
        }

        let rtts = tcp.compactMap(\.rttMs)
        let hotspots = deltas
            .filter { $0.retransDelta > 0 }
            .sorted {
                if $0.retransDelta != $1.retransDelta { return $0.retransDelta > $1.retransDelta }
                if $0.segsOutDelta != $1.segsOutDelta { return $0.segsOutDelta > $1.segsOutDelta }
                return $0.connection.key < $1.connection.key
            }
            .prefix(50)

        return TCPQualityReport(
            intervalSeconds: intervalSeconds,
            connectionCount: tcp.count,
            establishedCount: tcp.filter { $0.state == "ESTAB" || $0.state == "ESTABLISHED" }.count,
            averageRttMs: rtts.isEmpty ? nil : rtts.reduce(0, +) / Double(rtts.count),
            maxRttMs: rtts.max(),
            retransDelta: retransDelta,
            segsOutDelta: segsOutDelta,
            retransRatePercent: segsOutDelta > 0
                ? Double(retransDelta) / Double(segsOutDelta) * 100 : nil,
            bytesRetransDelta: bytesRetransDelta,
            bytesSentDelta: bytesSentDelta,
            byteRetransRatePercent: anyByteCounters && bytesSentDelta > 0
                ? Double(bytesRetransDelta) / Double(bytesSentDelta) * 100 : nil,
            retransHotspots: Array(hotspots)
        )
    }

    // MARK: - tcp_info token extraction

    /// Picks the metrics we chart out of the free-form tcp_info continuation:
    /// `rtt:12.3/4.5`, `rto:204`, `retrans:0/3`, `bytes_sent:N`,
    /// `bytes_retrans:N`, `bytes_acked:N`, `segs_out:N`, `cwnd:N`.
    private static func applyInfo(_ text: String, to conn: inout TCPConnectionInfo) {
        guard !text.isEmpty else { return }
        var rtt: Double?, rttVar: Double?, rto: Double?
        var retransCur: Int?, retransTotal: Int?
        var bytesSent: UInt64?, bytesRetrans: UInt64?, bytesAcked: UInt64?
        var segsOut: UInt64?, cwnd: Int?
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            guard let colon = token.firstIndex(of: ":") else { continue }
            let name = token[..<colon]
            let value = token[token.index(after: colon)...]
            switch name {
            case "rtt":
                let halves = value.split(separator: "/", maxSplits: 1)
                if let first = halves.first, let v = Double(first), v.isFinite, v >= 0 { rtt = v }
                if halves.count > 1, let v = Double(halves[1]), v.isFinite, v >= 0 { rttVar = v }
            case "rto":
                if let v = Double(value), v.isFinite, v >= 0 { rto = v }
            case "retrans":
                let halves = value.split(separator: "/", maxSplits: 1)
                if let first = halves.first { retransCur = Int(first) }
                if halves.count > 1 { retransTotal = Int(halves[1]) }
            case "bytes_sent": bytesSent = UInt64(value)
            case "bytes_retrans": bytesRetrans = UInt64(value)
            case "bytes_acked": bytesAcked = UInt64(value)
            case "segs_out": segsOut = UInt64(value)
            case "cwnd": cwnd = Int(value)
            default: break
            }
        }
        conn = TCPConnectionInfo(
            state: conn.state,
            localAddress: conn.localAddress, localPort: conn.localPort,
            peerAddress: conn.peerAddress, peerPort: conn.peerPort,
            rttMs: rtt, rttVarMs: rttVar, rtoMs: rto,
            retransCurrent: retransCur, retransTotal: retransTotal,
            bytesSent: bytesSent, bytesRetransmitted: bytesRetrans,
            bytesAcked: bytesAcked, segsOut: segsOut,
            congestionWindow: cwnd
        )
    }

    /// Splits an `ss` endpoint into (address, port). IPv6 brackets are
    /// stripped; a `*` port (unconnected/listen peer) becomes 0. Returns nil
    /// for unix-socket paths and other shapes without a numeric-or-`*` port.
    static func splitEndpoint(_ token: String) -> (String, Int)? {
        guard let lastColon = token.lastIndex(of: ":") else { return nil }
        var host = String(token[..<lastColon])
        let portToken = String(token[token.index(after: lastColon)...])
        let port: Int
        if portToken == "*" {
            port = 0
        } else if let parsed = Int(portToken), parsed >= 0, parsed <= 65535 {
            port = parsed
        } else {
            return nil
        }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return (host, port)
    }
}
