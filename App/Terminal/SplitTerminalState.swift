import Combine
import CoreGraphics
import Foundation

/// Orientation of a split divider, named for the divider LINE so it matches the
/// 水平分割 / 垂直分割 menu labels:
/// - `.horizontal`: a horizontal divider → the two panes stack top / bottom.
/// - `.vertical`: a vertical divider → the two panes sit side by side left / right.
enum SplitDirection {
    case horizontal
    case vertical
}

/// One node of a terminal tab's split tree. A tab begins as a single `.leaf`
/// wrapping its session; every split replaces a leaf with a `.split` whose two
/// children are the original leaf and a freshly-created one. `indirect` because
/// a `.split` holds child `SplitNode`s.
indirect enum SplitNode: Identifiable {
    case leaf(id: UUID, sessionID: UUID)
    case split(id: UUID, direction: SplitDirection, first: SplitNode, second: SplitNode, ratio: CGFloat)

    /// Stable identity, distinct from the session id so a leaf keeps its identity
    /// independent of which session it currently hosts.
    var id: UUID {
        switch self {
        case .leaf(let id, _): return id
        case .split(let id, _, _, _, _): return id
        }
    }
}

/// Split layout for one terminal tab: an observable tree of panes plus the
/// currently-focused pane. Pure model — it never spawns or tears down sessions
/// itself. The integration wires `makeSession` / `closeSession` to SessionManager
/// so this stays free of any SSH / lifecycle dependency and easy to reason about.
final class SplitTerminalState: ObservableObject {
    /// Root of the split tree. A brand-new tab is a single `.leaf` (no split).
    @Published private(set) var root: SplitNode
    /// Leaf whose terminal is active: drives the highlight border and the pane
    /// the ⌘D / ⌘⇧D shortcuts act on. Always kept pointing at a real leaf.
    @Published var focusedLeafID: UUID

    /// Smallest size (pt) either side of a split may shrink to, so a pane never
    /// collapses to an unusable sliver. The view clamps divider drags to this.
    static let minPaneSize: CGFloat = 120

    /// Creates a fresh session (by default cloned from `sourceSessionID`'s host)
    /// and returns its id, or nil if creation failed. Wired by the integration to
    /// SessionManager, which actually spawns the process and attaches services.
    var makeSession: ((_ sourceSessionID: UUID) -> UUID?)?
    /// Terminates / closes a session that has just left the tree (a removed pane).
    /// Wired by the integration to SessionManager.close.
    var closeSession: ((_ sessionID: UUID) -> Void)?

    init(rootSessionID: UUID) {
        let leafID = UUID()
        self.root = .leaf(id: leafID, sessionID: rootSessionID)
        self.focusedLeafID = leafID
    }

    /// True once the tab holds more than one pane.
    var isSplit: Bool {
        if case .split = root { return true }
        return false
    }

    /// Every session id currently displayed, in first-to-second tree order.
    var sessionIDs: [UUID] { Self.sessionIDs(in: root) }

    // MARK: - Splitting

    /// Splits `leafID` with a horizontal divider (new pane below). ⌘⇧D.
    func splitHorizontal(leafID: UUID) { split(leafID: leafID, direction: .horizontal) }

    /// Splits `leafID` with a vertical divider (new pane to the right). ⌘D.
    func splitVertical(leafID: UUID) { split(leafID: leafID, direction: .vertical) }

    private func split(leafID: UUID, direction: SplitDirection) {
        guard case .leaf(_, let sourceSessionID)? = Self.find(leafID, in: root),
              let newSessionID = makeSession?(sourceSessionID) else { return }
        let newLeafID = UUID()
        root = Self.replacingLeaf(leafID, in: root) { existing in
            .split(
                id: UUID(),
                direction: direction,
                first: existing,
                second: .leaf(id: newLeafID, sessionID: newSessionID),
                ratio: 0.5
            )
        }
        focusedLeafID = newLeafID
    }

    // MARK: - Removing

    /// Removes `leafID`; its sibling expands to fill the freed space, and the
    /// removed pane's session is closed via `closeSession`. No-op when it is the
    /// sole pane (a tab always keeps at least one). Returns the removed id(s).
    @discardableResult
    func removePane(leafID: UUID) -> [UUID] {
        guard isSplit,
              case .leaf(_, let removedSessionID)? = Self.find(leafID, in: root),
              let newRoot = Self.removing(leafID, from: root) else { return [] }
        root = newRoot
        if Self.find(focusedLeafID, in: root) == nil {
            focusedLeafID = Self.firstLeaf(in: root).id
        }
        closeSession?(removedSessionID)
        return [removedSessionID]
    }

    /// Collapses every split, keeping only the focused pane and closing all other
    /// sessions via `closeSession`. Returns the removed session ids.
    @discardableResult
    func unsplit() -> [UUID] {
        guard isSplit else { return [] }
        let keep = focusedLeaf
        let removed = sessionIDs.filter { $0 != keep.sessionID }
        root = .leaf(id: keep.id, sessionID: keep.sessionID)
        focusedLeafID = keep.id
        removed.forEach { closeSession?($0) }
        return removed
    }

    // MARK: - Divider ratio

    /// Live-updates the divider ratio of split `splitID` during a drag. `ratio`
    /// is the first child's fraction of the split's length.
    func setRatio(_ ratio: CGFloat, forSplit splitID: UUID) {
        root = Self.settingRatio(min(max(ratio, 0), 1), forSplit: splitID, in: root)
    }

    // MARK: - Focused leaf

    /// The focused leaf, falling back to the first leaf if the id ever goes stale.
    private var focusedLeaf: (id: UUID, sessionID: UUID) {
        if case .leaf(let id, let sid)? = Self.find(focusedLeafID, in: root) {
            return (id, sid)
        }
        return Self.firstLeaf(in: root)
    }

    // MARK: - Tree helpers (pure, recursive)

    private static func find(_ id: UUID, in node: SplitNode) -> SplitNode? {
        if node.id == id { return node }
        guard case .split(_, _, let first, let second, _) = node else { return nil }
        return find(id, in: first) ?? find(id, in: second)
    }

    private static func sessionIDs(in node: SplitNode) -> [UUID] {
        switch node {
        case .leaf(_, let sid): return [sid]
        case .split(_, _, let first, let second, _):
            return sessionIDs(in: first) + sessionIDs(in: second)
        }
    }

    private static func firstLeaf(in node: SplitNode) -> (id: UUID, sessionID: UUID) {
        switch node {
        case .leaf(let id, let sid): return (id, sid)
        case .split(_, _, let first, _, _): return firstLeaf(in: first)
        }
    }

    /// Rebuilds the tree with the leaf `leafID` replaced by `transform(leaf)`.
    private static func replacingLeaf(
        _ leafID: UUID,
        in node: SplitNode,
        with transform: (SplitNode) -> SplitNode
    ) -> SplitNode {
        switch node {
        case .leaf(let id, _):
            return id == leafID ? transform(node) : node
        case .split(let id, let direction, let first, let second, let ratio):
            return .split(
                id: id,
                direction: direction,
                first: replacingLeaf(leafID, in: first, with: transform),
                second: replacingLeaf(leafID, in: second, with: transform),
                ratio: ratio
            )
        }
    }

    /// Removes `leafID`, collapsing the split that held it into its sibling.
    /// Returns nil only if the whole subtree was exactly that leaf.
    private static func removing(_ leafID: UUID, from node: SplitNode) -> SplitNode? {
        switch node {
        case .leaf(let id, _):
            return id == leafID ? nil : node
        case .split(let id, let direction, let first, let second, let ratio):
            let newFirst = removing(leafID, from: first)
            let newSecond = removing(leafID, from: second)
            switch (newFirst, newSecond) {
            case (nil, nil): return nil
            case (nil, let survivor?), (let survivor?, nil): return survivor
            case (let f?, let s?):
                return .split(id: id, direction: direction, first: f, second: s, ratio: ratio)
            }
        }
    }

    private static func settingRatio(
        _ ratio: CGFloat,
        forSplit splitID: UUID,
        in node: SplitNode
    ) -> SplitNode {
        guard case .split(let id, let direction, let first, let second, let current) = node else {
            return node
        }
        if id == splitID {
            return .split(id: id, direction: direction, first: first, second: second, ratio: ratio)
        }
        return .split(
            id: id,
            direction: direction,
            first: settingRatio(ratio, forSplit: splitID, in: first),
            second: settingRatio(ratio, forSplit: splitID, in: second),
            ratio: current
        )
    }
}
