import SwiftUI
import HarborKit

/// Full connection table (`ss -tupnH` on demand): every tcp/udp socket with
/// state, endpoints and owning process. Grouped summaries on top (per-state
/// chips and top talkers by peer), the searchable table below. Fetched once
/// on open + on 刷新 — never on the 2s loop.
struct ConnectionsDetailView: View {
    @ObservedObject var monitor: MonitorService

    /// nil = not yet loaded; loadFailed distinguishes "couldn't ask" (ss
    /// missing / socket dead) from "no connections" (empty array).
    @State private var connections: [ConnectionEntry]?
    @State private var loading = true
    @State private var loadFailed = false
    @State private var query = ""
    @ScaledMetric(relativeTo: .callout) private var searchFontSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption) private var rowFontSize: CGFloat = 10.5

    /// Hard cap on rendered table rows; a busy host can hold thousands of
    /// TIME_WAITs and a SwiftUI Grid must not try to layout them all.
    private static let maxRows = 200

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            searchBar
            if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("正在读取连接表…")).font(.caption).foregroundStyle(.secondary)
                }
            } else if loadFailed {
                Text(L("无法读取连接表（可能服务器缺少 ss 命令）。"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let connections {
                if connections.isEmpty {
                    Text(L("没有活动连接。")).font(.caption).foregroundStyle(.tertiary)
                } else {
                    stateSummary(connections)
                    peerSummary(connections)
                    tableSection(connections)
                }
            }
        }
        .task { await load() }
    }

    private var searchBar: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField(L("搜索地址 / 端口 / 进程 / 状态"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: searchFontSize))
            Spacer(minLength: 0)
            MonitorIconButton(
                systemName: "arrow.clockwise",
                label: L("刷新")
            ) { Task { await load() } }
            .disabled(loading)
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(DS.Colors.barTrack))
    }

    /// Per-state counts (ESTAB × 12, TIME-WAIT × 30…), most common first.
    private func stateSummary(_ connections: [ConnectionEntry]) -> some View {
        let groups = SSConnectionsParser.groupByState(connections)
        return DetailSection(L("按状态分组")) {
            Grid(alignment: .leading, horizontalSpacing: DS.Space.m, verticalSpacing: 4) {
                ForEach(groups) { group in
                    GridRow {
                        Text(group.label)
                            .foregroundStyle(stateTint(group.label))
                        Text(L("%lld 条", group.count))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                    }
                    .font(.system(size: rowFontSize).monospacedDigit())
                }
            }
        }
    }

    /// Top talkers: peers holding the most connections (wildcard/unconnected
    /// peers already excluded by the parser helper). Capped at 10 rows.
    @ViewBuilder
    private func peerSummary(_ connections: [ConnectionEntry]) -> some View {
        let groups = SSConnectionsParser.groupByPeer(connections)
        if !groups.isEmpty {
            DetailSection(L("按远端地址")) {
                Grid(alignment: .leading, horizontalSpacing: DS.Space.m, verticalSpacing: 4) {
                    ForEach(groups.prefix(10)) { group in
                        GridRow {
                            Text(group.label)
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .help(group.label)
                            Text(L("%lld 条", group.count))
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                        }
                        .font(.system(size: rowFontSize, design: .monospaced))
                    }
                }
            }
        }
    }

    private func tableSection(_ connections: [ConnectionEntry]) -> some View {
        DetailSection(L("全部连接")) {
            if filtered.isEmpty {
                Text(L("没有匹配的连接。")).font(.caption).foregroundStyle(.tertiary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: DS.Space.s + 1, verticalSpacing: 5) {
                    GridRow {
                        Text(L("协议"))
                        Text(L("状态"))
                        Text(L("本地"))
                        Text(L("远端"))
                        Text(L("进程"))
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    Divider()
                    ForEach(filtered.prefix(Self.maxRows)) { conn in
                        GridRow {
                            Text(conn.proto).foregroundStyle(.tertiary)
                            Text(conn.state).foregroundStyle(stateTint(conn.state))
                            Text("\(conn.localAddress):\(conn.localPort)")
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Text(conn.peerDescription)
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Text(conn.process.isEmpty ? "—" : conn.process)
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        .font(.system(size: rowFontSize).monospacedDigit())
                    }
                }
                if filtered.count > Self.maxRows {
                    Text(L("等 %lld 项（仅显示前 %lld 条）", filtered.count, Self.maxRows))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// States that deserve attention tint; the rest read as secondary.
    private func stateTint(_ state: String) -> AnyShapeStyle {
        switch state {
        case "ESTAB", "ESTABLISHED":
            return AnyShapeStyle(DS.Colors.statusRunning)
        case "CLOSE-WAIT", "FIN-WAIT-1", "FIN-WAIT-2", "LAST-ACK":
            return AnyShapeStyle(DS.Colors.statusConnecting)
        default:
            return AnyShapeStyle(.secondary)
        }
    }

    /// Filtered by the search text (address / port / process / state, case-
    /// insensitive), ESTAB first then by state name for a stable scan order.
    private var filtered: [ConnectionEntry] {
        let base = (connections ?? []).sorted {
            let aEstab = $0.state.hasPrefix("ESTAB"), bEstab = $1.state.hasPrefix("ESTAB")
            if aEstab != bEstab { return aEstab }
            if $0.state != $1.state { return $0.state < $1.state }
            return $0.localPort < $1.localPort
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.localAddress.lowercased().contains(q)
                || $0.peerAddress.lowercased().contains(q)
                || "\($0.localPort)".contains(q)
                || ($0.peerPort > 0 && "\($0.peerPort)".contains(q))
                || $0.process.lowercased().contains(q)
                || $0.state.lowercased().contains(q)
                || $0.proto.contains(q)
        }
    }

    private func load() async {
        loading = true
        loadFailed = false
        let result = await monitor.fetchConnections()
        connections = result
        loadFailed = (result == nil)
        loading = false
    }
}
