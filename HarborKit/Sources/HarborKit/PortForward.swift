import Foundation

/// One `-L` / `-R` / `-D` forwarding rule.
public struct PortForward: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case local
        case remote
        case dynamic
    }

    public var id: UUID
    public var kind: Kind
    /// Optional bind address ("localhost", "0.0.0.0", ...). Empty/nil means ssh default.
    public var bindAddress: String?
    public var bindPort: Int
    /// Target host/port — unused for `.dynamic`.
    public var targetHost: String
    public var targetPort: Int

    public init(
        id: UUID = UUID(),
        kind: Kind,
        bindAddress: String? = nil,
        bindPort: Int,
        targetHost: String = "",
        targetPort: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.bindAddress = bindAddress
        self.bindPort = bindPort
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress)
        bindPort = try c.decode(Int.self, forKey: .bindPort)
        targetHost = try c.decodeIfPresent(String.self, forKey: .targetHost) ?? ""
        targetPort = try c.decodeIfPresent(Int.self, forKey: .targetPort) ?? 0
    }
}
