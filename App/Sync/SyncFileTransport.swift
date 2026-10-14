import Foundation
import CryptoKit

/// Raw file IO for the sync envelope and the local state file. Writes are
/// atomic (staging file + rename) with 0600 permissions; the enclosing
/// directory is created with 0700 when missing. All functions are
/// queue-agnostic — callers pick the queue.
enum SyncFileIO {
    /// nil when the file simply does not exist; throws on real IO errors.
    nonisolated static func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    nonisolated static func writeAtomic(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: staging) }
        guard fm.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: staging)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: url)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    nonisolated static func delete(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
    }

    nonisolated static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Shared ISO8601 strategies: fractional seconds on the wire (same-second
/// edits on different devices shouldn't collapse into deviceID tiebreaks more
/// often than necessary), tolerant of plain whole-second strings on decode.
///
/// `ISO8601DateFormatter` is not Sendable, but its string(from:) /
/// date(from:) are read-only and thread-safe once configured, and both codecs
/// run on the main actor anyway — the wrapper only satisfies the
/// strict-concurrency capture checks.
enum SyncDateCodec {
    private struct SendableFormatter: @unchecked Sendable {
        let value: ISO8601DateFormatter
    }

    private static let fractional = SendableFormatter(value: {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }())

    private static let plain = SendableFormatter(value: {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }())

    static var encodingStrategy: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractional.value.string(from: date))
        }
    }

    static var decodingStrategy: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = fractional.value.date(from: raw) ?? plain.value.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(raw)")
        }
    }
}

/// Watches a DIRECTORY (not the envelope file itself: sync services replace
/// files via rename, which would orphan an fd-level watch) and fires when the
/// envelope may have changed. Debouncing and self-write suppression live in
/// the engine.
final class SyncDirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1

    /// Starts watching; returns false when the directory cannot be opened.
    func start(directory: URL, onChange: @escaping @Sendable () -> Void) -> Bool {
        stop()
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        descriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: .global(qos: .utility)
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    deinit { stop() }
}
