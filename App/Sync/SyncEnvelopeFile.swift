import Foundation
import HarborKit

/// The whole sync envelope file (`sync-envelope.json`): five typed collection
/// sections plus writer metadata. A missing section decodes as nil and is
/// treated as "no data yet" for that collection; a structurally broken file
/// fails the top-level decode and is never overwritten (see CloudSyncEngine).
struct SyncEnvelopeFile: Codable, Sendable {
    static let currentVersion = 1

    var envelopeVersion: Int
    var writerDeviceID: String
    var writtenAt: Date
    /// deviceID → last write time, for the settings UI's device count.
    /// Entries not seen within the tombstone horizon are garbage-collected.
    var devices: [String: Date]
    var folders: SyncCollection<HostFolder>?
    var hosts: SyncCollection<SSHHost>?
    var commands: SyncCollection<QuickCommand>?
    var scripts: SyncCollection<ScriptSnippet>?
    var workspaces: SyncCollection<Workspace>?

    init(
        envelopeVersion: Int = SyncEnvelopeFile.currentVersion,
        writerDeviceID: String,
        writtenAt: Date,
        devices: [String: Date] = [:],
        folders: SyncCollection<HostFolder>? = nil,
        hosts: SyncCollection<SSHHost>? = nil,
        commands: SyncCollection<QuickCommand>? = nil,
        scripts: SyncCollection<ScriptSnippet>? = nil,
        workspaces: SyncCollection<Workspace>? = nil
    ) {
        self.envelopeVersion = envelopeVersion
        self.writerDeviceID = writerDeviceID
        self.writtenAt = writtenAt
        self.devices = devices
        self.folders = folders
        self.hosts = hosts
        self.commands = commands
        self.scripts = scripts
        self.workspaces = workspaces
    }
}

enum SyncEnvelopeCodec {
    static func encode(_ envelope: SyncEnvelopeFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = SyncDateCodec.encodingStrategy
        return try encoder.encode(envelope)
    }

    static func decode(_ data: Data) throws -> SyncEnvelopeFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = SyncDateCodec.decodingStrategy
        return try decoder.decode(SyncEnvelopeFile.self, from: data)
    }
}
