import SwiftUI

/// Named workspace management: save the current terminal layout, restore a
/// saved layout, or remove an obsolete one. It intentionally lives in a sheet
/// so it remains available even when the session area is empty.
struct WorkspaceManagerView: View {
    @EnvironmentObject private var workspaceStore: WorkspaceStore
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var localization: LocalizationManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage(MonitorPanelPreference.storageKey)
    private var monitorPanelVisible = MonitorPanelPreference.defaultVisible
    @AppStorage(FilePanelPreference.storageKey)
    private var filePanelVisible = FilePanelPreference.defaultVisible
    @State private var name = ""
    @State private var workspaceToRestore: Workspace?
    @State private var restoreNotice: String?

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sessionManager.sessions.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section("保存当前工作区") {
                    TextField("工作区名称", text: $name)
                        .onSubmit(saveCurrent)
                    HStack {
                        Text(L("%lld 个标签页", sessionManager.sessions.count))
                        Spacer()
                        Text(L("监控和文件面板状态会一并保存。"))
                            .foregroundStyle(.secondary)
                    }
                    Button("保存") { saveCurrent() }
                        .disabled(!canSave)
                }

                Section("已保存的工作区") {
                    if workspaceStore.workspaces.isEmpty {
                        ContentUnavailableView(
                            "没有已保存的工作区。",
                            systemImage: "rectangle.3.group",
                            description: Text("打开标签页后，为当前布局命名并保存。")
                        )
                    } else {
                        ForEach(workspaceStore.workspaces) { workspace in
                            workspaceRow(workspace)
                        }
                    }
                }
            }
            .navigationTitle("工作区")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .confirmationDialog(
            "恢复工作区",
            isPresented: Binding(
                get: { workspaceToRestore != nil },
                set: { if !$0 { workspaceToRestore = nil } }
            ),
            titleVisibility: .visible,
            presenting: workspaceToRestore
        ) { workspace in
            Button("恢复", role: .destructive) { restore(workspace) }
            Button("取消", role: .cancel) { workspaceToRestore = nil }
        } message: { workspace in
            Text(L("将关闭当前 %lld 个标签页并恢复“%@”。", sessionManager.sessions.count, workspace.name))
        }
        .alert(
            "工作区",
            isPresented: Binding(
                get: { restoreNotice != nil },
                set: { if !$0 { restoreNotice = nil } }
            )
        ) {
            Button("好", role: .cancel) { restoreNotice = nil }
        } message: {
            Text(restoreNotice ?? "")
        }
        .alert(
            "工作区存储出错",
            isPresented: Binding(
                get: { workspaceStore.lastError != nil },
                set: { if !$0 { workspaceStore.lastError = nil } }
            )
        ) {
            Button("好", role: .cancel) { workspaceStore.lastError = nil }
        } message: {
            Text(workspaceStore.lastError ?? "")
        }
        .localized(localization)
    }

    private func workspaceRow(_ workspace: Workspace) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.3.group")
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(workspace.name)
                    .font(.headline)
                Text(workspaceSummary(workspace))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if missingHostCount(in: workspace) > 0 {
                    Text(L("含 %lld 台不存在的主机，恢复时将跳过。", missingHostCount(in: workspace)))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            Button("恢复") { workspaceToRestore = workspace }
                .buttonStyle(.borderedProminent)
            Button(role: .destructive) {
                workspaceStore.delete(workspace)
            } label: {
                Image(systemName: "trash")
            }
            .help("删除工作区")
        }
        .padding(.vertical, 3)
    }

    private func saveCurrent() {
        workspaceStore.saveCurrent(
            name: name,
            sessions: sessionManager.sessions,
            selectedSessionID: sessionManager.selectedSessionID,
            monitorPanelVisible: monitorPanelVisible,
            filePanelVisible: filePanelVisible
        )
        name = ""
    }

    private func restore(_ workspace: Workspace) {
        workspaceToRestore = nil
        let result = workspaceStore.restore(
            workspace,
            hostStore: hostStore,
            sessionManager: sessionManager
        )
        if !result.replacedCurrentSessions {
            restoreNotice = L("工作区中的主机已不可用，当前标签页未关闭。")
            return
        }
        monitorPanelVisible = workspace.monitorPanelVisible
        filePanelVisible = workspace.filePanelVisible
        if result.skippedHostCount > 0 {
            restoreNotice = L("已恢复 %lld 个标签页，跳过 %lld 台不存在的主机。", result.restoredTabCount, result.skippedHostCount)
        }
    }

    private func workspaceSummary(_ workspace: Workspace) -> String {
        L("%lld 台主机 · %lld 个标签页", workspace.hostIDs.count, workspace.tabs.count)
    }

    private func missingHostCount(in workspace: Workspace) -> Int {
        let savedIDs = Set(hostStore.hosts.map(\.id))
        return workspace.hostIDs.reduce(into: 0) { count, id in
            if !savedIDs.contains(id) { count += 1 }
        }
    }
}
