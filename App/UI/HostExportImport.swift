import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HarborKit

/// One-shot host + quick-command export/import triggered by menu-bar items
/// (File > 导出主机… / 导入主机…). Panels and result alerts stay on the main
/// actor; file I/O, JSON work and untrusted-input validation run off-main.
enum HostExportImport {
    private static let maxImportBytes = 16 * 1024 * 1024
    private static let maxImportedItems = 10_000
    private static let maxImportedFolders = 1_000
    @MainActor private static var isBusy = false

    // MARK: - Export

    /// Shows an NSSavePanel, then encodes and writes the selected bundle without
    /// blocking the window while a large backup is serialized.
    @MainActor
    static func exportHosts(hosts: [SSHHost], commands: [QuickCommand], folders: [HostFolder]) {
        guard !isBusy else { return }
        let panel = NSSavePanel()
        panel.title = L("导出主机")
        panel.message = L("把已保存的主机、文件夹和快捷命令存为一个 .harbor 备份文件。该文件为未加密的明文，包含主机名、用户名、密钥路径等信息，以及快捷命令中可能写入的口令，请妥善保管。")
        panel.allowedContentTypes = [UTType(filenameExtension: "harbor") ?? .json]
        panel.nameFieldStringValue = "Harbor_Backup.harbor"
        panel.prompt = L("导出")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isBusy = true
        let bundle = HostBundle(hosts: hosts, commands: commands, folders: folders)
        Task {
            defer { isBusy = false }
            let failure: String? = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    let data = try JSONEncoder().encode(bundle)
                    // Host inventory is sensitive (hostnames, users, key paths).
                    // Write 0600 then replace so the backup is never world-readable.
                    let fm = FileManager.default
                    let temp = url.deletingLastPathComponent()
                        .appendingPathComponent(".harbor-export-\(UUID().uuidString).tmp")
                    guard fm.createFile(
                        atPath: temp.path,
                        contents: data,
                        attributes: [.posixPermissions: 0o600]
                    ) else {
                        return "Failed to create export file"
                    }
                    // Atomic swap when a backup already exists so a failed write
                    // never destroys the old file; plain move only when absent.
                    if fm.fileExists(atPath: url.path) {
                        let result = try fm.replaceItemAt(url, withItemAt: temp)
                        let finalURL = result ?? url
                        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: finalURL.path)
                    } else {
                        try fm.moveItem(at: temp, to: url)
                        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let failure else { return }
            let alert = NSAlert()
            alert.messageText = L("导出失败")
            alert.informativeText = failure
            alert.runModal()
        }
    }

    // MARK: - Import

    /// Shows an NSOpenPanel for a `.harbor` file. Reading, decoding and
    /// validation happen in the background; the final store merge remains on
    /// the main actor so it always applies to the latest in-memory state.
    @MainActor
    static func importHosts(
        hostStore: HostStore,
        quickCommandStore: QuickCommandStore,
        folderStore: HostFolderStore
    ) {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = L("导入主机")
        panel.message = L("选择一个 .harbor 备份文件。相同 ID 且连接目标一致的主机将更新；目标不一致时会作为新主机导入。文件夹按 ID 合并。")
        panel.allowedContentTypes = [UTType(filenameExtension: "harbor") ?? .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = L("导入")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isBusy = true
        Task {
            defer { isBusy = false }
            switch await Task.detached(priority: .userInitiated, operation: {
                loadImportBundle(from: url)
            }).value {
            case .success(let bundle):
                let outcome = merge(
                    bundle,
                    currentHosts: hostStore.hosts,
                    currentCommands: quickCommandStore.commands,
                    currentFolders: folderStore.items
                )
                hostStore.replaceAll(with: outcome.hosts)
                quickCommandStore.replaceAll(with: outcome.commands)
                folderStore.replaceAll(with: outcome.folders)

                let alert = NSAlert()
                alert.messageText = L("导入完成")
                alert.informativeText = L(
                    "已导入 %lld 台主机（其中 %lld 台更新，%lld 台新增），%lld 条命令（其中 %lld 条更新，%lld 条新增），%lld 个文件夹。",
                    bundle.hosts.count, outcome.updatedHosts, outcome.addedHosts,
                    bundle.commands.count, outcome.updatedCommands,
                    bundle.commands.count - outcome.updatedCommands,
                    bundle.folders?.count ?? 0
                )
                alert.runModal()
            case .importError(let error):
                let alert = NSAlert()
                alert.messageText = L("导入失败")
                alert.informativeText = error.message
                alert.runModal()
            case .failure(let description):
                let alert = NSAlert()
                alert.messageText = L("导入失败")
                alert.informativeText = description
                alert.runModal()
            }
        }
    }

    private static func loadImportBundle(from url: URL) -> ImportLoadResult {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maxImportBytes else { throw ImportError.fileTooLarge }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maxImportBytes + 1) ?? Data()
            guard data.count <= maxImportBytes else { throw ImportError.fileTooLarge }
            let bundle = try JSONDecoder().decode(HostBundle.self, from: data)
            try validate(bundle)
            return .success(bundle)
        } catch let error as ImportError {
            return .importError(error)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func merge(
        _ bundle: HostBundle,
        currentHosts: [SSHHost],
        currentCommands: [QuickCommand],
        currentFolders: [HostFolder]
    ) -> ImportOutcome {
        // Folders merge first so imported hosts can be checked against the
        // merged folder set: a host pointing at a folder the bundle does not
        // contain (and the store never had) falls back to the root.
        let incomingFolders = bundle.folders ?? []
        var foldersByID = Dictionary(grouping: currentFolders, by: \.id).compactMapValues(\.first)
        for folder in incomingFolders {
            foldersByID[folder.id] = folder
        }
        let currentFolderIDs = Set(currentFolders.map(\.id))
        var mergedFolders = currentFolders.compactMap { foldersByID[$0.id] }
        mergedFolders += incomingFolders.filter { !currentFolderIDs.contains($0.id) }
        for index in mergedFolders.indices { mergedFolders[index].order = index }
        let validFolderIDs = Set(mergedFolders.map(\.id))

        var byID = Dictionary(grouping: currentHosts, by: \.id).compactMapValues(\.first)
        var updatedHosts = 0
        var addedHosts = 0
        // Keep the normalized new records in insertion order. A conflicting
        // imported ID is deliberately regenerated below; rebuilding from the
        // original bundle later would otherwise look up the old ID and silently
        // omit the host we just counted as added.
        var newHosts: [SSHHost] = []
        for var host in bundle.hosts {
            if let folderID = host.folderID, !validFolderIDs.contains(folderID) {
                host.folderID = nil
            }
            if let existing = byID[host.id] {
                if sameConnectionIdentity(existing, host) {
                    // An update from a folderless backup must not evict the
                    // host from its current folder.
                    if host.folderID == nil { host.folderID = existing.folderID }
                    byID[host.id] = host
                    updatedHosts += 1
                } else {
                    repeat { host.id = UUID() } while byID[host.id] != nil
                    byID[host.id] = host
                    addedHosts += 1
                    newHosts.append(host)
                }
            } else {
                byID[host.id] = host
                addedHosts += 1
                newHosts.append(host)
            }
        }

        let currentCommandIDs = Set(currentCommands.map(\.id))
        var commandsByID = Dictionary(grouping: currentCommands, by: \.id).compactMapValues(\.first)
        var updatedCommands = 0
        for command in bundle.commands {
            commandsByID[command.id] = command
            if currentCommandIDs.contains(command.id) { updatedCommands += 1 }
        }
        let existingOrdered = currentHosts.compactMap { byID[$0.id] }
        let mergedHosts = existingOrdered + newHosts

        let existingCommandOrder = currentCommands.compactMap { commandsByID[$0.id] }
        let newCommands = bundle.commands.filter { !currentCommandIDs.contains($0.id) }
        return ImportOutcome(
            hosts: mergedHosts,
            commands: existingCommandOrder + newCommands,
            folders: mergedFolders,
            updatedHosts: updatedHosts,
            addedHosts: addedHosts,
            updatedCommands: updatedCommands
        )
    }

    private static func validate(_ bundle: HostBundle) throws {
        guard bundle.version == 1 else { throw ImportError.unsupportedVersion(bundle.version) }
        guard bundle.hosts.count <= maxImportedItems,
              bundle.commands.count <= maxImportedItems else {
            throw ImportError.tooManyItems
        }
        let folders = bundle.folders ?? []
        guard folders.count <= maxImportedFolders else { throw ImportError.tooManyItems }
        var folderIDs = Set<UUID>()
        for folder in folders {
            guard folderIDs.insert(folder.id).inserted else { throw ImportError.duplicateID }
            guard HostFolderStore.sanitizedName(folder.name) != nil else {
                throw ImportError.invalidFolder(folder.name)
            }
        }
        var hostIDs = Set<UUID>()
        for host in bundle.hosts {
            guard hostIDs.insert(host.id).inserted else { throw ImportError.duplicateID }
            switch host.connectionProtocol {
            case .ssh:
                _ = try SSHCommandBuilder.arguments(for: host)
            case .rdp:
                guard host.extraArgs.isEmpty, host.portForwards.isEmpty,
                      host.identityFile == nil, host.shell.isEmpty else {
                    throw ImportError.invalidHost(host.displayName)
                }
                // Reuse the SSH builder's strict token and port validation for
                // the fields that SSH and RDP share; no process is spawned.
                _ = try SSHCommandBuilder.arguments(for: SSHHost(
                    hostname: host.hostname, port: host.port, username: host.username
                ))
                try validateToken(host.rdpDomain, allowEmpty: true)
            case .local:
                // Local tabs are runtime-only and must never arrive through an
                // untrusted backup as a persisted connection definition.
                throw ImportError.invalidHost(host.displayName)
            }
        }
        guard Set(bundle.commands.map(\.id)).count == bundle.commands.count else {
            throw ImportError.duplicateID
        }
    }

    private static func validateToken(_ value: String, allowEmpty: Bool) throws {
        if value.isEmpty, allowEmpty { return }
        if value.isEmpty || value.hasPrefix("-") || value.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0)
        }) {
            throw ImportError.invalidHost(value)
        }
    }

    /// A Keychain TOTP secret is keyed by host UUID.  Never let an imported
    /// record reuse an existing UUID for a different account/server.
    private static func sameConnectionIdentity(_ lhs: SSHHost, _ rhs: SSHHost) -> Bool {
        lhs.connectionProtocol == rhs.connectionProtocol
            && lhs.hostname.caseInsensitiveCompare(rhs.hostname) == .orderedSame
            && lhs.port == rhs.port
            && lhs.username == rhs.username
            && lhs.rdpDomain == rhs.rdpDomain
    }
}

// MARK: - Wireframe

/// The backing storage model of a `.harbor` export file: hosts + folders +
/// commands in one versioned envelope. Kept as a private struct (no external
/// dependence). The version field enables future migration. `folders` is
/// optional so backups written before folders existed still decode.
private struct HostBundle: Codable, Sendable {
    var version: Int = 1
    var hosts: [SSHHost]
    var commands: [QuickCommand]
    var folders: [HostFolder]?
}

private enum ImportError: Error, Sendable {
    case fileTooLarge
    case tooManyItems
    case unsupportedVersion(Int)
    case duplicateID
    case invalidHost(String)
    case invalidFolder(String)

    @MainActor var message: String {
        switch self {
        case .fileTooLarge:
            return L("导入文件过大（上限 16 MB）。")
        case .tooManyItems:
            return L("导入文件包含过多主机或命令。")
        case .unsupportedVersion(let version):
            return L("不支持的备份格式版本：%lld", version)
        case .duplicateID:
            return L("导入文件包含重复 ID，已拒绝导入。")
        case .invalidHost(let name):
            return L("主机“%@”包含不安全或不支持的连接参数。", name)
        case .invalidFolder(let name):
            return L("文件夹“%@”无效（名称为空、过长或包含非法字符）。", name)
        }
    }
}

private enum ImportLoadResult: Sendable {
    case success(HostBundle)
    case importError(ImportError)
    case failure(String)
}

private struct ImportOutcome: Sendable {
    var hosts: [SSHHost]
    var commands: [QuickCommand]
    var folders: [HostFolder]
    var updatedHosts: Int
    var addedHosts: Int
    var updatedCommands: Int
}
