import SwiftUI
import HarborKit

// MARK: - File toolbar button

/// Uniform flat icon button for the file panel toolbar: fixed 30×26, clear
/// hover/active states and good contrast on the standard (non-themed) file
/// chrome — so the row reads as one tidy, consistent cluster instead of the old
/// mixed-size, low-contrast glass chips.
struct FileToolButton: View {
    let systemName: String
    let help: String
    var isOn: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    @State private var hovering = false

    init(_ systemName: String, help: String, isOn: Bool = false,
         disabled: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.isOn = isOn
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var tint: AnyShapeStyle {
        if disabled { return AnyShapeStyle(.tertiary) }
        if isOn { return AnyShapeStyle(SwiftUI.Color.accentColor) }
        return AnyShapeStyle(.secondary)
    }

    private var fill: SwiftUI.Color {
        if isOn { return SwiftUI.Color.accentColor.opacity(0.15) }
        if hovering && !disabled { return SwiftUI.Color.primary.opacity(0.08) }
        return .clear
    }
}

// MARK: - Remote file pane header toolbar

/// The header toolbar row for `RemoteFilePane`: nav cluster, path bar, and
/// transfer action buttons. Collapses to a two-row layout when space is tight.
struct RemoteFilePaneHeader: View {
    @ObservedObject var service: FileService
    @Binding var pathText: String
    @Binding var showHidden: Bool
    @Binding var treeVisible: Bool
    let isReady: Bool
    let selectedCount: Int
    let selectedEntries: [RemoteFileEntry]
    let onUpload: () -> Void
    let onDownload: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.xs) {
                Text(L("远程"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                navCluster
                RemotePathBar(service: service, pathText: $pathText, isReady: isReady)
                    .frame(minWidth: 100)
                refreshControl
                showHiddenButton
                Divider().frame(height: 14)
                transferButtons
            }
            VStack(spacing: 5) {
                HStack(spacing: DS.Space.xs) {
                    Text(L("远程"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    navCluster
                    refreshControl
                    showHiddenButton
                    Divider().frame(height: 14)
                    transferButtons
                    Spacer(minLength: 0)
                }
                RemotePathBar(service: service, pathText: $pathText, isReady: isReady)
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, 5)
    }

    private var navCluster: some View {
        HStack(spacing: 2) {
            FileToolButton("sidebar.left", help: treeVisible ? L("隐藏目录树") : L("显示目录树"),
                           isOn: treeVisible) { treeVisible.toggle() }
            FileToolButton("chevron.left", help: L("后退"),
                           disabled: !isReady || !service.canGoBack) { service.goBack() }
            FileToolButton("chevron.right", help: L("前进"),
                           disabled: !isReady || !service.canGoForward) { service.goForward() }
            FileToolButton("arrow.up", help: L("上级目录"),
                           disabled: !isReady || service.cwd == "/") { service.goUp() }
        }
    }

    @ViewBuilder
    private var refreshControl: some View {
        if service.isLoading || service.isMutating {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 30, height: 26)
        } else {
            FileToolButton("arrow.clockwise", help: L("刷新"), disabled: !isReady) {
                service.refresh()
            }
        }
    }

    private var showHiddenButton: some View {
        FileToolButton(showHidden ? "eye" : "eye.slash",
                       help: showHidden ? L("显示隐藏文件：开") : L("显示隐藏文件：关"),
                       isOn: showHidden) { showHidden.toggle() }
    }

    /// Transfer buttons for the remote pane.
    private var transferButtons: some View {
        HStack(spacing: 2) {
            FileToolButton("square.and.arrow.up", help: L("上传文件到当前目录…"),
                           disabled: !isReady) { onUpload() }
            FileToolButton(
                "square.and.arrow.down",
                help: selectedCount == 0 ? L("下载（先选择文件）") : L("下载所选 %lld 项到「下载」", selectedCount),
                disabled: !isReady || selectedCount == 0
            ) { onDownload() }
        }
    }
}
