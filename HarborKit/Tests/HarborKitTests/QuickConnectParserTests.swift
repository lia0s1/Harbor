import XCTest
@testable import HarborKit

final class QuickConnectParserTests: XCTestCase {

    func testBareHost() throws {
        let host = try QuickConnectParser.parse("example.com")
        XCTAssertEqual(host.hostname, "example.com")
        XCTAssertEqual(host.username, "")
        XCTAssertEqual(host.port, 22)
    }

    func testUserAtHost() throws {
        let host = try QuickConnectParser.parse("alice@example.com")
        XCTAssertEqual(host.hostname, "example.com")
        XCTAssertEqual(host.username, "alice")
        XCTAssertEqual(host.port, 22)
    }

    func testHostWithPort() throws {
        let host = try QuickConnectParser.parse("example.com:2222")
        XCTAssertEqual(host.hostname, "example.com")
        XCTAssertEqual(host.port, 2222)
    }

    func testUserHostAndPort() throws {
        let host = try QuickConnectParser.parse("alice@example.com:2222")
        XCTAssertEqual(host.username, "alice")
        XCTAssertEqual(host.hostname, "example.com")
        XCTAssertEqual(host.port, 2222)
    }

    func testWhitespaceIsTrimmed() throws {
        let host = try QuickConnectParser.parse("  alice@example.com:2222\n")
        XCTAssertEqual(host.username, "alice")
        XCTAssertEqual(host.hostname, "example.com")
        XCTAssertEqual(host.port, 2222)
    }

    func testIPv4Address() throws {
        let host = try QuickConnectParser.parse("10.0.0.5:2200")
        XCTAssertEqual(host.hostname, "10.0.0.5")
        XCTAssertEqual(host.port, 2200)
    }

    func testBareIPv6LiteralIsNotSplitOnColons() throws {
        let host = try QuickConnectParser.parse("fe80::1")
        XCTAssertEqual(host.hostname, "fe80::1")
        XCTAssertEqual(host.port, 22)
    }

    func testBracketedIPv6WithPort() throws {
        let host = try QuickConnectParser.parse("[2001:db8::1]:2222")
        XCTAssertEqual(host.hostname, "2001:db8::1") // brackets stripped
        XCTAssertEqual(host.port, 2222)
    }

    func testBracketedIPv6WithoutPort() throws {
        let host = try QuickConnectParser.parse("[::1]")
        XCTAssertEqual(host.hostname, "::1")
        XCTAssertEqual(host.port, 22)
    }

    func testUserAtBracketedIPv6WithPort() throws {
        let host = try QuickConnectParser.parse("alice@[fe80::1]:2200")
        XCTAssertEqual(host.username, "alice")
        XCTAssertEqual(host.hostname, "fe80::1")
        XCTAssertEqual(host.port, 2200)
    }

    func testBracketedIPv6InvalidPortThrows() {
        XCTAssertThrowsError(try QuickConnectParser.parse("[::1]:abc"))
        XCTAssertThrowsError(try QuickConnectParser.parse("[::1]:0"))
    }

    func testUnclosedBracketThrows() {
        XCTAssertThrowsError(try QuickConnectParser.parse("[::1")) { error in
            guard case QuickConnectError.invalidHost? = error as? QuickConnectError else {
                return XCTFail("expected invalidHost, got \(error)")
            }
        }
    }

    func testEmptyInputThrows() {
        XCTAssertThrowsError(try QuickConnectParser.parse("")) { error in
            XCTAssertEqual(error as? QuickConnectError, .empty)
        }
        XCTAssertThrowsError(try QuickConnectParser.parse("   \n"))
    }

    func testInvalidPortThrows() {
        XCTAssertThrowsError(try QuickConnectParser.parse("host:abc"))
        XCTAssertThrowsError(try QuickConnectParser.parse("host:0"))
        XCTAssertThrowsError(try QuickConnectParser.parse("host:99999"))
        XCTAssertThrowsError(try QuickConnectParser.parse("host:"))
    }

    func testEmptyUserThrows() {
        XCTAssertThrowsError(try QuickConnectParser.parse("@example.com"))
    }

    func testEmptyHostThrows() {
        XCTAssertThrowsError(try QuickConnectParser.parse("alice@"))
        XCTAssertThrowsError(try QuickConnectParser.parse("alice@:22"))
    }

    func testDashPrefixedHostThrows() {
        XCTAssertThrowsError(try QuickConnectParser.parse("-oProxyCommand=evil")) { error in
            guard case QuickConnectError.invalidHost? = error as? QuickConnectError else {
                return XCTFail("expected invalidHost, got \(error)")
            }
        }
    }

    func testDashPrefixedUserThrows() {
        XCTAssertThrowsError(try QuickConnectParser.parse("-bad@example.com")) { error in
            guard case QuickConnectError.invalidUser? = error as? QuickConnectError else {
                return XCTFail("expected invalidUser, got \(error)")
            }
        }
    }

    func testHostWithInteriorWhitespaceThrows() {
        XCTAssertThrowsError(try QuickConnectParser.parse("evil\thost"))
    }

    func testParsedHostBuildsValidSSHCommand() throws {
        let host = try QuickConnectParser.parse("alice@example.com:2222")
        let args = try SSHCommandBuilder.arguments(for: host)
        XCTAssertEqual(args.last, "alice@example.com")
        XCTAssertTrue(args.contains("2222"))
    }
}
