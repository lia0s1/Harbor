import SwiftUI
import HarborKit

// MARK: - Memory

struct MemoryDetailView: View {
    @ObservedObject var monitor: MonitorService

    var body: some View {
        if let snap = monitor.snapshot {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                DetailSection(L("物理内存")) { memorySection(snap) }
                DetailSection(L("交换空间")) { swapSection(snap) }
            }
        } else {
            Text(L("暂无数据")).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func memorySection(_ snap: SystemSnapshot) -> some View {
        // app-used = total − free − buffers − cached (the "really used" slice).
        let reclaimable = snap.memBuffersKB + snap.memCachedKB
        let appUsed = snap.memTotalKB > snap.memFreeKB + reclaimable
            ? snap.memTotalKB - snap.memFreeKB - reclaimable : 0
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            SegmentedBar(segments: [
                .init(value: Double(appUsed), color: usageTint(snap.memUsedFraction * 100), label: L("已用")),
                .init(value: Double(snap.memBuffersKB), color: .teal, label: L("缓冲")),
                .init(value: Double(snap.memCachedKB), color: .blue.opacity(0.55), label: L("缓存")),
                .init(value: Double(snap.memFreeKB), color: DS.Colors.barTrack, label: L("空闲内存")),
            ])
            DetailStatRow(L("总计"), MonitorFormat.sizeShort(kb: snap.memTotalKB))
            DetailStatRow(L("已用"), MonitorFormat.sizeShort(kb: appUsed), swatch: usageTint(snap.memUsedFraction * 100))
            DetailStatRow(L("可用"), MonitorFormat.sizeShort(kb: snap.memAvailableKB))
            DetailStatRow(L("缓冲"), MonitorFormat.sizeShort(kb: snap.memBuffersKB), swatch: .teal)
            DetailStatRow(L("缓存"), MonitorFormat.sizeShort(kb: snap.memCachedKB), swatch: .blue.opacity(0.55))
            DetailStatRow(L("空闲内存"), MonitorFormat.sizeShort(kb: snap.memFreeKB))
        }
    }

    @ViewBuilder
    private func swapSection(_ snap: SystemSnapshot) -> some View {
        if snap.swapTotalKB == 0 {
            Text(L("未启用交换空间。")).font(.caption).foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                UsageBar(fraction: snap.swapUsedFraction, tint: usageTint(snap.swapUsedFraction * 100))
                DetailStatRow(L("总计"), MonitorFormat.sizeShort(kb: snap.swapTotalKB))
                DetailStatRow(L("已用"), MonitorFormat.sizeShort(kb: snap.swapUsedKB))
                DetailStatRow(L("可用"), MonitorFormat.sizeShort(kb: snap.swapFreeKB))
            }
        }
    }
}
