import SwiftUI
import AppKit
import Charts
import HarborKit

// MARK: - Visibility preference

/// Shared storage for the monitor inspector's visibility: the toolbar button,
/// the ⌘I menu toggle and the inspector itself all bind to the same key.
enum MonitorPanelPreference {
    static let storageKey = "monitorPanelVisible"
    static let defaultVisible = true
}

/// A process targeted by a 结束进程 / 强制结束 action, shared by the compact
/// 进程 card (here) and the 进程详情 sheet, so both raise the same confirmation.
struct ProcessKillTarget: Identifiable {
    let process: TopProcess
    let signal: MonitorService.KillSignal
    var id: Int { process.pid }
}

// MARK: - Panel root

/// FinalShell's left monitoring rail reborn as a Mac-native trailing
/// inspector: per-session agentless stats (uptime / load / CPU / memory /
/// top processes / network / disks, read from /proc over the session's own
/// ControlMaster socket) plus a local ping latency sparkline.
///
/// Standard chrome: follows the app appearance (light/dark), unlike the
/// theme-tinted terminal surface.
struct MonitorPanel: View {
    @EnvironmentObject private var sessionManager: SessionManager

    var body: some View {
        Group {
            if let session = sessionManager.selectedSession,
               let monitor = sessionManager.monitor(for: session),
               let ping = sessionManager.ping(for: session) {
                MonitorPanelContent(session: session, monitor: monitor, ping: ping)
                    .id(session.id) // fresh scroll position per session
            } else {
                VStack {
                    Spacer()
                    MonitorNotice(
                        symbol: "gauge",
                        title: L("未连接"),
                        caption: L("打开一个会话后，这里会显示服务器的实时监控。")
                    )
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Per-session content

private struct MonitorPanelContent: View {
    @EnvironmentObject private var sessionManager: SessionManager
    // Not @ObservedObject — session.title fires 1-3×/sec via shell escapes,
    // which would re-render 12 stat cards + Swift Charts at that rate.
    // Only session.state and autoReconnectAttempt matter here; tracked below.
    let session: TerminalSession
    @ObservedObject var monitor: MonitorService
    // Plain let — not @ObservedObject. Ping updates must only redraw
    // LatencyCardView, not the entire panel (12 cards × every ping reply).
    let ping: PingService
    /// The single presented sheet: either the 系统信息 report or a per-card
    /// detail. One `.sheet(item:)` so two sheets are never stacked on one view.
    @State private var activeSheet: MonitorSheet?
    @AppStorage(ServerPrivacy.maskIPKey) private var maskIP = false
    /// Process awaiting a kill confirmation, raised from the compact 进程 card's
    /// right-click menu. (The 进程详情 sheet has its own equivalent state.)
    @State private var pendingKill: ProcessKillTarget?
    @State private var sessionState: TerminalSession.State = .connecting
    @State private var autoReconnectAttempt = 0
    @State private var alertSettingsPresented = false
    @ScaledMetric(relativeTo: .callout) private var hostnameFontSize: CGFloat = 12

    private var forwarding: ForwardingService? {
        sessionManager.forwarding(for: session)
    }

    var body: some View {
        ScrollView {
            // No GlassEffectContainer here: the stat cards below use a cheap
            // flat `statCard()` fill (no live GPU blur), so wrapping them in a
            // glass container would only add per-frame rasterization cost on
            // every 2s tick — the round-4 monitor-lag fix.
            VStack(alignment: .leading, spacing: DS.Space.s) {
                header
                stateBody
            }
            .padding(DS.Space.m)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .systemInfo:
                SystemInfoView(
                    service: sessionManager.systemInfo(for: session),
                    hostDisplayName: session.host.displayName
                )
            case .detail(let kind):
                MonitorDetailSheet(
                    kind: kind,
                    monitor: monitor,
                    ping: ping,
                    forwarding: forwarding,
                    tcpPing: sessionManager.tcpPing(for: session),
                    traceroute: sessionManager.traceroute(for: session)
                )
            }
        }
        .confirmationDialog(
            killTitle(pendingKill),
            isPresented: Binding(
                get: { pendingKill != nil },
                set: { if !$0 { pendingKill = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingKill
        ) { target in
            Button(target.signal == .kill ? L("强制结束") : L("结束进程"), role: .destructive) {
                Task { await monitor.terminate(pid: Int32(target.process.pid), signal: target.signal) }
            }
            Button(L("取消"), role: .cancel) {}
        }
        .onAppear {
            sessionState = session.state
            autoReconnectAttempt = session.autoReconnectAttempt
        }
        .onReceive(session.$state) { sessionState = $0 }
        .onReceive(session.$autoReconnectAttempt) { autoReconnectAttempt = $0 }
    }

    /// Confirmation prompt naming the signal, command and pid being targeted.
    private func killTitle(_ target: ProcessKillTarget?) -> String {
        guard let target else { return "" }
        let verb = target.signal == .kill ? L("强制结束") : L("结束进程")
        return L("%@：%@（PID %lld）？", verb, target.process.command, Int(target.process.pid))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            // Shape-redundant state glyph (not color alone) with an animated
            // color switch, mirroring the session-tab indicator.
            Image(systemName: stateSymbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(stateColor)
                .frame(width: 9, height: 9)
                .animation(DS.Anim.state, value: sessionState)
                .accessibilityLabel(stateAccessibilityLabel)
            Text(ServerPrivacy.mask(session.host.displayName, when: maskIP))
                .font(.system(size: hostnameFontSize, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(ServerPrivacy.mask(session.host.displayName, when: maskIP))
            Spacer(minLength: 0)
            MonitorIconButton(
                systemName: monitor.activeAlerts.isEmpty ? "bell" : "bell.badge.fill",
                label: L("监控告警设置"),
                size: 12,
                rest: monitor.activeAlerts.isEmpty
                    ? AnyShapeStyle(.secondary) : AnyShapeStyle(DS.Colors.statusError),
                hover: monitor.activeAlerts.isEmpty
                    ? AnyShapeStyle(.primary) : AnyShapeStyle(DS.Colors.statusError.opacity(0.7)),
                box: CGSize(width: 20, height: 20)
            ) {
                alertSettingsPresented.toggle()
            }
            .popover(isPresented: $alertSettingsPresented, arrowEdge: .top) {
                MonitorAlertSettingsView(monitor: monitor)
            }
        }
    }

    private var stateColor: Color {
        switch sessionState {
        case .connecting: return DS.Colors.statusConnecting
        case .running: return DS.Colors.statusRunning
        case .exited(let code): return (code ?? 1) == 0 ? DS.Colors.statusIdle : DS.Colors.statusError
        }
    }

    /// Shape-redundant state glyph paired with `stateColor` so state reads
    /// without hue (color-blind / grayscale / VoiceOver), per `DS.StatusSymbol`.
    private var stateSymbol: String {
        switch sessionState {
        case .connecting: return DS.StatusSymbol.connecting
        case .running: return DS.StatusSymbol.running
        case .exited(let code): return (code ?? 1) == 0 ? DS.StatusSymbol.idle : DS.StatusSymbol.error
        }
    }

    private var stateAccessibilityLabel: String {
        switch sessionState {
        case .connecting: return L("连接中")
        case .running: return L("已连接")
        case .exited(let code): return (code ?? 1) == 0 ? L("已断开") : L("连接出错")
        }
    }

    // MARK: Session / monitor states

    @ViewBuilder
    private var stateBody: some View {
        switch sessionState {
        case .connecting:
            MonitorNotice(
                spinner: true,
                title: L("正在连接…"),
                caption: L("会话建立后开始采集监控数据。")
            )
        case .exited:
            if autoReconnectAttempt > 0 {
                // Spinning connecting glyph (shape + motion, not a bare spinner)
                // so the auto-reconnect state never reads as frozen.
                MonitorNotice(
                    symbol: DS.StatusSymbol.connecting,
                    rotating: true,
                    symbolTint: AnyShapeStyle(DS.Colors.statusConnecting),
                    title: L("连接已断开，正在自动重连…"),
                    caption: L("第 %lld 次尝试（共 %lld 次）", autoReconnectAttempt, 5),
                    actionTitle: L("立即重连"),
                    action: { sessionManager.reconnect(session) }
                )
            } else {
                MonitorNotice(
                    symbol: "moon.zzz",
                    title: L("会话已结束"),
                    caption: L("重新连接后将恢复监控。"),
                    actionTitle: L("重新连接"),
                    action: { sessionManager.reconnect(session) }
                )
            }
        case .running:
            runningBody
        }
    }

    @ViewBuilder
    private var runningBody: some View {
        switch monitor.status {
        case .idle, .checking:
            // If we have cached data from the previous monitoring run, show it
            // immediately so tab switches are instant instead of blanking to a
            // spinner for 2+ seconds while the loop restarts and the first new
            // tick arrives.
            if monitor.snapshot != nil {
                liveCards
            } else {
                MonitorNotice(
                    spinner: true,
                    title: L("正在检测系统…"),
                    caption: L("正在通过已建立的 SSH 连接读取系统信息。")
                )
                latencyCard
            }
        case .unsupported(let os):
            MonitorNotice(
                symbol: "exclamationmark.triangle",
                title: L("此服务器系统暂不支持监控"),
                caption: L("检测到系统：%@（目前仅支持 Linux）。", os)
            )
            latencyCard
        case .unavailable(let reason):
            MonitorNotice(
                symbol: "wifi.exclamationmark",
                title: L("监控暂不可用"),
                caption: L("%@。将自动重试。", reason),
                actionTitle: L("重试"),
                action: retry
            )
            latencyCard
        case .active:
            liveCards
        }
    }

    /// All data cards for an active (or recently-active) monitoring session.
    /// Shared by the `.active` case and the `.idle`/`.checking` case when
    /// cached data is present, so tab switches show the last-known stats
    /// without duplicating the entire card list.
    @ViewBuilder
    private var liveCards: some View {
        if let snap = monitor.snapshot {
            // Every card is an identity-stable, Equatable subview fed only the
            // slice of state it draws, so a 2s tick re-renders just the cards
            // whose data actually changed — not the whole rail. The parent
            // still re-evaluates this list each tick, but that only rebuilds
            // lightweight card *values*; `.equatable()` lets unchanged cards
            // (disk, ports, an idle NIC's rings…) skip their bodies entirely.
            MonitorOverviewCard(
                hostname: session.host.hostname,
                uptimeSeconds: snap.uptimeSeconds,
                load1: snap.load1, load5: snap.load5, load15: snap.load15,
                maskIP: $maskIP,
                onSystemInfo: { activeSheet = .systemInfo }
            )
            .equatable()
            if !monitor.activeAlerts.isEmpty {
                MonitorAlertsCard(alerts: monitor.activeAlerts)
                    .equatable()
            }
            CPUUsageCard(
                percent: monitor.cpuSeries.last,
                corePercents: monitor.cpuCorePercents,
                onTap: { activeSheet = .detail(.cpu) }
            )
            .equatable()
            MemoryCard(
                usedFraction: snap.memUsedFraction,
                usedKB: snap.memUsedKB,
                totalKB: snap.memTotalKB,
                swapTotalKB: snap.swapTotalKB,
                swapUsedFraction: snap.swapUsedFraction,
                swapUsedKB: snap.swapUsedKB,
                onTap: { activeSheet = .detail(.memory) }
            )
            .equatable()
            ProcessListCard(
                processes: snap.topProcesses,
                onTap: { activeSheet = .detail(.process) },
                onKill: { proc, signal in
                    pendingKill = ProcessKillTarget(process: proc, signal: signal)
                }
            )
            .equatable()
            PortsCard(onTap: { activeSheet = .detail(.ports) })
                .equatable()
            // On-demand deep-dives next to 端口: TCP quality (double-sample
            // ss -ni), the full connection table, and the local network tools.
            StaticEntryCard(
                title: L("TCP 连接质量"),
                symbol: "waveform.path.ecg",
                caption: L("测量 RTT / 重传率"),
                onTap: { activeSheet = .detail(.tcpQuality) }
            )
            .equatable()
            StaticEntryCard(
                title: L("连接表"),
                symbol: "list.bullet.indent",
                caption: L("查看全量连接表 · 按状态与远端聚合"),
                onTap: { activeSheet = .detail(.connections) }
            )
            .equatable()
            StaticEntryCard(
                title: L("网络工具"),
                symbol: "wrench.and.screwdriver",
                caption: L("TCP ping · 路由追踪"),
                onTap: { activeSheet = .detail(.tools) }
            )
            .equatable()
            // Live port-forward toggles — only shown when forwards are
            // defined on the host, sitting between 端口 and 网络 as specified.
            if let forwarding = forwarding {
                ForwardsCard(
                    count: forwarding.forwards.count,
                    enabledCount: forwarding.enabled.values.filter { $0 }.count,
                    onTap: { activeSheet = .detail(.forwarding) }
                )
                .equatable()
            }
            networkCardView
            activeInterfacesCardView
            latencyCard
            DiskCard(
                disks: snap.disks,
                diskReadBytesPerSec: monitor.diskReadBytesPerSec,
                diskWriteBytesPerSec: monitor.diskWriteBytesPerSec,
                onTap: { activeSheet = .detail(.disk) }
            )
            .equatable()
            // Cumulative since-boot traffic, right below 磁盘 as requested —
            // always visible in the rail, not buried in the 系统信息 sheet.
            trafficCardView(snap)
        } else {
            // Snapshot not yet available (first tick after .active transition
            // or a brief polling gap). Show placeholder cards so the rail
            // doesn't go blank between the "正在检测" notice and live data.
            snapshotPlaceholderCards
            latencyCard
        }
    }

    /// Skeleton cards shown when monitor.status == .active but the first
    /// snapshot hasn't arrived yet (or is momentarily nil during a poll gap).
    /// Each mirrors the real card's title/symbol so the layout is stable and
    /// a ProgressView sits where the live data will appear.
    @ViewBuilder
    private var snapshotPlaceholderCards: some View {
        placeholderCard(L("概览"), symbol: "server.rack")
        placeholderCard(L("CPU"), symbol: "cpu")
        placeholderCard(L("内存"), symbol: "memorychip")
        placeholderCard(L("进程"), symbol: "list.bullet.rectangle")
        placeholderCard(L("网络"), symbol: "arrow.up.arrow.down")
        placeholderCard(L("磁盘"), symbol: "internaldrive")
    }

    private func placeholderCard(_ title: String, symbol: String) -> some View {
        MonitorCard(title, symbol: symbol) {
            HStack {
                Spacer(minLength: 0)
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(monitorSpinnerScale)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
    }

    private func retry() {
        monitor.stop()
        monitor.start()
    }

    // MARK: Live cards needing cross-field wiring

    /// The 网络 card, wired to the selected interface's throughput series and the
    /// cached picker list; the picker binds straight back to `selectedInterface`.
    private var networkCardView: some View {
        let interface = monitor.selectedInterface
        let rx = interface.flatMap { monitor.rxSpeedSeries[$0] } ?? []
        let tx = interface.flatMap { monitor.txSpeedSeries[$0] } ?? []
        return NetworkCard(
            rx: rx,
            tx: tx,
            interfaceNames: monitor.interfaceNames,
            selection: $monitor.selectedInterface,
            onTap: { activeSheet = .detail(.network) }
        )
        .equatable()
    }

    /// The 活动网卡 card — one row per busy live interface. Only shown when at
    /// least two interfaces are live (a single-NIC host sees it all in 网络).
    @ViewBuilder
    private var activeInterfacesCardView: some View {
        let names = monitor.activeInterfaceNames
        if names.count > 1 {
            ActiveInterfacesCard(
                rows: names.map { name in
                    ActiveNIC(
                        name: name,
                        rx: monitor.rxSpeedSeries[name]?.last ?? 0,
                        tx: monitor.txSpeedSeries[name]?.last ?? 0
                    )
                },
                selected: monitor.selectedInterface,
                onSelect: { monitor.selectedInterface = $0 },
                onTap: { activeSheet = .detail(.network) }
            )
            .equatable()
        }
    }

    /// The 网络流量 rings, scoped to the selected interface's since-boot counters.
    private func trafficCardView(_ snap: SystemSnapshot) -> some View {
        let name = monitor.selectedInterface
        let counter = name.flatMap { n in snap.interfaces.first { $0.name == n } }
        return TrafficCard(
            interfaceName: name,
            rxTotal: counter?.rxBytes ?? 0,
            txTotal: counter?.txBytes ?? 0,
            onTap: { activeSheet = .detail(.network) }
        )
        .equatable()
    }

    // MARK: 延迟

    private var latencyCard: some View {
        LatencyCardView(ping: ping)
    }

}

/// Column by which `ProcessListCard` and `ProcessDetailView` sort the process list.
enum ProcessSortKey {
    case cpu
    case memory
    case name
}

// MARK: - Rail cards
//
// Each card is a self-contained, `Equatable` subview handed only the slice of
// state it draws (never `@ObservedObject monitor`, which would re-render it on
// every 2s tick regardless). Paired with `.equatable()` at the call site, this
// lets SwiftUI skip a card's body whenever its inputs are unchanged since the
// last tick — so an idle disk / static ports card / quiet NIC costs nothing,
// and only the cards whose data actually moved re-render.
//
// The trailing action closures (onTap / onKill / onSelect / onSystemInfo) and
// bindings are deliberately excluded from each `==`: they only fire on user
// interaction and never affect the rendered output, and they capture stable
// @State/@Binding storage, so an old closure kept across a skipped update still
// targets the right state.

/// Small ↑/↓ throughput label reused by the 网络 and 活动网卡 cards.
private struct SpeedLabel: View {
    let arrow: String
    let color: Color
    let value: Double
    @ScaledMetric(relativeTo: .caption) private var valueFontSize: CGFloat = 11

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: arrow)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
            Text(MonitorFormat.speed(bytesPerSecond: value))
                .font(.system(size: valueFontSize).monospacedDigit())
        }
    }
}

private struct MonitorOverviewCard: View, @MainActor Equatable {
    let hostname: String
    let uptimeSeconds: Double
    let load1: Double
    let load5: Double
    let load15: Double
    @Binding var maskIP: Bool
    let onSystemInfo: () -> Void
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .caption) private var ipFontSize: CGFloat = 11
    @State private var sysInfoHovering = false

    static func == (a: MonitorOverviewCard, b: MonitorOverviewCard) -> Bool {
        a.hostname == b.hostname
            && a.uptimeSeconds == b.uptimeSeconds
            && a.load1 == b.load1 && a.load5 == b.load5 && a.load15 == b.load15
            && a.maskIP == b.maskIP
    }

    var body: some View {
        MonitorCard(L("概览"), symbol: "server.rack") {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                    Text("IP")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: DS.Space.s)
                    Text(ServerPrivacy.mask(hostname, when: maskIP))
                        .font(.system(size: ipFontSize, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    MonitorIconButton(
                        systemName: maskIP ? "eye.slash" : "eye",
                        label: maskIP ? L("显示 IP") : L("隐藏 IP"),
                        size: 9,
                        box: CGSize(width: 14, height: 14)
                    ) { maskIP.toggle() }
                    CopyButton(text: hostname, help: L("复制地址"))
                }
                InfoRow(label: L("运行时间"), value: MonitorFormat.uptime(seconds: uptimeSeconds, locale: locale))
                InfoRow(label: L("负载"), value: MonitorFormat.loadAverage(load1, load5, load15))
            }
        } accessory: {
            Button(action: onSystemInfo) {
                Label(L("系统信息"), systemImage: "info.circle")
                    .font(.caption2.weight(.medium))
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(sysInfoHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .pressFeedback()
            .onHover { sysInfoHovering = $0 }
            .help(L("查看详细系统信息"))
            .accessibilityLabel(L("系统信息"))
        }
    }
}

private struct CPUUsageCard: View, @MainActor Equatable {
    let percent: Double?
    /// Per-core busy %, in core order. Empty until at least two samples arrive.
    let corePercents: [Double]
    let onTap: () -> Void
    @ScaledMetric(relativeTo: .caption) private var percentFontSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption2) private var coreFontSize: CGFloat = 9

    static func == (a: CPUUsageCard, b: CPUUsageCard) -> Bool {
        a.percent == b.percent && a.corePercents == b.corePercents
    }

    var body: some View {
        MonitorCard(L("CPU"), symbol: "cpu", onTap: onTap) {
            VStack(spacing: DS.Space.s - 2) {
                HStack(spacing: DS.Space.s) {
                    UsageBar(fraction: (percent ?? 0) / 100, tint: usageTint(percent ?? 0))
                    Text(percent.map { MonitorFormat.percent($0) } ?? "—")
                        .font(.system(size: percentFontSize, weight: .medium).monospacedDigit())
                        .frame(minWidth: 32, alignment: .trailing)
                }
                if !corePercents.isEmpty {
                    coreGrid
                }
            }
        }
    }

    /// Compact 2-column grid of per-core usage bars, up to 16 cores.
    private var coreGrid: some View {
        let cores = Array(corePercents.prefix(16))
        return LazyVGrid(
            columns: [GridItem(.flexible(), spacing: DS.Space.s),
                      GridItem(.flexible(), spacing: DS.Space.s)],
            spacing: 5
        ) {
            ForEach(Array(cores.enumerated()), id: \.offset) { index, pct in
                HStack(spacing: 4) {
                    Text(L("核%lld", index))
                        .font(.system(size: coreFontSize, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .leading)
                    UsageBar(fraction: pct / 100, tint: usageTint(pct), height: 4)
                    Text(MonitorFormat.percent(pct))
                        .font(.system(size: coreFontSize).monospacedDigit())
                        .frame(width: 28, alignment: .trailing)
                }
            }
        }
    }
}

private struct MemoryCard: View, @MainActor Equatable {
    let usedFraction: Double
    let usedKB: UInt64
    let totalKB: UInt64
    let swapTotalKB: UInt64
    let swapUsedFraction: Double
    let swapUsedKB: UInt64
    let onTap: () -> Void
    @ScaledMetric(relativeTo: .caption) private var detailFontSize: CGFloat = 10.5

    static func == (a: MemoryCard, b: MemoryCard) -> Bool {
        a.usedFraction == b.usedFraction && a.usedKB == b.usedKB && a.totalKB == b.totalKB
            && a.swapTotalKB == b.swapTotalKB && a.swapUsedFraction == b.swapUsedFraction
            && a.swapUsedKB == b.swapUsedKB
    }

    var body: some View {
        MonitorCard(L("内存"), symbol: "memorychip", onTap: onTap) {
            VStack(spacing: DS.Space.s) {
                usageRow(
                    label: L("内存"),
                    fraction: usedFraction,
                    detail: MonitorFormat.percent(usedFraction * 100)
                        + " · " + MonitorFormat.sizePair(usedKB, totalKB)
                )
                if swapTotalKB > 0 {
                    usageRow(
                        label: L("交换"),
                        fraction: swapUsedFraction,
                        detail: MonitorFormat.percent(swapUsedFraction * 100)
                            + " · " + MonitorFormat.sizePair(swapUsedKB, swapTotalKB)
                    )
                } else {
                    HStack {
                        Text("交换")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("未启用")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func usageRow(label: String, fraction: Double, detail: String) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: DS.Space.s)
                Text(detail)
                    .font(.system(size: detailFontSize).monospacedDigit())
                    .lineLimit(1)
            }
            UsageBar(fraction: fraction, tint: usageTint(fraction * 100))
        }
    }
}

private struct ProcessListCard: View, @MainActor Equatable {
    let processes: [TopProcess]
    let onTap: () -> Void
    let onKill: (TopProcess, MonitorService.KillSignal) -> Void

    @State private var sortKey: ProcessSortKey = .cpu
    @State private var sortAscending = false
    @ScaledMetric(relativeTo: .caption) private var rowFontSize: CGFloat = 10.5

    static func == (a: ProcessListCard, b: ProcessListCard) -> Bool { a.processes == b.processes }

    var body: some View {
        MonitorCard(L("进程"), symbol: "list.bullet.rectangle", onTap: onTap) {
            if processes.isEmpty {
                Text("暂无进程数据")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    Grid(alignment: .leading, horizontalSpacing: DS.Space.s, verticalSpacing: 3) {
                        // Clickable column headers — tapping selects the column;
                        // tapping the active column reverses sort direction.
                        GridRow {
                            columnHeader(L("内存"), key: .memory).gridColumnAlignment(.trailing)
                            columnHeader(L("CPU"),  key: .cpu).gridColumnAlignment(.trailing)
                            columnHeader(L("命令"), key: .name)
                        }
                        ForEach(sortedProcesses, id: \.pid) { proc in
                            GridRow {
                                Text(MonitorFormat.sizeShort(kb: proc.rssKB))
                                Text(MonitorFormat.processCPU(proc.cpuPercent))
                                Text(proc.command)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .help(proc.command)
                            }
                            .font(.system(size: rowFontSize).monospacedDigit())
                            .contentShape(Rectangle())
                            .contextMenu {
                                if proc.pid > 0 {
                                    Button(L("结束进程")) { onKill(proc, .term) }
                                    Button(L("强制结束"), role: .destructive) { onKill(proc, .kill) }
                                }
                            }
                        }
                    }
                }
                // Show ~8 rows; the parent rail ScrollView handles the rest.
                .frame(maxHeight: 160)
            }
        }
    }

    private var sortedProcesses: [TopProcess] {
        switch sortKey {
        case .cpu:
            return processes.sorted { sortAscending ? $0.cpuPercent < $1.cpuPercent : $0.cpuPercent > $1.cpuPercent }
        case .memory:
            return processes.sorted { sortAscending ? $0.rssKB < $1.rssKB : $0.rssKB > $1.rssKB }
        case .name:
            return processes.sorted { sortAscending ? $0.command < $1.command : $0.command > $1.command }
        }
    }

    /// Small sortable column header button. The active column shows a chevron
    /// indicating current sort direction; clicking it reverses the direction.
    private func columnHeader(_ title: String, key: ProcessSortKey) -> some View {
        Button {
            if sortKey == key {
                sortAscending.toggle()
            } else {
                sortKey = key
                sortAscending = false
            }
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if sortKey == key {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
            }
        }
        .buttonStyle(.plain)
        .font(.caption2.weight(.medium))
        .foregroundStyle(sortKey == key ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
    }
}

/// Lightweight entry into the "谁占了 8080" panel. Static content (ports are
/// fetched on demand, not on the 2s loop), so it never re-renders after the
/// first pass.
private struct PortsCard: View, @MainActor Equatable {
    let onTap: () -> Void

    static func == (a: PortsCard, b: PortsCard) -> Bool { true }

    var body: some View {
        MonitorCard(L("端口"), symbol: "network", onTap: onTap) {
            Text(L("查看监听端口 · 排查端口占用"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Static rail card that only opens a detail sheet (TCP 连接质量 / 连接表 /
/// 网络工具). Same always-equal shape as PortsCard: its content never depends
/// on live data, so a 2s tick must not re-render it.
private struct StaticEntryCard: View, @MainActor Equatable {
    let title: String
    let symbol: String
    let caption: String
    let onTap: () -> Void

    static func == (a: StaticEntryCard, b: StaticEntryCard) -> Bool {
        a.title == b.title && a.symbol == b.symbol && a.caption == b.caption
    }

    var body: some View {
        MonitorCard(title, symbol: symbol, onTap: onTap) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Live port-forward summary: shown between 端口 and 网络 when the host defines at
/// least one forward rule. Tapping opens the forwarding detail sheet with
/// per-forward enable/disable toggles.
private struct ForwardsCard: View, @MainActor Equatable {
    let count: Int
    let enabledCount: Int
    let onTap: () -> Void

    static func == (a: ForwardsCard, b: ForwardsCard) -> Bool {
        a.count == b.count && a.enabledCount == b.enabledCount
    }

    var body: some View {
        MonitorCard(L("端口转发"), symbol: "arrow.triangle.swap", onTap: onTap) {
            HStack(spacing: DS.Space.s) {
                Text(L("已配置 %lld 条转发", Int(count)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: DS.Space.s)
                if enabledCount > 0 {
                    Circle()
                        .fill(DS.Colors.statusRunning)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(L("%lld 条已启用", Int(enabledCount)))
                        .font(.caption)
                        .foregroundStyle(DS.Colors.statusRunning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct NetworkCard: View, @MainActor Equatable {
    let rx: [Double]
    let tx: [Double]
    let interfaceNames: [String]
    @Binding var selection: String?
    let onTap: () -> Void

    static func == (a: NetworkCard, b: NetworkCard) -> Bool {
        a.rx == b.rx && a.tx == b.tx
            && a.interfaceNames == b.interfaceNames
            && a.selection == b.selection
    }

    var body: some View {
        MonitorCard(L("网络"), symbol: "arrow.up.arrow.down", onTap: onTap) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                if rx.isEmpty, tx.isEmpty {
                    Text("正在采集…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    HStack(spacing: DS.Space.m) {
                        SpeedLabel(arrow: "arrow.up", color: NetGraphPalette.upload, value: tx.last ?? 0)
                        SpeedLabel(arrow: "arrow.down", color: NetGraphPalette.download, value: rx.last ?? 0)
                        Spacer(minLength: 0)
                    }
                    NetworkSparkline(rx: rx, tx: tx)
                }
            }
        } accessory: {
            if !interfaceNames.isEmpty {
                Picker("网卡", selection: $selection) {
                    ForEach(interfaceNames, id: \.self) { name in
                        Text(name).tag(Optional(name))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.mini)
                .fixedSize()
                .help("选择要查看的网卡")
            }
        }
    }
}

/// One busy interface's current throughput, for the 活动网卡 rows.
private struct ActiveNIC: Equatable, Identifiable {
    let name: String
    let rx: Double
    let tx: Double
    var id: String { name }
}

/// One compact ↓RX / ↑TX row per active interface, so every live NIC is visible
/// at once instead of only the single `selectedInterface` charted by the 网络
/// card. Tapping a row selects that NIC, driving the 网络 card, 网络流量 rings and
/// the detail chart.
private struct ActiveInterfacesCard: View, @MainActor Equatable {
    let rows: [ActiveNIC]
    let selected: String?
    let onSelect: (String) -> Void
    let onTap: () -> Void
    @ScaledMetric(relativeTo: .caption) private var nameFontSize: CGFloat = 10.5

    static func == (a: ActiveInterfacesCard, b: ActiveInterfacesCard) -> Bool {
        a.rows == b.rows && a.selected == b.selected
    }

    var body: some View {
        MonitorCard(L("活动网卡"), symbol: "network", onTap: onTap) {
            VStack(spacing: DS.Space.s - 2) {
                ForEach(rows) { row in
                    interfaceRow(row)
                }
            }
        }
    }

    private func interfaceRow(_ row: ActiveNIC) -> some View {
        let isSelected = selected == row.name
        return HStack(spacing: DS.Space.s) {
            Text(row.name)
                .font(.system(size: nameFontSize, design: .monospaced))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(row.name)
            Spacer(minLength: DS.Space.s)
            SpeedLabel(arrow: "arrow.down", color: NetGraphPalette.download, value: row.rx)
            SpeedLabel(arrow: "arrow.up", color: NetGraphPalette.upload, value: row.tx)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? DS.Colors.barTrack : .clear)
        )
        .contentShape(Rectangle())
        // Tapping selects this NIC; stops here so it never also opens the detail
        // sheet (the card's own onTap handles the rest of the surface).
        .onTapGesture { onSelect(row.name) }
        .help(isSelected ? L("当前查看的网卡") : L("查看此网卡"))
    }
}

private struct DiskCard: View, @MainActor Equatable {
    let disks: [DiskUsage]
    /// Current read speed for the busiest disk in bytes/sec (0 until first delta).
    let diskReadBytesPerSec: Double
    /// Current write speed for the busiest disk in bytes/sec (0 until first delta).
    let diskWriteBytesPerSec: Double
    let onTap: () -> Void
    @ScaledMetric(relativeTo: .caption) private var rowFontSize: CGFloat = 10.5
    @ScaledMetric(relativeTo: .caption2) private var ioFontSize: CGFloat = 10

    static func == (a: DiskCard, b: DiskCard) -> Bool {
        a.disks == b.disks
            && a.diskReadBytesPerSec == b.diskReadBytesPerSec
            && a.diskWriteBytesPerSec == b.diskWriteBytesPerSec
    }

    var body: some View {
        MonitorCard(L("磁盘"), symbol: "internaldrive", onTap: onTap) {
            if disks.isEmpty {
                Text("暂无磁盘数据")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: DS.Space.s - 2) {
                    ForEach(disks, id: \.mount) { disk in
                        VStack(spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                // Overlay rows surfaced by the container fallback
                                // are labeled instead of shown as a host mount.
                                Text(disk.isContainerOverlay ? L("容器 overlay") : disk.mount)
                                    .font(.system(size: rowFontSize, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                    .help(disk.mount)
                                Spacer(minLength: DS.Space.s)
                                Text(MonitorFormat.sizePair(disk.availableKB, disk.totalKB))
                                    .font(.system(size: rowFontSize).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            UsageBar(
                                fraction: disk.usedFraction,
                                tint: usageTint(disk.usedFraction * 100),
                                height: 3
                            )
                        }
                    }
                    // Disk I/O speed — shown once data is available.
                    ioSpeedRow
                }
            }
        } accessory: {
            Text("可用/总量")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// "R: 12.3 MB/s  W: 4.1 MB/s" row below the disk fill bars.
    private var ioSpeedRow: some View {
        HStack(spacing: DS.Space.m) {
            ioLabel(prefix: "R:", bytes: diskReadBytesPerSec)
            ioLabel(prefix: "W:", bytes: diskWriteBytesPerSec)
            Spacer(minLength: 0)
        }
    }

    private func ioLabel(prefix: String, bytes: Double) -> some View {
        HStack(spacing: 3) {
            Text(prefix)
                .font(.system(size: ioFontSize))
                .foregroundStyle(.tertiary)
            Text(MonitorFormat.speed(bytesPerSecond: bytes))
                .font(.system(size: ioFontSize).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// Two donut rings — cumulative inbound/outbound bytes since boot — sitting
/// directly under the 磁盘 card. Scoped to the SAME interface shown in the 网络
/// card (the busiest real NIC by default, e.g. `ens17`).
///
/// We deliberately do NOT sum every interface: a Docker host carries the same
/// packets on the physical NIC, the `docker0`/`br-*` bridge AND the `veth*`
/// pairs, so adding them all double-counts and inflates the totals (outbound
/// especially). Reporting the selected real interface gives the true uplink
/// figure and keeps the two network cards consistent.
private struct TrafficCard: View, @MainActor Equatable {
    let interfaceName: String?
    let rxTotal: UInt64
    let txTotal: UInt64
    let onTap: () -> Void
    @ScaledMetric(relativeTo: .caption2) private var interfaceFontSize: CGFloat = 10

    static func == (a: TrafficCard, b: TrafficCard) -> Bool {
        a.interfaceName == b.interfaceName && a.rxTotal == b.rxTotal && a.txTotal == b.txTotal
    }

    var body: some View {
        let total = max(1.0, Double(rxTotal) + Double(txTotal))
        return MonitorCard(
            L("网络流量（自开机）"),
            symbol: "arrow.up.arrow.down",
            onTap: onTap
        ) {
            HStack(spacing: DS.Space.s) {
                Spacer(minLength: 0)
                TrafficRing(
                    title: L("入站"),
                    bytes: rxTotal,
                    fraction: Double(rxTotal) / total,
                    color: DS.Colors.netDownload,
                    symbol: "arrow.down"
                )
                TrafficRing(
                    title: L("出站"),
                    bytes: txTotal,
                    fraction: Double(txTotal) / total,
                    color: DS.Colors.netUpload,
                    symbol: "arrow.up"
                )
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        } accessory: {
            // Make it explicit which NIC these totals are for.
            if let interfaceName {
                Text(interfaceName)
                    .font(.system(size: interfaceFontSize, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Monitoring alerts

/// Persistent, in-app visibility for threshold breaches. Unlike the optional
/// macOS notification, this remains visible while the condition is true.
private struct MonitorAlertsCard: View, Equatable {
    let alerts: [MonitorAlert]

    var body: some View {
        MonitorCard(L("监控告警"), symbol: "exclamationmark.triangle.fill") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ForEach(alerts) { alert in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: symbol(for: alert.kind))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DS.Colors.statusError)
                            .frame(width: 13, alignment: .center)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alert.title)
                                .font(.caption.weight(.semibold))
                            Text(alert.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func symbol(for kind: MonitorAlertKind) -> String {
        switch kind {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .load: return "gauge.with.dots.needle.67percent"
        }
    }
}

/// Per-app alert policy. It is deliberately in the monitor rail instead of
/// global Settings: users can tune limits while looking at the host that is
/// currently breaching them. All values are shared through UserDefaults.
private struct MonitorAlertSettingsView: View {
    @ObservedObject var monitor: MonitorService
    @AppStorage(MonitorAlertPreference.cpuThresholdKey)
    private var cpuThreshold = MonitorAlertPreference.defaultCPUPercent
    @AppStorage(MonitorAlertPreference.memoryThresholdKey)
    private var memoryThreshold = MonitorAlertPreference.defaultMemoryPercent
    @AppStorage(MonitorAlertPreference.diskThresholdKey)
    private var diskThreshold = MonitorAlertPreference.defaultDiskPercent
    @AppStorage(MonitorAlertPreference.loadThresholdKey)
    private var loadThreshold = MonitorAlertPreference.defaultLoad
    @AppStorage(MonitorAlertPreference.systemNotificationsKey)
    private var systemNotifications = false

    var body: some View {
        Form {
            Section(L("告警阈值")) {
                percentStepper(L("CPU"), value: $cpuThreshold)
                percentStepper(L("内存"), value: $memoryThreshold)
                percentStepper(L("磁盘"), value: $diskThreshold)
                Stepper(value: $loadThreshold, in: 0.5...1_000, step: 0.5) {
                    HStack {
                        Text(L("1 分钟负载"))
                        Spacer()
                        Text(loadThreshold, format: .number.precision(.fractionLength(1)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            Section(L("通知")) {
                Toggle(L("使用系统通知"), isOn: $systemNotifications)
                    .onChange(of: systemNotifications) { _, enabled in
                        guard enabled else { return }
                        Task {
                            if !(await monitor.enableSystemNotifications()) {
                                systemNotifications = false
                            }
                        }
                    }
                Text(L("面板内告警始终显示；系统通知需授权，且同一主机同类告警最多每 10 分钟一次。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 300)
        .padding(DS.Space.s)
    }

    private func percentStepper(_ title: String, value: Binding<Double>) -> some View {
        Stepper(value: value, in: 50...100, step: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(MonitorFormat.percent(value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Shared pieces

/// Green below 70%, orange to 90%, red above — for every usage bar.
func usageTint(_ percent: Double) -> Color {
    if percent >= 90 { return DS.Colors.statusError }
    if percent >= 70 { return DS.Colors.statusConnecting }
    return DS.Colors.statusRunning
}

/// Shared scale for the small inline `ProgressView` spinners in the monitor
/// rail and detail sheets, so every sub-control spinner matches (was 0.6 / 0.5
/// ad hoc). `.controlSize(.small)` then this scale keeps them uniform.
let monitorSpinnerScale: CGFloat = 0.6

/// A hand-rolled icon button for dense monitor chrome that can't host a
/// `GlassIconButton` glass chip (rail header, card accessories, detail rows).
/// These were bare `Button { Image } .buttonStyle(.plain)` controls missing the
/// three affordances every icon button owes: a VoiceOver label, zero-frame
/// `pressFeedback()` scale, and a hover tint. Resting / hover tints are
/// caller-supplied so a destructive glyph keeps its red. Icon point size stays
/// fixed (a true glyph metric); only data text scales with Dynamic Type.
struct MonitorIconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = 11
    var weight: Font.Weight = .medium
    var rest: AnyShapeStyle = AnyShapeStyle(.secondary)
    var hover: AnyShapeStyle = AnyShapeStyle(.primary)
    /// Optional fixed hit box (matches the old `.frame(width:height:)`).
    var box: CGSize? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            glyph.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pressFeedback()
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var glyph: some View {
        let image = Image(systemName: systemName)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(hovering ? hover : rest)
        if let box {
            image.frame(width: box.width, height: box.height)
        } else {
            image
        }
    }
}

/// Compact card: SF Symbol + title header (optional trailing accessory),
/// then free-form content on a subtle rounded background.
private struct MonitorCard<Accessory: View, Content: View>: View {
    private let title: String
    private let symbol: String
    private let onTap: (() -> Void)?
    private let content: Content
    private let accessory: Accessory

    init(
        _ title: String,
        symbol: String,
        onTap: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.symbol = symbol
        self.onTap = onTap
        self.content = content()
        self.accessory = accessory()
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: DS.Space.s - 1) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                accessory
                // Chevron hints the card opens a detail panel on tap.
                if onTap != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
        .padding(.horizontal, DS.Space.m - 2)
        .padding(.vertical, DS.Space.s + 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Cheap frosted-flat card (appearance-adaptive fill + hairline border,
        // NO live GPU blur). Round-3 used `.glassCard()` here, but seven
        // Liquid-Glass cards re-rasterizing on every 2s tick was the jank the
        // user felt ("加载好卡"). `statCard()` looks nearly identical and is
        // free to redraw, so the inspector opens and updates instantly.
        .statCard()
    }

    var body: some View {
        if let onTap {
            // `.onTapGesture` (not a Button wrapper) so embedded controls — the
            // network interface picker, the system-info button — keep their own
            // taps; only the rest of the card opens the detail.
            card
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
        } else {
            card
        }
    }
}

/// "Label … value" row with middle truncation and mono digits.
private struct InfoRow: View {
    let label: String
    let value: String
    @ScaledMetric(relativeTo: .caption) private var valueFontSize: CGFloat = 11

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: DS.Space.s)
            Text(value)
                .font(.system(size: valueFontSize).monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
    }
}

/// Centered message for non-data states (not connected, checking,
/// unsupported OS, sampling failure), optionally with one action button.
private struct MonitorNotice: View {
    var symbol: String? = nil
    var spinner = false
    /// Spin `symbol` continuously (auto-reconnect) so the glyph — a shape+motion
    /// cue rather than a bare ProgressView — never reads as frozen.
    var rotating = false
    var symbolTint: AnyShapeStyle = AnyShapeStyle(.tertiary)
    let title: String
    var caption: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: DS.Space.s) {
            if spinner {
                ProgressView()
                    .controlSize(.small)
            } else if rotating, let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(symbolTint)
                    // macOS 15+ (project targets Tahoe); stops when `rotating`
                    // goes false or the notice is removed.
                    .symbolEffect(.rotate, options: .repeating, isActive: true)
                    .accessibilityLabel(title)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .light))
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.l)
        .padding(.horizontal, DS.Space.m)
    }
}

/// Thin capsule usage bar; never paints a sliver narrower than its height.
struct UsageBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 6

    var body: some View {
        let clamped = min(1, max(0, fraction))
        Capsule()
            .fill(DS.Colors.barTrack)
            .overlay(alignment: .leading) {
                if clamped > 0 {
                    GeometryReader { geo in
                        Capsule()
                            .fill(tint.gradient)
                            .frame(width: max(height, geo.size.width * clamped))
                    }
                }
            }
            .frame(height: height)
            .animation(.easeOut(duration: 0.3), value: fraction)
            // The bar is purely decorative; the adjacent Text labels carry
            // the accessible value for VoiceOver.
            .accessibilityHidden(true)
    }
}

/// A donut gauge for cumulative inbound/outbound traffic in the monitor rail:
/// the ring fills to this direction's share of total (in+out) traffic, with the
/// byte total + share stacked in the center. Sized to sit two-up in the narrow
/// inspector column.
private struct TrafficRing: View {
    let title: String
    let bytes: UInt64
    /// 0…1 share of total (in+out) traffic — the two rings are complementary.
    let fraction: Double
    let color: Color
    let symbol: String
    @ScaledMetric(relativeTo: .callout) private var bytesFontSize: CGFloat = 12.5
    @ScaledMetric(relativeTo: .caption2) private var percentFontSize: CGFloat = 9

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(DS.Colors.barTrack, lineWidth: 8)
                Circle()
                    // Always show a sliver so a 0% direction still reads as a ring.
                    .trim(from: 0, to: max(0.004, min(1, fraction)))
                    .stroke(color.gradient, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(color)
                    Text(MonitorFormat.sizeShort(bytes: Double(bytes)))
                        .font(.system(size: bytesFontSize, weight: .semibold, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(MonitorFormat.percent(fraction * 100))
                        .font(.system(size: percentFontSize).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
            .frame(width: 76, height: 76)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        // Combine the donut ring + labels into one VoiceOver element so
        // assistive tech reads "入站，已接收 1.2 GB，占 73%" in one pass.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(
            L("%@，占 %@",
              MonitorFormat.sizeShort(bytes: Double(bytes)),
              MonitorFormat.percent(fraction * 100))
        )
    }
}

/// Small icon button that copies `text` and flashes a checkmark.
private struct CopyButton: View {
    let text: String
    let help: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation { copied = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                withAnimation { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(copied ? AnyShapeStyle(DS.Colors.statusRunning) : AnyShapeStyle(.secondary))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Sparklines (Swift Charts)

/// Samples shown by the sparklines (~2 minutes at 2s monitor ticks).
private let sparklineWindow = 60

/// Samples shown by the bandwidth charts (~4 minutes at 2s ticks) — matches
/// MonitorService's series ring (`maxSamples = 120`), so a chart always has
/// the full buffer available instead of truncating a longer history.
private let bandwidthChartWindow = 120

/// FinalShell-style direction palette for the monitoring graphs (per the
/// reference screenshot): upload is orange-brown, download green, latency a
/// steel blue. Local to monitoring — the shared DS palette stays untouched.
/// Palette lifted from FinalShell 4.6.5's graph painter (`gj`), decoded at
/// runtime via its own string/int table: download green rgba(20,100,20,90),
/// latency steel-blue rgba(60,130,210,80). Upload orange measured off the
/// official screenshot (FinalShell draws the two directions as two overlaid
/// transparent widgets). Alphas match the source: ~90/255 ≈ 0.35.
enum NetGraphPalette {
    static let upload = Color(red: 219.0/255, green: 133.0/255, blue: 56.0/255)
    static let download = Color(red: 20.0/255, green: 100.0/255, blue: 20.0/255)
    static let latency = Color(red: 60.0/255, green: 130.0/255, blue: 210.0/255)
    // Bump from FS's 90/80 alphas: their panel is pure white, our card is
    // theme-tinted — at 0.35 the 2px spikes washed out on Retina.
    static let seriesAlpha = 0.5
    static let latencyAlpha = 0.55
}

/// FinalShell-style bandwidth chart: NOT a smoothed curve — each sample is a
/// thin vertical bar rising from the baseline, densely packed (htop / Task
/// Manager style). Both directions are translucent bars on the same baseline
/// (download green, upload orange-brown) so overlap blends; the left axis is
/// two-three dotted gridlines with small adaptive K/M labels, much lighter
/// than a numeric axis. `window` defaults to the 4-minute bandwidth buffer;
/// the rail card and the bigger 网络详情 chart share the same rendering,
/// only the height differs.
struct NetworkSparkline: View {
    let rx: [Double] // download, bytes/s
    let tx: [Double] // upload, bytes/s
    var height: CGFloat = 64
    var window: Int = bandwidthChartWindow

    var body: some View {
        SpikeGraph(
            series: [
                .init(values: Array(rx.suffix(window)), color: NetGraphPalette.download, alpha: NetGraphPalette.seriesAlpha),
                .init(values: Array(tx.suffix(window)), color: NetGraphPalette.upload, alpha: NetGraphPalette.seriesAlpha),
            ],
            height: height,
            labelFormat: { MonitorFormat.speedAxisLabel(bytesPerSecond: $0) }
        )
    }
}

/// Faithful port of FinalShell's `gj` graph painter (constants decoded at
/// runtime from its own obfuscated table): vertical spike lines at 2px pitch,
/// newest sample hugging the right edge, min…max normalization over the
/// VISIBLE window (so the graph always fills its height and small wiggles
/// stay visible), three dotted gridlines with max/mid/min labels down a 30px
/// left gutter, and a 1px bottom+right frame.
///
/// Canvas, not Swift Charts: Charts' `BarMark(width: .ratio)` collapses to
/// zero width on a continuous scale (render-verified), and the gridline/
/// gutter layout below isn't expressible with AxisMarks anyway.
struct SpikeGraph: View {
    struct Series {
        let values: [Double]      // oldest → newest
        let color: Color
        let alpha: Double
    }

    let series: [Series]
    var height: CGFloat = 64
    var labelFormat: (Double) -> String = { "\(Int($0.rounded()))" }

    // FinalShell geometry: left label gutter W=30, bottom zone H=15,
    // 2px pitch per sample, newest at width-2.
    private let gutter: CGFloat = 30
    private let foot: CGFloat = 15
    private let pitch: CGFloat = 2
    private let barWidth: CGFloat = 1.8

    var body: some View {
        Canvas { ctx, size in
            let width = size.width, h = size.height
            guard width > gutter + 8, h > foot + 8 else { return }

            let capacity = Int((width - gutter - 2) / pitch)
            let windows: [[Double]] = series.map { Array($0.values.suffix(capacity)) }
            let all = windows.flatMap { $0 }
            guard let hi = all.max(), let lo = all.min(), !all.isEmpty else {
                drawChrome(ctx: ctx, width: width, h: h, hi: nil, lo: nil)
                return
            }

            drawChrome(ctx: ctx, width: width, h: h, hi: hi, lo: lo)

            // Bars: newest at x = width-2, stepping left by 2px (FS R=2).
            // Top maps to y=0, min to y=height-foot; bars run to the bottom
            // edge, passing behind the label zone like the original.
            let range = hi - lo
            for (si, w) in windows.enumerated() {
                guard !w.isEmpty else { continue }
                var path = Path()
                for (i, v) in w.enumerated() {
                    let t = range > 0 ? (v - lo) / range : 0
                    let top = (h - foot) * (1 - CGFloat(t))
                    let x = width - 2 - CGFloat(w.count - 1 - i) * pitch
                    path.addRect(CGRect(x: x - barWidth / 2, y: top, width: barWidth, height: h - top))
                }
                ctx.fill(path, with: .color(series[si].color.opacity(series[si].alpha)))
            }
        }
        .frame(height: height)
        // Decorative sparkline — adjacent Text nodes carry the accessible values.
        .accessibilityHidden(true)
    }

    /// Dotted gridlines + max/mid/min labels + bottom/right frame.
    private func drawChrome(ctx: GraphicsContext, width: CGFloat, h: CGFloat, hi: Double?, lo: Double?) {
        let gridY: [CGFloat] = [1, (h - foot) / 2 + 1, h - foot - 1]
        let dash = StrokeStyle(lineWidth: 0.5, dash: [1, 3])
        for y in gridY {
            var p = Path()
            p.move(to: CGPoint(x: gutter - 5, y: y))
            p.addLine(to: CGPoint(x: width, y: y))
            ctx.stroke(p, with: .color(.secondary.opacity(0.35)), style: dash)
        }
        if let hi, let lo {
            let mid = (hi + lo) / 2
            // FS label placement: max pinned at y=10-ish, mid/min sit just
            // BELOW their gridlines (gridline+4), never above — avoids the
            // overlap that pinning mid above its line caused at 48pt height.
            let labels: [(Double, CGFloat)] = [(hi, 8), (mid, gridY[1] + 4), (lo, gridY[2] + 4)]
            for (value, y) in labels {
                ctx.draw(
                    Text(labelFormat(value))
                        .font(.system(size: 8.5).monospacedDigit())
                        .foregroundStyle(.tertiary),
                    at: CGPoint(x: 3, y: y), anchor: .topLeading
                )
            }
        }
        // 1px bottom + right frame (FS: rgba(70,130,150,100) / rgb(210,225,230)).
        var framePath = Path()
        framePath.move(to: CGPoint(x: 0, y: h - 0.5))
        framePath.addLine(to: CGPoint(x: width, y: h - 0.5))
        framePath.move(to: CGPoint(x: width - 0.5, y: 0))
        framePath.addLine(to: CGPoint(x: width - 0.5, y: h))
        ctx.stroke(framePath, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
    }
}

/// Isolated latency card — owns the sole @ObservedObject subscription to
/// PingService so ping updates only redraw this view, not the whole panel.
private struct LatencyCardView: View {
    @ObservedObject var ping: PingService
    @ScaledMetric(relativeTo: .title3) private var currentFontSize: CGFloat = 15

    var body: some View {
        MonitorCard(L("延迟"), symbol: "clock") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ping.currentMs.map { MonitorFormat.milliseconds($0) } ?? "—")
                        .font(.system(size: currentFontSize, weight: .medium, design: .rounded).monospacedDigit())
                    Spacer(minLength: DS.Space.s)
                    if let average = ping.averageMs {
                        Text(verbatim: L("平均 %@", MonitorFormat.milliseconds(average)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if ping.latencySeries.isEmpty {
                    if let error = ping.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(DS.Colors.statusError)
                    } else {
                        Text("等待 ping 响应…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    // A working ping that later died keeps its sparkline but
                    // gets an inline hint instead of silently going stale.
                    if let error = ping.lastError {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(DS.Colors.statusError)
                    }
                    LatencySparkline(samples: ping.latencySeries)
                }
            }
        }
    }
}

/// Round-trip-time pulse bars, FinalShell-style: steel-blue vertical spikes,
/// dotted gridlines with small ms labels down the left gutter, min…max
/// normalization over the visible window (same painter as the network graph).
private struct LatencySparkline: View {
    let samples: [Double]

    var body: some View {
        SpikeGraph(
            series: [.init(values: Array(samples.suffix(sparklineWindow)), color: NetGraphPalette.latency, alpha: NetGraphPalette.latencyAlpha)],
            height: 48,
            labelFormat: { "\(Int($0.rounded()))" }
        )
    }
}
