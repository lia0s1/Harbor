import SwiftUI
import HarborKit

struct ContentView: View {
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var quickCommandStore: QuickCommandStore
    @StateObject private var workspaceStore = WorkspaceStore()
    @State private var selectedHostID: UUID?
    /// Bound so ⌘T can reopen a collapsed sidebar (its quick-connect footer
    /// is unmounted while collapsed and would otherwise never get focus).
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @AppStorage(MonitorPanelPreference.storageKey)
    private var monitorPanelVisible = MonitorPanelPreference.defaultVisible
    @AppStorage(FilePanelPreference.storageKey)
    private var filePanelVisible = FilePanelPreference.defaultVisible
    /// Shared with SessionTabsView and CommandStripCommands via the same key;
    /// read here so ⌘F can ensure the strip is visible before focusing find.
    @AppStorage(CommandStripPreference.storageKey)
    private var commandStripVisible = CommandStripPreference.defaultVisible
    @State private var isQuickJumpOpen = false
    @State private var isBatchExecOpen = false
    @State private var showWelcomeGuide = !UserDefaults.standard.bool(forKey: "hasSeenWelcomeGuide")
    @State private var isScriptLibraryOpen = false
    @State private var isRecordingPlayerOpen = false
    @State private var isWorkspaceManagerOpen = false

    var body: some View {
        mainContent
        .onReceive(NotificationCenter.default.publisher(for: .harborFocusQuickConnect)) { note in
            // ⌘T while the sidebar is collapsed: its quick-connect footer is
            // unmounted, so nothing would receive focus. Reopen the sidebar;
            // the freshly mounted field grabs focus in its onAppear (mirrors
            // how ⌘L un-hides the command strip before focusing it).
            guard (note.object as? String) == QuickConnectField.Placement.sidebar.rawValue,
                  columnVisibility == .detailOnly else { return }
            QuickConnectFocus.requestPending()
            columnVisibility = .all
        }
        .onReceive(NotificationCenter.default.publisher(for: .harborFocusFind)) { _ in
            // ⌘F always works: if the command strip is hidden, show it so
            // CommandStripView.onAppear can pick up the pending find-focus marker.
            commandStripVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .harborExportHosts)) { _ in
            HostExportImport.exportHosts(hosts: hostStore.hosts,
                                         commands: quickCommandStore.commands)
        }
        .onReceive(NotificationCenter.default.publisher(for: .harborImportHosts)) { _ in
            HostExportImport.importHosts(hostStore: hostStore,
                                         quickCommandStore: quickCommandStore)
        }
        .onReceive(NotificationCenter.default.publisher(for: .harborQuickJump)) { _ in
            isQuickJumpOpen.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .harborBatchExec)) { _ in
            isBatchExecOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .harborToggleRecording)) { _ in
            guard let session = sessionManager.selectedSession else { return }
            if session.isRecording { session.stopRecording() } else { session.startRecording() }
        }
        .sheet(isPresented: $isBatchExecOpen) {
            BatchExecView()
        }
        .sheet(isPresented: $isWorkspaceManagerOpen) {
            WorkspaceManagerView()
                .frame(minWidth: 560, minHeight: 420)
        }
        .sheet(isPresented: $showWelcomeGuide, onDismiss: {
            UserDefaults.standard.set(true, forKey: "hasSeenWelcomeGuide")
        }) {
            WelcomeGuideView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .harborShowWelcome)) { _ in
            showWelcomeGuide = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .harborScriptLibrary)) { _ in
            isScriptLibraryOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .harborRecordingPlayer)) { _ in
            isRecordingPlayerOpen = true
        }
        .modifier(ToolSheetsModifier(
            isScriptLibraryOpen: $isScriptLibraryOpen,
            isRecordingPlayerOpen: $isRecordingPlayerOpen,
            sessionManager: sessionManager
        ))
        .modifier(SessionConnectionErrorAlert(sessionManager: sessionManager))
        .overlay {
            if isQuickJumpOpen {
                QuickHostJumpView(isPresented: $isQuickJumpOpen)
            }
        }
        .environmentObject(workspaceStore)
    }

    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            HostListView(selectedHostID: $selectedHostID)
                // Cap the max so the sidebar can't be dragged wide enough to
                // starve the detail pane (terminal + tab strip + command strip
                // + file panel) — the "dragging a side panel squeezes the
                // middle" complaint.
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if sessionManager.sessions.isEmpty {
                        EmptyStateView()
                    } else {
                        SessionTabsView(onManageWorkspaces: { isWorkspaceManagerOpen = true })
                    }
                }
                // FinalShell's monitoring rail, as a Mac-native trailing inspector.
                .inspector(isPresented: $monitorPanelVisible) {
                    MonitorPanel()
                        // min 270 so the cards never read as cramped; max 420 caps
                        // how far it can be dragged in, so widening it can't starve
                        // the detail pane.
                        .inspectorColumnWidth(min: 270, ideal: 320, max: 420)
                }
                .toolbar {
                    ContentToolbar(
                        isWorkspaceManagerOpen: $isWorkspaceManagerOpen,
                        filePanelVisible: $filePanelVisible,
                        monitorPanelVisible: $monitorPanelVisible
                    )
                }
                // The host-store error alert stays on the detail pane rather than
                // stacking with the connection-error alert attached below.
                .modifier(HostStoreErrorAlert(hostStore: hostStore))

                // Persistent thin status bar: connection dot, host name, latency.
                SessionStatusBar()
            }
        }
        // No `.navigationTitle`: a prominent centered "Harbor" title competed
        // with the trailing toolbar (file-panel button + SwiftUI's inspector
        // toggle) at the 980pt minimum width and pushed the inspector toggle
        // into a `»` overflow. The window/app is already identified by the dock
        // and About panel, so the chrome stays clean without a title.
        .navigationTitle("")
        // Occlusion guard: below this size sheets (520×600 editor), the tab
        // strip and the sidebar rows start clipping.
        .frame(minWidth: 980, minHeight: 620)
    }
}

private struct HostStoreErrorAlert: ViewModifier {
    @ObservedObject var hostStore: HostStore

    func body(content: Content) -> some View {
        content.alert(
            "主机存储出错",
            isPresented: Binding(
                get: { hostStore.lastError != nil },
                set: { if !$0 { hostStore.lastError = nil } }
            )
        ) {
            Button("好", role: .cancel) { hostStore.lastError = nil }
        } message: {
            Text(hostStore.lastError ?? "")
        }
    }
}

private struct SessionConnectionErrorAlert: ViewModifier {
    @ObservedObject var sessionManager: SessionManager

    func body(content: Content) -> some View {
        content.alert(
            "无法连接",
            isPresented: Binding(
                get: { sessionManager.connectionError != nil },
                set: { if !$0 { sessionManager.connectionError = nil } }
            )
        ) {
            Button("好", role: .cancel) { sessionManager.connectionError = nil }
        } message: {
            Text(sessionManager.connectionError ?? "")
        }
    }
}

private struct ContentToolbar: ToolbarContent {
    @Binding var isWorkspaceManagerOpen: Bool
    @Binding var filePanelVisible: Bool
    @Binding var monitorPanelVisible: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                isWorkspaceManagerOpen = true
            } label: {
                Label("工作区", systemImage: "rectangle.3.group")
            }
            .help("保存或恢复工作区")

            Button {
                filePanelVisible.toggle()
            } label: {
                Label("文件面板", systemImage: "folder")
            }
            .help(filePanelVisible ? L("隐藏文件面板 (⌘J)") : L("显示文件面板 (⌘J)"))

            Button {
                monitorPanelVisible.toggle()
            } label: {
                Label("监控面板", systemImage: "sidebar.right")
            }
            .help(monitorPanelVisible ? L("隐藏监控面板 (⌘I)") : L("显示监控面板 (⌘I)"))
        }

        ToolbarItem(placement: .primaryAction) {
            SettingsLink {
                Label("设置", systemImage: "gearshape")
            }
            .help(L("设置 (⌘,)"))
        }
    }
}

// MARK: - Persistent status bar

/// Thin 22pt bar docked below the main detail pane. Delegates ping observation
/// to `SessionStatusBarContent` so live latency ticks don't re-render the whole
/// content tree.
private struct SessionStatusBar: View {
    @EnvironmentObject private var sessionManager: SessionManager

    var body: some View {
        if let session = sessionManager.selectedSession {
            SessionStatusBarContent(
                session: session,
                ping: sessionManager.ping(for: session)
            )
            // Force recreation (and fresh @State / onReceive) when the active
            // tab changes, mirroring the .id on CommandStripView in SessionTabsView.
            .id(session.id)
        } else {
            idleBar
        }
    }

    private var idleBar: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.gray).frame(width: 6, height: 6)
            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(.bar)
    }
}

private struct SessionStatusBarContent: View {
    let session: TerminalSession
    let ping: PingService?
    @State private var sessionState: TerminalSession.State = .connecting

    private var isConnected: Bool { sessionState == .running }

    private var hostLabel: String {
        let u = session.host.username
        return u.isEmpty ? session.host.displayName : "\(u)@\(session.host.displayName)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isConnected ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Text(hostLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let ping {
                SessionStatusBarPingLabel(ping: ping)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(.bar)
        .onAppear { sessionState = session.state }
        .onReceive(session.$state) { sessionState = $0 }
    }
}

/// Isolated so that per-second ping ticks only re-render this label, not the
/// whole status bar (mirrors the LatencyCardView isolation in MonitorPanel).
private struct SessionStatusBarPingLabel: View {
    @ObservedObject var ping: PingService

    var body: some View {
        if let ms = ping.currentMs {
            Text("\(Int(ms)) ms")
                .foregroundStyle(.secondary)
        }
    }
}

private struct ToolSheetsModifier: ViewModifier {
    @Binding var isScriptLibraryOpen: Bool
    @Binding var isRecordingPlayerOpen: Bool
    let sessionManager: SessionManager
    @StateObject private var scriptStore = ScriptStore()

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isScriptLibraryOpen) {
                ScriptLibraryView(store: scriptStore, send: { text in
                    sessionManager.selectedSession?.sendText(text + "\n")
                })
                .frame(minWidth: 600, minHeight: 450)
            }
            .sheet(isPresented: $isRecordingPlayerOpen) {
                RecordingPlayerView()
                    .frame(minWidth: 700, minHeight: 500)
            }
    }
}

#Preview {
    ContentView()
        .environmentObject(HostStore())
        .environmentObject(SessionManager())
        .environmentObject(QuickCommandStore())
}
