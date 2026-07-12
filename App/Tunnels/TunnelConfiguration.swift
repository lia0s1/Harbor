import Foundation
import HarborKit

/// A saved SSH tunnel (port-forwarding) rule for a host. Mirrors the three ssh
/// forwarding modes: local (`-L`), remote (`-R`) and dynamic SOCKS (`-D`).
///
/// This is the persisted, user-facing shape. `portForward` bridges it to
/// HarborKit's `PortForward` so tunnels reuse the same injection-safe argv
/// builder (`SSHCommandBuilder.forwardArguments`) as the rest of the app —
/// there is deliberately no second copy of the `-L`/`-R`/`-D` assembly.
struct TunnelConfiguration: Codable, Identifiable, Equatable {
    var id: UUID
    var type: TunnelType
    /// Listening/bind port: the local port for `.local`/`.dynamic`, the remote
    /// bind port for `.remote`.
    var localPort: Int
    /// Target host — used by `.local`/`.remote`, ignored for `.dynamic`.
    var remoteHost: String
    /// Target port — used by `.local`/`.remote`, ignored for `.dynamic`.
    var remotePort: Int
    var enabled: Bool
    /// User-friendly name shown in the list; falls back to the endpoint summary.
    var label: String

    init(
        id: UUID = UUID(),
        type: TunnelType = .local,
        localPort: Int = 0,
        remoteHost: String = "",
        remotePort: Int = 0,
        enabled: Bool = true,
        label: String = ""
    ) {
        self.id = id
        self.type = type
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.enabled = enabled
        self.label = label
    }

    // Tolerant decode (matches SSHHost / PortForward): a single missing or
    // malformed field must not drop every saved tunnel in the array.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        type = (try? c.decodeIfPresent(TunnelType.self, forKey: .type)) ?? .local
        localPort = try c.decodeIfPresent(Int.self, forKey: .localPort) ?? 0
        remoteHost = try c.decodeIfPresent(String.self, forKey: .remoteHost) ?? ""
        remotePort = try c.decodeIfPresent(Int.self, forKey: .remotePort) ?? 0
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
    }

    /// Bridges to HarborKit's `PortForward` so tunnels share the app's single
    /// injection-safe argv builder. Keeps the same `id` so a live add
    /// (`ssh -O forward`) and its later cancel (`ssh -O cancel`) target the
    /// same rule.
    var portForward: PortForward {
        PortForward(
            id: id,
            kind: type.forwardKind,
            bindPort: localPort,
            targetHost: remoteHost,
            targetPort: remotePort
        )
    }

    /// Compact ssh-style endpoint description for the row, e.g.
    /// "8080:db:5432" (local/remote) or ":1080" (dynamic SOCKS).
    var endpointSummary: String {
        switch type {
        case .dynamic:
            return ":\(localPort)"
        case .local, .remote:
            return "\(localPort):\(remoteHost):\(remotePort)"
        }
    }

    /// Name to show in the list: the explicit label, else the endpoint summary.
    var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? endpointSummary : trimmed
    }
}

/// The three ssh forwarding modes.
enum TunnelType: String, Codable, CaseIterable {
    case local
    case remote
    case dynamic

    /// Maps to HarborKit's `PortForward.Kind` (same cases, distinct type so the
    /// app model stays decoupled from the kit model).
    var forwardKind: PortForward.Kind {
        switch self {
        case .local: return .local
        case .remote: return .remote
        case .dynamic: return .dynamic
        }
    }
}
