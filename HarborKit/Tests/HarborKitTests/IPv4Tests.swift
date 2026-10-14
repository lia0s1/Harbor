import XCTest
@testable import HarborKit

final class IPv4Tests: XCTestCase {
    // MARK: - Parsing

    func testParsesDottedQuad() {
        XCTAssertEqual(IPv4Address(dottedString: "192.168.1.10")?.raw, 0xC0A8_010A)
        XCTAssertEqual(IPv4Address(dottedString: "0.0.0.0")?.raw, 0)
        XCTAssertEqual(IPv4Address(dottedString: "255.255.255.255")?.raw, UInt32.max)
    }

    func testRoundTripsDottedString() {
        for string in ["1.2.3.4", "10.0.0.1", "172.16.254.200", "223.255.255.0"] {
            XCTAssertEqual(IPv4Address(dottedString: string)?.dottedString, string)
        }
    }

    func testRejectsMalformedAddresses() {
        let bad = [
            "", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1.2.3.256",
            "01.2.3.4", "1.2.3.a", " 1.2.3.4", "1.2.3.4 ", "-1.2.3.4",
            "1..2.3", "1.2.3.", ".1.2.3", "0x1.2.3.4", "1-2-3-4",
        ]
        for string in bad {
            XCTAssertNil(IPv4Address(dottedString: string), "should reject \(string)")
        }
    }

    func testComparable() {
        XCTAssertTrue(IPv4Address(dottedString: "192.168.1.9")! < IPv4Address(dottedString: "192.168.1.10")!)
        XCTAssertTrue(IPv4Address(dottedString: "9.0.0.1")! < IPv4Address(dottedString: "10.0.0.1")!)
    }

    // MARK: - Private / reserved judgment (GeoIP 内网 short-circuit)

    func testPrivateAndReservedRanges() {
        let private_ = [
            "0.0.0.0", "10.0.0.1", "10.255.255.255", "100.64.0.1",
            "100.127.255.255", "127.0.0.1", "127.255.255.254", "169.254.1.1",
            "172.16.0.1", "172.31.255.255", "192.0.2.1", "192.88.99.1",
            "192.168.0.1", "192.168.255.255", "198.18.0.1", "198.19.255.255",
            "198.51.100.1", "203.0.113.1", "224.0.0.1", "239.1.2.3",
            "240.0.0.1", "255.255.255.255",
        ]
        for string in private_ {
            XCTAssertTrue(
                IPv4Address(dottedString: string)!.isPrivateOrReserved,
                "\(string) should be private/reserved"
            )
        }
    }

    func testPublicRanges() {
        let public_ = [
            "1.1.1.1", "8.8.8.8", "11.0.0.1", "100.63.255.255", "100.128.0.1",
            "172.15.0.1", "172.32.0.1", "192.167.0.1", "193.0.0.1",
            "223.255.255.255",
        ]
        for string in public_ {
            XCTAssertFalse(
                IPv4Address(dottedString: string)!.isPrivateOrReserved,
                "\(string) should be public"
            )
        }
    }

    func testMulticast() {
        XCTAssertTrue(IPv4Address(dottedString: "224.0.0.251")!.isMulticast)
        XCTAssertFalse(IPv4Address(dottedString: "223.255.255.255")!.isMulticast)
    }

    // MARK: - Subnet math

    private func subnet(_ address: String, _ mask: String) -> LocalSubnet {
        LocalSubnet(
            interfaceName: "en0",
            address: IPv4Address(dottedString: address)!,
            netmask: IPv4Address(dottedString: mask)!
        )
    }

    func testPrefixLength() {
        XCTAssertEqual(subnet("192.168.1.10", "255.255.255.0").prefixLength, 24)
        XCTAssertEqual(subnet("10.0.0.5", "255.255.0.0").prefixLength, 16)
        XCTAssertEqual(subnet("10.0.0.5", "255.0.0.0").prefixLength, 8)
        XCTAssertEqual(subnet("10.0.0.5", "255.255.255.255").prefixLength, 32)
        XCTAssertEqual(subnet("10.0.0.5", "0.0.0.0").prefixLength, 0)
    }

    func testNonContiguousMaskRejected() {
        XCTAssertNil(subnet("10.0.0.5", "255.0.255.0").prefixLength)
        XCTAssertTrue(subnet("10.0.0.5", "255.0.255.0").scanAddresses.isEmpty)
    }

    func testSlash24ScansWholeSubnet() {
        let addresses = subnet("192.168.1.10", "255.255.255.0").scanAddresses
        XCTAssertEqual(addresses.count, 254)
        XCTAssertEqual(addresses.first?.dottedString, "192.168.1.1")
        XCTAssertEqual(addresses.last?.dottedString, "192.168.1.254")
        // Network and broadcast are excluded.
        XCTAssertFalse(addresses.contains(IPv4Address(dottedString: "192.168.1.0")!))
        XCTAssertFalse(addresses.contains(IPv4Address(dottedString: "192.168.1.255")!))
    }

    func testLargeSubnetTruncatesToSlash24AroundInterface() {
        // A /16 must not become a 65k-host sweep: scan only the interface's /24.
        let addresses = subnet("10.20.30.40", "255.255.0.0").scanAddresses
        XCTAssertEqual(addresses.count, 254)
        XCTAssertEqual(addresses.first?.dottedString, "10.20.30.1")
        XCTAssertEqual(addresses.last?.dottedString, "10.20.30.254")

        let twelve = subnet("172.16.5.200", "255.240.0.0").scanAddresses
        XCTAssertEqual(twelve.count, 254)
        XCTAssertTrue(twelve.allSatisfy { $0.dottedString.hasPrefix("172.16.5.") })
    }

    func testSmallSubnetHonoredAsIs() {
        let addresses = subnet("192.168.1.10", "255.255.255.128").scanAddresses
        XCTAssertEqual(addresses.count, 126)
        XCTAssertEqual(addresses.first?.dottedString, "192.168.1.1")
        XCTAssertEqual(addresses.last?.dottedString, "192.168.1.126")
    }

    func testSlash32ScansOnlyItself() {
        let addresses = subnet("192.168.1.10", "255.255.255.255").scanAddresses
        XCTAssertEqual(addresses, [IPv4Address(dottedString: "192.168.1.10")!])
    }

    func testSlash31PointToPoint() {
        let addresses = subnet("10.0.0.0", "255.255.255.254").scanAddresses
        XCTAssertEqual(addresses.map(\.dottedString), ["10.0.0.0", "10.0.0.1"])
    }

    func testScanBlockBaseDeduplicatesInterfaces() {
        XCTAssertEqual(
            subnet("192.168.1.10", "255.255.255.0").scanBlockBase,
            IPv4Address(dottedString: "192.168.1.0")
        )
        // Truncated /16 shares the /24 base with a plain /24 on the same block.
        XCTAssertEqual(
            subnet("192.168.1.10", "255.255.0.0").scanBlockBase,
            IPv4Address(dottedString: "192.168.1.0")
        )
        XCTAssertNil(subnet("10.0.0.5", "255.0.255.0").scanBlockBase)
    }
}
