import XCTest
@testable import HarborKit

final class HostStoreCodecTests: XCTestCase {

    func testRoundTrip() throws {
        let hosts = [
            SSHHost(
                name: "Prod",
                hostname: "prod.example.com",
                port: 2222,
                username: "deploy",
                identityFile: "~/.ssh/id_ed25519",
                extraArgs: ["-v"],
                portForwards: [PortForward(kind: .local, bindPort: 8080, targetHost: "db", targetPort: 5432)],
                tags: ["work"],
                notes: "primary box"
            ),
            SSHHost(name: "Pi", hostname: "raspberrypi.local", username: "pi")
        ]
        let data = try HostStoreCodec.encode(hosts)
        let decoded = try HostStoreCodec.decode(data)
        XCTAssertEqual(decoded, hosts)
    }

    func testEncodingIsPrettyPrinted() throws {
        let data = try HostStoreCodec.encode([SSHHost(hostname: "h")])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\n"), "expected pretty-printed JSON")
        XCTAssertTrue(text.contains("\"version\""))
    }

    func testDecodingBareArrayIsAccepted() throws {
        let json = """
        [{"id":"00000000-0000-0000-0000-000000000001","hostname":"legacy.example.com"}]
        """
        let hosts = try HostStoreCodec.decode(Data(json.utf8))
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts.first?.hostname, "legacy.example.com")
        XCTAssertEqual(hosts.first?.port, 22)
    }

    func testDecodingMissingOptionalFieldsUsesDefaults() throws {
        let json = """
        {"version":1,"hosts":[{"hostname":"min.example.com"}]}
        """
        let hosts = try HostStoreCodec.decode(Data(json.utf8))
        XCTAssertEqual(hosts.first?.hostname, "min.example.com")
        XCTAssertEqual(hosts.first?.port, 22)
        XCTAssertEqual(hosts.first?.extraArgs, [])
        XCTAssertEqual(hosts.first?.tags, [])
    }

    func testDecodingGarbageThrows() {
        XCTAssertThrowsError(try HostStoreCodec.decode(Data("not json".utf8)))
    }

    func testDecodingObjectMissingHostsKeyThrows() {
        // A structurally-valid object that lacks `hosts` is corruption, not an
        // empty store: it must THROW so the app layer preserves the file aside
        // instead of silently overwriting it with an empty list.
        XCTAssertThrowsError(try HostStoreCodec.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try HostStoreCodec.decode(Data(#"{"version":1}"#.utf8)))
    }

    func testDecodingExplicitlyEmptyHostsListIsAccepted() throws {
        // A genuinely empty store (what `encode([])` produces) round-trips fine.
        let hosts = try HostStoreCodec.decode(Data(#"{"version":1,"hosts":[]}"#.utf8))
        XCTAssertTrue(hosts.isEmpty)
        XCTAssertEqual(try HostStoreCodec.decode(HostStoreCodec.encode([])), [])
    }

    func testMalformedUUIDInOneEntryDoesNotDropAllHosts() throws {
        // A present-but-invalid id falls back to a fresh UUID for that one entry
        // rather than failing the whole file decode (which would lose every host).
        let json = """
        {"version":1,"hosts":[{"id":"not-a-uuid","hostname":"h1"},{"id":"00000000-0000-0000-0000-000000000002","hostname":"h2"}]}
        """
        let hosts = try HostStoreCodec.decode(Data(json.utf8))
        XCTAssertEqual(hosts.map(\.hostname), ["h1", "h2"])
        // The good id survives; the bad one was replaced with a generated id.
        XCTAssertEqual(hosts[1].id, UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        XCTAssertNotEqual(hosts[0].id, hosts[1].id)
    }

    func testForwardCompatibilityIgnoresUnknownKeysAndHigherVersion() throws {
        // A file written by a newer build (higher version + unknown keys) still
        // loads in an older build; JSONDecoder ignores unknown keys.
        let json = """
        {"version":99,"futureFlag":true,"hosts":[{"hostname":"h","newField":42}]}
        """
        let hosts = try HostStoreCodec.decode(Data(json.utf8))
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts.first?.hostname, "h")
    }
}
