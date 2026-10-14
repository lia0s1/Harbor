import XCTest
@testable import HarborKit

final class OSLogoAssetTests: XCTestCase {
    func testEveryOSBrandIDHasALogoDecision() {
        // Every id OSBrand can emit must either map to a shipped asset or be a
        // deliberate fallback (macOS uses SF Symbols' apple.logo; oracle/amazon
        // wordmarks are unreadable at icon size).
        let brandIDs: [(pretty: String, uname: String, id: String)] = [
            ("Ubuntu 24.04 LTS", "Linux", "ubuntu"),
            ("Debian GNU/Linux 12", "Linux", "debian"),
            ("Fedora Linux 40", "Linux", "fedora"),
            ("Arch Linux", "Linux", "arch"),
            ("Alpine Linux v3.20", "Linux", "alpine"),
            ("Kali GNU/Linux Rolling", "Linux", "kali"),
            ("CentOS Stream 9", "Linux", "centos"),
            ("Rocky Linux 9.4", "Linux", "rocky"),
            ("AlmaLinux 9.4", "Linux", "alma"),
            ("Red Hat Enterprise Linux 9.4", "Linux", "rhel"),
            ("openSUSE Leap 15.6", "Linux", "suse"),
            ("Linux Mint 21.3", "Linux", "mint"),
            ("Manjaro Linux", "Linux", "manjaro"),
            ("Gentoo Linux", "Linux", "gentoo"),
            ("NixOS 24.05", "Linux", "nixos"),
            ("Void Linux", "Linux", "void"),
            ("Some Exotic Distro", "Linux", "linux"),
        ]
        for entry in brandIDs {
            let brand = OSBrand.classify(prettyName: entry.pretty, uname: entry.uname)
            XCTAssertEqual(brand?.id, entry.id, "OSBrand id drifted for \(entry.pretty)")
            if entry.id == "linux" {
                // Generic fallback still has the Tux logo.
                XCTAssertEqual(OSLogoAsset.assetName(for: entry.id), "os-linux")
            } else {
                XCTAssertNotNil(OSLogoAsset.assetName(for: entry.id),
                                "\(entry.id) lost its logo asset mapping")
            }
        }
    }

    func testAssetNameFormatAndCaseInsensitivity() {
        XCTAssertEqual(OSLogoAsset.assetName(for: "ubuntu"), "os-ubuntu")
        XCTAssertEqual(OSLogoAsset.assetName(for: "Ubuntu"), "os-ubuntu")
        XCTAssertEqual(OSLogoAsset.assetName(for: "windows"), "os-windows")
        XCTAssertEqual(OSLogoAsset.assetName(for: "freebsd"), "os-freebsd")
    }

    func testDeliberateFallbacksReturnNil() {
        // macOS renders via SF Symbols' apple.logo; oracle/amazon are wordmarks
        // that read as smears at icon sizes; nil/empty/unknown get nothing.
        XCTAssertNil(OSLogoAsset.assetName(for: "macos"))
        XCTAssertNil(OSLogoAsset.assetName(for: "oracle"))
        XCTAssertNil(OSLogoAsset.assetName(for: "amazon"))
        XCTAssertNil(OSLogoAsset.assetName(for: "plan9"))
        XCTAssertNil(OSLogoAsset.assetName(for: ""))
        XCTAssertNil(OSLogoAsset.assetName(for: nil))
    }

    func testAvailableSetMatchesShippedAssetNames() {
        // Pin the exact asset names so renaming an imageset without updating
        // the mapping (or vice versa) fails the build pipeline loudly.
        for id in OSLogoAsset.available {
            XCTAssertEqual(OSLogoAsset.assetName(for: id), "os-\(id)")
        }
        XCTAssertEqual(OSLogoAsset.available.count, 19)
    }
}
