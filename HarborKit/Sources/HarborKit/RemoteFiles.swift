import Foundation

// MARK: - Model

/// One entry from a remote directory listing (`ls -lAn --time-style=+%s`).
public struct RemoteFileEntry: Equatable, Sendable, Identifiable {
    public let name: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    /// Target of a symlink (the part after " -> "), when present.
    public let linkTarget: String?
    public let sizeBytes: UInt64
    /// Modification time as a unix epoch (seconds).
    public let mtimeEpoch: Int
    /// Raw permission string exactly as ls printed it, e.g. "-rwsr-xr-x".
    public let permissions: String
    public let uid: Int
    public let gid: Int

    /// Names are unique within one directory listing.
    public var id: String { name }

    public var isHidden: Bool { name.hasPrefix(".") }

    public init(
        name: String,
        isDirectory: Bool,
        isSymlink: Bool,
        linkTarget: String? = nil,
        sizeBytes: UInt64,
        mtimeEpoch: Int,
        permissions: String,
        uid: Int,
        gid: Int
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.linkTarget = linkTarget
        self.sizeBytes = sizeBytes
        self.mtimeEpoch = mtimeEpoch
        self.permissions = permissions
        self.uid = uid
        self.gid = gid
    }
}

// MARK: - NUL-delimited find parser

/// Parses a fixed-width, NUL-delimited GNU `find` stream. File names may contain
/// newlines, tabs, or text that looks like a directory-listing row, so line-based
/// `ls` parsing must never be used for a mutable remote file browser.
public enum RemoteLsParser {
    /// The remote script that lists `path` (always one argv element). Each entry
    /// has eight NUL-delimited fields: type, mode, uid, gid, size, mtime, name,
    /// and symlink target. POSIX file names cannot contain NUL, so this framing
    /// preserves every valid file name without allowing it to create a fake row.
    public static func listScript(path: String) -> String {
        "cd \(sq(path)) && LC_ALL=C find . -mindepth 1 -maxdepth 1 "
            + "-printf '%y\\0%M\\0%U\\0%G\\0%s\\0%T@\\0%f\\0%l\\0'"
    }

    public static func parse(_ output: String) -> [RemoteFileEntry] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false)
        var entries: [RemoteFileEntry] = []
        var index = 0

        while index + 7 < fields.count {
            let type = String(fields[index])
            let permissions = String(fields[index + 1])
            let uidField = String(fields[index + 2])
            let gidField = String(fields[index + 3])
            let sizeField = String(fields[index + 4])
            let mtimeField = String(fields[index + 5])
            let name = String(fields[index + 6])
            let linkTargetField = String(fields[index + 7])
            index += 8

            guard type.count == 1,
                  let typeChar = type.first,
                  "fdlbcps".contains(typeChar),
                  permissions.count >= 10,
                  let uid = Int(uidField),
                  let gid = Int(gidField),
                  let mtime = Double(mtimeField),
                  mtime.isFinite,
                  mtime >= Double(Int.min),
                  mtime <= Double(Int.max),
                  !name.isEmpty
            else { continue }

            entries.append(RemoteFileEntry(
                name: name,
                isDirectory: typeChar == "d",
                isSymlink: typeChar == "l",
                linkTarget: typeChar == "l" && !linkTargetField.isEmpty ? linkTargetField : nil,
                sizeBytes: UInt64(sizeField) ?? 0,
                mtimeEpoch: Int(mtime),
                permissions: permissions,
                uid: uid,
                gid: gid
            ))
        }

        return entries
    }
}

// MARK: - Remote path helpers

/// Pure string helpers for absolute POSIX paths on the remote side. No "."
/// or ".." resolution — the shell's `cd` handles those.
public enum RemotePath {
    /// Trims whitespace, collapses duplicate slashes, strips the trailing
    /// slash (except for "/"). Empty input becomes "/".
    public static func normalize(_ path: String) -> String {
        var result = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "/" }
        while result.contains("//") {
            result = result.replacingOccurrences(of: "//", with: "/")
        }
        if result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    /// Parent directory; "/" is its own parent.
    public static func parent(of path: String) -> String {
        let normalized = normalize(path)
        guard normalized != "/", let slash = normalized.lastIndex(of: "/") else { return "/" }
        return slash == normalized.startIndex ? "/" : String(normalized[..<slash])
    }

    /// Joins a directory and a child name.
    public static func join(_ directory: String, _ name: String) -> String {
        let dir = normalize(directory)
        return dir == "/" ? "/" + name : dir + "/" + name
    }

    /// The final path component (folder/file name). "/" returns "/" so the
    /// directory-tree root renders a stable label.
    public static func lastComponent(of path: String) -> String {
        let normalized = normalize(path)
        guard normalized != "/", let slash = normalized.lastIndex(of: "/") else {
            return normalized
        }
        return String(normalized[normalized.index(after: slash)...])
    }
}

// MARK: - sftp batch lines

/// Builders for `sftp -b` batch commands. sftp's tokenizer treats a
/// backslash inside double quotes as LITERAL unless it precedes the quote
/// character, so only `"` needs tokenizer escaping; paths sftp additionally
/// runs through glob(3) (get's remote path, put's local path) get their glob
/// metacharacters backslash-escaped so they stay literal.
public enum SFTPBatch {
    /// Tokenizer-level quoting: wrap in double quotes, escape `"`. For paths
    /// sftp does NOT glob (destinations, rename, mkdir). Filenames where a
    /// backslash immediately precedes a `"` (or ends the name) cannot be
    /// represented and stay best-effort.
    public static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Quoting for paths sftp expands with glob(3): `* ? [` (and `\`, glob's
    /// own escape) are glob-escaped first, then the result is tokenizer-quoted.
    public static func quoteGlobbed(_ path: String) -> String {
        var globEscaped = ""
        for character in path {
            if character == "\\" || character == "*" || character == "?" || character == "[" || character == "{" {
                globEscaped.append("\\")
            }
            globEscaped.append(character)
        }
        return quote(globEscaped)
    }

    /// Download: `get -p [-R] "remote" "local"`. `-p` preserves times.
    public static func get(remote: String, local: String, recursive: Bool = false) -> String {
        "get -p\(recursive ? " -R" : "") \(quoteGlobbed(remote)) \(quote(local))"
    }

    /// Upload: `put -p [-R] "local" "remote"`.
    public static func put(local: String, remote: String, recursive: Bool = false) -> String {
        "put -p\(recursive ? " -R" : "") \(quoteGlobbed(local)) \(quote(remote))"
    }

    public static func rename(from: String, to: String) -> String {
        "rename \(quote(from)) \(quote(to))"
    }

    public static func mkdir(_ path: String) -> String {
        "mkdir \(quote(path))"
    }
}
