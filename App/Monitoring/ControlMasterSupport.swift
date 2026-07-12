import Foundation
import HarborKit

/// App-side home of the ControlMaster socket directory: ~/.cache/harbor,
/// mode 700. Socket file names come from `ControlSocket` (HarborKit) so the
/// main session and auxiliary commands share the same literal path — the
/// whole path stays well under the ~104-byte unix-socket limit.
enum ControlMasterSupport {
    static var cacheDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("harbor", isDirectory: true)
    }

    /// Creates ~/.cache/harbor (and ~/.cache if needed) with mode 700.
    /// Existing directories are re-chmodded to 700 (harbor only) so sockets
    /// are never group/world accessible. Best-effort: ssh will complain on
    /// its own if the path is unusable.
    @discardableResult
    static func ensureCacheDirectory() -> Bool {
        let fm = FileManager.default
        let url = cacheDirectoryURL
        do {
            try fm.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // createDirectory leaves an existing directory's mode untouched.
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return true
        } catch {
            NSLog("Harbor: cannot prepare control socket directory: \(error)")
            return false
        }
    }

    /// Fully expanded socket path for a host (no %C/%h tokens — ssh and the
    /// app must agree on the literal path). A non-nil `discriminator` yields
    /// a per-session socket for additional tabs to the same destination.
    static func socketPath(for host: SSHHost, discriminator: String? = nil) -> String {
        cacheDirectoryURL
            .appendingPathComponent(ControlSocket.fileName(for: host, discriminator: discriminator))
            .path
    }

    /// Verifies that `path` is short enough to be used as a Unix domain socket
    /// path (≤ 104 bytes on Darwin). Uses `precondition` so the check is NOT
    /// stripped in release builds — a path that exceeds the limit is a
    /// programming error that must be caught during development and will
    /// surface immediately in production rather than silently producing a
    /// broken socket.
    static func assertSafeSocketPath(_ path: String) {
        let byteCount = path.utf8.count
        precondition(byteCount <= 104,
            "Harbor: socket path exceeds 104-byte Unix limit (\(byteCount) bytes): \(path)")
    }
}
