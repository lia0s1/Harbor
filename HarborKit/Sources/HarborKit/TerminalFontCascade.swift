#if canImport(AppKit)
import AppKit

/// Split-font support (FinalShell-style en_font_name / cn_font_name): the
/// primary monospaced font renders ASCII, and a user-chosen Chinese font sits
/// FIRST in the descriptor cascade list so CJK glyphs fall back to it ahead of
/// the system fallback fonts.
///
/// Both SwiftTerm render paths honor the cascade: the CoreGraphics path draws
/// attributed strings through CoreText, and the Metal path shapes text with
/// `CTLineCreateWithAttributedString`, whose per-run fonts carry the
/// substitution.
///
/// Note: a cascade only engages for glyphs the PRIMARY font does not cover.
/// Menlo/SF Mono/etc. have no CJK ideographs, so Chinese always cascades;
/// with a CJK-covering primary (e.g. Sarasa) the primary keeps those glyphs.
public enum TerminalFontCascade {

    /// Builds the terminal font: `name`/`size` for primary glyphs, `cjkName`
    /// prepended to the descriptor cascade list for the rest. An empty/missing
    /// `cjkName` (or an uninstalled font) returns the plain base font.
    public static func makeFont(name: String, size: CGFloat, cjkName: String?) -> NSFont {
        let base = NSFont(name: name, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        guard let cjkName, !cjkName.isEmpty,
              let cjk = NSFont(name: cjkName, size: size) else {
            return base
        }
        // Keep any cascade the base descriptor already had (system fonts ship
        // one), with the user's CJK choice first and duplicates removed.
        let existing = (base.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor]) ?? []
        let cjkDescriptor = cjk.fontDescriptor
        let merged = [cjkDescriptor] + existing.filter {
            ($0.object(forKey: .name) as? String) != (cjkDescriptor.object(forKey: .name) as? String)
        }
        let descriptor = base.fontDescriptor.addingAttributes([
            .cascadeList: merged
        ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// PostScript names the given font's cascade list begins with — used by
    /// render caches that need to change identity when only the CJK fallback
    /// changed (same primary name/size).
    public static func cascadeSignature(of font: NSFont) -> String {
        let list = (font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor]) ?? []
        return list
            .compactMap { $0.object(forKey: .name) as? String }
            .joined(separator: ",")
    }

    /// Installed font families that cover CJK unified ideographs (tested with
    /// U+4E2D 中). The Settings 中文字体 picker lists these.
    public static func availableCJKFamilies() -> [String] {
        let manager = NSFontManager.shared
        let probe = CharacterSet(charactersIn: "\u{4E2D}")
        return manager.availableFontFamilies
            .filter { family in
                guard !family.hasPrefix(".") else { return false }
                guard let members = manager.availableMembers(ofFontFamily: family),
                      let faceName = members.first?.first as? String,
                      let font = NSFont(name: faceName, size: 12)
                else { return false }
                return font.coveredCharacterSet.isSuperset(of: probe)
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
#endif
