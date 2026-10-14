import Foundation

/// A sidebar folder grouping saved hosts. Flat (one level) by design — no
/// nested folders. Hosts reference a folder via `SSHHost.folderID`;
/// nil means unfiled (root).
public struct HostFolder: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Sidebar position; lower sorts first. Mutations normalize it to the
    /// array index so array order and `order` never drift apart.
    public var order: Int

    public init(id: UUID = UUID(), name: String, order: Int = 0) {
        self.id = id
        self.name = name
        self.order = order
    }

    // Tolerant decoding, mirroring SSHHost: one malformed entry must not
    // abort the whole array decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        order = (try? c.decodeIfPresent(Int.self, forKey: .order)) ?? 0
    }
}

/// Encodes/decodes the on-disk folders.json document. Pure data <-> bytes;
/// file IO lives in the app layer so it stays testable here.
public enum HostFolderStoreCodec {
    /// Versioned wrapper so future migrations have something to key off.
    public struct Document: Codable, Sendable {
        public var version: Int
        public var folders: [HostFolder]

        public init(version: Int = HostFolderStoreCodec.currentVersion, folders: [HostFolder]) {
            self.version = version
            self.folders = folders
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            // `folders` is REQUIRED: a structurally-valid object that lacks it
            // is corruption, not an empty store (same contract as
            // HostStoreCodec.Document).
            folders = try c.decode([HostFolder].self, forKey: .folders)
        }
    }

    public static let currentVersion = 1

    public static func encode(_ folders: [HostFolder]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Document(folders: folders))
    }

    public static func decode(_ data: Data) throws -> [HostFolder] {
        let decoder = JSONDecoder()
        // Accept either the versioned document or a bare array of folders,
        // mirroring HostStoreCodec.decode.
        do {
            return try decoder.decode(Document.self, from: data).folders
        } catch DecodingError.keyNotFound, DecodingError.typeMismatch {
            return try decoder.decode([HostFolder].self, from: data)
        }
    }
}
