import AppKit
import Combine
import HarborKit
import os.log
import SwiftTerm
import UniformTypeIdentifiers

/// UserDefaults key holding the global default Backspace key behavior
/// (Settings → 终端 → 键盘). Per-host `SSHHost.backspaceBehavior` overrides it.
enum BackspacePreference {
    static let globalDefaultKey = "backspaceBehaviorDefault"
}

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

    /// ZModem transfer router: while set, raw output bytes are offered here
    /// first; returning true consumes them, so protocol bytes never reach the
    /// screen, the TOTP detector, or the recording sink. Same lock discipline
    /// as `_dataInterceptor` — written on main, read on SwiftTerm's I/O thread.
    private var _byteRouter: (@Sendable (ArraySlice<UInt8>) -> Bool)?
    var byteRouter: (@Sendable (ArraySlice<UInt8>) -> Bool)? {
        get {
            interceptorLock.lock()
            defer { interceptorLock.unlock() }
            return _byteRouter
        }
        set {
            interceptorLock.lock()
            defer { interceptorLock.unlock() }
            _byteRouter = newValue
        }
    }

    /// While a ZModem transfer owns the byte stream, keyboard input is
    /// dropped — keystrokes would corrupt the protocol. Main-thread only.
    var keyboardLocked = false

    /// All keyboard/paste input funnels through here (SwiftTerm's
    /// `MacLocalTerminalView` marks it `open` for exactly this interception).
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if keyboardLocked { return }
        super.send(source: source, data: data)
    }

    /// Per-session override of what the Backspace key sends (resolved from the
    /// host's `backspaceBehavior` + the global default at connect time).
    /// nil = terminal default (SwiftTerm sends DEL; kitty keyboard mode reports
    /// the key event). Non-nil bytes are sent verbatim instead.
    var backspaceWireBytes: [UInt8]?

    /// Intercept Backspace at the key-command layer so all three explicit
    /// behaviors — including VT220's ESC[3~, which SwiftTerm's boolean
    /// `backspaceSendsControlH` cannot express — flow through one path.
    /// Kitty keyboard enhancement mode is left alone: an app that requested
    /// enhanced key reporting wants key identity, not a remapped byte.
    override func doCommand(by selector: Selector) {
        if selector == #selector(deleteBackward(_:)),
           let bytes = backspaceWireBytes,
           terminal.keyboardEnhancementFlags.isEmpty {
            send(bytes)
            return
        }
        super.doCommand(by: selector)
    }

    /// The view currently driving the shared `NSColorPanel` (text-color picker).
    /// Tracked so a deallocating view only tears down the panel wiring if it is
    /// still the owner — never clobbering another tab's or Settings' live pick.
    private static weak var colorPanelOwner: HarborTerminalView?

    deinit {
        // Drop our hold on the shared color panel so a later color change can't
        // message this freed view. Only if we're still the owner (the panel's
        // target is an unretained reference).
        // Use DispatchQueue.main.async instead of MainActor.assumeIsolated so
        // this works safely even when the last strong reference is dropped from
        // a background queue (assumeIsolated would trap in that scenario).
        let identity = ObjectIdentifier(self)
        DispatchQueue.main.async {
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
        // ZModem transfer in progress: protocol bytes are consumed wholesale
        // (kept off the screen and out of the recording sink on purpose).
        if let router = byteRouter, router(slice) {
            return
        }
        super.dataReceived(slice: slice)
        dataInterceptor?(slice)
        if !sawOutput {
            sawOutput = true
            onFirstOutput?()
        }
    }

    /// Belt-and-suspenders: if the terminal is first responder, never let AppKit
    /// menu/key-equivalent machinery claim Control key combos (especially Ctrl+C).
    /// Returning false forces the event into `keyDown`, where SwiftTerm maps it
    /// to a PTY control byte (0x03 = SIGINT).
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) && !flags.contains(.command) {
            return false
        }
        return super.performKeyEquivalent(with: event)
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

        let copyItem = NSMenuItem(title: L("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = .command
        copyItem.isEnabled = true
        menu.addItem(copyItem)

        let selectAllItem = NSMenuItem(title: L("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        selectAllItem.keyEquivalentModifierMask = .command
        menu.addItem(selectAllItem)

        let pasteItem = NSMenuItem(title: L("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = .command
        pasteItem.isEnabled = true
        menu.addItem(pasteItem)

        let pasteExecItem = NSMenuItem(title: L("粘贴并执行"), action: #selector(harborPasteAndExecute(_:)), keyEquivalent: "")
        menu.addItem(pasteExecItem)

        menu.addItem(.separator())

        // Clear scrollback + screen (local only; never touches the remote shell).
        let clearBuffer = NSMenuItem(
            title: L("清空终端"), action: #selector(harborClearBuffer), keyEquivalent: "k"
        )
        clearBuffer.keyEquivalentModifierMask = .command
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

    @objc private func harborPasteAndExecute(_ sender: NSMenuItem) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        // Read once before asking: the reviewed text is exactly what reaches
        // the terminal if the user confirms, even if another app changes the
        // pasteboard while the alert is visible. Plain Paste intentionally
        // remains unchanged; only this execution shortcut is coordinated.
        CommandExecutionConfirmationCoordinator.requestExecution(of: text, from: self) { [weak self] in
            self?.send(txt: text)
            self?.send(txt: "\r")
        }
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

/// AppKit bridge for the terminal context-menu execution shortcut. SwiftUI
/// surfaces render their own alerts, but they all derive their decision from
/// `CommandExecutionCoordinator`; this bridge gives Paste-and-Execute the same
/// policy instead of bypassing it by writing clipboard text plus Return.
@MainActor
private enum CommandExecutionConfirmationCoordinator {
    static func requestExecution(of command: String, from source: NSView, execute: @escaping () -> Void) {
        guard let risk = CommandExecutionCoordinator.confirmationRisk(for: command) else {
            execute()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("确认发送高风险命令")
        alert.informativeText = "\(risk.summary)\n\n\(command)"
        alert.addButton(withTitle: L("仍然发送"))
        alert.addButton(withTitle: L("取消"))

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            execute()
        }
        if let window = source.window {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }
}

/// Thread-safe recording writer kept separate from the main-actor session.
/// Terminal output can enqueue bytes without capturing actor-isolated state;
/// `close()` drains all queued writes before closing the file.  Both the
/// in-memory queue and the on-disk recording are explicitly bounded because a
/// connected terminal peer controls the volume of data it can produce.
private final class TerminalRecordingSink: @unchecked Sendable {
    enum Failure: Sendable, Equatable {
        case backlogLimitExceeded
        case sizeLimitExceeded
        case writeFailed

        /// Localization is actor-isolated in the app, so this type carries a
        /// stable key and TerminalSession renders it on the main actor.
        var messageKey: String {
            switch self {
            case .backlogLimitExceeded:
                return "终端输出过快，录制已停止以保护内存"
            case .sizeLimitExceeded:
                return "录制文件达到大小上限，已停止录制"
            case .writeFailed:
                return "无法写入录制文件，已停止录制"
            }
        }
    }

    /// A slow or stalled filesystem must not turn DispatchQueue.async calls
    /// into an unbounded heap queue.  Four MiB is enough for several terminal
    /// screens while still making an overloaded recorder fail promptly.
    private static let maximumPendingBytes = 4 * 1024 * 1024
    /// Keep a single recording from filling the user's disk indefinitely.
    private static let maximumRecordingBytes: Int64 = 256 * 1024 * 1024

    private let queue = DispatchQueue(label: "dev.zero.Harbor.recording")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let lock = NSLock()
    private var handle: FileHandle?
    private var pendingChunks: [Data] = []
    private var pendingBytes = 0
    /// Bytes removed from `pendingChunks` but currently being written.  Count
    /// them in admission control so a slow write cannot let producers enqueue
    /// another full backlog on top of the in-flight chunk(s).
    private var reservedBytes = 0
    private var bytesWritten: Int64 = 0
    private var drainScheduled = false
    private var acceptingWrites = true
    private var closeRequested = false
    private var failureReported = false
    private let onFailure: @Sendable (Failure) -> Void

    init(handle: FileHandle, onFailure: @escaping @Sendable (Failure) -> Void) {
        self.handle = handle
        self.onFailure = onFailure
        queue.setSpecific(key: queueKey, value: 1)
    }

    /// Adds one raw terminal chunk if both resource budgets allow it.  This is
    /// called on SwiftTerm's I/O thread, so it schedules at most one writer
    /// block and never waits for disk I/O.
    func write(_ bytes: ArraySlice<UInt8>) {
        var shouldScheduleDrain = false
        var failure: Failure?

        lock.lock()
        if acceptingWrites {
            let queuedOrWritingBytes = pendingBytes + reservedBytes
            let projectedFileBytes = bytesWritten + Int64(queuedOrWritingBytes) + Int64(bytes.count)
            if bytes.count > Self.maximumPendingBytes - queuedOrWritingBytes {
                failure = stopAcceptingLocked(for: .backlogLimitExceeded)
            } else if projectedFileBytes > Self.maximumRecordingBytes {
                failure = stopAcceptingLocked(for: .sizeLimitExceeded)
            } else {
                // Only materialize a Data copy after verifying capacity, so
                // rejected high-rate output cannot allocate an extra backlog.
                pendingChunks.append(Data(bytes))
                pendingBytes += bytes.count
            }
        }
        shouldScheduleDrain = scheduleDrainIfNeededLocked()
        lock.unlock()

        if shouldScheduleDrain {
            queue.async { [weak self] in self?.drain() }
        }
        if let failure {
            onFailure(failure)
        }
    }

    func close() {
        var shouldScheduleDrain = false
        lock.lock()
        acceptingWrites = false
        closeRequested = true
        shouldScheduleDrain = scheduleDrainIfNeededLocked()
        lock.unlock()

        if shouldScheduleDrain {
            queue.async { [weak self] in self?.drain() }
        }
        // A close from the writer itself must not synchronously wait on its own
        // serial queue.  Every other caller waits until all accepted writes have
        // been flushed and the descriptor is closed.
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            queue.sync {}
        }
    }

    deinit {
        close()
    }

    /// Must be called with `lock` held.  Returns the failure only once so a
    /// terminal flood cannot create a matching flood of UI notifications.
    private func stopAcceptingLocked(for reason: Failure) -> Failure? {
        acceptingWrites = false
        closeRequested = true
        guard !failureReported else { return nil }
        failureReported = true
        return reason
    }

    /// Must be called with `lock` held.
    private func scheduleDrainIfNeededLocked() -> Bool {
        guard !drainScheduled, (!pendingChunks.isEmpty || closeRequested) else {
            return false
        }
        drainScheduled = true
        return true
    }

    private func drain() {
        while true {
            let next: Data?
            let fileHandle: FileHandle?

            lock.lock()
            if !pendingChunks.isEmpty {
                next = pendingChunks.removeFirst()
                pendingBytes -= next?.count ?? 0
                reservedBytes += next?.count ?? 0
                fileHandle = handle
            } else {
                drainScheduled = false
                if closeRequested {
                    let closingHandle = handle
                    handle = nil
                    lock.unlock()
                    try? closingHandle?.close()
                    return
                }
                lock.unlock()
                return
            }
            lock.unlock()

            guard let next, let fileHandle else {
                reportWriteFailure()
                continue
            }

            do {
                try fileHandle.write(contentsOf: next)
                lock.lock()
                reservedBytes -= next.count
                bytesWritten += Int64(next.count)
                lock.unlock()
            } catch {
                lock.lock()
                reservedBytes -= next.count
                lock.unlock()
                reportWriteFailure()
            }
        }
    }

    private func reportWriteFailure() {
        var failure: Failure?
        lock.lock()
        // No point retaining additional chunks after an I/O error; release the
        // bounded queue immediately and close the descriptor in this drain.
        pendingChunks.removeAll(keepingCapacity: false)
        pendingBytes = 0
        reservedBytes = 0
        failure = stopAcceptingLocked(for: .writeFailed)
        lock.unlock()
        if let failure {
            onFailure(failure)
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
    /// Connect-time host snapshot. `reconnect()` refreshes it from the saved
    /// host (via `hostProvider`) so edits apply on the next dial; between
    /// connects later edits do not affect a live session.
    private(set) var host: SSHHost
    /// Literal (already expanded) ControlMaster socket path shared by this
    /// session and its auxiliary monitoring commands.
    let controlSocketPath: String
    /// `[user@]host` exactly as passed to ssh, for `-O check`/aux commands.
    private(set) var destination: String

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
    /// Most recent recorder failure.  The terminal also receives a local
    /// marker when this changes so a high-rate peer cannot stop recording
    /// silently while the user is looking at the session.
    @Published private(set) var recordingError: String?
    /// Current working directory reported by the shell via OSC 7.
    @Published private(set) var currentDirectory: String? = nil
    /// True after `TOTPPromptDetector` sees a 2FA prompt and this host has a
    /// Keychain secret. The session never stores the secret itself.
    @Published private(set) var totpPromptVisible = false
    /// User-assigned tab label; when set, terminal-escape titles are ignored.
    private var customTitle: String? = nil
    private var recordingSink: TerminalRecordingSink?
    /// Watches PTY output for 2FA prompts. Fed from the composed interceptor.
    private let totpDetector = TOTPPromptDetector()
    private var totpSecretPresent = false
    /// Identifies the current start/record operation.  A late setup or writer
    /// callback from a previous recording must never attach to, or stop, a new
    /// recording after the user toggles it again.
    private var recordingToken: UUID?
    private var runningFallbackTask: Task<Void, Never>?

    /// argv for /usr/bin/ssh, excluding the executable itself. Validated at
    /// init and rebuilt from the current saved host on reconnect.
    private var arguments: [String]

    /// Resolves the CURRENT saved host for reconnect; set by SessionManager.
    /// Nil (local shells) or a lookup miss (host deleted) keeps the
    /// connect-time snapshot argv.
    var hostProvider: (@MainActor () -> SSHHost?)?

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
        installTOTPPromptHandling()
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

    deinit {
        if let sink = recordingSink {
            TerminalSession.closeRecordingSink(sink)
        }
        runningFallbackTask?.cancel()
    }

    /// Tears down the child process if it is still running. The completion is
    /// invoked only after the direct child has exited or was already reaped;
    /// app termination uses it to avoid exiting while a TERM-resistant session
    /// is still alive.
    func terminate(completion: @escaping @Sendable () -> Void = {}) {
        guard !state.isExited else {
            completion()
            return
        }
        // SwiftTerm's terminate() sends SIGTERM but cancels its exit monitor
        // before the child dies, so it is never reaped via waitpid and would
        // linger as a zombie until app quit. Reap it ourselves off-main.
        let pid = terminalView.process.shellPid
        // `forkpty` makes the shell a session/process-group leader. Signal the
        // whole group when that invariant holds so an ssh child or a shell
        // pipeline does not survive after its direct parent has exited. The
        // equality check keeps us from ever signalling an unrelated group.
        let isProcessGroupLeader = pid > 0 && getpgid(pid) == pid
        if isProcessGroupLeader {
            kill(-pid, SIGTERM)
        }
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
                    if result == pid {
                        completion()
                        return // reaped
                    }
                    if result < 0 {
                        completion()
                        return // gone / not our child (errno ECHILD)
                    }
                    if Date() >= deadline { break }
                    usleep(20_000) // 20ms between polls
                }
                if isProcessGroupLeader, getpgid(pid) == pid {
                    kill(-pid, SIGKILL)
                } else {
                    kill(pid, SIGKILL)
                }
                waitpid(pid, &status, 0) // SIGKILL is uncatchable: this returns promptly
                completion()
            }
        } else {
            completion()
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

    /// Hides the inline 2FA banner without sending anything.
    func dismissTOTPPrompt() {
        totpPromptVisible = false
    }

    /// Types the current TOTP code + newline into the PTY, then hides the banner.
    /// Never auto-invoked: the user has to click 发送. No-op unless `.running`.
    func sendTOTPCode(_ code: String) {
        guard state == .running else { return }
        sendText(code + "\n")
        dismissTOTPPrompt()
    }

    /// Begins capturing terminal output to ~/Library/Logs/Harbor/<host>-<date>.log.
    /// No-op if already recording. File I/O runs in a detached task so a slow or
    /// contended filesystem never blocks the main actor.
    func startRecording() {
        guard !isRecording, recordingToken == nil else { return }
        let token = UUID()
        recordingToken = token
        recordingError = nil
        let hostname = host.hostname
        let logsDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Harbor", isDirectory: true)
        Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logsDir.path)
            } catch {
                os_log(.error, "Failed to create Harbor log directory at %{public}@: %{public}@", logsDir.path, error.localizedDescription)
                await MainActor.run { [weak self] in
                    self?.recordingStartFailed(token: token, message: L("无法创建录制目录"))
                }
                return
            }
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
            let stamp = fmt.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let safe = hostname.replacingOccurrences(of: "/", with: "_")
            let url = logsDir.appendingPathComponent("\(safe)-\(stamp).log")
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                NSLog("Harbor: startRecording: failed to create log file at \(url.path)")
                await MainActor.run { [weak self] in
                    self?.recordingStartFailed(token: token, message: L("无法创建录制文件"))
                }
                return
            }
            let handle: FileHandle
            do {
                handle = try FileHandle(forWritingTo: url)
            } catch {
                NSLog("Harbor: startRecording: cannot open log file for writing: \(error)")
                await MainActor.run { [weak self] in
                    self?.recordingStartFailed(token: token, message: L("无法打开录制文件"))
                }
                return
            }
            let sink = TerminalRecordingSink(handle: handle) { [weak self] failure in
                Task { @MainActor [weak self] in
                    self?.recordingFailed(token: token, failure: failure)
                }
            }
            await MainActor.run { [weak self] in
                guard let self, self.recordingToken == token, !self.isRecording else {
                    sink.close()
                    return
                }
                self.recordingSink = sink
                self.isRecording = true
                self.refreshDataInterceptor()
            }
        }
    }

    /// Stops recording and closes the log file.
    func stopRecording() {
        guard isRecording || recordingToken != nil else { return }
        recordingToken = nil
        // Drain any in-flight write before closing so a late write can't hit a
        // closed handle. Keep the TOTP feed alive via refreshDataInterceptor().
        let sink = recordingSink
        recordingSink = nil
        isRecording = false
        refreshDataInterceptor()
        if let sink {
            TerminalSession.closeRecordingSink(sink)
        }
    }

    /// Set by `SessionManager` to drive the auto-reconnect banner.
    func setAutoReconnectAttempt(_ n: Int) {
        if autoReconnectAttempt != n { autoReconnectAttempt = n }
    }

    /// Assigns a custom display name to this tab. Pass an empty string to revert
    /// to the terminal-reported (or host) title.
    func rename(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        customTitle = trimmed.isEmpty ? nil : trimmed
        title = customTitle ?? host.displayName
    }

    /// Fresh terminal view + fresh ssh process. The argv is rebuilt from the
    /// CURRENT saved host so edits to address/port/user/identity apply; a
    /// deleted host, a protocol switch, or a validation failure falls back to
    /// the connect-time snapshot argv.
    func reconnect() {
        guard state.isExited else { return }
        if let stored = hostProvider?(),
           stored.connectionProtocol == host.connectionProtocol,
           let rebuilt = try? SSHCommandBuilder.arguments(
               for: TerminalSession.expandingIdentityTilde(stored),
               controlSocketPath: controlSocketPath) {
            host = stored
            destination = SSHCommandBuilder.destination(for: stored)
            arguments = rebuilt
        }
        state = .connecting
        title = host.displayName
        // Silence the old view's first-output callback before discarding it so
        // a delayed delivery can't race with the new session's state machine.
        (terminalView as? HarborTerminalView)?.onFirstOutput = nil
        (terminalView as? HarborTerminalView)?.dataInterceptor = nil
        resetTOTPPrompt()
        terminalView = makeTerminalView()
        // Recording stays active across reconnects; TOTP feed is reattached
        // when this host still has a Keychain secret.
        refreshDataInterceptor()
        scheduleRunningFallback()
    }

    private func recordingStartFailed(token: UUID, message: String) {
        guard recordingToken == token else { return }
        recordingToken = nil
        recordingError = message
    }

    private func recordingFailed(token: UUID, failure: TerminalRecordingSink.Failure) {
        guard recordingToken == token else { return }
        let message = L(failure.messageKey)
        recordingToken = nil
        let sink = recordingSink
        recordingSink = nil
        isRecording = false
        recordingError = message
        refreshDataInterceptor()
        if let sink {
            TerminalSession.closeRecordingSink(sink)
        }
        // This is fed only into the local terminal emulator, never sent to the
        // remote host.  It gives the user immediate feedback even when the
        // recording control itself is not currently visible.
        terminalView.feed(text: "\r\n[Harbor: \(message)]\r\n")
    }

    /// `TerminalRecordingSink.close()` deliberately drains accepted writes;
    /// keep that potentially slow filesystem work off the main actor when a
    /// user stops recording or a resource cap auto-stops it.
    private static nonisolated func closeRecordingSink(_ sink: TerminalRecordingSink) {
        DispatchQueue.global(qos: .utility).async {
            sink.close()
        }
    }

    /// Single owner of `HarborTerminalView.dataInterceptor`. Recording and TOTP
    /// both need the one slot, so every attach / detach path comes through here
    /// instead of overwriting or nil-ing the other feed.
    private func refreshDataInterceptor() {
        guard let view = terminalView as? HarborTerminalView else { return }
        let sink = isRecording ? recordingSink : nil
        let detector = shouldFeedTOTPDetector ? totpDetector : nil
        // The ZModem detector always listens (rz/sz can run in any shell
        // tab). It's a cheap byte-level state machine fed on SwiftTerm's
        // serial I/O context; only an actual ZRQINIT hit hops to MainActor.
        let zdetector = zmodemDetector
        view.dataInterceptor = { [weak sink, weak detector, weak self] slice in
            detector?.feed(slice)
            sink?.write(slice)
            if let hit = zdetector.feed(slice) {
                Task { @MainActor [weak self] in
                    self?.zmodemTriggered(hit.trigger, frame: hit.frame)
                }
            }
        }
    }

    /// Local-shell tabs have no TOTP. SSH tabs only attach the detector when
    /// a Keychain secret exists for this host — the secret itself is not kept.
    private var shouldFeedTOTPDetector: Bool {
        host.connectionProtocol != .local && totpSecretPresent
    }

    private func installTOTPPromptHandling() {
        guard host.connectionProtocol != .local else { return }
        totpSecretPresent = TOTPStore.hasSecret(for: host.id)
        totpDetector.onPromptDetected = { [weak self] in
            guard let self, self.totpSecretPresent else { return }
            self.totpPromptVisible = true
        }
        refreshDataInterceptor()
    }

    private func resetTOTPPrompt() {
        totpDetector.reset()
        totpPromptVisible = false
    }

    // MARK: - ZModem (rz/sz) transfers

    /// Non-nil while a detected ZRQINIT frame awaits the user's choice.
    @Published private(set) var zmodemRequest: ZmodemTrigger? = nil
    /// One-line transfer status while running / briefly after finishing.
    @Published private(set) var zmodemStatus: String? = nil

    private var zmodemDetector = ZmodemDetector()
    private var zmodemSession: ZmodemSession?
    private var pendingZmodemFrame: Data? = nil
    private var zmodemWatchdog: Task<Void, Never>? = nil
    private var zmodemLastActivity = Date.distantPast

    /// Called (hopped to MainActor) when the detector saw a complete ZRQINIT.
    private func zmodemTriggered(_ trigger: ZmodemTrigger, frame: Data) {
        guard state == .running, zmodemSession == nil, zmodemRequest == nil else { return }
        pendingZmodemFrame = frame
        zmodemRequest = trigger
    }

    /// User picked local files after a remote `rz` — start sending them.
    func startZmodemUpload(files: [URL]) {
        guard !files.isEmpty else { return }
        startZmodem(role: .send(files: files))
    }

    /// User picked a local directory after a remote `sz` — receive into it.
    func startZmodemDownload(to directory: URL) {
        startZmodem(role: .receive(directory: directory))
    }

    /// Dismiss the detection banner without transferring.
    func dismissZmodemRequest() {
        zmodemRequest = nil
        pendingZmodemFrame = nil
        zmodemDetector.reset()
    }

    /// `sz -q` is indistinguishable from `rz` on the wire — let the user
    /// flip the detected direction before picking files.
    func switchZmodemDirection() {
        guard let current = zmodemRequest else { return }
        zmodemRequest = (current == .upload) ? .download : .upload
    }

    func cancelZmodemTransfer() {
        zmodemSession?.cancel()
    }

    private func startZmodem(role: ZmodemRole) {
        guard let view = terminalView as? HarborTerminalView,
              let frame = pendingZmodemFrame else { return }
        zmodemRequest = nil
        pendingZmodemFrame = nil

        let session = ZmodemSession(role: role)
        zmodemSession = session
        zmodemLastActivity = Date()

        session.onSend = { [weak view] data in
            view?.process.send(data: ArraySlice(data))
        }
        session.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleZmodemEvent(event)
            }
        }
        view.byteRouter = { [weak session] slice in
            guard let session else { return false }
            session.input(slice)
            return true
        }
        view.keyboardLocked = true
        zmodemStatus = L("ZModem 协商中…")

        // Replay the captured ZRQINIT so the state machine doesn't sit out
        // the peer's (5-10s) retransmission timer.
        session.input(frame)
        startZmodemWatchdog()
    }

    private func handleZmodemEvent(_ event: ZmodemSessionEvent) {
        zmodemLastActivity = Date()
        switch event {
        case .progress(let p):
            let pct = p.fileSize > 0 ? Int(Double(p.fileBytesTransferred) * 100 / Double(p.fileSize)) : 0
            zmodemStatus = String(format: L("ZModem 传输中：%@（%lld/%lld，%lld%%）"),
                                  p.fileName, p.fileIndex, p.fileCount, pct)
        case .fileCompleted(let name, _):
            zmodemStatus = String(format: L("ZModem 已传输：%@"), name)
        case .phaseChanged(let phase):
            switch phase {
            case .completed:
                zmodemStatus = L("ZModem 传输完成")
                finishZmodem(restoreDelay: 3)
            case .cancelled:
                zmodemStatus = L("ZModem 已取消")
                finishZmodem(restoreDelay: 2)
            case .failed:
                zmodemStatus = String(format: L("ZModem 传输失败：%@"),
                                      Self.describeZmodemError(zmodemSession?.error))
                finishZmodem(restoreDelay: 5)
            default:
                break
            }
        }
    }

    private static func describeZmodemError(_ error: ZmodemError?) -> String {
        switch error {
        case .cancelled: return L("已取消")
        case .abortedByPeer: return L("对端中止")
        case .protocolError(let m): return L("协议错误") + " (\(m))"
        case .fileIO(let m): return L("文件读写失败") + " (\(m))"
        case .tooManyErrors: return L("错误过多，已放弃")
        case .fileTooLarge(let f): return String(format: L("文件超过 4GiB：%@"), f)
        case nil: return ""
        }
    }

    /// Tears down byte routing after a short grace period so the final status
    /// line stays readable. Idempotent.
    private func finishZmodem(restoreDelay: TimeInterval) {
        zmodemWatchdog?.cancel()
        zmodemWatchdog = nil
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(restoreDelay * 1_000_000_000))
            guard let self else { return }
            if let view = self.terminalView as? HarborTerminalView {
                view.byteRouter = nil
                view.keyboardLocked = false
                // Nudge the shell prompt back onto a fresh line.
                view.feed(text: "\r\n")
            }
            self.zmodemSession = nil
            self.zmodemStatus = nil
            self.zmodemDetector.reset()
        }
    }

    /// Cancels a transfer that made no progress for 60s (dead peer, dropped
    /// connection). Progress and phase events refresh `zmodemLastActivity`.
    private func startZmodemWatchdog() {
        zmodemWatchdog?.cancel()
        zmodemWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, let session = self.zmodemSession else { return }
                if !session.isActive { return }
                if Date().timeIntervalSince(self.zmodemLastActivity) > 60 {
                    session.cancel()
                    return
                }
            }
        }
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
        if UserDefaults.standard.bool(forKey: "useMetalRenderer") {
            try? view.setUseMetal(true)
        }
        view.backspaceWireBytes = resolvedBackspaceWireBytes()
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
        if UserDefaults.standard.bool(forKey: "useMetalRenderer") {
            try? view.setUseMetal(true)
        }
        view.backspaceWireBytes = resolvedBackspaceWireBytes()
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

    /// Effective backspace wire bytes for a new view: the host's own choice
    /// (when not `.auto`) beats the global default from Settings. Resolved at
    /// connect time; `reconnect()` rebuilds the view so edits apply then.
    /// Local shells use the global default (their synthetic host is `.auto`).
    private func resolvedBackspaceWireBytes() -> [UInt8]? {
        let behavior = SSHHost.BackspaceBehavior.resolve(
            perHost: host.backspaceBehavior,
            globalRawValue: UserDefaults.standard.string(
                forKey: BackspacePreference.globalDefaultKey)
        )
        return behavior.wireBytes
    }

}

// MARK: - LocalProcessTerminalViewDelegate

extension TerminalSession: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // PTY winsize is updated by LocalProcessTerminalView itself.
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard source === terminalView else { return }
        guard customTitle == nil else { return }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let next = trimmed.isEmpty ? host.displayName : trimmed
        // Shells re-emit the SAME title on every precmd; @Published fires on
        // assignment regardless of equality, and every fire repaints the tab
        // strip — drop no-op updates at the source.
        guard next != self.title else { return }
        self.title = next
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard source === terminalView else { return }
        let next: String?
        if let raw = directory, let url = URL(string: raw), url.isFileURL {
            next = url.path
        } else {
            next = directory
        }
        guard next != currentDirectory else { return }
        currentDirectory = next
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
