import SwiftUI
import AppKit
import HarborKit
import UniformTypeIdentifiers

/// App settings (Cmd+,): 外观 (window appearance + terminal theme cards) and
/// 终端 (font, size, option-as-meta). Everything is backed by @AppStorage and
/// the open terminals observe the same keys (see TerminalHostingView), so
/// every change here applies live to all sessions.
struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem { Label(L("外观"), systemImage: "paintpalette") }
            TerminalSettingsView()
                .tabItem { Label(L("终端"), systemImage: "terminal") }
            KeyManagementView()
                .tabItem { Label(L("密钥"), systemImage: "key") }
            FileTransferSettingsView()
                .tabItem { Label(L("传输"), systemImage: "arrow.up.arrow.down") }
            PrivacySettingsView()
                .tabItem { Label(L("隐私"), systemImage: "hand.raised") }
            AboutSettingsView()
                .tabItem { Label(L("关于"), systemImage: "info.circle") }
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - 隐私

private struct PrivacySettingsView: View {
    @AppStorage(HistoryPrivacyPreference.persistenceKey) private var persistHistory = false

    var body: some View {
        Form {
            Section(L("敏感历史")) {
                Toggle(L("跨启动保存命令与远程路径历史"), isOn: $persistHistory)
                Text(verbatim: L(
                    "默认关闭。关闭时历史只保留在当前运行内，并会清除 UserDefaults 中已有的命令和远程路径。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(L("立即清除命令与路径历史"), role: .destructive) {
                    clearHistory()
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: persistHistory) {
            if !persistHistory { clearHistory() }
        }
    }

    private func clearHistory() {
        HistoryPrivacyPreference.clear()
        CommandHistoryStore.shared.clear()
        PathHistoryStore.shared.clear()
    }
}

// MARK: - 关于

private struct AboutSettingsView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        if short.isEmpty { return build }
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: DS.Space.m) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "Harbor")
                            .font(.title3.weight(.semibold))
                        if !version.isEmpty {
                            Text(verbatim: L("版本 %@", version))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(verbatim: "\(L("作者")) Wxcayst")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }

            Section("联系作者") {
                if let mail = URL(string: "mailto:738888@proton.me") {
                    LabeledContent("邮箱") {
                        Link(destination: mail) { Text(verbatim: "738888@proton.me") }
                    }
                }
                if let site = URL(string: "https://caobi.eu") {
                    LabeledContent("网站") {
                        Link(destination: site) { Text(verbatim: "caobi.eu") }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 传输

private struct FileTransferSettingsView: View {
    // Default ON (unset ⇒ true), matching FileService.packagedTransferEnabled.
    @AppStorage(FileService.packagedTransferKey) private var packaged = true

    var body: some View {
        Form {
            Section("文件夹传输") {
                Toggle("传输文件夹时自动压缩", isOn: $packaged)
                Text(verbatim: L("开启后，上传 / 下载文件夹会先打包成单个 tar.gz 再传输，大量小文件会快很多；关闭则逐个文件传输。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 外观

private struct AppearanceSettingsView: View {
    @EnvironmentObject private var localization: LocalizationManager
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.defaultValue.rawValue
    @AppStorage("themeID") private var themeID = TerminalTheme.defaultThemeID

    private let columns = [
        GridItem(.flexible(), spacing: DS.Space.m),
        GridItem(.flexible(), spacing: DS.Space.m),
    ]

    var body: some View {
        Form {
            Section("窗口") {
                Picker("外观", selection: $appearanceRaw) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(verbatim: appearance.label).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearanceRaw) {
                    (AppAppearance(rawValue: appearanceRaw) ?? AppAppearance.defaultValue).apply()
                }

                Picker("语言", selection: $localization.language) {
                    ForEach(AppLanguage.selectable, id: \.self) { language in
                        Text(verbatim: languageLabel(language)).tag(language)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("终端主题") {
                LazyVGrid(columns: columns, spacing: DS.Space.m) {
                    ForEach(TerminalTheme.builtIn) { theme in
                        ThemeCard(theme: theme, isSelected: theme.id == themeID) {
                            themeID = theme.id
                        }
                    }
                }
                .padding(.vertical, DS.Space.xs)
            }
        }
        .formStyle(.grouped)
    }

    /// "跟随系统" (localized) for `system`; otherwise the language's own name so
    /// it reads naturally whatever the current UI language is.
    private func languageLabel(_ language: AppLanguage) -> String {
        language == .system ? L("跟随系统") : language.nativeLabel
    }
}

/// Live theme preview card: terminal background, prompt sample, the 16 ANSI
/// swatches, and the theme name. Click to apply (updates open terminals).
private struct ThemeCard: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("harbor ❯ ssh prod")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.foreground.swiftUIColor)
                        .lineLimit(1)
                    swatches(0..<8)
                    swatches(8..<16)
                }
                .padding(DS.Space.s + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.background.swiftUIColor)

                HStack {
                    Text(theme.name)
                        .font(.caption.weight(.medium))
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, DS.Space.s + 2)
                .padding(.vertical, 6)
                .background(DS.Colors.chromeBackground)
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.medium)
                    .strokeBorder(
                        isSelected ? Color.accentColor : DS.Colors.separator,
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .help(L("使用主题“%@”", theme.name))
    }

    private func swatches(_ range: Range<Int>) -> some View {
        HStack(spacing: 3) {
            ForEach(range, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.ansi[index].swiftUIColor)
                    .frame(width: 14, height: 8)
            }
        }
    }
}

// MARK: - 终端

private struct TerminalSettingsView: View {
    @AppStorage("terminalFontName") private var terminalFontName = "Menlo"
    @AppStorage("terminalFontSize") private var terminalFontSize = 13.0
    @AppStorage("optionAsMeta") private var optionAsMeta = true
    @AppStorage("useMetalRenderer") private var useMetalRenderer = true
    @AppStorage("themeID") private var themeID = TerminalTheme.defaultThemeID
    @AppStorage(TerminalBackgroundPreference.storageKey) private var backgroundRaw = ""

    private static let fontSizeRange = 9.0...24.0

    /// Monospaced font families installed on this machine. `static` so the
    /// enumeration runs once for the app's lifetime, not on every rebuild of
    /// this view struct (SwiftUI recreates the value frequently).
    private static let monospacedFamilies = TerminalSettingsView.availableMonospacedFamilies()

    /// Decoded view of the persisted background; writes re-encode to JSON so
    /// open terminals (observing the same key) update live.
    private var background: Binding<TerminalBackground> {
        Binding(
            get: { TerminalBackground.decoded(from: backgroundRaw) },
            set: { backgroundRaw = $0.encodedString() ?? "" }
        )
    }

    var body: some View {
        Form {
            TerminalBackgroundSection(
                background: background,
                themeBackground: TerminalTheme.theme(withID: themeID).background.swiftUIColor,
                themeForeground: TerminalTheme.theme(withID: themeID).foreground.swiftUIColor
            )

            Section("字体") {
                Picker("字体", selection: $terminalFontName) {
                    ForEach(fontChoices, id: \.self) { family in
                        Text(family)
                            .font(.custom(family, size: 12))
                            .tag(family)
                    }
                }

                Stepper(value: $terminalFontSize, in: TerminalSettingsView.fontSizeRange, step: 1) {
                    HStack {
                        Text(verbatim: L("字号"))
                        Spacer()
                        Text("\(Int(terminalFontSize)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                LabeledContent("预览") {
                    Text("user@harbor ~ % ssh prod")
                        .font(.custom(terminalFontName, size: terminalFontSize))
                        .lineLimit(1)
                }
            }

            Section("键盘") {
                Toggle("将 Option 用作 Meta 键", isOn: $optionAsMeta)
            }

            Section("渲染") {
                Toggle("GPU 加速 (Metal)", isOn: $useMetalRenderer)
                Text("开启后终端使用 Metal GPU 渲染，帧率更高但内存占用增加约 150MB。需重新连接生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The picker needs the stored value among its tags or it renders empty,
    /// so keep a stale/uninstalled font name visible instead of dropping it.
    private var fontChoices: [String] {
        var families = Self.monospacedFamilies
        if !families.contains(terminalFontName) {
            families.insert(terminalFontName, at: 0)
        }
        return families
    }

    /// Fixed-pitch families, judged by their first member face. Always
    /// includes the classic terminal fonts as long as they are installed.
    static func availableMonospacedFamilies() -> [String] {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies
            .filter { family in
                guard !family.hasPrefix(".") else { return false }
                guard let members = manager.availableMembers(ofFontFamily: family),
                      let faceName = members.first?.first as? String,
                      let font = NSFont(name: faceName, size: 12)
                else { return false }
                return font.isFixedPitch
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

// MARK: - 终端背景

/// Custom terminal background: theme default, a solid color, or an image with
/// adjustable opacity and blur (FinalShell-style). Binds to the shared
/// `TerminalBackground` so every change previews live in open terminals.
private struct TerminalBackgroundSection: View {
    @Binding var background: TerminalBackground
    /// The active theme's own background, shown as the swatch for "主题默认".
    let themeBackground: SwiftUI.Color
    /// The active theme's own foreground, used as the text-color picker's
    /// default swatch when no custom color is set (so it matches what the
    /// terminal actually renders, and stays visible on light themes).
    let themeForeground: SwiftUI.Color

    /// The chosen image, decoded once and held here so dragging the opacity /
    /// blur sliders (which re-render this whole section every frame) doesn't
    /// re-read and re-decode the file from disk on each frame.
    @State private var cachedWallpaperImage: NSImage?

    var body: some View {
        Section("终端背景") {
            Picker("背景", selection: modeBinding) {
                Text(verbatim: L("主题默认")).tag(TerminalBackground.Mode.theme)
                Text(verbatim: L("自定义颜色")).tag(TerminalBackground.Mode.color)
                Text(verbatim: L("背景图片")).tag(TerminalBackground.Mode.image)
            }
            .pickerStyle(.segmented)

            switch background.mode {
            case .theme:
                LabeledContent("当前背景") {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(themeBackground)
                        .frame(width: 44, height: 22)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(DS.Colors.separator, lineWidth: 1)
                        )
                }
            case .color:
                ColorPicker("背景颜色", selection: colorBinding, supportsOpacity: false)
            case .image:
                imageControls
            }

            // Text color is independent of the background mode: a custom
            // foreground applies over the theme, a solid color, or an image
            // alike, so it lives below a divider, outside the mode switch.
            Divider()
            ColorPicker("文字颜色", selection: foregroundBinding, supportsOpacity: false)
            if background.foreground != nil {
                Button(L("恢复默认文字颜色")) { background.foreground = nil }
                    .buttonStyle(.borderless)
            }

            if background.mode != .theme {
                Button(L("恢复默认背景")) { background.mode = .theme }
            }
        }
        .onAppear { loadWallpaperImage() }
        .onChange(of: background.imagePath) { loadWallpaperImage() }
    }

    @ViewBuilder private var imageControls: some View {
        LabeledContent("图片") {
            HStack(spacing: DS.Space.s) {
                imageWell
                Button(L("选择图片…")) { chooseImage() }
                if !background.imagePath.isEmpty {
                    Button(L("移除")) { background.imagePath = "" }
                        .buttonStyle(.borderless)
                }
            }
        }

        if !background.imagePath.isEmpty && !FileManager.default.fileExists(atPath: background.imagePath) {
            Label(L("图片文件已不存在，将使用主题背景。"), systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        LabeledContent("不透明度") {
            Slider(
                value: $background.imageOpacity,
                in: TerminalBackground.opacityRange
            )
            Text(percent(background.imageOpacity))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }

        LabeledContent("模糊") {
            Slider(
                value: $background.imageBlur,
                in: TerminalBackground.blurRange
            )
            Text("\(Int(background.imageBlur))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    /// A small thumbnail of the chosen image, or a placeholder.
    private var imageWell: some View {
        Group {
            if let image = cachedWallpaperImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(DS.Colors.chromeBackground)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .frame(width: 52, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(DS.Colors.separator, lineWidth: 1)
        )
    }

    private func loadWallpaperImage() {
        let path = background.imagePath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            cachedWallpaperImage = nil
            return
        }
        cachedWallpaperImage = NSImage(contentsOfFile: path)
    }

    // MARK: Bindings & actions

    private var modeBinding: Binding<TerminalBackground.Mode> {
        Binding(get: { background.mode }, set: { background.mode = $0 })
    }

    private var colorBinding: Binding<SwiftUI.Color> {
        Binding(
            get: { background.color.swiftUIColor },
            set: { background.color = TerminalBackground.RGBA(nsColor: NSColor($0)) }
        )
    }

    /// Custom text color; when none is set the swatch shows the active theme's
    /// own foreground — the color the terminal is actually rendering — so it is
    /// accurate and stays visible on light themes alike.
    private var foregroundBinding: Binding<SwiftUI.Color> {
        Binding(
            get: { background.foreground?.swiftUIColor ?? themeForeground },
            set: { background.foreground = TerminalBackground.RGBA(nsColor: NSColor($0)) }
        )
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .image]
        panel.prompt = L("选择")
        if panel.runModal() == .OK, let url = panel.url {
            background.imagePath = url.path
        }
    }
}

#Preview {
    SettingsView()
}
