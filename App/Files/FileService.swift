import Foundation
import HarborKit

// MARK: - Persistent path history store

/// App-layer wrapper around HarborKit's pure `PathHistory`. It is shared in
/// memory across sessions, but disk persistence is opt-in in Privacy settings.
@MainActor
final class PathHistoryStore: ObservableObject {
    static let storageKey = HistoryPrivacyPreference.pathStorageKey
    static let shared = PathHistoryStore()

    @Published private(set) var history: PathHistory
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let persists = HistoryPrivacyPreference.isPersistenceEnabled(in: defaults)
        if !persists { defaults.removeObject(forKey: Self.storageKey) }
        let stored = persists ? (defaults.stringArray(forKey: Self.storageKey) ?? []) : []
        self.history = PathHistory(entries: stored)
    }

    func record(_ path: String) {
        history.record(path)
        if HistoryPrivacyPreference.isPersistenceEnabled(in: defaults) {
            defaults.set(history.entries, forKey: Self.storageKey)
        } else {
            defaults.removeObject(forKey: Self.storageKey)
        }
    }

    func clear() {
        history = PathHistory()
        defaults.removeObject(forKey: Self.storageKey)
    }
}

/// Per-session remote file browser (FinalShell's 文件 panel): directory
/// listings over the session's own ControlMaster socket plus sftp batch
/// transfers — all multiplexed, never re-authenticating, never prompting.
/// Linux-first like monitoring (GNU ls); other systems degrade to a notice.
@MainActor
final class FileService: ObservableObject {
    enum Status: Equatable {
        case idle
        /// Verifying the mux socket and probing `uname -s` / `$HOME`.
        case preparing
        /// Socket dead, probe failed, or non-Linux server.
        case unsupported(reason: String)
        case ready
    }

    enum TransferDirection {
        case download
        case upload
    }

    enum TransferState: Equatable {
        case running
        case done
        case failed(String)
    }

    struct Transfer: Identifiable {
        let id = UUID()
        let filename: String
        let direction: TransferDirection
        var state: TransferState = .running
        /// Bytes done so far (downloads poll the local file; 0 when unknown).
        var transferred: Int64 = 0
        /// Total size in bytes (0 when unknown, e.g. a recursive directory).
        var total: Int64 = 0
        /// Live throughput in bytes/second (downloads only).
        var bytesPerSecond: Double = 0
        /// The sftp batch this transfer (re)runs, kept so a failure can be
        /// retried verbatim. Empty ⇒ not retryable (external-editor sync rows).
        var batch: String = ""
        /// Whether to re-list the directory after success (uploads do).
        var refreshAfter: Bool = false
        /// Local file polled for download progress (nil for uploads / dirs).
        var progressURL: URL?
        /// Remote file polled (via `stat -c %s`) for UPLOAD progress — uploads
        /// can't poll a local file, so we watch the growing remote one.
        var remoteProgressPath: String?
        /// True for packaged (tar+gzip) folder transfers, shown with a tag.
        var packaged: Bool = false

        /// Only failed, batch-bearing transfers can be retried. Packaged
        /// transfers are multi-step (no single batch) and re-run from scratch
        /// instead — not via the simple retry button.
        var isRetryable: Bool {
            if case .failed = state, !batch.isEmpty { return true }
            return false
        }
    }

    /// When on (default), uploading/downloading a DIRECTORY is routed through a
    /// single tar+gzip archive instead of sftp's file-by-file recursion — one
    /// compressed stream beats N round-trips for many small files. Read as
    /// "unset ⇒ true" so a fresh install gets the fast path. Toggled in Settings.
    static let packagedTransferKey = "harbor.packagedTransfer"
    private var packagedTransferEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.packagedTransferKey) as? Bool ?? true
    }

    @Published private(set) var status: Status = .idle
    /// Always an absolute, normalized remote path once `status == .ready`.
    @Published private(set) var cwd = ""
    /// Sorted: directories first, then localized name order.
    @Published private(set) var entries: [RemoteFileEntry] = []
    @Published private(set) var isLoading = false
    /// True while a quick mutation (delete / rename / mkdir) runs.
    @Published private(set) var isMutating = false
    /// Last listing/mutation failure; cleared on the next successful listing
    /// (or dismissed by the UI).
    @Published var errorMessage: String?
    @Published private(set) var transfers: [Transfer] = []
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// Non-destructive local-to-remote comparison awaiting an explicit user
    /// confirmation. Applying it can only call the existing upload path.
    @Published private(set) var directorySyncPreview: DirectorySyncPreview?
    @Published private(set) var isComparingDirectory = false

    private let exec: RemoteExec
    /// Persisted recent remote-path history (cap 2000), recorded after every
    /// successful directory listing and surfaced via the path bar's recall menu.
    private let pathHistory: PathHistoryStore
    /// Shared connect-time socket gate (one `ssh -O check` loop for all of this
    /// session's services, instead of each polling its own).
    private let readiness: SocketReadiness
    private var homePath = "/"
    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private var prepareTask: Task<Void, Never>?
    /// Invalidates stale in-flight listings (last navigation wins).
    private var listGeneration = 0
    /// Serializes sftp transfers so a burst of downloads cannot exhaust the
    /// server's MaxSessions on the shared master connection. Holds only the
    /// most-recently-enqueued task (each chains on the previous), so it's the
    /// tail of the queue, NOT the running head.
    private var transferChain: Task<Void, Never>?
    /// Every in-flight transfer task, keyed by transfer id. The chain above
    /// tracks only the tail; cancelling that alone leaves the RUNNING head
    /// (and its live sftp child) alive after the tab closes. `stop()` cancels
    /// all of these; each task removes itself here when it finishes.
    private var transferTasks: [UUID: Task<Void, Never>] = [:]
    /// The most recent in-flight delete/rename/mkdir, tracked so `stop()` can
    /// cancel it (otherwise an aux command outlives the closed session).
    private var mutationTask: Task<Void, Never>?
    /// External-editor sessions this service started. Owned here so `stop()` can
    /// tear them down on session exit (otherwise their poll timers keep firing
    /// sftp uploads over a dead socket and the user's saves silently fail).
    private var editSessions: [RemoteEditSession] = []
    private var directorySyncTask: Task<Void, Never>?

    /// The mux socket only appears AFTER authentication succeeds, and the
    /// session flips to .running on the first PTY byte — which for password /
    /// 2FA hosts is the auth prompt itself. The shared `readiness` gate polls
    /// patiently (cancelled via `prepareTask` when the session exits) instead of
    /// giving up while the user is still typing a password.
    private static let checkDeadline: TimeInterval = 600
    private static let probeTimeout: TimeInterval = 8
    private static let listTimeout: TimeInterval = 20
    private static let mutationTimeout: TimeInterval = 60
    /// Archive extraction can take a while for large archives, so it gets a far
    /// more generous bound than a quick mkdir/rename/delete.
    private static let extractTimeout: TimeInterval = 1800
    private static let transferTimeout: TimeInterval = 3600
    private static let transferHistoryLimit = 30
    /// Upper bound for the IN-APP editor. A multi-GB file would otherwise be
    /// slurped fully into RAM (Data + several String copies + TextEditor) and
    /// hang/OOM. The external-editor path streams to disk, so it has no cap.
    static let maxInAppEditBytes: UInt64 = 8 * 1024 * 1024

    init(
        destination: String,
        controlSocketPath: String,
        port: Int,
        readiness: SocketReadiness,
        pathHistory: PathHistoryStore = PathHistoryStore.shared
    ) {
        self.exec = RemoteExec(
            destination: destination,
            controlSocketPath: controlSocketPath,
            port: port
        )
        self.readiness = readiness
        self.pathHistory = pathHistory
    }

    /// Recent remote paths, newest first, for the path bar's recall menu. The
    /// consecutive-dupe collapse in `PathHistory` already keeps refreshes and
    /// the current directory from flooding the list.
    func recentPaths(_ count: Int) -> [String] {
        pathHistory.history.recent(count)
    }

    // MARK: - Lifecycle (driven by the session state)

    /// Called when the session reaches `.running` (and from the 重试 button):
    /// verifies the mux socket, probes the OS and `$HOME`, then lists the
    /// current directory. Keeps `cwd` across reconnects.
    func start() {
        guard !exec.destination.isEmpty else { return }
        prepareTask?.cancel()
        status = .preparing
        errorMessage = nil
        prepareTask = Task { [weak self] in
            await self?.prepare()
        }
    }

    /// Called when the session exits. Cancels every in-flight task and timer so
    /// nothing keeps polling/uploading over the now-dead ControlMaster socket.
    func stop() {
        prepareTask?.cancel()
        prepareTask = nil
        directorySyncTask?.cancel()
        directorySyncTask = nil
        directorySyncPreview = nil
        isComparingDirectory = false
        mutationTask?.cancel()
        mutationTask = nil
        // Cancel EVERY in-flight transfer (not just the chain tail): each
        // cancellation SIGTERMs its sftp child via AuxProcess's cancellation
        // handler, so the running head doesn't outlive the closed session.
        for task in transferTasks.values { task.cancel() }
        transferTasks.removeAll()
        transferChain = nil
        for timer in progressPollers.values { timer.invalidate() }
        progressPollers.removeAll()
        for task in remoteProgressTasks.values { task.cancel() }
        remoteProgressTasks.removeAll()
        // Stop external-editor sync (and remove their temp dirs); over a dead
        // socket uploads only fail.
        for session in editSessions { session.cancel() }
        editSessions.removeAll()
        listGeneration += 1
        isLoading = false
        isMutating = false
        status = .idle
    }

    private func prepare() async {
        // Share the connect-time `ssh -O check` poll with the monitor/info
        // services rather than running our own loop.
        let socketAlive = await readiness.waitUntilReady(
            deadline: Date().addingTimeInterval(Self.checkDeadline))
        guard !Task.isCancelled else { return }
        guard socketAlive else {
            status = .unsupported(reason: L("无法复用 SSH 连接（ControlMaster 套接字不可用）。"))
            return
        }

        let probe = await exec.run("uname -s; echo \"$HOME\"", timeout: Self.probeTimeout)
        guard !Task.isCancelled else { return }
        guard !probe.timedOut, probe.exitCode == 0 else {
            status = .unsupported(reason: L("无法在服务器上执行命令。"))
            return
        }
        let lines = probe.stdoutText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let os = lines.first ?? ""
        guard os == "Linux" else {
            status = .unsupported(reason: L("检测到系统：%@（目前仅支持 Linux）。", os.isEmpty ? L("未知") : os))
            return
        }
        homePath = lines.count > 1 && !lines[1].isEmpty ? RemotePath.normalize(lines[1]) : "/"
        if cwd.isEmpty { cwd = homePath }
        status = .ready
        await performList(path: cwd, step: .stay)
    }

    // MARK: - Navigation

    func refresh() {
        Task { await performList(path: cwd, step: .stay) }
    }

    /// 重试 from the unsupported notice / error banner.
    func retry() {
        if case .unsupported = status {
            start()
        } else {
            refresh()
        }
    }

    /// Path typed into the header field; supports `~`, absolute and relative.
    func navigate(toUserPath raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let absolute: String
        if trimmed == "~" {
            absolute = homePath
        } else if trimmed.hasPrefix("~/") {
            absolute = RemotePath.join(homePath, String(trimmed.dropFirst(2)))
        } else if trimmed.hasPrefix("/") {
            absolute = trimmed
        } else {
            absolute = RemotePath.join(cwd, trimmed)
        }
        Task { await performList(path: absolute, step: .push) }
    }

    /// Double-clicked directory (or symlink — entering follows it; a symlink
    /// to a file fails the listing and surfaces an error instead).
    func open(_ entry: RemoteFileEntry) {
        Task { await performList(path: RemotePath.join(cwd, entry.name), step: .push) }
    }

    func goUp() {
        guard cwd != "/" else { return }
        Task { await performList(path: RemotePath.parent(of: cwd), step: .push) }
    }

    func goBack() {
        guard let target = backStack.last else { return }
        Task { await performList(path: target, step: .back) }
    }

    func goForward() {
        guard let target = forwardStack.last else { return }
        Task { await performList(path: target, step: .forward) }
    }

    func absolutePath(of entry: RemoteFileEntry) -> String {
        RemotePath.join(cwd, entry.name)
    }

    /// Drives navigation from the directory tree: lists `path` and records it
    /// in history exactly like a typed path. No-op when not ready.
    func navigate(toPath path: String) {
        guard status == .ready else { return }
        Task { await performList(path: path, step: .push) }
    }

    /// The remote `$HOME`, resolved during `prepare()`. Used by the tree to
    /// reveal the home subtree.
    var home: String { homePath }

    // MARK: - Directory tree (lazy, directories-only)

    /// Lists ONLY the subdirectories of `path` for the left tree pane — same
    /// mux socket, same `RemoteLsParser`, no new auth path. Returns the child
    /// directory names (sorted, symlinks-to-dirs excluded so the tree never
    /// loops), or `nil` on failure/timeout so the tree can show an error glyph.
    /// Honors `includeHidden` for dotfile directories.
    func listSubdirectories(of path: String, includeHidden: Bool) async -> [String]? {
        guard status == .ready else { return nil }
        let target = RemotePath.normalize(path)
        let result = await exec.run(
            RemoteLsParser.listScript(path: target),
            timeout: Self.listTimeout
        )
        guard !result.timedOut, result.exitCode == 0 else { return nil }
        let stdout = result.stdout
        let dirs = await Task.detached(priority: .userInitiated) {
            RemoteLsParser.parse(String(decoding: stdout, as: UTF8.self))
                .filter { $0.isDirectory && !$0.isSymlink }
                .filter { includeHidden || !$0.isHidden }
                .map(\.name)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }.value
        return Task.isCancelled ? nil : dirs
    }

    /// History is only mutated after a listing succeeds, so a failed
    /// navigation never corrupts the stacks.
    private enum HistoryStep {
        case stay, push, back, forward
    }

    private func performList(path: String, step: HistoryStep) async {
        // Only allow listing when fully ready (user-triggered navigation) or
        // from within `prepare()` itself (which flips status to .ready first).
        guard status == .ready else { return }
        let target = RemotePath.normalize(path)
        listGeneration += 1
        let generation = listGeneration
        isLoading = true
        let result = await exec.run(RemoteLsParser.listScript(path: target), timeout: Self.listTimeout)
        guard generation == listGeneration else { return }
        isLoading = false
        guard !result.timedOut, result.exitCode == 0 else {
            errorMessage = Self.failureText(result)
            if result.timedOut {
                // Listing timed out: the mux socket is likely dead (network
                // drop with SSH process still alive). Reset the shared gate
                // and re-enter prepare() so the socket is re-verified and
                // the panel recovers automatically when the connection returns.
                readiness.reset()
                start()
            }
            return
        }
        let stdout = result.stdout
        let parsedEntries = await Task.detached(priority: .userInitiated) {
            RemoteLsParser.parse(String(decoding: stdout, as: UTF8.self)).sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }.value
        guard !Task.isCancelled, generation == listGeneration else { return }
        errorMessage = nil
        switch step {
        case .stay:
            break
        case .push:
            if target != cwd {
                backStack.append(cwd)
                forwardStack.removeAll()
            }
        case .back:
            if !backStack.isEmpty {
                backStack.removeLast()
                forwardStack.append(cwd)
            }
        case .forward:
            if !forwardStack.isEmpty {
                forwardStack.removeLast()
                backStack.append(cwd)
            }
        }
        cwd = target
        entries = parsedEntries
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
        // Persist where the user actually landed (typed path, double-click,
        // tree pick, up/back/forward, or the initial listing). Consecutive
        // dupes collapse in the model, so refresh/.stay re-lists don't pile up.
        pathHistory.record(target)
    }

    // MARK: - Transfers (sftp batch over the socket)

    var hasRunningTransfers: Bool {
        transfers.contains { $0.state == .running }
    }

    var hasFinishedTransfers: Bool {
        transfers.contains { $0.state != .running }
    }

    /// Downloads each item into ~/Downloads (directories recursively); name
    /// collisions get a "-2", "-3"… suffix locally.
    func download(_ items: [RemoteFileEntry]) {
        guard status == .ready, !items.isEmpty else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        for entry in items {
            // Directories go through tar+gzip when enabled (one compressed
            // archive instead of sftp's per-file recursion); regular files and
            // symlinks keep the direct sftp path.
            if entry.isDirectory, !entry.isSymlink, packagedTransferEnabled {
                enqueuePackagedDownload(entry, into: downloads)
                continue
            }
            let local = Self.uniqueLocalURL(for: entry.name, in: downloads)
            let batch = SFTPBatch.get(
                remote: absolutePath(of: entry),
                local: local.path,
                recursive: entry.isDirectory
            )
            enqueueTransfer(
                filename: entry.name,
                direction: .download,
                batch: batch,
                refreshAfter: false,
                // A single regular file can be progress-polled by its local size;
                // a recursive directory cannot, so leave it unpolled.
                progressURL: entry.isDirectory ? nil : local,
                totalBytes: entry.isDirectory ? 0 : Int64(entry.sizeBytes)
            )
        }
    }

    /// Uploads local files (or folders, recursively) into the current
    /// directory. Refreshes the listing after each completed upload.
    func upload(urls: [URL]) {
        guard status == .ready, !urls.isEmpty else { return }
        for url in urls where url.isFileURL {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            // Folders go through tar+gzip when enabled; regular files keep the
            // direct sftp put, now with live progress from a remote stat poll.
            if isDirectory, packagedTransferEnabled {
                enqueuePackagedUpload(localURL: url)
                continue
            }
            let total = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let remote = RemotePath.join(cwd, url.lastPathComponent)
            let batch = SFTPBatch.put(
                local: url.path,
                remote: remote,
                recursive: isDirectory
            )
            enqueueTransfer(
                filename: url.lastPathComponent,
                direction: .upload,
                batch: batch,
                refreshAfter: true,
                // Uploads can't poll a local file; watch the growing remote one.
                remoteProgressPath: isDirectory ? nil : remote,
                totalBytes: total
            )
        }
    }

    // MARK: - Safe directory sync preview

    /// Compares the selected local folder with the CURRENT remote directory on
    /// a background task. This is dry-run only: no remote mutation happens
    /// until `applyDirectorySyncPreview()` is explicitly invoked by the sheet.
    func compareDirectory(_ localDirectory: URL) {
        guard status == .ready else { return }
        directorySyncTask?.cancel()
        let remoteDirectory = cwd
        let remoteEntries = entries
        isComparingDirectory = true
        directorySyncPreview = nil
        directorySyncTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try DirectorySyncPlanner.makePreview(
                        localDirectory: localDirectory,
                        remoteDirectory: remoteDirectory,
                        remoteEntries: remoteEntries
                    )
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.isComparingDirectory = false
            self.directorySyncTask = nil
            guard self.cwd == remoteDirectory else { return }
            switch result {
            case .success(let preview):
                self.directorySyncPreview = preview
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func dismissDirectorySyncPreview() {
        directorySyncPreview = nil
    }

    /// Applies only the local-new and locally-different preview rows. The
    /// preview has no delete path, so remote-only files are always preserved.
    func applyDirectorySyncPreview() {
        guard let preview = directorySyncPreview else { return }
        guard status == .ready, cwd == preview.remoteDirectory else {
            errorMessage = L("远程目录已变更，请重新对比后再同步。")
            return
        }
        directorySyncPreview = nil
        upload(urls: preview.uploadURLs)
    }

    /// Downloads each item into a custom local directory (instead of ~/Downloads),
    /// for the dual-pane "下载到 Mac" action that targets the local pane's cwd.
    /// Name collisions get a "-2", "-3"… suffix locally.
    func download(into localDir: URL, items: [RemoteFileEntry]) {
        guard status == .ready, !items.isEmpty else { return }
        for entry in items {
            if entry.isDirectory, !entry.isSymlink, packagedTransferEnabled {
                enqueuePackagedDownload(entry, into: localDir)
                continue
            }
            let local = Self.uniqueLocalURL(for: entry.name, in: localDir)
            let batch = SFTPBatch.get(
                remote: absolutePath(of: entry),
                local: local.path,
                recursive: entry.isDirectory
            )
            enqueueTransfer(
                filename: entry.name,
                direction: .download,
                batch: batch,
                refreshAfter: false,
                progressURL: entry.isDirectory ? nil : local,
                totalBytes: entry.isDirectory ? 0 : Int64(entry.sizeBytes)
            )
        }
    }

    func clearFinishedTransfers() {
        transfers.removeAll { $0.state != .running }
    }

    /// Downloads `entry` to a temp copy, opens it in the default editor, and
    /// auto-uploads it back on every save (see `RemoteEditSession`).
    func beginEdit(_ entry: RemoteFileEntry) {
        guard status == .ready, !entry.isDirectory else { return }
        guard !entry.isSymlink else {
            errorMessage = RemoteEditFailure.symlink.message
            return
        }
        let remotePath = absolutePath(of: entry)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-edit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let localURL = tempDir.appendingPathComponent(entry.name)
        let exec = self.exec
        let transfer = Transfer(filename: entry.name, direction: .download)
        let transferID = transfer.id
        transfers.append(transfer)
        trimTransfers()
        // Route the initial download through the SAME serialization chain as
        // every other transfer (it previously spawned its own bare Task), so
        // opening several files at once can't exhaust the master's MaxSessions.
        let previous = transferChain
        let task = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: tempDir)
                return
            }
            let initialVersion: RemoteFileVersion
            switch await readRemoteFileVersion(using: exec, path: remotePath) {
            case .success(let version):
                initialVersion = version
            case .failure(let failure):
                self?.transferTasks.removeValue(forKey: transferID)
                self?.failTransfer(transferID, failure.message)
                try? FileManager.default.removeItem(at: tempDir)
                return
            }
            let result = await exec.runSFTPBatch(
                SFTPBatch.get(remote: remotePath, local: localURL.path),
                timeout: Self.transferTimeout
            )
            guard let self else {
                try? FileManager.default.removeItem(at: tempDir)
                return
            }
            defer { self.transferTasks.removeValue(forKey: transferID) }
            guard !result.timedOut, result.exitCode == 0,
                  FileManager.default.fileExists(atPath: localURL.path) else {
                self.completeTransfer(id: transferID, result: result, refreshAfter: false)
                // Download failed/cancelled: drop the temp dir instead of leaking it.
                try? FileManager.default.removeItem(at: tempDir)
                return
            }
            let downloadedVersion: RemoteFileVersion
            switch await readRemoteFileVersion(using: exec, path: remotePath) {
            case .success(let version):
                downloadedVersion = version
            case .failure(let failure):
                self.failTransfer(transferID, failure.message)
                try? FileManager.default.removeItem(at: tempDir)
                return
            }
            guard downloadedVersion == initialVersion else {
                self.failTransfer(transferID, RemoteEditFailure.conflict.message)
                try? FileManager.default.removeItem(at: tempDir)
                return
            }
            self.completeTransfer(id: transferID, result: result, refreshAfter: false)
            // Bail if the service was stopped while the download was in flight —
            // the session would start polling sftp over a dead socket otherwise.
            guard !Task.isCancelled, self.status == .ready else {
                try? FileManager.default.removeItem(at: tempDir)
                return
            }
            let session = RemoteEditSession(
                localURL: localURL,
                remotePath: remotePath,
                expectedVersion: downloadedVersion,
                exec: exec,
                onUpload: { [weak self] result in
                    self?.recordEditUpload(filename: entry.name, result: result)
                },
                onEnd: { [weak self] session in
                    self?.editSessions.removeAll { $0 === session }
                }
            )
            self.editSessions.append(session)
            session.start()
        }
        transferChain = task
        transferTasks[transferID] = task
    }

    /// User-facing failure carrying a localized message (Result needs Error).
    struct EditError: Error, Sendable { let message: String }

    struct LoadedText: Sendable {
        let text: String
        let version: RemoteFileVersion
    }

    private enum LocalTextReadResult: Sendable {
        case text(String)
        case unreadable
        case binary
    }

    private enum LocalTextWriteResult: Sendable {
        case success
        case failure(String)
    }

    /// Downloads `entry` as UTF-8 text for the in-app editor. Fails clearly for
    /// binary files (so the editor never shows garbage).
    func loadText(_ entry: RemoteFileEntry) async -> Result<LoadedText, EditError> {
        guard status == .ready, !entry.isDirectory else { return .failure(EditError(message: L("会话未就绪。"))) }
        guard !entry.isSymlink else {
            return .failure(EditError(message: RemoteEditFailure.symlink.message))
        }
        // Refuse to slurp a huge file fully into RAM (Data + several String
        // copies + TextEditor) — use the already-known size. The external editor
        // streams to disk, so offer that instead.
        guard entry.sizeBytes <= Self.maxInAppEditBytes else {
            return .failure(EditError(message: L(
                "文件过大（%@），无法在应用内编辑；请用外部编辑器打开。",
                MonitorFormat.sizeShort(bytes: Double(entry.sizeBytes)))))
        }
        let exec = self.exec
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-edit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let remotePath = absolutePath(of: entry)
        let initialVersion: RemoteFileVersion
        switch await readRemoteFileVersion(using: exec, path: remotePath) {
        case .success(let version):
            initialVersion = version
        case .failure(let failure):
            return .failure(EditError(message: failure.message))
        }
        let result = await exec.runSFTPBatch(
            SFTPBatch.get(remote: remotePath, local: tempURL.path),
            timeout: Self.transferTimeout
        )
        guard !result.timedOut, result.exitCode == 0 else { return .failure(EditError(message: Self.failureText(result))) }
        let downloadedVersion: RemoteFileVersion
        switch await readRemoteFileVersion(using: exec, path: remotePath) {
        case .success(let version):
            downloadedVersion = version
        case .failure(let failure):
            return .failure(EditError(message: failure.message))
        }
        guard downloadedVersion == initialVersion else {
            return .failure(EditError(message: RemoteEditFailure.conflict.message))
        }
        let localText = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: tempURL) else { return LocalTextReadResult.unreadable }
            guard let text = String(data: data, encoding: .utf8) else { return LocalTextReadResult.binary }
            return .text(text)
        }.value
        switch localText {
        case .text(let text):
            return .success(LoadedText(text: text, version: downloadedVersion))
        case .unreadable:
            return .failure(EditError(message: L("无法读取下载的文件。")))
        case .binary:
            return .failure(EditError(message: L("这似乎是二进制文件，无法以文本方式编辑。")))
        }
    }

    /// Writes edited `content` to a sibling staging file, then conditionally and
    /// atomically replaces the version that was originally loaded.
    func saveText(
        _ entry: RemoteFileEntry,
        content: String,
        expectedVersion: RemoteFileVersion
    ) async -> Result<RemoteFileVersion, EditError> {
        guard status == .ready, !entry.isDirectory else { return .failure(EditError(message: L("会话未就绪。"))) }
        guard !entry.isSymlink else {
            return .failure(EditError(message: RemoteEditFailure.symlink.message))
        }
        guard content.utf8.count <= Self.maxInAppEditBytes else {
            return .failure(EditError(message: L("编辑后的文件超过应用内保存上限（8 MB）。")))
        }
        let exec = self.exec
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-edit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let localWrite = await Task.detached(priority: .userInitiated) {
            do {
                try Data(content.utf8).write(to: tempURL, options: .atomic)
                return LocalTextWriteResult.success
            } catch {
                return .failure(error.localizedDescription)
            }
        }.value
        if case .failure(let message) = localWrite {
            return .failure(EditError(message: message))
        }
        switch await atomicRemoteUpload(
            localURL: tempURL,
            remotePath: absolutePath(of: entry),
            expectedVersion: expectedVersion,
            using: exec,
            timeout: Self.transferTimeout
        ) {
        case .success(let version):
            return .success(version)
        case .failure(let failure):
            return .failure(EditError(message: failure.message))
        }
    }

    private func recordEditUpload(
        filename: String,
        result: Result<Void, RemoteEditFailure>
    ) {
        var transfer = Transfer(filename: filename, direction: .upload)
        switch result {
        case .success:
            transfer.state = .done
        case .failure(let failure):
            transfer.state = .failed(failure.message)
        }
        transfers.append(transfer)
        trimTransfers()
        if case .success = result, status == .ready { refresh() }
    }

    private func enqueueTransfer(
        filename: String,
        direction: TransferDirection,
        batch: String,
        refreshAfter: Bool,
        progressURL: URL? = nil,
        remoteProgressPath: String? = nil,
        totalBytes: Int64 = 0
    ) {
        var transfer = Transfer(filename: filename, direction: direction)
        transfer.total = totalBytes
        transfer.batch = batch
        transfer.refreshAfter = refreshAfter
        transfer.progressURL = progressURL
        transfer.remoteProgressPath = remoteProgressPath
        let id = transfer.id
        transfers.append(transfer)
        trimTransfers()
        scheduleBatch(id: id, batch: batch, progressURL: progressURL,
                      remoteProgressPath: remoteProgressPath, refreshAfter: refreshAfter)
    }

    /// Re-runs a failed transfer's sftp batch under a fresh queue slot, reusing
    /// the original local path (a partial download is overwritten, not
    /// duplicated). No-op unless the row is failed and carries a batch.
    func retryTransfer(_ id: UUID) {
        guard status == .ready,
              let index = transfers.firstIndex(where: { $0.id == id }),
              transfers[index].isRetryable else { return }
        let t = transfers[index]
        transfers[index].state = .running
        transfers[index].transferred = 0
        transfers[index].bytesPerSecond = 0
        scheduleBatch(id: id, batch: t.batch, progressURL: t.progressURL,
                      remoteProgressPath: t.remoteProgressPath, refreshAfter: t.refreshAfter)
    }

    /// Chains one sftp batch onto the serial transfer queue and wires its
    /// progress poll + completion. Shared by the initial enqueue and retry so
    /// both honor the same MaxSessions-protecting serialization.
    private func scheduleBatch(
        id: UUID, batch: String, progressURL: URL?,
        remoteProgressPath: String?, refreshAfter: Bool
    ) {
        let exec = self.exec
        let previous = transferChain
        let task = Task { [weak self] in
            await previous?.value
            // Start the progress poll only once THIS transfer actually begins —
            // not while it waits behind a long one — so it never polls a
            // not-yet-existing file for the whole queue wait.
            if let progressURL { self?.startProgressPoll(transferID: id, localURL: progressURL) }
            if let remoteProgressPath { self?.startRemoteProgressPoll(transferID: id, remotePath: remoteProgressPath) }
            let result = await exec.runSFTPBatch(batch, timeout: Self.transferTimeout)
            self?.stopProgressPoll(transferID: id)
            self?.completeTransfer(id: id, result: result, refreshAfter: refreshAfter)
            self?.transferTasks.removeValue(forKey: id)
        }
        transferChain = task
        transferTasks[id] = task
    }

    // MARK: - Packaged (tar+gzip) folder transfers

    /// macOS bundles bsdtar here; it reads/writes gzip via the `z` flag.
    private static let localTar = "/usr/bin/tar"

    /// A throwaway remote archive path. Our own name (UUID, no shell-special
    /// chars), but still `sq()`-quoted everywhere it is interpolated.
    private func remoteTempArchive() -> String {
        "/tmp/harbor-xfer-\(UUID().uuidString).tar.gz"
    }

    /// Downloads a directory as ONE tar+gzip archive: pack remotely, pull the
    /// archive (progress-pollable), extract locally into Downloads, clean up
    /// both temp archives. Far fewer round-trips than sftp's per-file recursion.
    private func enqueuePackagedDownload(_ entry: RemoteFileEntry, into downloads: URL) {
        let parent = RemotePath.parent(of: absolutePath(of: entry))
        let name = entry.name
        var transfer = Transfer(filename: name, direction: .download)
        transfer.packaged = true
        let id = transfer.id
        transfers.append(transfer)
        trimTransfers()
        let exec = self.exec
        let previous = transferChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.runPackagedDownload(
                id: id, parent: parent, name: name, downloads: downloads, exec: exec)
            self?.transferTasks.removeValue(forKey: id)
        }
        transferChain = task
        transferTasks[id] = task
    }

    private func runPackagedDownload(
        id: UUID, parent: String, name: String, downloads: URL, exec: RemoteExec
    ) async {
        // Any early exit (incl. Task cancellation from stop()) that leaves the
        // row still .running marks it failed, so a torn-down packaged transfer
        // never sticks as a phantom in-progress row.
        defer { failIfStillRunning(id) }

        let remoteTgz = remoteTempArchive()
        let localTgz = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-dl-\(UUID().uuidString).tar.gz")
        // Stage INSIDE Downloads so the final move is same-volume (a temp-dir
        // staging on a different volume than a redirected ~/Downloads would make
        // moveItem fail with EXDEV and discard a completed download).
        let staging = downloads.appendingPathComponent(
            ".harbor-stage-\(UUID().uuidString)", isDirectory: true)
        // Remote cleanup is detached so it still runs if THIS task was cancelled
        // (an `exec.run` issued from a cancelled task no-ops without spawning ssh,
        // which would otherwise leak the remote /tmp archive).
        func cleanupRemote() {
            Task.detached { _ = await exec.run("rm -f \(sq(remoteTgz))", timeout: 15) }
        }
        func cleanupLocal() {
            try? FileManager.default.removeItem(at: localTgz)
            try? FileManager.default.removeItem(at: staging)
        }

        // 1. Pack on the remote (`--` guards a name starting with "-").
        let pack = await exec.run(
            "tar czf \(sq(remoteTgz)) -C \(sq(parent)) -- \(sq(name))",
            timeout: Self.transferTimeout)
        guard !Task.isCancelled else { cleanupRemote(); cleanupLocal(); return }
        guard !pack.timedOut, pack.exitCode == 0 else {
            cleanupRemote(); cleanupLocal(); failTransfer(id, Self.failureText(pack)); return
        }

        // 2. Pull the single archive (progress from its growing local size).
        startProgressPoll(transferID: id, localURL: localTgz)
        let get = await exec.runSFTPBatch(
            SFTPBatch.get(remote: remoteTgz, local: localTgz.path), timeout: Self.transferTimeout)
        stopProgressPoll(transferID: id)
        cleanupRemote()
        guard !Task.isCancelled else { cleanupLocal(); return }
        guard !get.timedOut, get.exitCode == 0 else {
            cleanupLocal(); failTransfer(id, Self.failureText(get)); return
        }

        // 3. Extract locally into the staging dir, then move the extracted folder
        //    into Downloads with the usual "-2" collision suffix.
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let extract = await AuxProcess.run(
            argv: [Self.localTar, "xzf", localTgz.path, "-C", staging.path],
            timeout: Self.transferTimeout)
        guard extract.exitCode == 0 else {
            cleanupLocal(); failTransfer(id, L("解压下载的压缩包失败")); return
        }
        // Move the ACTUAL single top-level entry (normally `name`, but don't
        // assume — some tar configs store members differently).
        let items = (try? FileManager.default.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: nil)) ?? []
        guard let source = items.first(where: { $0.lastPathComponent == name }) ?? items.first else {
            cleanupLocal(); failTransfer(id, L("解压下载的压缩包失败")); return
        }
        let dest = Self.uniqueLocalURL(for: source.lastPathComponent, in: downloads)
        do {
            try FileManager.default.moveItem(at: source, to: dest)
        } catch {
            cleanupLocal(); failTransfer(id, error.localizedDescription); return
        }
        cleanupLocal()
        doneTransfer(id)
    }

    /// Uploads a local directory as ONE tar+gzip archive: pack locally, push the
    /// archive (progress from a remote stat poll), extract on the remote into the
    /// current directory, clean up both temp archives.
    private func enqueuePackagedUpload(localURL: URL) {
        let name = localURL.lastPathComponent
        let localParent = localURL.deletingLastPathComponent().path
        let destDir = cwd
        var transfer = Transfer(filename: name, direction: .upload)
        transfer.packaged = true
        let id = transfer.id
        transfers.append(transfer)
        trimTransfers()
        let exec = self.exec
        let previous = transferChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.runPackagedUpload(
                id: id, localParent: localParent, name: name, destDir: destDir, exec: exec)
            self?.transferTasks.removeValue(forKey: id)
        }
        transferChain = task
        transferTasks[id] = task
    }

    private func runPackagedUpload(
        id: UUID, localParent: String, name: String, destDir: String, exec: RemoteExec
    ) async {
        defer { failIfStillRunning(id) }

        let localTgz = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-ul-\(UUID().uuidString).tar.gz")
        let remoteTgz = remoteTempArchive()
        func cleanupLocal() { try? FileManager.default.removeItem(at: localTgz) }
        // Detached so it survives cancellation of this task (see the download path).
        func cleanupRemote() {
            Task.detached { _ = await exec.run("rm -f \(sq(remoteTgz))", timeout: 15) }
        }

        // 1. Pack locally (child process, no shell — `--` guards the name).
        let pack = await AuxProcess.run(
            argv: [Self.localTar, "czf", localTgz.path, "-C", localParent, "--", name],
            timeout: Self.transferTimeout)
        guard pack.exitCode == 0 else {
            cleanupLocal(); failTransfer(id, L("打包待上传的文件夹失败")); return
        }
        guard !Task.isCancelled else { cleanupLocal(); return }
        // Total is now known: the compressed archive size.
        let attrs = try? FileManager.default.attributesOfItem(atPath: localTgz.path)
        setTotal(id, (attrs?[.size] as? NSNumber)?.int64Value ?? 0)

        // 2. Push the archive (progress from the growing remote file).
        startRemoteProgressPoll(transferID: id, remotePath: remoteTgz)
        let put = await exec.runSFTPBatch(
            SFTPBatch.put(local: localTgz.path, remote: remoteTgz), timeout: Self.transferTimeout)
        stopProgressPoll(transferID: id)
        cleanupLocal()
        guard !Task.isCancelled else { cleanupRemote(); return }
        guard !put.timedOut, put.exitCode == 0 else {
            cleanupRemote(); failTransfer(id, Self.failureText(put)); return
        }

        // 3. Extract on the remote into the destination dir, then drop the archive.
        let extract = await exec.run(
            "mkdir -p \(sq(destDir)) && tar xzf \(sq(remoteTgz)) -C \(sq(destDir))",
            timeout: Self.transferTimeout)
        cleanupRemote()
        guard !extract.timedOut, extract.exitCode == 0 else {
            failTransfer(id, Self.failureText(extract)); return
        }
        doneTransfer(id, refreshAfter: true)
    }

    private func failTransfer(_ id: UUID, _ reason: String) {
        if let i = transfers.firstIndex(where: { $0.id == id }) {
            transfers[i].state = .failed(reason)
        }
    }

    /// Marks a row failed("已取消") only if it's still .running — the `defer`
    /// backstop for packaged transfers so a cancelled/torn-down one resolves
    /// instead of spinning forever. A row already .done/.failed is left as-is.
    private func failIfStillRunning(_ id: UUID) {
        if let i = transfers.firstIndex(where: { $0.id == id }), transfers[i].state == .running {
            transfers[i].state = .failed(L("已取消"))
        }
    }

    private func doneTransfer(_ id: UUID, refreshAfter: Bool = false) {
        if let i = transfers.firstIndex(where: { $0.id == id }) {
            transfers[i].state = .done
        }
        if refreshAfter, status == .ready { refresh() }
    }

    private func setTotal(_ id: UUID, _ total: Int64) {
        if let i = transfers.firstIndex(where: { $0.id == id }) {
            transfers[i].total = total
        }
    }

    // MARK: - Transfer progress (download speed)

    private var progressPollers: [UUID: Timer] = [:]
    /// Remote-size poll tasks for in-flight uploads (keyed by transfer id).
    private var remoteProgressTasks: [UUID: Task<Void, Never>] = [:]

    /// Polls a downloading file's local size to derive a live byte count + speed.
    private func startProgressPoll(transferID: UUID, localURL: URL) {
        var lastSize: Int64 = 0
        var lastTime = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size]
                    as? NSNumber)?.int64Value ?? 0
                let now = Date()
                let elapsed = now.timeIntervalSince(lastTime)
                let speed = elapsed > 0 ? Double(size - lastSize) / elapsed : 0
                self.updateProgress(transferID, transferred: size, speed: max(0, speed))
                lastSize = size
                lastTime = now
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressPollers[transferID] = timer
    }

    /// Upload progress: an upload has no local file to watch, so poll the
    /// growing REMOTE file's size with a tiny `stat -c %s` every 0.6s over the
    /// shared socket. Uploads are serialized, so at most one of these runs at a
    /// time. Self-cancels on completion via `stopProgressPoll`.
    private func startRemoteProgressPoll(transferID: UUID, remotePath: String) {
        let exec = self.exec
        let task = Task { [weak self] in
            var lastSize: Int64 = 0
            var lastTime = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000)
                if Task.isCancelled { return }
                let out = await exec.run(
                    "LC_ALL=C stat -c %s \(sq(remotePath)) 2>/dev/null", timeout: 4)
                guard let self, !Task.isCancelled else { return }
                let size = Int64(out.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? lastSize
                let now = Date()
                let elapsed = now.timeIntervalSince(lastTime)
                let speed = elapsed > 0 ? Double(size - lastSize) / elapsed : 0
                self.updateProgress(transferID, transferred: size, speed: max(0, speed))
                lastSize = size
                lastTime = now
            }
        }
        remoteProgressTasks[transferID] = task
    }

    private func stopProgressPoll(transferID: UUID) {
        progressPollers.removeValue(forKey: transferID)?.invalidate()
        remoteProgressTasks.removeValue(forKey: transferID)?.cancel()
    }

    private func updateProgress(_ id: UUID, transferred: Int64, speed: Double) {
        guard let index = transfers.firstIndex(where: { $0.id == id }),
              transfers[index].state == .running else { return }
        transfers[index].transferred = transferred
        transfers[index].bytesPerSecond = speed
    }

    private func completeTransfer(id: UUID, result: AuxProcess.Output, refreshAfter: Bool) {
        if let index = transfers.firstIndex(where: { $0.id == id }) {
            transfers[index].state = (result.timedOut || result.exitCode != 0)
                ? .failed(Self.failureText(result))
                : .done
        }
        if refreshAfter, status == .ready {
            refresh()
        }
    }

    /// Drops the oldest finished transfers beyond the history cap.
    private func trimTransfers() {
        while transfers.count > Self.transferHistoryLimit,
              let index = transfers.firstIndex(where: { $0.state != .running }) {
            transfers.remove(at: index)
        }
    }

    private static func uniqueLocalURL(for name: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            candidate = directory.appendingPathComponent(next)
            counter += 1
        }
        return candidate
    }

    // MARK: - Mutations (delete / rename / mkdir)

    /// `rm -rf` over ssh (handles files and directories alike); the UI shows a
    /// confirmation dialog with the exact paths first.
    ///
    /// OPTIMISTIC: the rows are dropped from the listing IMMEDIATELY so the UI
    /// updates instantly, regardless of how slow — or momentarily stalled — the
    /// remote round-trip is. The old path waited for the rm AND a full re-list,
    /// which felt frozen (10s+) on a sluggish ControlMaster mux. On failure the
    /// listing is resynced from the server and the error surfaced.
    func delete(_ items: [RemoteFileEntry]) {
        guard status == .ready, !items.isEmpty else { return }
        let names = Set(items.map(\.name))
        let cwdAtDelete = cwd
        let script = "rm -rf -- " + items
            .map { sq(absolutePath(of: $0)) }
            .joined(separator: " ")
        // Remove now — no spinner, no waiting on the network.
        entries.removeAll { names.contains($0.name) }
        let exec = self.exec
        // Wait for any in-flight rename/mkdir to finish before issuing the
        // delete; cancelling it here would silently discard the user's prior
        // operation with no feedback.
        let prior = mutationTask
        mutationTask = Task { [weak self] in
            await prior?.value
            let result = await exec.run(script, timeout: Self.mutationTimeout)
            guard let self, !Task.isCancelled else { return }
            // Success: the rows are already gone, nothing more to do.
            guard result.timedOut || result.exitCode != 0 else { return }
            // Failed: report and resync to the real listing (if still here).
            self.errorMessage = Self.failureText(result)
            if self.cwd == cwdAtDelete {
                await self.performList(path: cwdAtDelete, step: .stay)
            }
        }
    }

    /// One-click extract of an uploaded archive (zip / 7z / rar / tar.* / gz / …)
    /// into its own directory, then re-list to reveal the result. The matching
    /// Linux tool (unzip / 7z / unrar / tar …) must exist on the server; a
    /// missing one surfaces as a normal command error.
    /// Extract into the archive's own directory (current directory).
    func extract(_ entry: RemoteFileEntry) {
        extract(entry, to: cwd)
    }

    /// Extract into an arbitrary remote directory (created if missing). Supports
    /// `~` and relative paths just like the path bar. After success, re-lists
    /// whichever directory the user is currently viewing (so an in-place extract
    /// reveals the result; extracting elsewhere just refreshes).
    func extract(_ entry: RemoteFileEntry, to targetDir: String) {
        guard status == .ready, !entry.isDirectory else { return }
        let trimmed = targetDir.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let absoluteTarget: String
        if trimmed == "~" {
            absoluteTarget = homePath
        } else if trimmed.hasPrefix("~/") {
            absoluteTarget = RemotePath.join(homePath, String(trimmed.dropFirst(2)))
        } else if trimmed.hasPrefix("/") {
            absoluteTarget = trimmed
        } else {
            absoluteTarget = RemotePath.join(cwd, trimmed)
        }
        guard let cmd = ArchiveKind.extractCommand(
            archivePath: absolutePath(of: entry), into: RemotePath.normalize(absoluteTarget))
        else { return }
        let exec = self.exec
        let tool = ArchiveKind.requiredTool(for: entry.name)
        let dir = cwd
        isMutating = true
        let prior = mutationTask
        mutationTask = Task { [weak self] in
            await prior?.value
            let result = await exec.run(cmd, timeout: Self.extractTimeout)
            guard let self, !Task.isCancelled else { return }
            self.isMutating = false
            if result.timedOut || result.exitCode != 0 {
                let stderr = result.stderrText.lowercased()
                if let tool, stderr.contains("not found") {
                    // Lean server missing the extractor → tell the user what to install.
                    self.errorMessage = L("服务器未安装 %@，请先运行 apt install %@ 后重试",
                                          tool.tool, tool.package)
                } else {
                    self.errorMessage = Self.failureText(result)
                }
            }
            // Re-list to reveal the extracted files (or just refresh on failure).
            if self.cwd == dir { await self.performList(path: dir, step: .stay) }
        }
    }

    /// Whether the file panel should offer a 解压 action for this entry.
    func canExtract(_ entry: RemoteFileEntry) -> Bool {
        !entry.isDirectory && ArchiveKind.isArchive(entry.name)
    }

    func rename(_ entry: RemoteFileEntry, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard status == .ready, !trimmed.isEmpty, trimmed != entry.name,
              !trimmed.contains("/") else { return }
        let batch = SFTPBatch.rename(
            from: absolutePath(of: entry),
            to: RemotePath.join(cwd, trimmed)
        )
        let exec = self.exec
        runMutation { await exec.runSFTPBatch(batch, timeout: Self.mutationTimeout) }
    }

    func createDirectory(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard status == .ready, !trimmed.isEmpty, !trimmed.contains("/") else { return }
        let batch = SFTPBatch.mkdir(RemotePath.join(cwd, trimmed))
        let exec = self.exec
        runMutation { await exec.runSFTPBatch(batch, timeout: Self.mutationTimeout) }
    }

    /// `chmod <octal> <path>` over ssh. `octal` is a 3–4 digit mode string
    /// (validated by the caller's permission editor).
    func changePermissions(_ entry: RemoteFileEntry, octal: String) {
        guard status == .ready,
              !octal.isEmpty, octal.count <= 4, octal.allSatisfy({ ("0"..."7").contains($0) })
        else { return }
        let script = "chmod \(octal) -- " + sq(absolutePath(of: entry))
        let exec = self.exec
        runMutation { await exec.run(script, timeout: Self.mutationTimeout) }
    }

    /// `chown owner:group <path>` over ssh.
    func changeOwner(_ entry: RemoteFileEntry, owner: String, group: String) {
        let trimmedOwner = owner.trimmingCharacters(in: .whitespaces)
        let trimmedGroup = group.trimmingCharacters(in: .whitespaces)
        guard status == .ready, !trimmedOwner.isEmpty, !trimmedGroup.isEmpty else { return }
        let spec = sq("\(trimmedOwner):\(trimmedGroup)")
        let script = "chown \(spec) -- " + sq(absolutePath(of: entry))
        let exec = self.exec
        runMutation { await exec.run(script, timeout: Self.mutationTimeout) }
    }

    private func runMutation(_ work: @escaping @Sendable () async -> AuxProcess.Output) {
        isMutating = true
        let prior = mutationTask
        mutationTask = Task { [weak self] in
            await prior?.value
            let result = await work()
            // stop() cancels this task on session exit; don't touch state or
            // re-list a torn-down session after the fact.
            guard let self, !Task.isCancelled else { return }
            self.isMutating = false
            if result.timedOut || result.exitCode != 0 {
                self.errorMessage = Self.failureText(result)
            }
            await self.performList(path: self.cwd, step: .stay)
        }
    }

    // MARK: - Errors

    /// Surfaces the most informative stderr line (ssh/sftp print multi-line
    /// noise); falls back to the exit code.
    @MainActor
    private static func failureText(_ output: AuxProcess.Output) -> String {
        if output.timedOut { return L("操作超时") }
        let stderr = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let line = stderr.split(separator: "\n").last(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) {
            return String(line)
        }
        return L("命令执行失败（退出码 %lld）", Int(output.exitCode))
    }
}
