import Foundation
import Security

/// Secure per-host storage for TOTP secrets, backed by the macOS Keychain.
///
/// Secrets are stored as generic-password items keyed by host UUID in the
/// macOS Data Protection Keychain. They are never written to disk in plain
/// text and are only materialized for the duration of a single `load` call —
/// callers should hold the returned string no longer than needed.
enum TOTPStore {
    /// One Keychain item per host: `service = servicePrefix + hostID`.
    private static let servicePrefix = "dev.zero.Harbor.totp."
    /// Fixed account name; the host identity lives entirely in the service.
    private static let account = "totp-secret"

    private static func service(for hostID: UUID) -> String {
        servicePrefix + hostID.uuidString
    }

    /// Builds the item identity shared by reads, writes, and deletes. TOTP is
    /// an interactive foreground feature, so it belongs in the Data Protection
    /// Keychain and must only be readable while the user session is unlocked.
    private static func itemQuery(
        for hostID: UUID,
        dataProtectionKeychain: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: hostID),
            kSecAttrAccount as String: account
        ]
        if dataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// The item attributes for all new Data Protection Keychain entries.
    /// `ThisDeviceOnly` prevents sync/backup migration and `WhenUnlocked`
    /// prevents background access after the screen is locked.
    private static func protectedAttributes(with data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
    }

    /// Reads raw item data and preserves the Keychain status so callers can
    /// distinguish a missing item from a locked or otherwise unavailable one.
    private static func readData(
        for hostID: UUID,
        dataProtectionKeychain: Bool
    ) -> (status: OSStatus, data: Data?) {
        var query = itemQuery(for: hostID, dataProtectionKeychain: dataProtectionKeychain)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    private static func itemIsPresent(
        for hostID: UUID,
        dataProtectionKeychain: Bool
    ) -> OSStatus {
        var query = itemQuery(for: hostID, dataProtectionKeychain: dataProtectionKeychain)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil)
    }

    private static func deleteItem(
        for hostID: UUID,
        dataProtectionKeychain: Bool
    ) -> OSStatus {
        SecItemDelete(
            itemQuery(for: hostID, dataProtectionKeychain: dataProtectionKeychain) as CFDictionary
        )
    }

    private static func deleteSucceeded(_ status: OSStatus) -> Bool {
        status == errSecSuccess || status == errSecItemNotFound
    }

    /// Removes an item created by pre-Data-Protection-Keychain Harbor builds.
    /// This is called only after a protected replacement exists, so a failed
    /// migration never loses the user's TOTP secret.
    @discardableResult
    private static func removeLegacyItem(for hostID: UUID) -> Bool {
        deleteSucceeded(deleteItem(for: hostID, dataProtectionKeychain: false))
    }

    /// Creates a protected replacement for a legacy item. If a concurrent
    /// writer created the modern item first, verify that the modern item is
    /// readable before removing the legacy copy.
    private static func migrateLegacyItem(data: Data, for hostID: UUID) {
        var addQuery = itemQuery(for: hostID, dataProtectionKeychain: true)
        addQuery.merge(protectedAttributes(with: data), uniquingKeysWith: { _, new in new })

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            _ = removeLegacyItem(for: hostID)
        case errSecDuplicateItem:
            let modern = readData(for: hostID, dataProtectionKeychain: true)
            if modern.status == errSecSuccess, modern.data != nil {
                _ = removeLegacyItem(for: hostID)
            }
        default:
            // Keep the legacy entry intact. It remains available for a future
            // migration attempt and, crucially, no secret was discarded.
            break
        }
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

        // Prefer an update so a failed write never destroys an existing
        // secret. This also upgrades any earlier DP entry to WhenUnlocked.
        let attributes = protectedAttributes(with: data)
        let updateStatus = SecItemUpdate(
            itemQuery(for: hostID, dataProtectionKeychain: true) as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return removeLegacyItem(for: hostID)
        }
        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = itemQuery(for: hostID, dataProtectionKeychain: true)
        addQuery.merge(attributes, uniquingKeysWith: { _, new in new })
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return removeLegacyItem(for: hostID)
        }

        // Another caller may have won the add race. Updating it preserves the
        // requested value without falling back to the weaker legacy store.
        guard addStatus == errSecDuplicateItem else { return false }
        let retryStatus = SecItemUpdate(
            itemQuery(for: hostID, dataProtectionKeychain: true) as CFDictionary,
            attributes as CFDictionary
        )
        guard retryStatus == errSecSuccess else { return false }
        return removeLegacyItem(for: hostID)
    }

    /// Loads the Base32 secret for a host, or nil when none is stored.
    static func load(for hostID: UUID) -> String? {
        let modern = readData(for: hostID, dataProtectionKeychain: true)
        if modern.status == errSecSuccess {
            guard let data = modern.data else { return nil }
            return String(data: data, encoding: .utf8)
        }

        // Only inspect the legacy keychain if the protected store has no item.
        // In particular, never bypass an interaction/lock failure by falling
        // back to the less restrictive legacy record.
        guard modern.status == errSecItemNotFound else { return nil }

        let legacy = readData(for: hostID, dataProtectionKeychain: false)
        guard legacy.status == errSecSuccess,
              let data = legacy.data,
              let secret = String(data: data, encoding: .utf8)
        else { return nil }

        migrateLegacyItem(data: data, for: hostID)
        return secret
    }

    /// True when a secret is stored for the host, without materializing it.
    static func hasSecret(for hostID: UUID) -> Bool {
        let modernStatus = itemIsPresent(for: hostID, dataProtectionKeychain: true)
        if modernStatus == errSecSuccess { return true }
        guard modernStatus == errSecItemNotFound else { return false }
        return itemIsPresent(for: hostID, dataProtectionKeychain: false) == errSecSuccess
    }

    /// Removes the stored secret for a host. Returns true if the item is gone
    /// afterwards (including the case where none existed).
    @discardableResult
    static func delete(for hostID: UUID) -> Bool {
        let modernStatus = deleteItem(for: hostID, dataProtectionKeychain: true)
        let legacyStatus = deleteItem(for: hostID, dataProtectionKeychain: false)
        return deleteSucceeded(modernStatus) && deleteSucceeded(legacyStatus)
    }
}
