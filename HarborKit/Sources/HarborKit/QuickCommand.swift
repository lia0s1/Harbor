import Foundation

/// A saved one-click command (FinalShell's 命令 tab): a titled command template
/// that the user clicks to send to the terminal. Templates may contain ordered
/// `{name}` placeholders (e.g. `systemctl restart {service}`) which the UI
/// prompts for and `substitute(_:)` fills in.
///
/// Pure value type — persistence lives in the app layer (commands.json) and is
/// encoded/decoded by `QuickCommandStoreCodec`.
public struct QuickCommand: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Label shown in the list (falls back to the template when empty).
    public var title: String
    /// The command template, possibly containing `{name}` placeholders.
    public var command: String
    /// Optional folder/group used to bucket commands in the list. Empty = ungrouped.
    public var group: String

    public init(
        id: UUID = UUID(),
        title: String = "",
        command: String = "",
        group: String = ""
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.group = group
    }

    // Tolerant decoding so hand-edited JSON with missing keys still loads
    // (mirrors SSHHost): only sensible defaults, never a decode failure for a
    // dropped optional field.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
    }

    /// Label to show in UI: explicit title, else the command itself.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? command : trimmed
    }

    /// The placeholder names found in `command`, in first-appearance order with
    /// duplicates removed. A placeholder is `{name}` where `name` is a non-empty
    /// run of letters, digits, `_`, `-` or CJK — anything else (e.g. `${VAR}`,
    /// shell brace-expansion `{a,b}`, an empty `{}`) is left untouched.
    public var parameters: [String] {
        QuickCommand.parameters(in: command)
    }

    /// True when the template has at least one `{name}` placeholder to prompt for.
    public var hasParameters: Bool { !parameters.isEmpty }

    /// Fills the template's `{name}` placeholders from `values` and returns the
    /// final command to send. Placeholders missing from `values` are replaced
    /// with the empty string; un-placeholder text (incl. `${VAR}` and `{a,b}`)
    /// is preserved verbatim. Pure — no shell quoting is applied here so the
    /// command reads exactly as the user typed it (it is sent to an interactive
    /// shell, not embedded in a remote script).
    public func substitute(_ values: [String: String]) -> String {
        QuickCommand.substitute(in: command, values: values)
    }

    // MARK: - Pure placeholder engine

    /// Matches a single `{name}` token: an opening brace, a non-empty run of the
    /// allowed name characters, a closing brace. Deliberately rejects `{}`,
    /// `${...}` (the `$` is outside the token, so `{VAR}` inside `${VAR}` would
    /// match — guarded against in the scanner below), and `{a,b}` (comma is not
    /// an allowed name character).
    static func isNameCharacter(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" || scalar == "-" { return true }
        // ASCII letters / digits.
        if (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
            || (scalar >= "0" && scalar <= "9") {
            return true
        }
        // CJK unified ideographs (so 中文 placeholder names work).
        if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF { return true }
        return false
    }

    /// Scans `template` and yields each `{name}` placeholder as (name, range of
    /// the whole `{name}` token). A `{` immediately preceded by `$` is treated
    /// as shell `${VAR}` and skipped.
    static func scan(_ template: String) -> [(name: String, range: Range<String.Index>)] {
        var result: [(String, Range<String.Index>)] = []
        let chars = Array(template)
        let scalars: [Unicode.Scalar] = chars.map { $0.unicodeScalars.first ?? " " }
        var i = 0
        while i < chars.count {
            if chars[i] == "{" && (i == 0 || chars[i - 1] != "$") {
                var j = i + 1
                while j < chars.count && isNameCharacter(scalars[j]) {
                    j += 1
                }
                if j < chars.count && chars[j] == "}" && j > i + 1 {
                    let name = String(chars[(i + 1)..<j])
                    let start = template.index(template.startIndex, offsetBy: i)
                    let end = template.index(template.startIndex, offsetBy: j + 1)
                    result.append((name, start..<end))
                    i = j + 1
                    continue
                }
            }
            i += 1
        }
        return result
    }

    static func parameters(in template: String) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for hit in scan(template) where !seen.contains(hit.name) {
            seen.insert(hit.name)
            ordered.append(hit.name)
        }
        return ordered
    }

    static func substitute(in template: String, values: [String: String]) -> String {
        let hits = scan(template)
        guard !hits.isEmpty else { return template }
        var output = ""
        var cursor = template.startIndex
        for hit in hits {
            output += template[cursor..<hit.range.lowerBound]
            output += values[hit.name] ?? ""
            cursor = hit.range.upperBound
        }
        output += template[cursor...]
        return output
    }
}
