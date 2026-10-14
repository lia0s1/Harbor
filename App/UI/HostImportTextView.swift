import SwiftUI
import HarborKit

/// Bulk host import sheet: paste one `[user@]host[:port] [可选名称]` per line,
/// review the per-line preview (parse errors, duplicates against the store or
/// within the batch), then import the valid ones. Parsing is pure
/// (HostBulkImportParser); the hard line cap lives there too.
struct HostImportTextView: View {
    @EnvironmentObject private var hostStore: HostStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var result = HostBulkImportParser.Result(lines: [], overflowLines: 0)
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(L("从文本导入主机"))
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(L("每行一台主机：[user@]主机[:端口] [可选名称]。空行和 # 开头的行会被忽略，最多解析 %lld 行。", HostBulkImportParser.maxLines))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color.primary.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 1))
                .frame(minHeight: 110, maxHeight: 150)
                .focused($editorFocused)
                .padding(.top, 10)
                .onChange(of: text) { _, _ in reparse() }

            if result.overflowLines > 0 {
                Label(L("已超出 %lld 行上限，多余 %lld 行不参与导入。", HostBulkImportParser.maxLines, result.overflowLines),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }

            preview
                .padding(.top, 10)

            footer
                .padding(.top, 12)
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 600, minHeight: 540)
        .onAppear {
            reparse()
            editorFocused = true
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var preview: some View {
        if result.lines.isEmpty {
            ContentUnavailableView {
                Label(L("暂无内容"), systemImage: "text.cursor")
            } description: {
                Text(L("在上方粘贴主机列表，这里会逐行显示解析结果。"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(result.lines) {
                TableColumn(L("行")) { line in
                    Text(verbatim: "\(line.lineNumber)")
                        .foregroundStyle(.secondary)
                }
                .width(40)
                TableColumn(L("目标")) { line in
                    Text(targetText(for: line))
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TableColumn(L("名称")) { line in
                    Text(line.host?.name ?? "")
                        .lineLimit(1)
                }
                .width(90)
                TableColumn(L("状态")) { line in
                    statusLabel(for: line.status)
                }
                .width(150)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func targetText(for line: HostBulkImportParser.Line) -> String {
        if let host = line.host {
            let user = host.username.isEmpty ? "" : "\(host.username)@"
            let port = host.port == SSHHost.defaultPort ? "" : ":\(host.port)"
            return "\(user)\(host.hostname)\(port)"
        }
        // Unparseable lines: show the raw text (trimmed) so the user can find it.
        return line.raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func statusLabel(for status: HostBulkImportParser.Status) -> some View {
        switch status {
        case .ok:
            Label(L("可导入"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .skipped:
            Text(L("跳过"))
                .foregroundStyle(.tertiary)
        case .duplicateExisting:
            Label(L("与现有主机重复"), systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        case .duplicateBatch:
            Label(L("与上方行重复"), systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        case .invalid(let failure):
            Label(failureText(failure), systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(failureText(failure))
        }
    }

    private func failureText(_ failure: HostBulkImportParser.Failure) -> String {
        switch failure {
        case .invalidHost(let value): return L("主机名无效：%@", value)
        case .invalidUser(let value): return L("用户名无效：%@", value)
        case .invalidPort(let value): return L("端口无效：%@", value)
        case .nameTooLong: return L("名称过长（最多 %lld 字）", HostBulkImportParser.maxNameLength)
        case .invalidName: return L("名称包含非法字符")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            GlassEffectContainer(spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Button(L("取消"), role: .cancel) { dismiss() }
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                    Button(L("导入 %lld 台主机", result.okCount)) { importValid() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(result.okCount == 0)
                }
            }
        }
    }

    private var summaryText: String {
        L("可导入 %lld · 重复 %lld · 错误 %lld",
          result.okCount, result.duplicateCount, result.invalidCount)
    }

    // MARK: - Actions

    private func reparse() {
        result = HostBulkImportParser.parse(text, existing: hostStore.hosts)
    }

    private func importValid() {
        hostStore.append(contentsOf: result.acceptedHosts)
        dismiss()
    }
}
