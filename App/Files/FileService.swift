import Foundation
import HarborKit
import os.log

// MARK: - Persistent path history store

/// App-layer wrapper around HarborKit's pure `PathHistory`. History is bucketed
/// PER HOST so one server's paths never surface in another's recall menu. Disk
/// persistence is opt-in in Privacy settings; each bucket persists under its
/// own key derived from the host identity. `shared` remains as the privacy
/// control point: clearing it clears every host bucket.
@MainActor
final class PathHistoryStore: ObservableObject {
    static let storageKey = HistoryPrivacyPreference.pathStorageKey
    static let shared = PathHistoryStore()

    private static var hostBuckets: [String: PathHistoryStore] = [:]

    /// The per-host store for a session identity (`user@host` + port). Buckets
    /// live for the app's lifetime; their persisted entries follow the same
    /// privacy preference as the legacy shared key.
    static func forHost(destination: String, port: Int) -> PathHistoryStore {
        let key = "\(destination)#\(port)"
        if let bucket = hostBuckets[key] { return bucket }
        let bucket = PathHistoryStore(
            storageKey: "\(HistoryPrivacyPreference.pathStorageKey).\(key)")
        hostBuckets[key] = bucket
        return bucket
    }

    @Published private(set) var history: PathHistory
    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = HistoryPrivacyPreference.pathStorageKey) {
        self.defaults = defaults
        self.storageKey = storageKey
        let persists = HistoryPrivacyPreference.isPersistenceEnabled(in: defaults)
        if !persists { defaults.removeObject(forKey: storageKey) }
        // One-time cleanup: pre-bucketing builds stored everything under the
        // shared key; drop it so old cross-host entries never resurface.
        if storageKey != Self.storageKey { defaults.removeObject(forKey: Self.storageKey) }
        let stored = persists ? (defaults.stringArray(forKey: storageKey) ?? []) : []
        self.history = PathHistory(entries: stored)
    }

    func record(_ path: String) {
        history.record(path)
        if HistoryPrivacyPreference.isPersistenceEnabled(in: defaults) {
            defaults.set(history.entries, forKey: storageKey)
        } else {
            defaults.removeObject(forKey: storageKey)
        }
    }

    func clear() {
        history = PathHistory()
        defaults.removeObject(forKey: storageKey)
        // Settings' privacy clear goes through `.shared`; it must also drop
        // every host bucket's in-memory and persisted entries.
        if self === Self.shared {
            for bucket in Self.hostBuckets.values { bucket.clear() }
        }
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
        /// Explicitly cancelled by the user — visually distinct from a failure.
        case cancelled
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
        /// Only staged direct transfers have a complete safe retry plan.
        /// External-editor and packaged rows deliberately remain non-retryable.
        var retryable: Bool = false
        /// True for packaged (tar+gzip) folder transfers, shown with a tag.
        var packaged: Bool = false

        /// Only failed transfers with a retained staged plan can be retried.
        var isRetryable: Bool {
            if case .failed = state, retryable { return true }
            return false
        }
    }

    /// Direct file transfers cannot safely hand their user-visible destination
    /// straight to sftp: `get`/`put` may follow an existing symlink. Keep the
    /// requested transfer parameters separately so a failed staged transfer can
    /// retain the normal Retry affordance without ever retrying an unsafe batch.
    private enum DirectTransferPlan {
        case download(remote: String, localDirectory: URL, filename: String, recursive: Bool)
        case upload(localURL: URL, remote: String, recursive: Bool)
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
    /// True when the current remote listing was hard-capped. Surfaced as a
    /// notice so a huge directory is never silently truncated.
    @Published private(set) var listingTruncated = false

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
    private var consecutiveListTimeouts = 0
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
    /// Retry plans for direct transfers. No direct destination batch is retained:
    /// every retry reconstructs a fresh no-follow staging workflow.
    private var directTransferPlans: [UUID: DirectTransferPlan] = [:]
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
    /// Hard cap for one remote directory listing kept in memory. A million-row
    /// `/usr` (or similar) would otherwise pin the table, the tree, and any
    /// sync preview that copies `entries`.
    static let maxDirectoryEntries = 8_000
    /// Back/forward stacks are cheap strings, but a long click-around session
    /// should not keep an unbounded path history in RAM.
    private static let navigationStackLimit = 64
    /// Upper bound for the IN-APP editor. A multi-GB file would otherwise be
    /// slurped fully into RAM (Data + several String copies + TextEditor) and
    /// hang/OOM. The external-editor path streams to disk, so it has no cap.
    static let maxInAppEditBytes: UInt64 = 8 * 1024 * 1024

    init(
        destination: String,
        controlSocketPath: String,
        port: Int,
        readiness: SocketReadiness,
        pathHistory: PathHistoryStore? = nil
    ) {
        self.exec = RemoteExec(
            destination: destination,
            controlSocketPath: controlSocketPath,
            port: port
        )
        self.readiness = readiness
        self.pathHistory = pathHistory ?? PathHistoryStore.forHost(destination: destination, port: port)
    }

    /// Recent remote paths, newest first, for the path bar's recall menu. The
    /// consecutive-dupe collapse in `PathHistory` already keeps refreshes and
    /// the current directory from flooding the list.
    func recentPaths(_ count: Int) -> [String] {
        pathHistory.history.recent(count)
    }

    /// User-facing actions (nav, transfer, listing refresh) may fire whenever
    /// the mux is ready — a running delete/rename/extract no longer locks the
    /// whole panel.
    var canInteract: Bool { status == .ready }

    /// Destructive/structural mutations stay mutually exclusive: only one
    /// delete/rename/mkdir/extract/chmod in flight at a time.
    var canMutate: Bool { status == .ready && !isMutating }

    // MARK: - Lifecycle (driven by the session state)

    /// Called when the session reaches `.running` (and from the 重试 button):
    /// verifies the mux socket, probes the OS and `$HOME`, then lists the
    /// current directory. Keeps `cwd` across reconnects.
    func start() {
        guard !exec.destination.isEmpty else { return }
        // Idempotent: UserDefaults / tab refresh must not tear down a live listing.
        switch status {
        case .preparing, .ready:
            return
        case .idle, .unsupported:
            break
        }
        prepareTask?.cancel()
        status = .preparing
        errorMessage = nil
        consecutiveListTimeouts = 0
        prepareTask = Task { [weak self] in
            await self?.prepare()
        }
    }

    /// Called when the session exits. Cancels every in-flight task and timer so
    /// nothing keeps polling/uploading over the now-dead ControlMaster socket.
    func stop() {
        guard status != .idle || prepareTask != nil || !entries.isEmpty || !transfers.isEmpty else {
            return
        }
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
        // Stop external-editor sync and drop their on-disk / in-memory
        // buffers immediately. Over a dead socket uploads only fail.
        let sessions = editSessions
        editSessions.removeAll()
        for session in sessions { session.cancel(dropBuffers: true) }
        directorySyncPreview = nil
        isComparingDirectory = false
        listingTruncated = false
        clearPendingUpload()
        entries = []
        backStack.removeAll()
        forwardStack.removeAll()
        canGoBack = false
        canGoForward = false
        // Finished rows (and any leftover retry plans) must die with stop().
        // Cancelled in-flight rows are marked cancelled first so they qualify.
        for index in transfers.indices where transfers[index].state == .running {
            transfers[index].state = .cancelled
        }
        clearFinishedTransfers()
        directTransferPlans.removeAll()
        listGeneration += 1
        isLoading = false
        isMutating = false
        status = .idle
    }

    isolated deinit {
        prepareTask?.cancel()
        directorySyncTask?.cancel()
        mutationTask?.cancel()
        for task in transferTasks.values { task.cancel() }
        for timer in progressPollers.values { timer.invalidate() }
        for task in remoteProgressTasks.values { task.cancel() }
        let sessions = editSessions
        if !sessions.isEmpty {
            DispatchQueue.main.async {
                for session in sessions { session.cancel(dropBuffers: true) }
            }
        }
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
        guard canInteract else { return }
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
        guard canInteract else { return }
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
        guard canInteract else { return }
        Task { await performList(path: RemotePath.join(cwd, entry.name), step: .push) }
    }

    func goUp() {
        guard canInteract, cwd != "/" else { return }
        Task { await performList(path: RemotePath.parent(of: cwd), step: .push) }
    }

    func goBack() {
        guard canInteract, let target = backStack.last else { return }
        Task { await performList(path: target, step: .back) }
    }

    func goForward() {
        guard canInteract, let target = forwardStack.last else { return }
        Task { await performList(path: target, step: .forward) }
    }

    func absolutePath(of entry: RemoteFileEntry) -> String {
        RemotePath.join(cwd, entry.name)
    }

    /// Drives navigation from the directory tree: lists `path` and records it
    /// in history exactly like a typed path. No-op when not ready.
    func navigate(toPath path: String) {
        guard canInteract else { return }
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
            let names = RemoteLsParser.parse(String(decoding: stdout, as: UTF8.self))
                .filter { $0.isDirectory && !$0.isSymlink }
                .filter { includeHidden || !$0.isHidden }
                .map(\.name)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if names.count > FileService.maxDirectoryEntries {
                return Array(names.prefix(FileService.maxDirectoryEntries))
            }
            return names
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
                consecutiveListTimeouts += 1
                // A single slow `find` must not kill the whole panel. Only a
                // repeated timeout looks like a dead mux.
                if consecutiveListTimeouts >= 3 {
                    consecutiveListTimeouts = 0
                    readiness.reset()
                    if case .ready = status { status = .idle }
                    start()
                }
            } else {
                consecutiveListTimeouts = 0
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
        let truncated = parsedEntries.count > Self.maxDirectoryEntries
        listingTruncated = truncated
        switch step {
        case .stay:
            break
        case .push:
            if target != cwd {
                backStack.append(cwd)
                trimNavigationStacks()
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
        entries = truncated
            ? Array(parsedEntries.prefix(Self.maxDirectoryEntries))
            : parsedEntries
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
        guard canInteract, !items.isEmpty else { return }
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
            enqueueDirectDownload(
                filename: entry.name,
                remote: absolutePath(of: entry),
                localDirectory: downloads,
                recursive: entry.isDirectory,
                totalBytes: entry.isDirectory ? 0 : Int64(entry.sizeBytes)
            )
        }
    }

    /// Uploads local files (or folders, recursively) into the current
    /// directory. Refreshes the listing after each completed upload.
    ///
    /// Names that already exist in the current remote listing are NOT silently
    /// overwritten: the upload is parked in `pendingUploadConflicts` and the UI
    /// must confirm 覆盖/跳过/取消 before anything is enqueued.
    func upload(urls: [URL]) {
        guard canInteract, !urls.isEmpty else { return }
        let existing = Set(entries.map(\.name))
        let conflicts = urls.filter(\.isFileURL)
            .map(\.lastPathComponent)
            .filter { existing.contains($0) }
        guard conflicts.isEmpty else {
            pendingUploadURLs = urls.filter(\.isFileURL)
            pendingUploadConflicts = conflicts
            return
        }
        beginUpload(urls.filter(\.isFileURL))
    }

    /// Names in the parked upload that would overwrite existing remote entries.
    @Published private(set) var pendingUploadConflicts: [String] = []
    private var pendingUploadURLs: [URL] = []

    /// 覆盖: proceed with the parked upload, replacing conflicting destinations.
    func confirmOverwriteUpload() {
        let urls = pendingUploadURLs
        clearPendingUpload()
        beginUpload(urls)
    }

    /// 跳过: upload only the parked items that don't collide.
    func confirmSkipConflictsUpload() {
        let conflicts = Set(pendingUploadConflicts)
        let urls = pendingUploadURLs.filter { !conflicts.contains($0.lastPathComponent) }
        clearPendingUpload()
        guard !urls.isEmpty else { return }
        beginUpload(urls)
    }

    /// 取消: drop the parked upload entirely.
    func cancelPendingUpload() {
        clearPendingUpload()
    }

    private func clearPendingUpload() {
        pendingUploadURLs = []
        pendingUploadConflicts = []
    }

    private func beginUpload(_ urls: [URL]) {
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            // Folders go through tar+gzip when enabled; regular files keep the
            // direct sftp put, now with live progress from a remote stat poll.
            if isDirectory, packagedTransferEnabled {
                enqueuePackagedUpload(localURL: url)
                continue
            }
            let total = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let remote = RemotePath.join(cwd, url.lastPathComponent)
            enqueueDirectUpload(
                filename: url.lastPathComponent,
                localURL: url,
                remote: remote,
                recursive: isDirectory,
                totalBytes: total
            )
        }
    }

    // MARK: - Safe directory sync preview

    /// Compares the selected local folder with the CURRENT remote directory on
    /// a background task. This is dry-run only: no remote mutation happens
    /// until `applyDirectorySyncPreview()` is explicitly invoked by the sheet.
    func compareDirectory(_ localDirectory: URL) {
        guard canInteract else { return }
        directorySyncTask?.cancel()
        let remoteDirectory = cwd
        let remoteEntries = entries
        isComparingDirectory = true
        directorySyncPreview = nil
        directorySyncTask = Task { [weak self] in
            let wasTruncated = self?.listingTruncated ?? false
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try DirectorySyncPlanner.makePreview(
                        localDirectory: localDirectory,
                        remoteDirectory: remoteDirectory,
                        remoteEntries: remoteEntries,
                        remoteListingTruncated: wasTruncated
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
        guard canInteract, cwd == preview.remoteDirectory else {
            errorMessage = L("远程目录已变更，请重新对比后再同步。")
            directorySyncPreview = nil
            return
        }
        directorySyncPreview = nil
        upload(urls: preview.uploadURLs)
    }

    /// Downloads each item into a custom local directory (instead of ~/Downloads),
    /// for the dual-pane "下载到 Mac" action that targets the local pane's cwd.
    /// Name collisions get a "-2", "-3"… suffix locally.
    func download(into localDir: URL, items: [RemoteFileEntry]) {
        guard canInteract, !items.isEmpty else { return }
        for entry in items {
            if entry.isDirectory, !entry.isSymlink, packagedTransferEnabled {
                enqueuePackagedDownload(entry, into: localDir)
                continue
            }
            enqueueDirectDownload(
                filename: entry.name,
                remote: absolutePath(of: entry),
                localDirectory: localDir,
                recursive: entry.isDirectory,
                totalBytes: entry.isDirectory ? 0 : Int64(entry.sizeBytes)
            )
        }
    }

    func clearFinishedTransfers() {
        let finishedIDs = transfers
            .filter { $0.state != .running }
            .map(\.id)
        transfers.removeAll { $0.state != .running }
        for id in finishedIDs { directTransferPlans.removeValue(forKey: id) }
    }

    /// Downloads `entry` to a temp copy, opens it in the default editor, and
    /// auto-uploads it back on every save (see `RemoteEditSession`).
    func beginEdit(_ entry: RemoteFileEntry) {
        guard canInteract, !entry.isDirectory else { return }
        guard !entry.isSymlink else {
            errorMessage = RemoteEditFailure.symlink.message
            return
        }
        let remotePath = absolutePath(of: entry)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-edit-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            os_log(.error, "Failed to create temp edit directory at %{public}@: %{public}@", tempDir.path, error.localizedDescription)
        }
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
            let batch: String
            do {
                batch = try SFTPBatch.get(remote: remotePath, local: localURL.path)
            } catch {
                self?.transferTasks.removeValue(forKey: transferID)
                self?.failTransfer(transferID, error.localizedDescription)
                try? FileManager.default.removeItem(at: tempDir)
                return
            }
            let result = await exec.runSFTPBatch(
                batch,
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
        let batch: String
        do {
            batch = try SFTPBatch.get(remote: remotePath, local: tempURL.path)
        } catch {
            return .failure(EditError(message: error.localizedDescription))
        }
        let result = await exec.runSFTPBatch(
            batch,
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

    private func enqueueDirectDownload(
        filename: String,
        remote: String,
        localDirectory: URL,
        recursive: Bool,
        totalBytes: Int64
    ) {
        do {
            try SFTPBatch.validatePath(remote)
            try SFTPBatch.validatePath(localDirectory.path)
            _ = try LocalTransferStaging.validatedInstallName(filename)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        var transfer = Transfer(filename: filename, direction: .download)
        transfer.total = totalBytes
        transfer.retryable = true
        let id = transfer.id
        let plan = DirectTransferPlan.download(
            remote: remote,
            localDirectory: localDirectory,
            filename: filename,
            recursive: recursive
        )
        transfers.append(transfer)
        directTransferPlans[id] = plan
        trimTransfers()
        scheduleDirectTransfer(id: id, plan: plan)
    }

    private func enqueueDirectUpload(
        filename: String,
        localURL: URL,
        remote: String,
        recursive: Bool,
        totalBytes: Int64
    ) {
        do {
            try SFTPBatch.validatePath(localURL.path)
            try SFTPBatch.validatePath(remote)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        var transfer = Transfer(filename: filename, direction: .upload)
        transfer.total = totalBytes
        transfer.retryable = true
        let id = transfer.id
        let plan = DirectTransferPlan.upload(
            localURL: localURL,
            remote: remote,
            recursive: recursive
        )
        transfers.append(transfer)
        directTransferPlans[id] = plan
        trimTransfers()
        scheduleDirectTransfer(id: id, plan: plan)
    }

    /// Runs a staged no-follow direct transfer in the shared serial queue. A
    /// retry reconstructs fresh staging paths, so failed artifacts can never be
    /// reused or followed.
    private func scheduleDirectTransfer(id: UUID, plan: DirectTransferPlan) {
        let previous = transferChain
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            guard !Task.isCancelled else {
                self.failIfStillRunning(id)
                self.transferTasks.removeValue(forKey: id)
                return
            }
            switch plan {
            case let .download(remote, localDirectory, filename, recursive):
                await self.runDirectDownload(
                    id: id,
                    remote: remote,
                    localDirectory: localDirectory,
                    filename: filename,
                    recursive: recursive,
                    exec: self.exec
                )
            case let .upload(localURL, remote, recursive):
                await self.runDirectUpload(
                    id: id,
                    localURL: localURL,
                    remote: remote,
                    recursive: recursive,
                    exec: self.exec
                )
            }
            self.transferTasks.removeValue(forKey: id)
        }
        transferChain = task
        transferTasks[id] = task
    }

    /// Pull into a fresh 0700 sibling directory first, then atomically install
    /// it with `RENAME_EXCL`. This prevents sftp from opening a visible local
    /// destination that could be a live or dangling symlink.
    private func runDirectDownload(
        id: UUID,
        remote: String,
        localDirectory: URL,
        filename: String,
        recursive: Bool,
        exec: RemoteExec
    ) async {
        defer { failIfStillRunning(id) }
        let staging: URL
        do {
            staging = try LocalTransferStaging.createPrivateDirectory(in: localDirectory, label: "download")
        } catch {
            failTransfer(id, error.localizedDescription)
            return
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        let stagedLocal = staging.appendingPathComponent("payload", isDirectory: recursive)
        let batch: String
        do {
            batch = try SFTPBatch.get(remote: remote, local: stagedLocal.path, recursive: recursive)
        } catch {
            failTransfer(id, error.localizedDescription)
            return
        }

        if !recursive { startProgressPoll(transferID: id, localURL: stagedLocal) }
        let result = await exec.runSFTPBatch(batch, timeout: Self.transferTimeout)
        stopProgressPoll(transferID: id)
        guard !Task.isCancelled else { return }
        guard !result.timedOut, result.exitCode == 0,
              LocalTransferStaging.entryExists(at: stagedLocal) else {
            failTransfer(id, Self.failureText(result))
            return
        }

        do {
            _ = try LocalTransferStaging.moveStagedItem(
                at: stagedLocal,
                named: filename,
                into: localDirectory
            )
        } catch {
            failTransfer(id, error.localizedDescription)
            return
        }
        doneTransfer(id)
    }

    /// Push into a fresh private sibling directory, then promote with a
    /// same-directory rename. The promotion refuses an existing symlink and
    /// `mv -T` never traverses one if it appears in the final race window.
    private func runDirectUpload(
        id: UUID,
        localURL: URL,
        remote: String,
        recursive: Bool,
        exec: RemoteExec
    ) async {
        defer { failIfStillRunning(id) }
        let remoteStage = Self.remoteStagingArea(
            in: RemotePath.parent(of: remote),
            label: "upload"
        )
        defer { cleanupRemoteStaging(remoteStage, using: exec) }

        let setup = await createRemotePrivateDirectory(remoteStage.directory, using: exec)
        guard !Task.isCancelled else { return }
        guard !setup.timedOut, setup.exitCode == 0 else {
            failTransfer(id, Self.failureText(setup))
            return
        }

        let stagedRemote = RemotePath.join(remoteStage.directory, "payload")
        let batch: String
        do {
            batch = try SFTPBatch.put(local: localURL.path, remote: stagedRemote, recursive: recursive)
        } catch {
            failTransfer(id, error.localizedDescription)
            return
        }
        if !recursive { startRemoteProgressPoll(transferID: id, remotePath: stagedRemote) }
        let put = await exec.runSFTPBatch(batch, timeout: Self.transferTimeout)
        stopProgressPoll(transferID: id)
        guard !Task.isCancelled else { return }
        guard !put.timedOut, put.exitCode == 0 else {
            failTransfer(id, Self.failureText(put))
            return
        }

        let promote = await exec.run(
            "if [ -L \(sq(remote)) ]; then "
                + "printf '%s\\n' 'Refusing to replace a symbolic-link destination' >&2; exit 1; fi; "
                + "mv -fT -- \(sq(stagedRemote)) \(sq(remote))",
            timeout: Self.transferTimeout
        )
        guard !Task.isCancelled else { return }
        guard !promote.timedOut, promote.exitCode == 0 else {
            failTransfer(id, Self.failureText(promote))
            return
        }
        doneTransfer(id, refreshAfter: true)
    }

    /// Re-runs a failed direct transfer under a fresh queue slot. Its original
    /// visible destination is never reused as an sftp target.
    func retryTransfer(_ id: UUID) {
        guard canInteract,
              let index = transfers.firstIndex(where: { $0.id == id }),
              transfers[index].isRetryable,
              let plan = directTransferPlans[id] else { return }
        transfers[index].state = .running
        transfers[index].transferred = 0
        transfers[index].bytesPerSecond = 0
        scheduleDirectTransfer(id: id, plan: plan)
    }

    /// Cancels one in-flight transfer: kills its sftp child (AuxProcess's
    /// cancellation handler SIGTERMs it), stops its progress poll, and marks
    /// the row distinctly cancelled. Queued rows behind the chain tail simply
    /// never start.
    func cancelTransfer(id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }),
              transfers[index].state == .running else { return }
        stopProgressPoll(transferID: id)
        transferTasks[id]?.cancel()
        transferTasks.removeValue(forKey: id)
        directTransferPlans.removeValue(forKey: id)
        transfers[index].state = .cancelled
        transfers[index].transferred = 0
        transfers[index].bytesPerSecond = 0
    }

    // MARK: - Packaged (tar+gzip) folder transfers

    /// macOS bundles bsdtar here; it reads/writes gzip via the `z` flag.
    private static let localTar = "/usr/bin/tar"

    /// A remote staging directory and its private archive. The random directory
    /// is created with 0700 before use; the archive is then explicitly chmod'ed
    /// to 0600. Keeping the archive inside that directory also closes the small
    /// permission window while sftp creates a remote upload.
    private struct RemoteStagingArea {
        let directory: String
        let archive: String
    }

    private static func remoteStagingArea(in parent: String, label: String) -> RemoteStagingArea {
        let directory = RemotePath.join(parent, ".harbor-\(label)-\(UUID().uuidString)")
        return RemoteStagingArea(
            directory: directory,
            archive: RemotePath.join(directory, "archive.tar.gz")
        )
    }

    /// The app only supports Linux file panels, so GNU `mkdir`/`chmod` are an
    /// explicit part of this contract. `mkdir` is atomic and fails if the UUID
    /// path already exists; the final symlink check makes that failure safe.
    private func createRemotePrivateDirectory(
        _ directory: String,
        using exec: RemoteExec
    ) async -> AuxProcess.Output {
        await exec.run(
            "umask 077 && mkdir -m 700 -- \(sq(directory))"
                + " && chmod 700 -- \(sq(directory))"
                + " && [ -d \(sq(directory)) ] && [ ! -L \(sq(directory)) ]",
            timeout: Self.mutationTimeout
        )
    }

    /// Detached cleanup survives `stop()` cancellation, when a child transfer
    /// has already created remote staging but the parent task may no longer run.
    private func cleanupRemoteStaging(_ staging: RemoteStagingArea, using exec: RemoteExec) {
        Task.detached {
            _ = await exec.run("rm -rf -- \(sq(staging.directory))", timeout: 15)
        }
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
        let remoteStage = Self.remoteStagingArea(in: "/tmp", label: "xfer")
        let remoteTgz = remoteStage.archive
        let staging: URL
        do {
            // Stage INSIDE Downloads so the final no-replace rename stays on the
            // same volume even when ~/Downloads is redirected.
            staging = try LocalTransferStaging.createPrivateDirectory(in: downloads, label: "archive")
        } catch {
            failTransfer(id, error.localizedDescription)
            return
        }
        // Keep the downloaded archive inside the same private directory too:
        // sftp never opens a visible local destination, and the dot-prefix
        // keeps it out of the extracted top-level entry selection below.
        let localTgz = staging.appendingPathComponent(".archive.tar.gz")
        func cleanupLocal() {
            try? FileManager.default.removeItem(at: staging)
        }
        defer {
            cleanupRemoteStaging(remoteStage, using: exec)
            cleanupLocal()
            failIfStillRunning(id)
        }

        // 1. Pack in a private remote directory (`--` guards a name starting
        // with "-"). The archive mode is explicit, never inherited from the
        // remote account's umask.
        let setup = await createRemotePrivateDirectory(remoteStage.directory, using: exec)
        guard !Task.isCancelled else { return }
        guard !setup.timedOut, setup.exitCode == 0 else {
            failTransfer(id, Self.failureText(setup)); return
        }
        let pack = await exec.run(
            "umask 077 && tar czf \(sq(remoteTgz)) -C \(sq(parent)) -- \(sq(name))"
                + " && [ ! -L \(sq(remoteTgz)) ] && chmod 600 -- \(sq(remoteTgz))",
            timeout: Self.transferTimeout)
        guard !Task.isCancelled else { return }
        guard !pack.timedOut, pack.exitCode == 0 else {
            failTransfer(id, Self.failureText(pack)); return
        }

        // 2. Pull the single archive (progress from its growing local size).
        startProgressPoll(transferID: id, localURL: localTgz)
        let getBatch: String
        do {
            getBatch = try SFTPBatch.get(remote: remoteTgz, local: localTgz.path)
        } catch {
            stopProgressPoll(transferID: id)
            failTransfer(id, error.localizedDescription); return
        }
        let get = await exec.runSFTPBatch(getBatch, timeout: Self.transferTimeout)
        stopProgressPoll(transferID: id)
        guard !Task.isCancelled else { return }
        guard !get.timedOut, get.exitCode == 0 else {
            failTransfer(id, Self.failureText(get)); return
        }

        // 3. Validate archive members (reject path traversal / absolute paths),
        //    extract into staging, re-check containment, then move the top entry
        //    into Downloads with the usual "-2" collision suffix.
        if let slip = await Self.archivePathSlipReason(tar: Self.localTar, archive: localTgz) {
            failTransfer(id, slip); return
        }
        let extract = await AuxProcess.run(
            argv: [Self.localTar, "xzf", localTgz.path, "-C", staging.path],
            timeout: Self.transferTimeout)
        guard extract.exitCode == 0 else {
            failTransfer(id, L("解压下载的压缩包失败")); return
        }
        if let escape = Self.pathEscapeReason(under: staging) {
            failTransfer(id, escape); return
        }
        // Move the ACTUAL single top-level entry (normally `name`, but don't
        // assume — some tar configs store members differently).
        let items = (try? FileManager.default.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: nil)) ?? []
        // Ignore the staging dir's own AppleDouble / hidden noise if any.
        let visible = items.filter { !$0.lastPathComponent.hasPrefix(".") || $0.lastPathComponent == name }
        guard let source = visible.first(where: { $0.lastPathComponent == name }) ?? visible.first else {
            failTransfer(id, L("解压下载的压缩包失败")); return
        }
        do {
            _ = try LocalTransferStaging.moveStagedItem(
                at: source,
                named: source.lastPathComponent,
                into: downloads
            )
        } catch {
            failTransfer(id, error.localizedDescription); return
        }
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
        let localTgz = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-ul-\(UUID().uuidString).tar.gz")
        let remoteStage = Self.remoteStagingArea(in: "/tmp", label: "xfer")
        let remoteTgz = remoteStage.archive
        func cleanupLocal() { try? FileManager.default.removeItem(at: localTgz) }
        defer {
            cleanupRemoteStaging(remoteStage, using: exec)
            cleanupLocal()
            failIfStillRunning(id)
        }

        // 1. Pack locally (child process, no shell — `--` guards the name).
        let pack = await AuxProcess.run(
            argv: [Self.localTar, "czf", localTgz.path, "-C", localParent, "--", name],
            timeout: Self.transferTimeout)
        guard pack.exitCode == 0 else {
            failTransfer(id, L("打包待上传的文件夹失败")); return
        }
        guard !Task.isCancelled else { return }
        // `put -p` preserves the local archive's mode when the server supports
        // it. Set this before upload, then reassert 0600 remotely below.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: localTgz.path
        )
        // Total is now known: the compressed archive size.
        let attrs = try? FileManager.default.attributesOfItem(atPath: localTgz.path)
        setTotal(id, (attrs?[.size] as? NSNumber)?.int64Value ?? 0)

        // 2. Create a remote 0700 staging directory, then push the archive
        // into it. This keeps the archive private even before the explicit
        // chmod below completes.
        let setup = await createRemotePrivateDirectory(remoteStage.directory, using: exec)
        guard !Task.isCancelled else { return }
        guard !setup.timedOut, setup.exitCode == 0 else {
            failTransfer(id, Self.failureText(setup)); return
        }
        startRemoteProgressPoll(transferID: id, remotePath: remoteTgz)
        let putBatch: String
        do {
            putBatch = try SFTPBatch.put(local: localTgz.path, remote: remoteTgz)
        } catch {
            stopProgressPoll(transferID: id)
            failTransfer(id, error.localizedDescription); return
        }
        let put = await exec.runSFTPBatch(putBatch, timeout: Self.transferTimeout)
        stopProgressPoll(transferID: id)
        guard !Task.isCancelled else { return }
        guard !put.timedOut, put.exitCode == 0 else {
            failTransfer(id, Self.failureText(put)); return
        }
        let secureArchive = await exec.run(
            "[ ! -L \(sq(remoteTgz)) ] && chmod 600 -- \(sq(remoteTgz))",
            timeout: Self.mutationTimeout
        )
        guard !Task.isCancelled else { return }
        guard !secureArchive.timedOut, secureArchive.exitCode == 0 else {
            failTransfer(id, Self.failureText(secureArchive)); return
        }

        // 3. Extract on the remote into the destination dir, then drop the archive.
        let extract = await exec.run(
            "mkdir -p \(sq(destDir)) && tar xzf \(sq(remoteTgz)) -C \(sq(destDir))",
            timeout: Self.transferTimeout)
        guard !extract.timedOut, extract.exitCode == 0 else {
            failTransfer(id, Self.failureText(extract)); return
        }
        doneTransfer(id, refreshAfter: true)
    }

    private func failTransfer(_ id: UUID, _ reason: String) {
        if let i = transfers.firstIndex(where: { $0.id == id }) {
            transfers[i].state = .failed(reason)
            if !transfers[i].isRetryable {
                directTransferPlans.removeValue(forKey: id)
            }
        }
        trimTransfers()
    }

    /// Marks a row cancelled only if it's still .running — the `defer`
    /// backstop for packaged transfers so a cancelled/torn-down one resolves
    /// instead of spinning forever. A row already .done/.failed is left as-is.
    private func failIfStillRunning(_ id: UUID) {
        if let i = transfers.firstIndex(where: { $0.id == id }), transfers[i].state == .running {
            transfers[i].state = .cancelled
            if !transfers[i].isRetryable {
                directTransferPlans.removeValue(forKey: id)
            }
        }
        trimTransfers()
    }

    private func doneTransfer(_ id: UUID, refreshAfter: Bool = false) {
        if let i = transfers.firstIndex(where: { $0.id == id }) {
            transfers[i].state = .done
        }
        // Done rows cannot be retried — drop the staged plan immediately.
        directTransferPlans.removeValue(forKey: id)
        trimTransfers()
        if refreshAfter, canInteract { refresh() }
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
            let failed = result.timedOut || result.exitCode != 0
            transfers[index].state = failed
                ? .failed(Self.failureText(result))
                : .done
            if !transfers[index].isRetryable {
                directTransferPlans.removeValue(forKey: id)
            }
        }
        trimTransfers()
        if refreshAfter, canInteract {
            refresh()
        }
    }

    private func trimNavigationStacks() {
        if backStack.count > Self.navigationStackLimit {
            backStack.removeFirst(backStack.count - Self.navigationStackLimit)
        }
        if forwardStack.count > Self.navigationStackLimit {
            forwardStack.removeFirst(forwardStack.count - Self.navigationStackLimit)
        }
    }

    /// Drops the oldest finished transfers beyond the history cap.
    private func trimTransfers() {
        while transfers.count > Self.transferHistoryLimit,
              let index = transfers.firstIndex(where: { $0.state != .running }) {
            let removed = transfers.remove(at: index)
            directTransferPlans.removeValue(forKey: removed.id)
        }
    }

    /// Lists archive members with `tar tzf` and rejects absolute paths or any
    /// `..` component before extraction (classic tar slip).
    private static func archivePathSlipReason(tar: String, archive: URL) async -> String? {
        let listed = await AuxProcess.run(
            argv: [tar, "tzf", archive.path],
            timeout: transferTimeout
        )
        guard listed.exitCode == 0 else {
            return L("解压下载的压缩包失败")
        }
        let members = String(data: listed.stdout, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .map(String.init) ?? []
        for member in members where !member.isEmpty {
            if member.hasPrefix("/") || member.hasPrefix("\\") {
                return L("压缩包包含不安全路径，已拒绝解压")
            }
            // Windows-style drive paths or URL-like members.
            if member.count >= 2, member[member.index(member.startIndex, offsetBy: 1)] == ":" {
                return L("压缩包包含不安全路径，已拒绝解压")
            }
            let parts = member.split(separator: "/")
            if parts.contains("..") {
                return L("压缩包包含不安全路径，已拒绝解压")
            }
        }
        return nil
    }

    /// After extract, confirm every entry under `root` resolves inside `root`.
    /// Defense in depth if the local tar still wrote a link/escape.
    private static func pathEscapeReason(under root: URL) -> String? {
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return nil }
        while let item = enumerator.nextObject() as? URL {
            let resolved = item.standardizedFileURL.resolvingSymlinksInPath().path
            if resolved == rootPath { continue }
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            if !resolved.hasPrefix(prefix) {
                return L("压缩包解压后写到了目标目录之外，已拒绝")
            }
        }
        return nil
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
        guard canMutate, !items.isEmpty else { return }
        let names = Set(items.map(\.name))
        let cwdAtDelete = cwd
        let script = "rm -rf -- " + items
            .map { sq(absolutePath(of: $0)) }
            .joined(separator: " ")
        // Remove now — no spinner, no waiting on the network.
        entries.removeAll { names.contains($0.name) }
        let exec = self.exec
        isMutating = true
        // Wait for any in-flight rename/mkdir to finish before issuing the
        // delete; cancelling it here would silently discard the user's prior
        // operation with no feedback.
        let prior = mutationTask
        mutationTask = Task { [weak self] in
            await prior?.value
            let result = await exec.run(script, timeout: Self.mutationTimeout)
            guard let self, !Task.isCancelled else { return }
            self.isMutating = false
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
        guard canMutate, !entry.isDirectory else { return }
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
                let stderr = result.stderrText
                if stderr.contains(ArchiveKind.unsafeMemberMarker) {
                    self.errorMessage = L("压缩包包含不安全路径，已拒绝解压")
                } else if let tool, stderr.lowercased().contains("not found") {
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
        guard canMutate, !trimmed.isEmpty, trimmed != entry.name,
              !trimmed.contains("/") else { return }
        // Block control/newline names that would desync sftp batch lines.
        guard (try? SFTPBatch.validatePath(trimmed)) != nil else {
            errorMessage = SFTPBatchError.unsafePath(trimmed).localizedDescription
            return
        }
        let batch: String
        do {
            batch = try SFTPBatch.rename(
                from: absolutePath(of: entry),
                to: RemotePath.join(cwd, trimmed)
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let exec = self.exec
        runMutation { await exec.runSFTPBatch(batch, timeout: Self.mutationTimeout) }
    }

    /// Moves (renames) an entry to an arbitrary remote path — the 移动到…
    /// action. Accepts `~`, absolute, and cwd-relative destinations, exactly
    /// like the path bar.
    func move(_ entry: RemoteFileEntry, to destination: String) {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        guard canMutate, !trimmed.isEmpty else { return }
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
        let target = RemotePath.normalize(absolute)
        guard target != absolutePath(of: entry) else { return }
        let batch: String
        do {
            batch = try SFTPBatch.rename(from: absolutePath(of: entry), to: target)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let exec = self.exec
        runMutation { await exec.runSFTPBatch(batch, timeout: Self.mutationTimeout) }
    }

    func createDirectory(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard canMutate, !trimmed.isEmpty, !trimmed.contains("/") else { return }
        guard (try? SFTPBatch.validatePath(trimmed)) != nil else {
            errorMessage = SFTPBatchError.unsafePath(trimmed).localizedDescription
            return
        }
        let batch: String
        do {
            batch = try SFTPBatch.mkdir(RemotePath.join(cwd, trimmed))
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let exec = self.exec
        runMutation { await exec.runSFTPBatch(batch, timeout: Self.mutationTimeout) }
    }

    /// `chmod <octal> <path>` over ssh. `octal` is a 3–4 digit mode string
    /// (validated by the caller's permission editor).
    func changePermissions(_ entry: RemoteFileEntry, octal: String) {
        guard canMutate,
              !entry.isSymlink,
              (3...4).contains(octal.count),
              octal.allSatisfy({ ("0"..."7").contains($0) })
        else { return }
        let path = sq(absolutePath(of: entry))
        // The listing can be stale or raced. The explicit check gives a clear
        // failure, while GNU chmod's no-dereference mode prevents a symlink
        // installed after the check from changing its referent.
        let script = "if [ -L \(path) ]; then "
            + "printf '%s\\n' 'Refusing to change permissions of a symbolic link' >&2; exit 1; fi; "
            + "chmod --no-dereference \(octal) -- \(path)"
        let exec = self.exec
        runMutation { await exec.run(script, timeout: Self.mutationTimeout) }
    }

    /// `chown owner:group <path>` over ssh.
    func changeOwner(_ entry: RemoteFileEntry, owner: String, group: String) {
        let trimmedOwner = owner.trimmingCharacters(in: .whitespaces)
        let trimmedGroup = group.trimmingCharacters(in: .whitespaces)
        guard canMutate,
              !entry.isSymlink,
              !trimmedOwner.isEmpty,
              !trimmedGroup.isEmpty
        else { return }
        let spec = sq("\(trimmedOwner):\(trimmedGroup)")
        let path = sq(absolutePath(of: entry))
        // As above, reject a listed symlink and retain no-follow behavior if
        // a path replacement races this request.
        let script = "if [ -L \(path) ]; then "
            + "printf '%s\\n' 'Refusing to change ownership of a symbolic link' >&2; exit 1; fi; "
            + "chown --no-dereference \(spec) -- \(path)"
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

    /// Cancels the running mutation (delete/rename/mkdir/extract/…) — AuxProcess
    /// SIGTERMs the remote child — then re-lists, since the operation may or may
    /// not have completed remotely.
    func cancelMutation() {
        guard mutationTask != nil else { return }
        mutationTask?.cancel()
        mutationTask = nil
        isMutating = false
        if status == .ready {
            Task { await performList(path: cwd, step: .stay) }
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
