import Foundation

/// Recognizes archive filenames and builds the remote shell command to extract
/// them into a chosen directory (in-place when the target == the archive's own
/// dir). Pure logic — the file panel gates a "解压" action on `isArchive` and
/// runs `extractCommand` over the session's ControlMaster socket. All paths are
/// shell-quoted with `sq`.
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

    /// A remote shell command that extracts the archive at absolute `archivePath`
    /// INTO `targetDir` (created if missing), or nil if the name isn't a
    /// recognized archive. The target equals the archive's own directory for
    /// in-place extraction. The extractor tool (unzip / 7z / unrar / tar …) must
    /// exist on the server; a missing tool surfaces as a normal command failure.
    public static func extractCommand(archivePath: String, into targetDir: String) -> String? {
        let lower = archivePath.lowercased()
        let a = sq(archivePath)
        // mkdir -p + cd so output lands in the target; archivePath is absolute,
        // so tar/unzip/7z/unrar extract their (relative) contents under it.
        let prefix = "mkdir -p \(sq(targetDir)) && cd \(sq(targetDir)) && "

        for s in tarSuffixes where lower.hasSuffix(s) { return prefix + "tar xf \(a)" }
        if lower.hasSuffix(".zip") { return prefix + "unzip -o \(a)" }
        if lower.hasSuffix(".7z") { return prefix + "7z x -y \(a)" }
        if lower.hasSuffix(".rar") { return prefix + "unrar x -o+ \(a)" }
        for entry in singleFile where lower.hasSuffix(entry.suffix) {
            // Decompress to stdout, redirect under the suffix-stripped basename so
            // the result lands in targetDir and the source archive is kept.
            let stem = strippedBasename(of: archivePath, suffix: entry.suffix)
            return prefix + "\(entry.tool) -c \(a) > \(sq(stem))"
        }
        return nil
    }

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
