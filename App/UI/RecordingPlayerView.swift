import AppKit
import HarborKit
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

/// Replays a recorded terminal session: a read-only terminal on top, a transport
/// bar (play/pause, scrubber, speed, elapsed / total time) below, and an "open"
/// affordance to pick a recording from `~/Library/Logs/Harbor`.
struct RecordingPlayerView: View {
    @StateObject private var player = RecordingPlayer()

    /// Scrubber state. While the user drags, the slider shows `scrubValue` and
    /// playback is paused; on release we seek and (if it was playing) resume.
    @State private var isScrubbing = false
    @State private var scrubValue = 0.0
    @State private var resumeAfterScrub = false
    @State private var searchVisible = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if searchVisible {
                recordingSearchBar
                Divider()
            }
            terminalArea
            Divider()
            transportBar
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(DS.Colors.panelBackground)
    }

    // MARK: - Terminal

    private var terminalArea: some View {
        ZStack {
            RecordingTerminalView(player: player)
            // Shown only before a recording is loaded, so nothing meaningful is
            // ever covered (the terminal is blank at that point).
            if !player.hasRecording {
                emptyHint
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(L("打开一个会话录制文件开始回放"))
                .foregroundStyle(.secondary)
            Button(L("打开录制文件…")) { openRecording() }
                .buttonStyle(.borderedProminent)
        }
        .padding(DS.Space.xl)
    }

    // MARK: - Transport bar

    private var transportBar: some View {
        HStack(spacing: DS.Space.m) {
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!player.hasRecording)
            .help(player.isPlaying ? L("暂停") : L("播放"))

            Text(timeLabel(player.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(value: sliderBinding, in: 0 ... 1, onEditingChanged: onScrub)
                .controlSize(.small)
                .disabled(!player.hasRecording)

            Text(timeLabel(player.totalDuration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            speedMenu

            Button { openRecording() } label: {
                Image(systemName: "folder")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("打开录制文件"))

            Button {
                searchVisible.toggle()
                if searchVisible {
                    DispatchQueue.main.async { searchFocused = true }
                } else {
                    searchText = ""
                    player.search("")
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!player.hasRecording)
            .help(L("搜索录制内容"))
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .background(DS.Colors.chromeBackground)
    }

    private var recordingSearchBar: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(L("搜索录制内容"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit { player.search(searchText) }
                .onChange(of: searchText) { _, value in
                    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        player.search("")
                    }
                }

            if player.isSearching {
                ProgressView().controlSize(.small)
            } else if !searchText.isEmpty {
                searchMatchesMenu
            }

            Button { player.selectPreviousSearchMatch() } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(player.searchMatches.isEmpty)
            .help(L("查找上一个"))

            Button { player.selectNextSearchMatch() } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(player.searchMatches.isEmpty)
            .help(L("查找下一个"))

            Button {
                searchVisible = false
                searchText = ""
                player.search("")
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help(L("关闭查找"))
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .background(DS.Colors.chromeBackground)
    }

    private var searchMatchesMenu: some View {
        Menu {
            if player.searchMatches.isEmpty {
                Text(L("无匹配"))
            } else {
                ForEach(Array(player.searchMatches.enumerated()), id: \.element.id) { index, match in
                    Button(match.preview) { player.selectSearchMatch(at: index) }
                }
            }
        } label: {
            let selected = player.selectedSearchMatchIndex.map { $0 + 1 } ?? 0
            Text("\(selected)/\(player.searchMatches.count)")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 34)
        }
        .menuStyle(.borderlessButton)
        .disabled(player.searchMatches.isEmpty)
    }

    private var speedMenu: some View {
        Menu {
            ForEach(RecordingPlayer.Speed.allCases) { option in
                Button {
                    player.speed = option
                } label: {
                    if player.speed == option {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            Text(player.speed.label)
                .font(.caption.monospacedDigit())
                .frame(minWidth: 30)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!player.hasRecording)
        .help(L("播放速度"))
    }

    // MARK: - Scrubbing

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { isScrubbing ? scrubValue : player.progress },
            set: { scrubValue = $0 }
        )
    }

    private func onScrub(_ editing: Bool) {
        if editing {
            resumeAfterScrub = player.isPlaying
            isScrubbing = true
            player.pause()
        } else {
            player.seek(toFraction: scrubValue)
            isScrubbing = false
            if resumeAfterScrub { player.play() }
        }
    }

    // MARK: - Open panel

    private func openRecording() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = L("选择会话录制文件")
        panel.prompt = L("打开")

        var types: [UTType] = [.plainText, .data]
        if let log = UTType(filenameExtension: "log") { types.insert(log, at: 0) }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true

        let logsDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Harbor", isDirectory: true)
        if FileManager.default.fileExists(atPath: logsDir.path) {
            panel.directoryURL = logsDir
        }

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        player.load(url: url)
    }

    // MARK: - Formatting

    /// `mm:ss`, or `h:mm:ss` for recordings longer than an hour.
    private func timeLabel(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Read-only terminal

/// Embeds a bare SwiftTerm `TerminalView` for playback. No `terminalDelegate`
/// is wired, so the view is inherently read-only: any keystrokes would resolve
/// to the absent delegate and do nothing. The `RecordingPlayer` feeds recorded
/// bytes into it and applies the user's font / theme.
private struct RecordingTerminalView: NSViewRepresentable {
    @ObservedObject var player: RecordingPlayer

    @AppStorage("terminalFontName") private var terminalFontName = "Menlo"
    @AppStorage("terminalFontSize") private var terminalFontSize = 13.0
    @AppStorage("themeID") private var themeID = TerminalTheme.defaultThemeID

    final class Coordinator {
        var appliedThemeID: String?
        var appliedFontName: String?
        var appliedFontSize: CGFloat?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalView {
        let font = resolvedFont()
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480), font: font)
        let theme = TerminalTheme.theme(withID: themeID)
        view.apply(theme: theme)
        view.wantsLayer = true
        view.layer?.backgroundColor = theme.background.nsColor.cgColor

        player.terminal = view
        context.coordinator.appliedThemeID = themeID
        context.coordinator.appliedFontName = terminalFontName
        context.coordinator.appliedFontSize = CGFloat(terminalFontSize)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        if player.terminal !== view { player.terminal = view }

        let size = CGFloat(terminalFontSize)
        if context.coordinator.appliedFontName != terminalFontName
            || context.coordinator.appliedFontSize != size {
            view.font = resolvedFont()
            context.coordinator.appliedFontName = terminalFontName
            context.coordinator.appliedFontSize = size
        }

        if context.coordinator.appliedThemeID != themeID {
            let theme = TerminalTheme.theme(withID: themeID)
            view.apply(theme: theme)
            view.layer?.backgroundColor = theme.background.nsColor.cgColor
            context.coordinator.appliedThemeID = themeID
        }
    }

    private func resolvedFont() -> NSFont {
        let size = CGFloat(terminalFontSize)
        return NSFont(name: terminalFontName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
