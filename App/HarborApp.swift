import SwiftUI
import AppKit
import HarborKit

/// Quits when the main window closes and terminates child ssh processes on the
/// way out so no orphans linger.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var sessionManager: SessionManager?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Apply the saved window appearance (default 跟随系统) before any
        // window is shown so there is no appearance flash on launch.
        AppAppearance.applyStored()
        // Harbor has its own session tab strip in a single window; native
        // NSWindow tabbing would stack a second, conflicting tab bar on top
        // (and add useless Show Tab Bar / Move Tab items to View/Window).
        NSWindow.allowsAutomaticWindowTabbing = false
        // ControlMaster sockets live in ~/.cache/harbor (mode 700); create it
        // before the first session can spawn ssh.
        ControlMasterSupport.ensureCacheDirectory()
        // Remove any harbor-askpass-* temp dirs left by a previous crash before
        // the defer cleanup could run (password files inside are 0600 and live
        // under the per-user $TMPDIR, but shouldn't linger across launches).
        cleanStaleAskpassDirs()
    }

    private func cleanStaleAskpassDirs() {
        let tmp = FileManager.default.temporaryDirectory.path
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: tmp) else { return }
        for name in entries where name.hasPrefix("harbor-askpass-") {
            try? FileManager.default.removeItem(atPath: (tmp as NSString).appendingPathComponent(name))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Stay alive in the menu bar when the window is closed, so the status
        // item remains usable. Quit via ⌘Q or the menu bar's 退出 item.
        false
    }

    /// Dock-icon click with no open window: reopen / raise the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows
            where window.identifier?.rawValue.hasPrefix(HarborWindowID.main) == true {
                window.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // The user may have changed the system language in System Settings
        // while we were backgrounded; re-resolve `跟随系统` so the UI tracks it.
        LocalizationManager.shared.refreshForSystemChange()
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionManager?.terminateAll()
        JSONStorePersistence.flush()
    }
}

@main
struct HarborApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var quickCommandStore = QuickCommandStore()
    @StateObject private var localization = LocalizationManager.shared

    var body: some Scene {
        WindowGroup(id: HarborWindowID.main) {
            ContentView()
                .environmentObject(sessionManager.hostStore)
                .environmentObject(sessionManager)
                .environmentObject(quickCommandStore)
                .environmentObject(localization)
                // Re-render the whole tree in the new language on switch, and
                // format dates/numbers to match.
                .environment(\.locale, localization.locale)
                .id(localization.revision)
                .onAppear {
                    appDelegate.sessionManager = sessionManager
                }
        }
        // Open at a comfortable working size instead of slamming into the
        // 980×620 occlusion floor (which felt cramped). The content's own
        // `.frame(minWidth:minHeight:)` still enforces that floor on resize.
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            // Menu titles use L() rather than literal LocalizedStringKey so they
            // re-resolve from the live language: SwiftUI's .commands tree is
            // built at App scope (outside the WindowGroup's .id refresh and its
            // injected \.locale), so a literal Text("中文") there is resolved
            // once and would stay stale. L() reads the manager's current
            // .lproj every rebuild, which the localization @StateObject drives.
            CommandGroup(replacing: .appInfo) {
                Button(L("关于 Harbor")) {
                    showAboutPanel()
                }
            }
            // Replace (not append) so the default "New Window" item cannot
            // steal Cmd+N from New Host.
            CommandGroup(replacing: .newItem) {
                Button(L("新建主机")) {
                    NotificationCenter.default.post(name: .harborNewHost, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button(L("快速连接")) {
                    // Focus the quick-connect field the user can actually see:
                    // the empty-state one when no sessions are open, else the
                    // sidebar footer.
                    let placement: QuickConnectField.Placement =
                        sessionManager.sessions.isEmpty ? .emptyState : .sidebar
                    NotificationCenter.default.post(
                        name: .harborFocusQuickConnect,
                        object: placement.rawValue
                    )
                }
                .keyboardShortcut("t", modifiers: .command)
            }
            CommandGroup(replacing: .importExport) {
                Button(L("从 ~/.ssh/config 导入…")) {
                    NotificationCenter.default.post(name: .harborImportConfig, object: nil)
                }
            }
            CommandMenu(L("密钥")) {
                Button(L("复制 SSH 公钥…")) {
                    copySSHPublicKey()
                }
            }
            CommandMenu(L("工具")) {
                Button(L("脚本库")) {
                    NotificationCenter.default.post(name: .harborScriptLibrary, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Button(L("录制回放")) {
                    NotificationCenter.default.post(name: .harborRecordingPlayer, object: nil)
                }
            }
            SessionCommands(sessionManager: sessionManager)
            MonitorCommands()
            FilePanelCommands()
            CommandStripCommands()
            CommandGroup(replacing: .help) {
                Button(L("使用说明")) {
                    HelpWindowController.shared.show()
                }
                .keyboardShortcut("/", modifiers: .command)
                Button(L("欢迎引导")) {
                    UserDefaults.standard.set(false, forKey: "hasSeenWelcomeGuide")
                    NotificationCenter.default.post(name: .harborShowWelcome, object: nil)
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(localization)
                .environment(\.locale, localization.locale)
                .id(localization.revision)
        }

        // Status-bar (menu bar) presence: quick-connect to a saved host or
        // reopen the window even after it is closed. The app keeps running in
        // the menu bar (see AppDelegate.applicationShouldTerminateAfterLastWindowClosed).
        MenuBarExtra(L("Harbor"), systemImage: "sailboat.fill") {
            MenuBarContent()
                .environmentObject(sessionManager.hostStore)
                .environmentObject(sessionManager)
                .environmentObject(localization)
                .environment(\.locale, localization.locale)
        }
    }

    /// Standard About panel with a short credits blurb + author and clickable
    /// contact links (email opens Mail, the site opens in the browser).
    private func showAboutPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let credits = NSMutableAttributedString(
            string: L("原生 SSH 连接管理器。\n终端基于 SwiftTerm；连接使用系统 ssh。"),
            attributes: base
        )
        credits.append(NSAttributedString(string: "\n\n\(L("作者")) Wxcayst\n", attributes: base))
        if let mail = URL(string: "mailto:738888@proton.me") {
            credits.append(NSAttributedString(
                string: "738888@proton.me\n",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .link: mail]))
        }
        if let site = URL(string: "https://caobi.eu") {
            credits.append(NSAttributedString(
                string: "caobi.eu",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .link: site]))
        }
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationName: "Harbor",
        ])
    }

    /// Opens an NSOpenPanel scoped to ~/.ssh to let the user pick a .pub file,
    /// then copies its contents to the clipboard.
    private func copySSHPublicKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let sshDir = ("~/.ssh" as NSString).expandingTildeInPath
        panel.directoryURL = URL(fileURLWithPath: sshDir)
        panel.allowedContentTypes = []
        panel.title = L("选择 SSH 公钥文件")
        panel.prompt = L("复制")

        // Show the panel; the app must be active for it to appear.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension == "pub",
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content.trimmingCharacters(in: .whitespacesAndNewlines),
                                        forType: .string)
    }
}

/// Cmd+W (close tab, falling through to close window) and Cmd+1..9 (select tab).
struct SessionCommands: Commands {
    @ObservedObject var sessionManager: SessionManager
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some Commands {
        // .saveItem is the standard placement of Close/Save; replacing it lets
        // our Close own Cmd+W without a menu shortcut conflict.
        CommandGroup(replacing: .saveItem) {
            Button(closeTitle) {
                let keyWindow = NSApp.keyWindow
                // Only close the tab when the main window (or nothing) has key
                // focus; for auxiliary windows (Settings) close that window.
                if let session = sessionManager.selectedSession,
                   keyWindow == nil || keyWindow === NSApp.mainWindow {
                    sessionManager.close(session)
                } else {
                    keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)

            Button(L("复制会话")) {
                if let session = sessionManager.selectedSession {
                    sessionManager.clone(session)
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(sessionManager.selectedSession == nil)

            Divider()
            Button(L("本地终端")) {
                sessionManager.openLocalSession()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Button(L("批量执行…")) {
                NotificationCenter.default.post(name: .harborBatchExec, object: nil)
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])

            Button(L("快速跳转 (⌘P)")) {
                NotificationCenter.default.post(name: .harborQuickJump, object: nil)
            }
            .keyboardShortcut("p", modifiers: .command)

            Divider()
            Button(sessionManager.selectedSession?.isRecording == true ? L("停止录制") : L("开始录制")) {
                NotificationCenter.default.post(name: .harborToggleRecording, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(sessionManager.selectedSession == nil)
        }

        // Edit menu: clear the selected terminal's scrollback + screen (⌘K),
        // matching Terminal.app. Local-only; never injects into the remote shell.
        CommandGroup(after: .pasteboard) {
            Button(L("清空终端")) {
                sessionManager.selectedSession?.clearBuffer()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(sessionManager.selectedSession == nil)
        }

        CommandGroup(after: .windowList) {
            Divider()
            ForEach(1...9, id: \.self) { number in
                Button(L("选择标签页 %lld", number)) {
                    sessionManager.selectSession(at: number - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                .disabled(number > sessionManager.sessions.count)
            }
        }
    }

    private var closeTitle: String {
        sessionManager.selectedSession == nil ? L("关闭") : L("关闭标签页")
    }
}

/// View > 监控面板 (⌘I): toggles the monitoring inspector. State is shared
/// with ContentView's inspector and toolbar button via the same AppStorage key.
struct MonitorCommands: Commands {
    // Observed so a live language switch rebuilds this menu item with L().
    @ObservedObject private var localization = LocalizationManager.shared
    @AppStorage(MonitorPanelPreference.storageKey)
    private var monitorPanelVisible = MonitorPanelPreference.defaultVisible

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Toggle(L("监控面板"), isOn: $monitorPanelVisible)
                .keyboardShortcut("i", modifiers: .command)
        }
    }
}

/// View > 文件面板 (⌘J): toggles the bottom remote-file drawer. State is
/// shared with SessionTabsView and the toolbar button via the same key.
struct FilePanelCommands: Commands {
    @ObservedObject private var localization = LocalizationManager.shared
    @AppStorage(FilePanelPreference.storageKey)
    private var filePanelVisible = FilePanelPreference.defaultVisible

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Toggle(L("文件面板"), isOn: $filePanelVisible)
                .keyboardShortcut("j", modifiers: .command)
        }
    }
}

/// View > 命令输入栏 (⌘⇧L) shows/hides the strip; the 命令 menu's
/// 聚焦命令输入 (⌘L) toggles focus between the terminal and the field —
/// un-hiding the strip first when needed.
struct CommandStripCommands: Commands {
    @ObservedObject private var localization = LocalizationManager.shared
    @AppStorage(CommandStripPreference.storageKey)
    private var commandStripVisible = CommandStripPreference.defaultVisible

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Toggle(L("命令输入栏"), isOn: $commandStripVisible)
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
        CommandMenu(L("命令")) {
            Button(L("聚焦命令输入")) {
                if commandStripVisible {
                    // Strip is already mounted; signal it directly via the
                    // notification so onReceive is the one and only handler.
                    NotificationCenter.default.post(name: .harborToggleCommandFocus, object: nil)
                } else {
                    // Strip is hidden and not yet mounted; show it and leave a
                    // pending marker so the view's onAppear picks up the request.
                    commandStripVisible = true
                    CommandStripFocus.markPending()
                }
            }
            .keyboardShortcut("l", modifiers: .command)
        }
    }
}

extension Notification.Name {
    /// Posted by the Cmd+N menu item; observed by the sidebar to open the add-host sheet.
    static let harborNewHost = Notification.Name("dev.zero.Harbor.newHost")
    /// Posted by File > Import from ~/.ssh/config…; observed by the sidebar.
    static let harborImportConfig = Notification.Name("dev.zero.Harbor.importConfig")
    /// Posted by Cmd+T; object is the QuickConnectField.Placement rawValue to focus.
    static let harborFocusQuickConnect = Notification.Name("dev.zero.Harbor.focusQuickConnect")
    /// Posted by 命令 > 聚焦命令输入 (⌘L); the command strip toggles focus
    /// between its field and the terminal.
    static let harborToggleCommandFocus = Notification.Name("dev.zero.Harbor.toggleCommandFocus")
    /// Posted by File > 导出主机…; handled by ContentView.
    static let harborExportHosts = Notification.Name("dev.zero.Harbor.exportHosts")
    /// Posted by File > 导入主机…; handled by ContentView.
    static let harborImportHosts = Notification.Name("dev.zero.Harbor.importHosts")
    static let harborQuickJump = Notification.Name("dev.zero.Harbor.quickJump")
    static let harborLocalTerminal = Notification.Name("dev.zero.Harbor.localTerminal")
    static let harborBatchExec = Notification.Name("dev.zero.Harbor.batchExec")
    static let harborToggleRecording = Notification.Name("dev.zero.Harbor.toggleRecording")
    static let harborShowWelcome = Notification.Name("dev.zero.Harbor.showWelcome")
    static let harborScriptLibrary = Notification.Name("dev.zero.Harbor.scriptLibrary")
    static let harborRecordingPlayer = Notification.Name("dev.zero.Harbor.recordingPlayer")
}
