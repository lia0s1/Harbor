import SwiftUI
import HarborKit

/// TCP connection quality sheet: runs the double-sample `ss -ni` probe on
/// open (two snapshots 3s apart over one aux round-trip) and shows the
/// aggregate RTT / retransmission picture plus the worst-offending
/// connections. Re-measure via the refresh button; nothing here is polled.
struct TCPQualityDetailView: View {
    @ObservedObject var monitor: MonitorService
    /// nil = not yet measured; the spinner distinguishes loading from failed.
    @State private var report: TCPQualityReport?
    @State private var loading = false
    @State private var loadFailed = false
    @ScaledMetric(relativeTo: .caption) private var rowFontSize: CGFloat = 10.5

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            headerRow
            if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("正在测量 TCP 连接质量（双采样，约 3 秒）…"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if loadFailed {
                Text(L("无法测量 TCP 质量（可能服务器缺少 ss 命令）。"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let report {
                summarySection(report)
                hotspotsSection(report)
            }
        }
        .task { await measure() }
    }

    private var headerRow: some View {
        HStack(spacing: DS.Space.s) {
            Text(L("通过两次 ss -ni 采样（间隔 3 秒）计算重传增量与 RTT。"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            MonitorIconButton(
                systemName: "arrow.clockwise",
                label: L("重新测量")
            ) { Task { await measure() } }
            .disabled(loading)
        }
    }

    private func summarySection(_ report: TCPQualityReport) -> some View {
        DetailSection(L("质量概况")) {
            VStack(spacing: DS.Space.s - 2) {
                DetailStatRow(L("TCP 连接数"), "\(report.connectionCount)")
                DetailStatRow(L("已建立"), "\(report.establishedCount)")
                DetailStatRow(L("平均 RTT"), report.averageRttMs.map(MonitorFormat.milliseconds) ?? "—")
                DetailStatRow(L("最大 RTT"), report.maxRttMs.map(MonitorFormat.milliseconds) ?? "—")
                DetailStatRow(L("采样窗口"), L("%lld 秒", Int(report.intervalSeconds)))
                DetailStatRow(
                    L("窗口内重传段数"),
                    L("%lld / %lld", report.retransDelta, Int(report.segsOutDelta))
                )
                DetailStatRow(L("重传率"), rateText(report.retransRatePercent))
                DetailStatRow(L("字节重传率"), rateText(report.byteRetransRatePercent))
            }
        }
    }

    @ViewBuilder
    private func hotspotsSection(_ report: TCPQualityReport) -> some View {
        DetailSection(L("重传最多的连接")) {
            if report.connectionCount == 0 {
                Text(L("当前没有使用中的 TCP 连接。"))
                    .font(.caption).foregroundStyle(.tertiary)
            } else if report.retransHotspots.isEmpty {
                Text(L("采样窗口内没有发生重传。"))
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: DS.Space.s + 1, verticalSpacing: 5) {
                    GridRow {
                        Text(L("连接"))
                        Text(L("RTT")).gridColumnAlignment(.trailing)
                        Text(L("重传")).gridColumnAlignment(.trailing)
                        Text(L("发送段数")).gridColumnAlignment(.trailing)
                        Text(L("重传率")).gridColumnAlignment(.trailing)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    Divider()
                    ForEach(report.retransHotspots.prefix(10)) { delta in
                        GridRow {
                            Text(connectionLabel(delta.connection))
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(connectionLabel(delta.connection))
                            Text(delta.connection.rttMs.map(MonitorFormat.milliseconds) ?? "—")
                                .foregroundStyle(.secondary)
                            Text("+\(delta.retransDelta)")
                                .foregroundStyle(DS.Colors.statusError)
                            Text("\(delta.segsOutDelta)")
                                .foregroundStyle(.secondary)
                            Text(rateText(delta.retransRatePercent))
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: rowFontSize).monospacedDigit())
                    }
                }
            }
        }
    }

    private func connectionLabel(_ conn: TCPConnectionInfo) -> String {
        "\(conn.localAddress):\(conn.localPort) → \(conn.peerAddress):\(conn.peerPort)"
    }

    /// Two decimals below 10%, one above ("0.35%", "4.2%", "12.4%"); nil → "—".
    private func rateText(_ rate: Double?) -> String {
        guard let rate, rate.isFinite else { return "—" }
        return rate < 10 ? String(format: "%.2f%%", rate) : String(format: "%.1f%%", rate)
    }

    private func measure() async {
        loading = true
        loadFailed = false
        let result = await monitor.fetchTCPQuality()
        report = result
        loadFailed = (result == nil)
        loading = false
    }
}
