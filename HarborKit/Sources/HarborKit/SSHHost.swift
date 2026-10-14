import Foundation

/// Connection protocol for a saved host.
public enum ConnectionProtocol: String, Codable, Sendable, CaseIterable {
    case ssh
    case rdp
    case local   // local shell (no SSH — spawns $SHELL in a PTY)
}

/// A saved host plus all options needed to connect.
public struct SSHHost: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Display name shown in the sidebar. Falls back to hostname when empty.
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    /// Path to a private key file (`-i`). `~` is allowed; expansion happens at spawn time.
    public var identityFile: String?
    /// Jump host spec (`-J`), e.g. "admin@bastion:2222" or a comma-separated chain. Empty = none.
    public var proxyJump: String
    /// Raw extra arguments appended before the destination.
    public var extraArgs: [String]
    public var portForwards: [PortForward]
    public var tags: [String]
    public var notes: String
    /// OS family id (ubuntu/debian/fedora/…), detected on first connect and
    /// remembered so the sidebar can show the host's OS badge. nil until known.
    public var osID: String?
    /// Human distro name (e.g. "Ubuntu 22.04 LTS") for the badge/tooltip.
    public var osName: String?

    /// Whether to connect via SSH (default) or RDP (Windows Remote Desktop).
    public var connectionProtocol: ConnectionProtocol
    /// Windows domain for RDP authentication, e.g. "CORP". Empty = local account.
    public var rdpDomain: String
    /// Shell to launch after SSH login, e.g. "powershell.exe" or "cmd.exe".
    /// Empty = server default. Forces PTY allocation (`-t`) automatically.
    public var shell: String
    /// Folder this host belongs to in the sidebar tree. nil = unfiled (root).
    /// The folder records themselves live in the host store, keyed by this id.
    public var folderID: UUID?
    /// What the Backspace/Delete keys send on the wire, per host.
    /// `.auto` keeps the terminal default; the others fix hosts where
    /// backspace deletes wrong or prints `^H`/`^?`.
    public var backspaceBehavior: BackspaceBehavior

    /// Byte sequence sent for the Backspace key (and Delete where applicable).
    public enum BackspaceBehavior: String, Codable, Sendable, CaseIterable {
        case auto            // terminal default
        case asciiBackspace  // BS  = 0x08
        case asciiDelete     // DEL = 0x7f
        case vt220Delete     // DEL = ESC [ 3 ~
    }

    public static let defaultPort = 22
    public static let defaultRDPPort = 3389

    public init(
        id: UUID = UUID(),
        name: String = "",
        hostname: String = "",
        port: Int = SSHHost.defaultPort,
        username: String = "",
        identityFile: String? = nil,
        proxyJump: String = "",
        extraArgs: [String] = [],
        portForwards: [PortForward] = [],
        tags: [String] = [],
        notes: String = "",
        osID: String? = nil,
        osName: String? = nil,
        connectionProtocol: ConnectionProtocol = .ssh,
        rdpDomain: String = "",
        shell: String = "",
        folderID: UUID? = nil,
        backspaceBehavior: BackspaceBehavior = .auto
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.identityFile = identityFile
        self.proxyJump = proxyJump
        self.extraArgs = extraArgs
        self.portForwards = portForwards
        self.tags = tags
        self.notes = notes
        self.osID = osID
        self.osName = osName
        self.connectionProtocol = connectionProtocol
        self.rdpDomain = rdpDomain
        self.shell = shell
        self.folderID = folderID
        self.backspaceBehavior = backspaceBehavior
    }

    /// Creates a virtual host representing a local shell tab.
    /// Not persisted — used only as a session label / identity.
    public static func localShellHost() -> SSHHost {
        var h = SSHHost(hostname: "localhost")
        h.connectionProtocol = .local
        return h
    }

    /// Name to show in UI: explicit name, else "user@host", else hostname.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        if !username.isEmpty { return "\(username)@\(hostname)" }
        return hostname
    }

    // Tolerant decoding: only `id`/`hostname` style fields strictly required so
    // hand-edited JSON with missing keys still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A present-but-malformed UUID string (`decodeIfPresent` THROWS on a bad
        // value, it does not default) must not abort the whole array decode —
        // one corrupt id would otherwise drop every saved host. Fall back to a
        // fresh id for that one entry instead.
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        hostname = (try? c.decodeIfPresent(String.self, forKey: .hostname)) ?? ""
        port = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? SSHHost.defaultPort
        username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? ""
        identityFile = try? c.decodeIfPresent(String.self, forKey: .identityFile)
        proxyJump = (try? c.decodeIfPresent(String.self, forKey: .proxyJump)) ?? ""
        extraArgs = (try? c.decodeIfPresent([String].self, forKey: .extraArgs)) ?? []
        portForwards = (try? c.decodeIfPresent([PortForward].self, forKey: .portForwards)) ?? []
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        osID = try? c.decodeIfPresent(String.self, forKey: .osID)
        osName = try? c.decodeIfPresent(String.self, forKey: .osName)
        connectionProtocol = (try? c.decodeIfPresent(ConnectionProtocol.self, forKey: .connectionProtocol)) ?? .ssh
        rdpDomain = (try? c.decodeIfPresent(String.self, forKey: .rdpDomain)) ?? ""
        shell = (try? c.decodeIfPresent(String.self, forKey: .shell)) ?? ""
        folderID = try? c.decodeIfPresent(UUID.self, forKey: .folderID)
        backspaceBehavior = (try? c.decodeIfPresent(BackspaceBehavior.self, forKey: .backspaceBehavior)) ?? .auto
    }
}
