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
                    forwarding: forwarding
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
            Circle()
                .fill(stateColor)
                .frame(width: 7, height: 7)
                .accessibilityLabel(stateAccessibilityLabel)
            Text(ServerPrivacy.mask(session.host.displayName, when: maskIP))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(ServerPrivacy.mask(session.host.displayName, when: maskIP))
            Spacer(minLength: 0)
            Button {
                alertSettingsPresented.toggle()
            } label: {
                Image(systemName: monitor.activeAlerts.isEmpty ? "bell" : "bell.badge.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(monitor.activeAlerts.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(DS.Colors.statusError))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("监控告警设置"))
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
                MonitorNotice(
                    spinner: true,
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
            DiskCard(disks: snap.disks)
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
                    .scaleEffect(0.6)
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

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: arrow)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
            Text(MonitorFormat.speed(bytesPerSecond: value))
                .font(.system(size: 11).monospacedDigit())
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
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button { maskIP.toggle() } label: {
                        Image(systemName: maskIP ? "eye.slash" : "eye")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(maskIP ? L("显示 IP") : L("隐藏 IP"))
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
            .foregroundStyle(.secondary)
            .help(L("查看详细系统信息"))
        }
    }
}

private struct CPUUsageCard: View, @MainActor Equatable {
    let percent: Double?
    let onTap: () -> Void

    static func == (a: CPUUsageCard, b: CPUUsageCard) -> Bool { a.percent == b.percent }

    var body: some View {
        MonitorCard(L("CPU"), symbol: "cpu", onTap: onTap) {
            HStack(spacing: DS.Space.s) {
                UsageBar(fraction: (percent ?? 0) / 100, tint: usageTint(percent ?? 0))
                Text(percent.map { MonitorFormat.percent($0) } ?? "—")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .frame(minWidth: 32, alignment: .trailing)
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
                    .font(.system(size: 10.5).monospacedDigit())
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

    static func == (a: ProcessListCard, b: ProcessListCard) -> Bool { a.processes == b.processes }

    var body: some View {
        MonitorCard(L("进程"), symbol: "list.bullet.rectangle", onTap: onTap) {
            if processes.isEmpty {
                Text("暂无进程数据")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: DS.Space.s, verticalSpacing: 3) {
                    GridRow {
                        Text("内存").gridColumnAlignment(.trailing)
                        Text("CPU").gridColumnAlignment(.trailing)
                        Text("命令")
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    ForEach(processes.prefix(4), id: \.pid) { proc in
                        GridRow {
                            Text(MonitorFormat.sizeShort(kb: proc.rssKB))
                            Text(MonitorFormat.processCPU(proc.cpuPercent))
                            Text(proc.command)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(proc.command)
                        }
                        .font(.system(size: 10.5).monospacedDigit())
                        // Right-click to kill straight from the rail; full
                        // confirmation + signal choice lives in the 进程详情 sheet.
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
        }
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
                        SpeedLabel(arrow: "arrow.up", color: DS.Colors.netUpload, value: tx.last ?? 0)
                        SpeedLabel(arrow: "arrow.down", color: DS.Colors.netDownload, value: rx.last ?? 0)
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
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(row.name)
            Spacer(minLength: DS.Space.s)
            SpeedLabel(arrow: "arrow.down", color: DS.Colors.netDownload, value: row.rx)
            SpeedLabel(arrow: "arrow.up", color: DS.Colors.netUpload, value: row.tx)
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

    static func == (a: DiskCard, b: DiskCard) -> Bool { a.disks == b.disks }

    var body: some View {
        MonitorCard(L("磁盘"), symbol: "internaldrive") {
            if disks.isEmpty {
                Text("暂无磁盘数据")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: DS.Space.s - 2) {
                    ForEach(disks, id: \.mount) { disk in
                        VStack(spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(disk.mount)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                    .help(disk.mount)
                                Spacer(minLength: DS.Space.s)
                                Text(MonitorFormat.sizePair(disk.availableKB, disk.totalKB))
                                    .font(.system(size: 10.5).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            UsageBar(
                                fraction: disk.usedFraction,
                                tint: usageTint(disk.usedFraction * 100),
                                height: 3
                            )
                        }
                    }
                }
            }
        } accessory: {
            Text("可用/总量")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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

    static func == (a: TrafficCard, b: TrafficCard) -> Bool {
        a.interfaceName == b.interfaceName && a.rxTotal == b.rxTotal && a.txTotal == b.txTotal
    }

    var body: some View {
        let total = Double(max(1, rxTotal &+ txTotal))
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
                    .font(.system(size: 10, design: .monospaced))
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

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: DS.Space.s)
            Text(value)
                .font(.system(size: 11).monospacedDigit())
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
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(MonitorFormat.percent(fraction * 100))
                        .font(.system(size: 9).monospacedDigit())
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

/// Overlaid download (filled area + line) and upload (line) sparkline with
/// three trailing adaptive K/M tick labels. Replaces the old stacked bar
/// histogram, which packed 60 thin bars into an unreadable solid block.
struct NetworkSparkline: View {
    let rx: [Double] // download, bytes/s
    let tx: [Double] // upload, bytes/s
    var height: CGFloat = 56

    var body: some View {
        let rxW = Array(rx.suffix(sparklineWindow))
        let txW = Array(tx.suffix(sparklineWindow))
        let count = max(rxW.count, txW.count)
        let peak = max(1024, max(rxW.max() ?? 0, txW.max() ?? 0))
        Chart {
            ForEach(Array(rxW.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("时间", index), y: .value("下载", value), series: .value("s", "rx"))
                    .foregroundStyle(.linearGradient(
                        colors: [DS.Colors.netDownload.opacity(0.30), DS.Colors.netDownload.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("时间", index), y: .value("下载", value), series: .value("s", "rx"))
                    .foregroundStyle(DS.Colors.netDownload)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                    .interpolationMethod(.monotone)
            }
            ForEach(Array(txW.enumerated()), id: \.offset) { index, value in
                LineMark(x: .value("时间", index), y: .value("上传", value), series: .value("s", "tx"))
                    .foregroundStyle(DS.Colors.netUpload)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartXScale(domain: 0...max(1, count - 1))
        .chartYScale(domain: 0...(peak * 1.2))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisValueLabel {
                    if let speed = value.as(Double.self) {
                        Text(MonitorFormat.speedAxisLabel(bytesPerSecond: speed))
                            .font(.system(size: 8.5).monospacedDigit())
                    }
                }
            }
        }
        .frame(height: height)
        // Flatten the chart into one Metal layer so a 2s tick re-renders a
        // single composited image instead of dozens of marks.
        .drawingGroup()
        // Decorative sparkline — the upstream speed-label Text nodes
        // carry the accessible upload/download values for VoiceOver.
        .accessibilityHidden(true)
    }
}

/// Isolated latency card — owns the sole @ObservedObject subscription to
/// PingService so ping updates only redraw this view, not the whole panel.
private struct LatencyCardView: View {
    @ObservedObject var ping: PingService

    var body: some View {
        MonitorCard(L("延迟"), symbol: "clock") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ping.currentMs.map { MonitorFormat.milliseconds($0) } ?? "—")
                        .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
                    Spacer(minLength: DS.Space.s)
                    if let average = ping.averageMs {
                        Text(verbatim: L("平均 %@", MonitorFormat.milliseconds(average)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if ping.latencySeries.isEmpty {
                    Text("等待 ping 响应…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    LatencySparkline(samples: ping.latencySeries)
                }
            }
        }
    }
}

/// Blue round-trip-time histogram with three trailing ms tick labels.
private struct LatencySparkline: View {
    let samples: [Double]

    var body: some View {
        let window = Array(samples.suffix(sparklineWindow))
        let peak = max(10, window.max() ?? 0)
        Chart {
            ForEach(Array(window.enumerated()), id: \.offset) { index, ms in
                BarMark(
                    x: .value("时间", index),
                    y: .value("延迟", ms)
                )
                .foregroundStyle(DS.Colors.latency.opacity(0.85))
            }
        }
        .chartXAxis(.hidden)
        .chartXScale(domain: -1...sparklineWindow)
        .chartYScale(domain: 0...(peak * 1.15))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisValueLabel {
                    if let ms = value.as(Double.self) {
                        Text("\(Int(ms.rounded()))")
                            .font(.system(size: 8.5).monospacedDigit())
                    }
                }
            }
        }
        .frame(height: 44)
        // Flatten into one Metal layer — same rationale as NetworkSparkline.
        .drawingGroup()
        // Decorative histogram — the adjacent current/average Text nodes
        // in LatencyCardView carry the accessible latency values.
        .accessibilityHidden(true)
    }
}
