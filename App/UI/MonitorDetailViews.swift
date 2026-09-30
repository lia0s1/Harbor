import SwiftUI
import Charts
import HarborKit

/// Which stat card's detail panel is shown. Tapping a CPU / 内存 / 进程 / 网络 /
/// 磁盘 card in `MonitorPanel` presents `MonitorDetailSheet` for the matching kind.
enum MonitorDetailKind: String, Identifiable {
    case cpu, memory, process, network, ports, disk, forwarding
    var id: String { rawValue }
}

/// The single sheet the monitor panel may present. One `.sheet(item:)` drives
/// both the 系统信息 report and the per-card detail, so two sheet modifiers are
/// never stacked on one view (which would silently drop the second).
enum MonitorSheet: Identifiable {
    case systemInfo
    case detail(MonitorDetailKind)
    var id: String {
        switch self {
        case .systemInfo: return "systemInfo"
        case .detail(let kind): return kind.rawValue
        }
    }
}

/// Pop-out detail for one monitoring card. Observes the live `MonitorService`,
/// so every 2s tick refreshes the panel in place (per-core CPU, memory
/// breakdown, full process list, per-interface network). For `.forwarding` the
/// optional `forwarding` service drives the live enable/disable toggles.
struct MonitorDetailSheet: View {
    let kind: MonitorDetailKind
    @ObservedObject var monitor: MonitorService
    let ping: PingService
    var forwarding: ForwardingService? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(DS.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 470, height: 560)
    }

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(L("关闭"))
        }
        .padding(DS.Space.m)
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .cpu: CPUDetailView(monitor: monitor)
        case .memory: MemoryDetailView(monitor: monitor)
        case .process: ProcessDetailView(monitor: monitor)
        case .network: NetworkDetailView(monitor: monitor)
        case .ports: PortsDetailView(monitor: monitor)
        case .disk: DiskDetailView(monitor: monitor)
        case .forwarding:
            if let forwarding {
                ForwardingDetailView(service: forwarding)
            } else {
                Text(L("暂无转发数据"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var title: String {
        switch kind {
        case .cpu: return L("CPU 详情")
        case .memory: return L("内存详情")
        case .process: return L("进程详情")
        case .network: return L("网络详情")
        case .ports: return L("监听端口")
        case .disk: return L("磁盘详情")
        case .forwarding: return L("端口转发")
        }
    }

    private var symbol: String {
        switch kind {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .process: return "list.bullet.rectangle"
        case .network: return "arrow.up.arrow.down"
        case .ports: return "network"
        case .disk: return "internaldrive"
        case .forwarding: return "arrow.triangle.swap"
        }
    }
}

// MARK: - Shared detail pieces

/// Titled section: small uppercase-ish caption header + content below.
struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

/// "label … value" row, optionally led by a small color swatch.
struct DetailStatRow: View {
    let label: String
    let value: String
    let swatch: Color?
    init(_ label: String, _ value: String, swatch: Color? = nil) {
        self.label = label
        self.value = value
        self.swatch = swatch
    }
    var body: some View {
        HStack(spacing: DS.Space.s) {
            if let swatch {
                RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 9, height: 9)
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: DS.Space.s)
            Text(value).font(.system(size: 11).monospacedDigit())
        }
    }
}

/// Thin proportional line for a single component (no track styling fuss).
struct ProgressLine: View {
    let fraction: Double
    let tint: Color
    var body: some View {
        Capsule()
            .fill(DS.Colors.barTrack)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: max(0, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 5)
    }
}

/// Horizontal stacked bar of proportional colored segments (memory composition).
struct SegmentedBar: View {
    struct Segment: Identifiable {
        let id = UUID()
        let value: Double
        let color: Color
        let label: String
    }
    let segments: [Segment]

    var body: some View {
        let total = max(1, segments.reduce(0) { $0 + $1.value })
        Capsule()
            .fill(DS.Colors.barTrack.opacity(0))
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(segments) { segment in
                            segment.color
                                .frame(width: max(0, geo.size.width * (segment.value / total)))
                        }
                    }
                    .clipShape(Capsule())
                }
            }
            .frame(height: 10)
    }
}

// MARK: - Disk

/// Per-mount disk table for the 磁盘 detail sheet: one row per real filesystem
/// (device, mount point, type, total/used/available, fill %), root first.
struct DiskDetailView: View {
    @ObservedObject var monitor: MonitorService

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            if sortedDisks.isEmpty {
                Text(L("暂无磁盘数据"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                DetailSection(L("挂载点")) { table }
            }
        }
    }

    /// Root first (the row users scan for), then alphabetical by mount point.
    private var sortedDisks: [DiskUsage] {
        (monitor.snapshot?.disks ?? []).sorted { a, b in
            if (a.mount == "/") != (b.mount == "/") { return a.mount == "/" }
            return a.mount < b.mount
        }
    }

    private var table: some View {
        VStack(spacing: DS.Space.m) {
            headerRow
            ForEach(sortedDisks, id: \.mount) { disk in
                VStack(spacing: 4) {
                    dataRow(disk)
                    UsageBar(
                        fraction: disk.usedFraction,
                        tint: usageTint(disk.usedFraction * 100),
                        height: 4
                    )
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: DS.Space.s) {
            Text(L("设备")).frame(width: 72, alignment: .leading)
            Text(L("挂载点")).frame(width: 82, alignment: .leading)
            Text(L("文件系统类型")).frame(width: 62, alignment: .leading)
            Text(L("总量")).frame(width: 46, alignment: .trailing)
            Text(L("已用")).frame(width: 46, alignment: .trailing)
            Text(L("可用")).frame(width: 46, alignment: .trailing)
            Text(L("使用%")).frame(width: 34, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func dataRow(_ disk: DiskUsage) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(disk.device.isEmpty ? "—" : disk.device)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(disk.device)
                .frame(width: 72, alignment: .leading)
            Text(disk.isContainerOverlay ? L("容器 overlay") : disk.mount)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(disk.mount)
                .frame(width: 82, alignment: .leading)
            Text(disk.fstype.isEmpty ? "—" : disk.fstype)
                .font(.system(size: 10))
                .lineLimit(1)
                .frame(width: 62, alignment: .leading)
            sizeText(MonitorFormat.sizeShort(kb: disk.totalKB))
            sizeText(MonitorFormat.sizeShort(kb: disk.usedKB))
            sizeText(MonitorFormat.sizeShort(kb: disk.availableKB))
            Text(MonitorFormat.percent(disk.usedFraction * 100))
                .font(.system(size: 10).monospacedDigit())
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func sizeText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 10).monospacedDigit())
            .frame(width: 46, alignment: .trailing)
    }
}
