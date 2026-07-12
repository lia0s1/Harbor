import SwiftUI
import HarborKit

/// Sends one command to multiple running sessions at once (⌘⇧B).
/// Presented as a sheet. Only lists sessions that are currently .running.
struct BatchExecView: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss

    @State private var command = ""
    @State private var selectedIDs: Set<UUID> = []
    @State private var pendingRisk: CommandRisk?
    @FocusState private var commandFocused: Bool

    private var runningSessions: [TerminalSession] {
        sessionManager.sessions.filter { $0.state == .running }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(Color.accentColor)
                Text("批量执行")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Session selector
            VStack(alignment: .leading, spacing: 6) {
                Text("选择目标会话：")
                    .font(.subheadline.weight(.medium))
                if runningSessions.isEmpty {
                    Text("没有正在运行的会话")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
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
            }
            .padding()

            Divider()

            // Command input
            VStack(alignment: .leading, spacing: 6) {
                Text("命令：")
                    .font(.subheadline.weight(.medium))
                TextEditor(text: $command)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    .focused($commandFocused)
                Text("命令将追加换行符后发送到每个选中终端的 PTY，与在命令行中手动输入等效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            // Action bar
            HStack {
                Button("全选") {
                    selectedIDs = Set(runningSessions.map(\.id))
                }
                .disabled(runningSessions.isEmpty)
                Spacer()
                let canSend = !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !selectedIDs.isEmpty
                Button("执行") {
                    execute()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
            }
            .padding()
        }
        .frame(width: 480)
        .onAppear {
            selectedIDs = Set(runningSessions.map(\.id))
            commandFocused = true
        }
        .alert("确认批量执行高风险命令", isPresented: pendingRiskPresented) {
            Button("仍然执行", role: .destructive) {
                executeNow()
                pendingRisk = nil
            }
            Button("取消", role: .cancel) { pendingRisk = nil }
        } message: {
            Text("\(pendingRisk?.summary ?? "")\n\n此命令将发送到 \(selectedIDs.count) 个会话：\n\(command)")
        }
    }

    private func execute() {
        if let risk = CommandRiskDetector.detect(in: command) {
            pendingRisk = risk
            return
        }
        executeNow()
    }

    private func executeNow() {
        let payload = command.hasSuffix("\n") ? command : command + "\n"
        for session in runningSessions where selectedIDs.contains(session.id) {
            session.sendText(payload)
        }
        dismiss()
    }

    private var pendingRiskPresented: Binding<Bool> {
        Binding(get: { pendingRisk != nil }, set: { if !$0 { pendingRisk = nil } })
    }
}
