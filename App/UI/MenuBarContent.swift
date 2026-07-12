import SwiftUI
import AppKit
import HarborKit

/// Stable identifiers for the app's scenes, so the menu bar (and dock reopen)
/// can raise or recreate the main window.
enum HarborWindowID {
    static let main = "harbor-main"
}

/// The menu bar (status item) content: quick-connect to any saved host, jump to
/// an active session, or show the main window — so Harbor stays one click away
/// even when its window is closed (the app keeps running in the menu bar).
struct MenuBarContent: View {
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var sessionManager: SessionManager
    // Rebuilds the menu in the live language when it changes.
    @ObservedObject private var localization = LocalizationManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L("显示 Harbor 窗口")) { showMainWindow() }

        if !sessionManager.sessions.isEmpty {
            Section(L("活动会话")) {
                ForEach(sessionManager.sessions) { session in
                    Button(sessionLabel(session)) {
                        sessionManager.selectedSessionID = session.id
                        showMainWindow()
                    }
                }
            }
        }

        Section(L("连接到")) {
            if hostStore.hosts.isEmpty {
                Text(L("暂无已保存的主机"))
            } else {
                ForEach(hostStore.hosts) { host in
                    Button(host.displayName) { connect(host) }
                }
            }
        }

        Divider()
        Button(L("退出 Harbor")) { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    /// `●` marks the currently selected session.
    private func sessionLabel(_ session: TerminalSession) -> String {
        session.id == sessionManager.selectedSessionID ? "● \(session.title)" : "  \(session.title)"
    }

    private func connect(_ host: SSHHost) {
        sessionManager.openSession(host: host)
        showMainWindow()
    }

    /// Raise the existing main window if it is still around; otherwise ask the
    /// WindowGroup to make a fresh one. Avoids spawning duplicate windows.
    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = NSApp.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix(HarborWindowID.main) == true && $0.canBecomeMain
        }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: HarborWindowID.main)
        }
    }
}
