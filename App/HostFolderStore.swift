import Foundation
import HarborKit

/// Owns the sidebar folder list, persisted as folders.json next to hosts.json
/// via the shared JSONFileStore machinery (atomic writes, 0600, corrupt-aside).
///
/// Folders are one flat level. Array order is canonical; `order` is normalized
/// to the array index on every mutation. Deleting a folder never deletes its
/// hosts — the caller (sidebar) clears their `folderID` via HostStore.
@MainActor
final class HostFolderStore: JSONFileStore<HostFolder> {
    nonisolated static let maxNameLength = 64

    /// Folders in sidebar order.
    var folders: [HostFolder] {
        items.sorted { $0.order == $1.order ? $0.name < $1.name : $0.order < $1.order }
    }

    nonisolated static func defaultFileURL() -> URL {
        JSONFileStore<HostFolder>.defaultFileURL(filename: "folders.json")
    }

    init(fileURL: URL = HostFolderStore.defaultFileURL(), fileManager: FileManager = .default) {
        super.init(
            fileURL: fileURL,
            fileManager: fileManager,
            decode: { try HostFolderStoreCodec.decode($0) },
            encode: { try HostFolderStoreCodec.encode($0) }
        )
    }

    override func corruptMessage(aside: String) -> String {
        L("folders.json 无法读取，已移到一旁（%@），文件夹列表已重置。", aside)
    }

    override func saveErrorMessage(_ description: String) -> String {
        L("保存文件夹失败：%@", description)
    }

    /// Trimmed, bounded, control-character-free folder name; nil when invalid.
    /// nonisolated: also called from HostExportImport's background validation.
    nonisolated static func sanitizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxNameLength,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return trimmed
    }

    @discardableResult
    func createFolder(name raw: String) -> HostFolder? {
        guard let name = Self.sanitizedName(raw) else { return nil }
        let folder = HostFolder(name: name, order: (folders.last?.order ?? -1) + 1)
        add(folder)
        return folder
    }

    @discardableResult
    func renameFolder(_ id: UUID, name raw: String) -> Bool {
        guard let name = Self.sanitizedName(raw),
              var folder = items.first(where: { $0.id == id }) else { return false }
        folder.name = name
        update(folder)
        return true
    }

    func folder(withID id: UUID) -> HostFolder? {
        items.first { $0.id == id }
    }

    /// Moves a folder one position (offset -1 = up, +1 = down) in sidebar order.
    func moveFolder(_ id: UUID, offset: Int) {
        let ordered = folders
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard ordered.indices.contains(target) else { return }
        var updated = ordered
        updated.swapAt(index, target)
        for i in updated.indices { updated[i].order = i }
        replaceAll(with: updated)
    }
}
