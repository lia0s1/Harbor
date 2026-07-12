import SwiftUI
import HarborKit

// MARK: - Transfers popover content

/// The full contents of the transfers popover shown from `DualPaneFileView`.
struct TransfersPopoverView: View {
    @ObservedObject var service: FileService

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Text(L("传输"))
                    .font(.caption.weight(.semibold))
                Spacer()
                Button(L("清除已完成")) { service.clearFinishedTransfers() }
                    .controlSize(.mini)
                    .disabled(!service.hasFinishedTransfers)
            }
            if service.transfers.isEmpty {
                Text(L("暂无传输任务。双击文件即可下载到「下载」文件夹。"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.s - 2) {
                        ForEach(service.transfers.reversed()) { transfer in
                            TransferRowView(transfer: transfer, service: service)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(DS.Space.m)
        .frame(width: 300)
    }
}

// MARK: - Single transfer row

struct TransferRowView: View {
    let transfer: FileService.Transfer
    @ObservedObject var service: FileService

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                switch transfer.state {
                case .running:
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DS.Colors.statusRunning)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.Colors.statusError)
                }
            }
            .font(.system(size: 11))
            .frame(width: 14)

            Image(systemName: transfer.direction == .download ? "arrow.down" : "arrow.up")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(
                    transfer.direction == .download ? DS.Colors.netDownload : DS.Colors.netUpload
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(transfer.filename)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(transfer.filename)
                    if transfer.packaged {
                        Text(L("压缩"))
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 0.5)
                            .background(Capsule().fill(DS.Colors.barTrack))
                    }
                }
                switch transfer.state {
                case .running:
                    Text(TransferRowView.progressText(transfer))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if transfer.total > 0, transfer.transferred > 0 {
                        ProgressView(
                            value: min(Double(transfer.transferred), Double(transfer.total)),
                            total: Double(transfer.total)
                        )
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                    }
                case .done:
                    if transfer.total > 0 {
                        Text(MonitorFormat.sizeShort(bytes: Double(transfer.total)))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                case .failed(let reason):
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(DS.Colors.statusError)
                        .lineLimit(2)
                        .help(reason)
                }
            }
            Spacer(minLength: 0)
            if transfer.isRetryable {
                Button {
                    service.retryTransfer(transfer.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("重试"))
            }
        }
    }

    /// "1.2 MB/s · 3.4M/20M" while a download reports speed, else a plain label.
    @MainActor
    static func progressText(_ transfer: FileService.Transfer) -> String {
        guard transfer.bytesPerSecond > 0 else {
            return transfer.direction == .download ? L("下载中…") : L("上传中…")
        }
        let speed = MonitorFormat.speed(bytesPerSecond: transfer.bytesPerSecond)
        guard transfer.total > 0 else { return speed }
        let done = MonitorFormat.sizeShort(bytes: Double(transfer.transferred))
        let total = MonitorFormat.sizeShort(bytes: Double(transfer.total))
        return "\(speed) · \(done)/\(total)"
    }
}
