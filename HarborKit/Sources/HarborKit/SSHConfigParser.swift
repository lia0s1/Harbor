import Foundation

/// Parses OpenSSH client config text (`~/.ssh/config`) into `[SSHHost]`.
///
/// Supported: `Host` blocks (aliases containing `*` or `?`, or negated with
/// `!`, are skipped; "Host a b" creates one entry per alias), and the keys
/// HostName / User / Port / IdentityFile — case-insensitive, in either
/// `Key value` or `Key=value` form, with double-quoted values. `~` in
/// IdentityFile is expanded against the supplied home directory.
///
/// Ignored by design: `Match` blocks, `Include`, settings that appear before
/// the first `Host` line, and every unknown key. The parser never throws —
/// garbage lines are silently skipped. File IO lives in the app layer.
public enum SSHConfigParser {

    public static func parse(
        _ text: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [SSHHost] {
        var results: [SSHHost] = []

        /// Concrete aliases of the Host block currently being read. Empty when
        /// no block is open (preamble, Match block, or wildcard-only Host).
        var aliases: [String] = []
        var settings = BlockSettings()

        func flush() {
            defer {
                aliases = []
                settings = BlockSettings()
            }
            guard !aliases.isEmpty else { return }
            for alias in aliases {
                var host = SSHHost(name: alias, hostname: settings.hostname ?? alias)
                if let port = settings.port { host.port = port }
                if let user = settings.user { host.username = user }
                if let identity = settings.identityFile {
                    host.identityFile = expandTilde(identity, homeDirectory: homeDirectory)
                }
                results.append(host)
            }
        }

        // Split on any newline (\n, \r, or the single-grapheme "\r\n") so CRLF
        // files parse correctly; splitting on "\n" alone would not match the
        // CRLF grapheme cluster at all. The trim then catches any stray \r.
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let (key, value) = splitKeyValue(line) else { continue }

            switch key {
            case "host":
                flush()
                aliases = tokenize(value).filter(isConcreteAlias)
            case "match":
                // Match criteria are out of scope; flushing closes the open
                // block so the Match body's keys can never leak into a host.
                flush()
            case "hostname":
                if settings.hostname == nil, let v = firstToken(value) { settings.hostname = v }
            case "user":
                if settings.user == nil, let v = firstToken(value) { settings.user = v }
            case "port":
                // Strict: a Port value must be exactly one numeric token.
                let tokens = tokenize(value)
                if settings.port == nil, tokens.count == 1,
                   let port = Int(tokens[0]), (1...65535).contains(port) {
                    settings.port = port
                }
            case "identityfile":
                if settings.identityFile == nil, let v = firstToken(value) { settings.identityFile = v }
            default:
                break // Include, ProxyJump, unknown keys, … — ignored.
            }
        }
        flush()
        return results
    }

    // MARK: - Pieces

    /// Per-block values. ssh semantics: the first obtained value wins, so
    /// repeated keys within one block keep the first occurrence.
    private struct BlockSettings {
        var hostname: String?
        var user: String?
        var port: Int?
        var identityFile: String?
    }

    /// Splits "Key value", "Key=value", or "Key = value" into a lowercased key
    /// and the raw value. Returns nil for lines with no value.
    static func splitKeyValue(_ line: String) -> (key: String, value: String)? {
        guard let separator = line.firstIndex(where: { $0 == "=" || $0 == " " || $0 == "\t" }) else {
            return nil
        }
        let key = line[..<separator].lowercased()
        var rest = line[line.index(after: separator)...]
        rest = rest.drop { $0 == " " || $0 == "\t" }
        if line[separator] != "=", rest.first == "=" {
            rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
        }
        let value = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return (key, value)
    }

    /// Splits a value on whitespace while honoring double quotes
    /// (`IdentityFile "~/.ssh/my key"`).
    static func tokenize(_ value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in value {
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            if !inQuotes, character == " " || character == "\t" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func firstToken(_ value: String) -> String? {
        tokenize(value).first
    }

    /// True for aliases that name exactly one host: no `*`/`?` wildcards and
    /// not a `!` negation.
    static func isConcreteAlias(_ alias: String) -> Bool {
        !alias.isEmpty
            && !alias.contains("*")
            && !alias.contains("?")
            && !alias.hasPrefix("!")
    }

    /// Expands a leading `~` or `~/` against `homeDirectory`. `~otheruser`
    /// paths are left untouched.
    static func expandTilde(_ path: String, homeDirectory: String) -> String {
        guard path.hasPrefix("~") else { return path }
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") {
            return homeDirectory + path.dropFirst(1)
        }
        return path
    }
}
