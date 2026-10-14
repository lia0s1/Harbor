import Foundation

/// Codec for `.harbortheme` files — JSON color-scheme documents exchanged with
/// the user's `~/Library/Application Support/Harbor/Themes/` directory
/// (FinalShell-style shareable theme files).
///
/// Format (all fields optional unless noted):
/// ```json
/// {
///   "formatVersion": 1,
///   "id": "my-theme",                  // defaults to the file's base name
///   "name": "My Theme",                // defaults to the file's base name
///   "isDark": true,                    // defaults to background luminance
///   "background": "#10161F",
///   "foreground": "#D8E2EC",
///   "cursor": "#4FB3D9",
///   "selection": "#2C3A4E",
///   "ansi": ["#232C3B", ... 16 entries ...],
///   "backgroundOpacity": 0.85,         // 0–1, default 1 (opaque)
///   "backgroundBlur": 8                // 0–30, default 0 (off)
/// }
/// ```
///
/// Decoding is tolerant: a missing or malformed FIELD falls back to the
/// default theme's value and is reported in `TerminalThemeImport.warnings`;
/// the decode only throws when the file is not JSON, not an object, or it
/// explicitly sets `background`/`foreground` but neither parses (the user
/// tried to specify colors and got none).
public struct TerminalThemeImport: Sendable {
    public let theme: TerminalTheme
    /// Human-readable per-field problems encountered during a tolerant decode.
    public let warnings: [String]

    public init(theme: TerminalTheme, warnings: [String]) {
        self.theme = theme
        self.warnings = warnings
    }
}

/// Hard decode failures for `.harbortheme` payloads.
public enum TerminalThemeFileError: Error, Equatable {
    /// Payload is not valid JSON (or not a JSON object).
    case invalidJSON
    /// JSON parsed, but neither `background` nor `foreground` held a usable
    /// color, so there is no basis for a theme.
    case noUsableColors
    /// Encoded JSON could not be produced (should not happen for value types).
    case encodingFailed
}

extension TerminalTheme {

    private enum ThemeKey: String {
        case formatVersion, id, name, isDark
        case background, foreground, cursor, selection
        case ansi, backgroundOpacity, backgroundBlur
    }

    /// Decodes a `.harbortheme` document.
    ///
    /// - Parameter fallbackID: used for `id`/`name` when the file omits them
    ///   (the caller passes the file's base name).
    /// - Throws: `TerminalThemeFileError` for unusable payloads only.
    public static func decodeHarbortheme(
        _ data: Data,
        fallbackID: String
    ) throws -> TerminalThemeImport {
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw TerminalThemeFileError.invalidJSON
            }
            object = parsed
        } catch let error as TerminalThemeFileError {
            throw error
        } catch {
            throw TerminalThemeFileError.invalidJSON
        }

        var warnings: [String] = []
        let fallback = TerminalTheme.harborDark

        func string(_ key: ThemeKey) -> String? {
            object[key.rawValue] as? String
        }

        /// Tolerant per-field color decode: missing or malformed → default +
        /// warning. Whitespace-padded and "#"-less 6-hex forms are accepted.
        func color(_ key: ThemeKey, default defaultColor: RGB?) -> RGB? {
            guard let raw = object[key.rawValue] else { return defaultColor }
            guard let text = raw as? String, let parsed = RGB(harborthemeHex: text) else {
                warnings.append("\(key.rawValue): unrecognized color value; fell back to the default theme")
                return defaultColor
            }
            return parsed
        }

        let background = color(.background, default: nil)
        let foreground = color(.foreground, default: nil)
        // Throw only when the file TRIED to set colors and failed completely:
        // a key was present, yet neither background nor foreground parsed.
        // A file that simply omits colors gets the defaults like any other
        // missing field.
        let colorsAttempted = object[ThemeKey.background.rawValue] != nil
            || object[ThemeKey.foreground.rawValue] != nil
        if colorsAttempted && background == nil && foreground == nil {
            throw TerminalThemeFileError.noUsableColors
        }

        // ANSI palette: present entries are validated positionally; a short
        // list pads with the default theme, a long list truncates (the theme
        // initializer also normalizes, this just keeps the warnings precise).
        var ansi = fallback.ansi
        if let rawANSI = object[ThemeKey.ansi.rawValue] {
            if let list = rawANSI as? [Any] {
                if list.count != 16 {
                    warnings.append("ansi: expected 16 colors, got \(list.count); padded/truncated using the default theme")
                }
                for index in 0..<min(list.count, 16) {
                    if let entry = list[index] as? String,
                       let parsed = RGB(harborthemeHex: entry) {
                        ansi[index] = parsed
                    } else {
                        warnings.append("ansi[\(index)]: unrecognized color value; fell back to the default theme")
                    }
                }
            } else {
                warnings.append("ansi: expected an array of 16 hex colors; fell back to the default theme")
            }
        }

        func clampedNumber(_ key: ThemeKey, range: ClosedRange<Double>, default defaultValue: Double) -> Double {
            guard let raw = object[key.rawValue] else { return defaultValue }
            guard let number = raw as? NSNumber else {
                warnings.append("\(key.rawValue): expected a number; fell back to the default")
                return defaultValue
            }
            return min(max(number.doubleValue, range.lowerBound), range.upperBound)
        }

        let opacity = clampedNumber(.backgroundOpacity, range: 0.0...1.0, default: 1.0)
        // Matches TerminalBackground.blurRange.
        let blur = clampedNumber(.backgroundBlur, range: 0.0...30.0, default: 0.0)

        let id: String = {
            let explicit = string(.id)?.trimmingCharacters(in: .whitespaces) ?? ""
            return explicit.isEmpty ? fallbackID : explicit
        }()
        let name: String = {
            let explicit = string(.name)?.trimmingCharacters(in: .whitespaces) ?? ""
            return explicit.isEmpty ? id : explicit
        }()

        let resolvedBackground = background ?? fallback.background
        let isDark: Bool = {
            if let flag = object[ThemeKey.isDark.rawValue] as? Bool { return flag }
            return !resolvedBackground.prefersDarkText
        }()

        let theme = TerminalTheme(
            id: id,
            name: name,
            isDark: isDark,
            foreground: foreground ?? fallback.foreground,
            background: resolvedBackground,
            cursor: color(.cursor, default: fallback.cursor) ?? fallback.cursor,
            selection: color(.selection, default: fallback.selection),
            ansi: ansi,
            backgroundOpacity: opacity,
            backgroundBlur: blur
        )
        return TerminalThemeImport(theme: theme, warnings: warnings)
    }

    /// Encodes the theme as a `.harbortheme` JSON document (pretty-printed,
    /// stable key order) suitable for saving or sharing.
    public func encodeHarbortheme() throws -> Data {
        var object: [String: Any] = [
            ThemeKey.formatVersion.rawValue: 1,
            ThemeKey.id.rawValue: id,
            ThemeKey.name.rawValue: name,
            ThemeKey.isDark.rawValue: isDark,
            ThemeKey.background.rawValue: background.harborthemeHex,
            ThemeKey.foreground.rawValue: foreground.harborthemeHex,
            ThemeKey.cursor.rawValue: cursor.harborthemeHex,
            ThemeKey.ansi.rawValue: ansi.map(\.harborthemeHex),
        ]
        if let selection {
            object[ThemeKey.selection.rawValue] = selection.harborthemeHex
        }
        if backgroundOpacity < 1.0 {
            object[ThemeKey.backgroundOpacity.rawValue] = backgroundOpacity
        }
        if backgroundBlur > 0.0 {
            object[ThemeKey.backgroundBlur.rawValue] = backgroundBlur
        }
        do {
            return try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw TerminalThemeFileError.encodingFailed
        }
    }
}

extension TerminalTheme.RGB {

    /// Parses `#RRGGBB` / `RRGGBB` (case-insensitive, surrounding whitespace
    /// tolerated). Returns nil for anything else.
    public init?(harborthemeHex raw: String) {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, text.allSatisfy(\.isHexDigit) else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: text).scanHexInt64(&value) else { return nil }
        self.init(UInt32(value))
    }

    /// `#RRGGBB` uppercase — the canonical on-disk form.
    public var harborthemeHex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// Rough relative luminance used to default `isDark` for theme files that
    /// omit it: light backgrounds prefer dark text (isDark == false).
    var prefersDarkText: Bool {
        let luminance = 0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
        return luminance > 140
    }
}
