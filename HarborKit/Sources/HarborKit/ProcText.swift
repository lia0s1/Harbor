import Foundation

/// Shared low-level helpers for the multi-section `/proc`-derived payloads that
/// both `MonitorParsers` and `SystemInfoParser` consume. Kept in one place so
/// the two parsers cannot drift — e.g. adding a pseudo-filesystem to skip, or
/// hardening the section split, now happens once instead of in two copies.
enum ProcText {
    /// Splits a payload into sections on lines equal to `separator`.
    static func splitSections(_ payload: String, separator: String) -> [String] {
        var sections: [[Substring]] = [[]]
        for line in payload.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == separator {
                sections.append([])
            } else {
                sections[sections.count - 1].append(line)
            }
        }
        return sections.map { $0.joined(separator: "\n") }
    }

    /// Pseudo-filesystem device names that are noise in a disk table.
    static let skippedDFDevices: Set<String> = [
        "tmpfs", "devtmpfs", "udev", "overlay", "overlayfs", "squashfs",
        "none", "shm", "devfs", "rootfs", "map",
    ]
    static let skippedMountPrefixes = ["/proc", "/sys", "/run", "/dev/", "/snap"]

    /// Whether a `df` row for `device` mounted at `mount` is a real filesystem
    /// worth showing (filters tmpfs/overlay/loop pseudo-mounts and /proc-ish
    /// mount points). Mount-point dedup is left to the caller, which is stateful.
    static func isRealFilesystem(device: String, mount: String) -> Bool {
        !skippedDFDevices.contains(device)
            && !device.hasPrefix("/dev/loop")
            && mount != "/dev"
            && !skippedMountPrefixes.contains(where: {
                // Require a path boundary so "/snap" skips "/snap/core/1" but
                // not "/snapshots". Prefixes already ending in "/" (e.g. "/dev/")
                // are matched as-is since the slash IS the boundary.
                $0.hasSuffix("/") ? mount.hasPrefix($0) : (mount == $0 || mount.hasPrefix($0 + "/"))
            })
    }
}
