import SwiftUI
import HarborKit

// MARK: - Live port forwarding

/// Per-forward row: kind badge, bind → target detail, and an enable/disable
/// toggle. Calls `ForwardingService.enableForward` / `.disableForward` to
/// add/remove the rule on the live ControlMaster without reconnecting.
struct ForwardingDetailView: View {
    @ObservedObject var service: ForwardingService
    @State private var showingDraft = false
    @State private var currentDraft = ForwardDraft()
    @State private var draftError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(service.forwards) { forward in
                ForwardRow(service: service, forward: forward)
            }
            ForEach(service.adHocForwards) { forward in
                ForwardRow(service: service, forward: forward, isAdHoc: true)
            }
            if service.forwards.isEmpty && service.adHocForwards.isEmpty && !showingDraft {
                Text(L("未配置端口转发"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let error = service.lastError {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Colors.statusError)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
            if showingDraft {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    ForwardEditorRow(forward: $currentDraft) {
                        showingDraft = false
                        draftError = nil
                    }
                    if let error = draftError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(DS.Colors.statusError)
                    }
                    HStack(spacing: DS.Space.s) {
                        Button(L("确认")) { commitDraft() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(service.busy)
                        Button(L("取消")) {
                            showingDraft = false
                            draftError = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(DS.Space.s)
                .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(DS.Colors.barTrack))
            }
            if service.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("正在更新…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !showingDraft {
                Button {
                    currentDraft = ForwardDraft()
                    draftError = nil
                    service.lastError = nil
                    showingDraft = true
                } label: {
                    Label(L("添加转发"), systemImage: "plus")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .disabled(service.busy)
            }
        }
    }

    private func commitDraft() {
        switch currentDraft.build() {
        case .success(let forward):
            draftError = nil
            showingDraft = false
            let f = forward
            Task { await service.addAdHocForward(f) }
        case .failure(let failure):
            draftError = failure.message
        }
    }
}

struct ForwardRow: View {
    @ObservedObject var service: ForwardingService
    let forward: PortForward
    /// Ad-hoc forwards show a trash button and can be removed from the live session.
    var isAdHoc: Bool = false

    /// True while this row's toggle action is in flight (prevents double-tap).
    @State private var pending = false

    private var isEnabled: Bool {
        service.enabled[forward.id] == true
    }

    private func toggleEnabled() {
        guard !pending else { return }
        pending = true
        Task {
            let ok: Bool
            if isEnabled {
                ok = await service.disableForward(forward)
            } else {
                ok = await service.enableForward(forward)
            }
            // Pending clears regardless; the service publishes the new state.
            pending = ok ? false
                : await { try? await Task.sleep(nanoseconds: 300_000_000); return false }()
        }
    }

    private func removeAdHoc() {
        guard !pending else { return }
        pending = true
        Task { await service.removeAdHocForward(forward) }
    }

    var body: some View {
        HStack(spacing: DS.Space.s) {
            // Status dot: green when enabled, grey when not (or unknown).
            Circle()
                .fill(isEnabled ? AnyShapeStyle(DS.Colors.statusRunning) : AnyShapeStyle(.tertiary))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                // Kind badge
                Text(forward.kind.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                // Bind → target spec
                HStack(spacing: 3) {
                    Text(bindSpec)
                        .font(.system(size: 11, design: .monospaced))
                    if forward.kind != .dynamic {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text("\(forward.targetHost):\(forward.targetPort)")
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer(minLength: DS.Space.s)

            if pending {
                ProgressView().controlSize(.small)
            } else {
                if isAdHoc {
                    Button(action: removeAdHoc) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("移除此转发"))
                }
                Toggle(isOn: Binding(get: { isEnabled }, set: { _ in toggleEnabled() })) {
                    EmptyView()
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var bindSpec: String {
        if let addr = forward.bindAddress?.trimmingCharacters(in: .whitespaces), !addr.isEmpty {
            return "\(addr):\(forward.bindPort)"
        }
        return ":\(forward.bindPort)"
    }
}
