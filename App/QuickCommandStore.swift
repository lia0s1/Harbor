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
        var seen = Set<String>()
        var ordered: [String] = []
        for command in commands {
            let group = command.group.trimmingCharacters(in: .whitespacesAndNewlines)
            if !seen.contains(group) {
                seen.insert(group)
                ordered.append(group)
            }
        }
        return ordered
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
}
