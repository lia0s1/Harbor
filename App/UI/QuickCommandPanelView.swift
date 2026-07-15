import SwiftUI
import AppKit
import HarborKit

// MARK: - Bottom-panel tab selection

/// Which tab the shared bottom drawer shows: 文件 (file browser) or 命令 (the
/// quick-command library). Persisted so the choice sticks across launches.
enum BottomPanelTab: String, CaseIterable {
    case files
    case commands
    case docker

    static let storageKey = "bottomPanelTab"
    static let defaultValue = BottomPanelTab.files
}

// MARK: - Bottom panel container

/// The single bottom drawer under the terminal + command strip. Owns the drawer
/// chrome — persisted height, the top resize splitter, the standard-appearance
/// background and the 文件 | 命令 segmented tab bar — and shows the file browser
/// or the quick-command library inside it (FinalShell's bottom tabs).
///
/// Standard chrome (follows the app appearance), unlike the theme-tinted strips
/// above it. No live Liquid Glass here: nothing in this drawer updates at high
/// frequency, and the file table / command rows use cheap flat surfaces.
struct BottomPanelView: View {
    let session: TerminalSession
    @ObservedObject var fileService: FileService
    @ObservedObject var commandStore: QuickCommandStore
    /// Sends one command line to the selected session's terminal (text + "\n").
    let send: (String) -> Void
    var dockerService: DockerService?

    @AppStorage(FilePanelPreference.heightKey)
    private var panelHeight = FilePanelPreference.defaultHeight
    @AppStorage(BottomPanelTab.storageKey)
    private var tabRaw = BottomPanelTab.defaultValue.rawValue

    @State private var dragBaseHeight: Double?

    private var tab: BottomPanelTab {
        get { BottomPanelTab(rawValue: tabRaw) ?? .files }
        nonmutating set { tabRaw = newValue.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(DS.Colors.separator)
                .frame(height: 1)
            tabBar
            Divider()
            content
        }
        .frame(maxWidth: .infinity)
        .frame(height: FilePanelPreference.clampHeight(panelHeight))
        .background(DS.Colors.chromeBackground)
        .overlay(alignment: .top) { resizeHotZone }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .files:
            DualPaneFileView(session: session, service: fileService)
        case .commands:
            QuickCommandPanelView(session: session, store: commandStore, send: send)
        case .docker:
            if let docker = dockerService {
                DockerPanelView(service: docker)
            } else {
                ContentUnavailableView("Docker 面板", systemImage: "shippingbox", description: Text("请先建立 SSH 连接"))
            }
        }
    }

    // MARK: Tab bar (文件 | 命令)

    private var tabBar: some View {
        HStack(spacing: DS.Space.xs) {
            tabButton(.files, title: L("文件"), symbol: "folder")
            tabButton(.commands, title: L("命令"), symbol: "terminal")
            tabButton(.docker, title: L("Docker"), symbol: "shippingbox")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, 4)
    }

    private func tabButton(_ value: BottomPanelTab, title: String, symbol: String) -> some View {
        let isOn = tab == value
        return Button {
            tab = value
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: isOn ? .semibold : .regular))
            }
            .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .padding(.horizontal, DS.Space.s + 2)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.small + 1, style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(0.14) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.small + 1))
        }
        .buttonStyle(.plain)
        .help(value == .files ? L("文件面板") : value == .commands ? L("命令面板") : L("Docker 面板"))
    }

    // MARK: Resize splitter

    /// Thin hot zone along the top edge: drag to resize, persisted height
    /// (shared by both tabs).
    private var resizeHotZone: some View {
        Color.clear
            .frame(height: 6)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = dragBaseHeight ?? panelHeight
                        if dragBaseHeight == nil { dragBaseHeight = panelHeight }
                        panelHeight = FilePanelPreference.clampHeight(base - value.translation.height)
                    }
                    .onEnded { _ in dragBaseHeight = nil }
            )
            .help(L("拖动调整面板高度"))
    }
}

// MARK: - Quick-command panel

/// FinalShell's bottom 命令 tab: a library of saved one-click commands. Each
/// row is clickable to send to the selected session's terminal (reusing the
/// command-strip send path). Commands with `{placeholder}` parameters open a
/// small prompt sheet first. Add / Edit / Delete / Duplicate via the editor.
///
/// Standard chrome, appearance-correct, no live Liquid Glass (cheap flat rows).
struct QuickCommandPanelView: View {
    let session: TerminalSession
    @ObservedObject var store: QuickCommandStore
    let send: (String) -> Void

    @State private var editorTarget: QuickCommandEditor.Target?
    @State private var paramPrompt: ParamPrompt?
    @State private var deleteTarget: QuickCommand?
    @State private var sessionState: TerminalSession.State = .connecting
    @State private var pendingRisk: CommandRisk?
    @State private var pendingCommand = ""

    private var canSend: Bool { sessionState == .running }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if store.commands.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .sheet(item: $editorTarget) { target in
            QuickCommandEditor(target: target, store: store)
        }
        .sheet(item: $paramPrompt) { prompt in
            QuickCommandParameterSheet(prompt: prompt) { finalCommand in
                paramPrompt = nil
                sendWithConfirmation(finalCommand)
            }
        }
        .alert(
            deleteTarget.map { L("删除 \u{201C}%@\u{201D}？", L($0.displayTitle)) } ?? L("删除命令？"),
            isPresented: deletePresented
        ) {
            Button(L("删除"), role: .destructive) {
                if let target = deleteTarget { store.delete(target) }
                deleteTarget = nil
            }
            Button(L("取消"), role: .cancel) { deleteTarget = nil }
        } message: {
            Text(verbatim: L("此操作无法撤销。"))
        }
        .onAppear { sessionState = session.state }
        .onReceive(session.$state) { sessionState = $0 }
        .alert(L("确认发送高风险命令"), isPresented: pendingRiskPresented) {
            Button(L("仍然发送"), role: .destructive) {
                send(pendingCommand)
                pendingRisk = nil
                pendingCommand = ""
            }
            Button(L("取消"), role: .cancel) {
                pendingRisk = nil
                pendingCommand = ""
            }
        } message: {
            Text("\(pendingRisk?.summary ?? "")\n\n\(pendingCommand)")
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: DS.Space.xs) {
            if !canSend {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(L("会话未运行，点击命令暂不可发送"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(L("点击命令发送到当前会话"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: DS.Space.s)
            GlassIconButton("text.badge.plus", help: L("添加常用命令")) {
                addPresetCommands()
            }
            GlassIconButton("plus", help: L("新建命令…")) {
                editorTarget = .new
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, 5)
    }

    /// Inserts the built-in common commands the user doesn't already have
    /// (deduped by command text), so an existing library can pick up new presets.
    private func addPresetCommands() {
        let existing = Set(store.commands.map { $0.command.trimmingCharacters(in: .whitespacesAndNewlines) })
        for preset in QuickCommandStoreCodec.starterCommands()
        where !existing.contains(preset.command.trimmingCharacters(in: .whitespacesAndNewlines)) {
            store.upsert(preset)
        }
    }

    // MARK: List (grouped by folder)

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.s) {
                ForEach(store.groups, id: \.self) { group in
                    let items = store.commands.filter { $0.group.trimmingCharacters(in: .whitespacesAndNewlines) == group }
                    if !items.isEmpty {
                        if !group.isEmpty {
                            Text(L(group))
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, DS.Space.m)
                                .padding(.top, 2)
                        }
                        ForEach(items) { command in
                            QuickCommandRow(
                                command: command,
                                disabled: !canSend,
                                onSend: { run(command) },
                                onEdit: { editorTarget = .edit(command) },
                                onDuplicate: { store.duplicate(command) },
                                onDelete: { deleteTarget = command }
                            )
                            .padding(.horizontal, DS.Space.s)
                        }
                    }
                }
            }
            .padding(.vertical, DS.Space.s)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: "terminal")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L("还没有保存的命令"))
                .font(.callout.weight(.medium))
            Text(L("把常用命令存成一键命令，点击即可发送到终端。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                editorTarget = .new
            } label: {
                Label(L("新建命令…"), systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.horizontal, DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Behavior

    /// Click a row: parameterized commands open a prompt sheet first; plain
    /// commands send immediately. No-op when the session is not running.
    private func run(_ command: QuickCommand) {
        guard canSend else { return }
        if command.hasParameters {
            paramPrompt = ParamPrompt(command: command)
        } else {
            sendWithConfirmation(command.command)
        }
    }

    private func sendWithConfirmation(_ command: String) {
        guard canSend else { return }
        if let risk = CommandRiskDetector.detect(in: command) {
            pendingRisk = risk
            pendingCommand = command
            return
        }
        send(command)
    }

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    private var pendingRiskPresented: Binding<Bool> {
        Binding(get: { pendingRisk != nil }, set: { if !$0 { pendingRisk = nil } })
    }
}

// MARK: - Row

/// One command in the list: title + monospace preview, a primary send affordance
/// on the whole row, and a hover-revealed ••• menu (edit / duplicate / delete).
private struct QuickCommandRow: View {
    let command: QuickCommand
    let disabled: Bool
    let onSend: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onSend) {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(L(command.displayTitle))
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if command.hasParameters {
                                Text(L("参数"))
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                            }
                        }
                        if command.displayTitle != command.command {
                            Text(command.command)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: DS.Space.s + 32)
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(CommandRowButtonStyle(isHovering: isHovering, disabled: disabled))
            .disabled(disabled)

            Menu {
                Button(L("编辑…"), action: onEdit)
                Button(L("复制"), action: onDuplicate)
                Divider()
                Button(L("删除"), role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.trailing, DS.Space.s)
            .opacity(isHovering ? 1 : 0.35)
        }
        .onHover { isHovering = $0 }
        .help(disabled ? L("会话未运行") : L("点击发送：%@", command.command))
    }
}

private struct CommandRowButtonStyle: ButtonStyle {
    let isHovering: Bool
    let disabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.small + 1, style: .continuous)
                    .fill(configuration.isPressed && !disabled ? DS.Colors.rowBackground.opacity(0.6)
                          : isHovering && !disabled ? DS.Colors.rowBackground : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.small + 1))
            .scaleEffect(configuration.isPressed && !disabled ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Parameter prompt

/// Identifiable holder for a parameterized command awaiting its values.
struct ParamPrompt: Identifiable {
    let id = UUID()
    let command: QuickCommand
}

/// A small sheet with one field per `{placeholder}`. On 发送, substitutes the
/// values into the template and hands the final command back to the caller.
private struct QuickCommandParameterSheet: View {
    let prompt: ParamPrompt
    let onSend: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    private var parameters: [String] { prompt.command.parameters }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(L("填写参数"))
                .font(.headline)
            Text(L(prompt.command.displayTitle))
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                ForEach(parameters, id: \.self) { name in
                    TextField(name, text: binding(for: name))
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.columns)

            // Live preview of the resolved command.
            Text(prompt.command.substitute(values))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.s)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.small)
                        .fill(DS.Colors.fieldBackground)
                )

            HStack {
                Spacer()
                Button(L("取消"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("发送")) {
                    onSend(prompt.command.substitute(values))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(DS.Space.l)
        .frame(width: 360)
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(
            get: { values[name] ?? "" },
            set: { values[name] = $0 }
        )
    }
}

// MARK: - Editor sheet

/// Add / Edit a quick command: title, command template, optional folder.
/// Shows the detected `{placeholder}` parameters live so the user understands
/// what they will be prompted for.
struct QuickCommandEditor: View {
    enum Target: Identifiable {
        case new
        case edit(QuickCommand)

        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let command): return command.id.uuidString
            }
        }
    }

    let target: Target
    @ObservedObject var store: QuickCommandStore

    @Environment(\.dismiss) private var dismiss
    @State private var draft: QuickCommand

    init(target: Target, store: QuickCommandStore) {
        self.target = target
        self.store = store
        switch target {
        case .new:
            _draft = State(initialValue: QuickCommand())
        case .edit(let command):
            _draft = State(initialValue: command)
        }
    }

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private var canSave: Bool {
        !draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(isEditing ? L("编辑命令") : L("新建命令"))
                .font(.headline)

            Form {
                TextField(L("标题"), text: $draft.title, prompt: Text(L("可选，留空则显示命令本身")))
                TextField(L("命令"), text: $draft.command, prompt: Text(L("例如：systemctl restart {service}")))
                    .font(.system(size: 12, design: .monospaced))
                TextField(L("分组"), text: $draft.group, prompt: Text(L("可选，用于分类")))
            }
            .formStyle(.columns)

            if draft.hasParameters {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(L("发送时将提示输入：%@", draft.parameters.joined(separator: "、")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(L("提示：在命令中写 {名称} 可在发送时提示输入参数。"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(L("取消"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("保存")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(DS.Space.l)
        .frame(width: 400)
    }

    private func save() {
        guard canSave else { return }
        var command = draft
        command.title = command.title.trimmingCharacters(in: .whitespacesAndNewlines)
        command.command = command.command.trimmingCharacters(in: .whitespacesAndNewlines)
        command.group = command.group.trimmingCharacters(in: .whitespacesAndNewlines)
        store.upsert(command)
        dismiss()
    }
}
