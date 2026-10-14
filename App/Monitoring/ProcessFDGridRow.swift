import SwiftUI
import HarborKit

/// On-demand fd/socket count for one process, rendered as a GridRow so it
/// drops straight into the process inspector's info Grid (the row aligns with
/// the existing label/value pairs). Fetched once on appear — never on the
/// 2s loop. "—" when the process is gone or /proc/<pid>/fd is unreadable.
struct ProcessFDGridRow: View {
    @ObservedObject var monitor: MonitorService
    let pid: Int
    @State private var counts: ProcessFDCount?
    @State private var loaded = false

    var body: some View {
        GridRow {
            Text(L("文件描述符")).foregroundStyle(.secondary)
            Text(valueText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await load() }
        // A different process under the same view identity must refetch.
        .onChange(of: pid) { _, _ in Task { await load() } }
    }

    private var valueText: String {
        guard loaded else { return "…" }
        guard let counts else { return "—" }
        return L("%lld 个（含 socket %lld 个）", counts.total, counts.socketCount)
    }

    private func load() async {
        loaded = false
        counts = await monitor.fetchProcessFDs(pid: Int32(pid))
        loaded = true
    }
}
