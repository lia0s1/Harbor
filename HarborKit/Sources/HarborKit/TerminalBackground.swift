import Foundation

/// User customization of the terminal background, layered ON TOP of the chosen
/// `TerminalTheme`.
///
/// Pure data + clamping/encoding logic so it stays testable and UI-framework
/// free; the app layer maps it to NSColor / a background image layer behind the
/// SwiftTerm view.
///
/// Three modes:
/// - `.theme`   — use the theme's own background (the default; no override).
/// - `.color`   — paint a solid custom color behind the terminal.
/// - `.image`   — show a background image (path on disk) at a clamped opacity,
///                with an optional blur, behind a translucent terminal.
public struct TerminalBackground: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case theme
        case color
        case image
    }

    /// An 8-bit sRGB color with alpha, used for the custom solid color.
    public struct RGBA: Codable, Hashable, Sendable {
        public let red: UInt8
        public let green: UInt8
        public let blue: UInt8
        /// 0–255; usually 255 (opaque) for a solid background.
        public let alpha: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        /// 0xRRGGBB literal (fully opaque).
        public init(_ hex: UInt32) {
            self.init(
                red: UInt8((hex >> 16) & 0xFF),
                green: UInt8((hex >> 8) & 0xFF),
                blue: UInt8(hex & 0xFF)
            )
        }
    }

    public var mode: Mode
    /// Solid color for `.color` mode.
    public var color: RGBA
    /// Optional custom text (foreground) color, applied in EVERY mode (theme,
    /// color, image) independent of the background. `nil` keeps the active
    /// theme's foreground, so existing setups are unaffected.
    public var foreground: RGBA?
    /// Absolute path to the background image for `.image` mode. Empty when none
    /// has been chosen yet. The app must tolerate a path that no longer exists.
    public var imagePath: String
    /// Image opacity, clamped to `opacityRange`. Lower values let the theme
    /// background show through and keep glyphs readable.
    public var imageOpacity: Double
    /// Gaussian blur radius applied to the image, clamped to `blurRange`.
    public var imageBlur: Double

    public init(
        mode: Mode = .theme,
        color: RGBA = TerminalBackground.defaultColor,
        foreground: RGBA? = nil,
        imagePath: String = "",
        imageOpacity: Double = TerminalBackground.defaultOpacity,
        imageBlur: Double = 0
    ) {
        self.mode = mode
        self.color = color
        self.foreground = foreground
        self.imagePath = imagePath
        self.imageOpacity = TerminalBackground.clampOpacity(imageOpacity)
        self.imageBlur = TerminalBackground.clampBlur(imageBlur)
    }

    /// Tolerant decode: each field falls back independently (mirroring
    /// `SSHHost`/`QuickCommand`). Previously a single malformed sub-field — e.g.
    /// one bad RGBA component — made the whole `decode` throw, discarding the
    /// user's image path, opacity, blur and custom foreground together. Now a
    /// corrupt color is dropped to the default while the rest survives. Funnels
    /// through the designated initializer so numeric fields are re-clamped.
    /// (`encode(to:)` stays synthesized.)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? nil
        let color = (try? c.decodeIfPresent(RGBA.self, forKey: .color)) ?? nil
        let foreground = (try? c.decodeIfPresent(RGBA.self, forKey: .foreground)) ?? nil
        let imagePath = (try? c.decodeIfPresent(String.self, forKey: .imagePath)) ?? nil
        let imageOpacity = (try? c.decodeIfPresent(Double.self, forKey: .imageOpacity)) ?? nil
        let imageBlur = (try? c.decodeIfPresent(Double.self, forKey: .imageBlur)) ?? nil
        self.init(
            mode: mode ?? .theme,
            color: color ?? TerminalBackground.defaultColor,
            foreground: foreground,
            imagePath: imagePath ?? "",
            imageOpacity: imageOpacity ?? TerminalBackground.defaultOpacity,
            imageBlur: imageBlur ?? 0
        )
    }

    // MARK: - Defaults & ranges

    public static let `default` = TerminalBackground()

    /// A neutral dark slate, a sensible starting point for `.color` mode.
    public static let defaultColor = RGBA(0x12161D)

    /// Image opacity is clamped so the picture can never fully wash out the
    /// terminal text; even at max it stays slightly translucent.
    public static let opacityRange: ClosedRange<Double> = 0.15...1.0
    public static let defaultOpacity: Double = 0.4

    public static let blurRange: ClosedRange<Double> = 0.0...30.0

    public static func clampOpacity(_ value: Double) -> Double {
        value.clamped(to: opacityRange)
    }

    public static func clampBlur(_ value: Double) -> Double {
        value.clamped(to: blurRange)
    }

    // MARK: - Derived

    /// Whether an image should actually be drawn: `.image` mode AND a non-empty
    /// path. (Existence on disk is checked by the app layer, which falls back to
    /// the theme background when the file is missing.)
    public var wantsImage: Bool {
        mode == .image && !imagePath.isEmpty
    }

    /// Whether the terminal background should be made translucent so a layer
    /// behind it shows through (only in image mode with a path).
    public var usesTranslucentTerminal: Bool {
        wantsImage
    }

    // MARK: - JSON persistence

    /// JSON string suitable for storing in `@AppStorage` / `UserDefaults`.
    /// Returns `nil` only if encoding fails (it should not for this value type).
    public func encodedString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes a stored JSON string, tolerating `nil` / empty / corrupt input by
    /// returning the default (theme) background. Re-clamps numeric fields so a
    /// hand-edited or stale value can never push opacity/blur out of range.
    public static func decoded(from raw: String?) -> TerminalBackground {
        guard let raw, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(TerminalBackground.self, from: data)
        else {
            return .default
        }
        // Funnel through the initializer so clamping is reapplied.
        return TerminalBackground(
            mode: value.mode,
            color: value.color,
            foreground: value.foreground,
            imagePath: value.imagePath,
            imageOpacity: value.imageOpacity,
            imageBlur: value.imageBlur
        )
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
