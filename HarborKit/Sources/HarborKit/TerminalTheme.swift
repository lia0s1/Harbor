import Foundation

/// A terminal color scheme: the 16 ANSI palette entries plus default
/// foreground / background / cursor colors.
///
/// Pure data (8-bit sRGB components) so it stays testable and UI-framework
/// free; the app layer maps `RGB` to NSColor / SwiftTerm colors.
public struct TerminalTheme: Identifiable, Hashable, Sendable {
    /// One 8-bit sRGB color.
    public struct RGB: Hashable, Sendable {
        public let red: UInt8
        public let green: UInt8
        public let blue: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// 0xRRGGBB literal, e.g. `RGB(0x282A36)`.
        public init(_ hex: UInt32) {
            self.init(
                red: UInt8((hex >> 16) & 0xFF),
                green: UInt8((hex >> 8) & 0xFF),
                blue: UInt8(hex & 0xFF)
            )
        }
    }

    /// Stable identifier persisted in user defaults.
    public let id: String
    /// Display name shown in the theme picker.
    public let name: String
    /// Whether the background is dark (used for UI affordances, not rendering).
    public let isDark: Bool
    public let foreground: RGB
    public let background: RGB
    public let cursor: RGB
    /// Exactly 16 entries: ANSI 0–7 (normal) then 8–15 (bright).
    public let ansi: [RGB]

    public init(
        id: String,
        name: String,
        isDark: Bool,
        foreground: RGB,
        background: RGB,
        cursor: RGB,
        ansi: [RGB]
    ) {
        precondition(ansi.count == 16, "A terminal theme needs exactly 16 ANSI colors")
        self.id = id
        self.name = name
        self.isDark = isDark
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.ansi = ansi
    }

    // MARK: - Built-in themes

    public static let defaultThemeID = harborDark.id

    /// All built-in themes, in picker order. Harbor Dark is the default.
    public static let builtIn: [TerminalTheme] = [
        harborDark, solarizedDark, dracula, oneLight, paperWhite,
    ]

    /// Resolves a stored theme id, falling back to the default theme for
    /// unknown or stale ids (e.g. from an older build).
    public static func theme(withID id: String) -> TerminalTheme {
        builtIn.first { $0.id == id } ?? harborDark
    }

    public static let harborDark = TerminalTheme(
        id: "harbor-dark",
        name: "Harbor Dark",
        isDark: true,
        foreground: RGB(0xD8E2EC),
        background: RGB(0x10161F),
        cursor: RGB(0x4FB3D9),
        ansi: [
            RGB(0x232C3B), RGB(0xE05561), RGB(0x8CC265), RGB(0xD18F52),
            RGB(0x4AA5F0), RGB(0xC162DE), RGB(0x42B3C2), RGB(0xD7DAE0),
            RGB(0x546178), RGB(0xFF616E), RGB(0xA5E075), RGB(0xF0A45D),
            RGB(0x4DC4FF), RGB(0xDE73FF), RGB(0x4CD1E0), RGB(0xFFFFFF),
        ]
    )

    public static let solarizedDark = TerminalTheme(
        id: "solarized-dark",
        name: "Solarized Dark",
        isDark: true,
        foreground: RGB(0x839496),
        background: RGB(0x002B36),
        cursor: RGB(0x93A1A1),
        ansi: [
            RGB(0x073642), RGB(0xDC322F), RGB(0x859900), RGB(0xB58900),
            RGB(0x268BD2), RGB(0xD33682), RGB(0x2AA198), RGB(0xEEE8D5),
            RGB(0x002B36), RGB(0xCB4B16), RGB(0x586E75), RGB(0x657B83),
            RGB(0x839496), RGB(0x6C71C4), RGB(0x93A1A1), RGB(0xFDF6E3),
        ]
    )

    public static let dracula = TerminalTheme(
        id: "dracula",
        name: "Dracula",
        isDark: true,
        foreground: RGB(0xF8F8F2),
        background: RGB(0x282A36),
        cursor: RGB(0xF8F8F2),
        ansi: [
            RGB(0x21222C), RGB(0xFF5555), RGB(0x50FA7B), RGB(0xF1FA8C),
            RGB(0xBD93F9), RGB(0xFF79C6), RGB(0x8BE9FD), RGB(0xF8F8F2),
            RGB(0x6272A4), RGB(0xFF6E6E), RGB(0x69FF94), RGB(0xFFFFA5),
            RGB(0xD6ACFF), RGB(0xFF92DF), RGB(0xA4FFFF), RGB(0xFFFFFF),
        ]
    )

    public static let oneLight = TerminalTheme(
        id: "one-light",
        name: "One Light",
        isDark: false,
        foreground: RGB(0x383A42),
        background: RGB(0xFAFAFA),
        cursor: RGB(0x526FFF),
        ansi: [
            RGB(0x383A42), RGB(0xE45649), RGB(0x50A14F), RGB(0xC18401),
            RGB(0x0184BC), RGB(0xA626A4), RGB(0x0997B3), RGB(0xFAFAFA),
            RGB(0x696C77), RGB(0xE06C75), RGB(0x98C379), RGB(0xE5C07B),
            RGB(0x61AFEF), RGB(0xC678DD), RGB(0x56B6C2), RGB(0xFFFFFF),
        ]
    )

    /// Pure white background with black text — the cleanest light terminal,
    /// for users who want a plain paper look (independent of the app's
    /// light/dark appearance). The ANSI palette is darkened so colored output
    /// (git, ls, prompts) stays readable on white.
    public static let paperWhite = TerminalTheme(
        id: "paper-white",
        name: "纸白",
        isDark: false,
        foreground: RGB(0x000000),
        background: RGB(0xFFFFFF),
        cursor: RGB(0x000000),
        ansi: [
            RGB(0x000000), RGB(0xC8262C), RGB(0x1A8E1A), RGB(0xB08000),
            RGB(0x0A66C2), RGB(0x9C27B0), RGB(0x0E7C8A), RGB(0xAAAAAA),
            RGB(0x6E6E6E), RGB(0xE0474D), RGB(0x2FA82F), RGB(0xC79A0E),
            RGB(0x2D7FE0), RGB(0xBA68C8), RGB(0x1FA8A8), RGB(0xFFFFFF),
        ]
    )
}
