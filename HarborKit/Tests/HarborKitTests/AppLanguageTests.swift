import XCTest
@testable import HarborKit

final class AppLanguageTests: XCTestCase {
    func testStoredValueRoundTrips() {
        XCTAssertEqual(AppLanguage(storedValue: "system"), .system)
        XCTAssertEqual(AppLanguage(storedValue: "zh-Hans"), .zhHans)
        XCTAssertEqual(AppLanguage(storedValue: "en"), .english)
    }

    func testStoredValueFallsBackToSystem() {
        XCTAssertEqual(AppLanguage(storedValue: nil), .system)
        XCTAssertEqual(AppLanguage(storedValue: ""), .system)
        XCTAssertEqual(AppLanguage(storedValue: "klingon"), .system)
    }

    func testExplicitSelectionsIgnoreSystemPreference() {
        XCTAssertEqual(
            AppLanguage.zhHans.resolvedLanguageCode(preferredLanguages: ["en-US"]),
            "zh-Hans"
        )
        XCTAssertEqual(
            AppLanguage.english.resolvedLanguageCode(preferredLanguages: ["zh-Hans-CN"]),
            "en"
        )
    }

    func testSystemResolvesChineseInAnyRegionOrScript() {
        for code in ["zh-Hans-CN", "zh-Hant-TW", "zh", "zh-HK"] {
            XCTAssertEqual(
                AppLanguage.system.resolvedLanguageCode(preferredLanguages: [code]),
                "zh-Hans",
                "\(code) should resolve to zh-Hans"
            )
        }
    }

    func testSystemResolvesEnglishInAnyRegion() {
        for code in ["en", "en-US", "en-GB"] {
            XCTAssertEqual(
                AppLanguage.system.resolvedLanguageCode(preferredLanguages: [code]),
                "en",
                "\(code) should resolve to en"
            )
        }
    }

    func testSystemUsesFirstMatchingPreferredLanguage() {
        // French is unshipped: skip it and take the first shipped match.
        XCTAssertEqual(
            AppLanguage.system.resolvedLanguageCode(preferredLanguages: ["fr-FR", "zh-Hans-CN", "en"]),
            "zh-Hans"
        )
        XCTAssertEqual(
            AppLanguage.system.resolvedLanguageCode(preferredLanguages: ["fr-FR", "en-US", "zh-Hans"]),
            "en"
        )
    }

    func testSystemWithNoShippedMatchFallsBackToEnglish() {
        XCTAssertEqual(
            AppLanguage.system.resolvedLanguageCode(preferredLanguages: ["fr-FR", "de-DE"]),
            "en"
        )
    }

    func testSystemWithEmptyPreferencesFallsBackToDevelopmentLanguage() {
        XCTAssertEqual(
            AppLanguage.system.resolvedLanguageCode(preferredLanguages: []),
            "zh-Hans"
        )
    }

    func testSelectableOrderStartsWithSystem() {
        XCTAssertEqual(AppLanguage.selectable.first, .system)
        XCTAssertEqual(Set(AppLanguage.selectable), Set([.system, .zhHans, .english]))
    }

    func testBundleLanguageCodesCoverShippedCatalogs() {
        XCTAssertEqual(Set(AppLanguage.bundleLanguageCodes), Set(["zh-Hans", "en"]))
    }
}
