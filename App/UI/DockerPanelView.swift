import SwiftUI
import HarborKit

/// Docker panel: shows containers list with start/stop/rm + images list + logs.
/// Displayed as the "Docker" tab in BottomPanelView when a DockerService is available.
struct DockerPanelView: View {
    @ObservedObject var service: DockerService
    @EnvironmentObject private var sessionManager: SessionManager

    @State private var selectedID: String?
    @State private var showImages = false
    @State private var showLogs = false
    @State private var deleteID: String? = nil
    @State private var imageDeleteID: String? = nil
    @State private var autoFollow = true
    @State private var refreshHover = false
    @State private var errorDismissHover = false
    @State private var logsRefreshHover = false

    private var selectedContainer: DockerContainer? {
        guard let selectedID else { return nil }
        return service.containers.first { $0.id == selectedID }
    }

    private var containerPendingDelete: DockerContainer? {
        guard let deleteID else { return nil }
        return service.containers.first { $0.id == deleteID }
    }

    private var imagePendingDelete: DockerImage? {
        guard let imageDeleteID else { return nil }
        return service.images.first { $0.id == imageDeleteID }
    }

    var body: some View {
        HSplitView {
            containerList
                .frame(minWidth: 220)
            if showImages {
                imageList
                    .frame(minWidth: 200)
            }
            if showLogs, let c = selectedContainer {
                logsPane(for: c)
                    .frame(minWidth: 240)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { service.start() }
        .onDisappear { service.stop() }
        .onChange(of: service.containers) { _, containers in
            if let selectedID, !containers.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
                showLogs = false
            }
            if let deleteID, !containers.contains(where: { $0.id == deleteID }) {
                self.deleteID = nil
            }
        }
        .alert(L("删除容器"), isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) {
            Button(L("删除"), role: .destructive) {
                if let c = containerPendingDelete {
                    service.removeContainer(c)
                }
                deleteID = nil
            }
            .disabled(containerPendingDelete == nil || containerPendingDelete.map { service.isMutating($0.id) } == true)
            Button(L("取消"), role: .cancel) { deleteID = nil }
        } message: {
            if let c = containerPendingDelete {
                Text(L("确定要删除容器\u{201C}%@\u{201D}吗？此操作不可撤销。", c.displayName))
            } else {
                Text(L("该容器已不存在。"))
            }
        }
        .alert(L("删除镜像"), isPresented: Binding(get: { imageDeleteID != nil }, set: { if !$0 { imageDeleteID = nil } })) {
            Button(L("删除"), role: .destructive) {
                if let image = imagePendingDelete {
                    service.removeImage(image)
                }
                imageDeleteID = nil
            }
            .disabled(imagePendingDelete == nil)
            Button(L("取消"), role: .cancel) { imageDeleteID = nil }
        } message: {
            if let image = imagePendingDelete {
                Text(L("确定要删除镜像\u{201C}%@\u{201D}吗？此操作不可撤销。", image.displayName))
            } else {
                Text(L("该镜像已不存在。"))
            }
        }
    }

    private var containerList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(L("容器"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                switch service.status {
                case .loading: ProgressView().controlSize(.small).scaleEffect(0.8)
                case .unavailable(let msg): Text(msg).font(.caption).foregroundStyle(.red).lineLimit(1)
                default: EmptyView()
                }
                Toggle(isOn: $showImages) { Label(L("镜像"), systemImage: "square.stack") }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help(L("显示/隐藏镜像列表"))
                Toggle(isOn: $showLogs) { Label(L("日志"), systemImage: "text.alignleft") }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help(L("显示/隐藏容器日志"))
                    .disabled(selectedContainer == nil)
                Button { service.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(refreshHover ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .pressFeedback()
                .onHover { refreshHover = $0 }
                .help(L("刷新 Docker 状态"))
                .accessibilityLabel(L("刷新 Docker 状态"))
                .disabled(service.isRefreshing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()

            if let error = service.lastError {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button { service.lastError = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(errorDismissHover ? .secondary : .tertiary)
                    }
                    .buttonStyle(.plain)
                    .pressFeedback()
                    .onHover { errorDismissHover = $0 }
                    .help(L("关闭"))
                    .accessibilityLabel(L("关闭"))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            if case .unavailable(let msg) = service.status {
                ContentUnavailableView {
                    Label(L("Docker 不可用"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(msg)
                }
            } else if service.containers.isEmpty && service.status != DockerService.Status.loading {
                ContentUnavailableView {
                    Label(L("没有容器"), systemImage: "cube.box")
                }
            } else {
                List(service.containers, selection: $selectedID) { container in
                    DockerContainerRow(
                        container: container,
                        isBusy: service.isMutating(container.id) || service.logsLoadingID == container.id
                    ) {
                        guard !service.isMutating(container.id) else { return }
                        if container.isRunning {
                            service.stopContainer(container)
                        } else {
                            service.startContainer(container)
                        }
                    } onRestart: {
                        guard !service.isMutating(container.id) else { return }
                        service.restartContainer(container)
                    } onExec: {
                        openExecTerminal(container)
                    } onRemove: {
                        guard !service.isMutating(container.id) else { return }
                        deleteID = container.id
                    } onLogs: {
                        openLogs(for: container)
                    }
                    .tag(container.id)
                    .contextMenu { containerActions(for: container) }
                    .onTapGesture(count: 2) { openExecTerminal(container) }
                }
                .listStyle(.inset)
            }
        }
    }

    /// Shared actions behind the row ••• menu and the context menu.
    @ViewBuilder
    private func containerActions(for container: DockerContainer) -> some View {
        let busy = service.isMutating(container.id)
        Button(container.isRunning ? L("停止") : L("启动")) {
            guard !busy else { return }
            if container.isRunning {
                service.stopContainer(container)
            } else {
                service.startContainer(container)
            }
        }
        .disabled(busy)
        Button(L("重启")) {
            guard !busy else { return }
            service.restartContainer(container)
        }
        .disabled(busy)
        Button(L("打开终端")) { openExecTerminal(container) }
        Button(L("日志…")) { openLogs(for: container) }
        Divider()
        Button(L("删除…"), role: .destructive) {
            guard !busy else { return }
            deleteID = container.id
        }
        .disabled(busy)
    }

    /// Finds the session this DockerService is attached to and opens a new SSH
    /// tab that runs `docker exec -it <id> sh` once connected.
    private func openExecTerminal(_ container: DockerContainer) {
        guard let owner = sessionManager.sessions.first(where: { session in
            sessionManager.docker(for: session) === service
        }) else {
            service.lastError = L("找不到此容器所属的 SSH 会话")
            return
        }
        service.openExecTerminal(for: container, host: owner.host, sessionManager: sessionManager)
    }

    private func openLogs(for container: DockerContainer) {
        selectedID = container.id
        autoFollow = true
        service.followLogs(for: container)
        showLogs = true
    }

    private var imageList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("镜像"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            if service.images.isEmpty {
                ContentUnavailableView {
                    Label(L("没有镜像"), systemImage: "square.stack")
                }
            } else {
                List(service.images) { image in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(image.displayName)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        HStack {
                            Text(image.size)
                            Spacer()
                            Text(image.createdAt)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button(L("删除…"), role: .destructive) { imageDeleteID = image.id }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func logsPane(for container: DockerContainer) -> some View {
        let loading = service.logsLoadingID == container.id
        let logs = service.containerLogs[container.id]
        return VStack(spacing: 0) {
            HStack {
                Text(L("日志：%@", container.displayName))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if loading {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                }
                Toggle(isOn: $autoFollow) {
                    Label(L("跟随"), systemImage: "arrow.down")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(L("自动滚动到最新日志"))
                Button { service.followLogs(for: container) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(logsRefreshHover ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .pressFeedback()
                .onHover { logsRefreshHover = $0 }
                .help(L("重新跟踪日志"))
                .accessibilityLabel(L("重新跟踪日志"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    if let logs {
                        Text(logs)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                        Color.clear
                            .frame(height: 1)
                            .id(DockerLogsBottomAnchor())
                    } else {
                        ProgressView(L("加载日志中…"))
                            .padding()
                    }
                }
                .onChange(of: logs) { _, newLogs in
                    guard autoFollow, newLogs != nil else { return }
                    proxy.scrollTo(DockerLogsBottomAnchor(), anchor: .bottom)
                }
                // Any upward scroll (content offset decreasing) stops following
                // so history can be read; the 跟随 toggle resumes.
                .onScrollGeometryChange(for: Double.self) { geo in
                    geo.contentOffset.y
                } action: { old, new in
                    if new < old - 1 { autoFollow = false }
                }
            }
        }
    }
}

/// Scroll target pinned after the log text for follow-tail autoscrolling.
private struct DockerLogsBottomAnchor: Hashable {}

// Extend DockerService.Status to be Equatable for comparison in body
extension DockerService.Status: Equatable {
    static func == (lhs: DockerService.Status, rhs: DockerService.Status) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.ready, .ready): return true
        case (.unavailable(let a), .unavailable(let b)): return a == b
        default: return false
        }
    }
}

struct DockerContainerRow: View {
    let container: DockerContainer
    var isBusy: Bool = false
    let onToggle: () -> Void
    let onRestart: () -> Void
    let onExec: () -> Void
    let onRemove: () -> Void
    let onLogs: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(container.isRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(container.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(container.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !container.ports.isEmpty {
                    Text(container.ports)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if isBusy {
                ProgressView().controlSize(.small).scaleEffect(0.8)
            }
            Menu {
                Button(container.isRunning ? L("停止") : L("启动"), action: onToggle)
                    .disabled(isBusy)
                Button(L("重启"), action: onRestart)
                    .disabled(isBusy)
                Button(L("打开终端"), action: onExec)
                Button(L("日志…"), action: onLogs)
                    .disabled(isBusy)
                Divider()
                Button(L("删除…"), role: .destructive, action: onRemove)
                    .disabled(isBusy)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isBusy)
        }
        .padding(.vertical, 2)
    }
}
