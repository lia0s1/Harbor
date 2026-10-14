import SwiftUI
import HarborKit

/// LAN discovery sheet: sweeps the local /24s, lists live hosts with MAC and
/// SSH-port state, and hands the selected rows back as SSHHost drafts.
///
/// Self-contained by contract: `onAddHosts` is the ONLY integration point —
/// wiring it to `HostStore.importHosts(_:)` (dedup + injection validation for
/// free) happens at the call site. `existingHostnames` lets the caller mark
/// rows that are already saved.
struct LANDiscoveryView: View {
    /// Receives host drafts (port 22, empty username) built from the selected
    /// rows. The integrator owns persistence.
    let onAddHosts: ([SSHHost]) -> Void
    /// IPs already in the host list — matching rows get an 已存在 badge and
    /// are excluded from pre-selection.
    var existingHostnames: Set<String> = []

    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = LANScanner()
    @State private var selection: Set<DiscoveredHost.ID> = []
    @State private var addedMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 420)
        .onAppear {
            if scanner.phase == .idle { scanner.start() }
        }
        .onDisappear { scanner.cancel() }
        .onChange(of: scanner.phase) { _, newPhase in
            // Pre-select the rows most likely wanted: SSH open, not yet saved.
            // Only when the user hasn't made their own selection this round.
            if newPhase == .done, addedMessage == nil, selection.isEmpty {
                selection = Set(scanner.hosts
                    .filter { $0.sshOpen && !existingHostnames.contains($0.ip) }
                    .map(\.id))
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .foregroundStyle(Color.accentColor)
            Text(L("局域网发现"))
                .font(.headline)
            if !scanner.subnetSummary.isEmpty {
                Text(scanner.subnetSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(L("关闭")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch scanner.phase {
        case .failed(let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button(L("重试")) { scanner.start() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .idle, .scanning:
            if scanner.hosts.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L("正在扫描局域网，请稍候…"))
                        .foregroundStyle(.secondary)
                    progressText
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tableWithHints
            }
        case .done where scanner.hosts.isEmpty:
            VStack(spacing: 8) {
                Text(L("未发现任何主机"))
                    .font(.subheadline.weight(.medium))
                Text(L("可能原因：目标开了防火墙、不在同一 VLAN/网段，或只应答 ARP 的设备太少。可以检查网络后重试。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            tableWithHints
        }
    }

    private var tableWithHints: some View {
        VStack(alignment: .leading, spacing: 6) {
            table
            if scanner.phase == .done, scanner.hosts.count == 1 {
                Text(L("只发现了 %@。其它主机可能开着防火墙、位于其它 VLAN，或未应答 ARP。", scanner.hosts[0].ip))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
        }
    }

    private var table: some View {
        Table(scanner.hosts, selection: $selection) {
            TableColumn(L("IP 地址")) { host in
                HStack(spacing: 6) {
                    Text(host.ip)
                        .font(.system(.body, design: .monospaced))
                    if existingHostnames.contains(host.ip) {
                        Text(L("已存在"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            .width(min: 120, ideal: 150)
            TableColumn(L("主机名")) { host in
                Text(host.hostname ?? "—")
                    .foregroundStyle(host.hostname == nil ? .tertiary : .primary)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 150)
            TableColumn(L("MAC")) { host in
                Text(host.mac ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(host.mac == nil ? .tertiary : .primary)
            }
            .width(min: 130, ideal: 140)
            TableColumn(L("SSH")) { host in
                if host.sshOpen {
                    Label(L("开放"), systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.callout)
                        .foregroundStyle(.green)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 56, ideal: 70)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    @ViewBuilder
    private var progressText: some View {
        if scanner.probeProgress.total > 0 {
            Text(L("已探测 %lld / %lld", scanner.probeProgress.done, scanner.probeProgress.total))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    // MARK: - Footer

    /// Selected rows that aren't already saved — the ones 添加 will consume.
    private var addableSelection: [DiscoveredHost] {
        scanner.hosts.filter { selection.contains($0.id) && !existingHostnames.contains($0.ip) }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            switch scanner.phase {
            case .scanning:
                ProgressView()
                    .controlSize(.small)
                progressText
                Spacer()
                Button(L("停止")) { scanner.cancel() }
            default:
                if let addedMessage {
                    Text(addedMessage)
                        .foregroundStyle(.secondary)
                } else if case .done = scanner.phase {
                    let sshCount = scanner.hosts.filter(\.sshOpen).count
                    Text(L("发现 %lld 台主机，其中 %lld 台开放 SSH。", scanner.hosts.count, sshCount))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("重新扫描")) { scanner.start() }
                Button(L("添加选中为主机（%lld）", addableSelection.count)) { addSelected() }
                    .buttonStyle(.borderedProminent)
                    .disabled(addableSelection.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    private func addSelected() {
        let chosen = addableSelection
        guard !chosen.isEmpty else { return }
        let drafts = chosen.map { host in
            SSHHost(
                name: host.hostname ?? "",
                hostname: host.ip,
                port: SSHHost.defaultPort
            )
        }
        onAddHosts(drafts)
        addedMessage = L("已添加 %lld 台主机。", drafts.count)
        selection.subtract(chosen.map(\.id))
    }
}
