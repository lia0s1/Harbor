import XCTest
import CoreText
@testable import HarborKit

final class TerminalFontCascadeTests: XCTestCase {

    private let primaryName = "Menlo"
    private let cjkName = "PingFang SC" // ships with macOS

    func testNoCJKFontReturnsPlainBaseFont() {
        let font = TerminalFontCascade.makeFont(name: primaryName, size: 13, cjkName: nil)
        XCTAssertEqual(font.fontName, NSFont(name: primaryName, size: 13)?.fontName)
        XCTAssertTrue(TerminalFontCascade.cascadeSignature(of: font).isEmpty)

        let empty = TerminalFontCascade.makeFont(name: primaryName, size: 13, cjkName: "")
        XCTAssertTrue(TerminalFontCascade.cascadeSignature(of: empty).isEmpty)
    }

    func testUnknownCJKFontIsIgnored() {
        let font = TerminalFontCascade.makeFont(name: primaryName, size: 13, cjkName: "No Such Font Family")
        XCTAssertTrue(TerminalFontCascade.cascadeSignature(of: font).isEmpty)
    }

    func testCascadedFontPutsCJKFirst() {
        let font = TerminalFontCascade.makeFont(name: primaryName, size: 13, cjkName: cjkName)
        let cascade = font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor]
        XCTAssertNotNil(cascade)
        let firstName = cascade?.first?.object(forKey: .name) as? String ?? ""
        XCTAssertTrue(
            firstName.localizedCaseInsensitiveContains("PingFangSC"),
            "first cascade entry should be the CJK font, got \(firstName)"
        )
        // The cascaded font keeps the primary font's identity for metrics.
        XCTAssertEqual(font.pointSize, 13)
        XCTAssertEqual(TerminalFontCascade.cascadeSignature(of: font).isEmpty, false)
    }

    /// The acceptance criterion: a mixed ASCII+CJK attributed string shaped by
    /// CoreText uses the primary font for ASCII and the cascaded CJK font for
    /// 中文 — the exact mechanism both SwiftTerm render paths rely on.
    func testMixedStringShapingUsesCascadeFontForCJK() {
        let font = TerminalFontCascade.makeFont(name: primaryName, size: 13, cjkName: cjkName)
        let text = "ab中文cd"
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else {
            XCTFail("no glyph runs")
            return
        }

        var fontByCharacter: [Character: String] = [:]
        let nsText = text as NSString
        for run in runs {
            let range = CTRunGetStringRange(run)
            guard range.location != kCFNotFound, range.length > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any]
            let runFontName = ((attributes?[.font] as? NSFont) ?? font).fontName
            for index in range.location..<(range.location + range.length) {
                let character = Character(nsText.substring(with: NSRange(location: index, length: 1)))
                fontByCharacter[character] = runFontName
            }
        }

        for ascii in ["a", "b", "c", "d"].map(Character.init) {
            XCTAssertTrue(
                fontByCharacter[ascii]?.contains("Menlo") ?? false,
                "ASCII '\(ascii)' should render in Menlo, got \(fontByCharacter[ascii] ?? "nil")"
            )
        }
        for hanzi in ["中", "文"].map(Character.init) {
            let used = fontByCharacter[hanzi] ?? ""
            XCTAssertTrue(
                used.localizedCaseInsensitiveContains("PingFangSC"),
                "CJK '\(hanzi)' should render in \(cjkName), got \(used)"
            )
        }
    }

    /// SwiftTerm's FontSet derives bold/italic via NSFontManager; the cascade
    /// must survive that conversion or bold Chinese would lose the CJK font.
    func testCascadeSurvivesNSFontManagerTraitConversion() {
        let font = TerminalFontCascade.makeFont(name: primaryName, size: 13, cjkName: cjkName)
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        XCTAssertFalse(
            TerminalFontCascade.cascadeSignature(of: bold).isEmpty,
            "bold derivation must keep the cascade list"
        )
    }

    func testAvailableCJKFamiliesContainPingFangAndExcludeMenlo() {
        let families = TerminalFontCascade.availableCJKFamilies()
        XCTAssertTrue(families.contains("PingFang SC"))
        XCTAssertFalse(families.contains("Menlo"))
        XCTAssertFalse(families.contains { $0.hasPrefix(".") })
    }
}
