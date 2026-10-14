import Foundation
import os

/// One row of `arp -a` output. `mac` is nil for "(incomplete)" entries — the
/// kernel knows the address is on-link but got no ARP reply, which for LAN
/// discovery means "probably not alive".
public struct ArpEntry: Equatable, Sendable {
    /// Reverse-resolved name as printed by arp, nil when arp prints "?" (or
    /// when scanned with `-an`, which never resolves).
    public let hostname: String?
    public let ip: String
    /// Normalized to uppercase zero-padded "AA:BB:CC:DD:EE:FF" — macOS prints
    /// octets without leading zeros ("0:11:32:…").
    public let mac: String?
    /// Interface name, e.g. "en0". Empty when the line has no "on" clause.
    public let interfaceName: String

    public init(hostname: String?, ip: String, mac: String?, interfaceName: String) {
        self.hostname = hostname
        self.ip = ip
        self.mac = mac
        self.interfaceName = interfaceName
    }
}

/// Pure parser for macOS `arp -a` / `arp -an` output:
///
///     ? (192.168.1.1) at 0:11:32:1a:2b:3c on en0 ifscope [ethernet]
///     router.lan (192.168.1.5) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]
///     ? (192.168.1.9) at (incomplete) on en0 ifscope [ethernet]
///     ? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]
///
/// Tolerates missing `on` clauses and trailing flags; drops lines whose IP or
/// MAC doesn't parse so `arp` chatter never becomes phantom hosts.
public enum ArpTableParser {
    /// name (ip) at mac [on iface] …
    private static let lineRegex: NSRegularExpression? = {
        do {
            return try NSRegularExpression(
                pattern: #"^(\S+)\s+\(([^)]+)\)\s+at\s+(\S+)(?:\s+on\s+(\S+))?"#
            )
        } catch {
            Logger().warning("ArpTableParser: lineRegex compile failed: \(error.localizedDescription)")
            return nil
        }
    }()

    public static func parse(_ text: String) -> [ArpEntry] {
        guard let lineRegex else { return [] }
        var result: [ArpEntry] = []
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            let nsLine = line as NSString
            guard let match = lineRegex.firstMatch(
                in: line, range: NSRange(location: 0, length: nsLine.length)
            ) else { continue }

            let nameToken = nsLine.substring(with: match.range(at: 1))
            let ip = nsLine.substring(with: match.range(at: 2))
            let atField = nsLine.substring(with: match.range(at: 3))
            let interface = match.range(at: 4).location != NSNotFound
                ? nsLine.substring(with: match.range(at: 4))
                : ""

            // The IP must be a real dotted quad — this filters header noise and
            // (rare) IPv6-shaped neighbors out of an IPv4-oriented feature.
            guard IPv4Address(dottedString: ip) != nil else { continue }

            let hostname = nameToken == "?" ? nil : nameToken
            let mac = atField == "(incomplete)" ? nil : normalizeMAC(atField)
            // A present-but-unparseable MAC means the line isn't the format we
            // understand — drop it rather than show a half-parsed host.
            if mac == nil && atField != "(incomplete)" { continue }

            result.append(ArpEntry(hostname: hostname, ip: ip, mac: mac, interfaceName: interface))
        }
        return result
    }

    /// "0:11:32:a:b:c" → "00:11:32:0A:0B:0C". Returns nil unless exactly six
    /// 1-2 digit hex octets.
    static func normalizeMAC(_ token: String) -> String? {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var octets: [String] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 2,
                  part.allSatisfy({ $0.isHexDigit }) else { return nil }
            octets.append(String(repeating: "0", count: 2 - part.count) + part.uppercased())
        }
        return octets.joined(separator: ":")
    }
}
