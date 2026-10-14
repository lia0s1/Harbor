import XCTest
@testable import HarborKit

final class ArpTableParserTests: XCTestCase {
    /// Real macOS `arp -a` shape: named and unresolved hosts, an incomplete
    /// entry, mDNS multicast, and the subnet broadcast.
    private let macOSFixture = """
    ? (192.168.1.1) at 0:11:32:1a:2b:3c on en0 ifscope [ethernet]
    router.lan (192.168.1.5) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]
    ? (192.168.1.9) at (incomplete) on en0 ifscope [ethernet]
    ? (192.168.1.255) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
    ? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]
    """

    func testParsesAllRows() {
        let entries = ArpTableParser.parse(macOSFixture)
        XCTAssertEqual(entries.count, 5)
    }

    func testUnresolvedNameBecomesNilHostname() {
        let entries = ArpTableParser.parse(macOSFixture)
        let gateway = entries.first { $0.ip == "192.168.1.1" }
        XCTAssertNil(gateway?.hostname)
        XCTAssertEqual(gateway?.interfaceName, "en0")
    }

    func testNamedHostKeepsHostname() {
        let entries = ArpTableParser.parse(macOSFixture)
        let router = entries.first { $0.ip == "192.168.1.5" }
        XCTAssertEqual(router?.hostname, "router.lan")
    }

    /// macOS prints MAC octets without leading zeros; we normalize to
    /// uppercase zero-padded form for display.
    func testMACNormalizedToPaddedUppercase() {
        let entries = ArpTableParser.parse(macOSFixture)
        XCTAssertEqual(entries.first { $0.ip == "192.168.1.1" }?.mac, "00:11:32:1A:2B:3C")
        XCTAssertEqual(entries.first { $0.ip == "192.168.1.5" }?.mac, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(entries.first { $0.ip == "224.0.0.251" }?.mac, "01:00:5E:00:00:FB")
    }

    func testIncompleteEntryHasNilMAC() {
        let entries = ArpTableParser.parse(macOSFixture)
        let incomplete = entries.first { $0.ip == "192.168.1.9" }
        XCTAssertNotNil(incomplete)
        XCTAssertNil(incomplete?.mac)
    }

    /// `arp -an` (numeric) never resolves names — the whole table uses "?".
    func testNumericOutput() {
        let entries = ArpTableParser.parse("""
        ? (10.0.0.1) at 12:34:56:78:9a:bc on en1 ifscope [ethernet]
        ? (10.0.0.2) at (incomplete) on en1 ifscope [ethernet]
        """)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].hostname, nil)
        XCTAssertEqual(entries[0].mac, "12:34:56:78:9A:BC")
        XCTAssertEqual(entries[0].interfaceName, "en1")
        XCTAssertNil(entries[1].mac)
    }

    func testGarbageLinesDropped() {
        let entries = ArpTableParser.parse("""
        total verbosity of nothing
        ? (not-an-ip) at 0:11:22:33:44:55 on en0 ifscope [ethernet]
        ? (192.168.1.7) at zz:11:22:33:44:55 on en0 ifscope [ethernet]
        ? (192.168.1.8) at 0:11:22:33:44 on en0 ifscope [ethernet]

        ? (192.168.1.10) at 0:11:22:33:44:55 on en0 ifscope [ethernet]
        """)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.ip, "192.168.1.10")
    }

    func testEmptyInput() {
        XCTAssertTrue(ArpTableParser.parse("").isEmpty)
    }

    func testNormalizeMAC() {
        XCTAssertEqual(ArpTableParser.normalizeMAC("0:0:0:0:0:0"), "00:00:00:00:00:00")
        XCTAssertEqual(ArpTableParser.normalizeMAC("ff:ff:ff:ff:ff:ff"), "FF:FF:FF:FF:FF:FF")
        XCTAssertNil(ArpTableParser.normalizeMAC("0:11:22:33:44"))
        XCTAssertNil(ArpTableParser.normalizeMAC("0:11:22:33:44:55:66"))
        XCTAssertNil(ArpTableParser.normalizeMAC("(incomplete)"))
        XCTAssertNil(ArpTableParser.normalizeMAC(""))
    }
}
