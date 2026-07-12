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
    }
}
