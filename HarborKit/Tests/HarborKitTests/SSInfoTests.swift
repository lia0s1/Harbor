import XCTest
@testable import HarborKit

final class SSInfoTests: XCTestCase {
    /// Realistic `ss -ni` sample (Ubuntu 22.04 / iproute2 5.15 shape):
    /// header, ESTAB with full tcp_info, ESTAB with retrans, TIME-WAIT with
    /// no info line, LISTEN, UDP UNCONN, and an IPv6 connection.
    private let fixture = """
    State      Recv-Q   Send-Q    Local Address:Port     Peer Address:Port   Process
    ESTAB      0        0         192.168.1.10:22        203.0.113.5:51234
    \t skmem:(r0,rb369280,t0,tb87040,f4096,w0,o0,bl0,d38) ts sack cubic wscale:8,7 rto:208 rtt:4.662/2.331 ato:40 mss:1448 pmtu:1500 rcvmss:536 advmss:1448 cwnd:10 bytes_sent:18250 bytes_acked:18251 bytes_received:4021 segs_out:96 segs_in:77 data_segs_out:94 data_segs_in:76 send 24.9Mbps lastsnd:404 lastrcv:404 lastack:4 pacing_rate 49.7Mbps delivery_rate 24.9Mbps delivered:95 app_limited busy:404ms rcv_rtt:6.25 rcv_space:29200 rcv_ssthresh:64076 minrtt:4.662
    ESTAB      0        52        10.0.0.5:443           198.51.100.20:443
    \t ts sack cubic wscale:7,7 rto:240 rtt:36.5/18.2 ato:40 mss:1460 cwnd:10 ssthresh:7 bytes_sent:123456 bytes_retrans:3120 bytes_acked:120336 segs_out:200 segs_in:180 data_segs_out:150 data_segs_in:120 send 3.2Mbps lastsnd:120 lastrcv:120 lastack:100 pacing_rate 6.4Mbps delivery_rate 3.0Mbps delivered:151 busy:500ms retrans:0/4 dsack_dups:1 rcv_rtt:40 rcv_space:14600 minrtt:20.1
    TIME-WAIT  0        0         192.168.1.10:443       203.0.113.9:60001
    LISTEN     0        4096      0.0.0.0:8080           0.0.0.0:*
    UNCONN     0        0         127.0.0.53%lo:53       0.0.0.0:*
    ESTAB      0        0         [fd00::1]:22           [fd00::7]:51100
    \t cubic wscale:7,7 rto:204 rtt:12.3/4.5 ato:40 mss:1448 cwnd:10 retrans:0/3 bytes_sent:1000 bytes_acked:1001 segs_out:20 segs_in:15 data_segs_out:18 data_segs_in:12
    """

    // MARK: - parse

    func testParsesEveryConnectionRow() {
        let conns = SSInfoParser.parse(fixture)
        XCTAssertEqual(conns.count, 6)
        XCTAssertEqual(conns.map(\.state), ["ESTAB", "ESTAB", "TIME-WAIT", "LISTEN", "UNCONN", "ESTAB"])
    }

    func testSkipsHeaderLine() {
        let conns = SSInfoParser.parse(fixture)
        XCTAssertFalse(conns.contains { $0.state == "State" })
    }

    func testFullTCPInfoExtraction() {
        let conn = SSInfoParser.parse(fixture).first { $0.peerPort == 443 }
        XCTAssertNotNil(conn)
        XCTAssertEqual(conn?.rttMs ?? -1, 36.5, accuracy: 0.0001)
        XCTAssertEqual(conn?.rttVarMs ?? -1, 18.2, accuracy: 0.0001)
        XCTAssertEqual(conn?.rtoMs ?? -1, 240, accuracy: 0.0001)
        XCTAssertEqual(conn?.retransCurrent, 0)
        XCTAssertEqual(conn?.retransTotal, 4)
        XCTAssertEqual(conn?.bytesSent, 123456)
        XCTAssertEqual(conn?.bytesRetransmitted, 3120)
        XCTAssertEqual(conn?.bytesAcked, 120336)
        XCTAssertEqual(conn?.segsOut, 200)
        XCTAssertEqual(conn?.congestionWindow, 10)
        XCTAssertTrue(conn?.hasTCPInfo ?? false)
    }

    func testMissingRetransFieldStaysNil() {
        // ss only prints retrans:/bytes_retrans: once non-zero — the first
        // ESTAB row has neither.
        let conn = SSInfoParser.parse(fixture).first { $0.peerPort == 51234 }
        XCTAssertNil(conn?.retransTotal)
        XCTAssertNil(conn?.bytesRetransmitted)
        XCTAssertEqual(conn?.effectiveRetransTotal, 0)
        XCTAssertEqual(conn?.rttMs ?? -1, 4.662, accuracy: 0.0001)
        XCTAssertTrue(conn?.hasTCPInfo ?? false)
    }

    func testTimeWaitWithoutInfoLine() {
        let conn = SSInfoParser.parse(fixture).first { $0.state == "TIME-WAIT" }
        XCTAssertNotNil(conn)
        XCTAssertNil(conn?.rttMs)
        XCTAssertNil(conn?.retransTotal)
        XCTAssertFalse(conn?.hasTCPInfo ?? true)
    }

    func testIPv6BracketsStripped() {
        let conn = SSInfoParser.parse(fixture).first { $0.localAddress.contains("fd00") }
        XCTAssertEqual(conn?.localAddress, "fd00::1")
        XCTAssertEqual(conn?.peerAddress, "fd00::7")
        XCTAssertEqual(conn?.localPort, 22)
        XCTAssertEqual(conn?.rttMs ?? -1, 12.3, accuracy: 0.0001)
        XCTAssertEqual(conn?.retransTotal, 3)
    }

    func testListenPeerWildcardPortIsZero() {
        let conn = SSInfoParser.parse(fixture).first { $0.state == "LISTEN" }
        XCTAssertEqual(conn?.peerAddress, "0.0.0.0")
        XCTAssertEqual(conn?.peerPort, 0)
    }

    func testInterfaceScopedAddressKept() {
        let conn = SSInfoParser.parse(fixture).first { $0.state == "UNCONN" }
        XCTAssertEqual(conn?.localAddress, "127.0.0.53%lo")
    }

    func testGarbageAndEmpty() {
        XCTAssertTrue(SSInfoParser.parse("").isEmpty)
        XCTAssertTrue(SSInfoParser.parse("\n\n").isEmpty)
        XCTAssertTrue(SSInfoParser.parse("total garbage\nno colons here").isEmpty)
        // Header-only (live host with zero connections) is a valid empty parse.
        XCTAssertTrue(SSInfoParser.parse("State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n").isEmpty)
    }

    func testUnixSocketRowsDropped() {
        // `ss -ni` without -t can include unix rows; their paths have no
        // numeric port and must not enter the connection list.
        let unix = """
        u_str ESTAB 0 0 /run/systemd/journal/stdout 12345 * 0
        u_str ESTAB 0 0 * 12346 * 0
        """
        XCTAssertTrue(SSInfoParser.parse(unix).isEmpty)
    }

    func testSplitEndpoint() {
        XCTAssertEqual(SSInfoParser.splitEndpoint("192.168.1.1:22")?.0, "192.168.1.1")
        XCTAssertEqual(SSInfoParser.splitEndpoint("192.168.1.1:22")?.1, 22)
        XCTAssertEqual(SSInfoParser.splitEndpoint("[::1]:443")?.0, "::1")
        XCTAssertEqual(SSInfoParser.splitEndpoint("0.0.0.0:*")?.1, 0)
        XCTAssertNil(SSInfoParser.splitEndpoint("/run/socket/path"))
        XCTAssertNil(SSInfoParser.splitEndpoint("host:https")) // named port slipped past -n
        XCTAssertNil(SSInfoParser.splitEndpoint("host:70000"))
    }

    // MARK: - qualityReport

    /// Builds a minimal info-bearing connection for diff tests.
    private func conn(
        local: String = "10.0.0.1:22", peer: String = "10.0.0.2:5000",
        rtt: Double? = 10, retrans: Int? = 0, segs: UInt64? = 100,
        sent: UInt64? = 10_000, retransBytes: UInt64? = 0
    ) -> TCPConnectionInfo {
        let l = SSInfoParser.splitEndpoint(local)!
        let p = SSInfoParser.splitEndpoint(peer)!
        return TCPConnectionInfo(
            state: "ESTAB",
            localAddress: l.0, localPort: l.1, peerAddress: p.0, peerPort: p.1,
            rttMs: rtt, retransTotal: retrans,
            bytesSent: sent, bytesRetransmitted: retransBytes, segsOut: segs
        )
    }

    func testDeltaComputesRetransAndRate() {
        let before = [conn(retrans: 4, segs: 200, sent: 123456, retransBytes: 3120)]
        let after = [conn(retrans: 7, segs: 260, sent: 123456 + 6000, retransBytes: 3120 + 1200)]
        let report = SSInfoParser.qualityReport(previous: before, current: after, intervalSeconds: 3)
        XCTAssertEqual(report.retransDelta, 3)
        XCTAssertEqual(report.segsOutDelta, 60)
        XCTAssertEqual(report.retransRatePercent ?? -1, 5.0, accuracy: 0.0001)
        XCTAssertEqual(report.bytesRetransDelta, 1200)
        XCTAssertEqual(report.bytesSentDelta, 6000)
        XCTAssertEqual(report.byteRetransRatePercent ?? -1, 20.0, accuracy: 0.0001)
        XCTAssertEqual(report.retransHotspots.count, 1)
        XCTAssertEqual(report.retransHotspots.first?.retransDelta, 3)
    }

    func testMissingRetransFieldCountsAsZeroInDelta() {
        // First sample never retransmitted (field absent), second did.
        let before = [conn(retrans: nil)]
        let after = [conn(retrans: 2)]
        let report = SSInfoParser.qualityReport(previous: before, current: after, intervalSeconds: 3)
        XCTAssertEqual(report.retransDelta, 2)
    }

    func testCounterRegressionClampsToZero() {
        // 4-tuple reused by a fresh connection between samples: counters must
        // not go negative.
        let before = [conn(retrans: 9, segs: 500)]
        let after = [conn(retrans: 1, segs: 10)]
        let report = SSInfoParser.qualityReport(previous: before, current: after, intervalSeconds: 3)
        XCTAssertEqual(report.retransDelta, 0)
        XCTAssertEqual(report.segsOutDelta, 0)
        XCTAssertNil(report.retransRatePercent) // nothing sent → no rate
        XCTAssertTrue(report.retransHotspots.isEmpty)
    }

    func testNewConnectionHasNoDelta() {
        let before = [conn(peer: "10.0.0.2:5000")]
        let after = [conn(peer: "10.0.0.2:5000"), conn(peer: "10.0.0.3:6000", retrans: 5)]
        let report = SSInfoParser.qualityReport(previous: before, current: after, intervalSeconds: 3)
        XCTAssertEqual(report.retransDelta, 0)
        XCTAssertEqual(report.connectionCount, 2)
        XCTAssertEqual(report.establishedCount, 2)
    }

    func testRTTSummary() {
        let current = [
            conn(peer: "10.0.0.2:1", rtt: 10),
            conn(peer: "10.0.0.2:2", rtt: 20),
            conn(peer: "10.0.0.2:3", rtt: nil),
        ]
        let report = SSInfoParser.qualityReport(previous: [], current: current, intervalSeconds: 3)
        XCTAssertEqual(report.averageRttMs ?? -1, 15, accuracy: 0.0001)
        XCTAssertEqual(report.maxRttMs ?? -1, 20, accuracy: 0.0001)
    }

    func testNoByteCountersGivesNilByteRate() {
        let before = [conn(sent: nil, retransBytes: nil)]
        let after = [conn(retrans: 1, segs: 150, sent: nil, retransBytes: nil)]
        let report = SSInfoParser.qualityReport(previous: before, current: after, intervalSeconds: 3)
        XCTAssertNil(report.byteRetransRatePercent)
        XCTAssertEqual(report.retransRatePercent ?? -1, 2.0, accuracy: 0.0001)
    }

    func testHotspotsSortedWorstFirst() {
        let before = [
            conn(peer: "10.0.0.2:1", retrans: 0, segs: 100),
            conn(peer: "10.0.0.2:2", retrans: 0, segs: 100),
        ]
        let after = [
            conn(peer: "10.0.0.2:1", retrans: 2, segs: 200),
            conn(peer: "10.0.0.2:2", retrans: 9, segs: 150),
        ]
        let report = SSInfoParser.qualityReport(previous: before, current: after, intervalSeconds: 3)
        XCTAssertEqual(report.retransHotspots.map(\.retransDelta), [9, 2])
        XCTAssertEqual(report.retransDelta, 11)
    }

    func testNonTCPRowsExcludedFromCounts() {
        let udp = TCPConnectionInfo(
            state: "UNCONN", localAddress: "127.0.0.53%lo", localPort: 53,
            peerAddress: "0.0.0.0", peerPort: 0
        )
        let report = SSInfoParser.qualityReport(previous: [], current: [udp, conn()], intervalSeconds: 3)
        XCTAssertEqual(report.connectionCount, 1)
    }

    func testDoubleSampleScriptShape() {
        let script = SSInfoParser.doubleSampleScript(separator: "@@HARBOR@@")
        XCTAssertTrue(script.hasPrefix(SSInfoParser.command))
        XCTAssertTrue(script.contains("; sleep 3; echo @@HARBOR@@; "))
        XCTAssertEqual(script.components(separatedBy: SSInfoParser.command).count, 3)
    }
}
