import Foundation
import Combine
import HarborKit

/// `FileManager` lacks a Sendable annotation, but each instance passed here is
/// used only by `JSONStorePersistence`'s serial worker queue. Keeping the
/// wrapper local preserves injected file-manager behavior without allowing
/// concurrent JSON-save access.
private struct SerializedFileManager: @unchecked Sendable {
    let value: FileManager
}

/// Serializes JSON encoding and disk writes away from the main actor. All
/// stores share one queue so a newer snapshot cannot be overtaken by a later
/// file replacement from another queued write. `flush()` is called during
/// orderly app termination, preserving the previous synchronous durability
/// guarantee without making save buttons wait on filesystem I/O.
enum JSONStorePersistence {
    private static let queue = DispatchQueue(
        label: "dev.zero.Harbor.json-store",
        qos: .utility
    )

    fileprivate static func enqueue<Element: Sendable>(
        items: [Element],
        fileURL: URL,
        fileManager: SerializedFileManager,
        encode: @escaping @Sendable ([Element]) throws -> Data,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        queue.async {
            let failure: String?
            do {
                let data = try encode(items)
                try write(data, to: fileURL, using: fileManager.value)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            Task { @MainActor in completion(failure) }
        }
    }

    static func flush() {
        queue.sync {}
    }

    private static func write(_ data: Data, to fileURL: URL, using fileManager: FileManager) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let stagingURL = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: stagingURL) }
        guard fileManager.createFile(
            atPath: stagingURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: stagingURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagingURL.path)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: fileURL)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

/// Shared base for the JSON-backed stores (hosts.json, commands.json). Owns the
/// file-URL resolution, the corrupt-aside `load()`, background atomic `save()`,
/// and the common CRUD (add/update/upsert/duplicate/delete) so the stores can no
/// longer drift apart.
///
/// Subclasses are still `@MainActor ObservableObject`s: `items` is a real
/// `@Published` property, so a SwiftUI view observing a concrete subclass picks
/// up changes through the inherited `objectWillChange`. Subclasses supply only
/// their specifics (filename, codec, seed, the "副本" rename, error wording) and
/// expose a domain-named facade over `items` (`hosts` / `commands`) so existing
/// call sites keep compiling.
///
/// Writes are atomic. A corrupt file is renamed aside (<name>.corrupt-<timestamp>)
/// and the store starts fresh — it never crashes on bad JSON.
@MainActor
class JSONFileStore<Element: Identifiable & Codable & Sendable>: ObservableObject where Element.ID == UUID {
    @Published private(set) var items: [Element] = []

    /// Non-nil when the last load/save hit a problem worth surfacing.
    @Published var lastError: String?

    private let fileURL: URL
    private let fileManager: FileManager
    private let decodeItems: @Sendable (Data) throws -> [Element]
    private let encodeItems: @Sendable ([Element]) throws -> Data
    private var saveGeneration = 0

    /// Resolves <Application Support>/Harbor/<filename>, matching the historical
    /// per-store `defaultFileURL()` shape.
    nonisolated static func defaultFileURL(filename: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Harbor", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    init(
        fileURL: URL,
        fileManager: FileManager = .default,
        decode: @escaping @Sendable (Data) throws -> [Element],
        encode: @escaping @Sendable ([Element]) throws -> Data
    ) {
        assert(
            type(of: self) != JSONFileStore.self,
            "JSONFileStore must be subclassed; instantiating it directly is not supported"
        )
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.decodeItems = decode
        self.encodeItems = encode
        load()
    }

    // MARK: - Subclass hooks

    /// Elements to seed on a true first run (no file at all). Default: none.
    /// A non-empty seed is persisted immediately so the file exists thereafter.
    func seedItems() -> [Element] { [] }

    /// Localized message when the on-disk file could not be read and was moved
    /// aside; `aside` is the renamed file's last path component.
    func corruptMessage(aside: String) -> String {
        L("%@ 无法读取，已移到一旁（%@），列表已重置。", fileURL.lastPathComponent, aside)
    }

    /// Localized message when a background atomic save failed.
    func saveErrorMessage(_ description: String) -> String {
        L("保存失败：%@", description)
    }

    // MARK: - CRUD

    func add(_ item: Element) {
        items.append(item)
        save()
    }

    func update(_ item: Element) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        save()
    }

    /// Adds the item if new, replaces it if the id already exists.
    func upsert(_ item: Element) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        save()
    }

    func delete(_ item: Element) {
        delete(ids: [item.id])
    }

    /// Replaces the entire item list and saves. Used by import (hosts, commands)
    /// to atomically overwrite with a merged set without exposing `items` as a
    /// mutable property.
    func replaceAll(with newItems: [Element]) {
        items = newItems
        save()
    }

    /// Appends a batch of items and saves once. No-op (no write) on an empty
    /// batch, so importers can call it unconditionally. `items` is `private(set)`,
    /// so subclasses route bulk inserts through here.
    func append(contentsOf newItems: [Element]) {
        guard !newItems.isEmpty else { return }
        items.append(contentsOf: newItems)
        save()
    }

    func delete(ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        save()
    }

    /// Inserts a copy directly after the original (or appends if not found),
    /// after the subclass rewrites the copy's identity/label via `rename`.
    @discardableResult
    func duplicate(_ item: Element, rename: (inout Element, Element) -> Void) -> Element {
        var copy = item
        rename(&copy, item)
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items.insert(copy, at: index + 1)
        } else {
            items.append(copy)
        }
        save()
        return copy
    }

    // MARK: - Persistence

    func load() {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            // True first run: seed (empty by default), persisting any seed so the
            // file exists from then on.
            let seed = seedItems()
            items = seed
            if !seed.isEmpty { save() }
            return
        }
        // Tighten before reading (and before a possible corrupt-file rename),
        // so a legacy 0644 store is not left exposed for the rest of startup.
        tightenPermissions()
        do {
            let data = try Data(contentsOf: fileURL)
            items = try decodeItems(data)
            lastError = nil
        } catch {
            // Corrupt or unreadable: move it aside and start fresh. Never crash.
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let asideURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(timestamp)")
            try? fileManager.moveItem(at: fileURL, to: asideURL)
            items = []
            lastError = corruptMessage(aside: asideURL.lastPathComponent)
        }
    }

    func save() {
        saveGeneration += 1
        let generation = saveGeneration
        let snapshot = items
        let fileURL = fileURL
        let encodeItems = encodeItems
        JSONStorePersistence.enqueue(
            items: snapshot,
            fileURL: fileURL,
            fileManager: SerializedFileManager(value: fileManager),
            encode: encodeItems
        ) { [weak self] failure in
            guard let self, generation == self.saveGeneration else { return }
            self.lastError = failure.map(self.saveErrorMessage)
        }
    }

    private func tightenPermissions() {
        let directory = fileURL.deletingLastPathComponent()
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
