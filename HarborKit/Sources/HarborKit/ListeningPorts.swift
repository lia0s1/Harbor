import Foundation

/// One listening socket from `ss -tulnpH` — the "谁占了 8080" lookup. Carries
/// the protocol, bind address + port, and the owning process when `ss` can see
/// it. Process attribution needs root for *other* users' sockets; without it the
/// process fields stay empty but the port itself still shows. Linux-only, like
/// the rest of monitoring.
public struct ListeningPort: Equatable, Sendable, Identifiable {
    /// "tcp" or "udp" (ss's `tcp6`/`udp6` netids fold to the base name; the
    /// IPv6-ness is already visible in `address`).
    public let proto: String
    /// Bind address as `ss` prints it, IPv6 brackets stripped: "0.0.0.0", "*",
    /// "::", "127.0.0.1", "::1".
    public let address: String
    public let port: Int
    /// First owning process name, or "" when `ss` couldn't attribute it.
    public let process: String
    /// First owning pid, or 0 when unknown (non-root, or process gone).
    public let pid: Int

    public init(proto: String, address: String, port: Int, process: String, pid: Int) {
        self.proto = proto
        self.address = address
        self.port = port
        self.process = process
        self.pid = pid
    }

    public var id: String { "\(proto)/\(address):\(port)#\(pid)" }

    /// True for wildcard binds reachable from any address (0.0.0.0 / :: / *) —
    /// the ones worth flagging as externally exposed.
    public var isWildcard: Bool {
        address == "0.0.0.0" || address == "::" || address == "*"
    }
}

/// Pure parser for `ss -tulnpH` (or header-bearing `ss -tulnp` on older
/// iproute2). Tolerates the header line, missing process attribution, IPv6
/// bracket syntax, and wildcard addresses.
public enum ListeningPortsParser {
    /// The remote command: `-t` tcp, `-u` udp, `-l` listening, `-n` numeric (no
    /// DNS/port-name resolution), `-p` process, `-H` no header. `LC_ALL=C` keeps
    /// the columns from ever localizing. Falls back to header-bearing `ss`
    /// (iproute2 without `-H`) — the parser skips the header either way.
    public static let command =
        "LC_ALL=C ss -tulnpH 2>/dev/null || LC_ALL=C ss -tulnp 2>/dev/null"

    /// `users:(("name",pid=123,fd=4),…)` — captures the FIRST process name + pid.
    private static let procRegex: NSRegularExpression = {
        do { return try NSRegularExpression(pattern: #"\"([^\"]+)\",pid=(\d+)"#) }
        catch { fatalError("procRegex pattern is invalid: \(error)") }
    }()

    public static func parse(_ text: String) -> [ListeningPort] {
        var result: [ListeningPort] = []
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // ss columns: Netid State Recv-Q Send-Q Local:Port Peer:Port [Process]
            guard fields.count >= 5 else { continue }
            let netid = fields[0].lowercased()
            // Anything that isn't a known netid is the header ("Netid") or noise.
            guard netid == "tcp" || netid == "tcp6" || netid == "udp" || netid == "udp6"
            else { continue }
            let proto = netid.hasPrefix("tcp") ? "tcp" : "udp"
            guard let (address, port) = Self.splitHostPort(fields[4]) else { continue }
            // Scan the WHOLE line for the users:((…)) blob — robust whether it is
            // its own field or (rarely, with extra ss columns) shifted.
            var procName = ""
            var pid = 0
            let nsLine = line as NSString
            if let match = procRegex.firstMatch(
                in: line, range: NSRange(location: 0, length: nsLine.length)
            ) {
                procName = nsLine.substring(with: match.range(at: 1))
                pid = Int(nsLine.substring(with: match.range(at: 2))) ?? 0
            }
            result.append(ListeningPort(
                proto: proto, address: address, port: port, process: procName, pid: pid
            ))
        }
        return result
    }

    /// Splits an `ss` "address:port" token into (host, port). Handles IPv6
    /// "[::]:22" / "[::1]:631", IPv4 "0.0.0.0:22", and wildcard "*:22". Returns
    /// nil when the trailing token after the last colon isn't a number (a named
    /// port slipping past `-n`, or a stray header), so such lines are dropped.
    static func splitHostPort(_ token: String) -> (String, Int)? {
        guard let lastColon = token.lastIndex(of: ":") else { return nil }
        var host = String(token[..<lastColon])
        let portStr = String(token[token.index(after: lastColon)...])
        guard let port = Int(portStr), port >= 0, port <= 65535 else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return (host, port)
    }
}
