import SwiftUI
import HarborKit

// MARK: - Tree model

/// Lazy, cached directory tree backing the file panel's left pane (FinalShell's
/// file-browser tree). Each node lists its child directories on demand through
/// the SAME `FileService` mux exec + `RemoteLsParser` — no new auth path, no
/// SFTP — and caches the result. Expanding a node lists it once; navigating the
/// table reveals/selects the matching node without reloading the whole tree.
///
/// State is keyed by absolute path so cached listings survive collapse/expand
/// and the "reveal current path" walk can reuse already-loaded levels.
@MainActor
final class DirectoryTreeModel: ObservableObject {
    /// Per-path load state. A node is a directory; `children` is `nil` until it
    /// has been listed once (then an array, possibly empty = a leaf directory).
    struct Node: Equatable {
        var children: [String]?
        var isExpanded = false
        var isLoading = false
        /// True after a listing failed (timeout / permission). The row shows a
        /// warning glyph and a click retries.
        var failed = false
    }

    /// Keyed by absolute, normalized path.
    @Published private(set) var nodes: [String: Node] = [:]
    /// The path the table currently shows (highlighted in the tree).
    @Published private(set) var selectedPath = "/"

    private weak var service: FileService?
    /// Bumped whenever `includeHidden` changes so cached listings reload lazily.
    private var hiddenGeneration = 0
    private var includeHidden = false
    /// In-flight `load` tasks keyed by path, so a serialized reveal walk can
    /// await a level that another caller already started rather than racing it.
    private var loadTasks: [String: Task<Void, Never>] = [:]

    func configure(service: FileService, includeHidden: Bool) {
        self.service = service
        if self.includeHidden != includeHidden {
            self.includeHidden = includeHidden
            // Drop cached child lists (a dotfile dir may appear/disappear);
            // keep expansion so the tree does not collapse under the user.
            for key in nodes.keys {
                nodes[key]?.children = nil
                nodes[key]?.failed = false
            }
            hiddenGeneration += 1
            // Re-list anything currently expanded so the view stays populated.
            for (path, node) in nodes where node.isExpanded {
                load(path, force: true)
            }
        }
    }

    func node(for path: String) -> Node {
        nodes[RemotePath.normalize(path)] ?? Node()
    }

    func isExpanded(_ path: String) -> Bool {
        node(for: path).isExpanded
    }

    /// Toggle a node. Expanding lists its children once (cached afterwards).
    func toggle(_ path: String) {
        let key = RemotePath.normalize(path)
        var node = nodes[key] ?? Node()
        node.isExpanded.toggle()
        nodes[key] = node
        if node.isExpanded, node.children == nil, !node.isLoading {
            load(key, force: false)
        }
    }

    /// Expand a node without toggling (used by the reveal walk).
    func expand(_ path: String) {
        let key = RemotePath.normalize(path)
        var node = nodes[key] ?? Node()
        guard !node.isExpanded || node.children == nil else { return }
        node.isExpanded = true
        nodes[key] = node
        if node.children == nil, !node.isLoading {
            load(key, force: false)
        }
    }

    /// (Re)list a node's child directories on the mux exec channel.
    func load(_ path: String, force: Bool) {
        let key = RemotePath.normalize(path)
        _ = loadTask(key, force: force)
    }

    /// Starts (or returns the in-flight) listing task for `key`. The serialized
    /// reveal walk awaits this so one deep navigation never fans out into K
    /// simultaneous aux `ssh` channels on the shared ControlMaster socket.
    @discardableResult
    private func loadTask(_ key: String, force: Bool) -> Task<Void, Never>? {
        guard let service else { return nil }
        if !force, nodes[key]?.children != nil { return nil }
        if let existing = loadTasks[key] { return existing }
        var node = nodes[key] ?? Node()
        node.isLoading = true
        node.failed = false
        nodes[key] = node
        let generation = hiddenGeneration
        let includeHidden = self.includeHidden
        let task = Task { [weak self] in
            let children = await service.listSubdirectories(of: key, includeHidden: includeHidden)
            guard let self else { return }
            self.loadTasks[key] = nil
            guard generation == self.hiddenGeneration else { return }
            var updated = self.nodes[key] ?? Node()
            updated.isLoading = false
            if let children {
                updated.children = children
                updated.failed = false
            } else {
                updated.failed = true
            }
            self.nodes[key] = updated
        }
        loadTasks[key] = task
        return task
    }

    /// Children of an already-loaded node, as absolute paths. Empty if unloaded.
    func childPaths(of path: String) -> [String] {
        let key = RemotePath.normalize(path)
        guard let names = nodes[key]?.children else { return [] }
        return names.map { RemotePath.join(key, $0) }
    }

    // MARK: Reveal

    /// Highlight `path` and expand every ancestor so it is visible. Each level
    /// is listed only if not already cached, so this is cheap on repeat
    /// navigation. Called whenever the table's `cwd` changes.
    ///
    /// The walk is SERIALIZED: each ancestor's listing is awaited before the
    /// next level is expanded, so a first-time deep reveal never launches K
    /// concurrent aux `ssh` channels over the one mux socket (mirroring how
    /// `FileService.transferChain` chains transfers to protect the master).
    func reveal(_ path: String) {
        let target = RemotePath.normalize(path)
        selectedPath = target
        // Root down to (but not including) the target, so the target row shows.
        var ancestors: [String] = []
        var current = target
        while current != "/" {
            let parent = RemotePath.parent(of: current)
            ancestors.append(parent)
            current = parent
        }
        let ordered = ancestors.reversed().map { $0 }
        Task { [weak self] in
            for ancestor in ordered {
                guard let self else { return }
                self.expand(ancestor)
                // Wait for this level to finish listing before expanding the
                // next, so listings run one-at-a-time on the shared socket.
                await self.loadTask(RemotePath.normalize(ancestor), force: false)?.value
            }
        }
    }
}

// MARK: - Flattened visible rows

/// One visible directory row, precomputed by the pane from the model so the row
/// view itself observes nothing. `Equatable` (via its stored value fields) lets
/// SwiftUI's diffing skip rows that did not change when a single node's listing
/// completes — no whole-tree re-render on a per-node mutation.
private struct TreeRow: Identifiable, Equatable {
    let path: String
    let name: String
    let depth: Int
    let isSelected: Bool
    let isExpanded: Bool
    let isLoading: Bool
    let failed: Bool
    /// `true` once the node is confirmed to be a leaf (listed, no subdirs), so
    /// the row hides its disclosure triangle.
    let isLeaf: Bool

    var id: String { path }
}

/// Flattens the expanded portion of the tree into an ordered array of value
/// rows. Runs in the pane (which observes the model) so the model's single
/// `@Published nodes` change recomputes the list once; the per-row views then
/// diff on `Equatable` and only the changed rows re-render.
@MainActor
private func flattenTree(_ model: DirectoryTreeModel) -> [TreeRow] {
    let selected = RemotePath.normalize(model.selectedPath)
    var rows: [TreeRow] = []

    func appendRow(path: String, name: String, depth: Int) {
        let normalized = RemotePath.normalize(path)
        let node = model.node(for: normalized)
        rows.append(
            TreeRow(
                path: normalized,
                name: name,
                depth: depth,
                isSelected: normalized == selected,
                isExpanded: node.isExpanded,
                isLoading: node.isLoading,
                failed: node.failed,
                isLeaf: node.children?.isEmpty == true
            )
        )
        if node.isExpanded {
            for child in model.childPaths(of: normalized) {
                appendRow(path: child, name: RemotePath.lastComponent(of: child), depth: depth + 1)
            }
        }
    }

    appendRow(path: "/", name: "/", depth: 0)
    return rows
}

// MARK: - Tree pane

/// The left directory-tree pane. Directories only; lazy + cached; a per-node
/// spinner while listing; click navigates the table (and vice-versa via
/// `model.reveal`). Standard appearance-correct chrome, no live Liquid Glass.
struct DirectoryTreeView: View {
    @ObservedObject var service: FileService
    @ObservedObject var model: DirectoryTreeModel
    let includeHidden: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // The pane observes the model and flattens once per change;
                    // each row view observes nothing and diffs on Equatable, so
                    // a single node's listing only re-renders the rows it moved.
                    ForEach(flattenTree(model)) { row in
                        DirectoryTreeRow(
                            row: row,
                            onTap: { service.navigate(toPath: row.path) },
                            onToggle: { model.toggle(row.path) }
                        )
                        .equatable()
                    }
                }
                .padding(.vertical, 2)
            }
            .background(DS.Colors.fieldBackground.opacity(0.4))
        }
        .onAppear {
            model.configure(service: service, includeHidden: includeHidden)
            model.load("/", force: false)
            model.reveal(service.cwd)
        }
        .onChange(of: includeHidden) { _, newValue in
            model.configure(service: service, includeHidden: newValue)
        }
        .onChange(of: service.cwd) { _, newValue in
            model.reveal(newValue)
        }
        .onChange(of: service.status) { _, newValue in
            // First-ready (or reconnect): seed the root and reveal cwd.
            if newValue == .ready {
                model.configure(service: service, includeHidden: includeHidden)
                model.load("/", force: true)
                model.reveal(service.cwd)
            }
        }
    }
}

/// One disclosure row. Driven entirely by a plain `TreeRow` value plus two
/// closures — it observes NO ObservableObject, so SwiftUI skips it whenever its
/// value is unchanged (no whole-tree invalidation on a per-node listing).
private struct DirectoryTreeRow: View, @MainActor Equatable {
    let row: TreeRow
    let onTap: () -> Void
    let onToggle: () -> Void

    @State private var isHovering = false

    /// Equatability ignores the closures (stable per path) and compares only
    /// the value payload, which is what actually drives the rendering.
    static func == (lhs: DirectoryTreeRow, rhs: DirectoryTreeRow) -> Bool {
        lhs.row == rhs.row
    }

    var body: some View {
        HStack(spacing: 3) {
            disclosure
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(row.isSelected ? Color.accentColor : Color(nsColor: .systemBlue))
                .frame(width: 14)
            Text(row.name)
                .font(.system(size: 11.5, weight: row.isSelected ? .semibold : .regular))
                .foregroundStyle(row.isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.middle)
            if row.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            } else if row.failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(DS.Colors.statusConnecting)
                    .help(L("无法读取此目录"))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2.5)
        .padding(.trailing, DS.Space.xs)
        .padding(.leading, CGFloat(row.depth) * 12 + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { isHovering = $0 }
        .help(row.path)
    }

    @ViewBuilder
    private var disclosure: some View {
        // A confirmed leaf directory shows no triangle, just a spacer.
        if row.isLeaf {
            Color.clear.frame(width: 12, height: 12)
        } else {
            Button {
                onToggle()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: DS.Radius.small - 1, style: .continuous)
            .fill(row.isSelected ? Color.accentColor.opacity(0.16)
                  : (isHovering ? DS.Colors.rowBackground : .clear))
            .padding(.horizontal, 2)
    }
}
