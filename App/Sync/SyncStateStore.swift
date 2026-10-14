import Foundation

/// Local sync bookkeeping, persisted at
/// ~/Library/Application Support/Harbor/sync-state.json (never in the sync
/// directory). The stores' models carry no timestamps, so this file is how a
/// later cycle learns which records changed (content hash mismatch), which
/// were deleted (present here, missing from the store), and when.
struct SyncRecordState: Codable, Sendable, Equatable {
    var modifiedAt: Date
    var deviceID: String
    var deletedAt: Date?
    /// SHA-256 hex of the canonical payload JSON; empty for tombstones.
    var contentHash: String
}

struct CollectionSyncState: Codable, Sendable, Equatable {
    /// Keyed by UUID uuidString.
    var records: [String: SyncRecordState] = [:]
    var orderSnapshot: [UUID] = []
    var orderModifiedAt: Date = Date(timeIntervalSince1970: 0)
    var orderDeviceID: String = ""
}

struct SyncStateFile: Codable, Sendable, Equatable {
    var version: Int = 1
    var collections: [String: CollectionSyncState] = [:]
}

/// Loads/saves the state file with the same discipline as the stores:
/// atomic write, 0600, corrupt-aside instead of a crash.
final class SyncStateStore: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.fileURL = support
                .appendingPathComponent("Harbor", isDirectory: true)
                .appendingPathComponent("sync-state.json", isDirectory: false)
        }
    }

    func load() -> SyncStateFile {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return SyncStateFile() }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = SyncDateCodec.decodingStrategy
            return try decoder.decode(SyncStateFile.self, from: data)
        } catch {
            // A corrupt state file must not take sync down: move it aside and
            // rebuild from scratch. Record timestamps are re-derived from the
            // remote envelope where payloads are identical (adopt-if-same).
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(timestamp)")
            try? fm.moveItem(at: fileURL, to: aside)
            return SyncStateFile()
        }
    }

    func save(_ state: SyncStateFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = SyncDateCodec.encodingStrategy
        let data = try encoder.encode(state)
        try SyncFileIO.writeAtomic(data, to: fileURL)
    }
}
