import SwiftUI
import HarborKit

// MARK: - Processes

struct ProcessDetailView: View {
    @ObservedObject var monitor: MonitorService
    @State private var sortKey: ProcessSortKey = .cpu
    @State private var sortAscending = false
    /// The process awaiting a kill confirmation, plus the signal to send. Held
    /// together so the dialog text and the action use the same target. Uses the
    /// shared `ProcessKillTarget` (defined in MonitorPanel) so the rail's compact
    /// 进程 card and this sheet raise an identical confirmation.
    @State private var pendingKill: ProcessKillTarget?
    /// The process whose detail popover is open (tapping a row). Wrapped so it
    /// can drive `.popover(item:)`; identified by pid.
    @State private var inspected: InspectedProcess?

    private struct InspectedProcess: Identifiable {
        let process: TopProcess
        var id: Int { process.pid }
    }

    private var processes: [TopProcess] {
        let list = monitor.snapshot?.topProcesses ?? []
        switch sortKey {
        case .cpu:
            return list.sorted { sortAscending ? $0.cpuPercent < $1.cpuPercent : $0.cpuPercent > $1.cpuPercent }
        case .memory:
            return list.sorted { sortAscending ? $0.rssKB < $1.rssKB : $0.rssKB > $1.rssKB }
        case .name:
            return list.sorted { sortAscending ? $0.command < $1.command : $0.command > $1.command }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Picker(L("排序"), selection: $sortKey) {
                    Text(L("按 CPU")).tag(ProcessSortKey.cpu)
                    Text(L("按内存")).tag(ProcessSortKey.memory)
                    Text(L("按名称")).tag(ProcessSortKey.name)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button {
                    sortAscending.toggle()
                } label: {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(sortAscending ? L("升序") : L("降序"))
            }

            // Transient banner for a failed kill (e.g. permission denied / gone).
            if let error = monitor.lastActionError {
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

            if processes.isEmpty {
                Text(L("暂无进程数据")).font(.caption).foregroundStyle(.tertiary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: DS.Space.s + 1, verticalSpacing: 5) {
                    GridRow {
                        Text(L("PID")).gridColumnAlignment(.trailing)
                        Text(L("用户"))
                        Text(L("CPU")).gridColumnAlignment(.trailing)
                        Text(L("内存")).gridColumnAlignment(.trailing)
                        Text(L("命令"))
                        Text("")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    Divider()
                    ForEach(processes, id: \.pid) { proc in
                        GridRow {
                            Text(proc.pid > 0 ? "\(proc.pid)" : "—")
                                .foregroundStyle(.secondary)
                            Text(proc.user.isEmpty ? "—" : proc.user)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(MonitorFormat.processCPU(proc.cpuPercent))
                                .foregroundStyle(proc.cpuPercent >= 50 ? DS.Colors.statusError : .primary)
                            Text(MonitorFormat.sizeShort(kb: proc.rssKB))
                            Text(proc.command)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(proc.command)
                            // Always-visible end-process button so the action is
                            // discoverable without knowing about the right-click.
                            killButton(for: proc)
                        }
                        .font(.system(size: 10.5).monospacedDigit())
                        // Tap a row to inspect; whole-row hit target also backs
                        // the right-click menu over the empty 命令 stretch.
                        .contentShape(Rectangle())
                        .onTapGesture { if proc.pid > 0 { inspected = InspectedProcess(process: proc) } }
                        .contextMenu { killMenu(for: proc) }
                    }
                }
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
        .popover(item: $inspected) { item in
            ProcessInspectorView(monitor: monitor, process: item.process)
        }
    }

    /// Right-click actions for one row. Hidden for kernel/aggregate rows that
    /// carry no real pid (`pid <= 0`), which cannot be signalled anyway.
    @ViewBuilder
    private func killMenu(for proc: TopProcess) -> some View {
        if proc.pid > 0 {
            Button(L("结束进程")) { pendingKill = ProcessKillTarget(process: proc, signal: .term) }
            Button(L("强制结束"), role: .destructive) {
                pendingKill = ProcessKillTarget(process: proc, signal: .kill)
            }
        }
    }

    /// The always-visible per-row stop button. A no-pid (kernel/aggregate) row
    /// shows a disabled placeholder so the column still aligns.
    @ViewBuilder
    private func killButton(for proc: TopProcess) -> some View {
        if proc.pid > 0 {
            Button {
                pendingKill = ProcessKillTarget(process: proc, signal: .term)
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.statusError)
            }
            .buttonStyle(.plain)
            .help(L("结束进程"))
        } else {
            Color.clear.frame(width: 12, height: 12)
        }
    }

    /// Confirmation prompt naming the signal, command and pid being targeted.
    private func killTitle(_ target: ProcessKillTarget?) -> String {
        guard let target else { return "" }
        let verb = target.signal == .kill ? L("强制结束") : L("结束进程")
        return L("%@：%@（PID %lld）？", verb, target.process.command, Int(target.process.pid))
    }
}

/// On-demand detail for one process, shown as a popover when a row is tapped.
/// Loads the rich `ProcessDetail` (parent, state, threads, memory split, start
/// time, full command line) and offers prominent, *visible* 结束/强制结束 actions
/// — the kill that used to hide behind a right-click only.
struct ProcessInspectorView: View {
    @ObservedObject var monitor: MonitorService
    let process: TopProcess
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    @State private var detail: ProcessDetail?
    @State private var loading = true
    @State private var pendingKill: ProcessKillTarget?
    /// Ports this pid is listening on (from the same on-demand `ss` probe),
    /// shown so "what is this process serving" is answerable inline.
    @State private var listening: [ListeningPort] = []

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(process.command)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()

            if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("正在读取进程信息…")).font(.caption).foregroundStyle(.secondary)
                }
            } else if let d = detail {
                Grid(alignment: .leading, horizontalSpacing: DS.Space.m, verticalSpacing: 4) {
                    infoRow(L("PID"), "\(d.pid)")
                    infoRow(L("父进程"), "\(d.ppid)")
                    infoRow(L("用户"), d.user.isEmpty ? "—" : d.user)
                    infoRow(L("状态"), stateText(d.state))
                    infoRow(L("CPU"), MonitorFormat.processCPU(d.cpuPercent))
                    infoRow(L("内存占用"), String(format: "%.1f%%", d.memPercent))
                    infoRow(L("常驻内存"), MonitorFormat.sizeShort(kb: d.rssKB))
                    infoRow(L("虚拟内存"), MonitorFormat.sizeShort(kb: d.vszKB))
                    infoRow(L("线程数"), "\(d.threads)")
                    infoRow(L("优先级"), L("%lld（nice %lld）", d.priority, d.nice))
                    if d.elapsedSeconds > 0 {
                        infoRow(L("已运行"), MonitorFormat.uptime(seconds: Double(d.elapsedSeconds), locale: locale))
                    }
                    if !d.startTime.isEmpty {
                        infoRow(L("启动时间"), d.startTime)
                    }
                }
                .font(.system(size: 11).monospacedDigit())

                if !d.command.isEmpty {
                    Text(L("命令行")).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    Text(d.command)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !listening.isEmpty {
                    Text(L("监听端口")).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    ForEach(listening) { p in
                        HStack(spacing: 5) {
                            Text(p.proto)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text("\(p.address):\(p.port)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(p.isWildcard ? AnyShapeStyle(DS.Colors.statusConnecting) : AnyShapeStyle(.secondary))
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                }
            } else {
                Text(L("进程已退出或无法读取")).font(.caption).foregroundStyle(.secondary)
            }

            if let error = monitor.lastActionError {
                Text(error).font(.caption).foregroundStyle(DS.Colors.statusError).lineLimit(2)
            }

            Divider()
            HStack(spacing: DS.Space.s) {
                Button {
                    pendingKill = ProcessKillTarget(process: process, signal: .term)
                } label: {
                    Label(L("结束进程"), systemImage: "stop.circle")
                }
                Button(role: .destructive) {
                    pendingKill = ProcessKillTarget(process: process, signal: .kill)
                } label: {
                    Label(L("强制结束"), systemImage: "xmark.octagon")
                }
                .tint(DS.Colors.statusError)
                Spacer(minLength: 0)
            }
            .disabled(process.pid <= 0)
        }
        .padding(DS.Space.m)
        .frame(width: 320)
        .task { await load() }
        .onChange(of: monitor.frame) { _, _ in
            // Re-fetch when the monitor ticks so the inspector stays current.
            guard !loading else { return }
            Task { await load() }
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
                Task {
                    let ok = await monitor.terminate(pid: Int32(target.process.pid), signal: target.signal)
                    if ok { dismiss() }
                }
            }
            Button(L("取消"), role: .cancel) {}
        }
    }

    private func load() async {
        loading = true
        // Detail and the listening-port probe run concurrently over the shared
        // socket — one round-trip of latency, not two.
        async let detailFetch = monitor.fetchDetail(pid: Int32(process.pid))
        async let portsFetch = monitor.fetchListeningPorts()
        detail = await detailFetch
        listening = (await portsFetch)?
            .filter { $0.pid == process.pid }
            .sorted { $0.port < $1.port } ?? []
        loading = false
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Maps the leading `stat` letter to a human label, keeping the raw code in
    /// parentheses for the flags (e.g. "l" threaded, "+" foreground) that follow.
    private func stateText(_ stat: String) -> String {
        guard let first = stat.first else { return "—" }
        let name: String
        switch first {
        case "R": name = L("运行中")
        case "S": name = L("睡眠")
        case "D": name = L("不可中断")
        case "T", "t": name = L("已停止")
        case "Z": name = L("僵尸")
        case "I": name = L("空闲")
        default: name = ""
        }
        return name.isEmpty ? stat : "\(name)（\(stat)）"
    }

    private func killTitle(_ target: ProcessKillTarget?) -> String {
        guard let target else { return "" }
        let verb = target.signal == .kill ? L("强制结束") : L("结束进程")
        return L("%@：%@（PID %lld）？", verb, target.process.command, Int(target.process.pid))
    }
}

// MARK: - Listening ports

/// A pid targeted for a kill from the ports list, paired with its signal. Built
/// from a `ListeningPort` (which carries pid + process name) so the ports panel
/// can raise the same confirmation flow as the process list without a TopProcess.
struct PortKillTarget: Identifiable {
    let pid: Int
    let process: String
    let port: Int
    let signal: MonitorService.KillSignal
    var id: String { "\(pid)-\(signal.rawValue)" }
}

/// On-demand "谁占了 8080" panel: runs `ss -tulnpH` once over the shared socket
/// and lists every listening tcp/udp port with its bind address and owning
/// process. A live search filters by port, process or address; each attributed
/// row offers a visible 结束进程 button. Process names need root to see *other*
/// users' sockets — without it ports still list, just without an owner.
struct PortsDetailView: View {
    @ObservedObject var monitor: MonitorService

    /// nil = not yet loaded; the load distinguishes "couldn't ask" (loadFailed)
    /// from "nothing listening" (empty array).
    @State private var ports: [ListeningPort]?
    @State private var loading = true
    @State private var loadFailed = false
    @State private var query = ""
    @State private var pendingKill: PortKillTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField(L("搜索端口 / 进程 / 地址"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("刷新"))
                .disabled(loading)
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(DS.Colors.barTrack))

            if let error = monitor.lastActionError {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(DS.Colors.statusError)
                    Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                }
            }

            if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("正在读取监听端口…")).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, DS.Space.s)
            } else if loadFailed {
                Text(L("无法读取端口信息（可能服务器缺少 ss 命令）。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, DS.Space.s)
            } else if filtered.isEmpty {
                Text(ports?.isEmpty == true ? L("没有监听中的端口。") : L("没有匹配的端口。"))
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.top, DS.Space.s)
            } else {
                portsGrid
            }
        }
        .task { await load() }
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
                Task {
                    let ok = await monitor.terminate(pid: Int32(target.pid), signal: target.signal)
                    if ok { await load() } // refresh so the freed port disappears
                }
            }
            Button(L("取消"), role: .cancel) {}
        }
    }

    private var portsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: DS.Space.s + 1, verticalSpacing: 5) {
            GridRow {
                Text(L("协议"))
                Text(L("端口")).gridColumnAlignment(.trailing)
                Text(L("地址"))
                Text(L("进程"))
                Text("")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            Divider()
            ForEach(filtered) { port in
                GridRow {
                    Text(port.proto)
                        .foregroundStyle(.secondary)
                    Text("\(port.port)")
                        .foregroundStyle(.primary)
                    Text(port.address)
                        .foregroundStyle(port.isWildcard ? AnyShapeStyle(DS.Colors.statusConnecting) : AnyShapeStyle(.secondary))
                        .lineLimit(1).truncationMode(.middle)
                        .help(port.isWildcard ? L("对所有地址开放") : port.address)
                    Text(processLabel(port))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .help(processLabel(port))
                    killButton(for: port)
                }
                .font(.system(size: 10.5).monospacedDigit())
            }
        }
    }

    @ViewBuilder
    private func killButton(for port: ListeningPort) -> some View {
        if port.pid > 0 {
            Button {
                pendingKill = PortKillTarget(
                    pid: port.pid, process: port.process, port: port.port, signal: .term)
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.statusError)
            }
            .buttonStyle(.plain)
            .help(L("结束占用此端口的进程"))
        } else {
            Color.clear.frame(width: 12, height: 12)
        }
    }

    private func processLabel(_ port: ListeningPort) -> String {
        if port.process.isEmpty { return port.pid > 0 ? "PID \(port.pid)" : "—" }
        return "\(port.process)（\(port.pid)）"
    }

    /// Sorted by port ascending, filtered by the search text (port / process /
    /// address, case-insensitive).
    private var filtered: [ListeningPort] {
        let base = (ports ?? []).sorted {
            $0.port != $1.port ? $0.port < $1.port : $0.proto < $1.proto
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter {
            "\($0.port)".contains(q)
                || $0.process.lowercased().contains(q)
                || $0.address.lowercased().contains(q)
                || $0.proto.contains(q)
        }
    }

    private func load() async {
        loading = true
        loadFailed = false
        let result = await monitor.fetchListeningPorts()
        ports = result
        loadFailed = (result == nil)
        loading = false
    }

    private func killTitle(_ target: PortKillTarget?) -> String {
        guard let target else { return "" }
        let verb = target.signal == .kill ? L("强制结束") : L("结束进程")
        let name = target.process.isEmpty ? L("未知进程") : target.process
        return L("%@：%@（PID %lld，端口 %lld）？", verb, name, Int(target.pid), Int(target.port))
    }
}
