import Foundation

/// How many file descriptors one process holds open, and how many of those
/// are sockets — the "is this process leaking sockets" answer. Collected on
/// demand per pid (never in the 2s loop) via `ls -l /proc/<pid>/fd`.
public struct ProcessFDCount: Equatable, Sendable {
    /// Every fd symlink under /proc/<pid>/fd (files, pipes, sockets, anon
    /// inodes — all of them).
    public let total: Int
    /// Subset whose readlink target is `socket:[inode]`.
    public let socketCount: Int

    public init(total: Int, socketCount: Int) {
        self.total = total
        self.socketCount = socketCount
    }
}

/// Pure parser for `ls -l /proc/<pid>/fd`. Each fd is one `l…` symlink line
/// ending in ` -> <target>`; the leading `total N` line ls prints is skipped.
/// A socket fd's target is literally `socket:[12345]`.
public enum ProcFDParser {
    /// The remote command for one (already validated numeric) pid.
    public static func command(pid: Int) -> String {
        "LC_ALL=C ls -l /proc/\(pid)/fd 2>/dev/null"
    }

    public static func parse(_ text: String) -> ProcessFDCount {
        var total = 0
        var sockets = 0
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            // The fd entry is whatever follows the LAST " -> " (targets can
            // contain the sequence in a pathological name, but the link text
            // is always last and always introduced by " -> ").
            guard let arrow = line.range(of: " -> ", options: .backwards) else { continue }
            total += 1
            if line[arrow.upperBound...].hasPrefix("socket:[") { sockets += 1 }
        }
        return ProcessFDCount(total: total, socketCount: sockets)
    }
}
