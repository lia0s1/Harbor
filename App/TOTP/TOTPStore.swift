import Foundation
import Security

/// Secure per-host storage for TOTP secrets, backed by the macOS Keychain.
///
/// Secrets are stored as generic-password items keyed by host UUID. They are
/// never written to disk in plain text and are only materialized for the
/// duration of a single `load` call — callers should hold the returned string
/// no longer than needed.
enum TOTPStore {
    /// One Keychain item per host: `service = servicePrefix + hostID`.
    private static let servicePrefix = "dev.zero.Harbor.totp."
    /// Fixed account name; the host identity lives entirely in the service.
    private static let account = "totp-secret"

    private static func service(for hostID: UUID) -> String {
        servicePrefix + hostID.uuidString
    }

    /// Saves (or replaces) the Base32 secret for a host. An empty or
    /// whitespace-only secret deletes the item instead. Returns true on success.
    @discardableResult
    static func save(secret: String, for hostID: UUID) -> Bool {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return delete(for: hostID)
        }
        guard let data = trimmed.data(using: .utf8) else { return false }

        // Delete any existing record first so we always insert a clean item
        // (simpler and more portable than SecItemUpdate across OS versions).
        delete(for: hostID)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: hostID),
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Readable after first unlock; never leaves this device / syncs.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Loads the Base32 secret for a host, or nil when none is stored.
    static func load(for hostID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: hostID),
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let secret = String(data: data, encoding: .utf8)
        else { return nil }
        return secret
    }

    /// True when a secret is stored for the host, without materializing it.
    static func hasSecret(for hostID: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: hostID),
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Removes the stored secret for a host. Returns true if the item is gone
    /// afterwards (including the case where none existed).
    @discardableResult
    static func delete(for hostID: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: hostID),
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
