import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HarborKit

/// A `Table` sort comparator that keeps only Sendable values in SwiftUI state.
/// `KeyPathComparator` would otherwise store a non-Sendable Swift key path,
/// which becomes an error under Swift 6 strict concurrency.
private struct RemoteFileEntrySortComparator: SortComparator {
    enum Field: Hashable, Sendable {
        case name
        case size
        case modificationTime
    }

    var field: Field
    var order: SortOrder = .forward

    init(_ field: Field, order: SortOrder = .forward) {
        self.field = field
        self.order = order
    }

    func compare(_ lhs: RemoteFileEntry, _ rhs: RemoteFileEntry) -> ComparisonResult {
        switch field {
        case .name:
            // Finder semantics: localized, case-insensitive, digit-aware — and
            // directories always group first, even when the order is reversed.
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory ? .orderedAscending : .orderedDescending
            }
            let result = lhs.name.localizedStandardCompare(rhs.name)
            return order == .reverse ? Self.flip(result) : result
        case .size:
            let result = Self.ordered(lhs.sizeBytes, rhs.sizeBytes)
            return order == .reverse ? Self.flip(result) : result
        case .modificationTime:
            let result = Self.ordered(lhs.mtimeEpoch, rhs.mtimeEpoch)
            return order == .reverse ? Self.flip(result) : result
        }
    }

    private static func ordered<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }

    private static func flip(_ result: ComparisonResult) -> ComparisonResult {
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        @unknown default: return result
        }
    }
}

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
    @State private var transfersHovering = false
    @State private var sessionState: TerminalSession.State = .connecting

    private var isReady: Bool {
        service.status == .ready && sessionState == .running
    }

    /// F2/End key (NSF2FunctionKey, 0xF705). Always a valid Private Use Area scalar.
    private var endKeyEquivalent: KeyEquivalent {
        if let scalar = UnicodeScalar(0xF705) {
            return KeyEquivalent(Character(scalar))
        }
        // 0xF705 never fails; defensive fallback via Character literal
        return KeyEquivalent("?")
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

    private var hasFailedTransfers: Bool {
        service.transfers.contains { transfer in
            if case .failed = transfer.state { return true }
            return false
        }
    }

    private var transfersButton: some View {
        Button {
            transfersPresented.toggle()
        } label: {
            Image(systemName: service.hasRunningTransfers ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(transferIconStyle)
                .frame(width: 30, height: 26)
                .overlay(alignment: .topTrailing) {
                    if !service.transfers.isEmpty {
                        Text("\(service.transfers.count)")
                            .font(.system(size: 8, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 0.5)
                            .background(Capsule().fill(hasFailedTransfers ? DS.Colors.statusError : SwiftUI.Color.accentColor))
                            .offset(x: 5, y: -2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pressFeedback()
        .onHover { transfersHovering = $0 }
        .help(hasFailedTransfers ? L("有传输失败，点击查看") : L("传输列表"))
        .accessibilityLabel(hasFailedTransfers ? L("有传输失败，点击查看") : L("传输列表"))
        .popover(isPresented: $transfersPresented, arrowEdge: .bottom) {
            TransfersPopoverView(service: service)
        }
    }

    private var transferIconStyle: AnyShapeStyle {
        if hasFailedTransfers { return AnyShapeStyle(DS.Colors.statusError) }
        if service.hasRunningTransfers { return AnyShapeStyle(SwiftUI.Color.accentColor) }
        return transfersHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
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
    @State private var sortOrder: [RemoteFileEntrySortComparator] = [.init(.name)]
    @State private var inlineRenamingID: RemoteFileEntry.ID? = nil
    @State private var inlineRenameText = ""
    @FocusState private var renameFocused: Bool
    @State private var permissionsTarget: RemoteFileEntry?
    @State private var editingFile: RemoteFileEntry?
    @State private var deleteTargets: [RemoteFileEntry] = []
    @State private var deleteConfirmPresented = false
    @State private var newFolderPresented = false
    @State private var newFolderName = ""
    /// Archive awaiting an "解压到…" target path, plus the editable destination.
    @State private var extractTarget: RemoteFileEntry?
    @State private var extractDestText = ""
    /// Entry awaiting a "移动到…" destination path, plus the editable target.
    @State private var moveTarget: RemoteFileEntry?
    @State private var moveDestText = ""
    @State private var isDropTargeted = false
    @State private var sessionState: TerminalSession.State = .connecting
    /// Name filter (⌘F), applied case-insensitively to visible entry names.
    @State private var filterText = ""
    @State private var filterVisible = false
    @FocusState private var filterFocused: Bool
    /// Brief transient hint when an action is dropped (e.g. panel not ready).
    @State private var actionHint: String?
    @State private var actionHintTask: Task<Void, Never>?
    /// Dynamic-Type-aware size for the dense metadata columns (size / date /
    /// permissions / owner). Keeps the former fixed 11pt at the default text
    /// size but now scales with the user's preferred text size.
    @ScaledMetric(relativeTo: .caption) private var columnFontSize: CGFloat = 11

    private var isReady: Bool {
        service.status == .ready && sessionState == .running
    }

    private var canInteract: Bool {
        isReady
    }

    private var canMutate: Bool {
        isReady && !service.isMutating
    }

    var body: some View {
        paneContent
            .onAppear(perform: handleAppear)
            .onReceive(session.$state) { sessionState = $0 }
            .onChange(of: service.cwd, handleCwdChange)
            .onChange(of: service.status, handleStatusChange)
            .onChange(of: service.entries, handleEntriesChange)
            .alert(L("新建文件夹"), isPresented: $newFolderPresented) {
                TextField(L("文件夹名称"), text: $newFolderName)
                Button(L("创建"), action: createFolder)
                    .disabled(!canMutate)
                Button(L("取消"), role: .cancel) {}
            } message: {
                Text(verbatim: L("在 %@ 中创建新文件夹。", service.cwd))
            }
            .alert(L("解压到…"), isPresented: extractPresented) {
                TextField(L("目标目录"), text: $extractDestText)
                Button(L("解压"), action: confirmExtract)
                    .disabled(!canMutate)
                Button(L("取消"), role: .cancel) { extractTarget = nil }
            } message: {
                Text(verbatim: L("把 \u{201C}%@\u{201D} 解压到哪个目录?(支持 ~ 和相对路径)", extractTarget?.name ?? ""))
            }
            .alert(L("移动到…"), isPresented: movePresented) {
                TextField(L("目标路径"), text: $moveDestText)
                Button(L("移动"), action: confirmMove)
                    .disabled(!canMutate || moveDestText.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(L("取消"), role: .cancel) { moveTarget = nil }
            } message: {
                Text(verbatim: L("把 \u{201C}%@\u{201D} 移动到哪个路径？(支持 ~ 和相对路径)", moveTarget?.name ?? ""))
            }
            .alert(deleteTitle, isPresented: $deleteConfirmPresented) {
                Button(L("删除"), role: .destructive, action: confirmDelete)
                    .disabled(!canMutate)
                Button(L("取消"), role: .cancel) { deleteTargets = [] }
            } message: {
                Text(verbatim: L("此操作无法撤销，将删除：\n%@", deletePathsPreview))
            }
            .confirmationDialog(
                uploadConflictTitle,
                isPresented: uploadConflictPresented,
                titleVisibility: .visible,
                actions: { uploadConflictActions },
                message: { uploadConflictMessage }
            )
            .sheet(item: $permissionsTarget, content: permissionsSheet)
            .sheet(item: $editingFile, content: editorSheet)
            .sheet(item: directorySyncBinding, content: directorySyncSheet)
    }

    @ViewBuilder
    private var uploadConflictActions: some View {
        Button(L("覆盖"), role: .destructive) { service.confirmOverwriteUpload() }
        Button(L("跳过冲突项")) { service.confirmSkipConflictsUpload() }
        Button(L("取消"), role: .cancel) { service.cancelPendingUpload() }
    }

    private var uploadConflictMessage: some View {
        Text(verbatim: L("以下文件已存在于远程目录，将如何处理？\n%@", uploadConflictPreview))
    }

    private var movePresented: Binding<Bool> {
        Binding(get: { moveTarget != nil }, set: { if !$0 { moveTarget = nil } })
    }

    private var uploadConflictPresented: Binding<Bool> {
        Binding(
            get: { !service.pendingUploadConflicts.isEmpty },
            set: { if !$0 { service.cancelPendingUpload() } }
        )
    }

    private var uploadConflictTitle: String {
        let count = service.pendingUploadConflicts.count
        return count == 1
            ? L("覆盖 \u{201C}%@\u{201D}？", service.pendingUploadConflicts[0])
            : L("%lld 个同名文件已存在", count)
    }

    private var uploadConflictPreview: String {
        let names = service.pendingUploadConflicts
        if names.count <= 8 { return names.joined(separator: "\n") }
        return names.prefix(8).joined(separator: "\n") + L("\n…等 %lld 项", names.count)
    }

    private var paneContent: some View {
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
    }

    private var extractPresented: Binding<Bool> {
        Binding(get: { extractTarget != nil }, set: { if !$0 { extractTarget = nil } })
    }

    private var directorySyncBinding: Binding<DirectorySyncPreview?> {
        Binding(
            get: { service.directorySyncPreview },
            set: { if $0 == nil { service.dismissDirectorySyncPreview() } }
        )
    }

    private func handleAppear() {
        pathText = service.cwd
        sessionState = session.state
    }

    private func handleCwdChange(_ oldValue: String, _ newValue: String) {
        pathText = newValue
        selection.removeAll()
        // A parked upload conflict was confirmed against the OLD directory;
        // never carry it into a different cwd.
        service.cancelPendingUpload()
    }

    private func handleStatusChange(_ oldValue: FileService.Status, _ status: FileService.Status) {
                if status != .ready {
            editingFile = nil
            permissionsTarget = nil
            extractTarget = nil
            moveTarget = nil
            newFolderPresented = false
            deleteConfirmPresented = false
            inlineRenamingID = nil
            treeModel.stop()
        }
    }

    private func handleEntriesChange(_ oldValue: [RemoteFileEntry], _ newEntries: [RemoteFileEntry]) {
        let live = Set(newEntries.map(\.id))
        selection.formIntersection(live)
    }

    private func createFolder() {
        guard canMutate else { return }
        service.createDirectory(named: newFolderName)
    }

    private func confirmExtract() {
        guard canMutate, let target = extractTarget else {
            extractTarget = nil
            return
        }
        service.extract(target, to: extractDestText)
        extractTarget = nil
    }

    private func confirmMove() {
        guard canMutate, let target = moveTarget else {
            moveTarget = nil
            return
        }
        service.move(target, to: moveDestText)
        moveTarget = nil
    }

    private func confirmDelete() {
        guard canMutate else { return }
        service.delete(deleteTargets)
        deleteTargets = []
        selection.removeAll()
    }

    private func showHint(_ text: String) {
        actionHint = text
        actionHintTask?.cancel()
        actionHintTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            actionHint = nil
        }
    }

    @ViewBuilder
    private func permissionsSheet(_ entry: RemoteFileEntry) -> some View {
        if !entry.isSymlink {
            PermissionsSheet(entry: entry, onApply: { octal in
                service.changePermissions(entry, octal: octal)
            }, onChown: { owner, group in
                service.changeOwner(entry, owner: owner, group: group)
            })
        }
    }

    private func editorSheet(_ entry: RemoteFileEntry) -> some View {
        FileEditorView(entry: entry, service: service)
    }

    private func directorySyncSheet(_ preview: DirectorySyncPreview) -> some View {
        DirectorySyncPreviewSheet(
            preview: preview,
            isApplyEnabled: canInteract
        ) {
            service.applyDirectorySyncPreview()
        }
    }

    // MARK: Remote body

    /// Shared slide-from-top + fade for the status banners that insert at the
    /// top of the list, so appearing / disappearing no longer snaps the table.
    private var bannerTransition: AnyTransition {
        .move(edge: .top).combined(with: .opacity)
    }

    /// One Equatable value that flips whenever any status banner toggles, so a
    /// single `.animation(DS.Anim.state, value:)` drives every banner's insert /
    /// remove (and the table's reflow) smoothly instead of snapping.
    private var bannerSignature: [Bool] {
        [service.errorMessage != nil, service.listingTruncated,
         service.isComparingDirectory, service.isMutating, filterVisible]
    }

    @ViewBuilder
    private var remoteBody: some View {
        VStack(spacing: 0) {
            if let message = service.errorMessage {
                errorBanner(message)
                    .transition(bannerTransition)
            }
            if service.listingTruncated {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.statusConnecting)
                    Text(L("目录条目过多，仅显示前 %lld 项。", FileService.maxDirectoryEntries))
                        .font(.caption)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, 4)
                .background(DS.Colors.statusConnecting.opacity(0.12))
                .transition(bannerTransition)
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
                .transition(bannerTransition)
            }
            if service.isMutating {
                HStack(spacing: DS.Space.s) {
                    ProgressView().controlSize(.small)
                    Text(L("正在执行文件操作…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("取消")) { service.cancelMutation() }
                        .controlSize(.mini)
                        .buttonStyle(.glass)
                }
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, 4)
                .background(DS.Colors.separator.opacity(0.35))
                .transition(bannerTransition)
            }
            if filterVisible {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    TextField(L("筛选文件名"), text: $filterText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .focused($filterFocused)
                        .onSubmit { filterFocused = true }
                    if !filterText.isEmpty {
                        InlineIconButton("xmark.circle.fill", help: L("清除筛选"), size: 10) {
                            filterText = ""
                        }
                    }
                }
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, 4)
                .background(DS.Colors.separator.opacity(0.25))
                .transition(bannerTransition)
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
        .overlay(alignment: .bottom) {
            if let hint = actionHint {
                Text(hint)
                    .font(.caption)
                    .padding(.horizontal, DS.Space.m)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(DS.Colors.separator, lineWidth: 1))
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .animation(DS.Anim.toast, value: actionHint)
        .animation(DS.Anim.state, value: bannerSignature)
        .background {
            // ⌘F reveals and focuses the name-filter field.
            Button("") { filterVisible = true; filterFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
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
                .disabled(!canInteract)
            InlineIconButton("xmark", help: L("关闭提示"), size: 9) {
                service.errorMessage = nil
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, 4)
        .background(DS.Colors.statusConnecting.opacity(0.12))
    }

    private var visibleEntries: [RemoteFileEntry] {
        var filtered = showHidden ? service.entries : service.entries.filter { !$0.isHidden }
        if !filterText.isEmpty {
            filtered = filtered.filter {
                $0.name.localizedCaseInsensitiveContains(filterText)
            }
        }
        return filtered.sorted(using: sortOrder)
    }

    private var selectedEntries: [RemoteFileEntry] {
        visibleEntries.filter { selection.contains($0.id) }
    }

    private func entries(for ids: Set<RemoteFileEntry.ID>) -> [RemoteFileEntry] {
        visibleEntries.filter { ids.contains($0.id) }
    }

    private var remoteTable: some View {
        Table(of: RemoteFileEntry.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(L("名称"), sortUsing: RemoteFileEntrySortComparator(.name)) { entry in
                if entry.id == inlineRenamingID {
                    TextField("", text: $inlineRenameText)
                        .focused($renameFocused)
                        .onSubmit { commitInlineRename() }
                        .disabled(!canMutate)
                        .onKeyPress(.escape) {
                            inlineRenamingID = nil
                            return .handled
                        }
                } else {
                    HStack(spacing: 5) {
                        RemoteFileEntryIcon(entry: entry)
                        Text(entry.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let target = entry.linkTarget {
                            Text("→ \(target)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .help(entry.linkTarget.map { "\(entry.name) → \($0)" } ?? entry.name)
                }
            }
            .width(min: 130, ideal: 220)

            TableColumn(L("大小"), sortUsing: RemoteFileEntrySortComparator(.size)) { entry in
                Text(DualPaneFileView.sizeText(entry.sizeBytes, isDirectory: entry.isDirectory))
                    .font(.system(size: columnFontSize).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 60, max: 80)

            TableColumn(L("修改时间"), sortUsing: RemoteFileEntrySortComparator(.modificationTime)) { entry in
                Text(DualPaneFileView.dateText(entry.mtimeEpoch))
                    .font(.system(size: columnFontSize).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 118, max: 130)

            TableColumn(L("权限")) { entry in
                Text(entry.permissions)
                    .font(.system(size: columnFontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 78, ideal: 88, max: 110)

            TableColumn(L("用户/组")) { entry in
                Text("\(entry.uid):\(entry.gid)")
                    .font(.system(size: columnFontSize).monospacedDigit())
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
        .onKeyPress(KeyEquivalent(Character(UnicodeScalar(0xF705) ?? "?"))) {
            guard selection.count == 1, let entry = selectedEntries.first else {
                return .ignored
            }
            beginRename(entry)
            return .handled
        }
        .onKeyPress(.delete) {
            beginDeleteFromKeyboard()
        }
        .onKeyPress(KeyEquivalent(Character(UnicodeScalar(0xF739) ?? "?"))) {
            beginDeleteFromKeyboard()
        }
        .onChange(of: inlineRenamingID) { _, newID in
            if newID != nil { renameFocused = true }
        }
        .onChange(of: renameFocused) { _, focused in
            // Finder semantics: blurring the inline rename field COMMITS the
            // edit (unless it was dismissed with Escape, which clears the id).
            if !focused { commitInlineRename() }
        }
    }

    /// Delete/Forward-Delete key: same confirm-delete flow as the context menu.
    private func beginDeleteFromKeyboard() -> KeyPress.Result {
        guard canMutate, inlineRenamingID == nil, !selection.isEmpty else { return .ignored }
        deleteTargets = selectedEntries
        guard !deleteTargets.isEmpty else { return .ignored }
        deleteConfirmPresented = true
        return .handled
    }

    /// Commits the in-place rename on blur / submit; Escape bypasses this by
    /// clearing `inlineRenamingID` first.
    private func commitInlineRename() {
        guard let id = inlineRenamingID else { return }
        inlineRenamingID = nil
        guard let entry = service.entries.first(where: { $0.id == id }) else { return }
        let trimmed = inlineRenameText.trimmingCharacters(in: .whitespaces)
        guard canMutate, !trimmed.isEmpty, trimmed != entry.name else { return }
        service.rename(entry, to: trimmed)
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
        let locked = !canInteract
        let mutationLocked = !canMutate
        if !items.isEmpty {
            Button(items.count == 1 ? L("下载") : L("下载 %lld 项", items.count)) {
                service.download(items)
            }
            .disabled(locked)
            Button(L("下载到…")) { chooseDownloadDestination(items) }
                .disabled(locked)
            // One-click extract for an uploaded archive (zip / 7z / rar / tar.* …).
            if items.count == 1, service.canExtract(items[0]) {
                Button(L("解压到当前目录")) { service.extract(items[0]) }
                    .disabled(mutationLocked)
                Button(L("解压到…")) {
                    extractDestText = service.cwd
                    extractTarget = items[0]
                }
                .disabled(mutationLocked)
            }
            if items.count == 1 {
                if !items[0].isDirectory {
                    if items[0].sizeBytes <= FileService.maxInAppEditBytes {
                        Button(L("编辑")) { editingFile = items[0] }
                            .disabled(locked)
                    }
                    Button(L("用外部编辑器打开")) { editEntry(items[0]) }
                        .disabled(locked)
                }
                Button(L("在终端中打开")) {
                    let entry = items[0]
                    let dir = entry.isDirectory
                        ? service.absolutePath(of: entry)
                        : service.cwd
                    session.sendText("cd \(sq(dir))\r")
                }
                .disabled(!isReady)
                Button(L("重命名…")) { beginRename(items[0]) }
                    .disabled(mutationLocked)
                Button(L("移动到…")) {
                    moveDestText = service.cwd
                    moveTarget = items[0]
                }
                .disabled(mutationLocked)
                if !items[0].isSymlink {
                    Button(L("权限…")) { permissionsTarget = items[0] }
                        .disabled(mutationLocked)
                }
            }
            Button(L("复制路径")) { copyPaths(items) }
        }
        Button(L("新建文件夹…")) { beginNewFolder() }
            .disabled(mutationLocked)
        Divider()
        Button(service.isComparingDirectory ? L("正在对比本地目录…") : L("与本地目录对比…")) {
            chooseSyncDirectory()
        }
        .disabled(locked || service.isComparingDirectory)
        Button(L("刷新")) { service.refresh() }
            .disabled(locked)
        if !items.isEmpty {
            Divider()
            Button(L("删除…"), role: .destructive) {
                deleteTargets = items
                deleteConfirmPresented = true
            }
            .disabled(mutationLocked)
        }
    }

    /// Double click: enter directories (symlinks try to enter; a symlink to
    /// a file surfaces the error banner), download plain files.
    private func handlePrimaryAction(_ ids: Set<RemoteFileEntry.ID>) {
        guard canInteract, ids.count == 1, let entry = entries(for: ids).first else { return }
        if entry.isDirectory || entry.isSymlink {
            service.open(entry)
        } else {
            service.download([entry])
        }
    }

    private func beginRename(_ entry: RemoteFileEntry) {
        guard canMutate else { return }
        inlineRenameText = entry.name
        inlineRenamingID = entry.id
    }

    private func editEntry(_ entry: RemoteFileEntry) {
        guard canInteract, !entry.isDirectory else { return }
        service.beginEdit(entry)
    }

    private func beginNewFolder() {
        guard canMutate else { return }
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
        guard canInteract else {
            showHint(L("会话未就绪，暂时无法上传。"))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("上传")
        panel.message = L("选择要上传到 %@ 的文件或文件夹", service.cwd)
        let service = self.service
        panel.begin { response in
            guard response == .OK else { return }
            guard service.canInteract else { return }
            service.upload(urls: panel.urls)
        }
    }

    private func chooseDownloadDestination(_ items: [RemoteFileEntry]) {
        guard canInteract, !items.isEmpty else {
            showHint(L("会话未就绪，暂时无法下载。"))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("下载")
        panel.message = L("选择保存位置")
        let service = self.service
        panel.begin { response in
            guard response == .OK, let url = panel.url, service.canInteract else { return }
            service.download(into: url, items: items)
        }
    }

    private func chooseSyncDirectory() {
        guard canInteract else {
            showHint(L("会话未就绪，暂时无法对比。"))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("对比")
        panel.message = L("选择要与 %@ 对比的本地目录", service.cwd)
        let service = self.service
        panel.begin { response in
            guard response == .OK, let url = panel.url, service.canInteract else { return }
            service.compareDirectory(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canInteract else {
            showHint(L("会话未就绪，暂时无法上传。"))
            return false
        }
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
                Task { @MainActor in
                    guard service.canInteract else {
                        self.showHint(L("会话未就绪，暂时无法上传。"))
                        return
                    }
                    service.upload(urls: [url])
                }
            }
        }
        return accepted
    }

    // MARK: Alert helpers

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

// MARK: - Permissions editor

/// chmod editor: owner/group/other × read/write/execute toggles initialized
/// from the entry's `ls -l` permission string, with a live octal preview.
private struct PermissionsSheet: View {
    let entry: RemoteFileEntry
    let onApply: (String) -> Void
    var onChown: ((String, String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    private let initialMode: POSIXPermissionMode
    private let initialOwnerText: String
    private let initialGroupText: String
    @State private var bits: [Bool]
    @State private var setUserID: Bool
    @State private var setGroupID: Bool
    @State private var sticky: Bool
    @State private var ownerText: String
    @State private var groupText: String

    init(entry: RemoteFileEntry, onApply: @escaping (String) -> Void, onChown: ((String, String) -> Void)? = nil) {
        self.entry = entry
        self.onApply = onApply
        self.onChown = onChown
        let mode = POSIXPermissionMode(lsPermissions: entry.permissions)
        let owner = String(entry.uid)
        let group = String(entry.gid)
        self.initialMode = mode
        self.initialOwnerText = owner
        self.initialGroupText = group
        _bits = State(initialValue: mode.rwx)
        _setUserID = State(initialValue: mode.setUserID)
        _setGroupID = State(initialValue: mode.setGroupID)
        _sticky = State(initialValue: mode.sticky)
        _ownerText = State(initialValue: owner)
        _groupText = State(initialValue: group)
    }

    private var mode: POSIXPermissionMode {
        POSIXPermissionMode(
            rwx: bits,
            setUserID: setUserID,
            setGroupID: setGroupID,
            sticky: sticky
        )
    }

    /// Four-digit octal mode, e.g. "0755" or "4755".
    private var octal: String {
        mode.octal
    }

    private var permissionsChanged: Bool {
        mode != initialMode
    }

    private var trimmedOwnerText: String {
        ownerText.trimmingCharacters(in: .whitespaces)
    }

    private var trimmedGroupText: String {
        groupText.trimmingCharacters(in: .whitespaces)
    }

    private var ownershipChanged: Bool {
        trimmedOwnerText != initialOwnerText || trimmedGroupText != initialGroupText
    }

    private var hasValidOwnership: Bool {
        !trimmedOwnerText.isEmpty && !trimmedGroupText.isEmpty
    }

    /// Do not turn an unchanged sheet into a remote `chmod`/`chown`. A
    /// partially cleared owner/group is also not a valid change to submit.
    private var isDirty: Bool {
        permissionsChanged || (ownershipChanged && hasValidOwnership)
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

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(L("特殊位")).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: DS.Space.m) {
                    Toggle("setuid", isOn: $setUserID)
                    Toggle("setgid", isOn: $setGroupID)
                    Toggle("sticky", isOn: $sticky)
                }
                .toggleStyle(.checkbox)
            }

            HStack(spacing: DS.Space.s) {
                Text(L("八进制")).font(.caption).foregroundStyle(.secondary)
                Text(octal).font(.system(.title3, design: .monospaced)).fontWeight(.semibold)
                Spacer()
            }

            HStack(spacing: DS.Space.s) {
                Text(L("所有者")).font(.caption).foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
                TextField("uid", text: $ownerText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 70)
                Text(L("组")).font(.caption).foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .trailing)
                TextField("gid", text: $groupText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 70)
            }

            HStack {
                Spacer()
                Button(L("取消"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("应用")) {
                    if permissionsChanged {
                        onApply(octal)
                    }
                    if ownershipChanged, hasValidOwnership {
                        onChown?(
                            trimmedOwnerText,
                            trimmedGroupText
                        )
                    }
                    dismiss()
                }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty)
            }
        }
        .padding(DS.Space.l)
        .frame(minWidth: 320)
    }

    private func permRow(_ label: String, _ row: Int) -> some View {
        GridRow {
            Text(label).font(.callout).gridColumnAlignment(.leading)
            Toggle("", isOn: $bits[row * 3]).labelsHidden()
            Toggle("", isOn: $bits[row * 3 + 1]).labelsHidden()
            Toggle("", isOn: $bits[row * 3 + 2]).labelsHidden()
        }
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
