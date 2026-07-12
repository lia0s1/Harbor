import Foundation

/// A reusable shell script saved in the script library. Unlike a one-click
/// `QuickCommand`, a snippet holds a full (often multi-line) script, a
/// user-defined `category`, and named `{{name}}` placeholders that the UI
/// prompts for and `substitute(_:)` fills in before sending to a terminal.
///
/// Pure value type — persistence lives in the app layer (scripts.json) and is
/// handled by `ScriptStore`.
struct ScriptSnippet: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    /// Label shown in the list (falls back to the first line when empty).
    var title: String
    /// The script body, possibly multi-line, with `{{name}}` placeholders.
    var content: String
    /// User-defined category/folder used to bucket scripts. Empty = uncategorized.
    var category: String
    /// Placeholder names found in `content`. Kept in sync when the snippet is
    /// saved so the on-disk JSON is self-describing; the send flow always
    /// re-derives from `content` (see `detectedVariables`) so it never goes stale.
    var variables: [String]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        content: String = "",
        category: String = "",
        variables: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.category = category
        self.variables = variables
        self.createdAt = createdAt
    }

    // Tolerant decoding so hand-edited JSON with missing keys still loads
    // (mirrors QuickCommand / SSHHost): sensible defaults, never a decode failure
    // for a dropped optional field.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        variables = try c.decodeIfPresent([String].self, forKey: .variables) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    /// Label to show in UI: explicit title, else the first non-empty line of the
    /// script body.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return content.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    /// The `{{name}}` placeholder names in `content`, first-appearance order with
    /// duplicates removed. This — not the stored `variables` — is the source of
    /// truth for the substitution prompt, so a hand-edited body is never stale.
    var detectedVariables: [String] {
        ScriptSnippet.variables(in: content)
    }

    /// True when the body has at least one `{{name}}` placeholder to prompt for.
    var hasVariables: Bool { !detectedVariables.isEmpty }

    /// Fills the body's `{{name}}` placeholders from `values` and returns the
    /// final script to send. Placeholders missing from `values` become the empty
    /// string; everything else (incl. `${VAR}` and shell `{a,b}`) is preserved
    /// verbatim. No shell quoting is applied — the script is fed to an interactive
    /// shell exactly as written.
    func substitute(_ values: [String: String]) -> String {
        ScriptSnippet.substitute(in: content, values: values)
    }

    // MARK: - Pure placeholder engine ({{name}})

    /// Characters allowed inside a `{{name}}` token: ASCII letters/digits, `_`,
    /// `-`, and CJK ideographs (so 中文 variable names work). Mirrors
    /// `QuickCommand`'s single-brace engine, which this deliberately parallels.
    private static func isNameCharacter(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" || scalar == "-" { return true }
        if (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
            || (scalar >= "0" && scalar <= "9") {
            return true
        }
        if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF { return true }
        return false
    }

    /// Scans `template` and yields each `{{name}}` placeholder as (name, range of
    /// the whole `{{name}}` token). Empty `{{}}` and unterminated braces are left
    /// untouched.
    static func scan(_ template: String) -> [(name: String, range: Range<String.Index>)] {
        var result: [(String, Range<String.Index>)] = []
        let chars = Array(template)
        let scalars: [Unicode.Scalar] = chars.map { $0.unicodeScalars.first ?? " " }
        var i = 0
        while i < chars.count {
            if chars[i] == "{" && i + 1 < chars.count && chars[i + 1] == "{" {
                var j = i + 2
                while j < chars.count && isNameCharacter(scalars[j]) { j += 1 }
                // Require at least one name char and a closing "}}".
                if j > i + 2 && j + 1 < chars.count && chars[j] == "}" && chars[j + 1] == "}" {
                    let name = String(chars[(i + 2)..<j])
                    let start = template.index(template.startIndex, offsetBy: i)
                    let end = template.index(template.startIndex, offsetBy: j + 2)
                    result.append((name, start..<end))
                    i = j + 2
                    continue
                }
            }
            i += 1
        }
        return result
    }

    static func variables(in template: String) -> [String] {
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
