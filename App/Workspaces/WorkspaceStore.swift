import Foundation
import Combine
import HarborKit

/// A named snapshot of the terminal workspace. Host references deliberately
/// keep only saved-host IDs: passwords and connection settings stay in the
/// existing HostStore, and a deleted host can be skipped safely on restore.
struct Workspace: Identifiable, Codable, Sendable {
    struct Tab: Codable, Hashable, Sendable {
        enum Kind: String, Codable, Sendable {
            case remoteHost
            case localShell
        }

        let kind: Kind
        let hostID: UUID?

        static func remoteHost(_ id: UUID) -> Tab {
            Tab(kind: .remoteHost, hostID: id)
        }

        static let localShell = Tab(kind: .localShell, hostID: nil)
    }

    let id: UUID
    var name: String
    /// Unique saved hosts represented in the workspace, in first-tab order.
    let hostIDs: [UUID]
    /// Open-tab order, including repeated connections to the same host.
    let tabs: [Tab]
    /// The active tab's position in `tabs`, retained even when a restore skips
    /// an unavailable host so a nearby surviving tab can become active.
    let selectedTabIndex: Int?
    let monitorPanelVisible: Bool
    let filePanelVisible: Bool
    let updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        hostIDs: [UUID],
        tabs: [Tab],
        selectedTabIndex: Int?,
        monitorPanelVisible: Bool,
        filePanelVisible: Bool,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.hostIDs = hostIDs
        self.tabs = tabs
        self.selectedTabIndex = selectedTabIndex
        self.monitorPanelVisible = monitorPanelVisible
        self.filePanelVisible = filePanelVisible
        self.updatedAt = updatedAt
    }
}

struct WorkspaceRestoreResult {
    let restoredTabCount: Int
    let skippedHostCount: Int
    let replacedCurrentSessions: Bool
}

/// Persists named terminal layouts at
/// ~/Library/Application Support/Harbor/workspaces.json.
@MainActor
final class WorkspaceStore: JSONFileStore<Workspace> {
    var workspaces: [Workspace] { items }

    nonisolated static func defaultFileURL() -> URL {
        JSONFileStore<Workspace>.defaultFileURL(filename: "workspaces.json")
    }

    init(fileURL: URL = WorkspaceStore.defaultFileURL(), fileManager: FileManager = .default) {
        super.init(
            fileURL: fileURL,
            fileManager: fileManager,
            decode: { try WorkspaceStore.decodeItems($0) },
            encode: { try WorkspaceStore.encodeItems($0) }
        )
    }

    /// Saves the current tab order, selection, and panel visibility. Saving a
    /// name that already exists updates that workspace instead of creating a
    /// visually ambiguous duplicate.
    func saveCurrent(
        name: String,
        sessions: [TerminalSession],
        selectedSessionID: UUID?,
        monitorPanelVisible: Bool,
        filePanelVisible: Bool
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !sessions.isEmpty else { return }

        var hostIDs: [UUID] = []
        var tabs: [Workspace.Tab] = []
        for session in sessions {
            if session.host.connectionProtocol == .local {
                tabs.append(.localShell)
            } else {
                tabs.append(.remoteHost(session.host.id))
                if !hostIDs.contains(session.host.id) {
                    hostIDs.append(session.host.id)
                }
            }
        }
        let selectedIndex = sessions.firstIndex { $0.id == selectedSessionID }
        let existing = workspaces.first { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }
        let workspace = Workspace(
            id: existing?.id ?? UUID(),
            name: trimmedName,
            hostIDs: hostIDs,
            tabs: tabs,
            selectedTabIndex: selectedIndex,
            monitorPanelVisible: monitorPanelVisible,
            filePanelVisible: filePanelVisible
        )
        upsert(workspace)
    }

    /// Replaces the open tabs with a workspace. Missing saved hosts are skipped;
    /// if none of the workspace's tabs can be restored, existing sessions stay
    /// open rather than leaving the user with an empty window.
    func restore(
        _ workspace: Workspace,
        hostStore: HostStore,
        sessionManager: SessionManager
    ) -> WorkspaceRestoreResult {
        let hostsByID = Dictionary(uniqueKeysWithValues: hostStore.hosts.map { ($0.id, $0) })
        var plannedTabs: [(index: Int, tab: Workspace.Tab)] = []
        var skippedHostCount = 0

        for (index, tab) in workspace.tabs.enumerated() {
            switch tab.kind {
            case .localShell:
                plannedTabs.append((index, tab))
            case .remoteHost:
                guard let hostID = tab.hostID, hostsByID[hostID] != nil else {
                    skippedHostCount += 1
                    continue
                }
                plannedTabs.append((index, tab))
            }
        }

        guard !plannedTabs.isEmpty else {
            return WorkspaceRestoreResult(
                restoredTabCount: 0,
                skippedHostCount: skippedHostCount,
                replacedCurrentSessions: false
            )
        }

        for session in sessionManager.sessions {
            sessionManager.close(session)
        }

        var restoredByIndex: [Int: TerminalSession] = [:]
        for planned in plannedTabs {
            let restored: TerminalSession?
            switch planned.tab.kind {
            case .localShell:
                restored = sessionManager.openLocalSession()
            case .remoteHost:
                guard let hostID = planned.tab.hostID, let host = hostsByID[hostID] else { continue }
                restored = sessionManager.openSession(host: host)
            }
            if let restored {
                restoredByIndex[planned.index] = restored
            }
        }

        if let selectedIndex = workspace.selectedTabIndex,
           let selected = restoredByIndex[selectedIndex] {
            sessionManager.selectedSessionID = selected.id
        } else if let first = restoredByIndex.sorted(by: { $0.key < $1.key }).first?.value {
            sessionManager.selectedSessionID = first.id
        }

        return WorkspaceRestoreResult(
            restoredTabCount: restoredByIndex.count,
            skippedHostCount: skippedHostCount,
            replacedCurrentSessions: true
        )
    }

    override func corruptMessage(aside: String) -> String {
        L("workspaces.json 无法读取，已移到一旁（%@），工作区列表已重置。", aside)
    }

    override func saveErrorMessage(_ description: String) -> String {
        L("保存工作区失败：%@", description)
    }

    nonisolated private static func decodeItems(_ data: Data) throws -> [Workspace] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Document.self, from: data).workspaces
        } catch DecodingError.keyNotFound, DecodingError.typeMismatch {
            return try decoder.decode([Workspace].self, from: data)
        }
    }

    nonisolated private static func encodeItems(_ items: [Workspace]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Document(workspaces: items))
    }

    private struct Document: Codable, Sendable {
        let version: Int
        let workspaces: [Workspace]

        init(version: Int = 1, workspaces: [Workspace]) {
            self.version = version
            self.workspaces = workspaces
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            workspaces = try container.decode([Workspace].self, forKey: .workspaces)
        }
    }
}
