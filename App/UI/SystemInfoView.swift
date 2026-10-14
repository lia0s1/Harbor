import SwiftUI
import AppKit
import HarborKit

// MARK: - Sheet

/// FinalShell's 系统信息 report as a Mac-native sheet: a one-shot detailed probe
/// (OS, kernel, CPU, memory, interfaces, filesystems) over the session's own
/// ControlMaster socket, laid out as clean grouped rows on the cheap flat
/// `statCard()` surface (NO live Liquid Glass — this content is static once
/// loaded, but we keep the same frosted-flat look as the monitor cards).
struct SystemInfoView: View {
    @ObservedObject var service: SystemInfoService
    let hostDisplayName: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ServerPrivacy.maskIPKey) private var maskIP = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 460, height: 560)
        // Usually a no-op or an instant render: the report is PREFETCHED when
        // the session connects (SessionManager) and the last good probe is
        // cached on disk per host, so opening this sheet shows the in-memory
        // result or the disk snapshot (marked with its age) while a fresh
        // probe runs in the background. Only fetch here if nothing has been
        // loaded yet. Do NOT cancel on disappear — that would kill the
        // background prefetch and the cached result other opens rely on; the
        // service is cleaned up when the session closes.
        .onAppear { service.fetchIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "cpu")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("系统信息"))
                    .font(.headline)
                Text(ServerPrivacy.mask(hostDisplayName, when: maskIP))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: DS.Space.s)
            Button { maskIP.toggle() } label: {
                Image(systemName: maskIP ? "eye.slash" : "eye")
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
            .help(maskIP ? L("显示 IP 地址") : L("隐藏 IP 地址"))
            if isRefreshable {
                Button {
                    service.fetch()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .help(L("刷新"))
                .disabled(service.isRefreshing)
            }
            Button(L("完成")) { dismiss() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(DS.Space.m)
    }

    /// The report can be refetched once it is in a terminal state (loaded /
    /// unsupported / failed) or while showing a cached snapshot; hide the
    /// refresh control only during the first-ever contentless load.
    private var isRefreshable: Bool {
        switch service.state {
        case .idle, .loading: return false
        case .cached, .loaded, .unsupported, .failed: return true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch service.state {
        case .idle, .loading:
            SystemInfoNotice(spinner: true, title: L("正在读取系统信息…"))
        case .unsupported(let os):
            SystemInfoNotice(
                symbol: "exclamationmark.triangle",
                title: L("此服务器系统暂不支持"),
                caption: L("检测到系统：%@（目前仅支持 Linux）。", os)
            )
        case .failed(let reason):
            SystemInfoNotice(
                symbol: "wifi.exclamationmark",
                title: L("读取失败"),
                caption: reason,
                actionTitle: L("重试"),
                action: { service.fetch() }
            )
        // cached/loaded share ONE branch on purpose: same view identity, so
        // a background refresh landing (cached → loaded) swaps the banner for
        // fresh values in place instead of resetting the user's scroll.
        case .cached(let info, let fetchedAt), .loaded(let info, let fetchedAt):
            SystemInfoReport(
                info: info, fetchedAt: fetchedAt,
                isSnapshot: service.state.isSnapshot,
                isRefreshing: service.isRefreshing
            )
        }
    }
}

// MARK: - Report

private struct SystemInfoReport: View {
    let info: SystemInfo
    let fetchedAt: Date
    /// True while rendering the on-disk snapshot: drifting fields (运行时间,
    /// memory, disk) are from the snapshot moment and marked accordingly.
    let isSnapshot: Bool
    let isRefreshing: Bool
    @AppStorage(ServerPrivacy.maskIPKey) private var maskIP = false
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                if isSnapshot { snapshotBanner }
                systemSection
                cpuSection
                memorySection
                if !info.interfaces.isEmpty { networkSection }
                if !info.filesystems.isEmpty { diskSection }
            }
            .padding(DS.Space.m)
        }
    }

    /// "上次更新：3 分钟前 · 正在刷新…" — marks everything below as a snapshot
    /// so drifting fields are not mistaken for live values.
    private var snapshotBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10, weight: .semibold))
            Text(snapshotCaption)
                .lineLimit(1)
                .truncationMode(.tail)
            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Space.m - 2)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statCard()
    }

    private var snapshotCaption: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = locale
        let age = formatter.localizedString(for: fetchedAt, relativeTo: Date())
        let base = L("上次更新：%@", age)
        return isRefreshing ? "\(base) · \(L("正在刷新…"))" : base
    }

    // MARK: 系统

    private var systemSection: some View {
        SystemInfoGroup(title: L("系统"), symbol: "server.rack") {
            if !info.prettyName.isEmpty {
                SystemInfoRow(label: L("操作系统"), value: info.prettyName)
            }
            SystemInfoRow(label: L("内核"), value: info.kernel.isEmpty ? "—" : info.kernel)
            SystemInfoRow(label: L("架构"), value: info.arch.isEmpty ? "—" : info.arch)
            SystemInfoRow(label: L("主机名"), value: info.hostname.isEmpty ? "—" : ServerPrivacy.mask(info.hostname, when: maskIP))
            // A snapshot's uptime is the value AT the snapshot moment — mark
            // it so it is not read as live; the background refresh replaces
            // it with the fresh value within seconds.
            SystemInfoRow(
                label: L("运行时间"),
                value: MonitorFormat.uptime(seconds: info.uptimeSeconds, locale: locale)
                    + (isSnapshot ? L("（快照）") : "")
            )
        }
    }

    // MARK: CPU

    private var cpuSection: some View {
        SystemInfoGroup(title: L("处理器"), symbol: "cpu") {
            SystemInfoRow(label: L("型号"), value: info.cpuModel.isEmpty ? "—" : info.cpuModel)
            SystemInfoRow(label: L("核心数"), value: info.cpuCores > 0 ? "\(info.cpuCores)" : "—")
            if info.cpuMHz > 0 {
                SystemInfoRow(label: L("主频"), value: String(format: "%.0f MHz", info.cpuMHz.rounded()))
            }
        }
    }

    // MARK: 内存

    private var memorySection: some View {
        SystemInfoGroup(title: L("内存"), symbol: "memorychip") {
            SystemInfoRow(
                label: L("内存"),
                value: MonitorFormat.sizePair(info.memUsedKB, info.memTotalKB)
            )
            if info.swapTotalKB > 0 {
                SystemInfoRow(
                    label: L("交换"),
                    value: MonitorFormat.sizePair(info.swapUsedKB, info.swapTotalKB)
                )
            } else {
                SystemInfoRow(label: L("交换"), value: L("未启用"))
            }
        }
    }

    // MARK: 网络

    private var networkSection: some View {
        SystemInfoGroup(title: L("网络"), symbol: "network") {
            ForEach(Array(info.interfaces.enumerated()), id: \.element.name) { index, iface in
                if index > 0 {
                    Divider().padding(.vertical, 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(iface.name)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    ForEach(iface.addresses, id: \.self) { address in
                        Text(ServerPrivacy.mask(address, when: maskIP))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 磁盘

    private var diskSection: some View {
        SystemInfoGroup(title: L("文件系统"), symbol: "internaldrive") {
            ForEach(Array(info.filesystems.enumerated()), id: \.element.mount) { index, fs in
                if index > 0 {
                    Divider().padding(.vertical, 1)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                        Text(fs.mount)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(fs.mount)
                        Spacer(minLength: DS.Space.s)
                        Text(MonitorFormat.sizePair(fs.usedKB, fs.totalKB))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: DS.Space.s) {
                        Text(fs.device)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text(MonitorFormat.percent(fs.usedFraction * 100))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Building blocks

/// A titled flat card grouping related System Info rows. Uses the cheap
/// `statCard()` fill (no live Liquid Glass), matching the round-1 monitor card
/// redesign so the report reads as part of the same family.
private struct SystemInfoGroup<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: DS.Space.s - 2) {
                content
            }
        }
        .padding(.horizontal, DS.Space.m - 2)
        .padding(.vertical, DS.Space.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statCard()
    }
}

/// "Label … value" row; value is selectable and middle-truncates.
private struct SystemInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(value)
        }
    }
}

/// Centered message for the non-data states (loading, unsupported, failed),
/// optionally with a retry button.
private struct SystemInfoNotice: View {
    var symbol: String? = nil
    var spinner = false
    let title: String
    var caption: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: DS.Space.s) {
            Spacer()
            if spinner {
                ProgressView().controlSize(.small)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .light))
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
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Space.l)
    }
}
