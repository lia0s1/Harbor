import AppKit
import Foundation
import HarborKit

/// File-based terminal themes: scans `~/Library/Application Support/Harbor/Themes/`
/// for `.harbortheme` documents (FinalShell-style shareable color schemes) and
/// registers them into `TerminalTheme`'s process-wide registry, so every
/// existing `TerminalTheme.theme(withID:)` call site resolves them.
///
/// Directory/files follow the JSONFileStore permission conventions:
/// directory 0700, theme files 0600.
///
/// After every rescan the store bumps `catalogRevisionKey` in UserDefaults;
/// terminal hosting views observe that key and re-apply the resolved theme,
/// which is how an imported/edited file theme reaches already-open sessions.
@MainActor
final class TerminalThemeStore: ObservableObject {
    static let shared = TerminalThemeStore()

    static let fileExtension = "harbortheme"
    /// UserDefaults counter bumped on every catalog change.
    static let catalogRevisionKey = "terminalThemeCatalogRevision"
    /// UserDefaults key holding the selected theme id (pre-existing).
    static let selectedThemeKey = "themeID"

    /// File themes currently registered, sorted for display.
    @Published private(set) var fileThemes: [TerminalTheme] = []
    /// Per-file problems from the last scan (bad JSON, bad colors, id clashes).
    @Published private(set) var loadIssues: [String] = []

    /// Registered theme id → the file it came from, from the last rescan.
    /// Used by `delete(theme:)` so a renamed (collision-suffixed) theme still
    /// maps back to its exact source file.
    private var fileURLByThemeID: [String: URL] = [:]

    /// Injected for tests; production uses the Application Support location.
    private let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL ?? TerminalThemeStore.defaultDirectoryURL(fileManager: fileManager)
        self.fileManager = fileManager
        rescan()
    }

    static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Harbor", isDirectory: true)
            .appendingPathComponent("Themes", isDirectory: true)
    }

    // MARK: - Scanning

    /// Re-reads the Themes directory and replaces the registered file themes.
    /// Individual broken files are skipped (with an entry in `loadIssues`);
    /// one bad file never blocks the rest.
    func rescan() {
        var themes: [TerminalTheme] = []
        var issues: [String] = []
        var urlByID: [String: URL] = [:]
        var seenIDs = Set(TerminalTheme.builtIn.map(\.id))

        let fileURLs = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in fileURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension == Self.fileExtension {
            let baseName = url.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: url) else {
                issues.append(L("%@：无法读取文件", url.lastPathComponent))
                continue
            }
            do {
                var imported = try TerminalTheme.decodeHarbortheme(data, fallbackID: baseName)
                // A file theme may not shadow a built-in or a sibling file:
                // lookups resolve the first match, so rename the newcomer.
                if seenIDs.contains(imported.theme.id) {
                    let originalID = imported.theme.id
                    var suffix = 2
                    var candidate = "\(originalID)-\(suffix)"
                    while seenIDs.contains(candidate) {
                        suffix += 1
                        candidate = "\(originalID)-\(suffix)"
                    }
                    imported = TerminalThemeImport(
                        theme: renamed(imported.theme, to: candidate),
                        warnings: imported.warnings
                    )
                    issues.append(L("%@：主题 ID「%@」已被占用，已改用「%@」", url.lastPathComponent, originalID, candidate))
                }
                seenIDs.insert(imported.theme.id)
                themes.append(imported.theme)
                urlByID[imported.theme.id] = url
                issues.append(contentsOf: imported.warnings.map { "\(url.lastPathComponent): \($0)" })
            } catch {
                let reason: String
                switch error as? TerminalThemeFileError {
                case .invalidJSON: reason = L("不是有效的 JSON 对象")
                case .noUsableColors: reason = L("background/foreground 颜色都无法识别")
                default: reason = error.localizedDescription
                }
                issues.append(L("%@：%@", url.lastPathComponent, reason))
            }
        }

        let sorted = themes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // No-change fast path: re-running a scan (e.g. every time Settings
        // opens) must not bump the catalog revision, or every open terminal
        // would needlessly re-apply its theme.
        guard sorted != fileThemes || issues != loadIssues else { return }

        fileThemes = sorted
        loadIssues = issues
        fileURLByThemeID = urlByID
        TerminalTheme.registerFileThemes(sorted)

        // If the selected theme vanished (file deleted between scans), fall
        // back to the default so no terminal is pinned to an unresolvable id.
        let defaults = UserDefaults.standard
        let selected = defaults.string(forKey: Self.selectedThemeKey) ?? TerminalTheme.defaultThemeID
        if !TerminalTheme.allThemes.contains(where: { $0.id == selected }) {
            defaults.set(TerminalTheme.defaultThemeID, forKey: Self.selectedThemeKey)
        }
        bumpCatalogRevision(defaults: defaults)
    }

    // MARK: - Import / export / delete

    /// Validates and copies a `.harbortheme` file into the Themes directory.
    /// Returns an error message on failure, nil on success.
    @discardableResult
    func importTheme(from sourceURL: URL) -> String? {
        guard let data = try? Data(contentsOf: sourceURL) else {
            return L("无法读取所选文件")
        }
        do {
            _ = try TerminalTheme.decodeHarbortheme(
                data,
                fallbackID: sourceURL.deletingPathExtension().lastPathComponent
            )
        } catch {
            switch error as? TerminalThemeFileError {
            case .invalidJSON:
                return L("不是有效的 JSON 对象")
            case .noUsableColors:
                return L("background/foreground 颜色都无法识别")
            default:
                return error.localizedDescription
            }
        }
        do {
            try ensureDirectory()
            let destination = directoryURL.appendingPathComponent(sourceURL.lastPathComponent)
            // Stage + move so a failed copy never leaves a half-written file.
            let staging = directoryURL.appendingPathComponent(".\(sourceURL.lastPathComponent).tmp")
            defer { try? fileManager.removeItem(at: staging) }
            try data.write(to: staging, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            return error.localizedDescription
        }
        rescan()
        return nil
    }

    /// Writes the theme as a `.harbortheme` document at `destination`
    /// (chosen by the user via NSSavePanel). Returns an error message or nil.
    @discardableResult
    func export(theme: TerminalTheme, to destination: URL) -> String? {
        do {
            let data = try theme.encodeHarbortheme()
            try data.write(to: destination, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Moves a FILE theme's file to the Trash (built-ins cannot be removed).
    func delete(theme: TerminalTheme) {
        guard let url = fileURLByThemeID[theme.id] else { return }
        try? fileManager.trashItem(at: url, resultingItemURL: nil)
        rescan()
    }

    /// Creates the Themes directory (0700) if needed and reveals it.
    func revealThemesDirectory() {
        try? ensureDirectory()
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directoryURL.path)
    }

    // MARK: - Helpers

    @discardableResult
    private func ensureDirectory() throws -> URL {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        return directoryURL
    }

    private func bumpCatalogRevision(defaults: UserDefaults) {
        defaults.set(defaults.integer(forKey: Self.catalogRevisionKey) + 1,
                     forKey: Self.catalogRevisionKey)
    }

    /// TerminalTheme is immutable; id renaming rebuilds the value.
    private func renamed(_ theme: TerminalTheme, to newID: String) -> TerminalTheme {
        TerminalTheme(
            id: newID,
            name: theme.name,
            isDark: theme.isDark,
            foreground: theme.foreground,
            background: theme.background,
            cursor: theme.cursor,
            selection: theme.selection,
            ansi: theme.ansi,
            backgroundOpacity: theme.backgroundOpacity,
            backgroundBlur: theme.backgroundBlur
        )
    }
}
