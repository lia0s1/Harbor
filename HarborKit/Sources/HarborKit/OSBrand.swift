import Foundation

/// Classifies a host's operating system from its `/etc/os-release` PRETTY_NAME
/// (or `uname -s`) to a stable id + display name, so the sidebar can show a
/// per-distro badge. Pure data so it stays testable and UI-free.
public enum OSBrand {
    public struct Brand: Equatable, Sendable {
        public let id: String
        public let name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// Distro needles matched against a lowercased PRETTY_NAME, most-specific
    /// first. Returns the family id and a clean display name.
    private static let table: [(needle: String, id: String, name: String)] = [
        ("raspbian", "debian", "Raspberry Pi OS"),
        ("raspberry pi", "debian", "Raspberry Pi OS"),
        ("ubuntu", "ubuntu", "Ubuntu"),
        ("debian", "debian", "Debian"),
        ("linux mint", "mint", "Linux Mint"),
        ("centos", "centos", "CentOS"),
        ("rocky", "rocky", "Rocky Linux"),
        ("almalinux", "alma", "AlmaLinux"),
        ("oracle", "oracle", "Oracle Linux"),
        ("red hat", "rhel", "RHEL"),
        ("fedora", "fedora", "Fedora"),
        ("amazon", "amazon", "Amazon Linux"),
        ("manjaro", "manjaro", "Manjaro"),
        ("arch", "arch", "Arch Linux"),
        ("alpine", "alpine", "Alpine"),
        ("opensuse", "suse", "openSUSE"),
        ("suse", "suse", "SUSE"),
        ("kali", "kali", "Kali Linux"),
        ("gentoo", "gentoo", "Gentoo"),
        ("void", "void", "Void Linux"),
        ("nixos", "nixos", "NixOS"),
    ]

    /// Returns the detected brand, or nil when nothing useful is known.
    public static func classify(prettyName: String, uname: String) -> Brand? {
        let pretty = prettyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerPretty = pretty.lowercased()
        let lowerUname = uname.lowercased()

        for entry in table where lowerPretty.contains(entry.needle) {
            return Brand(id: entry.id, name: entry.name)
        }
        if lowerUname.contains("darwin") { return Brand(id: "macos", name: "macOS") }
        if !pretty.isEmpty { return Brand(id: "linux", name: pretty) }
        if lowerUname.contains("linux") { return Brand(id: "linux", name: "Linux") }
        return nil
    }
}
