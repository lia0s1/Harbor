import SwiftUI
import HarborKit

/// Per-host SSH tunnel manager: lists a host's port-forwarding rules with
/// enable/disable toggles and add/edit/delete, and reflects each tunnel's live
/// status from `TunnelManager`. When a live session's `exec` channel is
/// supplied, toggling a tunnel applies it over the running ControlMaster
/// immediately; otherwise the change is saved and takes effect on next connect.
struct TunnelView: View {
    @Binding var tunnels: [TunnelConfiguration]
    @ObservedObject var manager: TunnelManager
    /// Live auxiliary channel of the running session, when connected. `nil`
    /// means no live session — toggles only update the saved configuration.
    var exec: RemoteExec? = nil

    /// Non-nil while the add/edit sheet is open. A fresh value adds; an existing
    /// one edits (save upserts by id).
    @State private var editorTunnel: TunnelConfiguration?

    var body: some View {
        Form {
            Section {
                if tunnels.isEmpty {
                    emptyState
                } else {
                    ForEach($tunnels) { $tunnel in
                        TunnelRow(
                            tunnel: $tunnel,
                            status: manager.status(for: tunnel.id),
                            showLiveStatus: exec != nil,
                            onEnabledChanged: { applyEnabled(tunnel, $0) },
                            onEdit: { editorTunnel = tunnel },
                            onDelete: { delete(tunnel) }
                        )
                    }
                }
            } header: {
                header
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(item: $editorTunnel) { tunnel in
            TunnelEditorSheet(tunnel: tunnel) { upsert($0) }
        }
    }

    // MARK: - Header & empty state

    private var header: some View {
        HStack(spacing: 6) {
            Text(verbatim: L("SSH 隧道"))
            CountBadge(count: tunnels.count)
            Spacer()
            Button {
                editorTunnel = TunnelConfiguration()
            } label: {
                Label(L("添加隧道"), systemImage: "plus")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
        }
    }

    private var emptyState: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "arrow.left.arrow.right")
                .foregroundStyle(.secondary)
            Text(verbatim: L("尚未配置隧道"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, DS.Space.s)
    }

    // MARK: - Mutations

    /// Reacts to a toggle: the binding already flipped `enabled`; when a live
    /// session exists, add/remove the forward on the running connection too.
    private func applyEnabled(_ tunnel: TunnelConfiguration, _ enabled: Bool) {
        guard let exec else { return }
        // Use the freshest copy from the array (label/ports may have changed).
        let config = tunnels.first { $0.id == tunnel.id } ?? tunnel
        Task {
            if enabled {
                await manager.activate(config, using: exec)
            } else {
                await manager.deactivate(config, using: exec)
            }
        }
    }

    private func upsert(_ config: TunnelConfiguration) {
        if let index = tunnels.firstIndex(where: { $0.id == config.id }) {
            tunnels[index] = config
        } else {
            tunnels.append(config)
        }
    }

    private func delete(_ tunnel: TunnelConfiguration) {
        tunnels.removeAll { $0.id == tunnel.id }
        if let exec, manager.isActive(tunnel.id) {
            Task {
                await manager.deactivate(tunnel, using: exec)
                manager.forget(tunnel.id)
            }
        } else {
            manager.forget(tunnel.id)
        }
    }
}

// MARK: - Row

/// One tunnel line: colored type badge, name/endpoint, live status dot, an
/// enable switch, and an ellipsis menu for edit/delete.
private struct TunnelRow: View {
    @Binding var tunnel: TunnelConfiguration
    let status: TunnelManager.Status
    let showLiveStatus: Bool
    let onEnabledChanged: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.m) {
            TunnelTypeBadge(type: tunnel.type)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: tunnel.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(verbatim: tunnel.endpointSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: DS.Space.s)

            if showLiveStatus { statusIndicator }

            Toggle("", isOn: Binding(
                get: { tunnel.enabled },
                set: { newValue in
                    tunnel.enabled = newValue
                    onEnabledChanged(newValue)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            Menu {
                Button(action: onEdit) {
                    Label(L("编辑"), systemImage: "pencil")
                }
                Button(role: .destructive, action: onDelete) {
                    Label(L("删除"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var statusIndicator: some View {
        switch status {
        case .active:
            Circle().fill(DS.Colors.statusRunning)
                .frame(width: 7, height: 7)
                .help(L("已连接"))
        case .activating:
            ProgressView().controlSize(.small).scaleEffect(0.6)
                .frame(width: 7, height: 7)
        case .failed:
            Circle().fill(DS.Colors.statusError)
                .frame(width: 7, height: 7)
                .help(L("连接失败"))
        case .inactive:
            Circle().fill(DS.Colors.statusIdle.opacity(0.4))
                .frame(width: 7, height: 7)
                .help(L("未连接"))
        }
    }
}

// MARK: - Type badge

/// Colored capsule marking a tunnel's mode (Local=blue, Remote=green,
/// Dynamic=orange).
struct TunnelTypeBadge: View {
    let type: TunnelType

    var body: some View {
        Text(verbatim: type.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(type.badgeColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(type.badgeColor.opacity(0.15)))
            .overlay(Capsule().strokeBorder(type.badgeColor.opacity(0.35), lineWidth: 1))
    }
}

extension TunnelType {
    @MainActor var label: String {
        switch self {
        case .local: return L("本地")
        case .remote: return L("远程")
        case .dynamic: return L("动态")
        }
    }

    /// The ssh flag this mode maps to, shown as a hint in the editor picker.
    var flag: String {
        switch self {
        case .local: return "-L"
        case .remote: return "-R"
        case .dynamic: return "-D"
        }
    }

    /// Badge accent color (per the design: Local=blue, Remote=green,
    /// Dynamic=orange). SwiftUI's semantic colors already adapt light/dark.
    var badgeColor: Color {
        switch self {
        case .local: return .blue
        case .remote: return .green
        case .dynamic: return .orange
        }
    }
}

// MARK: - Add / edit sheet

/// Compact add/edit form for a single tunnel. Validates against the same
/// injection-safe builder the connection uses, so anything saved here produces
/// a valid `-L`/`-R`/`-D` spec. Save stays disabled until the draft validates.
private struct TunnelEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (TunnelConfiguration) -> Void

    private let id: UUID
    /// Preserved across the edit so the enabled state is never lost on save.
    private let enabled: Bool

    @State private var type: TunnelType
    @State private var label: String
    @State private var localPortText: String
    @State private var remoteHost: String
    @State private var remotePortText: String

    init(tunnel: TunnelConfiguration, onSave: @escaping (TunnelConfiguration) -> Void) {
        self.onSave = onSave
        self.id = tunnel.id
        self.enabled = tunnel.enabled
        _type = State(initialValue: tunnel.type)
        _label = State(initialValue: tunnel.label)
        _localPortText = State(initialValue: tunnel.localPort == 0 ? "" : String(tunnel.localPort))
        _remoteHost = State(initialValue: tunnel.remoteHost)
        _remotePortText = State(initialValue: tunnel.remotePort == 0 ? "" : String(tunnel.remotePort))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: L("隧道"))
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.top, .horizontal], 20)
                .padding(.bottom, 8)

            Form {
                Section {
                    Picker(L("类型"), selection: $type) {
                        ForEach(TunnelType.allCases, id: \.self) { kind in
                            Text(verbatim: "\(kind.label) (\(kind.flag))").tag(kind)
                        }
                    }
                    .labelsHidden()
                } header: {
                    Text(verbatim: L("类型"))
                } footer: {
                    Text(verbatim: typeHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(L("配置")) {
                    TextField(L("名称"), text: $label, prompt: Text(verbatim: L("可选的显示名称")))
                    TextField(localPortLabel, text: $localPortText, prompt: Text(verbatim: "8080"))
                    if type != .dynamic {
                        TextField(L("目标主机"), text: $remoteHost, prompt: Text(verbatim: "localhost"))
                        TextField(L("目标端口"), text: $remotePortText, prompt: Text(verbatim: "5432"))
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            footer
        }
        .frame(width: 460, height: 440)
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            if let message = validationMessage {
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            GlassEffectContainer(spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Button(L("取消"), role: .cancel) { dismiss() }
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                    Button(L("保存")) { save() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(validationError != nil)
                }
            }
        }
        .padding(20)
    }

    // MARK: - Draft & validation

    private var draft: TunnelConfiguration {
        TunnelConfiguration(
            id: id,
            type: type,
            localPort: Int(localPortText.trimmingCharacters(in: .whitespaces)) ?? 0,
            remoteHost: remoteHost.trimmingCharacters(in: .whitespaces),
            remotePort: Int(remotePortText.trimmingCharacters(in: .whitespaces)) ?? 0,
            enabled: enabled,
            label: label.trimmingCharacters(in: .whitespaces)
        )
    }

    /// Non-nil while the draft cannot produce a valid tunnel. Messages mirror
    /// the host editor's port-forward validation.
    private var validationError: String? {
        guard (1...65535).contains(draft.localPort) else {
            return L("端口必须是 1 到 65535 之间的数字。")
        }
        if type != .dynamic {
            guard !draft.remoteHost.isEmpty else { return L("请填写目标主机。") }
            guard (1...65535).contains(draft.remotePort) else {
                return L("目标端口必须在 1 到 65535 之间。")
            }
        }
        do {
            _ = try TunnelManager.arguments(for: draft)
        } catch {
            return harborErrorMessage(error)
        }
        return nil
    }

    /// The error banner stays hidden while the form is still untouched (all
    /// fields empty), so a fresh sheet doesn't open shouting a port error.
    private var validationMessage: String? {
        isPristine ? nil : validationError
    }

    private var isPristine: Bool {
        localPortText.isEmpty && remoteHost.isEmpty
            && remotePortText.isEmpty && label.isEmpty
    }

    private var localPortLabel: String {
        type == .remote ? L("远程绑定端口") : L("本地端口")
    }

    private var typeHelp: String {
        switch type {
        case .local: return L("本地转发（-L）：把本机端口的连接转发到服务器可达的目标。")
        case .remote: return L("远程转发（-R）：把服务器端口的连接转发回本机可达的目标。")
        case .dynamic: return L("动态转发（-D）：在本机开启一个 SOCKS 代理端口。")
        }
    }

    private func save() {
        guard validationError == nil else { return }
        onSave(draft)
        dismiss()
    }
}
