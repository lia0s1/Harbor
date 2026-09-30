import Foundation

/// Recognizes archive filenames and builds the remote shell command to extract
/// them into a chosen directory (in-place when the target == the archive's own
/// dir). Pure logic — the file panel gates a "解压" action on `isArchive` and
/// runs `extractCommand` over the session's ControlMaster socket. All paths are
/// shell-quoted with `sq`.
///
/// Extraction is fail-closed against classic archive slips: member names and
/// symlink targets that are absolute, drive-qualified, backslash-delimited, or
/// contain a `..` component are rejected before the extractor runs. The payload
/// is unpacked into a private staging directory, re-checked, then moved.
public enum ArchiveKind {
    /// Multi-part tar suffixes — GNU `tar xf` auto-detects the compression
    /// (gzip/bzip2/xz/zstd/lzma), so one command handles them all. Longest
    /// suffixes first so `.tar.gz` matches before a bare `.gz`.
    private static let tarSuffixes = [
        ".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2",
        ".tar.xz", ".txz", ".tar.zst", ".tar.zstd",
        ".tar.lz", ".tar.lzma", ".tar",
    ]

    /// Single-file compressors (NOT tarballs): (suffix, decompress tool). They
    /// have no extract-to-dir flag, so we decompress to stdout and redirect.
    private static let singleFile: [(suffix: String, tool: String)] = [
        (".gz", "gunzip"), (".bz2", "bunzip2"), (".xz", "unxz"),
        (".zst", "unzstd"), (".zstd", "unzstd"),
    ]

    /// Marker printed to stderr when a member would escape the extract root.
    public static let unsafeMemberMarker = "HARBOR_UNSAFE_ARCHIVE_PATH"

    /// True when `filename` looks like an archive we can offer to extract.
    public static func isArchive(_ filename: String) -> Bool {
        requiredTool(for: filename) != nil
    }

    /// The CLI tool an extract needs and the apt package that provides it — used
    /// to turn a "command not found" failure into a friendly "install X" hint
    /// (lean servers often lack unzip/7z/unrar). Nil for non-archives.
    public static func requiredTool(for filename: String) -> (tool: String, package: String)? {
        let lower = filename.lowercased()
        for s in tarSuffixes where lower.hasSuffix(s) { return ("tar", "tar") }
        if lower.hasSuffix(".zip") { return ("unzip", "unzip") }
        if lower.hasSuffix(".7z") { return ("7z", "p7zip-full") }
        if lower.hasSuffix(".rar") { return ("unrar", "unrar") }
        if lower.hasSuffix(".gz") { return ("gunzip", "gzip") }
        if lower.hasSuffix(".bz2") { return ("bunzip2", "bzip2") }
        if lower.hasSuffix(".xz") { return ("unxz", "xz-utils") }
        if lower.hasSuffix(".zst") || lower.hasSuffix(".zstd") { return ("unzstd", "zstd") }
        return nil
    }

    /// True when an archive member name or symlink target would extract outside
    /// the chosen directory. Empty names are treated as unsafe so callers cannot
    /// install a nameless entry.
    public static func isUnsafeArchiveMember(_ name: String) -> Bool {
        if name.isEmpty || name == "." || name == ".." { return true }
        if name.hasPrefix("/") || name.hasPrefix("\\") { return true }
        if name.contains("\\") { return true }
        if name.contains("\0") || name.contains("\n") || name.contains("\r") { return true }
        if name.count >= 2 {
            let second = name[name.index(name.startIndex, offsetBy: 1)]
            if second == ":" { return true }
        }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return parts.contains("..")
    }

    /// A remote shell command that extracts the archive at absolute `archivePath`
    /// INTO `targetDir` (created if missing), or nil if the name isn't a
    /// recognized archive. The extractor tool must exist on the server; a
    /// missing tool surfaces as a normal command failure.
    public static func extractCommand(archivePath: String, into targetDir: String) -> String? {
        let lower = archivePath.lowercased()
        let archive = sq(archivePath)
        let target = sq(targetDir)

        for s in tarSuffixes where lower.hasSuffix(s) {
            return guardedExtract(
                target: target,
                listCommands: [
                    "tar tf -- \(archive)",
                    "tar -tvf -- \(archive) | harbor_check_tar_links",
                ],
                extractCommand: "tar --no-absolute-filenames -xf -- \(archive) -C \"$staging\""
            )
        }
        if lower.hasSuffix(".zip") {
            return guardedExtract(
                target: target,
                listCommands: [
                    "{ unzip -Z1 -- \(archive) || zipinfo -1 -- \(archive); }",
                ],
                extractCommand: "unzip -o -d \"$staging\" -- \(archive)"
            )
        }
        if lower.hasSuffix(".7z") {
            return guardedExtract(
                target: target,
                listCommands: [
                    "7z l -slt -- \(archive) | awk -F ' = ' 'BEGIN{skip=1} $1==\"Path\"{if(skip){skip=0;next} print $2}'",
                ],
                extractCommand: "7z x -y \"-o$staging\" -- \(archive)"
            )
        }
        if lower.hasSuffix(".rar") {
            return guardedExtract(
                target: target,
                listCommands: [
                    "unrar lb -- \(archive)",
                ],
                extractCommand: "unrar x -o+ -- \(archive) \"$staging/\""
            )
        }
        for entry in singleFile where lower.hasSuffix(entry.suffix) {
            let stem = strippedBasename(of: archivePath, suffix: entry.suffix)
            guard !stem.isEmpty, !isUnsafeArchiveMember(stem), !stem.contains("/") else {
                return nil
            }
            return singleFileExtract(
                target: target,
                tool: entry.tool,
                archive: archive,
                stem: sq(stem)
            )
        }
        return nil
    }

    private static func guardedExtract(
        target: String,
        listCommands: [String],
        extractCommand: String
    ) -> String {
        let lists = listCommands
            .map { "(\($0)) | harbor_check_members || exit 1" }
            .joined(separator: "\n")
        return """
        \(memberHelpers)
        target=\(target)
        mkdir -p -- "$target" || exit 1
        if [ -L "$target" ]; then
          printf '%s\\n' 'refusing to extract into a symbolic link' >&2
          exit 1
        fi
        \(lists)
        staging=$(mktemp -d -- "$target/.harbor-extract.XXXXXX") || exit 1
        trap 'rm -rf -- "$staging"' EXIT HUP INT TERM
        \(extractCommand) || exit 1
        harbor_check_extracted "$staging" || exit 1
        harbor_install_extracted "$staging" "$target" || exit 1
        trap - EXIT HUP INT TERM
        rm -rf -- "$staging"
        """
    }

    private static func singleFileExtract(
        target: String,
        tool: String,
        archive: String,
        stem: String
    ) -> String {
        """
        \(memberHelpers)
        target=\(target)
        stem=\(stem)
        mkdir -p -- "$target" || exit 1
        if [ -L "$target" ]; then
          printf '%s\\n' 'refusing to extract into a symbolic link' >&2
          exit 1
        fi
        staging=$(mktemp -d -- "$target/.harbor-extract.XXXXXX") || exit 1
        trap 'rm -rf -- "$staging"' EXIT HUP INT TERM
        \(tool) -c -- \(archive) > "$staging/$stem" || exit 1
        harbor_check_extracted "$staging" || exit 1
        harbor_install_extracted "$staging" "$target" || exit 1
        trap - EXIT HUP INT TERM
        rm -rf -- "$staging"
        """
    }

    /// POSIX helpers inlined into every extract script. `set -f` so a member
    /// named `*` cannot expand while we split on `/`.
    private static let memberHelpers = """
    harbor_reject_member() {
      mem=$1
      case "$mem" in
        "") return 0 ;;
        /*|\\\\*)
          printf '%s\\n' 'HARBOR_UNSAFE_ARCHIVE_PATH' >&2
          return 1
          ;;
      esac
      rest=${mem#?}
      second=${rest%"${rest#?}"}
      if [ "$second" = ":" ]; then
        printf '%s\\n' 'HARBOR_UNSAFE_ARCHIVE_PATH' >&2
        return 1
      fi
      case "$mem" in
        *\\\\*)
          printf '%s\\n' 'HARBOR_UNSAFE_ARCHIVE_PATH' >&2
          return 1
          ;;
      esac
      oldifs=$IFS
      IFS=/
      set -f
      set -- $mem
      set +f
      IFS=$oldifs
      for part in "$@"; do
        if [ "$part" = ".." ]; then
          printf '%s\\n' 'HARBOR_UNSAFE_ARCHIVE_PATH' >&2
          return 1
        fi
      done
      return 0
    }
    harbor_check_members() {
      while IFS= read -r mem || [ -n "$mem" ]; do
        harbor_reject_member "$mem" || return 1
      done
      return 0
    }
    harbor_check_tar_links() {
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          l*)
            tgt=${line#* -> }
            [ "$tgt" = "$line" ] && continue
            harbor_reject_member "$tgt" || return 1
            ;;
        esac
      done
      return 0
    }
    harbor_check_extracted() {
      root=$1
      [ -d "$root" ] || return 1
      if [ -L "$root" ]; then
        printf '%s\\n' 'HARBOR_UNSAFE_ARCHIVE_PATH' >&2
        return 1
      fi
      list=$(mktemp) || return 1
      find "$root" \\( -type l -o -type f -o -type d \\) -print > "$list" || { rm -f "$list"; return 1; }
      while IFS= read -r item || [ -n "$item" ]; do
        [ "$item" = "$root" ] && continue
        case "$item" in
          "$root"/*) ;;
          *)
            rm -f "$list"
            printf '%s\\n' 'HARBOR_UNSAFE_ARCHIVE_PATH' >&2
            return 1
            ;;
        esac
        if [ -L "$item" ]; then
          tgt=$(readlink -- "$item" 2>/dev/null || readlink "$item") || { rm -f "$list"; return 1; }
          if ! harbor_reject_member "$tgt"; then
            rm -f "$list"
            return 1
          fi
        fi
      done < "$list"
      rm -f "$list"
      return 0
    }
    harbor_install_extracted() {
      src=$1
      dest=$2
      list=$(mktemp) || return 1
      find "$src" -mindepth 1 -maxdepth 1 -print > "$list" || { rm -f "$list"; return 1; }
      while IFS= read -r item || [ -n "$item" ]; do
        [ -z "$item" ] && continue
        name=${item##*/}
        if ! harbor_reject_member "$name"; then
          rm -f "$list"
          return 1
        fi
        if [ -e "$dest/$name" ] || [ -L "$dest/$name" ]; then
          rm -f "$list"
          printf '%s\\n' "refusing to overwrite $name" >&2
          return 1
        fi
        if ! mv -n -- "$item" "$dest/"; then
          rm -f "$list"
          return 1
        fi
      done < "$list"
      rm -f "$list"
      return 0
    }
    """

    /// The archive's basename with the given compression suffix removed
    /// (e.g. "/root/data.txt.gz" + ".gz" → "data.txt").
    private static func strippedBasename(of path: String, suffix: String) -> String {
        let base = (path as NSString).lastPathComponent
        if base.lowercased().hasSuffix(suffix) {
            return String(base.dropLast(suffix.count))
        }
        return base
    }
}
