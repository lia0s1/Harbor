import XCTest
@testable import HarborKit

final class QuickCommandStoreCodecTests: XCTestCase {

    func testRoundTrip() throws {
        let commands = [
            QuickCommand(title: "Restart service", command: "systemctl restart {service}", group: "系统"),
            QuickCommand(title: "Disk usage", command: "df -h"),
            QuickCommand(command: "docker ps", group: "Docker"),
        ]
        let data = try QuickCommandStoreCodec.encode(commands)
        let decoded = try QuickCommandStoreCodec.decode(data)
        XCTAssertEqual(decoded, commands)
    }

    func testEncodingIsPrettyPrintedAndVersioned() throws {
        let data = try QuickCommandStoreCodec.encode([QuickCommand(command: "df -h")])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\n"), "expected pretty-printed JSON")
        XCTAssertTrue(text.contains("\"version\""))
        XCTAssertTrue(text.contains("\"commands\""))
    }

    func testDecodingBareArrayIsAccepted() throws {
        let json = """
        [{"id":"00000000-0000-0000-0000-000000000001","title":"legacy","command":"uptime"}]
        """
        let commands = try QuickCommandStoreCodec.decode(Data(json.utf8))
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.command, "uptime")
        XCTAssertEqual(commands.first?.title, "legacy")
    }

    func testDecodingMissingOptionalFieldsUsesDefaults() throws {
        let json = """
        {"version":1,"commands":[{"id":"00000000-0000-0000-0000-000000000002","command":"ls"}]}
        """
        let commands = try QuickCommandStoreCodec.decode(Data(json.utf8))
        XCTAssertEqual(commands.first?.command, "ls")
        XCTAssertEqual(commands.first?.title, "")
        XCTAssertEqual(commands.first?.group, "")
    }

    func testDecodingMissingIDGetsGenerated() throws {
        // Hand-edited JSON without an id still loads (a fresh UUID is assigned).
        let json = """
        {"version":1,"commands":[{"command":"uptime"}]}
        """
        let commands = try QuickCommandStoreCodec.decode(Data(json.utf8))
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.command, "uptime")
    }

    func testDecodingGarbageThrows() {
        XCTAssertThrowsError(try QuickCommandStoreCodec.decode(Data("not json".utf8)))
    }

    func testDecodingObjectMissingCommandsKeyThrows() {
        // An object lacking `commands` is corruption, not an empty list: throw
        // so the app layer preserves it aside instead of silently wiping it.
        XCTAssertThrowsError(try QuickCommandStoreCodec.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try QuickCommandStoreCodec.decode(Data(#"{"version":1}"#.utf8)))
    }

    func testDecodingExplicitlyEmptyCommandsListIsAccepted() throws {
        let commands = try QuickCommandStoreCodec.decode(Data(#"{"version":1,"commands":[]}"#.utf8))
        XCTAssertTrue(commands.isEmpty)
    }

    func testStarterCommandsAreUsableAndDistinct() {
        let starters = QuickCommandStoreCodec.starterCommands()
        XCTAssertFalse(starters.isEmpty)
        // All distinct ids and non-empty commands.
        XCTAssertEqual(Set(starters.map(\.id)).count, starters.count)
        XCTAssertTrue(starters.allSatisfy { !$0.command.isEmpty })
    }

    func testStarterCommandsRoundTrip() throws {
        let starters = QuickCommandStoreCodec.starterCommands()
        let data = try QuickCommandStoreCodec.encode(starters)
        XCTAssertEqual(try QuickCommandStoreCodec.decode(data), starters)
    }
}
