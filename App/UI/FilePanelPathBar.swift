import SwiftUI
import HarborKit

// MARK: - Remote path bar

/// Path text field + history menu used in the remote file pane header.
struct RemotePathBar: View {
    @ObservedObject var service: FileService
    @Binding var pathText: String
    let isReady: Bool

    var body: some View {
        HStack(spacing: 2) {
            pathField
            pathHistoryButton
        }
    }

    private var pathField: some View {
        TextField(L("路径"), text: $pathText)
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.system(size: 11.5, design: .monospaced))
            .onSubmit { service.navigate(toUserPath: pathText) }
            .disabled(!isReady)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.small)
                    .fill(DS.Colors.fieldBackground)
            )
            .frame(maxWidth: .infinity)
            .help(L("当前目录；输入路径后回车跳转，支持 ~ 开头"))
    }

    /// Recent 20 remote paths, newest first.
    private var pathHistoryButton: some View {
        Menu {
            let recents = service.recentPaths(20)
            if recents.isEmpty {
                Text("暂无历史路径")
            } else {
                ForEach(Array(recents.enumerated()), id: \.offset) { _, path in
                    Button(path) { service.navigate(toPath: path) }
                }
            }
        } label: {
            Image(systemName: "clock")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isReady)
        .help(L("历史路径"))
    }
}
