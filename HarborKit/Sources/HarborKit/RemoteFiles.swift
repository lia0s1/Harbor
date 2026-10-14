import Foundation
import Darwin

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

// MARK: - POSIX permission modes

/// A POSIX permission mode as rendered by GNU `find %M` / `ls -l`.
///
/// The execute positions may render as `s`/`S` (set-user-ID or set-group-ID)
/// and `t`/`T` (sticky).  Those special bits must be represented separately:
/// treating every non-`-` character as execute silently turns `S`/`T` into an
/// executable bit and drops the special bit on the next `chmod`.
public struct POSIXPermissionMode: Equatable, Sendable {
    private var storage: [Bool]

    /// Owner/group/other read, write, execute bits, in that order.
    public var rwx: [Bool] {
        get { storage }
        set { storage = Self.normalizedRwx(newValue) }
    }

    public var setUserID: Bool
    public var setGroupID: Bool
    public var sticky: Bool

    public init(
        rwx: [Bool] = [Bool](repeating: false, count: 9),
        setUserID: Bool = false,
        setGroupID: Bool = false,
        sticky: Bool = false
    ) {
        self.storage = Self.normalizedRwx(rwx)
        self.setUserID = setUserID
        self.setGroupID = setGroupID
        self.sticky = sticky
    }

    /// Parses a mode such as `-rwsr-Sr-T`. Invalid or shortened strings
    /// produce an empty mode rather than guessing at permissions.
    public init(lsPermissions: String) {
        let characters = Array(lsPermissions)
        guard characters.count >= 10 else {
            self.init()
            return
        }

        var rwx = [Bool](repeating: false, count: 9)
        for index in 0..<9 where index != 2 && index != 5 && index != 8 {
            rwx[index] = characters[index + 1] != "-"
        }

        let ownerExecute = characters[3]
        rwx[2] = ownerExecute == "x" || ownerExecute == "s"
        let groupExecute = characters[6]
        rwx[5] = groupExecute == "x" || groupExecute == "s"
        let otherExecute = characters[9]
        rwx[8] = otherExecute == "x" || otherExecute == "t"

        self.init(
            rwx: rwx,
            setUserID: ownerExecute == "s" || ownerExecute == "S",
            setGroupID: groupExecute == "s" || groupExecute == "S",
            sticky: otherExecute == "t" || otherExecute == "T"
        )
    }

    /// A four-digit octal mode, including a leading zero when no special bits
    /// are set (for example, `0755`).
    public var octal: String {
        func digit(_ row: Int) -> Int {
            (storage[row * 3] ? 4 : 0)
                + (storage[row * 3 + 1] ? 2 : 0)
                + (storage[row * 3 + 2] ? 1 : 0)
        }
        let special = (setUserID ? 4 : 0) + (setGroupID ? 2 : 0) + (sticky ? 1 : 0)
        return "\(special)\(digit(0))\(digit(1))\(digit(2))"
    }

    private static func normalizedRwx(_ rwx: [Bool]) -> [Bool] {
        Array(rwx.prefix(9)) + [Bool](repeating: false, count: max(0, 9 - rwx.count))
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
    /// Eight NUL fields per entry. Cap the stream so a huge directory cannot
    /// hang the mux long enough to look like the file pane dropped.
    public static let maxListFields = 8_000 * 8

    public static func listScript(path: String) -> String {
        "cd \(sq(path)) && LC_ALL=C find . -mindepth 1 -maxdepth 1 "
            + "-printf '%y\\0%M\\0%U\\0%G\\0%s\\0%T@\\0%f\\0%l\\0' "
            + "| awk 'BEGIN{RS=\"\\0\";ORS=\"\\0\";n=0} {print; n++; if(n>=\(maxListFields)) exit}'"
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

/// Pure string helpers for absolute POSIX paths on the remote side. "." and
/// ".." segments are resolved lexically — symlinks are never consulted.
public enum RemotePath {
    /// Trims whitespace, collapses duplicate slashes, strips the trailing
    /// slash (except for "/"), and lexically resolves "." / ".." segments.
    /// Empty input becomes "/"; a fully-collapsed relative path becomes ".".
    public static func normalize(_ path: String) -> String {
        var result = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "/" }
        while result.contains("//") {
            result = result.replacingOccurrences(of: "//", with: "/")
        }
        if result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        let isAbsolute = result.hasPrefix("/")
        var components: [String] = []
        for part in result.split(separator: "/") {
            switch part {
            case ".":
                continue
            case "..":
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else if isAbsolute {
                    continue
                } else {
                    components.append("..")
                }
            default:
                components.append(String(part))
            }
        }
        let joined = components.joined(separator: "/")
        if isAbsolute {
            return joined.isEmpty ? "/" : "/" + joined
        }
        return joined.isEmpty ? "." : joined
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

// MARK: - Safe local transfer staging

/// Local staging primitives for file transfers. `FileManager.fileExists` treats
/// a dangling symlink as absent, so it must not be used to choose an sftp
/// destination: a subsequent open can follow the link outside the requested
/// directory. These helpers stage privately and atomically install with
/// `RENAME_EXCL` instead.
public enum LocalTransferStaging {
    /// Reports every existing directory entry, including a dangling symlink,
    /// without resolving its final path component.
    public static func entryExists(at url: URL) -> Bool {
        var metadata = stat()
        return url.path.withCString { path in
            lstat(path, &metadata) == 0
        }
    }

    /// Creates a fresh 0700 staging directory directly inside `directory`, so
    /// its payload can later be atomically renamed onto the same volume.
    public static func createPrivateDirectory(in directory: URL, label: String) throws -> URL {
        let staging = directory.appendingPathComponent(
            ".harbor-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        let manager = FileManager.default
        try manager.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        do {
            // Reassert the mode and reject a substituted symlink before a child
            // path is handed to sftp.
            try manager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: staging.path
            )
            var metadata = stat()
            let exists = staging.path.withCString { path in
                lstat(path, &metadata) == 0
            }
            let mode = mode_t(metadata.st_mode)
            guard exists, (mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                throw stagingError("Unable to create a safe local staging directory", code: 1)
            }
            return staging
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    /// A single path component that can be installed next to `directory`.
    /// `URL.appendingPathComponent` treats `/` as a separator on file URLs, so
    /// a hostile listing name such as `../Library/LaunchAgents/x.plist` would
    /// otherwise escape the chosen folder.
    @discardableResult
    public static func validatedInstallName(_ name: String) throws -> String {
        let last = (name as NSString).lastPathComponent
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\"),
              name == last,
              !name.unicodeScalars.contains(where: { forbidden.contains($0) })
        else {
            throw stagingError("Unsafe local destination filename", code: 3)
        }
        return name
    }

    /// Atomically selects a collision-free destination and installs `source`.
    /// Existing regular files, directories, live symlinks, and dangling symlinks
    /// are all treated as occupied. `source` must be a sibling-volume staging
    /// item created by `createPrivateDirectory`. `name` must be a single
    /// path component — separators and `.`/`..` are rejected.
    @discardableResult
    public static func moveStagedItem(
        at source: URL,
        named name: String,
        into directory: URL
    ) throws -> URL {
        let filename = try validatedInstallName(name)
        var counter = 1
        while counter <= 10_000 {
            let candidate = candidateURL(for: filename, in: directory, counter: counter)
            switch try renameExclusively(from: source, to: candidate) {
            case .moved:
                return candidate
            case .destinationExists:
                counter += 1
            }
        }
        throw stagingError("Unable to select a safe local destination filename", code: 2)
    }

    private enum ExclusiveRenameResult {
        case moved
        case destinationExists
    }

    /// `renameatx_np(..., RENAME_EXCL)` never follows the final component and
    /// fails atomically if an entry appeared after the collision check.
    private static func renameExclusively(from source: URL, to destination: URL) throws -> ExclusiveRenameResult {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        if result == 0 { return .moved }
        switch errno {
        case EEXIST, ENOTEMPTY, EISDIR:
            return .destinationExists
        default:
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }
    }

    private static func candidateURL(for name: String, in directory: URL, counter: Int) -> URL {
        guard counter > 1 else { return directory.appendingPathComponent(name) }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let candidate = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
        return directory.appendingPathComponent(candidate)
    }

    private static func stagingError(_ message: String, code: Int) -> NSError {
        NSError(
            domain: "HarborKit.LocalTransferStaging",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

// MARK: - sftp batch lines

/// Errors from building `sftp -b` batch commands.
public enum SFTPBatchError: Error, Equatable, LocalizedError, Sendable {
    /// Path contains CR/LF/NUL/other controls that break the line-oriented
    /// sftp batch protocol even inside double quotes.
    case unsafePath(String)

    public var errorDescription: String? {
        switch self {
        case .unsafePath:
            return "Path contains control or newline characters that cannot be used with sftp batch mode"
        }
    }
}

/// Builders for `sftp -b` batch commands. sftp's tokenizer treats `\\` as an
/// escaped backslash and `\"` as an escaped double-quote inside double-quoted
/// strings; all other characters are literal. Glob metacharacters are further
/// expanded by sftp for get/put source paths (see quoteGlobbed).
///
/// Paths with newlines or other control characters are rejected: the batch
/// protocol is line-oriented, so a remote name containing `\n` can desync the
/// script into attacker-controlled extra commands.
public enum SFTPBatch {
    /// Reject empty paths and any control/newline scalar (CR/LF/NUL/tabs and
    /// Unicode line/paragraph separators). Call this before building batch lines.
    public static func validatePath(_ path: String) throws {
        guard !path.isEmpty else {
            throw SFTPBatchError.unsafePath(path)
        }
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        if path.unicodeScalars.contains(where: { forbidden.contains($0) }) {
            throw SFTPBatchError.unsafePath(path)
        }
    }

    /// Tokenizer-level quoting: wrap in double quotes, escape `\` then `"`.
    /// For paths sftp does NOT expand with glob(3) (destinations, rename, mkdir).
    public static func quote(_ path: String) throws -> String {
        try validatePath(path)
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    /// Quoting for paths sftp expands with glob(3): `* ? [` (and `\`, glob's
    /// own escape) are glob-escaped first, then the result is tokenizer-quoted.
    public static func quoteGlobbed(_ path: String) throws -> String {
        try validatePath(path)
        var globEscaped = ""
        for character in path {
            if character == "\\" || character == "*" || character == "?" || character == "[" || character == "{" {
                globEscaped.append("\\")
            }
            globEscaped.append(character)
        }
        // Glob-escaping only inserts backslashes (already allowed); re-quote.
        return try quote(globEscaped)
    }

    /// Download: `get -p [-R] "remote" "local"`. `-p` preserves times.
    public static func get(remote: String, local: String, recursive: Bool = false) throws -> String {
        "get -p\(recursive ? " -R" : "") \(try quoteGlobbed(remote)) \(try quote(local))"
    }

    /// Upload: `put -p [-R] "local" "remote"`.
    public static func put(local: String, remote: String, recursive: Bool = false) throws -> String {
        "put -p\(recursive ? " -R" : "") \(try quoteGlobbed(local)) \(try quote(remote))"
    }

    public static func rename(from: String, to: String) throws -> String {
        "rename \(try quote(from)) \(try quote(to))"
    }

    public static func mkdir(_ path: String) throws -> String {
        "mkdir \(try quote(path))"
    }
}

// MARK: - Quick delete (shell rm over the mux socket)

/// Errors from building a quick-delete (`rm -rf`) remote command.
public enum QuickDeleteError: Error, Equatable, LocalizedError, Sendable {
    /// The selection was empty — there is nothing to delete.
    case emptySelection
    /// A path is not absolute. Quick delete must never resolve a target
    /// relative to the ssh login directory.
    case notAbsolute(String)
    /// A path contains CR/LF/NUL/other control characters. The command runs
    /// as a single remote shell line, where such characters would break out
    /// of the single-quoted argument and smuggle in additional commands.
    case unsafePath(String)

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "No items selected"
        case .notAbsolute:
            return "Quick delete requires an absolute remote path"
        case .unsafePath:
            // Never echo the hostile path back: it contains the very control
            // characters we rejected, which would corrupt the error banner.
            return "Path contains control or newline characters that cannot be used in a shell command"
        }
    }
}

/// Builds the `rm -rf` shell line behind the file panel's 快速删除 action.
///
/// sftp deletes recurse file-by-file over the mux socket (one round trip per
/// entry), so wiping a large directory tree is slow. This bypasses sftp and
/// issues ONE remote `rm -rf` instead — the same trade FinalShell makes.
/// Every path is validated (absolute, free of control/newline characters) and
/// single-quoted individually via `sq`, so a hostile name from a remote
/// listing cannot inject extra shell commands into the auxiliary channel.
public enum RemoteQuickDelete {
    /// `rm -rf -- '<path>' …` for the given absolute remote paths.
    /// The `--` stops option parsing so a name like `-rf` stays an operand.
    public static func command(paths: [String]) throws -> String {
        try validate(paths: paths)
        return "rm -rf -- " + paths.map { sq($0) }.joined(separator: " ")
    }

    /// Validation only — used by the UI to explain a rejected selection
    /// before the confirmation dialog even opens.
    public static func validate(paths: [String]) throws {
        guard !paths.isEmpty else { throw QuickDeleteError.emptySelection }
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        for path in paths {
            guard !path.isEmpty,
                  !path.unicodeScalars.contains(where: { forbidden.contains($0) })
            else {
                throw QuickDeleteError.unsafePath(path)
            }
            guard path.hasPrefix("/") else {
                throw QuickDeleteError.notAbsolute(path)
            }
        }
    }
}
