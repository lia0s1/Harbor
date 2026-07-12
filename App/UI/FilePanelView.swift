import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HarborKit

// MARK: - Visibility / height preferences

/// Shared storage for the file panel: the toolbar button, the ⌘J menu toggle
/// and SessionTabsView bind to the same keys. Height persists across drags.
enum FilePanelPreference {
    static let storageKey = "filePanelVisible"
    static let defaultVisible = true
    static let heightKey = "filePanelHeight"
    static let showHiddenKey = "filePanelShowHidden"
    /// Whether the left directory-tree pane is shown (FinalShell's file tree).
    static let treeVisibleKey = "filePanelTreeVisible"
    static let defaultTreeVisible = true
    /// Persisted width of the tree pane.
    static let treeWidthKey = "filePanelTreeWidth"
    static let defaultTreeWidth: Double = 180
    static let minTreeWidth: Double = 120
    static let maxTreeWidth: Double = 340
    static let defaultHeight: Double = 240
    static let minHeight: Double = 140
    static let maxHeight: Double = 480

    static func clampHeight(_ height: Double) -> Double {
        min(maxHeight, max(minHeight, height))
    }

    static func clampTreeWidth(_ width: Double) -> Double {
        min(maxTreeWidth, max(minTreeWidth, width))
    }

}

// MARK: - Panel root

/// Remote file manager panel: browse, upload, download, edit files on the SSH server.
struct DualPaneFileView: View {
    let session: TerminalSession
    @ObservedObject var service: FileService

    @AppStorage(FilePanelPreference.showHiddenKey)
    private var showHidden = false
    @AppStorage(FilePanelPreference.treeVisibleKey)
    private var treeVisible = FilePanelPreference.defaultTreeVisible
    @AppStorage(FilePanelPreference.treeWidthKey)
    private var treeWidth = FilePanelPreference.defaultTreeWidth

    @State private var transfersPresented = false
    @State private var sessionState: TerminalSession.State = .connecting

    private var isReady: Bool {
        service.status == .ready && sessionState == .running
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            contentBody
        }
        .frame(maxWidth: .infinity)
        .onAppear { sessionState = session.state }
        .onReceive(session.$state) { sessionState = $0 }
    }

    // MARK: Header (path bar + actions)

    @ViewBuilder
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.xs) {
                transferCluster
            }
            VStack(spacing: 5) {
                HStack(spacing: DS.Space.xs) {
                    transferCluster
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, 5)
    }

    /// Transfer cluster — shared across both panes.
    private var transferCluster: some View {
        HStack(spacing: 2) {
            Text(L("传输"))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            transfersButton
        }
    }

    // MARK: Transfers popover (shared)

    private var transfersButton: some View {
        Button {
            transfersPresented.toggle()
        } label: {
            Image(systemName: service.hasRunningTransfers ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(service.hasRunningTransfers ? AnyShapeStyle(SwiftUI.Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 30, height: 26)
                .overlay(alignment: .topTrailing) {
                    if !service.transfers.isEmpty {
                        Text("\(service.transfers.count)")
                            .font(.system(size: 8, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 0.5)
                            .background(Capsule().fill(SwiftUI.Color.accentColor))
                            .offset(x: 5, y: -2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("传输列表"))
        .popover(isPresented: $transfersPresented, arrowEdge: .bottom) {
            TransfersPopoverView(service: service)
        }
    }

    // MARK: States

    @ViewBuilder
    private var contentBody: some View {
        switch session.state {
        case .exited:
            PanelNotice(
                symbol: "moon.zzz",
                title: L("会话已结束"),
                caption: L("重新连接后可继续浏览文件。")
            )
        case .connecting:
            PanelNotice(spinner: true, title: L("正在连接…"))
        case .running:
            switch service.status {
            case .idle, .preparing:
                PanelNotice(
                    spinner: true,
                    title: L("正在准备文件面板…"),
                    caption: L("正在通过已建立的 SSH 连接检测服务器。")
                )
            case .unsupported(let reason):
                PanelNotice(
                    symbol: "externaldrive.badge.xmark",
                    title: L("文件面板需要 Linux 服务器与连接复用"),
                    caption: reason,
                    actionTitle: L("重试"),
                    action: { service.retry() }
                )
            case .ready:
                RemoteFilePane(
                    session: session,
                    service: service,
                    showHidden: $showHidden,
                    treeVisible: $treeVisible,
                    treeWidth: $treeWidth
                )
            }
        }
    }

    // MARK: Formatting (shared)

    static func sizeText(_ sizeBytes: UInt64, isDirectory: Bool) -> String {
        if isDirectory { return "—" }
        if sizeBytes < 1024 { return "\(sizeBytes) B" }
        return MonitorFormat.sizeShort(bytes: Double(sizeBytes))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func dateText(_ epoch: Int) -> String {
        guard epoch > 0 else { return "—" }
        return dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    static func dateText(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}

// MARK: - Remote file pane

/// The RIGHT pane of the dual-pane file manager: the existing remote file
/// browser extracted from the former `FilePanelView`. All original remote
/// functionality preserved: download, upload, delete, rename, mkdir,
/// permissions, edit, extract, tree.
struct RemoteFilePane: View {
    let session: TerminalSession
    @ObservedObject var service: FileService
    @Binding var showHidden: Bool
    @Binding var treeVisible: Bool
    @Binding var treeWidth: Double

    /// The lazy directory tree backing the left pane. Owned here (per file
    /// panel) so its cache is reset with the panel's `.id(session)`.
    @StateObject private var treeModel = DirectoryTreeModel()
    @State private var treeDragBaseWidth: Double?

    @State private var selection = Set<RemoteFileEntry.ID>()
    @State private var pathText = ""
    @State private var renameTarget: RemoteFileEntry?
    @State private var renameText = ""
    @State private var permissionsTarget: RemoteFileEntry?
    @State private var editingFile: RemoteFileEntry?
    @State private var deleteTargets: [RemoteFileEntry] = []
    @State private var deleteConfirmPresented = false
    @State private var newFolderPresented = false
    @State private var newFolderName = ""
    /// Archive awaiting an "解压到…" target path, plus the editable destination.
    @State private var extractTarget: RemoteFileEntry?
    @State private var extractDestText = ""
    @State private var isDropTargeted = false
    @State private var sessionState: TerminalSession.State = .connecting

    private var isReady: Bool {
        service.status == .ready && sessionState == .running
    }

    var body: some View {
        VStack(spacing: 0) {
            RemoteFilePaneHeader(
                service: service,
                pathText: $pathText,
                showHidden: $showHidden,
                treeVisible: $treeVisible,
                isReady: isReady,
                selectedCount: selection.count,
                selectedEntries: selectedEntries,
                onUpload: { chooseUploadFiles() },
                onDownload: { service.download(selectedEntries) }
            )
            Divider()
            remoteBody
        }
        .onAppear {
            pathText = service.cwd
            sessionState = session.state
        }
        .onReceive(session.$state) { sessionState = $0 }
        .onChange(of: service.cwd) { _, newValue in
            pathText = newValue
            selection.removeAll()
        }
        .onChange(of: service.entries) { _, newEntries in
            // Prune stale IDs after rename/mkdir/permissions/extract so selection
            // never points to a file that no longer exists under its old name.
            let live = Set(newEntries.map(\.id))
            selection.formIntersection(live)
        }
        .alert(L("重命名"), isPresented: renamePresented) {
            TextField(L("新名称"), text: $renameText)
            Button(L("重命名")) {
                if let target = renameTarget {
                    service.rename(target, to: renameText)
                }
                renameTarget = nil
            }
            Button(L("取消"), role: .cancel) { renameTarget = nil }
        } message: {
            Text(verbatim: L("输入 \u{201C}%@\u{201D} 的新名称。", renameTarget?.name ?? ""))
        }
        .alert(L("新建文件夹"), isPresented: $newFolderPresented) {
            TextField(L("文件夹名称"), text: $newFolderName)
            Button(L("创建")) { service.createDirectory(named: newFolderName) }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(verbatim: L("在 %@ 中创建新文件夹。", service.cwd))
        }
        .alert(L("解压到…"), isPresented: Binding(
            get: { extractTarget != nil },
            set: { if !$0 { extractTarget = nil } }
        )) {
            TextField(L("目标目录"), text: $extractDestText)
            Button(L("解压")) {
                if let target = extractTarget {
                    service.extract(target, to: extractDestText)
                }
                extractTarget = nil
            }
            Button(L("取消"), role: .cancel) { extractTarget = nil }
        } message: {
            Text(verbatim: L("把 \u{201C}%@\u{201D} 解压到哪个目录?(支持 ~ 和相对路径)", extractTarget?.name ?? ""))
        }
        .alert(deleteTitle, isPresented: $deleteConfirmPresented) {
            Button(L("删除"), role: .destructive) {
                service.delete(deleteTargets)
                deleteTargets = []
                selection.removeAll()
            }
            Button(L("取消"), role: .cancel) { deleteTargets = [] }
        } message: {
            Text(verbatim: L("此操作无法撤销，将删除：\n%@", deletePathsPreview))
        }
        .sheet(item: $permissionsTarget) { entry in
            PermissionsSheet(entry: entry) { octal in
                service.changePermissions(entry, octal: octal)
            }
        }
        .sheet(item: $editingFile) { entry in
            FileEditorView(entry: entry, service: service)
        }
        .sheet(item: Binding(
            get: { service.directorySyncPreview },
            set: { if $0 == nil { service.dismissDirectorySyncPreview() } }
        )) { preview in
            DirectorySyncPreviewSheet(preview: preview) {
                service.applyDirectorySyncPreview()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .harborUploadLocalFiles)) { notification in
            guard isReady, let urls = notification.object as? [URL] else { return }
            service.upload(urls: urls)
        }
    }

    // MARK: Remote body

    @ViewBuilder
    private var remoteBody: some View {
        VStack(spacing: 0) {
            if let message = service.errorMessage {
                errorBanner(message)
            }
            if service.isComparingDirectory {
                HStack(spacing: DS.Space.s) {
                    ProgressView().controlSize(.small)
                    Text(L("正在对比本地目录…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, 4)
                .background(DS.Colors.separator.opacity(0.35))
            }
            if treeVisible {
                HStack(spacing: 0) {
                    treePane
                    treeDivider
                    remoteTable
                }
            } else {
                remoteTable
            }
        }
    }

    // MARK: Directory tree pane (left)

    private var treePane: some View {
        DirectoryTreeView(service: service, model: treeModel, includeHidden: showHidden)
            .frame(width: FilePanelPreference.clampTreeWidth(treeWidth))
    }

    /// Draggable hairline between the tree and the table; persists tree width.
    private var treeDivider: some View {
        Rectangle()
            .fill(DS.Colors.separator)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = treeDragBaseWidth ?? treeWidth
                                if treeDragBaseWidth == nil { treeDragBaseWidth = treeWidth }
                                treeWidth = FilePanelPreference.clampTreeWidth(base + value.translation.width)
                            }
                            .onEnded { _ in treeDragBaseWidth = nil }
                    )
            }
            .help(L("拖动调整目录树宽度"))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.statusConnecting)
            Text(message)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(message)
            Spacer(minLength: DS.Space.s)
            Button(L("重试")) { service.retry() }
                .buttonStyle(.glass)
                .controlSize(.mini)
            Button {
                service.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help(L("关闭提示"))
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, 4)
        .background(DS.Colors.statusConnecting.opacity(0.12))
    }

    private var visibleEntries: [RemoteFileEntry] {
        showHidden ? service.entries : service.entries.filter { !$0.isHidden }
    }

    private var selectedEntries: [RemoteFileEntry] {
        visibleEntries.filter { selection.contains($0.id) }
    }

    private func entries(for ids: Set<RemoteFileEntry.ID>) -> [RemoteFileEntry] {
        visibleEntries.filter { ids.contains($0.id) }
    }

    private var remoteTable: some View {
        Table(of: RemoteFileEntry.self, selection: $selection) {
            TableColumn(L("名称")) { entry in
                HStack(spacing: 5) {
                    RemoteFileEntryIcon(entry: entry)
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let target = entry.linkTarget {
                        Text("→ \(target)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .help(entry.linkTarget.map { "\(entry.name) → \($0)" } ?? entry.name)
            }
            .width(min: 130, ideal: 220)

            TableColumn(L("大小")) { entry in
                Text(DualPaneFileView.sizeText(entry.sizeBytes, isDirectory: entry.isDirectory))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 60, max: 80)

            TableColumn(L("修改时间")) { entry in
                Text(DualPaneFileView.dateText(entry.mtimeEpoch))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 118, max: 130)

            TableColumn(L("权限")) { entry in
                Text(entry.permissions)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 78, ideal: 88, max: 110)

            TableColumn(L("用户/组")) { entry in
                Text("\(entry.uid):\(entry.gid)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 64, max: 110)
        } rows: {
            ForEach(visibleEntries) { entry in
                TableRow(entry)
            }
        }
        .contextMenu(forSelectionType: RemoteFileEntry.ID.self) { ids in
            tableContextMenu(ids)
        } primaryAction: { ids in
            handlePrimaryAction(ids)
        }
        .overlay { tableOverlay.allowsHitTesting(false) }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: DS.Radius.small)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.06))
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder
    private var tableOverlay: some View {
        if service.isLoading && service.entries.isEmpty {
            ProgressView()
                .controlSize(.small)
        } else if visibleEntries.isEmpty && !service.isLoading && service.errorMessage == nil {
            Text(verbatim: service.entries.isEmpty ? L("此目录为空") : L("仅有隐藏文件（可在上方工具条开启显示）"))
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Context menu / double click

    @ViewBuilder
    private func tableContextMenu(_ ids: Set<RemoteFileEntry.ID>) -> some View {
        let items = entries(for: ids)
        if !items.isEmpty {
            Button(items.count == 1 ? L("下载") : L("下载 %lld 项", items.count)) {
                service.download(items)
            }
            // One-click extract for an uploaded archive (zip / 7z / rar / tar.* …).
            if items.count == 1, service.canExtract(items[0]) {
                Button(L("解压到当前目录")) { service.extract(items[0]) }
                Button(L("解压到…")) {
                    extractDestText = service.cwd
                    extractTarget = items[0]
                }
            }
            if items.count == 1 {
                if !items[0].isDirectory {
                    if items[0].sizeBytes <= FileService.maxInAppEditBytes {
                        Button("编辑") { editingFile = items[0] }
                    }
                    Button("用外部编辑器打开") { editEntry(items[0]) }
                }
                Button("重命名…") { beginRename(items[0]) }
                Button("权限…") { permissionsTarget = items[0] }
            }
            Button("复制路径") { copyPaths(items) }
        }
        Button("新建文件夹…") { beginNewFolder() }
        Divider()
        Button(service.isComparingDirectory ? L("正在对比本地目录…") : L("与本地目录对比…")) {
            chooseSyncDirectory()
        }
        .disabled(!isReady || service.isComparingDirectory)
        Button("刷新") { service.refresh() }
        if !items.isEmpty {
            Divider()
            Button("删除…", role: .destructive) {
                deleteTargets = items
                deleteConfirmPresented = true
            }
        }
    }

    /// Double click: enter directories (symlinks try to enter; a symlink to
    /// a file surfaces the error banner), download plain files.
    private func handlePrimaryAction(_ ids: Set<RemoteFileEntry.ID>) {
        guard ids.count == 1, let entry = entries(for: ids).first else { return }
        if entry.isDirectory || entry.isSymlink {
            service.open(entry)
        } else {
            service.download([entry])
        }
    }

    private func beginRename(_ entry: RemoteFileEntry) {
        renameText = entry.name
        renameTarget = entry
    }

    private func editEntry(_ entry: RemoteFileEntry) {
        guard !entry.isDirectory else { return }
        service.beginEdit(entry)
    }

    private func beginNewFolder() {
        newFolderName = ""
        newFolderPresented = true
    }

    private func copyPaths(_ items: [RemoteFileEntry]) {
        let text = items.map { service.absolutePath(of: $0) }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Upload (open panel + drop)

    private func chooseUploadFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("上传")
        panel.message = L("选择要上传到 %@ 的文件或文件夹", service.cwd)
        let service = self.service
        panel.begin { response in
            guard response == .OK else { return }
            service.upload(urls: panel.urls)
        }
    }

    private func chooseSyncDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("对比")
        panel.message = L("选择要与 %@ 对比的本地目录", service.cwd)
        let service = self.service
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            service.compareDirectory(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard isReady else { return false }
        let service = self.service
        var accepted = false
        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async {
                    service.upload(urls: [url])
                }
            }
        }
        return accepted
    }

    // MARK: Alert helpers

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private var deleteTitle: String {
        deleteTargets.count == 1
            ? L("删除 \u{201C}%@\u{201D}？", deleteTargets[0].name)
            : L("删除 %lld 个项目？", deleteTargets.count)
    }

    /// Exact remote paths, capped at 8 lines.
    private var deletePathsPreview: String {
        let paths = deleteTargets.map { service.absolutePath(of: $0) }
        if paths.count <= 8 { return paths.joined(separator: "\n") }
        return paths.prefix(8).joined(separator: "\n") + L("\n…等 %lld 项", paths.count)
    }
}

// MARK: - Notification names for inter-pane communication

extension Notification.Name {
    /// Posted by LocalFilePane when the user chooses "上传到服务器". The object
    /// is an array of file:// `URL`s. Handled by RemoteFilePane.
    static let harborUploadLocalFiles = Notification.Name("harborUploadLocalFiles")
}

// MARK: - Permissions editor

/// chmod editor: owner/group/other × read/write/execute toggles initialized
/// from the entry's `ls -l` permission string, with a live octal preview.
private struct PermissionsSheet: View {
    let entry: RemoteFileEntry
    let onApply: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var bits: [Bool]

    init(entry: RemoteFileEntry, onApply: @escaping (String) -> Void) {
        self.entry = entry
        self.onApply = onApply
        _bits = State(initialValue: PermissionsSheet.parse(entry.permissions))
    }

    /// 9 rwx bits → "ugo" octal string, e.g. "755".
    private var octal: String {
        func digit(_ row: Int) -> Int {
            (bits[row * 3] ? 4 : 0) + (bits[row * 3 + 1] ? 2 : 0) + (bits[row * 3 + 2] ? 1 : 0)
        }
        return "\(digit(0))\(digit(1))\(digit(2))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(L("权限")).font(.headline)
            Text(entry.name)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)

            Grid(alignment: .center, horizontalSpacing: DS.Space.m, verticalSpacing: DS.Space.s) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text(L("读")); Text(L("写")); Text(L("执行"))
                }
                .font(.caption).foregroundStyle(.secondary)
                permRow(L("所有者"), 0)
                permRow(L("组"), 1)
                permRow(L("其他"), 2)
            }

            HStack(spacing: DS.Space.s) {
                Text(L("八进制")).font(.caption).foregroundStyle(.secondary)
                Text(octal).font(.system(.title3, design: .monospaced)).fontWeight(.semibold)
                Spacer()
            }

            HStack {
                Spacer()
                Button(L("取消"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("应用")) { onApply(octal); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(DS.Space.l)
        .frame(width: 320)
    }

    private func permRow(_ label: String, _ row: Int) -> some View {
        GridRow {
            Text(label).font(.callout).gridColumnAlignment(.leading)
            Toggle("", isOn: $bits[row * 3]).labelsHidden()
            Toggle("", isOn: $bits[row * 3 + 1]).labelsHidden()
            Toggle("", isOn: $bits[row * 3 + 2]).labelsHidden()
        }
    }

    /// Parses the 9 rwx flags from an `ls -l` string like "-rwxr-xr-x"; any
    /// non-"-" character (incl. s/t special bits) counts as the bit set.
    static func parse(_ permissions: String) -> [Bool] {
        let chars = Array(permissions)
        var bits = [Bool](repeating: false, count: 9)
        guard chars.count >= 10 else { return bits }
        for i in 0..<9 { bits[i] = chars[i + 1] != "-" }
        return bits
    }
}

// MARK: - Notice

/// Centered message for non-data states (connecting, preparing, unsupported,
/// session ended), optionally with one action button.
private struct PanelNotice: View {
    var symbol: String? = nil
    var spinner = false
    let title: String
    var caption: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: DS.Space.s) {
            if spinner {
                ProgressView()
                    .controlSize(.small)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            Text(title)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
