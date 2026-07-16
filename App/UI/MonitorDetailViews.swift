import SwiftUI
import Charts
import HarborKit

/// Which stat card's detail panel is shown. Tapping a CPU / 内存 / 进程 / 网络
/// card in `MonitorPanel` presents `MonitorDetailSheet` for the matching kind.
enum MonitorDetailKind: String, Identifiable {
    case cpu, memory, process, network, ports, forwarding
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
    @ObservedObject var ping: PingService
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
