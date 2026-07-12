import SwiftUI
import AppKit
import HarborKit

// MARK: - Window appearance (跟随系统 / 浅色 / 深色)

/// App-wide window appearance preference. Defaults to 跟随系统; the chrome is
/// designed to look finished in both light and dark (FinalShell itself is
/// light chrome around a dark terminal).
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appAppearance"
    static let defaultValue = AppAppearance.system

    var id: String { rawValue }

    @MainActor
    var label: String {
        switch self {
        case .system: return L("跟随系统")
        case .light: return L("浅色")
        case .dark: return L("深色")
        }
    }

    @MainActor
    private var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    func apply() {
        NSApp.appearance = nsAppearance
    }

    /// Reads the stored preference (default 跟随系统) and applies it app-wide.
    @MainActor
    static func applyStored() {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? defaultValue.rawValue
        (AppAppearance(rawValue: raw) ?? defaultValue).apply()
    }
}

extension NSAppearance {
    /// True for any of the dark appearance variants.
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

// MARK: - Server privacy (hide IP)

/// Shared toggle for masking the server's IP / addresses in the monitor and
/// 系统信息 panels — handy when screenshotting or screen-sharing.
enum ServerPrivacy {
    static let maskIPKey = "maskServerIP"

    /// Replaces letters/digits in an address with `•`, keeping `.` `:` `/`
    /// separators so the shape still reads as an address.
    static func mask(_ address: String, when masked: Bool) -> String {
        guard masked else { return address }
        return String(address.map { ($0.isLetter || $0.isNumber) ? "•" : $0 })
    }
}

// MARK: - Design tokens

/// Central design tokens: every custom color, spacing and radius the chrome
/// uses lives here so the look stays coherent in light and dark mode.
enum DS {
    /// Spacing scale (pt).
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// Corner radii.
    enum Radius {
        static let small: CGFloat = 5
        static let medium: CGFloat = 8
        static let large: CGFloat = 14
    }

    /// Color tokens. Status colors are fixed; surfaces adapt to the window
    /// appearance via semantic AppKit colors.
    enum Colors {
        /// Session is running.
        static let statusRunning = Color(nsColor: .systemGreen)
        /// Session is connecting.
        static let statusConnecting = Color(nsColor: .systemOrange)
        /// Session exited cleanly / idle.
        static let statusIdle = Color(nsColor: .systemGray)
        /// Session exited with an error.
        static let statusError = Color(nsColor: .systemRed)

        /// Large background panels (empty state, detail placeholders).
        /// windowBackgroundColor, not underPageBackgroundColor: the latter
        /// renders as a heavy gray slab in light mode next to the light sidebar.
        static let panelBackground = Color(nsColor: .windowBackgroundColor)
        /// Default window chrome surface.
        static let chromeBackground = Color(nsColor: .windowBackgroundColor)
        /// Subtle filled background for custom fields and cards. Adapts per
        /// appearance: in dark mode a flat 5% white tint vanishes against the
        /// near-black window, so fields/cards need a stronger fill to read as
        /// distinct, tappable surfaces (round-3 dark-visibility complaint).
        static let fieldBackground = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor.white.withAlphaComponent(0.10)
                              : NSColor.black.withAlphaComponent(0.05)
        })
        /// Subtle filled background for list-like rows outside of List.
        static let rowBackground = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor.white.withAlphaComponent(0.09)
                              : NSColor.black.withAlphaComponent(0.05)
        })
        /// Hairline separators on standard chrome.
        static let separator = Color(nsColor: .separatorColor)
        /// Hairline border around flat stat cards (`statCard`). Slightly
        /// stronger than `separator` so each frosted-flat card reads as a
        /// distinct surface in both light and dark without a GPU blur.
        static let cardBorder = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor.white.withAlphaComponent(0.10)
                              : NSColor.black.withAlphaComponent(0.08)
        })

        // Monitoring panel accents — a calmer, modern palette (the old
        // green/orange read as harsh): cool blue for download, violet for
        // upload, teal for latency.
        /// Download (rx) bars in network sparklines.
        static let netDownload = Color(red: 0.23, green: 0.55, blue: 0.94)
        /// Upload (tx) bars in network sparklines.
        static let netUpload = Color(red: 0.58, green: 0.40, blue: 0.93)
        /// Latency sparkline bars.
        static let latency = Color(red: 0.13, green: 0.66, blue: 0.71)
        /// Track behind usage capsule bars.
        static let barTrack = Color.primary.opacity(0.08)
    }

    // MARK: Host avatars

    /// FNV-1a over UTF-8 — deterministic across launches (Swift's `Hashable`
    /// is seeded per-process and would reshuffle avatar colors every run).
    static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// Deterministic avatar hue derived from the host name.
    static func avatarColor(for name: String) -> Color {
        let hue = Double(stableHash(name) % 360) / 360.0
        return Color(hue: hue, saturation: 0.58, brightness: 0.72)
    }

    /// First character of the name, uppercased (works for CJK too).
    static func avatarInitial(for name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(first).uppercased()
    }

    /// Brand color for a detected OS id (from `OSBrand`), used to tint the host
    /// avatar so the distro is recognizable at a glance (Ubuntu orange, etc.).
    static func osColor(_ id: String?) -> Color? {
        switch id {
        case "ubuntu": return Color(red: 0.91, green: 0.36, blue: 0.13)
        case "debian": return Color(red: 0.84, green: 0.07, blue: 0.33)
        case "fedora": return Color(red: 0.20, green: 0.38, blue: 0.62)
        case "centos", "rhel", "rocky", "alma", "oracle": return Color(red: 0.79, green: 0.16, blue: 0.16)
        case "arch": return Color(red: 0.10, green: 0.59, blue: 0.86)
        case "manjaro": return Color(red: 0.20, green: 0.66, blue: 0.45)
        case "alpine": return Color(red: 0.05, green: 0.31, blue: 0.56)
        case "suse": return Color(red: 0.17, green: 0.60, blue: 0.20)
        case "kali": return Color(red: 0.16, green: 0.18, blue: 0.24)
        case "mint": return Color(red: 0.42, green: 0.69, blue: 0.30)
        case "amazon": return Color(red: 0.95, green: 0.60, blue: 0.07)
        case "macos": return Color(nsColor: .systemGray)
        case "linux": return Color(red: 0.32, green: 0.35, blue: 0.40)
        default: return nil
        }
    }
}

// MARK: - Reusable components

/// Colored circle with the host's initial — the host identity mark used in
/// the sidebar and recents lists.
struct HostAvatarView: View {
    let name: String
    /// Detected OS family id (from `SSHHost.osID`); tints the avatar with the
    /// distro's brand color and shows the distro initial when known.
    var osID: String? = nil
    var osName: String? = nil
    var size: CGFloat = 26

    var body: some View {
        Group {
            if let osID, let logo = NSImage(named: "os-\(osID)"), logo.size.width > 1 {
                // An official logo image was added to the asset catalog
                // (Assets.xcassets, named "os-<id>"): show it on a neutral disc.
                // The size guard ignores the empty placeholder slots so they
                // fall through to the vector mark until a real image is dropped in.
                ZStack {
                    Circle().fill(Color(nsColor: .windowBackgroundColor))
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(size * 0.14)
                }
            } else {
                ZStack {
                    Circle()
                        .fill((DS.osColor(osID) ?? DS.avatarColor(for: name)).gradient)
                    if osID == "macos" {
                        Image(systemName: "apple.logo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .foregroundStyle(.white)
                            .frame(width: size * 0.5, height: size * 0.5)
                    } else if OSLogo.has(osID), let osID {
                        OSLogo(osID: osID)
                            .frame(width: size * 0.72, height: size * 0.72)
                    } else {
                        Text(initial)
                            .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .help(osName.map { L("系统：%@", $0) } ?? "")
    }

    private var initial: String {
        if let osName, let first = osName.trimmingCharacters(in: .whitespaces).first {
            return String(first).uppercased()
        }
        return DS.avatarInitial(for: name)
    }
}

/// Small capsule count badge for section headers.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

/// Sidebar section header: small-caps style title plus a count badge.
struct SidebarSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
            CountBadge(count: count)
        }
    }
}

// MARK: - Theme-derived chrome colors

/// Colors derived from the active terminal theme so the chrome around the
/// terminal (tab strip, separators) reads as one continuous dark surface.
extension TerminalTheme {
    /// The terminal background itself.
    var backgroundColor: SwiftUI.Color { background.swiftUIColor }

    /// Tab strip surface: terminal background nudged toward the opposite tone.
    var chromeBackgroundColor: SwiftUI.Color { blendedBackground(0.06) }
    /// Hovered tab pill.
    var chromeHoverColor: SwiftUI.Color { blendedBackground(0.12) }
    /// Active tab pill.
    var chromeActiveColor: SwiftUI.Color { blendedBackground(0.20) }

    /// Faint 1px separator inside theme-tinted chrome.
    var chromeSeparatorColor: SwiftUI.Color {
        isDark ? SwiftUI.Color.white.opacity(0.08) : SwiftUI.Color.black.opacity(0.12)
    }

    var chromePrimaryTextColor: SwiftUI.Color {
        isDark ? SwiftUI.Color.white.opacity(0.92) : SwiftUI.Color.black.opacity(0.85)
    }

    var chromeSecondaryTextColor: SwiftUI.Color {
        // Bumped from 0.55 → 0.68 in dark: icon-button glyphs on the tinted
        // strip were hard to see against the near-black terminal background.
        isDark ? SwiftUI.Color.white.opacity(0.68) : SwiftUI.Color.black.opacity(0.55)
    }

    private func blendedBackground(_ fraction: CGFloat) -> SwiftUI.Color {
        let target: NSColor = isDark ? .white : .black
        let base = background.nsColor
        return SwiftUI.Color(nsColor: base.blended(withFraction: fraction, of: target) ?? base)
    }
}

// MARK: - Liquid Glass chrome (macOS 26 Tahoe)

/// A compact icon button for theme-tinted chrome (tab strip, command strip,
/// file panel toolbar). Wraps the glyph in `.glassEffect` so it picks up the
/// Tahoe Liquid Glass material, with an explicit visible chip + border in the
/// resting state so the control is obviously tappable in dark mode — the
/// round-3 complaint was that bare glyphs on the dark strip read as decoration.
///
/// Place several of these inside a `GlassEffectContainer` so adjacent glass
/// chips blend into one continuous capsule cluster.
struct GlassIconButton: View {
    let systemName: String
    let help: String
    var isOn = false
    var size: CGFloat = 12
    var disabled = false
    let action: () -> Void

    @State private var isHovering = false
    @GestureState private var isPressed = false

    init(
        _ systemName: String,
        help: String,
        isOn: Bool = false,
        size: CGFloat = 12,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.help = help
        self.isOn = isOn
        self.size = size
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: isOn ? .semibold : .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.small + 1)
                // .interactive() removed: it routes press feedback through the
                // GPU compositing pipeline (async), adding 1-2 frame latency
                // before any visual acknowledgment. Synchronous scale feedback
                // via @GestureState below replaces it with zero-frame response.
                .glassEffect(
                    isOn ? .regular.tint(Color.accentColor.opacity(0.5)) : .regular,
                    in: .rect(cornerRadius: DS.Radius.small + 1)
                )
                .opacity(disabled ? 0.55 : 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.small + 1)
                .strokeBorder(isOn ? Color.accentColor.opacity(0.5) : restingBorder,
                              lineWidth: 1)
        }
        .scaleEffect(isPressed ? 0.88 : 1.0)
        .animation(.easeOut(duration: 0.08), value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, state, _ in state = true }
        )
        .disabled(disabled)
        .onHover { isHovering = $0 }
        .help(help)
    }

    private var tint: Color {
        if disabled { return .secondary }
        if isOn { return .accentColor }
        return isHovering ? .primary : .secondary
    }

    /// Resting (not-on / not-hover) border. Branches on appearance like the
    /// sibling tokens (`cardBorder`, `chromeSeparatorColor`): a flat white tint
    /// is near-invisible on a light glass surface, so the dark-mode white-ish
    /// edge gives way to a dark edge in light mode — keeping the tappable
    /// affordance visible in both appearances.
    private var restingBorder: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor.white.withAlphaComponent(0.10)
                              : NSColor.black.withAlphaComponent(0.10)
        })
    }
}

extension View {
    /// Wraps a chrome card / cluster in Liquid Glass (Tahoe). Use on chrome
    /// that updates rarely — buttons, menus, the file-panel toolbar — so it
    /// floats over the terminal hero without a flat opaque slab.
    ///
    /// Do NOT use this on surfaces that re-render frequently (the live monitor
    /// cards, sparklines): Liquid Glass is a GPU blur that is re-rasterized
    /// every frame, and seven frosted cards re-blurring on every 2s monitor
    /// tick is the jank the inspector used to show. Use `statCard()` there.
    func glassCard(cornerRadius: CGFloat = DS.Radius.medium) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }

    /// Cheap, appearance-adaptive "frosted-flat" card for dense, frequently
    /// updating surfaces (the live monitor stat cards). A subtle semantic fill
    /// + hairline border + medium radius — visually close to a glass card but
    /// with NO live GPU blur, so a 2s data tick never pays a re-rasterization
    /// cost. This is the round-4 fix for the laggy monitor inspector.
    func statCard(cornerRadius: CGFloat = DS.Radius.medium) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(DS.Colors.fieldBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(DS.Colors.cardBorder, lineWidth: 1)
        )
    }
}

// MARK: - Error localization

/// Maps HarborKit's (English, test-pinned) errors to user-facing localized
/// messages. Unknown errors fall back to their own description.
@MainActor
func harborErrorMessage(_ error: Error) -> String {
    switch error {
    case let parse as QuickConnectError:
        switch parse {
        case .empty:
            return L("请输入要连接的主机。")
        case .invalidPort(let port):
            return L("端口无效：“%@”", port)
        case .invalidHost(let host):
            return L("主机无效：“%@”", host)
        case .invalidUser(let user):
            return L("用户名无效：“%@”", user)
        }
    case let command as SSHCommandError:
        switch command {
        case .emptyHostname:
            return L("主机名不能为空。")
        case .unsafeValue(let field, let value):
            return L("%@包含不安全字符：“%@”", localizedFieldName(field), value)
        case .invalidPort(let port):
            return L("端口无效：%@", port)
        }
    default:
        return error.localizedDescription
    }
}

@MainActor
private func localizedFieldName(_ field: String) -> String {
    switch field {
    case "hostname": return L("主机名")
    case "username": return L("用户名")
    case "identityFile": return L("密钥文件路径")
    case "bindAddress": return L("绑定地址")
    case "targetHost": return L("目标主机")
    default: return field
    }
}
