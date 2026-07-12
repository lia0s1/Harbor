import Foundation

/// Quotes a value for safe inclusion in a POSIX shell command line (remote
/// scripts executed over ssh). Uses the single-quote technique: the value is
/// wrapped in single quotes and every embedded `'` becomes `'"'"'` (close the
/// single-quoted span, emit a double-quoted `'`, reopen single quotes).
///
/// Every user- or remote-derived value interpolated into a remote script MUST
/// go through this function. Local spawns never use a shell, so this is only
/// for the *remote* side of `ssh <dest> '<script>'`.
public func sq(_ value: String) -> String {
    let safe = value.replacingOccurrences(of: "\0", with: "")
    return "'" + safe.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}
