import AppKit
import SwiftUI
import HarborKit
import SwiftTerm

/// Bridges HarborKit's pure `TerminalTheme` data to AppKit / SwiftTerm.
extension TerminalTheme.RGB {
    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }

    var swiftUIColor: SwiftUI.Color {
        SwiftUI.Color(nsColor: nsColor)
    }

    /// SwiftTerm colors use 16-bit components; 257 maps 0xFF to 0xFFFF exactly.
    var terminalColor: SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16(red) * 257,
            green: UInt16(green) * 257,
            blue: UInt16(blue) * 257
        )
    }
}

extension TerminalView {
    /// Installs the theme's 16-color ANSI palette plus default fg/bg/cursor.
    /// Safe to call on a live terminal; SwiftTerm repaints existing content.
    func apply(theme: TerminalTheme) {
        installColors(theme.ansi.map(\.terminalColor))
        nativeBackgroundColor = theme.background.nsColor
        nativeForegroundColor = theme.foreground.nsColor
        caretColor = theme.cursor.nsColor
    }
}
