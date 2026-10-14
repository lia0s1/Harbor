import XCTest
@testable import HarborKit

final class HostFolderStoreCodecTests: XCTestCase {
    func testRoundTripPreservesFields() throws {
        let folders = [
            HostFolder(id: UUID(), name: "生产", order: 0),
            HostFolder(id: UUID(), name: "Web Servers", order: 1),
        ]
        let data = try HostFolderStoreCodec.encode(folders)
        let decoded = try HostFolderStoreCodec.decode(data)
        XCTAssertEqual(decoded, folders)
    }

    func testEmptyRoundTrip() throws {
        let data = try HostFolderStoreCodec.encode([])
        XCTAssertEqual(try HostFolderStoreCodec.decode(data), [])
    }

    func testDecodeBareArray() throws {
        let folder = HostFolder(name: "bare", order: 3)
        let data = try JSONEncoder().encode([folder])
        XCTAssertEqual(try HostFolderStoreCodec.decode(data), [folder])
    }

    func testDecodeDocumentRequiresFoldersKey() {
        // A structurally valid object without "folders" is corruption, not an
        // empty store — and must not silently decode as one.
        XCTAssertThrowsError(try HostFolderStoreCodec.decode(Data(#"{"version":1}"#.utf8)))
    }

    func testCorruptDataThrows() {
        XCTAssertThrowsError(try HostFolderStoreCodec.decode(Data("not json".utf8)))
    }

    func testTolerantDecodeDefaultsMissingFields() throws {
        // A hand-edited entry missing name/order must still decode.
        let id = UUID()
        let json = #"{"folders":[{"id":""# + id.uuidString + #""}]}"#
        let decoded = try HostFolderStoreCodec.decode(Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.id, id)
        XCTAssertEqual(decoded.first?.name, "")
        XCTAssertEqual(decoded.first?.order, 0)
    }

    func testMalformedIDFallsBackToFreshUUID() throws {
        let json = #"{"folders":[{"id":"not-a-uuid","name":"x","order":1}]}"#
        let decoded = try HostFolderStoreCodec.decode(Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.name, "x")
        XCTAssertNotEqual(decoded.first?.id.uuidString, "not-a-uuid")
    }

    func testHostFolderIDRoundTripsThroughHostStoreCodec() throws {
        // hosts.json written before folders existed must load unchanged, and
        // a set folderID must survive an encode/decode round trip.
        var host = SSHHost(hostname: "example.com")
        let folderID = UUID()
        host.folderID = folderID
        let data = try HostStoreCodec.encode([host])
        let decoded = try HostStoreCodec.decode(data)
        XCTAssertEqual(decoded.first?.folderID, folderID)

        let legacy = Data(#"{"hosts":[{"hostname":"old.example.com"}]}"#.utf8)
        let legacyDecoded = try HostStoreCodec.decode(legacy)
        XCTAssertNil(legacyDecoded.first?.folderID)
    }
}
