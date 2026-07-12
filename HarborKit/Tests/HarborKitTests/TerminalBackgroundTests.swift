import XCTest
@testable import HarborKit

final class TerminalBackgroundTests: XCTestCase {
    func testDefaultIsThemeMode() {
        XCTAssertEqual(TerminalBackground.default.mode, .theme)
        XCTAssertFalse(TerminalBackground.default.wantsImage)
        XCTAssertFalse(TerminalBackground.default.usesTranslucentTerminal)
    }

    func testRGBAHexInit() {
        let color = TerminalBackground.RGBA(0x336699)
        XCTAssertEqual(color.red, 0x33)
        XCTAssertEqual(color.green, 0x66)
        XCTAssertEqual(color.blue, 0x99)
        XCTAssertEqual(color.alpha, 255)
    }

    func testOpacityClampedInInitializer() {
        XCTAssertEqual(TerminalBackground(imageOpacity: -5).imageOpacity, TerminalBackground.opacityRange.lowerBound)
        XCTAssertEqual(TerminalBackground(imageOpacity: 99).imageOpacity, TerminalBackground.opacityRange.upperBound)
        XCTAssertEqual(TerminalBackground(imageOpacity: 0.5).imageOpacity, 0.5)
    }

    func testBlurClampedInInitializer() {
        XCTAssertEqual(TerminalBackground(imageBlur: -1).imageBlur, TerminalBackground.blurRange.lowerBound)
        XCTAssertEqual(TerminalBackground(imageBlur: 1000).imageBlur, TerminalBackground.blurRange.upperBound)
        XCTAssertEqual(TerminalBackground(imageBlur: 12).imageBlur, 12)
    }

    func testWantsImageRequiresPath() {
        XCTAssertFalse(TerminalBackground(mode: .image, imagePath: "").wantsImage)
        XCTAssertTrue(TerminalBackground(mode: .image, imagePath: "/tmp/x.png").wantsImage)
        // A path while NOT in image mode must not draw an image.
        XCTAssertFalse(TerminalBackground(mode: .color, imagePath: "/tmp/x.png").wantsImage)
    }

    func testTranslucentTerminalOnlyForActiveImage() {
        XCTAssertTrue(TerminalBackground(mode: .image, imagePath: "/a.png").usesTranslucentTerminal)
        XCTAssertFalse(TerminalBackground(mode: .color).usesTranslucentTerminal)
        XCTAssertFalse(TerminalBackground(mode: .theme).usesTranslucentTerminal)
    }

    func testRoundTripEncoding() {
        let original = TerminalBackground(
            mode: .image,
            color: TerminalBackground.RGBA(red: 10, green: 20, blue: 30, alpha: 200),
            imagePath: "/Users/test/bg.heic",
            imageOpacity: 0.55,
            imageBlur: 8
        )
        let encoded = original.encodedString()
        XCTAssertNotNil(encoded)
        let decoded = TerminalBackground.decoded(from: encoded)
        XCTAssertEqual(decoded, original)
    }

    func testForegroundPersistsInEveryMode() {
        // The custom text color applies independent of the background, so it
        // must round-trip in theme / color / image mode alike.
        let fg = TerminalBackground.RGBA(0xFF8800)
        for mode in TerminalBackground.Mode.allCases {
            let original = TerminalBackground(mode: mode, foreground: fg, imagePath: "/a.png")
            let decoded = TerminalBackground.decoded(from: original.encodedString())
            XCTAssertEqual(decoded.foreground, fg, "foreground lost in \(mode) mode")
            XCTAssertEqual(decoded.mode, mode)
        }
    }

    func testForegroundDefaultsToNil() {
        // Unset by default so existing setups keep the theme's own foreground.
        XCTAssertNil(TerminalBackground.default.foreground)
        XCTAssertNil(TerminalBackground(mode: .image, imagePath: "/a.png").foreground)
    }

    func testDecodeNilAndEmptyFallBackToDefault() {
        XCTAssertEqual(TerminalBackground.decoded(from: nil), .default)
        XCTAssertEqual(TerminalBackground.decoded(from: ""), .default)
    }

    func testDecodeCorruptFallsBackToDefault() {
        XCTAssertEqual(TerminalBackground.decoded(from: "{not json"), .default)
        XCTAssertEqual(TerminalBackground.decoded(from: "{\"mode\":\"bogus\"}"), .default)
    }

    func testDecodeToleratesOneBadFieldAndKeepsTheRest() {
        // A single malformed sub-field (here a corrupt color component) must NOT
        // discard the user's image path / opacity / blur. Per-field tolerance.
        let json = """
        {"mode":"image","color":{"red":"oops"},"imagePath":"/a.png",\
        "imageOpacity":0.6,"imageBlur":4.0}
        """
        let decoded = TerminalBackground.decoded(from: json)
        XCTAssertEqual(decoded.mode, .image)
        XCTAssertEqual(decoded.imagePath, "/a.png")
        XCTAssertEqual(decoded.imageOpacity, 0.6, accuracy: 0.0001)
        XCTAssertEqual(decoded.imageBlur, 4.0, accuracy: 0.0001)
        // The corrupt color fell back to the default rather than failing the lot.
        XCTAssertEqual(decoded.color, TerminalBackground.defaultColor)
    }

    func testDecodeReclampsOutOfRangeNumbers() {
        // Hand-craft JSON with an out-of-range opacity/blur the encoder would
        // never produce, to prove decode re-clamps.
        let json = """
        {"mode":"image","color":{"red":1,"green":2,"blue":3,"alpha":255},\
        "imagePath":"/a.png","imageOpacity":5.0,"imageBlur":-9.0}
        """
        let decoded = TerminalBackground.decoded(from: json)
        XCTAssertEqual(decoded.imageOpacity, TerminalBackground.opacityRange.upperBound)
        XCTAssertEqual(decoded.imageBlur, TerminalBackground.blurRange.lowerBound)
    }
}
