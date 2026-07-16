import SwiftUI
import HarborKit

/// Sidebar: searchable host list grouped into sections by tag ("未分组"
/// last; a host with N tags appears in N sections), full context menus,
/// add/edit sheets, import from ~/.ssh/config, and a quick-connect footer.
struct HostListView: View {
    @EnvironmentObject private var hostStore: HostStore
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
    @State private var cachedSections: [HostSection] = []
    @State private var cachedLiveHostIDs: Set<UUID> = []

    var body: some View {
        List(selection: $selectedHostID) {
            ForEach(cachedSections, id: \.title) { section in
                Section {
                    ForEach(section.hosts) { host in
                        row(for: host, isLive: cachedLiveHostIDs.contains(host.id))
                    }
                } header: {
                    SidebarSectionHeader(title: section.title, count: section.hosts.count)
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
        .overlay { emptyOverlay(filtered: cachedSections.flatMap(\.hosts)) }
        .onAppear { rebuildSections(); rebuildLiveIDs() }
        .onChange(of: searchText) { _, _ in rebuildSections() }
        .onChange(of: hostStore.hosts) { _, _ in rebuildSections() }
        .onChange(of: sessionManager.sessions) { _, _ in rebuildLiveIDs() }
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
        HostRowView(host: host, isLive: isLive, rdpRunning: rdpRunning, rdpError: rdpError)
            .tag(host.id)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
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
            Button(L("在新标签页中连接")) { connectInNewTab(host) }
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

    private struct HostSection {
        let title: String
        let hosts: [SSHHost]
    }

    private func rebuildSections() {
        let filtered = filteredHosts
        cachedSections = groupedSections(from: filtered)
    }

    private func rebuildLiveIDs() {
        cachedLiveHostIDs = Set(sessionManager.sessions.compactMap { session in
            session.state.isExited ? nil : session.host.id
        })
    }

    /// One section per tag, alphabetical (case-insensitive); hosts without
    /// tags land in "未分组", which always sorts last. When no host has any
    /// tag the single section is just titled "主机".
    private func groupedSections(from hosts: [SSHHost]) -> [HostSection] {
        var byTag: [String: [SSHHost]] = [:]
        var tagTitles: [String: String] = [:] // lowercased key -> first-seen spelling
        var untagged: [SSHHost] = []

        for host in hosts {
            let tags = host.tags
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !tags.isEmpty else {
                untagged.append(host)
                continue
            }
            var seen = Set<String>()
            for tag in tags {
                let key = tag.lowercased()
                guard seen.insert(key).inserted else { continue }
                byTag[key, default: []].append(host)
                if tagTitles[key] == nil { tagTitles[key] = tag }
            }
        }

        var result = byTag.keys.sorted().map { key in
            HostSection(title: tagTitles[key] ?? key, hosts: byTag[key]!)
        }
        if !untagged.isEmpty {
            result.append(HostSection(title: result.isEmpty ? L("主机") : L("未分组"), hosts: untagged))
        }
        return result
    }

    /// Search across name, hostname, username, and tags.
    private var filteredHosts: [SSHHost] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return hostStore.hosts }
        return hostStore.hosts.filter { host in
            host.name.lowercased().contains(query)
                || host.hostname.lowercased().contains(query)
                || host.username.lowercased().contains(query)
                || host.tags.contains { $0.lowercased().contains(query) }
        }
    }

    @ViewBuilder
    private func emptyOverlay(filtered: [SSHHost]) -> some View {
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
                }
            }
        } else if filtered.isEmpty {
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
        // Just the add-host button. The former "更多" (ellipsis) menu only held
        // "从 ~/.ssh/config 导入…", which is also in the File menu; it was an
        // extra leading item that, together with the trailing file-panel button
        // and the inspector toggle, overflowed the toolbar into a `»` at the
        // 980pt minimum width (round-3 occlusion complaint). Dropping it keeps
        // every toolbar control visible at the minimum size.
        ToolbarItem(placement: .primaryAction) {
            Button {
                isAddingHost = true
            } label: {
                Label("添加主机", systemImage: "plus")
            }
            .help("添加主机 (⌘N)")
        }
    }

    // MARK: - Actions

    /// "连接": focus an existing live session for this host, else open one.
    /// For RDP hosts, shows password prompt then launches freerdp.
    private func connect(_ host: SSHHost) {
        if host.connectionProtocol == .rdp {
            if let conn = sessionManager.rdpConnection(for: host), conn.isRunning { return }
            guard RDPService.isFreerdpInstalled else {
                rdpNoFreerdp = true
                return
            }
            rdpPasswordText = ""
            rdpPasswordHost = host
        } else {
            if let existing = sessionManager.sessions.first(where: {
                $0.host.id == host.id && !$0.state.isExited
            }) {
                sessionManager.selectedSessionID = existing.id
            } else {
                sessionManager.openSession(host: host)
            }
        }
    }

    /// "在新标签页中连接": always a fresh SSH session (not applicable to RDP).
    private func connectInNewTab(_ host: SSHHost) {
        guard host.connectionProtocol == .ssh else { return }
        sessionManager.openSession(host: host)
    }

    // MARK: - Import from ~/.ssh/config

    private enum ImportOutcome {
        case noConfig
        case unreadable(String)
        case done(imported: Int, skipped: Int)

        @MainActor
        var title: String {
            switch self {
            case .noConfig: return L("未找到 SSH 配置")
            case .unreadable: return L("无法读取 SSH 配置")
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
        case unreadable(String)
    }

    private func importFromSSHConfig() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        guard FileManager.default.fileExists(atPath: url.path) else {
            importOutcome = .noConfig
            return
        }
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                do {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    return SSHConfigLoadResult.loaded(SSHConfigParser.parse(text))
                } catch {
                    return SSHConfigLoadResult.unreadable(error.localizedDescription)
                }
            }.value
            switch loaded {
            case .loaded(let parsed):
                let result = hostStore.importHosts(parsed)
                importOutcome = .done(imported: result.imported, skipped: result.skipped)
            case .unreadable(let reason):
                importOutcome = .unreadable(reason)
            }
        }
    }
}

/// One sidebar row: colored avatar, name, mono user@host subtitle, and a
/// status dot (green = SSH live, blue = RDP running, red = RDP error).
struct HostRowView: View {
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
                Text(subtitle)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                    .help("RDP 连接出错")
                    .accessibilityLabel("RDP 连接出错")
            } else if rdpRunning {
                Circle()
                    .fill(.blue)
                    .frame(width: 7, height: 7)
                    .help("Windows 远程桌面正在运行")
                    .accessibilityLabel("Windows 远程桌面正在运行")
            } else if isLive {
                Circle()
                    .fill(DS.Colors.statusRunning)
                    .frame(width: 7, height: 7)
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
