import SwiftUI
import HarborKit

/// Docker panel: shows containers list with start/stop/rm + images list + logs.
/// Displayed as the "Docker" tab in BottomPanelView when a DockerService is available.
struct DockerPanelView: View {
    @ObservedObject var service: DockerService

    @State private var selectedContainer: DockerContainer?
    @State private var showImages = false
    @State private var showLogs = false

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
    }

    private var containerList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("容器")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                switch service.status {
                case .loading: ProgressView().scaleEffect(0.6)
                case .unavailable(let msg): Text(msg).font(.caption).foregroundStyle(.red).lineLimit(1)
                default: EmptyView()
                }
                Toggle(isOn: $showImages) { Label("镜像", systemImage: "square.stack") }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("显示/隐藏镜像列表")
                Toggle(isOn: $showLogs) { Label("日志", systemImage: "text.alignleft") }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("显示/隐藏容器日志")
                    .disabled(selectedContainer == nil)
                Button { service.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.plain)
                .help("刷新 Docker 状态")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()

            if case .unavailable(let msg) = service.status {
                ContentUnavailableView("Docker 不可用", systemImage: "exclamationmark.triangle", description: Text(msg))
            } else if service.containers.isEmpty && service.status != DockerService.Status.loading {
                ContentUnavailableView("没有容器", systemImage: "cube.box")
            } else {
                List(service.containers, selection: $selectedContainer) { container in
                    DockerContainerRow(container: container) {
                        if container.isRunning {
                            service.stopContainer(container)
                        } else {
                            service.startContainer(container)
                        }
                    } onRemove: {
                        service.removeContainer(container)
                    } onLogs: {
                        selectedContainer = container
                        service.fetchLogs(for: container)
                        showLogs = true
                    }
                    .tag(container)
                }
                .listStyle(.inset)
            }
        }
    }

    private var imageList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("镜像")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            if service.images.isEmpty {
                ContentUnavailableView("没有镜像", systemImage: "square.stack")
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
                }
                .listStyle(.inset)
            }
        }
    }

    private func logsPane(for container: DockerContainer) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("日志：\(container.displayName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button { service.fetchLogs(for: container) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("刷新日志")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            ScrollView {
                if let logs = service.containerLogs[container.id] {
                    Text(logs)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                } else {
                    ProgressView("加载日志中…")
                        .padding()
                }
            }
        }
    }
}

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
    let onToggle: () -> Void
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
            Menu {
                Button(container.isRunning ? "停止" : "启动", action: onToggle)
                Button("日志…", action: onLogs)
                Divider()
                Button("删除…", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }
}
