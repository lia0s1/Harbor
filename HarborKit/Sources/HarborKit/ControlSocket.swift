import CryptoKit
import Foundation

/// Naming for SSH ControlMaster multiplexing sockets.
///
/// The app passes an explicit, already-expanded socket path (no `%C`/`%h`
/// tokens) so the interactive master session and auxiliary monitoring
/// commands share the same literal `ControlPath`. The file name is short and
/// deterministic — `cm-` + first 16 hex characters of SHA1("user@host:port")
/// — keeping the full path well under the ~104-byte `sockaddr_un` limit.
public enum ControlSocket {
    /// `cm-<first 16 hex of SHA1("user@host:port")>`. The username may be
    /// empty (key becomes `"@host:port"`); what matters is determinism.
    ///
    /// A non-nil `discriminator` is appended as `"#<discriminator>"` before
    /// hashing: when a second tab opens to the same destination it must become
    /// its OWN mux master on a distinct socket — otherwise closing the first
    /// tab (the shared master) would disconnect every sibling mux client.
    public static func fileName(
        username: String,
        hostname: String,
        port: Int,
        discriminator: String? = nil
    ) -> String {
        var key = "\(username)@\(hostname):\(port)"
        if let discriminator, !discriminator.isEmpty {
            key += "#\(discriminator)"
        }
        let digest = Insecure.SHA1.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "cm-" + String(hex.prefix(16))
    }

    /// Convenience over a host: trims whitespace the same way
    /// `SSHCommandBuilder` does so the key matches the spawned destination.
    public static func fileName(for host: SSHHost, discriminator: String? = nil) -> String {
        fileName(
            username: host.username.trimmingCharacters(in: .whitespaces),
            hostname: host.hostname.trimmingCharacters(in: .whitespaces),
            port: host.port,
            discriminator: discriminator
        )
    }
}
