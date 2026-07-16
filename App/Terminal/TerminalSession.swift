import AppKit
import Combine
import HarborKit
import SwiftTerm
import UniformTypeIdentifiers

/// SwiftTerm terminal view subclass that reports the first byte of output, so
/// the owning session can flip from `.connecting` to `.running`.
@MainActor
final class HarborTerminalView: LocalProcessTerminalView {
    var onFirstOutput: (() -> Void)?
    /// Called with every chunk of raw output received from the child process.
    /// Used by TerminalSession to capture output for session recording.
    /// Protected by `interceptorLock`: written on the main thread, read on
    /// SwiftTerm's I/O thread, so a plain var would be a data race.
    private let interceptorLock = NSLock()
    private var _dataInterceptor: (@Sendable (ArraySlice<UInt8>) -> Void)?
    var dataInterceptor: (@Sendable (ArraySlice<UInt8>) -> Void)? {
        get {
            interceptorLock.lock()
            defer { interceptorLock.unlock() }
            return _dataInterceptor
        }
        set {
            interceptorLock.lock()
            defer { interceptorLock.unlock() }
            _dataInterceptor = newValue
        }
    }
    private var sawOutput = false

    /// The view currently driving the shared `NSColorPanel` (text-color picker).
    /// Tracked so a deallocating view only tears down the panel wiring if it is
    /// still the owner — never clobbering another tab's or Settings' live pick.
    private static weak var colorPanelOwner: HarborTerminalView?

    deinit {
        // Drop our hold on the shared color panel so a later color change can't
        // message this freed view. Only if we're still the owner (the panel's
        // target is an unretained reference).
        let identity = ObjectIdentifier(self)
        MainActor.assumeIsolated {
            if let owner = HarborTerminalView.colorPanelOwner,
               ObjectIdentifier(owner) == identity {
                let panel = NSColorPanel.shared
                panel.setTarget(nil)
                panel.setAction(nil)
                HarborTerminalView.colorPanelOwner = nil
            }
        }
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        dataInterceptor?(slice)
        if !sawOutput {
            sawOutput = true
            onFirstOutput?()
        }
    }

    // MARK: - Right-click / two-finger background menu

    /// Secondary-click (right-click or two-finger tap) menu: copy/paste plus
    /// quick terminal-background controls — set a wallpaper image, adjust its
    /// opacity, or clear it. Writes to the same `terminalBackground` preference
    /// the Settings panel uses, so changes apply live to every open session.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        // Control item enabling ourselves: SwiftTerm's TerminalView validates
        // menu items and disables selectors it doesn't recognize (which would
        // grey out our custom background items under auto-validation).
        menu.autoenablesItems = false

        let copyItem = NSMenuItem(title: L("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "")
        copyItem.isEnabled = true
        let pasteItem = NSMenuItem(title: L("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "")
        pasteItem.isEnabled = true
        menu.addItem(copyItem)
        menu.addItem(pasteItem)
        menu.addItem(.separator())

        // Clear scrollback + screen (local only; never touches the remote shell).
        let clearBuffer = NSMenuItem(
            title: L("清空终端"), action: #selector(harborClearBuffer), keyEquivalent: ""
        )
        clearBuffer.target = self
        menu.addItem(clearBuffer)
        menu.addItem(.separator())

        let wallpaper = NSMenuItem(
            title: L("设置背景壁纸…"),
            action: #selector(harborChooseWallpaper), keyEquivalent: ""
        )
        wallpaper.target = self
        menu.addItem(wallpaper)

        let current = TerminalBackgroundPreference.load()
        let opacityItem = NSMenuItem(title: L("背景不透明度"), action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        opacityMenu.autoenablesItems = false
        for percent in [25, 40, 60, 80, 100] {
            let item = NSMenuItem(
                title: "\(percent)%",
                action: #selector(harborSetBackgroundOpacity(_:)), keyEquivalent: ""
            )
            item.target = self
            item.tag = percent
            // Tick the closest current opacity, and only enable when an image is set.
            item.state = Int((current.imageOpacity * 100).rounded()) == percent ? .on : .off
            item.isEnabled = current.wantsImage
            opacityMenu.addItem(item)
        }
        opacityItem.submenu = opacityMenu
        opacityItem.isEnabled = current.wantsImage
        menu.addItem(opacityItem)

        let clear = NSMenuItem(
            title: L("移除自定义背景"),
            action: #selector(harborClearBackground), keyEquivalent: ""
        )
        clear.target = self
        clear.isEnabled = current.mode != .theme
        menu.addItem(clear)

        menu.addItem(.separator())

        let textColor = NSMenuItem(
            title: L("设置文字颜色…"),
            action: #selector(harborChooseTextColor), keyEquivalent: ""
        )
        textColor.target = self
        menu.addItem(textColor)

        let clearText = NSMenuItem(
            title: L("恢复默认文字颜色"),
            action: #selector(harborClearTextColor), keyEquivalent: ""
        )
        clearText.target = self
        // Only meaningful once a custom text color is actually set.
        clearText.isEnabled = current.foreground != nil
        menu.addItem(clearText)

        return menu
    }

    /// Clears scrollback locally (ESC[3J) then sends Ctrl-L so the remote shell
    /// clears its screen and redraws the prompt (a blank, prompt-less screen read
    /// as "frozen"). Ctrl-L only triggers a redraw inside full-screen apps.
    @objc private func harborClearBuffer() {
        feed(text: "\u{1b}[3J")
        send(txt: "\u{0C}")
    }

    @objc private func harborChooseWallpaper() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = L("选择终端背景壁纸")
        panel.prompt = L("选择")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let current = TerminalBackgroundPreference.load()
        saveBackground(TerminalBackground(
            mode: .image,
            color: current.color,
            foreground: current.foreground,
            imagePath: url.path,
            imageOpacity: current.imageOpacity,
            imageBlur: current.imageBlur
        ))
    }

    @objc private func harborSetBackgroundOpacity(_ sender: NSMenuItem) {
        let current = TerminalBackgroundPreference.load()
        saveBackground(TerminalBackground(
            mode: current.mode,
            color: current.color,
            foreground: current.foreground,
            imagePath: current.imagePath,
            imageOpacity: Double(sender.tag) / 100.0,
            imageBlur: current.imageBlur
        ))
    }

    @objc private func harborClearBackground() {
        // Preserve a custom text color when clearing the background: only the
        // background mode/image resets, not the user's chosen foreground.
        let current = TerminalBackgroundPreference.load()
        saveBackground(TerminalBackground(mode: .theme, foreground: current.foreground))
    }

    // MARK: - Text (foreground) color via the shared NSColorPanel

    @objc private func harborChooseTextColor() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        HarborTerminalView.colorPanelOwner = self
        panel.setTarget(self)
        panel.setAction(#selector(harborTextColorChanged(_:)))
        // Seed with the current text color: the custom one if set, else the
        // color the terminal is actually showing now (the theme's foreground).
        let current = TerminalBackgroundPreference.load()
        panel.color = current.foreground?.nsColor ?? nativeForegroundColor
        panel.orderFront(nil)
    }

    /// Live callback as the user drags in the color panel: persist the new
    /// foreground so every open terminal recolors its text in real time.
    @objc private func harborTextColorChanged(_ sender: NSColorPanel) {
        let current = TerminalBackgroundPreference.load()
        // Text is always fully opaque: even with the alpha slider hidden, a color
        // dragged in from elsewhere could carry alpha < 1 → invisible glyphs.
        saveBackground(TerminalBackground(
            mode: current.mode,
            color: current.color,
            foreground: TerminalBackground.RGBA(nsColor: sender.color.withAlphaComponent(1)),
            imagePath: current.imagePath,
            imageOpacity: current.imageOpacity,
            imageBlur: current.imageBlur
        ))
    }

    @objc private func harborClearTextColor() {
        let current = TerminalBackgroundPreference.load()
        saveBackground(TerminalBackground(
            mode: current.mode,
            color: current.color,
            foreground: nil,
            imagePath: current.imagePath,
            imageOpacity: current.imageOpacity,
            imageBlur: current.imageBlur
        ))
    }

    private func saveBackground(_ background: TerminalBackground) {
        guard let json = background.encodedString() else { return }
        UserDefaults.standard.set(json, forKey: TerminalBackgroundPreference.storageKey)
    }
}

/// Thread-safe recording writer kept separate from the main-actor session.
/// Terminal output can enqueue bytes without capturing actor-isolated state;
/// `close()` drains all queued writes before closing the file.
private final class TerminalRecordingSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.zero.Harbor.recording")
    private var handle: FileHandle?

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) {
        queue.async { [self] in
            handle?.write(data)
        }
    }

    func close() {
        queue.sync { [self] in
            handle?.closeFile()
            handle = nil
        }
    }
}

/// One live SSH session: owns its terminal NSView (created once per process
/// start, never recreated by SwiftUI) and tracks process lifecycle state.
@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable {
    enum State: Equatable {
        case connecting
        case running
        /// Exit code is nil when the process failed during IO/spawn.
        case exited(Int32?)

        var isExited: Bool {
            if case .exited = self { return true }
            return false
        }
    }

    let id = UUID()
    /// Snapshot of the host at connect time; later edits to the saved host do
    /// not affect a live session.
    let host: SSHHost
    /// Literal (already expanded) ControlMaster socket path shared by this
    /// session and its auxiliary monitoring commands.
    let controlSocketPath: String
    /// `[user@]host` exactly as passed to ssh, for `-O check`/aux commands.
    let destination: String

    @Published private(set) var state: State = .connecting
    /// >0 while `SessionManager` is auto-reconnecting after an UNEXPECTED drop
    /// (the current attempt number); 0 when idle or connected. The exited banner
    /// reads this to show "正在自动重连…(第 N 次)" instead of the plain notice.
    /// Driven by SessionManager via `setAutoReconnectAttempt`.
    @Published private(set) var autoReconnectAttempt = 0
    /// Title from terminal escape sequences; falls back to the host name.
    @Published private(set) var title: String
    /// The terminal view currently bound to this session. Replaced only on
    /// reconnect (fresh view + fresh process); SwiftUI must reparent it then.
    @Published private(set) var terminalView: LocalProcessTerminalView
    /// True while terminal output is being saved to ~/Library/Logs/Harbor/.
    @Published private(set) var isRecording = false
    private var recordingSink: TerminalRecordingSink?
    private var runningFallbackTask: Task<Void, Never>?

    /// argv for /usr/bin/ssh, excluding the executable itself. Validated once at init.
    private let arguments: [String]

    /// Throws (SSHCommandError) when the host fails injection-safety validation.
    ///
    /// `avoidingControlSocketPaths` carries the socket paths of every other
    /// open tab: each session must be its OWN mux master, because an OpenSSH
    /// master's death disconnects all of its mux clients — if a second tab to
    /// the same destination shared the first tab's socket, closing tab 1 would
    /// instantly kill tabs 2..N. When the host's base socket is taken, a
    /// unique per-session socket (same length) is derived instead.
    init(host: SSHHost, avoidingControlSocketPaths usedSocketPaths: Set<String> = []) throws {
        let spawnHost = TerminalSession.expandingIdentityTilde(host)
        self.host = host
        self.title = host.displayName
        // Multiplexing is always on (saved and ad-hoc hosts alike): this
        // session becomes the ControlMaster that monitoring piggybacks on.
        ControlMasterSupport.ensureCacheDirectory()
        var socketPath = ControlMasterSupport.socketPath(for: host)
        while usedSocketPaths.contains(socketPath) {
            socketPath = ControlMasterSupport.socketPath(
                for: host,
                discriminator: UUID().uuidString
            )
        }
        self.controlSocketPath = socketPath
        self.destination = SSHCommandBuilder.destination(for: host)
        self.arguments = try SSHCommandBuilder.arguments(for: spawnHost, controlSocketPath: socketPath)
        // Placeholder; replaced by makeTerminalView() below. Avoids an IUO.
        self.terminalView = LocalProcessTerminalView(frame: .zero)
        super.init()
        self.terminalView = makeTerminalView()
        scheduleRunningFallback()
    }

    /// Creates a local-shell session (spawns $SHELL in a PTY; no SSH).
    init(localShell: String) {
        self.host = SSHHost.localShellHost()
        self.title = "本地终端"
        self.controlSocketPath = ""
        self.destination = "local"
        self.arguments = []
        self.terminalView = LocalProcessTerminalView(frame: .zero)
        super.init()
        self.terminalView = makeLocalTerminalView(shell: localShell)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.state == .connecting else { return }
            if self.terminalView.process.running { self.state = .running }
        }
    }

    /// Tears down the child process if it is still running.
    func terminate() {
        guard !state.isExited else { return }
        // SwiftTerm's terminate() sends SIGTERM but cancels its exit monitor
        // before the child dies, so it is never reaped via waitpid and would
        // linger as a zombie until app quit. Reap it ourselves off-main.
        let pid = terminalView.process.shellPid
        terminalView.terminate()
        if pid > 0 {
            DispatchQueue.global(qos: .utility).async {
                // SwiftTerm's terminate() already sent SIGTERM. Poll for the
                // child non-blockingly (WNOHANG) for up to ~1s rather than an
                // unbounded waitpid(): a child that ignores/traps SIGTERM or is
                // uninterruptible would otherwise park this worker thread
                // forever. If it has not been reaped within the window,
                // escalate to SIGKILL — mirroring AuxProcess — and do a final
                // reap. The normal path (child exits promptly) returns on the
                // first successful waitpid.
                var status: Int32 = 0
                let deadline = Date().addingTimeInterval(1)
                while true {
                    let result = waitpid(pid, &status, WNOHANG)
                    if result == pid { return } // reaped
                    if result < 0 { return }    // gone / not our child (errno ECHILD)
                    if Date() >= deadline { break }
                    usleep(20_000) // 20ms between polls
                }
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0) // SIGKILL is uncatchable: this returns promptly
            }
        }
    }

    /// Clears the terminal: wipes the local SwiftTerm scrollback (ESC[3J), then
    /// sends Ctrl-L so the REMOTE shell clears its screen and — crucially —
    /// redraws the prompt. An earlier version only fed local clear codes, which
    /// left a blank screen with no prompt and looked frozen ("执行不了命令").
    /// Ctrl-L is the standard readline clear-screen; inside a full-screen app it
    /// just triggers a harmless redraw, so a running program is never disturbed.
    func clearBuffer() {
        guard !state.isExited else { return }
        terminalView.feed(text: "\u{1b}[3J")
        terminalView.send(txt: "\u{0C}")
    }

    /// Sends text verbatim to the PTY (used by batch execute). Includes the
    /// caller-supplied newline; does NOT append one automatically.
    func sendText(_ text: String) {
        guard state == .running else { return }
        terminalView.send(txt: text)
        terminalView.scrollToBottom()
    }

    /// Begins capturing terminal output to ~/Library/Logs/Harbor/<host>-<date>.log.
    /// No-op if already recording.
    func startRecording() {
        guard !isRecording else { return }
        let logsDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Harbor", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let stamp = fmt.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safe = host.hostname.replacingOccurrences(of: "/", with: "_")
        let url = logsDir.appendingPathComponent("\(safe)-\(stamp).log")
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        let sink = TerminalRecordingSink(handle: handle)
        recordingSink = sink
        isRecording = true
        // The sink serializes writes independently of the UI actor.
        (terminalView as? HarborTerminalView)?.dataInterceptor = { [weak sink] slice in
            sink?.write(Data(slice))
        }
    }

    /// Stops recording and closes the log file.
    func stopRecording() {
        guard isRecording else { return }
        (terminalView as? HarborTerminalView)?.dataInterceptor = nil
        // Drain any in-flight write before closing so a late write can't hit a
        // closed handle.
        recordingSink?.close()
        recordingSink = nil
        isRecording = false
    }

    /// Set by `SessionManager` to drive the auto-reconnect banner.
    func setAutoReconnectAttempt(_ n: Int) {
        if autoReconnectAttempt != n { autoReconnectAttempt = n }
    }

    /// Fresh terminal view + fresh ssh process for the same host.
    func reconnect() {
        guard state.isExited else { return }
        state = .connecting
        title = host.displayName
        // Silence the old view's first-output callback before discarding it so
        // a delayed delivery can't race with the new session's state machine.
        (terminalView as? HarborTerminalView)?.onFirstOutput = nil
        // Also clear any active recording interceptor from the old view and
        // rewire it to the fresh view (recording stays active across reconnects).
        if isRecording {
            (terminalView as? HarborTerminalView)?.dataInterceptor = nil
        }
        terminalView = makeTerminalView()
        if isRecording, let sink = recordingSink {
            (terminalView as? HarborTerminalView)?.dataInterceptor = { [weak sink] slice in
                sink?.write(Data(slice))
            }
        }
        scheduleRunningFallback()
    }

    /// Backstop for the `.connecting → .running` transition. SwiftTerm's
    /// first-output callback (`HarborTerminalView.dataReceived`) is unreliable
    /// across versions and can leave a session stuck in `.connecting` forever —
    /// which gates monitoring and the file panel (they only start once
    /// `.running`). After a generous delay, emit `.running` only if the SSH
    /// process is still alive — an already-exited child has already flipped to
    /// `.exited` via `processTerminated`, so this becomes a no-op on auth
    /// failure or bad hostnames and never falsely signals a connected state.
    private func scheduleRunningFallback() {
        runningFallbackTask?.cancel()
        runningFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled, self.state == .connecting else { return }
            guard self.terminalView.process.running else { return }
            self.state = .running
        }
    }

    // MARK: - Process spawning

    private func makeLocalTerminalView(shell: String) -> LocalProcessTerminalView {
        let view = HarborTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        if UserDefaults.standard.object(forKey: "useMetalRenderer") == nil || UserDefaults.standard.bool(forKey: "useMetalRenderer") {
            try? view.setUseMetal(true)
        }
        view.processDelegate = self
        view.onFirstOutput = { [weak self, weak view] in
            guard let self, let view, view === self.terminalView else { return }
            if self.state == .connecting { self.state = .running }
        }
        view.startProcess(
            executable: shell,
            args: ["--login"],
            environment: TerminalSession.environment()
        )
        return view
    }

    private func makeTerminalView() -> LocalProcessTerminalView {
        let view = HarborTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        if UserDefaults.standard.object(forKey: "useMetalRenderer") == nil || UserDefaults.standard.bool(forKey: "useMetalRenderer") {
            try? view.setUseMetal(true)
        }
        view.processDelegate = self
        view.onFirstOutput = { [weak self, weak view] in
            guard let self, let view, view === self.terminalView else { return }
            if self.state == .connecting { self.state = .running }
        }
        view.startProcess(
            executable: SSHCommandBuilder.executablePath,
            args: arguments,
            environment: TerminalSession.environment()
        )
        return view
    }

    /// Environment for the child ssh process: SwiftTerm's defaults (TERM,
    /// COLORTERM, LANG, HOME, USER, LOGNAME, …) plus PATH and SSH_AUTH_SOCK,
    /// which `Terminal.getEnvironmentVariables` deliberately omits.
    static func environment() -> [String] {
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        let inherited = ProcessInfo.processInfo.environment
        env.append("PATH=" + (inherited["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"))
        // Forward the agent socket so the spawned ssh can reach the user's
        // ssh-agent (macOS launchd agent, `ssh-add --apple-use-keychain` keys,
        // or third-party agents like 1Password/Secretive).
        if let socket = inherited["SSH_AUTH_SOCK"] {
            env.append("SSH_AUTH_SOCK=\(socket)")
        }
        // Honor the user's locale overrides when present (SwiftTerm only sets
        // a default LANG and never copies these).
        for key in ["LC_ALL", "LC_CTYPE"] {
            if let value = inherited[key], !env.contains(where: { $0.hasPrefix("\(key)=") }) {
                env.append("\(key)=\(value)")
            }
        }
        if !env.contains(where: { $0.hasPrefix("HOME=") }) {
            env.append("HOME=\(NSHomeDirectory())")
        }
        if !env.contains(where: { $0.hasPrefix("USER=") }) {
            env.append("USER=\(NSUserName())")
        }
        return env
    }

    /// ssh expands `~` in config-file paths but the shell normally handles it
    /// for -i; since there is no shell here, expand it ourselves.
    private static func expandingIdentityTilde(_ host: SSHHost) -> SSHHost {
        var copy = host
        if let identity = copy.identityFile, identity.hasPrefix("~") {
            copy.identityFile = (identity as NSString).expandingTildeInPath
        }
        return copy
    }

}

// MARK: - LocalProcessTerminalViewDelegate

extension TerminalSession: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // PTY winsize is updated by LocalProcessTerminalView itself.
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard source === terminalView else { return }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        self.title = trimmed.isEmpty ? host.displayName : trimmed
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // Not surfaced in the UI (yet).
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard source === terminalView else { return }
        state = .exited(TerminalSession.normalizedExitCode(exitCode))
    }

    /// SwiftTerm's active (forkpty) backend reports the RAW `wait(2)` status
    /// (e.g. 65280 for an ssh exit of 255, or 9 for a SIGKILL). Decode it: an
    /// exited child has the low 7 bits clear with the exit code in bits 8–15; a
    /// signalled child carries the signal in the low 7 bits. Previously any
    /// value ≤ 255 was returned verbatim, so a signal death (raw == signal, e.g.
    /// 9/15) was mislabeled as "exit code 9/15". A signal is now encoded as a
    /// NEGATIVE number so the UI can say "terminated by signal N" instead — and
    /// status-dot logic (`(code ?? 1) == 0`) still reads any signal as an error.
    static func normalizedExitCode(_ raw: Int32?) -> Int32? {
        guard let raw else { return nil }
        guard raw >= 0 else { return raw } // already a sentinel, leave as-is
        if (raw & 0x7F) == 0 {
            return (raw >> 8) & 0xFF // WIFEXITED -> WEXITSTATUS (0…255)
        }
        return -(raw & 0x7F) // WIFSIGNALED -> -signal
    }
}
