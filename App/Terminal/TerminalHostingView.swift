import AppKit
import Combine
import SwiftUI
import HarborKit
import SwiftTerm

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

    @AppStorage("terminalFontName") private var terminalFontName = "Menlo"
    @AppStorage("terminalFontSize") private var terminalFontSize = 13.0
    @AppStorage("themeID") private var themeID = TerminalTheme.defaultThemeID
    @AppStorage("optionAsMeta") private var optionAsMeta = true
    @AppStorage(TerminalBackgroundPreference.storageKey) private var backgroundRaw = ""

    final class Coordinator {
        var wasSelected = false
        var lastTerminalView: ObjectIdentifier?
        var appliedThemeID: String?
        var appliedBackground: TerminalBackground?
        var appliedBackgroundRaw: String?
        var appliedFontName: String?
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
                // Font + optionAsMeta
                let fontName = UserDefaults.standard.string(forKey: "terminalFontName") ?? "Menlo"
                let rawSize = UserDefaults.standard.double(forKey: "terminalFontSize")
                let size = rawSize > 0 ? CGFloat(rawSize) : 13.0
                let font = NSFont(name: fontName, size: size)
                    ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                newTerminal.font = font
                newTerminal.optionAsMetaKey = UserDefaults.standard.bool(forKey: "optionAsMeta")
                coordinator.appliedFontName = fontName
                coordinator.appliedFontSize = size
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
        guard force || coordinator.appliedThemeID != themeID else { return }
        terminal.apply(theme: TerminalTheme.theme(withID: themeID))
        coordinator.appliedThemeID = themeID
        coordinator.appliedBackground = nil
    }

    private func applyAppearance(to terminal: LocalProcessTerminalView, coordinator: Coordinator) {
        let size = CGFloat(terminalFontSize)
        guard coordinator.appliedFontName != terminalFontName
           || coordinator.appliedFontSize != size
           || coordinator.appliedOptionAsMeta != optionAsMeta else { return }
        let desired = NSFont(name: terminalFontName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        if terminal.font.fontName != desired.fontName || terminal.font.pointSize != desired.pointSize {
            terminal.font = desired
        }
        terminal.optionAsMetaKey = optionAsMeta
        coordinator.appliedFontName = terminalFontName
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
