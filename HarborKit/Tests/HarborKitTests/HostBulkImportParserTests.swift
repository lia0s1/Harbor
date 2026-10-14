import XCTest
@testable import HarborKit

final class HostBulkImportParserTests: XCTestCase {
    private func parse(_ text: String, existing: [SSHHost] = []) -> HostBulkImportParser.Result {
        HostBulkImportParser.parse(text, existing: existing)
    }

    func testSimpleHostLine() {
        let result = parse("example.com")
        XCTAssertEqual(result.lines.count, 1)
        let line = result.lines[0]
        XCTAssertEqual(line.status, .ok)
        XCTAssertEqual(line.host?.hostname, "example.com")
        XCTAssertEqual(line.host?.port, SSHHost.defaultPort)
        XCTAssertEqual(line.host?.username, "")
        XCTAssertTrue(line.host?.name.isEmpty ?? false)
    }

    func testFullLineWithUserPortAndName() {
        let result = parse("root@1.2.3.4:2222 生产 Web")
        XCTAssertEqual(result.lines[0].status, .ok)
        let host = result.lines[0].host
        XCTAssertEqual(host?.username, "root")
        XCTAssertEqual(host?.hostname, "1.2.3.4")
        XCTAssertEqual(host?.port, 2222)
        XCTAssertEqual(host?.name, "生产 Web")
    }

    func testTabSeparatedName() {
        let result = parse("example.com\t标签名")
        XCTAssertEqual(result.lines[0].status, .ok)
        XCTAssertEqual(result.lines[0].host?.name, "标签名")
    }

    func testBlankAndCommentLinesAreSkipped() {
        let result = parse("\n# comment\n   \nexample.com\n")
        XCTAssertEqual(result.lines.count, 5)
        XCTAssertEqual(result.lines[0].status, .skipped)
        XCTAssertEqual(result.lines[1].status, .skipped)
        XCTAssertEqual(result.lines[2].status, .skipped)
        XCTAssertEqual(result.lines[3].status, .ok)
        XCTAssertEqual(result.lines[4].status, .skipped) // trailing newline
    }

    func testCRLFLineEndings() {
        let result = parse("a.com\r\nb.com:2222\r\n")
        XCTAssertEqual(result.lines[0].status, .ok)
        XCTAssertEqual(result.lines[0].host?.hostname, "a.com")
        XCTAssertEqual(result.lines[1].status, .ok)
        XCTAssertEqual(result.lines[1].host?.port, 2222)
    }

    func testDuplicateAgainstExisting() {
        let existing = [SSHHost(hostname: "Example.COM", port: 22)]
        let result = parse("example.com", existing: existing)
        XCTAssertEqual(result.lines[0].status, .duplicateExisting)
    }

    func testDuplicateWithinBatch() {
        let result = parse("a.com\nA.COM\na.com:22")
        XCTAssertEqual(result.lines[0].status, .ok)
        XCTAssertEqual(result.lines[1].status, .duplicateBatch)
        // "a.com:22" normalizes to port 22 — still the same target.
        XCTAssertEqual(result.lines[2].status, .duplicateBatch)
    }

    func testDifferentPortIsNotDuplicate() {
        let result = parse("a.com\na.com:2222")
        XCTAssertEqual(result.lines[0].status, .ok)
        XCTAssertEqual(result.lines[1].status, .ok)
    }

    func testInvalidPort() {
        let result = parse("a.com:99999")
        XCTAssertEqual(result.lines[0].status, .invalid(.invalidPort("99999")))
    }

    func testInvalidHostLeadingDash() {
        let result = parse("-oProxyCommand=evil")
        guard case .invalid(.invalidHost) = result.lines[0].status else {
            return XCTFail("expected invalidHost, got \(result.lines[0].status)")
        }
    }

    func testEmptyUserBeforeAt() {
        let result = parse("@host.com")
        guard case .invalid(.invalidUser) = result.lines[0].status else {
            return XCTFail("expected invalidUser, got \(result.lines[0].status)")
        }
    }

    func testNameTooLong() {
        let longName = String(repeating: "x", count: HostBulkImportParser.maxNameLength + 1)
        let result = parse("a.com \(longName)")
        XCTAssertEqual(result.lines[0].status, .invalid(.nameTooLong))
    }

    func testIPv6BracketWithPortAndName() {
        let result = parse("[2001:db8::1]:2222 v6 box")
        XCTAssertEqual(result.lines[0].status, .ok)
        XCTAssertEqual(result.lines[0].host?.hostname, "2001:db8::1")
        XCTAssertEqual(result.lines[0].host?.port, 2222)
        XCTAssertEqual(result.lines[0].host?.name, "v6 box")
    }

    func testBareIPv6WithoutBrackets() {
        let result = parse("2001:db8::1")
        XCTAssertEqual(result.lines[0].status, .ok)
        XCTAssertEqual(result.lines[0].host?.hostname, "2001:db8::1")
        XCTAssertEqual(result.lines[0].host?.port, SSHHost.defaultPort)
    }

    func testOverflowLinesAreCountedNotParsed() {
        let many = (1...1200).map { "host\($0).example.com" }.joined(separator: "\n")
        let result = parse(many)
        XCTAssertEqual(result.lines.count, HostBulkImportParser.maxLines)
        XCTAssertEqual(result.overflowLines, 200)
        XCTAssertEqual(result.okCount, HostBulkImportParser.maxLines)
    }

    func testCountsAndAcceptedHosts() {
        let existing = [SSHHost(hostname: "dup.com", port: 22)]
        let result = parse("""
        one.com 一
        dup.com
        bad:99999
        # note
        two.com
        """, existing: existing)
        XCTAssertEqual(result.okCount, 2)
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertEqual(result.invalidCount, 1)
        XCTAssertEqual(result.acceptedHosts.map(\.hostname), ["one.com", "two.com"])
        XCTAssertEqual(result.acceptedHosts[0].name, "一")
    }

    func testLineNumbersTrackSource() {
        let result = parse("# c\n\na.com\nb.com")
        XCTAssertEqual(result.lines.map(\.lineNumber), [1, 2, 3, 4])
    }
}
