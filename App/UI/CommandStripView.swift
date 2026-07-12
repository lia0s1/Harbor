import SwiftUI
import AppKit
import HarborKit
import SwiftTerm

// MARK: - Visibility preference

/// Shared storage for the command strip's visibility: the View-menu toggle
/// (⌘⇧L) and SessionTabsView bind to the same key. Default visible.
enum CommandStripPreference {
    static let storageKey = "commandStripVisible"
    static let defaultVisible = true
}

// MARK: - Focus requests (⌘L)

/// Bridges the ⌘L menu command to the strip for the hidden→visible case.
/// When the strip is already mounted the menu posts `.harborToggleCommandFocus`
/// directly; this enum only handles the race where the view is not yet mounted.
@MainActor
enum CommandStripFocus {
    private static var pendingSince: Date?

    /// Called by the menu when the strip was just un-hidden and is not yet
    /// mounted; the pending timestamp lets `onAppear` pick the request up.
    static func markPending() {
        pendingSince = Date()
    }

    /// True when a recent request is still unserved (strip was not mounted yet).
    static func consumePending() -> Bool {
        defer { pendingSince = nil }
        guard let since = pendingSince else { return false }
        return Date().timeIntervalSince(since) < 1.0
    }
}

// MARK: - Persistent history store

/// App-layer wrapper around HarborKit's pure `CommandHistory`. History is
/// memory-only by default; users may explicitly opt into UserDefaults
/// persistence in Privacy settings (cap 2000, consecutive dupes collapsed).
@MainActor
final class CommandHistoryStore: ObservableObject {
    static let storageKey = HistoryPrivacyPreference.commandStorageKey
    static let shared = CommandHistoryStore()

    @Published private(set) var history: CommandHistory
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let persists = HistoryPrivacyPreference.isPersistenceEnabled(in: defaults)
        if !persists { defaults.removeObject(forKey: Self.storageKey) }
        let stored = persists ? (defaults.stringArray(forKey: Self.storageKey) ?? []) : []
        self.history = CommandHistory(entries: stored)
    }

    func record(_ command: String) {
        history.record(command)
        if HistoryPrivacyPreference.isPersistenceEnabled(in: defaults) {
            defaults.set(history.entries, forKey: Self.storageKey)
        } else {
            defaults.removeObject(forKey: Self.storageKey)
        }
    }

    func clear() {
        history = CommandHistory()
        defaults.removeObject(forKey: Self.storageKey)
    }
}

// MARK: - Uniform command-bar icon button

/// A single, consistent ghost icon button used for every trailing affordance in
/// the command bar (find, history, broadcast, clear). One treatment — a subtle
/// hover/active fill on the theme-tinted chrome — so the row reads as a tidy,
/// uniform cluster instead of three competing glass pills (round-4 redesign).
///
/// This is cheap (no live GPU blur): the command bar is not high-frequency, and
/// a uniform flat ghost button keeps the bar elegant and coherent.
private struct CommandBarIconButton: View {
    let systemName: String
    let help: String
    var isOn = false
    var disabled = false
    let theme: TerminalTheme
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: isOn ? .semibold : .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.small))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .strokeBorder(isOn ? SwiftUI.Color.accentColor.opacity(0.55) : SwiftUI.Color.clear, lineWidth: 1)
        )
        .disabled(disabled)
        .onHover { isHovering = $0 }
        .help(help)
    }

    private var fill: SwiftUI.Color {
        if isOn { return SwiftUI.Color.accentColor.opacity(0.20) }
        if isHovering { return theme.chromeHoverColor }
        return .clear
    }

    private var tint: SwiftUI.Color {
        if disabled { return theme.chromeSecondaryTextColor.opacity(0.6) }
        if isOn { return .accentColor }
        return isHovering ? theme.chromePrimaryTextColor : theme.chromeSecondaryTextColor
    }
}

// MARK: - Command strip

/// FinalShell's 命令输入 strip, docked under the terminal: ONE cohesive, rounded
/// input bar — a prompt chevron, a monospace field, and a single uniform
/// trailing icon row (find / history / broadcast / clear) plus a slim primary
/// Send. Lives on theme-tinted chrome (like the tab strip), independent of the
/// app appearance.
///
/// Keys: ⏎ send · ↑/↓ history · ⌘L toggle focus with the terminal.
struct CommandStripView: View {
    @EnvironmentObject private var sessionManager: SessionManager
    // Not @ObservedObject — TerminalSession.title fires ~1–3× per second via
    // shell title escapes, which would re-render the entire strip (including
    // an O(n) history scan) on every tick. We only need to react to state
    // changes, handled below via onReceive(session.$state).
    let session: TerminalSession
    let theme: TerminalTheme

    @ObservedObject private var historyStore = CommandHistoryStore.shared
    @State private var text = ""
    @State private var navigator = CommandHistoryNavigator()
    @State private var broadcast = false
    @State private var findVisible = false
    @State private var findText = ""
    @State private var findStatus: FindStatus = .idle
    @State private var isExited = false
    @State private var pendingRisk: CommandRisk?
    @State private var pendingCommand = ""
    @FocusState private var fieldFocused: Bool
    @FocusState private var findFocused: Bool

    private enum FindStatus: Equatable { case idle, found, notFound }

    var body: some View {
        // Evaluate the history scan once per render; thread it into both readers.
        let suggestion = self.suggestion
        let suggestionSuffix = self.suggestionSuffix(for: suggestion)
        VStack(spacing: 0) {
            Rectangle()
                .fill(theme.chromeSeparatorColor)
                .frame(height: 1)
            if findVisible {
                findBar
                Rectangle()
                    .fill(theme.chromeSeparatorColor.opacity(0.6))
                    .frame(height: 1)
            }
            VStack(alignment: .leading, spacing: 4) {
                inputBar(suggestion: suggestion, suggestionSuffix: suggestionSuffix)
                hintRow(suggestionSuffix: suggestionSuffix)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, 7)
            .disabled(isExited)
            .opacity(isExited ? 0.45 : 1)
        }
        .background(theme.chromeBackgroundColor)
        // Theme-tinted chrome is appearance-independent; render standard
        // controls for the theme's tone (same trick as the exited banner).
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .onAppear {
            isExited = session.state.isExited
            if CommandStripFocus.consumePending() {
                fieldFocused = true
            }
        }
        .onReceive(session.$state) { isExited = $0.isExited }
        .onReceive(NotificationCenter.default.publisher(for: .harborToggleCommandFocus)) { _ in
            toggleFocus()
        }
        .alert(L("确认发送高风险命令"), isPresented: pendingRiskPresented) {
            Button(L("仍然发送"), role: .destructive) {
                sendNow()
                pendingRisk = nil
                pendingCommand = ""
            }
            Button(L("取消"), role: .cancel) {
                pendingRisk = nil
                pendingCommand = ""
            }
        } message: {
            Text("\(pendingRisk?.summary ?? "")\n\n\(pendingCommand)")
        }
    }

    // MARK: Cohesive input bar

    /// The single rounded container: chevron + field + uniform trailing icons +
    /// slim primary Send. No competing glass pills — one coherent surface.
    private func inputBar(suggestion: String, suggestionSuffix: String) -> some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(fieldFocused ? SwiftUI.Color.accentColor : theme.chromeSecondaryTextColor)
                .padding(.leading, DS.Space.s + 2)

            commandField(suggestion: suggestion, suggestionSuffix: suggestionSuffix)

            HStack(spacing: 2) {
                CommandBarIconButton(
                    systemName: "magnifyingglass",
                    help: L("在终端中查找"),
                    isOn: findVisible,
                    theme: theme
                ) { toggleFind() }
                historyButton
                CommandBarIconButton(
                    systemName: "rectangle.on.rectangle",
                    help: broadcast ? L("发送到所有标签页：开") : L("发送到所有标签页：关"),
                    isOn: broadcast,
                    theme: theme
                ) { broadcast.toggle() }
                CommandBarIconButton(
                    systemName: "clear",
                    help: L("清空终端 (clear)"),
                    disabled: isExited,
                    theme: theme
                ) { clearTerminal() }
            }
            .padding(.trailing, 4)

            sendButton
                .padding(.trailing, 4)
        }
        .frame(minHeight: 30)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                .fill(theme.chromeHoverColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                .strokeBorder(
                    fieldFocused ? SwiftUI.Color.accentColor.opacity(0.7) : theme.chromeSeparatorColor,
                    lineWidth: 1
                )
        )
    }

    /// FinalShell-style hint under the bar. Surfaces the ⇥ 补全 affordance the
    /// moment an autosuggestion is available, so the feature is discoverable.
    private func hintRow(suggestionSuffix: String) -> some View {
        Text(suggestionSuffix.isEmpty
             ? "⏎ \(L("发送")) · ↑/↓ \(L("历史命令")) · ⌘L \(L("焦点"))"
             : "⇥ \(L("补全")) · ⏎ \(L("发送")) · ↑/↓ \(L("历史命令"))")
            .font(.system(size: 10))
            .foregroundStyle(theme.chromeSecondaryTextColor.opacity(0.85))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, DS.Space.s + 2)
    }

    // MARK: Field

    /// The most recent history command that extends the current text — the
    /// inline autosuggestion. Empty unless the field is focused and there is a
    /// longer prefix match. (Pure logic + tests live in HarborKit.)
    private var suggestion: String {
        guard fieldFocused, !text.isEmpty else { return "" }
        return historyStore.history.autosuggestion(forPrefix: text) ?? ""
    }

    /// The greyed remainder drawn after the typed text (the part Tab accepts),
    /// derived from an already-computed `suggestion` so history isn't re-scanned.
    private func suggestionSuffix(for suggestion: String) -> String {
        guard suggestion.hasPrefix(text), suggestion.count > text.count else { return "" }
        return String(suggestion.dropFirst(text.count))
    }

    private func commandField(suggestion: String, suggestionSuffix: String) -> some View {
        ZStack(alignment: .leading) {
            // Ghost suggestion behind the field: the typed prefix is drawn clear
            // (to occupy its exact width in the same monospaced font) and the
            // remainder grey. The 5pt leading matches the plain field editor's
            // lineFragmentPadding so the grey suffix lines up after the cursor.
            if !suggestionSuffix.isEmpty {
                Text("\(Text(text).foregroundColor(.clear))\(Text(suggestionSuffix).foregroundColor(theme.chromeSecondaryTextColor.opacity(0.55)))")
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 5)
                    .padding(.vertical, 5)
                    .allowsHitTesting(false)
            }
            TextField(
                "命令输入",
                text: $text,
                prompt: Text("在此输入命令，⏎ 发送…")
            )
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(theme.chromePrimaryTextColor)
            .focused($fieldFocused)
            .onSubmit(send)
            // Tab accepts the autosuggestion; with none, Tab falls through.
            .onKeyPress(.tab) {
                guard !suggestion.isEmpty, suggestion != text else { return .ignored }
                text = suggestion
                navigator.reset()
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard let older = navigator.older(in: historyStore.history, current: text) else {
                    return .ignored
                }
                text = older
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard let newer = navigator.newer(in: historyStore.history) else {
                    return .ignored
                }
                text = newer
                return .handled
            }
            .padding(.vertical, 5)
        }
        .help("命令输入：⏎ 发送，⇥ 补全历史，↑/↓ 历史，⌘L 在终端与输入框间切换焦点")
    }

    // MARK: Send

    /// Slim primary Send — reads as the call-to-action but not bulky.
    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 19))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(text.isEmpty ? AnyShapeStyle(theme.chromeSecondaryTextColor.opacity(0.5))
                                                : AnyShapeStyle(SwiftUI.Color.accentColor))
        }
        .buttonStyle(.plain)
        .disabled(text.isEmpty)
        .help("发送到当前会话 (⏎)")
    }

    // MARK: History

    /// Recent 20 commands, newest first; click inserts into the field. Rendered
    /// as a borderless menu wearing the SAME uniform ghost-button chrome.
    private var historyButton: some View {
        Menu {
            let recents = historyStore.history.recent(20)
            if recents.isEmpty {
                Text("暂无历史命令")
            } else {
                ForEach(Array(recents.enumerated()), id: \.offset) { _, command in
                    Button(command) {
                        text = command
                        navigator.reset()
                        fieldFocused = true
                    }
                }
            }
        } label: {
            Image(systemName: "clock")
                .font(.system(size: 12))
                .foregroundStyle(theme.chromeSecondaryTextColor)
                .frame(width: 28, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.small))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("历史命令")
    }

    // MARK: Find bar

    /// Inline find-in-terminal row, revealed by the magnifier. Wires SwiftTerm's
    /// findNext/findPrevious to select+scroll matches in the selected terminal.
    private var findBar: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.chromeSecondaryTextColor)
                .padding(.leading, DS.Space.s + 2)

            TextField("在终端中查找…", text: $findText)
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(theme.chromePrimaryTextColor)
                .focused($findFocused)
                .onSubmit { find(forward: true) }
                .onChange(of: findText) { _, _ in findStatus = .idle }
                .padding(.vertical, 5)

            if findStatus == .notFound, !findText.isEmpty {
                Text("无匹配")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.statusError)
            }

            CommandBarIconButton(systemName: "chevron.up", help: L("查找上一个"), theme: theme) {
                find(forward: false)
            }
            .disabled(findText.isEmpty)
            CommandBarIconButton(systemName: "chevron.down", help: L("查找下一个"), theme: theme) {
                find(forward: true)
            }
            .disabled(findText.isEmpty)
            CommandBarIconButton(systemName: "xmark", help: L("关闭查找"), theme: theme) {
                closeFind()
            }
            .padding(.trailing, 4)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, 6)
        .background(theme.chromeBackgroundColor)
    }

    // MARK: Behavior

    /// ⏎ / 发送: text + \n into the PTY of the selected session — or of every
    /// live session when broadcast is on — then record history and clear.
    /// Empty field sends a bare \n so interactive prompts (sudo, less, read…) work.
    private func send() {
        guard !isExited else { return }
        if let risk = CommandRiskDetector.detect(in: text) {
            pendingRisk = risk
            pendingCommand = text
            return
        }
        sendNow()
    }

    private func sendNow() {
        guard !isExited else { return }
        let payload = text.isEmpty ? "\n" : text + "\n"
        let targets: [TerminalSession] = broadcast
            ? sessionManager.sessions.filter { !$0.state.isExited }
            : [session]
        for target in targets {
            target.terminalView.send(txt: payload)
            target.terminalView.scrollToBottom()
        }
        if !text.isEmpty {
            historyStore.record(text)
            text = ""
            navigator.reset()
        }
    }

    private var pendingRiskPresented: Binding<Bool> {
        Binding(get: { pendingRisk != nil }, set: { if !$0 { pendingRisk = nil } })
    }

    /// Clear: send `clear\n` to the PTY so the remote shell clears its own
    /// screen (and scrollback where the shell supports it) — remote-aware,
    /// consistent with how Send reaches the terminal. Broadcast-aware.
    private func clearTerminal() {
        guard !isExited else { return }
        let payload = "clear\n"
        let targets: [TerminalSession] = broadcast
            ? sessionManager.sessions.filter { !$0.state.isExited }
            : [session]
        for target in targets {
            target.terminalView.send(txt: payload)
            target.terminalView.scrollToBottom()
        }
    }

    /// Toggle the inline find bar; focus its field when shown, clear search on hide.
    private func toggleFind() {
        if findVisible {
            closeFind()
        } else {
            findVisible = true
            findStatus = .idle
            DispatchQueue.main.async { findFocused = true }
        }
    }

    private func closeFind() {
        findVisible = false
        findStatus = .idle
        session.terminalView.clearSearch()
        // Hand focus back to the terminal so the user keeps working.
        let terminal = session.terminalView
        DispatchQueue.main.async {
            guard let window = terminal.window, terminal.superview != nil else { return }
            window.makeFirstResponder(terminal)
        }
    }

    /// Run a find in the selected terminal (find is per-terminal, never broadcast).
    private func find(forward: Bool) {
        guard !findText.isEmpty else { return }
        let hit = forward
            ? session.terminalView.findNext(findText)
            : session.terminalView.findPrevious(findText)
        findStatus = hit ? .found : .notFound
    }

    /// ⌘L: field focused -> hand focus back to the terminal; otherwise grab it.
    private func toggleFocus() {
        if fieldFocused {
            fieldFocused = false
            let terminal = session.terminalView
            DispatchQueue.main.async {
                guard let window = terminal.window, terminal.superview != nil else { return }
                window.makeFirstResponder(terminal)
            }
        } else {
            fieldFocused = true
        }
    }
}
