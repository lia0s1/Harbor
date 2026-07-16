import Foundation
import AppKit
import UniformTypeIdentifiers
import HarborKit

// MARK: - Local file entry model

/// One entry from the local macOS filesystem. Mirrors `RemoteFileEntry`'s
/// shape so the local pane can share a common table layout.
struct LocalFileEntry: Identifiable, Equatable {
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    /// Symlink destination when readable.
    let symlinkTarget: String?
    let sizeBytes: UInt64
    let modificationDate: Date
    /// Human-readable permission string like "-rw-r--r--".
    let permissions: String
    /// Full absolute path on the local filesystem.
    let path: String

    var id: String { name }

    var isHidden: Bool { name.hasPrefix(".") }

    init(
        name: String,
        isDirectory: Bool,
        isSymlink: Bool = false,
        symlinkTarget: String? = nil,
        sizeBytes: UInt64 = 0,
        modificationDate: Date = Date(),
        permissions: String = "",
        path: String = ""
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.symlinkTarget = symlinkTarget
        self.sizeBytes = sizeBytes
        self.modificationDate = modificationDate
        self.permissions = permissions
        self.path = path
    }
}

// MARK: - Local file service

/// Browses the LOCAL Mac filesystem — the left pane of the dual-pane file
/// manager. Mirrors `FileService`'s observable surface (`cwd`, `entries`,
/// `isLoading`, `errorMessage`, navigation stacks) but reads from
/// `FileManager` instead of a remote SSH socket. Supports `~` expansion like
/// the remote path bar.
@MainActor
final class LocalFileService: ObservableObject {
    @Published var cwd: String = NSHomeDirectory()
    @Published var entries: [LocalFileEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    @Published var canGoBack = false
    @Published var canGoForward = false

    /// When on, dot-files appear in the listing.
    @Published var showHidden = false

    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private let fileManager = FileManager.default
    private var listGeneration = 0

    init(startPath: String? = nil) {
        if let startPath, !startPath.isEmpty {
            self.cwd = (startPath as NSString).expandingTildeInPath
        }
        refreshListing()
    }

    // MARK: - Listing

    func list(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            errorMessage = L("目录不存在或无权访问：%@", expanded)
            return
        }
        cwd = expanded
        refreshListing()
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
    }

    /// Re-list the current directory (no history-side-effect).
    func refresh() {
        refreshListing()
    }

    /// List with navigation step recorded.
    func list(path: String, step: HistoryStep) {

        let expanded = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            errorMessage = L("目录不存在或无权访问：%@", expanded)
            return
        }

        switch step {
        case .push where expanded != cwd:
            backStack.append(cwd)
            forwardStack.removeAll()
        case .back where !backStack.isEmpty:
            backStack.removeLast()
            forwardStack.append(cwd)
        case .forward where !forwardStack.isEmpty:
            forwardStack.removeLast()
            backStack.append(cwd)
        case .stay:
            break
        case .push, .back, .forward:
            break
        }

        cwd = expanded
        refreshListing()
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
    }

    private func refreshListing() {
        isLoading = true
        errorMessage = nil
        listGeneration += 1
        let generation = listGeneration
        let dir = cwd
        let showHidden = self.showHidden

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.listDirectory(at: dir, showHidden: showHidden)
            Task { @MainActor [weak self] in
                guard let self, generation == self.listGeneration else { return }
                self.isLoading = false
                switch result {
                case .success(let entries):
                    self.entries = entries
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    nonisolated private static func listDirectory(
        at path: String,
        showHidden: Bool
    ) -> Result<[LocalFileEntry], Error> {
        let fm = FileManager.default
        do {
            let names = try fm.contentsOfDirectory(atPath: path)
            var entries: [LocalFileEntry] = []
            for name in names {
                guard showHidden || !name.hasPrefix(".") else { continue }
                let fullPath = (path as NSString).appendingPathComponent(name)
                guard let attrs = try? fm.attributesOfItem(atPath: fullPath) else { continue }
                let fileType = attrs[.type] as? FileAttributeType ?? .typeUnknown
                let isDir = fileType == .typeDirectory
                let isSymlink = fileType == .typeSymbolicLink
                let symlinkTarget = isSymlink ? (try? fm.destinationOfSymbolicLink(atPath: fullPath)) : nil
                let sizeBytes = (attrs[.size] as? UInt64) ?? 0
                let modDate = (attrs[.modificationDate] as? Date) ?? Date.distantPast
                let posix = (attrs[.posixPermissions] as? Int) ?? 0
                let permStr = Self.permissionsString(posix: posix, isDir: isDir)
                entries.append(LocalFileEntry(
                    name: name,
                    isDirectory: isDir,
                    isSymlink: isSymlink,
                    symlinkTarget: symlinkTarget,
                    sizeBytes: sizeBytes,
                    modificationDate: modDate,
                    permissions: permStr,
                    path: fullPath
                ))
            }
            entries.sort { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return .success(entries)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Navigation

    func goUp() {
        let parent = (cwd as NSString).deletingLastPathComponent
        let normalized = parent.isEmpty ? "/" : parent
        list(path: (normalized as NSString).expandingTildeInPath, step: .push)
    }

    func goBack() {
        guard let target = backStack.last else { return }
        list(path: target, step: .back)
    }

    func goForward() {
        guard let target = forwardStack.last else { return }
        list(path: target, step: .forward)
    }

    func navigate(toPath raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let expanded = (trimmed as NSString).expandingTildeInPath
        list(path: expanded, step: .push)
    }

    /// Double-click a directory (or symlink to directory) to navigate in.
    func open(_ entry: LocalFileEntry) {
        guard entry.isDirectory else { return }
        if entry.isSymlink {
            // Resolve symlink target
            if let target = entry.symlinkTarget {
                let resolved: String
                if target.hasPrefix("/") {
                    resolved = target
                } else {
                    resolved = (cwd as NSString).appendingPathComponent(target)
                }
                let normalized = (resolved as NSString).standardizingPath
                list(path: normalized, step: .push)
            }
        } else {
            let newPath = (cwd as NSString).appendingPathComponent(entry.name)
            list(path: newPath, step: .push)
        }
    }

    /// Absolute path for an entry in the current directory.
    func absolutePath(of entry: LocalFileEntry) -> String {
        (cwd as NSString).appendingPathComponent(entry.name)
    }

    // MARK: - State helpers

    func homePath() -> String {
        NSHomeDirectory()
    }

    enum HistoryStep {
        case stay, push, back, forward
    }

    // MARK: - Permissions string

    /// Builds an `ls -l` style 10-character permission string from a POSIX mask.
    nonisolated private static func permissionsString(posix: Int, isDir: Bool) -> String {
        var result = isDir ? "d" : "-"
        for i in (0..<3).reversed() {
            let shift = i * 3
            result.append(((posix >> (shift + 2)) & 1) != 0 ? "r" : "-")
            result.append(((posix >> (shift + 1)) & 1) != 0 ? "w" : "-")
            result.append(((posix >> shift) & 1) != 0 ? "x" : "-")
        }
        return result
    }

    /// Size formatting (same logic as the remote panel).
    static func sizeText(_ entry: LocalFileEntry) -> String {
        if entry.isDirectory { return "—" }
        if entry.sizeBytes < 1024 { return "\(entry.sizeBytes) B" }
        return MonitorFormat.sizeShort(bytes: Double(entry.sizeBytes))
    }

    /// Date formatting.
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func dateText(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}
