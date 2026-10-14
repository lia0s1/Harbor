import Foundation

/// Collection identifiers shared by the stores (via `syncCollectionID`), the
/// envelope file sections, and the per-collection settings toggles.
enum SyncCollectionID: String, CaseIterable, Sendable {
    case folders
    case hosts
    case commands
    case scripts
    case workspaces
}

/// UserDefaults-backed sync preferences. Read live (not cached) so the
/// settings UI and the engine never disagree about the current value.
enum SyncSettings {
    static let enabledKey = "harbor.sync.enabled"
    static let directoryKey = "harbor.sync.directory"
    static let stripHostNotesKey = "harbor.sync.stripHostNotes"
    static let deviceIDKey = "harbor.sync.deviceID"
    static let lastSyncKey = "harbor.sync.lastSyncAt"

    static func collectionKey(_ id: SyncCollectionID) -> String {
        "harbor.sync.coll.\(id.rawValue)"
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Per-collection toggle; defaults to ON (sync everything) when unset.
    static func isCollectionEnabled(_ id: SyncCollectionID) -> Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: collectionKey(id)) as? Bool ?? true
    }

    /// Notes stripping defaults to ON: host notes stay on this machine unless
    /// the user explicitly opts into syncing them.
    static var stripHostNotes: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: stripHostNotesKey) as? Bool ?? true
    }

    /// Stable per-install writer identity used for LWW tiebreaks.
    static var deviceID: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceIDKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: deviceIDKey)
        return fresh
    }

    static var lastSyncAt: Date? {
        get { UserDefaults.standard.object(forKey: lastSyncKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastSyncKey) }
    }

    // MARK: - Sync directory

    /// The default sync directory inside iCloud Drive's user-visible area.
    /// Harbor is not sandboxed, so it can read/write CloudDocs directly
    /// without any iCloud entitlement.
    nonisolated static var iCloudDriveRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    nonisolated static var defaultDirectory: URL {
        iCloudDriveRoot.appendingPathComponent("Harbor", isDirectory: true)
    }

    /// False when iCloud Drive has never been set up on this Mac (the
    /// CloudDocs root simply does not exist).
    nonisolated static var iCloudDriveAvailable: Bool {
        FileManager.default.fileExists(atPath: iCloudDriveRoot.path)
    }

    /// The user-chosen directory, if any.
    static var customDirectory: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: directoryKey), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            UserDefaults.standard.set(newValue?.path, forKey: directoryKey)
        }
    }

    /// Where the envelope lives: the custom directory when set, else the
    /// iCloud Drive default. nil when neither is usable (iCloud missing and
    /// no custom directory chosen yet).
    static var effectiveDirectory: URL? {
        if let custom = customDirectory { return custom }
        return iCloudDriveAvailable ? defaultDirectory : nil
    }

    nonisolated static func envelopeFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("sync-envelope.json", isDirectory: false)
    }
}
