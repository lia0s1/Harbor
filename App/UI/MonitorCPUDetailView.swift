import SwiftUI
import Charts
import HarborKit

// MARK: - CPU

struct CPUDetailView: View {
    @ObservedObject var monitor: MonitorService

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            totalSection
            if let breakdown = monitor.cpuBreakdown {
                DetailSection(L("占用构成")) { breakdownRows(breakdown) }
            }
            DetailSection(L("各核心")) { coreGrid }
        }
    }

    private var totalSection: some View {
        let percent = monitor.cpuSeries.last
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(percent.map { MonitorFormat.percent($0) } ?? "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(usageTint(percent ?? 0))
                Text(L("总占用"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let cores = coreCount {
                    Text(L("%lld 核", cores))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let snap = monitor.snapshot {
                HStack(spacing: DS.Space.s) {
                    Text(L("负载"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(MonitorFormat.loadAverage(snap.load1, snap.load5, snap.load15))
                        .font(.system(size: 12).monospacedDigit())
                    Text(L("（1 / 5 / 15 分钟）"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            if monitor.cpuSeries.count > 1 {
                CPUHistoryChart(series: monitor.cpuSeries)
            }
        }
    }

    private var coreCount: Int? {
        let n = monitor.cpuCorePercents.count
        return n > 0 ? n : nil
    }

    @ViewBuilder
    private func breakdownRows(_ b: MonitorParsers.CPUBreakdown) -> some View {
        VStack(spacing: 5) {
            componentRow(L("用户"), b.user, .blue)
            componentRow(L("系统"), b.system, .orange)
            componentRow(L("IO 等待"), b.iowait, .pink)
            if b.nice > 0.05 { componentRow(L("nice"), b.nice, .teal) }
            if b.irq + b.softirq > 0.05 { componentRow(L("中断"), b.irq + b.softirq, .purple) }
            if b.steal > 0.05 { componentRow(L("被偷取"), b.steal, .red) }
            componentRow(L("空闲"), b.idle, .gray)
        }
    }

    private func componentRow(_ label: String, _ percent: Double, _ color: Color) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            ProgressLine(fraction: percent / 100, tint: color)
            Text(MonitorFormat.percent(percent))
                .font(.system(size: 10.5).monospacedDigit())
                .frame(width: 38, alignment: .trailing)
        }
    }

    private var coreGrid: some View {
        let cores = monitor.cpuCorePercents
        return Group {
            if cores.isEmpty {
                Text(L("此服务器未提供每核心数据。"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: DS.Space.m),
                              GridItem(.flexible(), spacing: DS.Space.m)],
                    spacing: 7
                ) {
                    ForEach(Array(cores.enumerated()), id: \.offset) { index, pct in
                        HStack(spacing: 6) {
                            Text(L("核%lld", index))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .leading)
                            UsageBar(fraction: pct / 100, tint: usageTint(pct), height: 5)
                            Text(MonitorFormat.percent(pct))
                                .font(.system(size: 10).monospacedDigit())
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
}

private struct CPUHistoryChart: View {
    let series: [Double]

    var body: some View {
        let window = Array(series.suffix(90))
        Chart {
            ForEach(Array(window.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("t", index), y: .value("cpu", value))
                    .foregroundStyle(
                        .linearGradient(
                            colors: [DS.Colors.statusRunning.opacity(0.35), DS.Colors.statusRunning.opacity(0.04)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                LineMark(x: .value("t", index), y: .value("cpu", value))
                    .foregroundStyle(DS.Colors.statusRunning)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
        .chartXAxis(.hidden)
        .chartXScale(domain: 0...max(1, window.count - 1))
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))").font(.system(size: 8.5).monospacedDigit())
                    }
                }
            }
        }
        .frame(height: 96)
        .drawingGroup()
    }
}
