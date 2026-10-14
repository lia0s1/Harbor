import SwiftUI
import AppKit
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
                            canCloseOthers: sessionManager.sessions.count > 1,
                            onDuplicate: { sessionManager.clone(session) },
                            onReconnect: { sessionManager.reconnect(session) }
                        )
                    }
                    GlassEffectContainer { newTabMenu }
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, 3)
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
                Button { sessionManager.openSession(host: host) } label: {
                    // Same identity mark as the sidebar: real distro logo when
                    // the OS has been detected, colored initial otherwise.
                    Label {
                        Text(host.displayName)
                    } icon: {
                        HostAvatarView(
                            name: host.displayName,
                            osID: host.osID,
                            osName: host.osName,
                            size: 16
                        )
                    }
                }
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

/// One tab: OS logo badged with a live status dot, live title, hover-revealed
/// close button. Colors come from the terminal theme so the strip blends with
/// the terminal background.
struct SessionTabItem: View {
    // Not @ObservedObject — session.title fires 1-3×/sec and would rebuild
    // all tab items + force a GlassEffectContainer re-rasterization on every
    // title escape. We subscribe only to the properties we actually read.
    let session: TerminalSession
    let theme: TerminalTheme
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    var canCloseOthers = true
    let onDuplicate: () -> Void
    let onReconnect: () -> Void

    @EnvironmentObject private var hostStore: HostStore
    @State private var isHovering = false
    @State private var title = ""
    @State private var isRecording = false
    @State private var sessionState: TerminalSession.State = .connecting
    @State private var autoReconnectAttempt = 0
    @State private var currentDirectory: String? = nil
    @State private var isRenaming = false
    @State private var renameText = ""
    /// Brief brightening of the status dot when a BACKGROUND tab shows output
    /// activity (title/cwd escapes are the only public output-adjacent signals;
    /// the selected tab needs no indicator — its terminal is on screen).
    @State private var activityFlash = false
    @State private var activityDecayTask: Task<Void, Never>?
    /// Flash-off deadline, pushed forward by each activity event. The decay
    /// loop reads it through @State storage, so it always sees the latest
    /// push without being cancelled + respawned per title escape.
    @State private var activityDeadline = Date.distantPast
    /// Memoized store-resolved osID — re-resolved on appear and whenever the
    /// store's host list changes, NOT on every title-driven body re-eval (1-3×/sec).
    @State private var resolvedOSID: String?
    @ScaledMetric(relativeTo: .callout) private var titleFontSize: CGFloat = 11.5

    var body: some View {
        HStack(spacing: 5) {
            tabIcon
            if isRecording {
                Circle()
                    .fill(Color.red)
                    .frame(width: 5, height: 5)
                    .accessibilityLabel("录制中")
            }
            // Single line only: the title already carries user@host + cwd
            // (e.g. "root@web:~"), a second line just doubled the strip height.
            Text(title)
                .font(.system(size: titleFontSize))
                .foregroundStyle(isSelected ? theme.chromePrimaryTextColor : theme.chromeSecondaryTextColor)
                .lineLimit(1)
                // Middle truncation keeps the head (host name) AND the tail
                // (often the interesting bit: cwd / running command).
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
            closeButton
        }
        .padding(.leading, 7)
        .padding(.trailing, 4)
        .padding(.vertical, 2.5)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.small + 1)
                .fill(tabFill)
        )
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.small + 1))
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("重新连接") { onReconnect() }
            Divider()
            Button("关闭标签页") { onClose() }
            Button("关闭其他标签页") { onCloseOthers() }
                .disabled(!canCloseOthers)
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
                TextField(L("标签页名称"), text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit {
                        session.rename(to: renameText)
                        isRenaming = false
                    }
                Button(L("确定")) {
                    session.rename(to: renameText)
                    isRenaming = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding()
        }
        .help(tooltip)
        .onAppear {
            title = session.title
            isRecording = session.isRecording
            sessionState = session.state
            autoReconnectAttempt = session.autoReconnectAttempt
            currentDirectory = session.currentDirectory
            resolvedOSID = resolveOSID()
        }
        .onReceive(session.$title) { newTitle in
            title = newTitle
            noteActivity()
        }
        .onReceive(session.$isRecording) { isRecording = $0 }
        .onReceive(session.$state) { sessionState = $0 }
        .onReceive(session.$autoReconnectAttempt) { autoReconnectAttempt = $0 }
        .onReceive(session.$currentDirectory) { newDir in
            currentDirectory = newDir
            noteActivity()
        }
        // recordOS writes the SAVED host when it sniffs a distro, so the
        // store's items publisher is the live-upgrade signal for the icon;
        // re-resolving only here keeps the per-title re-renders cheap.
        .onReceive(hostStore.$items) { _ in
            resolvedOSID = resolveOSID()
        }
        .onDisappear {
            activityDecayTask?.cancel()
        }
    }

    // MARK: - Icon (OS logo + status badge)

    /// 13pt identity mark with a 6pt status dot badged on its bottom-right
    /// corner — the FinalShell "which server is this tab" glance, but kept
    /// flat and theme-tinted to stay native.
    private var tabIcon: some View {
        baseIcon
            .frame(width: 13, height: 13)
            .overlay(alignment: .bottomTrailing) {
                statusDot
                    // Ring in the chrome color reads as a cut-out on both the
                    // clear resting tab and the filled selected/hovered pill.
                    .overlay(Circle().strokeBorder(theme.chromeBackgroundColor, lineWidth: 1.4))
                    .offset(x: 2, y: 2)
            }
            .accessibilityLabel(stateAccessibilityLabel)
    }

    @ViewBuilder
    private var baseIcon: some View {
        switch session.host.connectionProtocol {
        case .local:
            // The local shell runs on THIS Mac — the Apple mark is the honest icon.
            Image(systemName: "apple.logo")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? theme.chromePrimaryTextColor : theme.chromeSecondaryTextColor)
        case .rdp:
            OSLogo(osID: "windows")
        case .ssh:
            if let osID = resolvedOSID, osID == "macos" {
                Image(systemName: "apple.logo")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? theme.chromePrimaryTextColor : theme.chromeSecondaryTextColor)
            } else if let osID = resolvedOSID, OSLogo.has(osID) {
                OSLogo(osID: osID)
            } else {
                Image(systemName: "server.rack")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(DS.osColor(resolvedOSID) ?? (isSelected ? theme.chromePrimaryTextColor : theme.chromeSecondaryTextColor))
            }
        }
    }

    /// The session's osID, re-resolved from the store so a distro detected
    /// AFTER the tab opened (recordOS writes to the saved host, not to the
    /// session's connect-time snapshot) still upgrades the icon live. Quick
    /// connects match by destination, mirroring `SessionManager.recordOS`.
    /// Called on appear and on hostStore.$items changes only — the result
    /// lives in `resolvedOSID`, because this scan (and the destination string
    /// builds in the fallback) must not run on every 1-3×/sec title repaint.
    private func resolveOSID() -> String? {
        if let stored = hostStore.host(withID: session.host.id) {
            return stored.osID ?? session.host.osID
        }
        if let match = hostStore.hosts.first(where: {
            SSHCommandBuilder.destination(for: $0) == session.destination
        }) {
            return match.osID ?? session.host.osID
        }
        return session.host.osID
    }

    // MARK: - Status dot

    private var statusDot: some View {
        let dot = Circle()
            .fill(statusDotColor)
            .frame(width: 6, height: 6)
            .scaleEffect(activityFlash ? 1.35 : 1.0)
            .animation(DS.Anim.state, value: activityFlash)
        return Group {
            if statusPulses {
                dot.phaseAnimator([1.0, 0.3]) { content, opacity in
                    content.opacity(opacity)
                } animation: { _ in
                    .easeInOut(duration: 0.7)
                }
            } else {
                dot
            }
        }
    }

    /// Connecting and auto-reconnecting get a gentle breathing pulse; steady
    /// states stay static (no disco strip).
    private var statusPulses: Bool {
        switch sessionState {
        case .connecting: return true
        case .exited: return autoReconnectAttempt > 0
        case .running: return false
        }
    }

    private var statusDotColor: Color {
        switch sessionState {
        case .connecting: return DS.Colors.statusConnecting
        case .running: return DS.Colors.statusRunning
        case .exited(let code):
            if autoReconnectAttempt > 0 { return DS.Colors.statusConnecting }
            return (code ?? 1) == 0 ? DS.Colors.statusIdle : DS.Colors.statusError
        }
    }

    private var stateAccessibilityLabel: String {
        switch sessionState {
        case .connecting: return L("连接中")
        case .running: return L("已连接")
        case .exited(let code):
            if autoReconnectAttempt > 0 { return L("连接已断开，正在自动重连…") }
            return (code ?? 1) == 0 ? L("已断开") : L("连接出错")
        }
    }

    /// Full identity + target + state, so a truncated tab still tells the user
    /// exactly which server it is (FinalShell shows the same trio).
    private var tooltip: String {
        let host = session.host
        var lines = [host.displayName]
        switch host.connectionProtocol {
        case .local:
            lines.append(L("本地终端"))
        case .rdp:
            lines.append("RDP · \(host.hostname):\(host.port)")
        case .ssh:
            let user = host.username.isEmpty ? "" : "\(host.username)@"
            lines.append("\(user)\(host.hostname):\(host.port)")
        }
        lines.append(stateAccessibilityLabel)
        return lines.joined(separator: "\n")
    }

    /// Lights the status dot briefly when a background tab prints something.
    /// The only public output-adjacent signals are the title/cwd publishers
    /// (raw PTY bytes are deliberately not exposed), so this is a proxy — a
    /// shell with a static title simply won't flash. Selected tabs skip it:
    /// their terminal is already on screen.
    ///
    /// One decay loop per flash run: events just push `activityDeadline`
    /// forward. The previous cancel-and-respawn per event churned a Task
    /// allocation + cancellation at shell-escape frequency (1-3×/sec per
    /// background tab) for zero visual difference.
    private func noteActivity() {
        guard !isSelected, sessionState == .running else { return }
        activityDeadline = Date().addingTimeInterval(1.4)
        if !activityFlash { activityFlash = true }
        guard activityDecayTask == nil else { return }
        activityDecayTask = Task { @MainActor in
            while !Task.isCancelled {
                let remaining = activityDeadline.timeIntervalSinceNow
                guard remaining > 0 else { break }
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            activityDecayTask = nil
            if !Task.isCancelled { activityFlash = false }
        }
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
                // 14pt glyph + 5pt padding on each side = 24×24 hit area
                // (≥24pt), while the visible mark stays small.
                .padding(5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pressFeedback()
        .opacity(isHovering || isSelected ? 1 : 0)
        .animation(DS.Anim.state, value: isHovering)
        .accessibilityLabel(L("关闭标签页"))
        .help("关闭标签页 (⌘W)")
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
    @State private var totpPromptVisible = false
    /// Loaded only while the banner is up; never kept on the session.
    @State private var totpSecret: String?
    @State private var zmodemRequest: ZmodemTrigger?
    @State private var zmodemStatus: String?

    var body: some View {
        VStack(spacing: 0) {
            if isSelected,
               totpPromptVisible,
               session.host.connectionProtocol != .local,
               let secret = totpSecret {
                TOTPAutoFillBanner(
                    secret: secret,
                    onSend: { code in
                        guard !code.isEmpty else { return }
                        session.sendTOTPCode(code)
                    },
                    onDismiss: {
                        totpSecret = nil
                        totpPromptVisible = false
                        session.dismissTOTPPrompt()
                    }
                )
                .padding(.horizontal, DS.Space.m)
                .padding(.top, DS.Space.s)
                .padding(.bottom, DS.Space.xs)
            }
            if isSelected, let trigger = zmodemRequest {
                zmodemRequestBanner(trigger: trigger)
                    .padding(.horizontal, DS.Space.m)
                    .padding(.top, DS.Space.s)
                    .padding(.bottom, DS.Space.xs)
            } else if isSelected, let status = zmodemStatus {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundStyle(.secondary)
                    Text(status)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(L("取消")) { session.cancelZmodemTransfer() }
                        .controlSize(.small)
                }
                .padding(.horizontal, DS.Space.m)
                .padding(.top, DS.Space.s)
                .padding(.bottom, DS.Space.xs)
            }
            TerminalHostingView(session: session, isSelected: isSelected)
            if case .exited(let code) = sessionState {
                exitedBanner(code: code)
            }
        }
        .onAppear {
            sessionState = session.state
            autoReconnectAttempt = session.autoReconnectAttempt
            syncTOTPBanner(visible: session.totpPromptVisible)
            zmodemRequest = session.zmodemRequest
            zmodemStatus = session.zmodemStatus
        }
        .onReceive(session.$state) { sessionState = $0 }
        .onReceive(session.$autoReconnectAttempt) { autoReconnectAttempt = $0 }
        .onReceive(session.$totpPromptVisible) { syncTOTPBanner(visible: $0) }
        .onReceive(session.$zmodemRequest) { zmodemRequest = $0 }
        .onReceive(session.$zmodemStatus) { zmodemStatus = $0 }
    }

    /// Banner shown when the remote ran `rz`/`sz`: pick files (or a download
    /// destination) to accept, flip the detected direction (covers `sz -q`),
    /// or dismiss.
    private func zmodemRequestBanner(trigger: ZmodemTrigger) -> some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "arrow.up.arrow.down")
                .foregroundStyle(.secondary)
            Text(trigger == .upload
                 ? L("检测到 ZModem 上传请求（远程执行了 rz）")
                 : L("检测到 ZModem 下载请求（远程执行了 sz）"))
                .font(.callout)
                .lineLimit(1)
            Spacer()
            Button(trigger == .upload ? L("选择文件…") : L("选择保存目录…")) {
                pickZmodemTarget(for: trigger)
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            Button(trigger == .upload ? L("改为下载") : L("改为上传")) {
                session.switchZmodemDirection()
            }
            .controlSize(.small)
            Button(L("取消")) { session.dismissZmodemRequest() }
                .controlSize(.small)
        }
    }

    private func pickZmodemTarget(for trigger: ZmodemTrigger) {
        let panel = NSOpenPanel()
        if trigger == .upload {
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            if panel.runModal() == .OK, !panel.urls.isEmpty {
                session.startZmodemUpload(files: panel.urls)
            }
        } else {
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            if panel.runModal() == .OK, let url = panel.url {
                session.startZmodemDownload(to: url)
            }
        }
    }

    private func syncTOTPBanner(visible: Bool) {
        guard session.host.connectionProtocol != .local else {
            totpPromptVisible = false
            totpSecret = nil
            return
        }
        if visible, let secret = TOTPStore.load(for: session.host.id) {
            totpSecret = secret
            totpPromptVisible = true
        } else {
            totpSecret = nil
            totpPromptVisible = false
            if visible {
                session.dismissTOTPPrompt()
            }
        }
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
                    // Spin while auto-reconnecting so the glyph never reads as
                    // frozen; the indefinite effect stops the moment
                    // `reconnecting` goes false or the banner is removed.
                    .symbolEffect(.rotate, options: .repeating, isActive: reconnecting)
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
