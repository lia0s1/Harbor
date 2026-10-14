import Foundation

/// Dotted-quad IPv4 address backed by a host-order UInt32. Pure value type
/// shared by LAN discovery (subnet math) and GeoIP (private-range short
/// circuit). Parsing is strict — four decimal 0-255 octets, no leading zeros,
/// no whitespace — so UI input and parser output never silently reinterpret.
public struct IPv4Address: Hashable, Sendable, Comparable {
    /// Host byte order: 192.168.1.10 == 0xC0A8010A.
    public let raw: UInt32

    public init(raw: UInt32) {
        self.raw = raw
    }

    /// Parses "192.168.1.10". Rejects short forms ("1.2.3"), hex, leading
    /// zeros ("010.0.0.1" — octal-ambiguous in legacy parsers), and anything
    /// outside 0-255.
    public init?(dottedString: String) {
        let parts = dottedString.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            if part.count > 1 && part.first == "0" { return nil }
            guard let octet = UInt32(part), octet <= 255 else { return nil }
            value = (value << 8) | octet
        }
        self.raw = value
    }

    public var dottedString: String {
        "\(raw >> 24).\(raw >> 16 & 0xFF).\(raw >> 8 & 0xFF).\(raw & 0xFF)"
    }

    public static func < (lhs: IPv4Address, rhs: IPv4Address) -> Bool {
        lhs.raw < rhs.raw
    }

    /// 224.0.0.0/4 — mDNS/SSDP etc. show up in `arp -a` but are never hosts.
    public var isMulticast: Bool {
        raw >> 28 == 0xE
    }

    /// (network, prefix) pairs that never identify a public-internet host.
    /// Used by GeoIP to answer "内网" without burning an API call, and by the
    /// LAN scanner to drop junk ARP entries.
    private static let reservedRanges: [(network: UInt32, prefix: Int)] = [
        (0x0000_0000, 8),   // 0.0.0.0/8        "this network" (RFC 1122)
        (0x0A00_0000, 8),   // 10.0.0.0/8       RFC 1918
        (0x6440_0000, 10),  // 100.64.0.0/10    CGNAT (RFC 6598)
        (0x7F00_0000, 8),   // 127.0.0.0/8      loopback
        (0xA9FE_0000, 16),  // 169.254.0.0/16   link-local
        (0xAC10_0000, 12),  // 172.16.0.0/12    RFC 1918
        (0xC000_0200, 24),  // 192.0.2.0/24     TEST-NET-1 (RFC 5737)
        (0xC058_6300, 24),  // 192.88.99.0/24   6to4 relay anycast (deprecated)
        (0xC0A8_0000, 16),  // 192.168.0.0/16   RFC 1918
        (0xC612_0000, 15),  // 198.18.0.0/15    benchmarking (RFC 2544)
        (0xC633_6400, 24),  // 198.51.100.0/24  TEST-NET-2
        (0xCB00_7100, 24),  // 203.0.113.0/24   TEST-NET-3
        (0xE000_0000, 4),   // 224.0.0.0/4      multicast
        (0xF000_0000, 4),   // 240.0.0.0/4      reserved (incl. 255.255.255.255)
    ]

    /// True for RFC 1918 / loopback / link-local / CGNAT / multicast /
    /// reserved / documentation ranges — anything that can never be a public
    /// internet endpoint worth geolocating.
    public var isPrivateOrReserved: Bool {
        Self.reservedRanges.contains { range in
            (raw >> (32 - range.prefix)) == (range.network >> (32 - range.prefix))
        }
    }
}

/// One local network interface's IPv4 address + netmask, and the host range
/// derived from it for scanning.
public struct LocalSubnet: Equatable, Sendable {
    /// Interface name as the kernel reports it, e.g. "en0".
    public let interfaceName: String
    public let address: IPv4Address
    public let netmask: IPv4Address

    public init(interfaceName: String, address: IPv4Address, netmask: IPv4Address) {
        self.interfaceName = interfaceName
        self.address = address
        self.netmask = netmask
    }

    /// Leading-one count of the netmask; nil when the mask is not contiguous
    /// (e.g. 255.0.255.0). Such interfaces are skipped — guessing a range from
    /// a broken mask would spray probes at unrelated addresses.
    public var prefixLength: Int? {
        var mask = netmask.raw
        var prefix = 0
        while mask & 0x8000_0000 != 0 {
            prefix += 1
            mask <<= 1
        }
        return mask == 0 ? prefix : nil
    }

    /// The network address of the effective (possibly truncated) scan block.
    /// Useful for deduplicating interfaces that sit on the same segment.
    public var scanBlockBase: IPv4Address? {
        guard let prefix = prefixLength else { return nil }
        let effective = max(prefix, 24)
        let shift = 32 - effective
        return IPv4Address(raw: address.raw & (UInt32.max << shift))
    }

    /// Host addresses to probe. Subnets larger than /24 are truncated to the
    /// /24 containing the interface address — a /16 corporate LAN must not
    /// turn into a 65k-host sweep. Subnets smaller than /24 are honored as-is.
    /// Network and broadcast addresses are excluded; absolute cap 254.
    public var scanAddresses: [IPv4Address] {
        guard let prefix = prefixLength else { return [] }
        let effective = max(prefix, 24)
        if effective == 32 { return [address] }
        let shift = 32 - effective
        let mask = UInt32.max << shift
        let base = address.raw & mask
        let broadcast = base | ~mask
        // /31 is a point-to-point link (RFC 3021): both addresses are hosts.
        if effective == 31 {
            return [IPv4Address(raw: base), IPv4Address(raw: broadcast)]
        }
        guard broadcast > base else { return [] }
        var result: [IPv4Address] = []
        var current = base &+ 1
        while current < broadcast, result.count < 254 {
            result.append(IPv4Address(raw: current))
            current &+= 1
        }
        return result
    }
}
