import Foundation

public enum QuickConnectError: Error, Equatable, LocalizedError {
    case empty
    case invalidPort(String)
    case invalidHost(String)
    case invalidUser(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "Enter a host to connect to."
        case .invalidPort(let p): return "Invalid port: \u{201C}\(p)\u{201D}"
        case .invalidHost(let h): return "Invalid host: \u{201C}\(h)\u{201D}"
        case .invalidUser(let u): return "Invalid user: \u{201C}\(u)\u{201D}"
        }
    }
}

/// Parses quick-connect strings of the form `[user@]host[:port]` into an `SSHHost`.
public enum QuickConnectParser {
    public static func parse(_ input: String) throws -> SSHHost {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QuickConnectError.empty }

        var rest = Substring(trimmed)
        var username = ""

        // Split on the LAST "@" so usernames containing "@" (rare but legal
        // in some directory setups) still work.
        if let at = rest.lastIndex(of: "@") {
            username = String(rest[rest.startIndex..<at])
            rest = rest[rest.index(after: at)...]
            guard !username.isEmpty else { throw QuickConnectError.invalidUser(trimmed) }
        }

        var host = String(rest)
        var port = SSHHost.defaultPort

        if host.hasPrefix("[") {
            // Bracketed IPv6 literal, optionally with a port: "[::1]" or
            // "[2001:db8::1]:2222". Strip the brackets (ssh takes a bare IPv6
            // host plus the port via -p) and parse a trailing ":port" if any.
            guard let close = host.firstIndex(of: "]") else {
                throw QuickConnectError.invalidHost(trimmed)
            }
            let inner = String(host[host.index(after: host.startIndex)..<close])
            let afterBracket = host[host.index(after: close)...]
            if afterBracket.isEmpty {
                host = inner
            } else if afterBracket.first == ":" {
                let portPart = String(afterBracket.dropFirst())
                guard let p = Int(portPart), (1...65535).contains(p), !portPart.isEmpty else {
                    throw QuickConnectError.invalidPort(portPart)
                }
                port = p
                host = inner
            } else {
                throw QuickConnectError.invalidHost(trimmed)
            }
        } else if let colon = host.lastIndex(of: ":") {
            let portPart = String(host[host.index(after: colon)...])
            // Only treat as a port when everything after ":" is digits and
            // there is exactly one colon (avoid mangling IPv6 literals).
            let colonCount = host.filter { $0 == ":" }.count
            if colonCount == 1 {
                guard let p = Int(portPart), (1...65535).contains(p), !portPart.isEmpty else {
                    throw QuickConnectError.invalidPort(portPart)
                }
                port = p
                host = String(host[host.startIndex..<colon])
            }
            // Multiple colons: assume bare IPv6 literal, leave as-is.
        }

        guard !host.isEmpty else { throw QuickConnectError.invalidHost(trimmed) }

        // Same injection rules as SSHCommandBuilder: no leading dash, no
        // whitespace/control chars in host or user.
        do {
            try SSHCommandBuilder.validate(host, field: "hostname")
        } catch {
            throw QuickConnectError.invalidHost(host)
        }
        if !username.isEmpty {
            do {
                try SSHCommandBuilder.validate(username, field: "username")
            } catch {
                throw QuickConnectError.invalidUser(username)
            }
        }

        return SSHHost(hostname: host, port: port, username: username)
    }
}
