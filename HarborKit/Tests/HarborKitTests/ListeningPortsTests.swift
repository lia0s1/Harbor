import XCTest
@testable import HarborKit

final class ListeningPortsTests: XCTestCase {
    // Real `ss -tulnpH` output (root: process attribution present).
    private let rootFixture = """
    tcp   LISTEN 0      128          0.0.0.0:22         0.0.0.0:*    users:(("sshd",pid=812,fd=3))
    tcp   LISTEN 0      511        127.0.0.1:6379       0.0.0.0:*    users:(("redis-server",pid=940,fd=6))
    tcp   LISTEN 0      128             [::]:22            [::]:*    users:(("sshd",pid=812,fd=4))
    tcp   LISTEN 0      4096       0.0.0.0:8080       0.0.0.0:*    users:(("java",pid=2201,fd=120),("java",pid=2201,fd=121))
    udp   UNCONN 0      0          0.0.0.0:68         0.0.0.0:*    users:(("dhclient",pid=600,fd=6))
    udp   UNCONN 0      0          127.0.0.53%lo:53   0.0.0.0:*    users:(("systemd-resolve",pid=410,fd=12))
    """

    func testParsesAllListeningSockets() {
        let ports = ListeningPortsParser.parse(rootFixture)
        XCTAssertEqual(ports.count, 6)
    }

    func testTCPv4WithProcess() {
        let ports = ListeningPortsParser.parse(rootFixture)
        let ssh = ports.first { $0.port == 22 && $0.address == "0.0.0.0" }
        XCTAssertEqual(ssh?.proto, "tcp")
        XCTAssertEqual(ssh?.process, "sshd")
        XCTAssertEqual(ssh?.pid, 812)
        XCTAssertTrue(ssh?.isWildcard ?? false)
    }

    func testLoopbackBindIsNotWildcard() {
        let ports = ListeningPortsParser.parse(rootFixture)
        let redis = ports.first { $0.port == 6379 }
        XCTAssertEqual(redis?.address, "127.0.0.1")
        XCTAssertEqual(redis?.process, "redis-server")
        XCTAssertFalse(redis?.isWildcard ?? true)
    }

    func testIPv6BracketsStripped() {
        let ports = ListeningPortsParser.parse(rootFixture)
        let v6 = ports.first { $0.address == "::" }
        XCTAssertNotNil(v6)
        XCTAssertEqual(v6?.port, 22)
        XCTAssertTrue(v6?.isWildcard ?? false)
    }

    func testMultiProcessTakesFirst() {
        let ports = ListeningPortsParser.parse(rootFixture)
        let java = ports.first { $0.port == 8080 }
        XCTAssertEqual(java?.process, "java")
        XCTAssertEqual(java?.pid, 2201)
    }

    func testUDPParsed() {
        let ports = ListeningPortsParser.parse(rootFixture)
        let dhcp = ports.first { $0.port == 68 }
        XCTAssertEqual(dhcp?.proto, "udp")
        XCTAssertEqual(dhcp?.process, "dhclient")
    }

    func testInterfaceScopedAddress() {
        // "127.0.0.53%lo" — the %lo scope stays part of the host token; the port
        // (after the LAST colon) is still extracted correctly.
        let ports = ListeningPortsParser.parse(rootFixture)
        let resolved = ports.first { $0.port == 53 }
        XCTAssertEqual(resolved?.process, "systemd-resolve")
        XCTAssertEqual(resolved?.address, "127.0.0.53%lo")
    }

    // Non-root: no process attribution, but ports still listed.
    func testNoProcessAttribution() {
        let fixture = """
        tcp   LISTEN 0      128          0.0.0.0:22         0.0.0.0:*
        tcp   LISTEN 0      511        127.0.0.1:5432       0.0.0.0:*
        """
        let ports = ListeningPortsParser.parse(fixture)
        XCTAssertEqual(ports.count, 2)
        XCTAssertEqual(ports.first?.process, "")
        XCTAssertEqual(ports.first?.pid, 0)
        XCTAssertEqual(ports.first?.port, 22)
    }

    // Header-bearing `ss -tulnp` (older iproute2 without -H).
    func testSkipsHeaderLine() {
        let fixture = """
        Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
        tcp   LISTEN 0      128          0.0.0.0:22         0.0.0.0:*    users:(("sshd",pid=812,fd=3))
        """
        let ports = ListeningPortsParser.parse(fixture)
        XCTAssertEqual(ports.count, 1)
        XCTAssertEqual(ports.first?.port, 22)
    }

    func testEmptyAndGarbage() {
        XCTAssertTrue(ListeningPortsParser.parse("").isEmpty)
        XCTAssertTrue(ListeningPortsParser.parse("\n\n   \n").isEmpty)
        XCTAssertTrue(ListeningPortsParser.parse("total garbage no colons").isEmpty)
    }

    func testWildcardStarAddress() {
        // Some ss builds print "*:5353" for udp wildcard.
        let fixture = """
        udp   UNCONN 0      0                *:5353             *:*    users:(("avahi-daemon",pid=700,fd=12))
        """
        let ports = ListeningPortsParser.parse(fixture)
        XCTAssertEqual(ports.first?.address, "*")
        XCTAssertEqual(ports.first?.port, 5353)
        XCTAssertTrue(ports.first?.isWildcard ?? false)
    }

    // MARK: - splitHostPort unit

    func testSplitHostPort() {
        XCTAssertEqual(ListeningPortsParser.splitHostPort("0.0.0.0:22")?.0, "0.0.0.0")
        XCTAssertEqual(ListeningPortsParser.splitHostPort("0.0.0.0:22")?.1, 22)
        XCTAssertEqual(ListeningPortsParser.splitHostPort("[::1]:631")?.0, "::1")
        XCTAssertEqual(ListeningPortsParser.splitHostPort("[::1]:631")?.1, 631)
        XCTAssertNil(ListeningPortsParser.splitHostPort("no-colon"))
        XCTAssertNil(ListeningPortsParser.splitHostPort("host:notaport"))
        XCTAssertNil(ListeningPortsParser.splitHostPort("host:70000"))
    }
}
