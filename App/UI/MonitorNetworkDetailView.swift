import SwiftUI
import HarborKit

// MARK: - Network

struct NetworkDetailView: View {
    @ObservedObject var monitor: MonitorService

    var body: some View {
        if let snap = monitor.snapshot, !snap.interfaces.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                if let selected = monitor.selectedInterface {
                    DetailSection(selected) { selectedSection(selected, snap) }
                }
                DetailSection(L("所有网卡")) { interfaceList(snap) }
            }
        } else {
            Text(L("正在采集…")).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func selectedSection(_ name: String, _ snap: SystemSnapshot) -> some View {
        let rx = monitor.rxSpeedSeries[name] ?? []
        let tx = monitor.txSpeedSeries[name] ?? []
        let counter = snap.interfaces.first { $0.name == name }
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.m) {
                speedLabel("arrow.up", DS.Colors.netUpload, tx.last ?? 0)
                speedLabel("arrow.down", DS.Colors.netDownload, rx.last ?? 0)
                Spacer()
            }
            if rx.isEmpty, tx.isEmpty {
                Text(L("正在采集…")).font(.caption).foregroundStyle(.tertiary)
            } else {
                NetworkSparkline(rx: rx, tx: tx, height: 64)
            }
            if let c = counter {
                Divider()
                DetailStatRow(L("累计接收"), MonitorFormat.sizeShort(bytes: Double(c.rxBytes)), swatch: DS.Colors.netDownload)
                DetailStatRow(L("累计发送"), MonitorFormat.sizeShort(bytes: Double(c.txBytes)), swatch: DS.Colors.netUpload)
                DetailStatRow(L("数据包 收/发"), "\(c.rxPackets) / \(c.txPackets)")
                if c.rxErrors + c.txErrors + c.rxDrops + c.txDrops > 0 {
                    DetailStatRow(
                        L("错误 / 丢弃"),
                        "\(c.rxErrors + c.txErrors) / \(c.rxDrops + c.txDrops)",
                        swatch: DS.Colors.statusError
                    )
                }
            }
        }
    }

    private func interfaceList(_ snap: SystemSnapshot) -> some View {
        let ordered = snap.interfaces.sorted { a, b in
            if (a.name == "lo") != (b.name == "lo") { return b.name == "lo" }
            return a.name < b.name
        }
        return Grid(alignment: .leading, horizontalSpacing: DS.Space.m, verticalSpacing: 6) {
            GridRow {
                Text(L("网卡"))
                Text(L("实时 ↑/↓")).gridColumnAlignment(.trailing)
                Text(L("累计 ↑/↓")).gridColumnAlignment(.trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            Divider()
            ForEach(ordered, id: \.name) { iface in
                GridRow {
                    Text(iface.name)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                        .help(iface.name)
                    Text(
                        MonitorFormat.speed(bytesPerSecond: monitor.txSpeedSeries[iface.name]?.last ?? 0)
                        + " / " +
                        MonitorFormat.speed(bytesPerSecond: monitor.rxSpeedSeries[iface.name]?.last ?? 0)
                    )
                    .font(.system(size: 10).monospacedDigit())
                    Text(
                        MonitorFormat.sizeShort(bytes: Double(iface.txBytes))
                        + " / " +
                        MonitorFormat.sizeShort(bytes: Double(iface.rxBytes))
                    )
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func speedLabel(_ arrow: String, _ color: Color, _ value: Double) -> some View {
        HStack(spacing: 3) {
            Image(systemName: arrow).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
            Text(MonitorFormat.speed(bytesPerSecond: value))
                .font(.system(size: 12).monospacedDigit())
        }
    }
}
