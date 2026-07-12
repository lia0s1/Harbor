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

    // MARK: - Export

    /// Shows an NSSavePanel, then encodes and writes the selected bundle without
    /// blocking the window while a large backup is serialized.
    @MainActor
    static func exportHosts(hosts: [SSHHost], commands: [QuickCommand]) {
        let panel = NSSavePanel()
        panel.title = L("导出主机")
        panel.message = L("把已保存的主机和快捷命令存为一个 .harbor 备份文件。")
        panel.allowedContentTypes = [UTType(filenameExtension: "harbor") ?? .json]
        panel.nameFieldStringValue = "Harbor_Backup.harbor"
        panel.prompt = L("导出")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let bundle = HostBundle(hosts: hosts, commands: commands)
        Task {
            let failure = await Task.detached(priority: .userInitiated) {
                do {
                    let data = try JSONEncoder().encode(bundle)
                    try data.write(to: url, options: .atomic)
                    return nil as String?
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
        quickCommandStore: QuickCommandStore
    ) {
        let panel = NSOpenPanel()
        panel.title = L("导入主机")
        panel.message = L("选择一个 .harbor 备份文件。相同 ID 且连接目标一致的主机将更新；目标不一致时会作为新主机导入。")
        panel.allowedContentTypes = [UTType(filenameExtension: "harbor") ?? .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = L("导入")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            switch await Task.detached(priority: .userInitiated, operation: {
                loadImportBundle(from: url)
            }).value {
            case .success(let bundle):
                let outcome = merge(
                    bundle,
                    currentHosts: hostStore.hosts,
                    currentCommands: quickCommandStore.commands
                )
                hostStore.replaceAll(with: outcome.hosts)
                quickCommandStore.replaceAll(with: outcome.commands)

                let alert = NSAlert()
                alert.messageText = L("导入完成")
                alert.informativeText = L(
                    "已导入 %lld 台主机（其中 %lld 台更新，%lld 台新增），%lld 条命令（其中 %lld 条更新，%lld 条新增）。",
                    bundle.hosts.count, outcome.updatedHosts, outcome.addedHosts,
                    bundle.commands.count, outcome.updatedCommands,
                    bundle.commands.count - outcome.updatedCommands
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
        currentCommands: [QuickCommand]
    ) -> ImportOutcome {
        var byID = Dictionary(grouping: currentHosts, by: \.id).compactMapValues(\.first)
        var updatedHosts = 0
        var addedHosts = 0
        for var host in bundle.hosts {
            if let existing = byID[host.id] {
                if sameConnectionIdentity(existing, host) {
                    byID[host.id] = host
                    updatedHosts += 1
                } else {
                    repeat { host.id = UUID() } while byID[host.id] != nil
                    byID[host.id] = host
                    addedHosts += 1
                }
            } else {
                byID[host.id] = host
                addedHosts += 1
            }
        }

        let currentCommandIDs = Set(currentCommands.map(\.id))
        var commandsByID = Dictionary(grouping: currentCommands, by: \.id).compactMapValues(\.first)
        var updatedCommands = 0
        for command in bundle.commands {
            commandsByID[command.id] = command
            if currentCommandIDs.contains(command.id) { updatedCommands += 1 }
        }
        return ImportOutcome(
            hosts: Array(byID.values),
            commands: Array(commandsByID.values),
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

/// The backing storage model of a `.harbor` export file: hosts + commands in one
/// versioned envelope. Kept as a private struct (no external dependence). The
/// version field enables future migration.
private struct HostBundle: Codable, Sendable {
    var version: Int = 1
    var hosts: [SSHHost]
    var commands: [QuickCommand]
}

private enum ImportError: Error, Sendable {
    case fileTooLarge
    case tooManyItems
    case unsupportedVersion(Int)
    case duplicateID
    case invalidHost(String)

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
    var updatedHosts: Int
    var addedHosts: Int
    var updatedCommands: Int
}
