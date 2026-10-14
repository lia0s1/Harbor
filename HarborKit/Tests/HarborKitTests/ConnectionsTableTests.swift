import XCTest
@testable import HarborKit

final class ConnectionsTableTests: XCTestCase {
    /// Realistic `ss -tupnH` output as root: attributed and bare rows, all
    /// common states, IPv4 + bracketed IPv6, scoped address, wildcard peers.
    private let fixture = """
    tcp   ESTAB      0      0      192.168.1.5:22      198.51.100.7:51100   users:(("sshd",pid=812,fd=4))
    tcp   TIME-WAIT  0      0      192.168.1.5:443     203.0.113.9:60001
    udp   UNCONN     0      0      127.0.0.53%lo:53    0.0.0.0:*            users:(("systemd-resolve",pid=410,fd=12))
    tcp   LISTEN     0      128    0.0.0.0:22          0.0.0.0:*            users:(("sshd",pid=812,fd=3))
    tcp   ESTAB      0      0      [fd00::1]:5222      [fd00::9]:443       users:(("java",pid=2201,fd=120))
    udp   ESTAB      0      0      10.0.0.5:12345      8.8.8.8:53
    tcp   CLOSE-WAIT 0      0      192.168.1.5:8443    203.0.113.9:55000   users:(("nginx",pid=1001,fd=9))
    """

    func testParsesAllRows() {
        let conns = SSConnectionsParser.parse(fixture)
        XCTAssertEqual(conns.count, 7)
    }

    func testTCPv4WithProcess() {
        let conn = SSConnectionsParser.parse(fixture).first { $0.localPort == 22 && $0.state == "ESTAB" }
        XCTAssertEqual(conn?.proto, "tcp")
        XCTAssertEqual(conn?.localAddress, "192.168.1.5")
        XCTAssertEqual(conn?.peerAddress, "198.51.100.7")
        XCTAssertEqual(conn?.peerPort, 51100)
        XCTAssertEqual(conn?.process, "sshd")
        XCTAssertEqual(conn?.pid, 812)
        XCTAssertEqual(conn?.peerDescription, "198.51.100.7:51100")
    }

    func testUnattributedRowKeepsEmptyProcess() {
        let conn = SSConnectionsParser.parse(fixture).first { $0.state == "TIME-WAIT" }
        XCTAssertNotNil(conn)
        XCTAssertEqual(conn?.process, "")
        XCTAssertEqual(conn?.pid, 0)
    }

    func testWildcardPeerParsesToZeroPort() {
        let listen = SSConnectionsParser.parse(fixture).first { $0.state == "LISTEN" }
        XCTAssertEqual(listen?.peerAddress, "0.0.0.0")
        XCTAssertEqual(listen?.peerPort, 0)
        XCTAssertEqual(listen?.peerDescription, "—")
    }

    func testIPv6BracketsStripped() {
        let conn = SSConnectionsParser.parse(fixture).first { $0.localAddress.contains("fd00") }
        XCTAssertEqual(conn?.localAddress, "fd00::1")
        XCTAssertEqual(conn?.peerAddress, "fd00::9")
        XCTAssertEqual(conn?.peerPort, 443)
        XCTAssertEqual(conn?.process, "java")
    }

    func testUDPParsed() {
        let conn = SSConnectionsParser.parse(fixture).first { $0.proto == "udp" && $0.state == "ESTAB" }
        XCTAssertEqual(conn?.peerAddress, "8.8.8.8")
        XCTAssertEqual(conn?.peerPort, 53)
    }

    func testSkipsHeaderLine() {
        let withHeader = "Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n" + fixture
        let conns = SSConnectionsParser.parse(withHeader)
        XCTAssertEqual(conns.count, 7)
        XCTAssertFalse(conns.contains { $0.state == "State" })
    }

    func testEmptyAndGarbage() {
        XCTAssertTrue(SSConnectionsParser.parse("").isEmpty)
        XCTAssertTrue(SSConnectionsParser.parse("\n \n").isEmpty)
        XCTAssertTrue(SSConnectionsParser.parse("nothing to see here").isEmpty)
    }

    func testGroupByState() {
        let groups = SSConnectionsParser.groupByState(SSConnectionsParser.parse(fixture))
        XCTAssertEqual(groups.first { $0.label == "ESTAB" }?.count, 3)
        XCTAssertEqual(groups.first { $0.label == "TIME-WAIT" }?.count, 1)
        XCTAssertEqual(groups.first { $0.label == "LISTEN" }?.count, 1)
        XCTAssertEqual(groups.first { $0.label == "UNCONN" }?.count, 1)
        XCTAssertEqual(groups.first { $0.label == "CLOSE-WAIT" }?.count, 1)
        // Sorted most-common-first.
        XCTAssertEqual(groups.first?.label, "ESTAB")
    }

    func testGroupByPeerExcludesWildcardPeers() {
        let conns = SSConnectionsParser.parse(fixture)
        let groups = SSConnectionsParser.groupByPeer(conns)
        // 203.0.113.9 appears twice (TIME-WAIT + CLOSE-WAIT) → top talker.
        XCTAssertEqual(groups.first?.label, "203.0.113.9")
        XCTAssertEqual(groups.first?.count, 2)
        // Wildcard/empty peers (LISTEN, UNCONN rows) never aggregate.
        XCTAssertFalse(groups.contains { $0.label == "0.0.0.0" || $0.label == "*" || $0.label.isEmpty })
        XCTAssertEqual(groups.reduce(0) { $0 + $1.count }, 5) // only connected rows
    }

    func testGroupByStateStableOnTies() {
        let conns = [
            ConnectionEntry(proto: "tcp", state: "TIME-WAIT", localAddress: "10.0.0.1", localPort: 1, peerAddress: "10.0.0.2", peerPort: 2, process: "", pid: 0),
            ConnectionEntry(proto: "tcp", state: "ESTAB", localAddress: "10.0.0.1", localPort: 3, peerAddress: "10.0.0.2", peerPort: 4, process: "", pid: 0),
        ]
        let groups = SSConnectionsParser.groupByState(conns)
        XCTAssertEqual(groups.map(\.label), ["ESTAB", "TIME-WAIT"]) // alphabetical tie-break
    }
}
