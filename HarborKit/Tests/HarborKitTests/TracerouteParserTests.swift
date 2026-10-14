import XCTest
@testable import HarborKit

final class TracerouteParserTests: XCTestCase {
    func testSingleProbeLine() {
        let hop = TracerouteParser.parseLine(" 1  192.168.1.1  1.234 ms")
        XCTAssertEqual(hop?.number, 1)
        XCTAssertEqual(hop?.address, "192.168.1.1")
        XCTAssertEqual(hop?.rttMs ?? [], [1.234])
        XCTAssertEqual(hop?.bestRttMs ?? -1, 1.234, accuracy: 0.0001)
        XCTAssertFalse(hop?.isLoss ?? true)
    }

    func testThreeProbeLine() {
        let hop = TracerouteParser.parseLine(" 2  10.0.0.1  2.123 ms  2.456 ms  2.345 ms")
        XCTAssertEqual(hop?.rttMs ?? [], [2.123, 2.456, 2.345])
        XCTAssertEqual(hop?.bestRttMs ?? -1, 2.123, accuracy: 0.0001)
    }

    func testDifferentRespondersOnOneHop() {
        // A later probe answered by a different router: first address wins,
        // all RTTs collected.
        let hop = TracerouteParser.parseLine(" 5  1.2.3.4  10.5 ms  5.6.7.8  11.25 ms")
        XCTAssertEqual(hop?.address, "1.2.3.4")
        XCTAssertEqual(hop?.rttMs ?? [], [10.5, 11.25])
    }

    func testAllStarsIsLoss() {
        let hop = TracerouteParser.parseLine(" 3  *")
        XCTAssertEqual(hop?.number, 3)
        XCTAssertEqual(hop?.address, "")
        XCTAssertTrue(hop?.rttMs.isEmpty ?? false)
        XCTAssertTrue(hop?.isLoss ?? false)
        let threeStars = TracerouteParser.parseLine(" 3  * * *")
        XCTAssertTrue(threeStars?.isLoss ?? false)
    }

    func testMixedStarAndReply() {
        let hop = TracerouteParser.parseLine(" 4  *  10.0.0.1  5.5 ms")
        XCTAssertEqual(hop?.address, "10.0.0.1")
        XCTAssertEqual(hop?.rttMs ?? [], [5.5])
    }

    func testReachabilityAnnotation() {
        // "ms !H" — the annotation must not break RTT parsing.
        let hop = TracerouteParser.parseLine(" 4  172.16.0.1  20.5 ms !H")
        XCTAssertEqual(hop?.address, "172.16.0.1")
        XCTAssertEqual(hop?.rttMs ?? [], [20.5])
    }

    func testHeaderAndGarbageReturnNil() {
        XCTAssertNil(TracerouteParser.parseLine("traceroute to 1.1.1.1 (1.1.1.1), 30 hops max, 60 byte packets"))
        XCTAssertNil(TracerouteParser.parseLine(""))
        XCTAssertNil(TracerouteParser.parseLine("traceroute: unknown host nope"))
    }

    func testIPv6Hop() {
        let hop = TracerouteParser.parseLine(" 2  2001:db8::1  3.5 ms")
        XCTAssertEqual(hop?.address, "2001:db8::1")
        XCTAssertEqual(hop?.rttMs ?? [], [3.5])
    }

    func testParseWholeText() {
        let text = """
        traceroute to 1.1.1.1 (1.1.1.1), 30 hops max, 60 byte packets
         1  192.168.1.1  1.2 ms
         2  *
         3  10.10.0.1  5.1 ms
        """
        let hops = TracerouteParser.parse(text)
        XCTAssertEqual(hops.map(\.number), [1, 2, 3])
        XCTAssertTrue(hops[1].isLoss)
    }
}
