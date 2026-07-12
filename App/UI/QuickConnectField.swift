import SwiftUI
import HarborKit

/// Bridges ⌘T to a quick-connect field that is not mounted yet: when the
/// sidebar is collapsed, ContentView reopens it and records a pending
/// request; the freshly mounted sidebar field picks it up in `onAppear`
/// (same pattern as `CommandStripFocus` for ⌘L un-hiding the strip).
@MainActor
enum QuickConnectFocus {
    private static var pendingSince: Date?

    static func requestPending() {
        pendingSince = Date()
    }

    /// True when a recent request is still unserved (field was not mounted yet).
    static func consumePending() -> Bool {
        defer { pendingSince = nil }
        guard let since = pendingSince else { return false }
        return Date().timeIntervalSince(since) < 1.0
    }
}

/// Quick-connect text field accepting `[user@]host[:port]`. Enter opens an
/// ad-hoc session (not saved — the tab bar offers "保存为主机…" afterwards).
/// Shared by the empty state and the sidebar footer; styled as a rounded
/// prompt-like field with a ⌘T hint.
struct QuickConnectField: View {
    /// Which placement this instance is; Cmd+T focuses the matching one.
    enum Placement: String {
        case sidebar
        case emptyState
    }

    var placement: Placement = .sidebar

    @EnvironmentObject private var sessionManager: SessionManager
    @State private var text = ""
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isFocused ? Color.accentColor : Color.secondary)
                TextField("快速连接", text: $text, prompt: Text("user@host:port"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($isFocused)
                    .onSubmit(connect)
                if !isFocused && text.isEmpty {
                    Text("⌘T")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.07))
                        )
                }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.medium)
                    .fill(DS.Colors.fieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.medium)
                    .strokeBorder(
                        isFocused ? Color.accentColor.opacity(0.7) : DS.Colors.separator.opacity(0.6),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.medium))
            .onTapGesture { isFocused = true }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(DS.Colors.statusError)
            }
        }
        .help("快速连接：[user@]host[:port]，回车打开会话 (⌘T)")
        .onChange(of: text) { errorMessage = nil }
        .onAppear {
            // ⌘T arrived while the sidebar was collapsed: the field has just
            // been mounted by ContentView reopening the column — grab focus.
            if placement == .sidebar, QuickConnectFocus.consumePending() {
                isFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .harborFocusQuickConnect)) { note in
            guard (note.object as? String) == placement.rawValue else { return }
            isFocused = true
        }
    }

    private func connect() {
        do {
            let host = try QuickConnectParser.parse(text)
            errorMessage = nil
            text = ""
            sessionManager.openSession(host: host)
        } catch {
            errorMessage = harborErrorMessage(error)
        }
    }
}
