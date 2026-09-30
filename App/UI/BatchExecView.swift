import SwiftUI
import HarborKit

/// Sends one command to multiple running sessions at once (⌘⇧B).
/// Presented as a sheet. Only lists sessions that are currently .running.
/// Remembers the last selection, and after executing keeps the sheet open
/// with a per-host result summary until the user presses 完成.
struct BatchExecView: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss

    /// Persisted selection (comma-separated UUIDs) so the next run preselects
    /// the same hosts; filtered against currently-running sessions on appear.
    @AppStorage("batchExecLastSelection") private var lastSelectionRaw = ""

    @State private var command = ""
    @State private var selectedIDs: Set<UUID> = []
    @State private var results: [SendResult]?
    @State private var pendingRisk: CommandRisk?
    @FocusState private var commandFocused: Bool

    private struct SendResult: Identifiable {
        let sessionID: UUID
        let title: String
        let success: Bool
        var id: UUID { sessionID }
    }

    private var runningSessions: [TerminalSession] {
        sessionManager.sessions.filter { $0.state == .running }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(Color.accentColor)
                Text(L("批量执行"))
                    .font(.headline)
                Spacer()
                Button(L("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Session selector
            VStack(alignment: .leading, spacing: 6) {
                Text(L("选择目标会话："))
                    .font(.subheadline.weight(.medium))
                if runningSessions.isEmpty {
                    Text(L("没有正在运行的会话"))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(runningSessions) { session in
                                Toggle(isOn: Binding(
                                    get: { selectedIDs.contains(session.id) },
                                    set: { if $0 { selectedIDs.insert(session.id) } else { selectedIDs.remove(session.id) } }
                                )) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "server.rack")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(session.title)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
            }
            .padding()

            Divider()

            if let results {
                // Result summary — the sheet stays open until 完成.
                VStack(alignment: .leading, spacing: 6) {
                    let failed = results.filter { !$0.success }
                    Text(failed.isEmpty
                        ? L("已发送到 %lld 个会话。", results.count)
                        : L("已发送到 %lld 个会话，其中 %lld 个失败。", results.count, failed.count))
                        .font(.subheadline.weight(.medium))
                    if !failed.isEmpty {
                        ForEach(failed) { result in
                            Label(result.title, systemImage: "xmark.circle")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }
                    }
                    Text(L("命令已追加换行符发送到每个选中终端的 PTY。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                HStack {
                    Spacer()
                    Button(L("完成")) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                // Command input
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("命令："))
                        .font(.subheadline.weight(.medium))
                    TextEditor(text: $command)
                        .font(.system(.callout, design: .monospaced))
                        .frame(height: 80)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                        .focused($commandFocused)
                    Text(L("命令将追加换行符后发送到每个选中终端的 PTY，与在命令行中手动输入等效。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()

                Divider()

                // Action bar
                HStack {
                    Button(L("全选")) {
                        selectedIDs = Set(runningSessions.map(\.id))
                    }
                    .disabled(runningSessions.isEmpty)
                    Button(L("反选")) {
                        selectedIDs = Set(runningSessions.map(\.id)).subtracting(selectedIDs)
                    }
                    .disabled(runningSessions.isEmpty)
                    Spacer()
                    let canSend = !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !selectedIDs.isEmpty
                    Button(L("执行")) {
                        execute()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
                }
                .padding()
            }
        }
        .frame(width: 480)
        .onAppear {
            let saved = Set(lastSelectionRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
            let available = Set(runningSessions.map(\.id))
            selectedIDs = saved.isEmpty ? available : saved.intersection(available)
            commandFocused = true
        }
        .onChange(of: selectedIDs) { _, ids in
            lastSelectionRaw = ids.map(\.uuidString).sorted().joined(separator: ",")
        }
        .onDisappear {
            command = ""
            results = nil
        }
        .alert(L("确认批量执行高风险命令"), isPresented: pendingRiskPresented) {
            Button(L("仍然执行"), role: .destructive) {
                executeNow()
                pendingRisk = nil
            }
            Button(L("取消"), role: .cancel) { pendingRisk = nil }
        } message: {
            Text("\(pendingRisk?.summary ?? "")\n\n\(L("此命令将发送到 %lld 个会话：", selectedIDs.count))\n\(command)")
        }
    }

    private func execute() {
        if let risk = CommandExecutionCoordinator.confirmationRisk(for: command) {
            pendingRisk = risk
            return
        }
        executeNow()
    }

    private func executeNow() {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !selectedIDs.isEmpty else { return }
        let payload = command.hasSuffix("\n") ? command : command + "\n"
        var out: [SendResult] = []
        for session in runningSessions where selectedIDs.contains(session.id) {
            let success = session.state == .running
            if success { session.sendText(payload) }
            out.append(SendResult(sessionID: session.id, title: session.title, success: success))
        }
        guard !out.isEmpty else { return }
        results = out
        command = ""
    }

    private var pendingRiskPresented: Binding<Bool> {
        Binding(get: { pendingRisk != nil }, set: { if !$0 { pendingRisk = nil } })
    }
}
