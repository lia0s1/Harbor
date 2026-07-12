import XCTest
@testable import HarborKit

final class TerminalThemeTests: XCTestCase {
    func testHexInitSplitsComponents() {
        let color = TerminalTheme.RGB(0x336699)
        XCTAssertEqual(color.red, 0x33)
        XCTAssertEqual(color.green, 0x66)
        XCTAssertEqual(color.blue, 0x99)
    }

    func testHexInitBoundaries() {
        let black = TerminalTheme.RGB(0x000000)
        XCTAssertEqual(black, TerminalTheme.RGB(red: 0, green: 0, blue: 0))
        let white = TerminalTheme.RGB(0xFFFFFF)
        XCTAssertEqual(white, TerminalTheme.RGB(red: 255, green: 255, blue: 255))
    }

    func testBuiltInThemesAreWellFormed() {
        XCTAssertEqual(TerminalTheme.builtIn.count, 5)
        for theme in TerminalTheme.builtIn {
            XCTAssertEqual(theme.ansi.count, 16, "\(theme.id) must have 16 ANSI colors")
            XCTAssertFalse(theme.id.isEmpty)
            XCTAssertFalse(theme.name.isEmpty)
        }
    }

    func testPaperWhiteIsPureWhiteOnBlack() {
        let paper = TerminalTheme.theme(withID: "paper-white")
        XCTAssertEqual(paper.id, "paper-white")
        XCTAssertFalse(paper.isDark)
        XCTAssertEqual(paper.background, TerminalTheme.RGB(0xFFFFFF)) // pure white
        XCTAssertEqual(paper.foreground, TerminalTheme.RGB(0x000000)) // black text
    }

    func testBuiltInThemeIDsAreUnique() {
        let ids = TerminalTheme.builtIn.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testDefaultThemeIsFirstBuiltIn() {
        XCTAssertEqual(TerminalTheme.defaultThemeID, "harbor-dark")
        XCTAssertEqual(TerminalTheme.builtIn.first?.id, TerminalTheme.defaultThemeID)
    }

    func testLookupByID() {
        XCTAssertEqual(TerminalTheme.theme(withID: "dracula").name, "Dracula")
        XCTAssertEqual(TerminalTheme.theme(withID: "one-light").isDark, false)
    }

    func testLookupFallsBackToDefaultForUnknownID() {
        XCTAssertEqual(TerminalTheme.theme(withID: "no-such-theme").id, TerminalTheme.defaultThemeID)
        // The pre-1.0 stored value was "default"; it must also resolve.
        XCTAssertEqual(TerminalTheme.theme(withID: "default").id, TerminalTheme.defaultThemeID)
    }
}
