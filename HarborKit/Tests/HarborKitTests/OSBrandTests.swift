import XCTest
@testable import HarborKit

final class OSBrandTests: XCTestCase {

    private func id(_ pretty: String, uname: String = "Linux") -> String? {
        OSBrand.classify(prettyName: pretty, uname: uname)?.id
    }

    func testUbuntuBeatsDebian() {
        // PRETTY_NAME for Ubuntu does not contain "debian", but order matters
        // generally; Ubuntu must resolve to its own brand.
        let brand = OSBrand.classify(prettyName: "Ubuntu 22.04.3 LTS", uname: "Linux")
        XCTAssertEqual(brand?.id, "ubuntu")
        XCTAssertEqual(brand?.name, "Ubuntu")
    }

    func testRaspbianBeatsDebian() {
        // Raspbian/Raspberry Pi OS strings contain neither "ubuntu"; they are
        // matched before the generic "debian" needle.
        XCTAssertEqual(id("Raspbian GNU/Linux 11 (bullseye)"), "debian")
        XCTAssertEqual(
            OSBrand.classify(prettyName: "Raspberry Pi OS", uname: "Linux")?.name,
            "Raspberry Pi OS"
        )
    }

    func testDebianStillMatches() {
        let brand = OSBrand.classify(prettyName: "Debian GNU/Linux 12 (bookworm)", uname: "Linux")
        XCTAssertEqual(brand?.id, "debian")
        XCTAssertEqual(brand?.name, "Debian")
    }

    func testRedHatBeatsFedora() {
        // "Red Hat" is listed before "fedora"; an RHEL PRETTY_NAME must not be
        // mis-tagged as Fedora.
        XCTAssertEqual(id("Red Hat Enterprise Linux 9.2 (Plow)"), "rhel")
        XCTAssertEqual(id("Fedora Linux 39 (Workstation Edition)"), "fedora")
    }

    func testManjaroBeatsArch() {
        XCTAssertEqual(id("Manjaro Linux"), "manjaro")
        XCTAssertEqual(id("Arch Linux"), "arch")
    }

    func testOpenSUSEBeatsSUSE() {
        XCTAssertEqual(id("openSUSE Tumbleweed"), "suse")
        XCTAssertEqual(
            OSBrand.classify(prettyName: "openSUSE Leap 15.5", uname: "Linux")?.name,
            "openSUSE"
        )
        XCTAssertEqual(
            OSBrand.classify(prettyName: "SUSE Linux Enterprise Server 15", uname: "Linux")?.name,
            "SUSE"
        )
    }

    func testMatchingIsCaseInsensitiveAndTrimmed() {
        XCTAssertEqual(id("  UBUNTU 20.04  "), "ubuntu")
        XCTAssertEqual(
            OSBrand.classify(prettyName: "  Ubuntu  ", uname: "Linux")?.name,
            "Ubuntu"
        )
    }

    func testDarwinUnameMapsToMacOS() {
        let brand = OSBrand.classify(prettyName: "", uname: "Darwin")
        XCTAssertEqual(brand?.id, "macos")
        XCTAssertEqual(brand?.name, "macOS")
    }

    func testUnknownPrettyNameFallsBackToGenericLinuxWithRawName() {
        // A non-empty PRETTY_NAME with no table match keeps the id "linux" but
        // surfaces the raw (trimmed) name for the badge tooltip.
        let brand = OSBrand.classify(prettyName: "ExoticDistro 1.0", uname: "Linux")
        XCTAssertEqual(brand?.id, "linux")
        XCTAssertEqual(brand?.name, "ExoticDistro 1.0")
    }

    func testEmptyPrettyNameWithLinuxUnameFallsBack() {
        let brand = OSBrand.classify(prettyName: "", uname: "Linux")
        XCTAssertEqual(brand?.id, "linux")
        XCTAssertEqual(brand?.name, "Linux")
    }

    func testNilWhenNothingKnown() {
        XCTAssertNil(OSBrand.classify(prettyName: "", uname: ""))
        XCTAssertNil(OSBrand.classify(prettyName: "   ", uname: "   "))
    }
}
