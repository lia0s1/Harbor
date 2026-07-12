import Foundation

/// Encodes/decodes the on-disk hosts.json document. Pure data <-> bytes; file
/// IO lives in the app layer so it stays testable here.
public enum HostStoreCodec {
    /// Versioned wrapper so future migrations have something to key off.
    public struct Document: Codable, Sendable {
        public var version: Int
        public var hosts: [SSHHost]

        public init(version: Int = HostStoreCodec.currentVersion, hosts: [SSHHost]) {
            self.version = version
            self.hosts = hosts
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            // `hosts` is REQUIRED: a structurally-valid object that lacks it
            // (e.g. `{}` or `{"version":1}`) is corruption, not an empty store.
            // Decoding non-optionally throws keyNotFound so HostStore.load's
            // catch moves the file aside instead of silently replacing it with
            // an empty list on the next save. An actually-empty store always
            // round-trips through `encode`, which writes `"hosts": []`.
            hosts = try c.decode([SSHHost].self, forKey: .hosts)
        }
    }

    public static let currentVersion = 1

    public static func encode(_ hosts: [SSHHost]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Document(hosts: hosts))
    }

    public static func decode(_ data: Data) throws -> [SSHHost] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Accept either the versioned document or a bare array of hosts.
        // Only fall back to the bare-array format when the data is structurally
        // not a document object (keyNotFound for "hosts"). Any other error —
        // including a corrupt entry inside "hosts" — propagates so the caller
        // can move the file aside rather than silently losing all hosts.
        do {
            return try decoder.decode(Document.self, from: data).hosts
        } catch DecodingError.keyNotFound, DecodingError.typeMismatch {
            return try decoder.decode([SSHHost].self, from: data)
        }
    }
}
