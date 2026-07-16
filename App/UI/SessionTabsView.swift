import SwiftUI
import HarborKit

/// Detail pane when sessions are open: a theme-tinted tab strip plus a ZStack
/// that keeps every session's terminal mounted (hidden, not destroyed) so
/// scrollback and running processes survive tab switches.
///
/// The strip's background derives from the active terminal theme so the tab
/// bar and the terminal read as one continuous dark surface (FinalShell-style).
struct SessionTabsView: View {
    private let onManageWorkspaces: () -> Void
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var quickCommandStore: QuickCommandStore
    @EnvironmentObject private var localization: LocalizationManager
    @State private var hostToSave: SSHHost?
    @AppStorage("themeID") private var themeID = TerminalTheme.defaultThemeID
    @AppStorage(CommandStripPreference.storageKey)
    private var commandStripVisible = CommandStripPreference.defaultVisible
    @AppStorage(FilePanelPreference.storageKey)
    private var filePanelVisible = FilePanelPreference.defaultVisible

    init(onManageWorkspaces: @escaping () -> Void = {}) {
        self.onManageWorkspaces = onManageWorkspaces
    }

    private var theme: TerminalTheme { TerminalTheme.theme(withID: themeID) }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Rectangle()
                .fill(theme.chromeSeparatorColor)
                .frame(height: 1)
            ZStack {
                ForEach(sessionManager.sessions) { session in
                    SessionTerminalPane(
                        session: session,
                        theme: theme,
                        isSelected: session.id == sessionManager.selectedSessionID,
                        onReconnect: { sessionManager.reconnect(session) },
                        onClose: { sessionManager.close(session) }
                    )
                    .opacity(session.id == sessionManager.selectedSessionID ? 1 : 0)
                    .allowsHitTesting(session.id == sessionManager.selectedSessionID)
                }
            }
            // FinalShell's 命令输入 strip, docked under the terminal. Same
            // theme-tinted chrome as the tab bar; hidden via ⌘⇧L or when no
            // session is selected.
            if commandStripVisible, let selected = sessionManager.selectedSession {
                CommandStripView(session: selected, theme: theme)
                    // Reset the strip's per-session @State (half-typed draft,
                    // find query, broadcast toggle, navigator cursor) when the
                    // selected tab changes — otherwise a draft typed in tab A
                    // carries over and could be sent to tab B's host. Mirrors the
                    // .id on BottomPanelView below. The shared command history
                    // survives because CommandHistoryStore reloads from
                    // UserDefaults on recreation.
                    .id(selected.id)
            }
            // FinalShell's bottom drawer (⌘J): the 文件 | 命令 tabs. Standard
            // chrome — unlike the theme-tinted strips above, it follows the app
            // appearance. The 命令 library is shared across sessions; the 文件
            // browser is per-session (path/selection reset on the .id below).
            if filePanelVisible, let selected = sessionManager.selectedSession,
               let files = sessionManager.files(for: selected) {
                BottomPanelView(
                    session: selected,
                    fileService: files,
                    commandStore: quickCommandStore,
                    send: { sendToTerminal($0, session: selected) },
                    dockerService: sessionManager.docker(for: selected)
                )
                .id(selected.id) // fresh selection/path state per session
            }
        }
        .background(theme.backgroundColor)
    }

    /// Sends one command line to a session's terminal (text + newline), the same
    /// path the command strip uses. Guards against a non-running session so a
    /// click on the 命令 panel never writes into an exited PTY.
    private func sendToTerminal(_ command: String, session: TerminalSession) {
        guard session.state == .running else { return }
        session.terminalView.send(txt: command + "\n")
        session.terminalView.scrollToBottom()
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.xs) {
                    ForEach(sessionManager.sessions) { session in
                        SessionTabItem(
                            session: session,
                            theme: theme,
                            isSelected: session.id == sessionManager.selectedSessionID,
                            onSelect: { sessionManager.selectedSessionID = session.id },
                            onClose: { sessionManager.close(session) },
                            onCloseOthers: {
                                let others = sessionManager.sessions.filter { $0.id != session.id }
                                others.forEach { sessionManager.close($0) }
                            },
                            onDuplicate: { sessionManager.clone(session) }
                        )
                    }
                    GlassEffectContainer { newTabMenu }
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, 5)
            }
            Spacer(minLength: 0)
            workspaceButton
            saveAsHostButton
        }
        .background(theme.chromeBackgroundColor)
        // Glass + controls must render for the strip's tone (it is
        // appearance-independent, like the command strip / exited banner).
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .sheet(item: $hostToSave) { host in
            HostEditorView(title: L("保存为主机"), host: host) { hostStore.add($0) }
                .localized(localization)
        }
    }

    private var workspaceButton: some View {
        Button(action: onManageWorkspaces) {
            Label("工作区", systemImage: "rectangle.3.group")
                .font(.callout)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .padding(.trailing, DS.Space.s)
        .help("保存或恢复工作区")
    }

    /// FinalShell-style "+": open a saved host in a new tab, or jump to quick
    /// connect. Sits in a Liquid Glass chip so it is clearly a button on the
    /// dark, theme-tinted strip.
    private var newTabMenu: some View {
        Menu {
            ForEach(hostStore.hosts) { host in
                Button(host.displayName) { sessionManager.openSession(host: host) }
            }
            if !hostStore.hosts.isEmpty { Divider() }
            Button("快速连接…") {
                NotificationCenter.default.post(
                    name: .harborFocusQuickConnect,
                    object: QuickConnectField.Placement.sidebar.rawValue
                )
            }
            Divider()
            Button("本地终端") {
                sessionManager.openLocalSession()
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .bold))
                // Accent-colored so the "connect another server" affordance is
                // obviously a button on the dark tinted strip (it used to nearly
                // vanish in muted theme gray).
                .foregroundStyle(SwiftUI.Color.accentColor)
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.small + 1)
                .fill(SwiftUI.Color.accentColor.opacity(0.16))
        }
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.small + 1)
                .strokeBorder(SwiftUI.Color.accentColor.opacity(0.55), lineWidth: 1)
        }
        .help("连接新服务器")
    }

    /// Shown when the selected session targets a host that is not in the
    /// store (a quick-connect ad-hoc target): one click saves it. Prominent
    /// Liquid Glass so it stands out as the call-to-action on the strip.
    @ViewBuilder
    private var saveAsHostButton: some View {
        if let session = sessionManager.selectedSession,
           hostStore.host(withID: session.host.id) == nil {
            Button {
                hostToSave = session.host
            } label: {
                Label("保存为主机…", systemImage: "square.and.arrow.down")
                    .font(.callout)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .padding(.trailing, DS.Space.s + 2)
            .help("把这个快速连接目标保存为主机")
        }
    }
}

/// One tab: state dot, live title, hover-revealed close button. Colors come
/// from the terminal theme so the strip blends with the terminal background.
struct SessionTabItem: View {
    // Not @ObservedObject — session.title fires 1-3×/sec and would rebuild
    // all tab items + force a GlassEffectContainer re-rasterization on every
    // title escape. We subscribe only to the three properties we actually read.
    let session: TerminalSession
    let theme: TerminalTheme
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onDuplicate: () -> Void

    @State private var isHovering = false
    @State private var title = ""
    @State private var isRecording = false
    @State private var sessionState: TerminalSession.State = .connecting
    @State private var currentDirectory: String? = nil
    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 7, height: 7)
                .accessibilityLabel(stateAccessibilityLabel)
            if isRecording {
                Circle()
                    .fill(Color.red)
                    .frame(width: 5, height: 5)
                    .accessibilityLabel("录制中")
            }
            if session.host.connectionProtocol == .local {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? theme.chromePrimaryTextColor : theme.chromeSecondaryTextColor)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isSelected ? theme.chromePrimaryTextColor : theme.chromeSecondaryTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let cwd = currentDirectory {
                    Text(URL(fileURLWithPath: cwd).lastPathComponent)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: 150, alignment: .leading)
            closeButton
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.small + 1)
                .fill(tabFill)
        )
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.small + 1))
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("关闭标签页") { onClose() }
            Button("关闭其他标签页") { onCloseOthers() }
            Divider()
            Button("复制标签页") { onDuplicate() }
            Divider()
            Button("重命名标签页") {
                renameText = title
                isRenaming = true
            }
        }
        .popover(isPresented: $isRenaming) {
            HStack(spacing: DS.Space.s) {
                TextField("标签页名称", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit {
                        session.rename(to: renameText)
                        isRenaming = false
                    }
                Button("确定") {
                    session.rename(to: renameText)
                    isRenaming = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding()
        }
        .help(session.host.displayName)
        .onAppear {
            title = session.title
            isRecording = session.isRecording
            sessionState = session.state
            currentDirectory = session.currentDirectory
        }
        .onReceive(session.$title) { title = $0 }
        .onReceive(session.$isRecording) { isRecording = $0 }
        .onReceive(session.$state) { sessionState = $0 }
        .onReceive(session.$currentDirectory) { currentDirectory = $0 }
    }

    private var tabFill: Color {
        if isSelected { return theme.chromeActiveColor }
        if isHovering { return theme.chromeHoverColor }
        return .clear
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(theme.chromeSecondaryTextColor)
                .frame(width: 14, height: 14)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isHovering || isSelected ? 1 : 0)
        .help("关闭标签页 (⌘W)")
    }

    private var stateColor: Color {
        switch sessionState {
        case .connecting: return DS.Colors.statusConnecting
        case .running: return DS.Colors.statusRunning
        case .exited(let code): return (code ?? 1) == 0 ? DS.Colors.statusIdle : DS.Colors.statusError
        }
    }

    private var stateAccessibilityLabel: String {
        switch sessionState {
        case .connecting: return L("连接中")
        case .running: return L("已连接")
        case .exited(let code): return (code ?? 1) == 0 ? L("已断开") : L("连接出错")
        }
    }
}

/// Terminal plus a compact "会话已结束" banner.
///
/// The banner sits BELOW the terminal (FinalShell command-strip position) so
/// the final output — host-key errors, last lines of a crashed job — stays
/// fully visible, scrollable and copyable. Never a covering overlay.
struct SessionTerminalPane: View {
    // Not @ObservedObject — title escapes fire 1-3×/sec and would re-run
    // the entire pane + TerminalHostingView.updateNSView at that rate.
    let session: TerminalSession
    let theme: TerminalTheme
    let isSelected: Bool
    let onReconnect: () -> Void
    let onClose: () -> Void

    @State private var sessionState: TerminalSession.State = .connecting
    @State private var autoReconnectAttempt = 0

    var body: some View {
        VStack(spacing: 0) {
            TerminalHostingView(session: session, isSelected: isSelected)
            if case .exited(let code) = sessionState {
                exitedBanner(code: code)
            }
        }
        .onAppear {
            sessionState = session.state
            autoReconnectAttempt = session.autoReconnectAttempt
        }
        .onReceive(session.$state) { sessionState = $0 }
        .onReceive(session.$autoReconnectAttempt) { autoReconnectAttempt = $0 }
    }

    private func exitedBanner(code: Int32?) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(theme.chromeSeparatorColor)
                .frame(height: 1)
            HStack(spacing: DS.Space.s + 2) {
                let reconnecting = autoReconnectAttempt > 0
                Image(systemName: reconnecting ? "arrow.triangle.2.circlepath" : "bolt.horizontal.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(reconnecting ? DS.Colors.statusConnecting : statusColor(code: code))
                Text(reconnecting ? L("连接已断开，正在自动重连…") : L("会话已结束"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.chromePrimaryTextColor)
                Text(reconnecting
                     ? L("第 %lld 次尝试（共 %lld 次）", autoReconnectAttempt, 5)
                     : exitDescription(code: code))
                    .font(.callout)
                    .foregroundStyle(theme.chromeSecondaryTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: DS.Space.m)
                GlassEffectContainer(spacing: DS.Space.s) {
                    HStack(spacing: DS.Space.s) {
                        Button(reconnecting ? L("立即重连") : L("重新连接"), action: onReconnect)
                            .buttonStyle(.glassProminent)
                            .controlSize(.small)
                            .help(L("重新连接到 %@", session.host.displayName))
                        Button("关闭", action: onClose)
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .help("关闭标签页 (⌘W)")
                    }
                }
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
        }
        .background(theme.chromeBackgroundColor)
        // The banner lives on theme-tinted chrome, independent of the app
        // appearance; render standard controls for the theme's tone so a
        // light window never paints unreadable controls on a dark strip.
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    private func statusColor(code: Int32?) -> Color {
        guard let code, code == 0 else { return DS.Colors.statusError }
        return DS.Colors.statusIdle
    }

    private func exitDescription(code: Int32?) -> String {
        guard let code else { return L("无法建立连接。") }
        if code < 0 { return L("已被信号 %lld 终止。", Int(-code)) }
        return code == 0 ? L("连接已正常断开（退出码 0）。") : L("已退出，退出码 %lld。", Int(code))
    }
}
