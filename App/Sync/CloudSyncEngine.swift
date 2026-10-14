import Foundation
import AppKit
import Combine
import HarborKit

/// Folder-sync engine. Stores self-register via `JSONFileStore.init` (the base
/// class calls `register(_:)` when the subclass declares a `syncCollectionID`);
/// the engine then owns the whole lifecycle: debounced push on local edits,
/// directory-watch pull on external changes, and the read-merge-write cycle
/// that converges every device on one envelope.
///
/// The local stores stay the source of truth. A pull lands via
/// `applyRemote(_:)`, which never fires `onItemsChanged`, so a remote change
/// cannot echo back as a push.
@MainActor
final class CloudSyncEngine: ObservableObject {
    static let shared = CloudSyncEngine()

    enum Status: Equatable {
        case disabled
        /// Sync is on but no usable directory (iCloud Drive missing, custom
        /// directory gone, or it cannot be created).
        case unavailable
        case idle
        case syncing
        case error(String)
        /// The file was written by a newer Harbor: merge-read only, never write.
        case readOnlyNewerVersion
    }

    @Published private(set) var status: Status = .disabled
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var deviceCount = 0

    private let foldersSync = CollectionSync<HostFolder>(collectionID: .folders)
    private let hostsSync = CollectionSync<SSHHost>(collectionID: .hosts)
    private let commandsSync = CollectionSync<QuickCommand>(collectionID: .commands)
    private let scriptsSync = CollectionSync<ScriptSnippet>(collectionID: .scripts)
    private let workspacesSync = CollectionSync<Workspace>(collectionID: .workspaces)

    private let stateStore = SyncStateStore()
    private var state = SyncStateFile()
    private let watcher = SyncDirectoryWatcher()
    private var becomeActiveObserver: NSObjectProtocol?

    private var pushWorkItem: DispatchWorkItem?
    private var pullWorkItem: DispatchWorkItem?
    /// Hash of the last file bytes we wrote or read; a directory event whose
    /// file still matches this is our own write echoing back.
    private var lastSeenFileHash: String?
    private var isSyncing = false
    private var pendingCycle = false
    private var started = false
    /// Set by deleteRemoteData(): the file must not be recreated until the
    /// user makes a fresh local change.
    private var suppressPushUntilLocalChange = false

    private init() {
        // Folder array order is canonical; `order` mirrors the index.
        foldersSync.applyFixup = { items, _ in
            for index in items.indices where items[index].order != index {
                items[index].order = index
            }
        }
        // A host pointing at a folder the merge dropped falls back to root,
        // mirroring HostExportImport.merge.
        hostsSync.applyFixup = { items, ctx in
            guard let valid = ctx.validFolderIDs else { return }
            for index in items.indices {
                if let folderID = items[index].folderID, !valid.contains(folderID) {
                    items[index].folderID = nil
                }
            }
        }
        // Notes stripping affects only the file-bound copy; the stores and the
        // local state keep the real values, and the merger's carve-out keeps a
        // stripped winner from erasing them.
        hostsSync.filePayloadTransform = { host in
            if SyncSettings.stripHostNotes { host.notes = "" }
        }
        lastSyncAt = SyncSettings.lastSyncAt
    }

    // MARK: - Store registration (called from JSONFileStore.init)

    func register<Element: Identifiable & Codable & Sendable>(_ store: JSONFileStore<Element>) where Element.ID == UUID {
        guard let raw = store.syncCollectionID, let collection = SyncCollectionID(rawValue: raw) else { return }
        switch collection {
        case .hosts: attach(store, to: hostsSync)
        case .folders: attach(store, to: foldersSync)
        case .commands: attach(store, to: commandsSync)
        case .scripts: attach(store, to: scriptsSync)
        case .workspaces: attach(store, to: workspacesSync)
        }
        startIfNeeded()
    }

    private func attach<Element, Payload>(
        _ store: JSONFileStore<Element>,
        to slot: CollectionSync<Payload>
    ) where Element: Identifiable & Codable & Sendable,
            Payload: Identifiable & Codable & Sendable,
            Element.ID == UUID, Payload.ID == UUID {
        // The subclass declares its collection by id; a mismatched Element
        // simply fails the cast and the store stays unsynced.
        guard let typed = store as? JSONFileStore<Payload> else { return }
        // The first live store of a collection triggers a reconcile: stores
        // register one by one during launch (and when a window reopens), so
        // the startup cycle must not leave late collections behind.
        let isFirstLiveStore = !slot.hasLiveStore
        slot.attach(typed)
        typed.onItemsChanged = { [weak self] _ in
            guard let self else { return }
            self.suppressPushUntilLocalChange = false
            self.schedulePush()
        }
        if isFirstLiveStore {
            schedulePush(delay: 0.2)
        }
    }

    // MARK: - Lifecycle

    /// Idempotent: stores register as they come up during app launch, and the
    /// settings toggle re-enters via `reconfigure()`.
    func startIfNeeded() {
        guard SyncSettings.isEnabled, !started else { return }
        started = true
        state = stateStore.load()
        lastSeenFileHash = nil

        guard let directory = SyncSettings.effectiveDirectory else {
            status = .unavailable
            return
        }
        do {
            // Watching needs the directory to exist; creating the default
            // CloudDocs/Harbor folder is expected once sync is switched on.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            status = .unavailable
            return
        }
        _ = watcher.start(directory: directory) { [weak self] in
            Task { @MainActor in self?.schedulePull() }
        }
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.schedulePull() }
        }
        status = .idle
        runCycle()
    }

    /// Settings on/off or a new sync directory.
    func reconfigure() {
        stop()
        startIfNeeded()
    }

    /// Collection toggles / notes preference: no restart needed, just converge.
    func settingsChanged() {
        guard SyncSettings.isEnabled else { reconfigure(); return }
        startIfNeeded()
        schedulePush(delay: 0.5)
    }

    private func stop() {
        started = false
        watcher.stop()
        if let observer = becomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            becomeActiveObserver = nil
        }
        pushWorkItem?.cancel()
        pullWorkItem?.cancel()
        isSyncing = false
        pendingCycle = false
        status = .disabled
    }

    // MARK: - Triggers

    func syncNow() {
        schedulePush(delay: 0)
    }

    /// Local edits batch into one write after 3 quiet seconds.
    private func schedulePush(delay: TimeInterval = 3) {
        guard SyncSettings.isEnabled else { return }
        startIfNeeded()
        pushWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.runCycle() }
        pushWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// External file changes (another device landing through iCloud/Dropbox)
    /// settle quickly but still debounce: a sync service can rewrite the file
    /// in several rapid steps.
    private func schedulePull() {
        guard started, SyncSettings.isEnabled else { return }
        pullWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.runCycle() }
        pullWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    // MARK: - The read-merge-write cycle

    private func runCycle() {
        guard SyncSettings.isEnabled, started else { return }
        guard let directory = SyncSettings.effectiveDirectory else {
            status = .unavailable
            return
        }
        guard !isSyncing else {
            pendingCycle = true
            return
        }
        isSyncing = true
        status = .syncing
        let fileURL = SyncSettings.envelopeFileURL(in: directory)
        let previousHash = lastSeenFileHash

        Task.detached(priority: .utility) { [weak self] in
            let readResult: Result<Data?, Error>
            do {
                readResult = .success(try SyncFileIO.read(fileURL))
            } catch {
                readResult = .failure(error)
            }
            await self?.finishCycle(readResult: readResult, fileURL: fileURL, previousHash: previousHash)
        }
    }

    private func finishCycle(readResult: Result<Data?, Error>, fileURL: URL, previousHash: String?) {
        defer {
            isSyncing = false
            if pendingCycle {
                pendingCycle = false
                schedulePush(delay: 0.1)
            }
        }

        let data: Data?
        switch readResult {
        case .success(let read):
            data = read
        case .failure(let error):
            status = .error(error.localizedDescription)
            return
        }

        // Echo suppression: the directory watcher also fires for our own write.
        if let data, SyncFileIO.sha256Hex(of: data) == previousHash {
            status = .idle
            return
        }

        var remote: SyncEnvelopeFile?
        if let data {
            do {
                remote = try SyncEnvelopeCodec.decode(data)
                lastSeenFileHash = SyncFileIO.sha256Hex(of: data)
            } catch {
                // A corrupt envelope is never overwritten: local data is the
                // source of truth and the user can delete the file to resync.
                status = .error(L("同步文件无法解析，已暂停同步以免覆盖数据。文件：%@", fileURL.path))
                return
            }
        } else {
            lastSeenFileHash = nil
        }

        if let remote, remote.envelopeVersion > SyncEnvelopeFile.currentVersion {
            // Merge-read would still be safe, but writing a v1 file over a
            // newer format would silently drop fields — refuse to write.
            status = .readOnlyNewerVersion
        }

        var ctx = SyncCycleContext(
            now: Date(),
            deviceID: SyncSettings.deviceID,
            preserveNonEmptyNotes: SyncSettings.stripHostNotes,
            validFolderIDs: nil
        )

        // Folders merge first so hosts can validate folderID references
        // against the merged set.
        let foldersOutcome = drive(foldersSync, remote: remote?.folders, ctx: ctx)
        if let foldersOutcome {
            ctx.validFolderIDs = Set(foldersOutcome.sectionForFile.records.compactMap {
                $0.isTombstone ? nil : $0.id
            })
        }
        let hostsOutcome = drive(hostsSync, remote: remote?.hosts, ctx: ctx)
        let commandsOutcome = drive(commandsSync, remote: remote?.commands, ctx: ctx)
        let scriptsOutcome = drive(scriptsSync, remote: remote?.scripts, ctx: ctx)
        let workspacesOutcome = drive(workspacesSync, remote: remote?.workspaces, ctx: ctx)

        let droveAny = foldersOutcome != nil || hostsOutcome != nil || commandsOutcome != nil
            || scriptsOutcome != nil || workspacesOutcome != nil
        let needsWrite = [foldersOutcome?.needsWrite, hostsOutcome?.needsWrite, commandsOutcome?.needsWrite,
                          scriptsOutcome?.needsWrite, workspacesOutcome?.needsWrite].contains(true)

        let writePermitted = remote == nil || remote!.envelopeVersion <= SyncEnvelopeFile.currentVersion
        if needsWrite && writePermitted && droveAny && !suppressPushUntilLocalChange {
            var devices = remote?.devices ?? [:]
            devices[ctx.deviceID] = ctx.now
            devices = devices.filter { ctx.now.timeIntervalSince($0.value) <= SyncMerger.tombstoneHorizon }
            let envelope = SyncEnvelopeFile(
                writerDeviceID: ctx.deviceID,
                writtenAt: ctx.now,
                devices: devices,
                folders: foldersOutcome?.sectionForFile ?? remote?.folders,
                hosts: hostsOutcome?.sectionForFile ?? remote?.hosts,
                commands: commandsOutcome?.sectionForFile ?? remote?.commands,
                scripts: scriptsOutcome?.sectionForFile ?? remote?.scripts,
                workspaces: workspacesOutcome?.sectionForFile ?? remote?.workspaces
            )
            do {
                let encoded = try SyncEnvelopeCodec.encode(envelope)
                lastSeenFileHash = SyncFileIO.sha256Hex(of: encoded)
                deviceCount = devices.count
                Task.detached(priority: .utility) { [weak self] in
                    do {
                        try SyncFileIO.writeAtomic(encoded, to: fileURL)
                    } catch {
                        await self?.noteWriteFailure(error)
                    }
                }
            } catch {
                status = .error(error.localizedDescription)
                return
            }
        } else {
            deviceCount = remote?.devices.count ?? 0
        }

        // Persist the adopted state off the critical path.
        let snapshot = state
        let store = stateStore
        Task.detached(priority: .utility) {
            try? store.save(snapshot)
        }

        // Error and version-gate statuses set above survive; syncing settles.
        if status == .syncing { status = .idle }
        lastSyncAt = ctx.now
        SyncSettings.lastSyncAt = ctx.now
    }

    private func noteWriteFailure(_ error: Error) {
        status = .error(error.localizedDescription)
    }

    /// Runs one collection through reconcile → merge → land → state adoption.
    /// A collection is skipped (nil outcome) when the user disabled it or no
    /// live store exists (its window is closed) — an absent store must never
    /// read as "everything deleted".
    private func drive<Payload: Identifiable & Codable & Sendable>(
        _ slot: CollectionSync<Payload>,
        remote: SyncCollection<Payload>?,
        ctx: SyncCycleContext
    ) -> CollectionCycleOutcome<Payload>? where Payload.ID == UUID {
        guard SyncSettings.isCollectionEnabled(slot.collectionID), slot.hasLiveStore else { return nil }
        let collectionState = state.collections[slot.collectionID.rawValue] ?? CollectionSyncState()
        let (outcome, newState) = slot.syncCycle(remote: remote, state: collectionState, ctx: ctx)
        state.collections[slot.collectionID.rawValue] = newState
        return outcome
    }

    // MARK: - Destructive

    /// Deletes the envelope file. While sync stays enabled the file would be
    /// recreated by the next cycle, so suppression holds until the next local
    /// edit — the settings copy says exactly that.
    func deleteRemoteData() {
        guard let directory = SyncSettings.effectiveDirectory else { return }
        let fileURL = SyncSettings.envelopeFileURL(in: directory)
        suppressPushUntilLocalChange = true
        lastSeenFileHash = nil
        deviceCount = 0
        Task.detached(priority: .utility) {
            try? SyncFileIO.delete(fileURL)
        }
    }
}
