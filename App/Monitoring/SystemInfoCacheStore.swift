import CryptoKit
import Foundation
import HarborKit

/// One host's last good 系统信息 probe, persisted to disk.
///
/// `hostKey` is the human-readable `user@host:port` the snapshot belongs to
/// (debug aid — the file name is derived from the same string); `version`
/// leaves room to evolve the payload without crashing on stale files.
struct CachedSystemInfo: Codable, Sendable {
    var version: Int = 1
    var hostKey: String
    var fetchedAt: Date
    var info: SystemInfo
}

/// Stale-while-revalidate disk cache for the 系统信息 report, one small JSON
/// file per host under `Application Support/Harbor/system-info/`.
///
/// The in-session `@Published` state already makes RE-opening the sheet
/// instant, but it dies with the session — so every reconnect / app restart
/// used to pay the full socket-gate + mux + remote-exec chain (seconds on a
/// high-RTT host) before anything rendered. Persisting the last good probe
/// lets the view render instantly from disk and refresh in place when the
/// background probe lands.
///
/// Follows the `JSONFileStore` durability style: directory 0700, file 0600,
/// atomic staging-file replace, writes serialized on a background queue.
/// Reads are synchronous: the file is a few KB, so decoding it on the main
/// actor costs less than a frame — far cheaper than the spinner it replaces.
enum SystemInfoCacheStore {
    private static let queue = DispatchQueue(
        label: "dev.zero.Harbor.sysinfo-cache",
        qos: .utility
    )

    /// Stable cache identity for one host: `user@host:port`. Two users on the
    /// same box can legitimately see different mounts/addresses, so the
    /// destination (which includes the user) is part of the key.
    static func hostID(destination: String, port: Int) -> String {
        "\(destination):\(port)"
    }

    /// Loads the cached snapshot for `hostID`, or nil when absent/corrupt.
    /// Corrupt files are moved aside (`*.corrupt-<ts>`) like JSONFileStore,
    /// so a bad write can never wedge every future open.
    static func load(hostID: String, fileManager: FileManager = .default) -> CachedSystemInfo? {
        let url = fileURL(cacheKey: hostID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let snapshot = try makeDecoder().decode(CachedSystemInfo.self, from: data)
            guard snapshot.version == 1 else { return nil }
            return snapshot
        } catch {
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).corrupt-\(timestamp)")
            try? fileManager.moveItem(at: url, to: aside)
            return nil
        }
    }

    /// Persists a snapshot off the caller's thread. Fire-and-forget: a failed
    /// cache write must never fail the probe that produced it, so errors are
    /// only logged to the timing channel.
    static func save(_ snapshot: CachedSystemInfo, fileManager: FileManager = .default) {
        queue.async {
            // snapshot.hostKey IS the cache identity (`user@host:port`), so
            // the file name derives from it directly.
            write(snapshot, to: fileURL(cacheKey: snapshot.hostKey), using: fileManager)
        }
    }

    // MARK: - Paths

    /// `<Application Support>/Harbor/system-info/`, matching the resolution
    /// `JSONFileStore.defaultFileURL` uses for its siblings.
    private static func directory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Harbor", isDirectory: true)
            .appendingPathComponent("system-info", isDirectory: true)
    }

    /// Human-legible but collision-safe file name: sanitized identity plus a
    /// short digest of the full string (`user@host:port` can exceed filename
    /// limits and contains `/`-adjacent characters).
    private static func fileURL(cacheKey: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@._-"))
        var sanitized = cacheKey.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "_" }
            .map(String.init)
            .joined()
        if sanitized.count > 48 { sanitized = String(sanitized.prefix(48)) }
        let digest = SHA256.hash(data: Data(cacheKey.utf8))
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
        return directory().appendingPathComponent("\(sanitized)-\(digest).json")
    }

    // MARK: - Coders

    /// Fresh coder per call: runs once per probe, so the allocation is noise
    /// and there is no shared-JSONEncoder threading question to reason about.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Atomic write (mirrors JSONStorePersistence.write)

    private static func write(_ snapshot: CachedSystemInfo, to url: URL, using fileManager: FileManager) {
        do {
            let data = try makeEncoder().encode(snapshot)
            let directory = url.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let stagingURL = directory.appendingPathComponent(
                ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
            )
            defer { try? fileManager.removeItem(at: stagingURL) }
            guard fileManager.createFile(
                atPath: stagingURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else { return }
            try data.write(to: stagingURL)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: stagingURL)
            } else {
                try fileManager.moveItem(at: stagingURL, to: url)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Cache writes are best-effort; surface them only on the timing
            // channel so a full/damaged disk never breaks the report itself.
            SysInfoTiming.note("sysinfo cache-write-failed: \(error.localizedDescription)")
        }
    }
}
