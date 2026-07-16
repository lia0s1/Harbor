import AppKit
import SwiftUI
import HarborKit

/// Renders a terminal tab's split tree: each leaf hosts a live terminal, splits
/// lay out with draggable dividers, and the focused pane carries a subtle accent
/// border. ⌘D splits the focused pane vertically, ⌘⇧D horizontally.
///
/// Only the panes actually present in the tree are built, so an unsplit tab is
/// just one `TerminalHostingView` with no extra layout machinery.
struct SplitTerminalView: View {
    @ObservedObject var state: SplitTerminalState
    let theme: TerminalTheme
    /// Resolves a leaf's session id to the live session it should host — supplied
    /// by the integration (e.g. a lookup into SessionManager.sessions).
    let session: (UUID) -> TerminalSession?

    var body: some View {
        SplitNodeView(node: state.root, state: state, theme: theme, session: session)
            .background { shortcutCatchers }
    }

    /// Invisible buttons that register the split shortcuts while this view is on
    /// screen. Hidden buttons still carry their keyboard shortcuts, and both act
    /// on the focused pane.
    private var shortcutCatchers: some View {
        ZStack {
            Button(L("垂直分割")) { state.splitVertical(leafID: state.focusedLeafID) }
                .keyboardShortcut("d", modifiers: .command)
            Button(L("水平分割")) { state.splitHorizontal(leafID: state.focusedLeafID) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
        .hidden()
    }
}

/// Recursively renders one node: a leaf becomes a terminal pane, a split becomes
/// a draggable-divider container holding two child nodes.
private struct SplitNodeView: View {
    let node: SplitNode
    @ObservedObject var state: SplitTerminalState
    let theme: TerminalTheme
    let session: (UUID) -> TerminalSession?

    var body: some View {
        switch node {
        case .leaf(let id, let sessionID):
            LeafPaneView(leafID: id, sessionID: sessionID, state: state, theme: theme, session: session)
        case let .split(id, direction, first, second, ratio):
            SplitContainerView(
                splitID: id, direction: direction, first: first, second: second,
                ratio: ratio, state: state, theme: theme, session: session
            )
        }
    }
}

/// A single terminal pane. Hosts its session's terminal, shows a focus border
/// when it is the active pane of a split, focuses on click, and offers the
/// split / close context menu.
private struct LeafPaneView: View {
    let leafID: UUID
    let sessionID: UUID
    @ObservedObject var state: SplitTerminalState
    let theme: TerminalTheme
    let session: (UUID) -> TerminalSession?

    var body: some View {
        ZStack {
            if let session = session(sessionID) {
                TerminalHostingView(session: session, isSelected: isFocused)
            } else {
                theme.backgroundColor
            }
        }
        .overlay {
            if showsFocusBorder {
                Rectangle()
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        // Simultaneous so the click still reaches the terminal (which takes
        // keyboard focus itself); this just moves the highlight / shortcut target.
        .simultaneousGesture(TapGesture().onEnded { state.focusedLeafID = leafID })
        .contextMenu {
            Button(L("水平分割")) { state.splitHorizontal(leafID: leafID) }
            Button(L("垂直分割")) { state.splitVertical(leafID: leafID) }
            if state.isSplit {
                Divider()
                Button(L("关闭面板"), role: .destructive) { state.removePane(leafID: leafID) }
            }
        }
    }

    /// The unsplit single pane is always focused (so its terminal is first
    /// responder); in a split only the active pane is.
    private var isFocused: Bool { state.focusedLeafID == leafID }
    /// Border only reads as meaningful once there is more than one pane.
    private var showsFocusBorder: Bool { state.isSplit && isFocused }
}

/// Lays out a split's two children with an overlaid, draggable divider on the
/// seam (the panes themselves stay flush, FinalShell-style — no gap).
private struct SplitContainerView: View {
    let splitID: UUID
    let direction: SplitDirection
    let first: SplitNode
    let second: SplitNode
    let ratio: CGFloat
    @ObservedObject var state: SplitTerminalState
    let theme: TerminalTheme
    let session: (UUID) -> TerminalSession?

    /// Width/height of the invisible drag target straddling the seam.
    private let dividerHit: CGFloat = 8

    /// First pane's extent captured at drag start, so the drag translation is
    /// applied from a stable base (the live `ratio` shifts as we drag).
    @State private var dragStartExtent: CGFloat?
    /// Live ratio during drag — kept local so only this view re-renders while
    /// dragging; written back to shared state only on drag end.
    @State private var localRatio: CGFloat?

    /// `.vertical` means a vertical divider → the panes sit in a row (left/right).
    private var isRow: Bool { direction == .vertical }

    var body: some View {
        GeometryReader { geo in
            let total = isRow ? geo.size.width : geo.size.height
            let cross = isRow ? geo.size.height : geo.size.width
            let firstExtent = clamped((localRatio ?? ratio) * total, total: total)
            ZStack(alignment: .topLeading) {
                panes(firstExtent: firstExtent, total: total, cross: cross)
                divider(position: firstExtent, total: total, cross: cross)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder
    private func panes(firstExtent: CGFloat, total: CGFloat, cross: CGFloat) -> some View {
        let secondExtent = max(total - firstExtent, 0)
        if isRow {
            HStack(spacing: 0) {
                child(first).frame(width: firstExtent, height: cross)
                child(second).frame(width: secondExtent, height: cross)
            }
        } else {
            VStack(spacing: 0) {
                child(first).frame(width: cross, height: firstExtent)
                child(second).frame(width: cross, height: secondExtent)
            }
        }
    }

    private func child(_ node: SplitNode) -> some View {
        SplitNodeView(node: node, state: state, theme: theme, session: session)
    }

    private func divider(position: CGFloat, total: CGFloat, cross: CGFloat) -> some View {
        Rectangle()
            .fill(theme.chromeSeparatorColor)
            .frame(width: isRow ? 1 : cross, height: isRow ? cross : 1)
            .frame(width: isRow ? dividerHit : cross, height: isRow ? cross : dividerHit)
            .contentShape(Rectangle())
            .offset(
                x: isRow ? position - dividerHit / 2 : 0,
                y: isRow ? 0 : position - dividerHit / 2
            )
            .gesture(dividerDrag(total: total))
            .onHover { hovering in
                if hovering {
                    (isRow ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                } else {
                    NSCursor.arrow.set()
                }
            }
    }

    private func dividerDrag(total: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let base = dragStartExtent ?? clamped(ratio * total, total: total)
                if dragStartExtent == nil { dragStartExtent = base }
                let delta = isRow ? value.translation.width : value.translation.height
                localRatio = clamped(base + delta, total: total) / total
            }
            .onEnded { _ in
                if let r = localRatio {
                    state.setRatio(r, forSplit: splitID)
                }
                localRatio = nil
                dragStartExtent = nil
            }
    }

    /// Keeps both sides at least `minPaneSize` (or half the length when the whole
    /// split is too small to honor that).
    private func clamped(_ extent: CGFloat, total: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        let minSize = min(SplitTerminalState.minPaneSize, total / 2)
        return min(max(extent, minSize), total - minSize)
    }
}
