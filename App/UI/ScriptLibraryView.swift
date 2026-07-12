import SwiftUI
import AppKit
import HarborKit

// MARK: - Script library

/// The full script/snippet library: a persistent, searchable collection of
/// reusable shell scripts the user organizes into categories and sends to any
/// terminal session. Sidebar of categories on the left, the scripts in the
/// selection on the right; add / edit / duplicate / delete via the editor sheet,
/// and `{{name}}` scripts prompt for their variables before sending.
///
/// Standard chrome (follows the app appearance); no live Liquid Glass — nothing
/// here updates at high frequency, and the rows use cheap flat surfaces.
struct ScriptLibraryView: View {
    @ObservedObject var store: ScriptStore
    /// Sends the (variable-substituted) script to the active terminal session.
    let send: (String) -> Void

    /// Which sidebar bucket is selected.
    private enum CategorySelection: Hashable {
        case all
        case uncategorized
        case named(String)
    }

    /// Pending category name edit driving the shared name alert.
    private enum CategoryNameEdit {
        case new
        case rename(String)
    }

    @State private var selection: CategorySelection = .all
    @State private var searchText = ""
    @State private var editorTarget: ScriptEditorView.Target?
    @State private var varPrompt: VariablePrompt?
    @State private var deleteTarget: ScriptSnippet?
    @State private var categoryEdit: CategoryNameEdit?
    @State private var categoryNameField = ""
    @State private var deleteCategoryTarget: String?
    @State private var pendingRisk: CommandRisk?
    @State private var pendingCommand = ""

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 172, idealWidth: 200, maxWidth: 280)
            detail
                .frame(minWidth: 340, maxWidth: .infinity)
        }
        .frame(minWidth: 640, minHeight: 440)
        .sheet(item: $editorTarget) { target in
            ScriptEditorView(target: target, store: store)
        }
        .sheet(item: $varPrompt) { prompt in
            ScriptVariableSheet(prompt: prompt) {
                varPrompt = nil
                sendWithConfirmation($0)
            }
        }
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

    // MARK: Sidebar (categories)

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.xs) {
                Text(L("脚本库"))
                    .font(.headline)
                Spacer(minLength: DS.Space.s)
                Menu {
                    Button(L("新建脚本…")) { editorTarget = .new(category: selectedCategoryName) }
                    Button(L("新建分组…")) { beginNewCategory() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("新建"))
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)

            Divider()

            List(selection: sidebarSelection) {
                Label(L("全部"), systemImage: "square.stack.3d.up")
                    .badge(store.snippets.count)
                    .tag(CategorySelection.all)

                if store.hasUncategorized {
                    Label(L("未分类"), systemImage: "tray")
                        .badge(store.count(inCategory: ""))
                        .tag(CategorySelection.uncategorized)
                }

                if !store.categories.isEmpty {
                    Section(L("分组")) {
                        ForEach(store.categories, id: \.self) { category in
                            Label(category, systemImage: "folder")
                                .badge(store.count(inCategory: category))
                                .tag(CategorySelection.named(category))
                                .contextMenu {
                                    Button(L("重命名分组…")) { beginRename(category) }
                                    Button(L("删除分组…"), role: .destructive) {
                                        deleteCategoryTarget = category
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .alert(categoryEditTitle, isPresented: categoryEditPresented) {
                TextField(L("分组名称"), text: $categoryNameField)
                Button(L("取消"), role: .cancel) { categoryEdit = nil }
                Button(categoryEditConfirm) { commitCategoryEdit() }
            } message: {
                Text(categoryEditMessage)
            }
        }
        .background(DS.Colors.panelBackground)
        .alert(
            deleteCategoryTarget.map { L("删除分组 “%@”？", $0) } ?? L("删除分组？"),
            isPresented: deleteCategoryPresented
        ) {
            Button(L("删除"), role: .destructive) { confirmDeleteCategory() }
            Button(L("取消"), role: .cancel) { deleteCategoryTarget = nil }
        } message: {
            Text(deleteCategoryTarget.map {
                L("该分组下的 %lld 个脚本也会被删除，此操作无法撤销。", store.count(inCategory: $0))
            } ?? "")
        }
    }

    // MARK: Detail (scripts)

    private var detail: some View {
        VStack(spacing: 0) {
            detailToolbar
            Divider()
            if visibleSnippets.isEmpty {
                emptyState
            } else {
                scriptList
            }
        }
        .background(DS.Colors.chromeBackground)
        .alert(
            deleteTarget.map { L("删除 “%@”？", $0.displayTitle) } ?? L("删除脚本？"),
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
    }

    private var detailToolbar: some View {
        HStack(spacing: DS.Space.s) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField(L("搜索脚本…"), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(DS.Colors.fieldBackground)
            )

            Button {
                editorTarget = .new(category: selectedCategoryName)
            } label: {
                Label(L("新建脚本"), systemImage: "plus")
            }
            .controlSize(.small)
            .help(L("新建脚本"))
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
    }

    private var scriptList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(visibleSnippets) { snippet in
                    ScriptRow(
                        snippet: snippet,
                        showCategory: showsCategoryTag,
                        onSend: { runSend(snippet) },
                        onEdit: { editorTarget = .edit(snippet) },
                        onDuplicate: { store.duplicate(snippet) },
                        onDelete: { deleteTarget = snippet }
                    )
                }
            }
            .padding(DS.Space.s)
        }
    }

    private var emptyState: some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: searchActive ? "magnifyingglass" : "doc.text")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text(searchActive ? L("没有匹配的脚本") : L("还没有脚本"))
                .font(.callout.weight(.medium))
            if !searchActive {
                Text(L("把常用脚本保存到库里，随时发送到任意终端会话。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    editorTarget = .new(category: selectedCategoryName)
                } label: {
                    Label(L("新建脚本…"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Derived state

    private var searchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The scripts to show: a global search when the field is non-empty,
    /// otherwise the selected sidebar bucket.
    private var visibleSnippets: [ScriptSnippet] {
        if searchActive { return store.search(searchText) }
        switch selection {
        case .all: return store.snippets
        case .uncategorized: return store.snippets(inCategory: "")
        case .named(let category): return store.snippets(inCategory: category)
        }
    }

    /// Show the category tag on rows only when the current view mixes categories
    /// (全部 or search results); redundant when a single category is selected.
    private var showsCategoryTag: Bool {
        if searchActive { return true }
        if case .all = selection { return true }
        return false
    }

    /// The category a newly created script should default to: the selected named
    /// category, else empty (uncategorized).
    private var selectedCategoryName: String {
        if case .named(let category) = selection { return category }
        return ""
    }

    // MARK: Actions

    /// Sends a script — prompting for `{{name}}` variables first when present.
    private func runSend(_ snippet: ScriptSnippet) {
        if snippet.hasVariables {
            varPrompt = VariablePrompt(snippet: snippet)
        } else {
            sendWithConfirmation(snippet.content)
        }
    }

    private func sendWithConfirmation(_ command: String) {
        if let risk = CommandRiskDetector.detect(in: command) {
            pendingRisk = risk
            pendingCommand = command
            return
        }
        send(command)
    }

    private func beginNewCategory() {
        categoryNameField = ""
        categoryEdit = .new
    }

    private func beginRename(_ category: String) {
        categoryNameField = category
        categoryEdit = .rename(category)
    }

    private func commitCategoryEdit() {
        let name = categoryNameField.trimmingCharacters(in: .whitespacesAndNewlines)
        let edit = categoryEdit
        categoryEdit = nil
        guard !name.isEmpty, let edit else { return }
        switch edit {
        case .new:
            // A category only exists once a script uses it: open the editor to
            // create the first script in it. Deferred so the alert finishes
            // dismissing before the sheet presents.
            DispatchQueue.main.async { editorTarget = .new(category: name) }
        case .rename(let old):
            store.renameCategory(old, to: name)
            if selection == .named(old) { selection = .named(name) }
        }
    }

    private func confirmDeleteCategory() {
        guard let category = deleteCategoryTarget else { return }
        store.deleteCategory(category)
        if selection == .named(category) { selection = .all }
        deleteCategoryTarget = nil
    }

    // MARK: Bindings

    /// `List` needs an optional selection; snap a deselect back to 全部.
    private var sidebarSelection: Binding<CategorySelection?> {
        Binding(get: { selection }, set: { selection = $0 ?? .all })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private var deleteCategoryPresented: Binding<Bool> {
        Binding(get: { deleteCategoryTarget != nil }, set: { if !$0 { deleteCategoryTarget = nil } })
    }

    private var categoryEditPresented: Binding<Bool> {
        Binding(get: { categoryEdit != nil }, set: { if !$0 { categoryEdit = nil } })
    }

    private var pendingRiskPresented: Binding<Bool> {
        Binding(get: { pendingRisk != nil }, set: { if !$0 { pendingRisk = nil } })
    }

    private var isRenamingCategory: Bool {
        switch categoryEdit {
        case .some(.rename): return true
        default: return false
        }
    }

    private var categoryEditTitle: String {
        isRenamingCategory ? L("重命名分组") : L("新建分组")
    }

    private var categoryEditConfirm: String {
        isRenamingCategory ? L("重命名") : L("下一步")
    }

    private var categoryEditMessage: String {
        isRenamingCategory
            ? L("重命名会更新该分组下的所有脚本。")
            : L("先给分组起个名字，然后新建它的第一个脚本。")
    }
}

// MARK: - Row

/// One script in the list: an icon, its title with optional 变量 / 分组 tags, a
/// short monospace preview of the body, an explicit 发送到终端 button and a
/// hover-revealed ••• menu (edit / duplicate / delete).
private struct ScriptRow: View {
    let snippet: ScriptSnippet
    let showCategory: Bool
    let onSend: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: "curlybraces.square")
                .font(.system(size: 15))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(snippet.displayTitle)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if snippet.hasVariables {
                        TagLabel(L("变量"), systemImage: "curlybraces")
                    }
                    if showCategory, !snippet.category.isEmpty {
                        TagLabel(snippet.category, systemImage: "folder")
                    }
                }
                if !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: DS.Space.s)

            Button(action: onSend) {
                Label(L("发送到终端"), systemImage: "paperplane.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.accentColor)
            .fixedSize()
            .help(L("发送到终端"))

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
            .opacity(isHovering ? 1 : 0.35)
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.s)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.small + 1, style: .continuous)
                .fill(isHovering ? DS.Colors.rowBackground : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.small + 1))
        .onHover { isHovering = $0 }
    }

    /// First up-to-two non-empty lines of the body for a compact preview.
    private var preview: String {
        snippet.content
            .split(whereSeparator: \.isNewline)
            .prefix(2)
            .joined(separator: "\n")
    }
}

/// Small capsule tag used for the 变量 / 分组 markers on a row.
private struct TagLabel: View {
    let text: String
    var systemImage: String?

    init(_ text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 2) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 8, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

// MARK: - Variable prompt

/// Identifiable holder for a `{{name}}` script awaiting its variable values.
struct VariablePrompt: Identifiable {
    let id = UUID()
    let snippet: ScriptSnippet
}

/// A sheet with one field per `{{name}}` variable and a live preview of the
/// resolved script. On 发送到终端 it substitutes the values and hands the final
/// script back to the caller.
private struct ScriptVariableSheet: View {
    let prompt: VariablePrompt
    let onSend: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    private var variables: [String] { prompt.snippet.detectedVariables }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(L("填写变量"))
                .font(.headline)
            Text(prompt.snippet.displayTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Form {
                ForEach(variables, id: \.self) { name in
                    TextField(name, text: binding(for: name))
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.columns)

            VStack(alignment: .leading, spacing: 4) {
                Text(L("预览"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(prompt.snippet.substitute(values))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(DS.Space.s)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.small)
                        .fill(DS.Colors.fieldBackground)
                )
            }

            HStack {
                Spacer()
                Button(L("取消"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("发送到终端")) {
                    onSend(prompt.snippet.substitute(values))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(DS.Space.l)
        .frame(width: 440)
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }
}

// MARK: - Editor sheet

/// Add / edit a script: title, category (free text with a menu of existing
/// categories), and the multi-line monospaced body. The detected `{{name}}`
/// variables are shown live so the user knows what they will be prompted for.
struct ScriptEditorView: View {
    enum Target: Identifiable {
        case new(category: String)
        case edit(ScriptSnippet)

        var id: String {
            switch self {
            case .new(let category): return "new:\(category)"
            case .edit(let snippet): return snippet.id.uuidString
            }
        }
    }

    let target: Target
    @ObservedObject var store: ScriptStore

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ScriptSnippet

    init(target: Target, store: ScriptStore) {
        self.target = target
        self.store = store
        switch target {
        case .new(let category):
            _draft = State(initialValue: ScriptSnippet(category: category))
        case .edit(let snippet):
            _draft = State(initialValue: snippet)
        }
    }

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private var canSave: Bool {
        !draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(isEditing ? L("编辑脚本") : L("新建脚本"))
                .font(.headline)

            HStack(spacing: DS.Space.s) {
                TextField(L("标题"), text: $draft.title, prompt: Text(L("可选，留空则用首行")))
                    .textFieldStyle(.roundedBorder)
                categoryField
                    .frame(width: 168)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L("脚本内容"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                editor
            }

            variablesHint

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
        .frame(width: 520, height: 468)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if draft.content.isEmpty {
                Text(L("在此输入脚本，可多行。用 {{名称}} 定义变量。"))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $draft.content)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(DS.Space.xs)
        }
        .frame(minHeight: 210)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(DS.Colors.fieldBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .strokeBorder(DS.Colors.cardBorder, lineWidth: 1)
        )
    }

    private var categoryField: some View {
        HStack(spacing: 4) {
            TextField(L("分组"), text: $draft.category, prompt: Text(L("可选")))
                .textFieldStyle(.roundedBorder)
            if !store.categories.isEmpty {
                Menu {
                    ForEach(store.categories, id: \.self) { category in
                        Button(category) { draft.category = category }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("选择已有分组"))
            }
        }
    }

    @ViewBuilder
    private var variablesHint: some View {
        let variables = draft.detectedVariables
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "curlybraces")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if variables.isEmpty {
                Text(L("提示：写 {{名称}} 可在发送前提示输入变量。"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("发送时将提示输入：%@", variables.joined(separator: "、")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func save() {
        guard canSave else { return }
        var snippet = draft
        snippet.title = snippet.title.trimmingCharacters(in: .whitespacesAndNewlines)
        snippet.category = snippet.category.trimmingCharacters(in: .whitespacesAndNewlines)
        snippet.variables = snippet.detectedVariables
        store.upsert(snippet)
        dismiss()
    }
}
