import Foundation

/// Maps a detected OS id (`SSHHost.osID`, produced by `OSBrand`) to the real
/// logo image shipped in the app asset catalog (`os-<id>` imagesets, see
/// `App/Assets.xcassets/LOGO-CREDITS.md` for sources and licenses).
///
/// Pure data + one function so the mapping stays unit-testable and UI-free;
/// `App/UI/OSLogo.swift` and `HostAvatarView` both resolve through this.
public enum OSLogoAsset {
    /// Ids that have a real logo imageset in the catalog. Keep in sync with
    /// `App/Assets.xcassets/os-*.imageset` — the test suite pins this set so a
    /// renamed asset fails loudly instead of silently falling back.
    public static let available: Set<String> = [
        "ubuntu", "debian", "fedora", "arch", "alpine", "kali",
        "centos", "rocky", "alma", "rhel", "suse",
        "mint", "manjaro", "gentoo", "nixos", "void",
        "freebsd", "windows", "linux",
    ]

    /// Asset-catalog image name for an OS id, or nil when the id has no real
    /// logo (unknown distros, `macos` — which uses SF Symbols' `apple.logo` —
    /// and `oracle`/`amazon`, whose wordmarks are unreadable at icon size).
    public static func assetName(for osID: String?) -> String? {
        guard let osID, !osID.isEmpty else { return nil }
        let id = osID.lowercased()
        guard available.contains(id) else { return nil }
        return "os-\(id)"
    }
}
