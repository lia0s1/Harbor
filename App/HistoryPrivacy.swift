import Foundation

/// Privacy policy shared by command and remote-path history. Persistence is
/// opt-in: an unset preference means history remains in memory for the current
/// UI/session only and any legacy UserDefaults copy is erased on first use.
enum HistoryPrivacyPreference {
    static let persistenceKey = "harbor.persistSensitiveHistory"
    static let commandStorageKey = "commandHistory"
    static let pathStorageKey = "harbor.pathHistory"

    static func isPersistenceEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: persistenceKey)
    }

    @MainActor
    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: commandStorageKey)
        defaults.removeObject(forKey: pathStorageKey)
        // Sweep every per-host bucket (`pathStorageKey.<dest>#<port>`). Buckets
        // written by earlier sessions may have no in-memory store this run, so
        // PathHistoryStore's live-bucket clear can't reach them — enumerate all
        // persisted keys and drop the ones under the per-host prefix.
        let bucketPrefix = pathStorageKey + "."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(bucketPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
