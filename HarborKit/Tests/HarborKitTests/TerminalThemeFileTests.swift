import XCTest
@testable import HarborKit

final class TerminalThemeFileTests: XCTestCase {

    override func tearDown() {
        // The file-theme registry is process-wide; never leak registrations
        // into other test cases.
        TerminalTheme.registerFileThemes([])
        super.tearDown()
    }

    private func json(_ body: String) -> Data {
        Data("{ \(body) }".utf8)
    }

    // MARK: - Happy path

    func testDecodeFullDocument() throws {
        let data = json("""
            "formatVersion": 1,
            "id": "nightly",
            "name": "Nightly",
            "isDark": true,
            "background": "#0B0E14",
            "foreground": "#B3B1AD",
            "cursor": "#E6B450",
            "selection": "#273747",
            "backgroundOpacity": 0.85,
            "backgroundBlur": 12,
            "ansi": ["#01060E","#EA6C73","#91B362","#F9AF4F",
                     "#53BDFA","#FAE994","#90E1C6","#C7C7C7",
                     "#686868","#F07178","#C2D94C","#FFB454",
                     "#59C2FF","#FFEE99","#95E6CB","#FFFFFF"]
            """)
        let result = try TerminalTheme.decodeHarbortheme(data, fallbackID: "ignored")
        XCTAssertEqual(result.theme.id, "nightly")
        XCTAssertEqual(result.theme.name, "Nightly")
        XCTAssertTrue(result.theme.isDark)
        XCTAssertEqual(result.theme.background, TerminalTheme.RGB(0x0B0E14))
        XCTAssertEqual(result.theme.foreground, TerminalTheme.RGB(0xB3B1AD))
        XCTAssertEqual(result.theme.cursor, TerminalTheme.RGB(0xE6B450))
        XCTAssertEqual(result.theme.selection, TerminalTheme.RGB(0x273747))
        XCTAssertEqual(result.theme.backgroundOpacity, 0.85, accuracy: 0.0001)
        XCTAssertEqual(result.theme.backgroundBlur, 12, accuracy: 0.0001)
        XCTAssertEqual(result.theme.ansi.count, 16)
        XCTAssertEqual(result.theme.ansi[1], TerminalTheme.RGB(0xEA6C73))
        XCTAssertEqual(result.theme.ansi[15], TerminalTheme.RGB(0xFFFFFF))
        XCTAssertTrue(result.warnings.isEmpty)
    }

    // MARK: - Tolerance

    func testMissingFieldsFallBackToDefaults() throws {
        let result = try TerminalTheme.decodeHarbortheme(json(""), fallbackID: "bare")
        XCTAssertEqual(result.theme.id, "bare")
        XCTAssertEqual(result.theme.name, "bare")
        // Colors come from the default theme.
        XCTAssertEqual(result.theme.background, TerminalTheme.harborDark.background)
        XCTAssertEqual(result.theme.foreground, TerminalTheme.harborDark.foreground)
        XCTAssertEqual(result.theme.ansi, TerminalTheme.harborDark.ansi)
        XCTAssertEqual(result.theme.backgroundOpacity, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.theme.backgroundBlur, 0.0, accuracy: 0.0001)
    }

    func testMalformedColorFallsBackWithWarning() throws {
        let result = try TerminalTheme.decodeHarbortheme(
            json("""
                "background": "not-a-color",
                "foreground": "#A1B2C3",
                "cursor": "12"
                """),
            fallbackID: "x"
        )
        XCTAssertEqual(result.theme.background, TerminalTheme.harborDark.background)
        XCTAssertEqual(result.theme.foreground, TerminalTheme.RGB(0xA1B2C3))
        XCTAssertEqual(result.theme.cursor, TerminalTheme.harborDark.cursor)
        XCTAssertEqual(result.warnings.count, 2)
        XCTAssertTrue(result.warnings.contains { $0.hasPrefix("background:") })
        XCTAssertTrue(result.warnings.contains { $0.hasPrefix("cursor:") })
    }

    func testANSIShortListPadsAndWarns() throws {
        let result = try TerminalTheme.decodeHarbortheme(
            json("""
                "background": "#000000",
                "ansi": ["#111111", "#222222"]
                """),
            fallbackID: "x"
        )
        XCTAssertEqual(result.theme.ansi[0], TerminalTheme.RGB(0x111111))
        XCTAssertEqual(result.theme.ansi[1], TerminalTheme.RGB(0x222222))
        // Padding comes from the default theme.
        XCTAssertEqual(result.theme.ansi[2], TerminalTheme.harborDark.ansi[2])
        XCTAssertTrue(result.warnings.contains { $0.hasPrefix("ansi:") })
    }

    func testANSINonArrayFallsBack() throws {
        let result = try TerminalTheme.decodeHarbortheme(
            json("""
                "background": "#000000",
                "ansi": "red"
                """),
            fallbackID: "x"
        )
        XCTAssertEqual(result.theme.ansi, TerminalTheme.harborDark.ansi)
        XCTAssertTrue(result.warnings.contains { $0.hasPrefix("ansi:") })
    }

    func testOpacityAndBlurAreClamped() throws {
        let result = try TerminalTheme.decodeHarbortheme(
            json("""
                "background": "#000000",
                "backgroundOpacity": 4.0,
                "backgroundBlur": 500
                """),
            fallbackID: "x"
        )
        XCTAssertEqual(result.theme.backgroundOpacity, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.theme.backgroundBlur, 30.0, accuracy: 0.0001)
    }

    func testIsDarkInferredFromBackgroundWhenOmitted() throws {
        let dark = try TerminalTheme.decodeHarbortheme(json("\"background\": \"#101010\""), fallbackID: "d")
        XCTAssertTrue(dark.theme.isDark)
        let light = try TerminalTheme.decodeHarbortheme(json("\"background\": \"#FAFAFA\""), fallbackID: "l")
        XCTAssertFalse(light.theme.isDark)
    }

    func testHexAcceptsHashlessAndLowercaseAndWhitespace() throws {
        let result = try TerminalTheme.decodeHarbortheme(
            json("\"background\": \"  ff00aa \""),
            fallbackID: "x"
        )
        XCTAssertEqual(result.theme.background, TerminalTheme.RGB(0xFF00AA))
    }

    // MARK: - Hard failures

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try TerminalTheme.decodeHarbortheme(Data("nope".utf8), fallbackID: "x")) { error in
            XCTAssertEqual(error as? TerminalThemeFileError, .invalidJSON)
        }
    }

    func testNonObjectJSONThrows() {
        XCTAssertThrowsError(try TerminalTheme.decodeHarbortheme(Data("[1,2]".utf8), fallbackID: "x")) { error in
            XCTAssertEqual(error as? TerminalThemeFileError, .invalidJSON)
        }
    }

    func testNoUsableColorsThrows() {
        XCTAssertThrowsError(try TerminalTheme.decodeHarbortheme(
            json(#""background": "zzzzzz", "foreground": 42"#),
            fallbackID: "x"
        )) { error in
            XCTAssertEqual(error as? TerminalThemeFileError, .noUsableColors)
        }
    }

    // MARK: - Round trips

    func testEncodeDecodeRoundTrip() throws {
        let original = TerminalTheme(
            id: "roundtrip",
            name: "Round Trip",
            isDark: false,
            foreground: TerminalTheme.RGB(0x111111),
            background: TerminalTheme.RGB(0xEEEEEE),
            cursor: TerminalTheme.RGB(0x222222),
            selection: TerminalTheme.RGB(0x333333),
            ansi: (0..<16).map { TerminalTheme.RGB(red: UInt8($0 * 16), green: 1, blue: 2) },
            backgroundOpacity: 0.5,
            backgroundBlur: 4
        )
        let data = try original.encodeHarbortheme()
        let decoded = try TerminalTheme.decodeHarbortheme(data, fallbackID: "ignored").theme
        XCTAssertEqual(decoded, original)
    }

    func testEncodeOmitsOptionalDefaults() throws {
        let data = try TerminalTheme.harborDark.encodeHarbortheme()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("backgroundOpacity"))
        XCTAssertFalse(text.contains("backgroundBlur"))
        XCTAssertTrue(text.contains("\"selection\"")) // built-ins carry one
    }

    func testBuiltInThemesSurviveTheFileCodec() throws {
        // The built-ins and file themes share one structure: every built-in
        // must encode to .harbortheme and decode back to an equal value.
        for theme in TerminalTheme.builtIn {
            let data = try theme.encodeHarbortheme()
            let decoded = try TerminalTheme.decodeHarbortheme(data, fallbackID: theme.id).theme
            XCTAssertEqual(decoded, theme, "\(theme.id) must round-trip through the file codec")
        }
    }

    // MARK: - Registry

    func testRegistryLookupFindsFileThemes() throws {
        let fileTheme = TerminalTheme(
            id: "from-file", name: "From File", isDark: true,
            foreground: TerminalTheme.RGB(0xFFFFFF), background: TerminalTheme.RGB(0x000000),
            cursor: TerminalTheme.RGB(0xFFFFFF),
            ansi: TerminalTheme.harborDark.ansi
        )
        TerminalTheme.registerFileThemes([fileTheme])
        XCTAssertEqual(TerminalTheme.theme(withID: "from-file"), fileTheme)
        XCTAssertEqual(TerminalTheme.fileThemes, [fileTheme])
        XCTAssertEqual(TerminalTheme.allThemes.count, TerminalTheme.builtIn.count + 1)
    }

    func testBuiltInWinsIDCollision() {
        let impostor = TerminalTheme(
            id: TerminalTheme.harborDark.id, name: "Impostor", isDark: false,
            foreground: TerminalTheme.RGB(0x000000), background: TerminalTheme.RGB(0xFFFFFF),
            cursor: TerminalTheme.RGB(0x000000),
            ansi: TerminalTheme.harborDark.ansi
        )
        TerminalTheme.registerFileThemes([impostor])
        XCTAssertEqual(TerminalTheme.theme(withID: TerminalTheme.harborDark.id), TerminalTheme.harborDark)
    }

    func testUnknownIDStillFallsBackToDefault() {
        TerminalTheme.registerFileThemes([])
        XCTAssertEqual(TerminalTheme.theme(withID: "no-such-theme").id, TerminalTheme.defaultThemeID)
    }
}
