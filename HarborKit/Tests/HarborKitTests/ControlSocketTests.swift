import XCTest
@testable import HarborKit

final class ControlSocketTests: XCTestCase {

    func testFileNameMatchesKnownSHA1Prefix() {
        // shasum -a1 of "alice@example.com:22" = c8226096af42e418ec34b7135c1cd2e0e79902fe
        XCTAssertEqual(
            ControlSocket.fileName(username: "alice", hostname: "example.com", port: 22),
            "cm-c8226096af42e418"
        )
        // shasum -a1 of "root@10.0.0.5:2222" = af1ed46d97a18aafcdf339ee962e4f4c9dfd1cc7
        XCTAssertEqual(
            ControlSocket.fileName(username: "root", hostname: "10.0.0.5", port: 2222),
            "cm-af1ed46d97a18aaf"
        )
    }

    func testEmptyUsernameIsStillDeterministic() {
        // shasum -a1 of "@example.com:22" = b1cd0782c6fa7b0f66b7f65829057640760e8a98
        XCTAssertEqual(
            ControlSocket.fileName(username: "", hostname: "example.com", port: 22),
            "cm-b1cd0782c6fa7b0f"
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
        XCTAssertEqual(ControlSocket.fileName(for: clean), "cm-c8226096af42e418")
    }

    func testDiscriminatorProducesDistinctDeterministicName() {
        let base = ControlSocket.fileName(username: "alice", hostname: "example.com", port: 22)
        let a = ControlSocket.fileName(
            username: "alice", hostname: "example.com", port: 22, discriminator: "tab-2"
        )
        let b = ControlSocket.fileName(
            username: "alice", hostname: "example.com", port: 22, discriminator: "tab-3"
        )
        // shasum -a1 of "alice@example.com:22#tab-2" prefix check via determinism:
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
