import XCTest
@testable import HarborKit

final class ControlSocketTests: XCTestCase {

    func testFileNameMatchesKnownSHA256Prefix() {
        // shasum -a 256 of "alice@example.com:22" = ca189eebce1a7f6dd62a918797f8f611a3b4968a6e481f100c6ed53e71ed11c8
        XCTAssertEqual(
            ControlSocket.fileName(username: "alice", hostname: "example.com", port: 22),
            "cm-ca189eebce1a7f6d"
        )
        // shasum -a 256 of "root@10.0.0.5:2222" = 2e00a8e8bd7e2416a0a9712093b428b4bddb0d5be873f7bdc0071c942be7727e
        XCTAssertEqual(
            ControlSocket.fileName(username: "root", hostname: "10.0.0.5", port: 2222),
            "cm-2e00a8e8bd7e2416"
        )
    }

    func testEmptyUsernameIsStillDeterministic() {
        // shasum -a 256 of "@example.com:22" = 50f34de5f6cac084e170744b42ccce5ae4169cb60ea0dfc7891aa9847d0868a9
        XCTAssertEqual(
            ControlSocket.fileName(username: "", hostname: "example.com", port: 22),
            "cm-50f34de5f6cac084"
        )
    }

    func testFormatIsShortAndHex() {
        let name = ControlSocket.fileName(username: "u", hostname: "h", port: 22)
        XCTAssertTrue(name.hasPrefix("cm-"))
        XCTAssertEqual(name.count, 19) // "cm-" + 16 hex chars
        let hex = name.dropFirst(3)
        XCTAssertTrue(hex.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
    }

    func testDifferentEndpointsProduceDifferentNames() {
        let a = ControlSocket.fileName(username: "alice", hostname: "example.com", port: 22)
        let b = ControlSocket.fileName(username: "alice", hostname: "example.com", port: 23)
        let c = ControlSocket.fileName(username: "bob", hostname: "example.com", port: 22)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(b, c)
    }

    func testHostConvenienceTrimsLikeCommandBuilder() throws {
        let messy = SSHHost(hostname: " example.com ", username: " alice ")
        let clean = SSHHost(hostname: "example.com", username: "alice")
        XCTAssertEqual(ControlSocket.fileName(for: messy), ControlSocket.fileName(for: clean))
        XCTAssertEqual(ControlSocket.fileName(for: clean), "cm-ca189eebce1a7f6d")
    }

    func testDiscriminatorProducesDistinctDeterministicName() {
        let base = ControlSocket.fileName(username: "alice", hostname: "example.com", port: 22)
        let a = ControlSocket.fileName(
            username: "alice", hostname: "example.com", port: 22, discriminator: "tab-2"
        )
        let b = ControlSocket.fileName(
            username: "alice", hostname: "example.com", port: 22, discriminator: "tab-3"
        )
        // shasum -a 256 of "alice@example.com:22#tab-2" prefix check via determinism:
        XCTAssertEqual(
            a,
            ControlSocket.fileName(
                username: "alice", hostname: "example.com", port: 22, discriminator: "tab-2"
            )
        )
        XCTAssertNotEqual(a, base)
        XCTAssertNotEqual(b, base)
        XCTAssertNotEqual(a, b)
        // Same short format, so the socket path length never grows.
        XCTAssertTrue(a.hasPrefix("cm-"))
        XCTAssertEqual(a.count, 19)
    }

    func testNilOrEmptyDiscriminatorMatchesBaseName() {
        let base = ControlSocket.fileName(username: "alice", hostname: "example.com", port: 22)
        XCTAssertEqual(
            ControlSocket.fileName(
                username: "alice", hostname: "example.com", port: 22, discriminator: nil
            ),
            base
        )
        XCTAssertEqual(
            ControlSocket.fileName(
                username: "alice", hostname: "example.com", port: 22, discriminator: ""
            ),
            base
        )
        let host = SSHHost(hostname: "example.com", username: "alice")
        XCTAssertEqual(ControlSocket.fileName(for: host, discriminator: nil), base)
        XCTAssertNotEqual(ControlSocket.fileName(for: host, discriminator: "x"), base)
    }
}
