import Foundation
import Combine
import HarborKit

/// Owns the saved-host list and persists it as pretty-printed JSON at
/// ~/Library/Application Support/Harbor/hosts.json.
///
/// Writes are atomic. A corrupt file is renamed aside (hosts.json.corrupt-<timestamp>)
/// and the store starts fresh — it never crashes on bad JSON. Persistence and the
/// shared CRUD live in `JSONFileStore`; this subclass supplies only host specifics.
@MainActor
final class HostStore: JSONFileStore<SSHHost> {
    /// Domain-named facade over the inherited `items` so existing call sites
    /// (`hostStore.hosts`) keep working unchanged.
    var hosts: [SSHHost] { items }

    nonisolated static func defaultFileURL() -> URL {
        JSONFileStore<SSHHost>.defaultFileURL(filename: "hosts.json")
    }

    init(fileURL: URL = HostStore.defaultFileURL(), fileManager: FileManager = .default) {
        super.init(
            fileURL: fileURL,
            fileManager: fileManager,
            decode: { try HostStoreCodec.decode($0) },
            encode: { try HostStoreCodec.encode($0) }
        )
    }

    override func corruptMessage(aside: String) -> String {
        L("hosts.json 无法读取，已移到一旁（%@），主机列表已重置。", aside)
    }

    override func saveErrorMessage(_ description: String) -> String {
        L("保存主机失败：%@", description)
    }

    // MARK: - Host-specific API

    @discardableResult
    func duplicate(_ host: SSHHost) -> SSHHost {
        duplicate(host) { copy, original in
            copy.id = UUID()
            copy.name = original.displayName + L(" 副本")
        }
    }

    func host(withID id: UUID) -> SSHHost? {
        hosts.first { $0.id == id }
    }

    override func delete(ids: Set<UUID>) {
        // TOTP records are keyed only by host UUID. Remove them with the host so
        // a later import can never inherit an orphaned secret.
        for id in ids { TOTPStore.delete(for: id) }
        super.delete(ids: ids)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var updated = items
        updated.move(fromOffsets: source, toOffset: destination)
        replaceAll(with: updated)
    }

    /// Merges imported hosts (e.g. from ~/.ssh/config). Skips candidates whose
    /// display name collides with an existing host (case-insensitive) and
    /// candidates that fail SSHCommandBuilder's injection-safety validation.
    @discardableResult
    func importHosts(_ candidates: [SSHHost]) -> (imported: Int, skipped: Int) {
        var existingNames = Set(hosts.map { $0.displayName.lowercased() })
        var accepted: [SSHHost] = []
        var skipped = 0
        for candidate in candidates {
            let key = candidate.displayName.lowercased()
            guard !existingNames.contains(key),
                  (try? SSHCommandBuilder.arguments(for: candidate)) != nil else {
                skipped += 1
                continue
            }
            accepted.append(candidate)
            existingNames.insert(key)
        }
        append(contentsOf: accepted)
        return (imported: accepted.count, skipped: skipped)
    }
}
