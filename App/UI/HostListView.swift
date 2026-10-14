import SwiftUI
import HarborKit

/// One-shot connect request for chrome that is not the sidebar itself
/// (menu bar, ⌘P jump, empty-state recents). HostListView owns the RDP
/// password sheet, so everyone else just posts a host id here.
@MainActor
enum PendingHostConnect {
    private static var hostID: UUID?

    static func request(_ id: UUID) {
        hostID = id
        NotificationCenter.default.post(name: .harborConnectHost, object: id)
    }

    static func take() -> UUID? {
        defer { hostID = nil }
        return hostID
    }
}

/// Sidebar: searchable host tree grouped by folders (collapsible sections,
/// drag hosts in/out, folder CRUD via context menu and the toolbar menu),
/// full host context menus, add/edit sheets, text bulk import, import from
/// ~/.ssh/config, and a quick-connect footer.
struct HostListView: View {
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var folderStore: HostFolderStore
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var localization: LocalizationManager
    @Binding var selectedHostID: UUID?

    @State private var searchText = ""
    @State private var isAddingHost = false
    @State private var editingHost: SSHHost?
    @State private var hostPendingDeletion: SSHHost?
    @State private var importOutcome: ImportOutcome?
    @State private var rdpPasswordHost: SSHHost?
    @State private var rdpPasswordText = ""
    @State private var rdpNoFreerdp = false
    @State private var rdpAlreadyRunning = false
    @State private var cachedSections: [HostSection] = []
    @State private var cachedLiveHostIDs: Set<UUID> = []
    @State private var cachedMatchCount = 0
    @State private var isImporting = false
    @State private var isImportingText = false
    @State private var isShowingLANDiscovery = false
    /// Folders the user collapsed; everything else stays expanded.
    @State private var collapsedFolders: Set<UUID> = []
    @State private var folderDialog: FolderDialog?
    @State private var folderNameText = ""
    @State private var folderPendingDeletion: HostFolder?

    /// Drag-to-reorder is only meaningful when there are no folders (single
    /// flat section) and no active search filter, so section-relative indices
    /// map 1-to-1 onto the underlying `hostStore.hosts` array.
    private var canReorder: Bool { searchText.isEmpty && folderStore.items.isEmpty }

    private func moveHosts(fromOffsets source: IndexSet, toOffset destination: Int) {
        hostStore.move(fromOffsets: source, toOffset: destination)
        rebuildSections()
    }

    private var hostList: some View {
        List(selection: $selectedHostID) {
            ForEach(cachedSections) { section in
                if let folder = section.folder {
                    Section(isExpanded: expansionBinding(for: folder.id)) {
                        ForEach(section.hosts) { host in
                            row(for: host, isLive: cachedLiveHostIDs.contains(host.id))
                        }
                    } header: {
                        folderHeader(folder, count: section.hosts.count)
                    }
                } else {
                    Section {
                        ForEach(section.hosts) { host in
                            row(for: host, isLive: cachedLiveHostIDs.contains(host.id))
                        }
                        .onMove { source, dest in
                            // Guard so that reordering only applies when all
                            // hosts are in a single flat section with no active
                            // search filter.
                            guard canReorder else { return }
                            moveHosts(fromOffsets: source, toOffset: dest)
                        }
                    } header: {
                        unfiledHeader(title: section.title, count: section.hosts.count)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "搜索主机")
        .help(L("双击主机或按回车连接"))
        .accessibilityHint(L("选择主机后，双击或按回车连接"))
        .contextMenu(forSelectionType: UUID.self) { selection in
            hostContextMenu(for: selection)
        } primaryAction: { selection in
            if let hostID = selection.first, let host = hostStore.host(withID: hostID) {
                connect(host)
            }
        }
        .onKeyPress(.return) {
            guard let id = selectedHostID, let host = hostStore.host(withID: id) else {
                return .ignored
            }
            connect(host)
            return .handled
        }
        .overlay { emptyOverlay }
        .onAppear {
            rebuildSections()
            rebuildLiveIDs()
            consumePendingConnect()
        }
        .onChange(of: searchText) { _, _ in rebuildSections() }
        .onReceive(hostStore.objectWillChange) { _ in
            // Rebuild after the published mutation lands, without snapshotting
            // the whole host array for Equatable comparison.
            DispatchQueue.main.async { rebuildSections() }
        }
        .onReceive(folderStore.objectWillChange) { _ in
            DispatchQueue.main.async { rebuildSections() }
        }
        .onReceive(sessionManager.objectWillChange) { _ in
            DispatchQueue.main.async { rebuildLiveIDs() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .harborConnectHost)) { _ in
            consumePendingConnect()
        }
    }

    var body: some View {
        hostList
        .safeAreaInset(edge: .bottom, spacing: 0) { quickConnectFooter }
        .toolbar { toolbarContent }
        .sheet(isPresented: $isAddingHost) {
            HostEditorView(title: L("新建主机"), saveLabel: L("添加")) { host in
                hostStore.add(host)
                selectedHostID = host.id
            }
            .localized(localization)
        }
        .sheet(item: $editingHost) { host in
            HostEditorView(title: L("编辑主机"), host: host) { hostStore.update($0) }
                .localized(localization)
        }
        .sheet(isPresented: $isImportingText) {
            HostImportTextView()
                .localized(localization)
        }
        .sheet(isPresented: $isShowingLANDiscovery) {
            LANDiscoveryView(
                onAddHosts: { _ = hostStore.importHosts($0) },
                existingHostnames: Set(hostStore.hosts.map(\.hostname))
            )
            .localized(localization)
        }
        .alert(
            folderDialog?.title ?? "",
            isPresented: Binding(
                get: { folderDialog != nil },
                set: { if !$0 { folderDialog = nil } }
            )
        ) {
            TextField(L("文件夹名称"), text: $folderNameText)
            Button(L("好")) { commitFolderDialog() }
                .disabled(HostFolderStore.sanitizedName(folderNameText) == nil)
            Button(L("取消"), role: .cancel) { folderDialog = nil }
        }
        .confirmationDialog(
            L("删除文件夹“%@”？", folderPendingDeletion?.name ?? ""),
            isPresented: Binding(
                get: { folderPendingDeletion != nil },
                set: { if !$0 { folderPendingDeletion = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                if let folder = folderPendingDeletion {
                    // Hosts keep living — they just fall back to the root.
                    folderStore.delete(ids: [folder.id])
                    hostStore.clearFolderReferences(folder.id)
                }
                folderPendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                folderPendingDeletion = nil
            }
        } message: {
            Text(L("文件夹中的主机会移回未分组，不会被删除。"))
        }
        .confirmationDialog(
            L("删除“%@”？", hostPendingDeletion?.displayName ?? ""),
            isPresented: Binding(
                get: { hostPendingDeletion != nil },
                set: { if !$0 { hostPendingDeletion = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                if let host = hostPendingDeletion {
                    if selectedHostID == host.id { selectedHostID = nil }
                    hostStore.delete(host)
                }
                hostPendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                hostPendingDeletion = nil
            }
        } message: {
            Text("此操作无法撤销。")
        }
        .alert(
            importOutcome?.title ?? "",
            isPresented: Binding(
                get: { importOutcome != nil },
                set: { if !$0 { importOutcome = nil } }
            ),
            presenting: importOutcome
        ) { _ in
            Button("好", role: .cancel) { importOutcome = nil }
        } message: { outcome in
            Text(outcome.message)
        }
        .alert(
            L("连接 Windows 远程桌面"),
            isPresented: Binding(
                get: { rdpPasswordHost != nil },
                set: { if !$0 { rdpPasswordHost = nil; rdpPasswordText = "" } }
            )
        ) {
            SecureField(L("密码（可选）"), text: $rdpPasswordText)
            Button(L("连接")) {
                if let host = rdpPasswordHost {
                    sessionManager.connectRDP(host: host, password: rdpPasswordText)
                }
                rdpPasswordHost = nil
                rdpPasswordText = ""
            }
            Button(L("取消"), role: .cancel) {
                rdpPasswordHost = nil
                rdpPasswordText = ""
            }
        } message: {
            Text(L(
                "主机：%@:%lld\nHarbor 将严格验证 RDP 证书；证书不受信任或与主机名不匹配时会被拒绝，不会自动忽略自签名证书。",
                rdpPasswordHost?.hostname ?? "",
                rdpPasswordHost?.port ?? SSHHost.defaultRDPPort
            ))
        }
        .alert(L("需要安装 freerdp"), isPresented: $rdpNoFreerdp) {
            Button(L("复制安装命令")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew install freerdp", forType: .string)
            }
            Button(L("关闭"), role: .cancel) {}
        } message: {
            Text(L("连接 Windows 远程桌面需要 freerdp。\n在终端运行：brew install freerdp"))
        }
        .alert(L("RDP 会话已在运行"), isPresented: $rdpAlreadyRunning) {
            Button(L("好"), role: .cancel) {}
        } message: {
            Text(L("该主机的远程桌面已经连接，重复点击不会新建连接。"))
        }
        .onReceive(NotificationCenter.default.publisher(for: .harborNewHost)) { _ in
            isAddingHost = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .harborImportConfig)) { _ in
            importFromSSHConfig()
        }
    }

    // MARK: - Rows & sections

    @ViewBuilder
    private func row(for host: SSHHost, isLive: Bool) -> some View {
        let rdpConn = sessionManager.rdpConnection(for: host)
        let rdpRunning = rdpConn?.isRunning ?? false
        let rdpError = rdpConn?.errorMessage != nil
        let base = HostRowView(host: host, isLive: isLive, rdpRunning: rdpRunning, rdpError: rdpError)
            .tag(host.id)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        if folderStore.items.isEmpty {
            // No folders: rows participate only in the List's onMove reorder.
            base
        } else {
            // With folders present, onMove reorder is disabled (section
            // indices no longer map onto the store) and drags carry the host
            // id for dropping into folder headers or back onto the root.
            base.draggable(host.id.uuidString)
        }
    }

    /// Folder section header: icon + name + count, drop target for host rows,
    /// context menu for rename/reorder/delete.
    @ViewBuilder
    private func folderHeader(_ folder: HostFolder, count: Int) -> some View {
        let header = HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(folder.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            CountBadge(count: count)
        }
        if searchText.isEmpty {
            header
                .dropDestination(for: String.self) { items, _ in
                    handleHostDrop(items, into: folder.id)
                }
                .contextMenu { folderContextMenu(folder) }
        } else {
            header
        }
    }

    /// The unfiled ("未分组" / "主机") header; doubles as the drop target for
    /// moving a host back out of its folder once folders exist.
    @ViewBuilder
    private func unfiledHeader(title: String, count: Int) -> some View {
        let header = SidebarSectionHeader(title: title, count: count)
        if searchText.isEmpty && !folderStore.items.isEmpty {
            header
                .dropDestination(for: String.self) { items, _ in
                    handleHostDrop(items, into: nil)
                }
        } else {
            header
        }
    }

    @ViewBuilder
    private func folderContextMenu(_ folder: HostFolder) -> some View {
        Button(L("重命名文件夹…")) {
            folderNameText = folder.name
            folderDialog = .rename(folder)
        }
        let ordered = folderStore.folders
        if let index = ordered.firstIndex(where: { $0.id == folder.id }) {
            Button(L("上移")) { folderStore.moveFolder(folder.id, offset: -1) }
                .disabled(index == 0)
            Button(L("下移")) { folderStore.moveFolder(folder.id, offset: 1) }
                .disabled(index == ordered.count - 1)
        }
        Divider()
        Button(L("删除文件夹…"), role: .destructive) {
            folderPendingDeletion = folder
        }
    }

    /// Drop payloads are host id strings (`row` uses `.draggable(uuidString)`).
    private func handleHostDrop(_ items: [String], into folderID: UUID?) -> Bool {
        var moved = false
        for item in items {
            guard let id = UUID(uuidString: item) else { continue }
            hostStore.assign(id, toFolder: folderID)
            moved = true
        }
        return moved
    }

    private func expansionBinding(for folderID: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsedFolders.contains(folderID) },
            set: { expanded in
                if expanded {
                    collapsedFolders.remove(folderID)
                } else {
                    collapsedFolders.insert(folderID)
                }
            }
        )
    }

    private enum FolderDialog: Identifiable {
        case new
        case rename(HostFolder)

        var id: String {
            switch self {
            case .new: return "new"
            case .rename(let folder): return folder.id.uuidString
            }
        }

        @MainActor
        var title: String {
            switch self {
            case .new: return L("新建文件夹")
            case .rename: return L("重命名文件夹")
            }
        }
    }

    private func commitFolderDialog() {
        guard let dialog = folderDialog else { return }
        switch dialog {
        case .new:
            _ = folderStore.createFolder(name: folderNameText)
        case .rename(let folder):
            _ = folderStore.renameFolder(folder.id, name: folderNameText)
        }
        folderDialog = nil
        folderNameText = ""
    }

    @ViewBuilder
    private func hostContextMenu(for selection: Set<UUID>) -> some View {
        if let hostID = selection.first, let host = hostStore.host(withID: hostID) {
            hostContextMenu(for: host)
        }
    }

    @ViewBuilder
    private func hostContextMenu(for host: SSHHost) -> some View {
        let rdpConn = sessionManager.rdpConnection(for: host)
        let rdpRunning = rdpConn?.isRunning ?? false
        if host.connectionProtocol == .rdp {
            if rdpRunning {
                Button(L("断开 RDP")) { sessionManager.disconnectRDP(host: host) }
            } else {
                Button(L("连接 RDP…")) { connect(host) }
            }
            if let errMsg = rdpConn?.errorMessage {
                Text(errMsg).foregroundStyle(.secondary)
            }
        } else {
            Button(L("连接")) { connect(host) }
            Button(L("复制 SSH 命令")) { copySSHCommand(host) }
        }
        Divider()
        Button(L("编辑…")) { editingHost = host }
        Button(L("创建副本")) {
            let copy = hostStore.duplicate(host)
            editingHost = copy
        }
        Divider()
        Button(L("删除…"), role: .destructive) {
            hostPendingDeletion = host
        }
    }

    private struct HostSection: Identifiable {
        /// nil = the unfiled root section.
        let folder: HostFolder?
        let title: String
        let hosts: [SSHHost]

        var id: UUID { folder?.id ?? Self.unfiledID }
        private static let unfiledID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }

    private func rebuildSections() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched: [SSHHost]
        if query.isEmpty {
            matched = hostStore.hosts
        } else {
            matched = hostStore.hosts.filter { hostMatches($0, query: query) }
        }
        cachedMatchCount = matched.count
        cachedSections = groupedSections(from: matched, showEmptyFolders: query.isEmpty)
    }

    private func hostMatches(_ host: SSHHost, query: String) -> Bool {
        if host.name.localizedCaseInsensitiveContains(query) { return true }
        if host.hostname.localizedCaseInsensitiveContains(query) { return true }
        if host.username.localizedCaseInsensitiveContains(query) { return true }
        return host.tags.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func consumePendingConnect() {
        guard let id = PendingHostConnect.take(),
              let host = hostStore.host(withID: id) else { return }
        connect(host)
    }

    private func rebuildLiveIDs() {
        cachedLiveHostIDs = Set(sessionManager.sessions.compactMap { session in
            session.state.isExited ? nil : session.host.id
        })
    }

    /// Sections follow the folder tree: each folder (in folder order) gets a
    /// collapsible section; hosts with a nil or dangling folderID land in the
    /// unfiled root section. With no folders at all the single section keeps
    /// the pre-folder flat look ("主机"). While searching, empty folder
    /// sections collapse away so the list shows only matches.
    private func groupedSections(from hosts: [SSHHost], showEmptyFolders: Bool) -> [HostSection] {
        let folders = folderStore.folders
        guard !folders.isEmpty else {
            return hosts.isEmpty ? [] : [HostSection(folder: nil, title: L("主机"), hosts: hosts)]
        }
        let knownIDs = Set(folders.map(\.id))
        var sections: [HostSection] = folders.map { folder in
            HostSection(
                folder: folder,
                title: folder.name,
                hosts: hosts.filter { $0.folderID == folder.id }
            )
        }
        if !showEmptyFolders {
            sections.removeAll { $0.hosts.isEmpty }
        }
        let unfiled = hosts.filter { host in
            guard let folderID = host.folderID else { return true }
            return !knownIDs.contains(folderID)
        }
        sections.append(HostSection(folder: nil, title: L("未分组"), hosts: unfiled))
        return sections
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if hostStore.hosts.isEmpty {
            ContentUnavailableView {
                Label("暂无主机", systemImage: "server.rack")
            } description: {
                Text("把常用的 SSH 主机保存在这里。")
            } actions: {
                // Stacked vertically: side by side they overflow the
                // sidebar's 220pt minimum width and get clipped.
                VStack(spacing: DS.Space.s) {
                    Button("添加主机…") { isAddingHost = true }
                    Button("从 ~/.ssh/config 导入…") { importFromSSHConfig() }
                        .disabled(isImporting)
                    Button("从文本导入…") { isImportingText = true }
                }
            }
        } else if cachedMatchCount == 0 {
            ContentUnavailableView.search(text: searchText)
        }
    }

    private var quickConnectFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            QuickConnectField()
                .padding(.horizontal, DS.Space.s + 2)
                .padding(.vertical, DS.Space.s + 1)
        }
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // A single toolbar item: click adds a host (primary action), the
        // chevron holds folder creation and the two import paths. A separate
        // ellipsis menu was removed before — it overflowed the toolbar into a
        // `»` at the 980pt minimum width; a Menu with primaryAction stays one
        // compact button.
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button(L("新建文件夹…")) {
                    folderNameText = ""
                    folderDialog = .new
                }
                Divider()
                Button(L("从文本导入…")) { isImportingText = true }
                Button(L("局域网发现…")) { isShowingLANDiscovery = true }
                Button(L("从 ~/.ssh/config 导入…")) { importFromSSHConfig() }
            } label: {
                Label("添加主机", systemImage: "plus")
            } primaryAction: {
                isAddingHost = true
            }
            .help("添加主机 (⌘N)")
        }
    }

    // MARK: - Actions

    /// "连接" (double-click / Enter / context menu): ALWAYS opens a fresh
    /// session tab — clicking connect means connect (Xshell/SecureCRT
    /// behavior); the new tab itself is the visible feedback. For RDP hosts,
    /// shows the password prompt then launches freerdp; a second connect on a
    /// running RDP host surfaces a notice instead of doing nothing.
    private func connect(_ host: SSHHost) {
        if host.connectionProtocol == .rdp {
            if sessionManager.rdpConnection(for: host)?.isRunning == true {
                rdpAlreadyRunning = true
                return
            }
            guard RDPService.isFreerdpInstalled else {
                rdpNoFreerdp = true
                return
            }
            rdpPasswordText = ""
            rdpPasswordHost = host
        } else {
            sessionManager.openSession(host: host)
        }
    }

    /// Copies a ready-to-paste `ssh user@host -p port` using the same
    /// destination shape SSHCommandBuilder dials; -p omitted on default port.
    private func copySSHCommand(_ host: SSHHost) {
        var command = "ssh \(SSHCommandBuilder.destination(for: host))"
        if host.port != SSHHost.defaultPort {
            command += " -p \(host.port)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    // MARK: - Import from ~/.ssh/config

    private enum ImportOutcome {
        case noConfig
        case unreadable(String)
        case unsupportedConfiguration([String])
        case done(imported: Int, skipped: Int)

        @MainActor
        var title: String {
            switch self {
            case .noConfig: return L("未找到 SSH 配置")
            case .unreadable: return L("无法读取 SSH 配置")
            case .unsupportedConfiguration: return L("SSH 配置包含未保留的策略")
            case .done: return L("导入完成")
            }
        }

        @MainActor
        var message: String {
            switch self {
            case .noConfig:
                return L("~/.ssh/config 不存在，没有可导入的内容。你仍然可以用 + 按钮手动添加主机。")
            case .unreadable(let reason):
                return reason
            case .unsupportedConfiguration(let directives):
                return L(
                    "为避免丢失跳板或主机密钥策略，Harbor 未导入此配置。未支持的指令：%@。请使用原始 SSH 别名连接，或先移除这些指令后再导入。",
                    directives.joined(separator: ", ")
                )
            case .done(let imported, let skipped):
                switch (imported, skipped) {
                case (0, 0):
                    return L("~/.ssh/config 中没有可导入的 Host 条目。")
                case (_, 0):
                    return L("已导入 %lld 个主机。", imported)
                case (0, _):
                    return L("没有导入新主机；跳过了 %lld 个条目（名称已存在或无效）。", skipped)
                default:
                    return L("已导入 %lld 个主机；跳过了 %lld 个条目（名称已存在或无效）。", imported, skipped)
                }
            }
        }
    }

    private enum SSHConfigLoadResult: Sendable {
        case loaded([SSHHost])
        case unsupportedConfiguration([String])
        case unreadable(String)
    }

    private func importFromSSHConfig() {
        guard !isImporting else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        guard FileManager.default.fileExists(atPath: url.path) else {
            importOutcome = .noConfig
            return
        }
        isImporting = true
        Task {
            defer { isImporting = false }
            let loaded = await Task.detached(priority: .userInitiated) {
                do {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    let unsupported = SSHConfigParser.unsupportedConnectionDirectives(in: text)
                    guard unsupported.isEmpty else {
                        return SSHConfigLoadResult.unsupportedConfiguration(unsupported)
                    }
                    return SSHConfigLoadResult.loaded(SSHConfigParser.parse(text))
                } catch {
                    return SSHConfigLoadResult.unreadable(error.localizedDescription)
                }
            }.value
            switch loaded {
            case .loaded(let parsed):
                let result = hostStore.importHosts(parsed)
                importOutcome = .done(imported: result.imported, skipped: result.skipped)
            case .unsupportedConfiguration(let directives):
                importOutcome = .unsupportedConfiguration(directives)
            case .unreadable(let reason):
                importOutcome = .unreadable(reason)
            }
        }
    }
}

/// One sidebar row: colored avatar, name, mono user@host subtitle, and a
/// status dot (green = SSH live, blue = RDP running, red = RDP error).
struct HostRowView: View, Equatable {
    let host: SSHHost
    var isLive: Bool = false
    var rdpRunning: Bool = false
    var rdpError: Bool = false

    var body: some View {
        HStack(spacing: DS.Space.s + 1) {
            HostAvatarView(name: host.displayName, osID: host.osID, osName: host.osName)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(host.displayName)
                        .lineLimit(1)
                    if host.connectionProtocol == .rdp {
                        Image(systemName: "display")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else if let osName = host.osName, !osName.isEmpty {
                        Text(osName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // GeoIP decoration; renders EmptyView unless the user
                    // opted in via Settings, so default rows are unchanged.
                    // fixedSize: the subtitle truncates first, the chip keeps
                    // its natural width.
                    HostLocationLabel(host: host.hostname)
                        .lineLimit(1)
                        .fixedSize()
                }
                if !host.notes.isEmpty {
                    Text(host.notes)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: DS.Space.xs)
            if rdpError {
                Image(systemName: DS.StatusSymbol.error)
                    .font(.system(size: 9))
                    .foregroundStyle(DS.Colors.statusError)
                    .help("RDP 连接出错")
                    .accessibilityLabel("RDP 连接出错")
            } else if rdpRunning {
                Image(systemName: DS.StatusSymbol.running)
                    .font(.system(size: 9))
                    .foregroundStyle(.blue)
                    .help("Windows 远程桌面正在运行")
                    .accessibilityLabel("Windows 远程桌面正在运行")
            } else if isLive {
                Image(systemName: DS.StatusSymbol.running)
                    .font(.system(size: 9))
                    .foregroundStyle(DS.Colors.statusRunning)
                    .help("有正在运行的会话")
                    .accessibilityLabel("已连接")
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if host.connectionProtocol == .rdp {
            let user = host.username.isEmpty ? "" : "\(host.username)@"
            let port = host.port != SSHHost.defaultRDPPort ? ":\(host.port)" : ""
            return "rdp://\(user)\(host.hostname)\(port)"
        }
        var text = host.username.isEmpty ? host.hostname : "\(host.username)@\(host.hostname)"
        if host.port != SSHHost.defaultPort {
            text += ":\(host.port)"
        }
        return text
    }
}
