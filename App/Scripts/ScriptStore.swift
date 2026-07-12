import Foundation
import Combine
import HarborKit

/// Owns the saved script/snippet library and persists it as pretty-printed JSON
/// at ~/Library/Application Support/Harbor/scripts.json.
///
/// Reuses `JSONFileStore` for the atomic write, corrupt-aside recovery and the
/// shared CRUD (add/update/upsert/delete); this subclass adds the script codec,
/// category derivation, search, and category management. Data lives in memory
/// only while the store is alive: `load()` on init, `save()` on every mutation.
///
/// Writes are atomic. A corrupt file is renamed aside (scripts.json.corrupt-…)
/// and the store starts empty — it never crashes on bad JSON.
@MainActor
final class ScriptStore: JSONFileStore<ScriptSnippet> {
    /// Domain-named facade over the inherited `items` so call sites read
    /// `store.snippets`.
    var snippets: [ScriptSnippet] { items }

    nonisolated static func defaultFileURL() -> URL {
        JSONFileStore<ScriptSnippet>.defaultFileURL(filename: "scripts.json")
    }

    init(fileURL: URL = ScriptStore.defaultFileURL(), fileManager: FileManager = .default) {
        super.init(
            fileURL: fileURL,
            fileManager: fileManager,
            decode: { try ScriptStore.decodeItems($0) },
            encode: { try ScriptStore.encodeItems($0) }
        )
    }

    // MARK: - Categories (computed from snippets)

    /// Non-empty category names in first-appearance order. Uncategorized snippets
    /// (empty category) are surfaced separately by the UI, not listed here.
    var categories: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for snippet in snippets {
            let category = snippet.category.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !category.isEmpty, !seen.contains(category) else { continue }
            seen.insert(category)
            ordered.append(category)
        }
        return ordered
    }

    /// True when at least one snippet has no category.
    var hasUncategorized: Bool {
        snippets.contains { $0.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Snippets in `category` (pass "" for the uncategorized bucket).
    func snippets(inCategory category: String) -> [ScriptSnippet] {
        let key = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return snippets.filter {
            $0.category.trimmingCharacters(in: .whitespacesAndNewlines) == key
        }
    }

    func count(inCategory category: String) -> Int {
        snippets(inCategory: category).count
    }

    // MARK: - Search

    /// Case-insensitive match on title or content. An empty query returns all.
    func search(_ query: String) -> [ScriptSnippet] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return snippets }
        return snippets.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.content.localizedCaseInsensitiveContains(q)
        }
    }

    // MARK: - Category management

    /// Rewrites every snippet's category from `old` to `new` in one atomic save.
    /// No-op when either name is empty or they already match.
    func renameCategory(_ old: String, to new: String) {
        let from = old.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty, from != to else { return }
        var updated = snippets
        var didChange = false
        for index in updated.indices
        where updated[index].category.trimmingCharacters(in: .whitespacesAndNewlines) == from {
            updated[index].category = to
            didChange = true
        }
        guard didChange else { return }
        replaceAll(with: updated)
    }

    /// Deletes every snippet in `category`.
    func deleteCategory(_ category: String) {
        let ids = Set(snippets(inCategory: category).map { $0.id })
        guard !ids.isEmpty else { return }
        delete(ids: ids)
    }

    // MARK: - Script-specific API

    @discardableResult
    func duplicate(_ snippet: ScriptSnippet) -> ScriptSnippet {
        duplicate(snippet) { copy, original in
            copy.id = UUID()
            copy.title = original.displayTitle + L(" 副本")
            copy.createdAt = Date()
        }
    }

    // MARK: - JSONFileStore hooks

    nonisolated private static func decodeItems(_ data: Data) throws -> [ScriptSnippet] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Prefer the versioned wrapper; fall back to a bare array only when the
        // top-level object is missing the keyed structure (migration path). Other
        // errors propagate so the app layer moves the file aside instead of
        // silently losing data. Mirrors QuickCommandStoreCodec / HostStoreCodec.
        do {
            return try decoder.decode(Document.self, from: data).scripts
        } catch DecodingError.keyNotFound, DecodingError.typeMismatch {
            return try decoder.decode([ScriptSnippet].self, from: data)
        }
    }

    nonisolated private static func encodeItems(_ items: [ScriptSnippet]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Document(scripts: items))
    }

    override func corruptMessage(aside: String) -> String {
        L("scripts.json 无法读取，已移到一旁（%@），脚本库已重置。", aside)
    }

    override func saveErrorMessage(_ description: String) -> String {
        L("保存脚本失败：%@", description)
    }

    // MARK: - Codec

    /// Versioned on-disk document (mirrors HostStoreCodec / QuickCommandStoreCodec):
    /// a version tag plus the script list, with a tolerant decode.
    private struct Document: Codable, Sendable {
        var version: Int
        var scripts: [ScriptSnippet]

        init(version: Int = 1, scripts: [ScriptSnippet]) {
            self.version = version
            self.scripts = scripts
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            // `scripts` is REQUIRED: an object missing it is corruption, not an
            // empty library — throw so the file is moved aside rather than
            // overwritten empty on the next save.
            scripts = try c.decode([ScriptSnippet].self, forKey: .scripts)
        }
    }
}
