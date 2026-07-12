import SwiftUI

/// Review step for folder synchronization. It intentionally has no delete
/// controls: remote-only files are displayed as retained, never as removals.
struct DirectorySyncPreviewSheet: View {
    let preview: DirectorySyncPreview
    let onApply: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var uploadCount: Int { preview.uploadURLs.count }
    private var remoteOnlyCount: Int {
        preview.changes.filter { $0.kind == .remoteOnly }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(L("同步预览"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 3) {
                Text(L("本地：%@", preview.localDirectory.path))
                Text(L("远程：%@", preview.remoteDirectory))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)

            if preview.changes.isEmpty {
                ContentUnavailableView(
                    L("目录已同步"),
                    systemImage: "checkmark.circle",
                    description: Text(L("名称、大小和修改时间均一致。"))
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                List(preview.changes) { change in
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: icon(for: change.kind))
                            .foregroundStyle(color(for: change.kind))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(detail(for: change))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: DS.Space.s)
                        Text(label(for: change.kind))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(color(for: change.kind))
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
                .frame(minHeight: 180, maxHeight: 340)
            }

            Text(L("确认后仅上传本地新增或差异文件；仅远程文件会保留，不会删除。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(L("取消"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("上传 %lld 项", uploadCount)) {
                    onApply()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(uploadCount == 0)
            }
        }
        .padding(DS.Space.l)
        .frame(width: 620)
    }

    private var summary: String {
        let changed = preview.changes.filter { $0.kind == .modified }.count
        let added = preview.changes.filter { $0.kind == .localOnly }.count
        return L("本地新增 %lld 项，差异 %lld 项，仅远程 %lld 项", added, changed, remoteOnlyCount)
    }

    private func label(for kind: DirectorySyncChange.Kind) -> String {
        switch kind {
        case .localOnly: return L("本地新增")
        case .modified: return L("有差异")
        case .remoteOnly: return L("仅远程")
        }
    }

    private func icon(for kind: DirectorySyncChange.Kind) -> String {
        switch kind {
        case .localOnly: return "arrow.up.circle"
        case .modified: return "arrow.triangle.2.circlepath"
        case .remoteOnly: return "arrow.down.circle"
        }
    }

    private func color(for kind: DirectorySyncChange.Kind) -> Color {
        switch kind {
        case .localOnly: return .accentColor
        case .modified: return .orange
        case .remoteOnly: return .secondary
        }
    }

    private func detail(for change: DirectorySyncChange) -> String {
        switch change.kind {
        case .localOnly:
            return metadata(size: change.localSize, date: change.localMtime)
        case .remoteOnly:
            return metadata(
                size: change.remoteSize,
                date: change.remoteMtimeEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        case .modified:
            return L(
                "本地 %@  ·  远程 %@",
                metadata(size: change.localSize, date: change.localMtime),
                metadata(
                    size: change.remoteSize,
                    date: change.remoteMtimeEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                )
            )
        }
    }

    private func metadata(size: UInt64?, date: Date?) -> String {
        let sizeText = size.map { DualPaneFileView.sizeText($0, isDirectory: false) } ?? "—"
        let dateText = date.map(DualPaneFileView.dateText) ?? "—"
        return "\(sizeText) · \(dateText)"
    }
}
