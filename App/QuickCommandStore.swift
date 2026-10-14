import Foundation
import Combine
import HarborKit

/// Owns the saved quick-command library (FinalShell's 命令 tab) and persists it
/// as pretty-printed JSON at ~/Library/Application Support/Harbor/commands.json.
///
/// Writes are atomic. A corrupt file is renamed aside (commands.json.corrupt-…)
/// and the store starts fresh — it never crashes on bad JSON. On a true first
/// run (no file at all) it seeds a few sensible starter commands the user can
/// keep or delete. Persistence and the shared CRUD live in `JSONFileStore`; this
/// subclass supplies only command specifics.
@MainActor
final class QuickCommandStore: JSONFileStore<QuickCommand> {
    /// Domain-named facade over the inherited `items` so existing call sites
    /// (`store.commands`) keep working unchanged.
    var commands: [QuickCommand] { items }

    /// Cloud sync collection registration (see `JSONFileStore`).
    override var syncCollectionID: String? { SyncCollectionID.commands.rawValue }

    nonisolated static func defaultFileURL() -> URL {
        JSONFileStore<QuickCommand>.defaultFileURL(filename: "commands.json")
    }

    init(fileURL: URL = QuickCommandStore.defaultFileURL(), fileManager: FileManager = .default) {
        super.init(
            fileURL: fileURL,
            fileManager: fileManager,
            decode: { try QuickCommandStoreCodec.decode($0) },
            encode: { try QuickCommandStoreCodec.encode($0) }
        )
    }

    /// Folder names present in the library, in first-appearance order. Commands
    /// without a group are bucketed under "" (ungrouped) by the UI.
    var groups: [String] {
        groupedCommands().map(\.group)
    }

    /// One linear pass: group names in first-appearance order plus the commands
    /// in each group. Avoids the previous "filter the whole array per group".
    func groupedCommands(in source: [QuickCommand]? = nil) -> [(group: String, commands: [QuickCommand])] {
        let items = source ?? commands
        var seen = Set<String>()
        var ordered: [String] = []
        var buckets: [String: [QuickCommand]] = [:]
        for command in items {
            let group = command.group.trimmingCharacters(in: .whitespacesAndNewlines)
            if seen.insert(group).inserted {
                ordered.append(group)
                buckets[group] = [command]
            } else {
                buckets[group, default: []].append(command)
            }
        }
        return ordered.map { (group: $0, commands: buckets[$0] ?? []) }
    }

    /// Case-insensitive match on title, command, or group. Empty query returns
    /// the live store array (no extra copy).
    func search(_ query: String) -> [QuickCommand] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return commands }
        return commands.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.command.localizedCaseInsensitiveContains(q)
                || $0.group.localizedCaseInsensitiveContains(q)
                || $0.displayTitle.localizedCaseInsensitiveContains(q)
        }
    }

    // MARK: - JSONFileStore hooks

    override func seedItems() -> [QuickCommand] {
        QuickCommandStoreCodec.starterCommands()
    }

    override func corruptMessage(aside: String) -> String {
        L("commands.json 无法读取，已移到一旁（%@），命令列表已重置。", aside)
    }

    override func saveErrorMessage(_ description: String) -> String {
        L("保存命令失败：%@", description)
    }

    // MARK: - Command-specific API

    @discardableResult
    func duplicate(_ command: QuickCommand) -> QuickCommand {
        duplicate(command) { copy, original in
            copy.id = UUID()
            copy.title = original.displayTitle + L(" 副本")
        }
    }

    /// Reorders commands within a single group section and persists.
    /// `source` and `destination` are indices relative to that group's filtered
    /// array, matching the IndexSet SwiftUI passes from `.onMove`.
    func move(inGroup group: String, fromOffsets source: IndexSet, toOffset destination: Int) {
        let groupIndices = items.indices.filter {
            items[$0].group.trimmingCharacters(in: .whitespacesAndNewlines) == group
        }
        guard !groupIndices.isEmpty else { return }
        var groupItems = groupIndices.map { items[$0] }
        groupItems.move(fromOffsets: source, toOffset: destination)
        var updated = items
        for (offset, globalIndex) in groupIndices.enumerated() {
            updated[globalIndex] = groupItems[offset]
        }
        replaceAll(with: updated)
    }
}
