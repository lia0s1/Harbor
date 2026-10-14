import AppKit
import Combine
import SwiftUI
import HarborKit
import SwiftTerm

/// Single source of truth for terminal font UserDefaults keys and defaults.
enum TerminalFontPreference {
    static let fontNameKey = "terminalFontName"
    static let fontSizeKey = "terminalFontSize"
    /// Separate CJK (Chinese) font family; empty = system fallback chain.
    static let cjkFontNameKey = "terminalCJKFontName"
    static let defaultFontName = "Menlo"
    static let defaultCJKFontName = ""
    static let defaultFontSize: Double = 13.0
    static let minFontSize: Double = 9.0
    static let maxFontSize: Double = 32.0

    /// Resolves the persisted font choices into the actual NSFont — primary
    /// font for ASCII, with the chosen CJK font first in the cascade list.
    static func resolveFont(defaults: UserDefaults = .standard) -> NSFont {
        let rawSize = defaults.double(forKey: fontSizeKey)
        let size = rawSize > 0 ? CGFloat(rawSize) : CGFloat(defaultFontSize)
        let name = defaults.string(forKey: fontNameKey) ?? defaultFontName
        let cjk = defaults.string(forKey: cjkFontNameKey) ?? defaultCJKFontName
        return TerminalFontCascade.makeFont(name: name, size: size, cjkName: cjk)
    }
}

/// Font zoom (⌘+/⌘−): persists to the shared UserDefaults keys so settings
/// and every open terminal pick the change up via @AppStorage.
extension LocalProcessTerminalView {
    public func zoomIn() { zoomFontSize(by: 0.5) }
    public func zoomOut() { zoomFontSize(by: -0.5) }

    private func zoomFontSize(by delta: Double) {
        let defaults = UserDefaults.standard
        let raw = defaults.double(forKey: TerminalFontPreference.fontSizeKey)
        let current = raw > 0 ? raw : TerminalFontPreference.defaultFontSize
        let clamped = min(max(current + delta, TerminalFontPreference.minFontSize), TerminalFontPreference.maxFontSize)
        guard clamped != current else { return }
        defaults.set(clamped, forKey: TerminalFontPreference.fontSizeKey)
        applyPersistedFont()
    }

    private func applyPersistedFont() {
        font = TerminalFontPreference.resolveFont()
    }
}

/// Hosts a session's long-lived `LocalProcessTerminalView` inside SwiftUI.
///
/// The terminal NSView is owned by the `TerminalSession`, NOT created here, so
/// tab switches never tear down terminal state. `makeNSView` returns a stable
/// `TerminalContainerView`; `updateNSView` applies font / appearance / theme /
/// custom-background settings when @AppStorage values change or isSelected
/// transitions. Reconnects (session.terminalView swapped) are handled via a
/// Combine subscription in the Coordinator so they bypass SwiftUI's update cycle
/// entirely — avoiding the 1-3×/sec updateNSView calls that session.title used
/// to trigger via @ObservedObject.
struct TerminalHostingView: NSViewRepresentable {
    // Not @ObservedObject — session.title fires 1-3×/sec and would call
    // updateNSView at that rate even though nothing relevant changed.
    // Reconnect detection is handled by the Coordinator's Combine subscription.
    let session: TerminalSession
    let isSelected: Bool

    @AppStorage(TerminalFontPreference.fontNameKey) private var terminalFontName = TerminalFontPreference.defaultFontName
    @AppStorage(TerminalFontPreference.fontSizeKey) private var terminalFontSize = TerminalFontPreference.defaultFontSize
    @AppStorage(TerminalFontPreference.cjkFontNameKey) private var terminalCJKFontName = TerminalFontPreference.defaultCJKFontName
    @AppStorage("themeID") private var themeID = TerminalTheme.defaultThemeID
    /// Bumped by TerminalThemeStore whenever file themes are (re)scanned, so a
    /// re-imported or deleted .harbortheme re-applies even when the theme ID
    /// itself did not change.
    @AppStorage(TerminalThemeStore.catalogRevisionKey) private var themeCatalogRevision = 0
    @AppStorage("optionAsMeta") private var optionAsMeta = true
    @AppStorage(TerminalBackgroundPreference.storageKey) private var backgroundRaw = ""

    final class Coordinator {
        var wasSelected = false
        var lastTerminalView: ObjectIdentifier?
        var appliedThemeID: String?
        var appliedThemeCatalogRevision = -1
        var appliedBackground: TerminalBackground?
        var appliedBackgroundRaw: String?
        var appliedFontName: String?
        var appliedCJKFontName: String?
        var appliedFontSize: CGFloat = 0
        var appliedOptionAsMeta: Bool?
        /// Holds the session.$terminalView subscription so reconnects re-embed
        /// the fresh terminal without going through SwiftUI's update cycle.
        var terminalViewSubscription: AnyCancellable?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView(frame: .zero)
        container.embed(session.terminalView)
        let coordinator = context.coordinator
        coordinator.lastTerminalView = ObjectIdentifier(session.terminalView)
        applyTheme(to: session.terminalView, coordinator: coordinator, force: true)
        applyBackground(to: container, terminal: session.terminalView, coordinator: coordinator)

        // React to reconnects: session.terminalView is replaced with a fresh view
        // after a successful reconnect. Handle it directly here so SwiftUI's
        // update cycle (and its 1-3×/sec title-escape noise) stays out of the path.
        coordinator.terminalViewSubscription = session.$terminalView
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak container, weak coordinator] newTerminal in
                guard let container, let coordinator else { return }
                container.embed(newTerminal)
                coordinator.lastTerminalView = ObjectIdentifier(newTerminal)
                // Apply current settings from UserDefaults (AppStorage values).
                let themeID = UserDefaults.standard.string(forKey: "themeID")
                    ?? TerminalTheme.defaultThemeID
                let theme = TerminalTheme.theme(withID: themeID)
                newTerminal.apply(theme: theme)
                coordinator.appliedThemeID = themeID
                coordinator.appliedThemeCatalogRevision = UserDefaults.standard.integer(
                    forKey: TerminalThemeStore.catalogRevisionKey)
                // Font + optionAsMeta (cascaded: primary + optional CJK fallback)
                let font = TerminalFontPreference.resolveFont()
                newTerminal.font = font
                newTerminal.optionAsMetaKey = UserDefaults.standard.bool(forKey: "optionAsMeta")
                coordinator.appliedFontName = UserDefaults.standard.string(forKey: TerminalFontPreference.fontNameKey)
                    ?? TerminalFontPreference.defaultFontName
                coordinator.appliedCJKFontName = UserDefaults.standard.string(forKey: TerminalFontPreference.cjkFontNameKey)
                    ?? TerminalFontPreference.defaultCJKFontName
                coordinator.appliedFontSize = font.pointSize
                coordinator.appliedOptionAsMeta = UserDefaults.standard.bool(forKey: "optionAsMeta")
                // Background
                let bgRaw = UserDefaults.standard.string(
                    forKey: TerminalBackgroundPreference.storageKey) ?? ""
                let bg = TerminalBackground.decoded(from: bgRaw)
                container.apply(background: bg, theme: theme, terminal: newTerminal)
                coordinator.appliedBackground = bg
                coordinator.appliedBackgroundRaw = bgRaw
                // Focus if this is the selected session
                if coordinator.wasSelected {
                    DispatchQueue.main.async {
                        guard let window = newTerminal.window,
                              newTerminal.superview != nil else { return }
                        if window.firstResponder !== newTerminal {
                            window.makeFirstResponder(newTerminal)
                        }
                    }
                }
            }

        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        let terminal = session.terminalView
        // Safety: re-embed if the terminal somehow lost its parent (e.g. a
        // reconnect that the Combine sink handled before makeNSView finished).
        if terminal.superview !== container {
            container.embed(terminal)
            context.coordinator.lastTerminalView = ObjectIdentifier(terminal)
        }
        // updateNSView is now only called for @AppStorage changes (font, theme,
        // background, optionAsMeta) and isSelected transitions — never for
        // session.title changes (no @ObservedObject on session).
        applyTheme(to: terminal, coordinator: context.coordinator, force: false)
        applyAppearance(to: terminal, coordinator: context.coordinator)
        applyBackground(to: container, terminal: terminal, coordinator: context.coordinator)

        let becameSelected = isSelected && !context.coordinator.wasSelected
        context.coordinator.wasSelected = isSelected
        if becameSelected {
            DispatchQueue.main.async {
                guard let window = terminal.window, terminal.superview != nil else { return }
                if window.firstResponder !== terminal {
                    window.makeFirstResponder(terminal)
                }
            }
        }
    }

    private func applyTheme(to terminal: LocalProcessTerminalView, coordinator: Coordinator, force: Bool) {
        let catalogChanged = coordinator.appliedThemeCatalogRevision != themeCatalogRevision
        guard force || coordinator.appliedThemeID != themeID || catalogChanged else { return }
        terminal.apply(theme: TerminalTheme.theme(withID: themeID))
        coordinator.appliedThemeID = themeID
        coordinator.appliedThemeCatalogRevision = themeCatalogRevision
        coordinator.appliedBackground = nil
        // The container background derives from the theme (theme bg is the
        // image-mode base color and the frost tint), so force its re-apply too.
        coordinator.appliedBackgroundRaw = nil
    }

    private func applyAppearance(to terminal: LocalProcessTerminalView, coordinator: Coordinator) {
        let size = CGFloat(terminalFontSize)
        guard coordinator.appliedFontName != terminalFontName
           || coordinator.appliedCJKFontName != terminalCJKFontName
           || coordinator.appliedFontSize != size
           || coordinator.appliedOptionAsMeta != optionAsMeta else { return }
        let desired = TerminalFontCascade.makeFont(
            name: terminalFontName, size: size, cjkName: terminalCJKFontName)
        if terminal.font.fontName != desired.fontName
            || terminal.font.pointSize != desired.pointSize
            || TerminalFontCascade.cascadeSignature(of: terminal.font)
                != TerminalFontCascade.cascadeSignature(of: desired) {
            terminal.font = desired
        }
        terminal.optionAsMetaKey = optionAsMeta
        coordinator.appliedFontName = terminalFontName
        coordinator.appliedCJKFontName = terminalCJKFontName
        coordinator.appliedFontSize = size
        coordinator.appliedOptionAsMeta = optionAsMeta
    }

    private func applyBackground(
        to container: TerminalContainerView,
        terminal: LocalProcessTerminalView,
        coordinator: Coordinator
    ) {
        guard coordinator.appliedBackgroundRaw != backgroundRaw else { return }
        let background = TerminalBackground.decoded(from: backgroundRaw)
        guard coordinator.appliedBackground != background else {
            coordinator.appliedBackgroundRaw = backgroundRaw
            return
        }
        coordinator.appliedBackgroundRaw = backgroundRaw
        coordinator.appliedBackground = background
        let theme = TerminalTheme.theme(withID: themeID)
        container.apply(background: background, theme: theme, terminal: terminal)
    }
}
