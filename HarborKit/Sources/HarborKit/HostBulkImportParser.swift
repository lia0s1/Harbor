import Foundation

/// Parses pasted multi-line text into host import candidates.
///
/// Grammar per line: `[user@]host[:port] [optional display name]` — the first
/// whitespace-separated token is the connection target (parsed by
/// `QuickConnectParser`, so IPv6 brackets and injection rules apply), the
/// remainder becomes the display name. Blank lines and lines starting with
/// `#` are skipped. Input beyond `maxLines` is not parsed, only counted.
///
/// Duplicates are detected against the existing store (by hostname+port,
/// case-insensitive — the same rule as the editor's duplicate warning) and
/// within the batch itself (the first occurrence wins).
public enum HostBulkImportParser {
    /// Hard cap on parsed lines; anything beyond is reported as overflow.
    public static let maxLines = 1000
    /// Display-name cap, generous but bounded so a pasted blob can't explode
    /// the sidebar row layout.
    public static let maxNameLength = 100

    /// Machine-readable failure reason; the UI maps these to localized text.
    public enum Failure: Equatable, Sendable {
        case invalidHost(String)
        case invalidUser(String)
        case invalidPort(String)
        case nameTooLong
        case invalidName
    }

    public enum Status: Equatable, Sendable {
        /// Parsed and not a duplicate — ready to import.
        case ok
        /// Blank line or `#` comment.
        case skipped
        /// hostname+port matches a host already in the store.
        case duplicateExisting
        /// hostname+port matches an earlier accepted line in this batch.
        case duplicateBatch
        case invalid(Failure)
    }

    public struct Line: Identifiable, Equatable, Sendable {
        /// 1-based line number in the source text.
        public let lineNumber: Int
        public let raw: String
        /// The parsed host (name applied) when `status == .ok`.
        public var host: SSHHost?
        public var status: Status

        public var id: Int { lineNumber }
    }

    public struct Result: Equatable, Sendable {
        /// One entry per parsed line (at most `maxLines`).
        public var lines: [Line]
        /// Lines beyond `maxLines`, counted but not parsed.
        public var overflowLines: Int

        public init(lines: [Line], overflowLines: Int) {
            self.lines = lines
            self.overflowLines = overflowLines
        }

        public var okCount: Int { lines.filter { $0.status == .ok }.count }
        public var duplicateCount: Int {
            lines.filter { $0.status == .duplicateExisting || $0.status == .duplicateBatch }.count
        }
        public var invalidCount: Int {
            lines.filter {
                if case .invalid = $0.status { return true }
                return false
            }.count
        }

        /// Hosts ready to insert, in source order.
        public var acceptedHosts: [SSHHost] {
            lines.compactMap { $0.status == .ok ? $0.host : nil }
        }
    }

    public static func parse(_ text: String, existing: [SSHHost]) -> Result {
        let existingKeys = Set(existing.map { connectionKey(hostname: $0.hostname, port: $0.port) })
        var batchKeys = Set<String>()
        var lines: [Line] = []
        var overflow = 0

        // `isNewline` splits on the CRLF grapheme cluster as ONE break — a
        // Character-based "\n" separator never matches inside "\r\n".
        let rawLines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        for (index, rawLine) in rawLines.enumerated() {
            let lineNumber = index + 1
            guard lineNumber <= maxLines else {
                overflow = rawLines.count - maxLines
                break
            }
            let raw = String(rawLine)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                lines.append(Line(lineNumber: lineNumber, raw: raw, host: nil, status: .skipped))
                continue
            }

            // First whitespace-separated token is the target; the rest is the
            // optional display name.
            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            let target = String(parts[0])
            let name = parts.count > 1
                ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""

            let host: SSHHost
            do {
                host = try QuickConnectParser.parse(target)
            } catch let error as QuickConnectError {
                let failure: Failure
                switch error {
                case .empty: failure = .invalidHost(target)
                case .invalidHost(let value): failure = .invalidHost(value)
                case .invalidUser(let value): failure = .invalidUser(value)
                case .invalidPort(let value): failure = .invalidPort(value)
                }
                lines.append(Line(lineNumber: lineNumber, raw: raw, host: nil, status: .invalid(failure)))
                continue
            } catch {
                lines.append(Line(lineNumber: lineNumber, raw: raw, host: nil,
                                  status: .invalid(.invalidHost(target))))
                continue
            }

            var candidate = host
            if !name.isEmpty {
                guard name.count <= maxNameLength else {
                    lines.append(Line(lineNumber: lineNumber, raw: raw, host: nil, status: .invalid(.nameTooLong)))
                    continue
                }
                guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    lines.append(Line(lineNumber: lineNumber, raw: raw, host: nil, status: .invalid(.invalidName)))
                    continue
                }
                candidate.name = name
            }

            let key = connectionKey(hostname: candidate.hostname, port: candidate.port)
            if batchKeys.contains(key) {
                lines.append(Line(lineNumber: lineNumber, raw: raw, host: candidate, status: .duplicateBatch))
            } else if existingKeys.contains(key) {
                lines.append(Line(lineNumber: lineNumber, raw: raw, host: candidate, status: .duplicateExisting))
            } else {
                batchKeys.insert(key)
                lines.append(Line(lineNumber: lineNumber, raw: raw, host: candidate, status: .ok))
            }
        }

        return Result(lines: lines, overflowLines: overflow)
    }

    /// Duplicate identity: hostname (case-insensitive) + port, matching the
    /// editor's duplicate warning.
    private static func connectionKey(hostname: String, port: Int) -> String {
        "\(hostname.lowercased()):\(port)"
    }
}
