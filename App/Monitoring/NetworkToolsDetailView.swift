import SwiftUI
import Charts
import HarborKit

/// 网络工具 sheet: TCP ping (handshake-latency curve to the host's SSH port,
/// works where ICMP is filtered) plus an on-demand traceroute table. TCP ping
/// starts on open and keeps running so its series stays warm; traceroute only
/// runs from the button.
struct NetworkToolsDetailView: View {
    @ObservedObject var tcpPing: TcpPingService
    @ObservedObject var traceroute: TracerouteService
    @ScaledMetric(relativeTo: .title3) private var currentFontSize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption) private var rowFontSize: CGFloat = 10.5
    @ScaledMetric(relativeTo: .caption2) private var axisFontSize: CGFloat = 8.5

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            tcpPingSection
            tracerouteSection
        }
        .onAppear { tcpPing.start() }
    }

    // MARK: - TCP ping

    private var tcpPingSection: some View {
        DetailSection(L("TCP Ping")) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text(tcpPing.currentMs.map { MonitorFormat.milliseconds($0) } ?? "—")
                        .font(.system(size: currentFontSize, weight: .medium, design: .rounded).monospacedDigit())
                    if let average = tcpPing.averageMs {
                        Text(L("平均 %@", MonitorFormat.milliseconds(average)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    successRateLabel
                    Button(tcpPing.isRunning ? L("暂停") : L("开始")) {
                        if tcpPing.isRunning { tcpPing.pause() } else { tcpPing.start() }
                    }
                    .controlSize(.small)
                }
                if let error = tcpPing.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(DS.Colors.statusError)
                }
                if tcpPing.latencySeries.isEmpty {
                    Text(tcpPing.isRunning ? L("等待第一次 TCP 握手…") : L("已暂停。"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    tcpPingChart
                }
                Text(L("每秒一次到 %@:%lld 的 TCP 握手；ICMP 被过滤时它比 ping 更能反映真实可达性。",
                       tcpPingTargetHost, tcpPing.port))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var tcpPingTargetHost: String { tcpPing.hostname }

    private var successRateLabel: some View {
        let total = tcpPing.successCount + tcpPing.failureCount
        let rate = total > 0 ? Double(tcpPing.successCount) / Double(total) * 100 : nil
        return Text(rate.map { L("成功率 %@", MonitorFormat.percent($0)) } ?? L("成功率 —"))
            .font(.caption.monospacedDigit())
            .foregroundStyle(rate.map { $0 < 100 ? AnyShapeStyle(DS.Colors.statusError) : AnyShapeStyle(.secondary) } ?? AnyShapeStyle(.tertiary))
    }

    /// Pulse bars matching the ICMP 延迟 card and FinalShell's ping graph:
    /// steel-blue vertical spikes via the shared `SpikeGraph` painter.
    private var tcpPingChart: some View {
        SpikeGraph(
            series: [.init(values: Array(tcpPing.latencySeries.suffix(60)), color: NetGraphPalette.latency, alpha: NetGraphPalette.latencyAlpha)],
            height: 48,
            labelFormat: { "\(Int($0.rounded()))" }
        )
    }

    // MARK: - Traceroute

    private var tracerouteSection: some View {
        DetailSection(L("路由追踪")) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Text(L("目标 %@（本机 traceroute）", traceroute.hostname))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if traceroute.status == .running {
                        Button(L("停止")) { traceroute.stop() }
                            .controlSize(.small)
                    } else {
                        Button(traceroute.hops.isEmpty ? L("开始") : L("重新追踪")) { traceroute.start() }
                            .controlSize(.small)
                    }
                }
                statusLine
                if !traceroute.hops.isEmpty { hopTable }
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch traceroute.status {
        case .idle:
            Text(L("尚未开始路由追踪。"))
                .font(.caption2).foregroundStyle(.tertiary)
        case .running:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(monitorSpinnerScale)
                Text(L("正在追踪到 %@ 的路由…", traceroute.hostname))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        case .finished:
            Text(L("追踪完成，共 %lld 跳。", traceroute.hops.count))
                .font(.caption2).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption2).foregroundStyle(DS.Colors.statusError)
        }
    }

    private var hopTable: some View {
        Grid(alignment: .leading, horizontalSpacing: DS.Space.s + 1, verticalSpacing: 4) {
            GridRow {
                Text(L("跳"))
                Text(L("地址"))
                Text(L("RTT")).gridColumnAlignment(.trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            Divider()
            ForEach(traceroute.hops) { hop in
                GridRow {
                    Text("\(hop.number)")
                        .foregroundStyle(.tertiary)
                    Text(hop.isLoss ? "* * *" : hop.address)
                        .foregroundStyle(hop.isLoss ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(hop.isLoss ? L("此跳无响应") : hop.address)
                    Text(hop.bestRttMs.map { MonitorFormat.milliseconds($0) } ?? "—")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: rowFontSize).monospacedDigit())
            }
        }
    }
}
