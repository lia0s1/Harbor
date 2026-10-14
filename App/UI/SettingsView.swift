import SwiftUI
import AppKit
import HarborKit
import UniformTypeIdentifiers
import ImageIO

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
        .frame(minWidth: 520, idealWidth: 520, maxWidth: 640, minHeight: 420, idealHeight: 420, maxHeight: 420)
    }
}

// MARK: - 隐私

private struct PrivacySettingsView: View {
    @AppStorage(HistoryPrivacyPreference.persistenceKey) private var persistHistory = false
    @State private var showClearHistoryConfirmation = false
    /// Live GeoIP toggle (隐私区；GeoIPSettings 的注释即指向这里）。
    /// @ObservedObject so flipping the switch reveals the cache row inline.
    @ObservedObject private var geoIP = GeoIPSettings.shared
    @State private var geoIPCacheCleared = false

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
                    showClearHistoryConfirmation = true
                }
                .confirmationDialog(
                    L("清除命令与路径历史？"),
                    isPresented: $showClearHistoryConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(L("清除"), role: .destructive) { clearHistory() }
                    Button(L("取消"), role: .cancel) { }
                } message: {
                    Text(L("将删除所有已保存的命令和远程路径历史，此操作无法撤销。"))
                }
            }

            Section(L("IP 归属地查询")) {
                Toggle(L("查询主机 IP 的归属地（国家/城市）"), isOn: $geoIP.isEnabled)
                Text(L("开启后会向第三方服务查询主机 IP 的国家/城市，主机地址会发给该服务。内网地址仅本地识别，不发起网络请求。默认关闭。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if geoIP.isEnabled {
                    Button(L("清除归属地缓存")) {
                        GeoIPService.shared.clearCache()
                        geoIPCacheCleared = true
                    }
                    if geoIPCacheCleared {
                        Text(L("已清除归属地缓存。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: persistHistory) { _, _ in
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
                        .aspectRatio(contentMode: .fit)
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
    @ObservedObject private var themeStore = TerminalThemeStore.shared

    /// Transient inline feedback for import/export/delete actions.
    @State private var themeActionMessage: String?
    @State private var themeActionIsError = false
    @State private var showDeleteThemeConfirmation = false

    var body: some View {
        Form {
            Section("窗口") {
                Picker("外观", selection: $appearanceRaw) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(verbatim: appearance.label).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearanceRaw) { _, _ in
                    (AppAppearance(rawValue: appearanceRaw) ?? AppAppearance.defaultValue).apply()
                }

                Picker("语言", selection: $localization.language) {
                    ForEach(AppLanguage.selectable, id: \.self) { language in
                        Text(verbatim: languageLabel(language)).tag(language)
                    }
                }
                .pickerStyle(.segmented)
            }

            themeSection
        }
        .formStyle(.grouped)
        .onAppear { themeStore.rescan() }
    }

    /// "跟随系统" (localized) for `system`; otherwise the language's own name so
    /// it reads naturally whatever the current UI language is.
    private func languageLabel(_ language: AppLanguage) -> String {
        language == .system ? L("跟随系统") : language.nativeLabel
    }

    // MARK: 终端主题（内置 + .harbortheme 文件方案）

    private var selectedTheme: TerminalTheme {
        TerminalTheme.theme(withID: themeID)
    }

    private var isSelectedThemeFromFile: Bool {
        themeStore.fileThemes.contains { $0.id == themeID }
    }

    private var themeSection: some View {
        Section("终端主题") {
            Picker("主题", selection: $themeID) {
                ForEach(TerminalTheme.builtIn) { theme in
                    Text(theme.name).tag(theme.id)
                }
                if !themeStore.fileThemes.isEmpty {
                    Divider()
                    ForEach(themeStore.fileThemes) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                // A stale id (deleted theme file between scans) must stay
                // selectable-taggable or the picker renders empty.
                if !TerminalTheme.allThemes.contains(where: { $0.id == themeID }) {
                    Divider()
                    Text(L("未知主题（%@）", themeID)).tag(themeID)
                }
            }

            ThemePreviewPanel(theme: selectedTheme)

            HStack(spacing: DS.Space.s) {
                Button(L("导入主题…"), action: importTheme)
                Button(L("导出当前主题…"), action: exportCurrentTheme)
                Button(L("打开主题目录")) { themeStore.revealThemesDirectory() }
                if isSelectedThemeFromFile {
                    Button(L("删除"), role: .destructive) {
                        showDeleteThemeConfirmation = true
                    }
                    .confirmationDialog(
                        L("删除主题「%@」？", selectedTheme.name),
                        isPresented: $showDeleteThemeConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(L("移到废纸篓"), role: .destructive) {
                            themeStore.delete(theme: selectedTheme)
                        }
                        Button(L("取消"), role: .cancel) { }
                    } message: {
                        Text(L("主题文件将移到废纸篓。"))
                    }
                }
            }

            if let message = themeActionMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(themeActionIsError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !themeStore.loadIssues.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("部分主题文件未加载："))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(themeStore.loadIssues, id: \.self) { issue in
                        Text(issue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text(L("主题文件存放于 ~/Library/Application Support/Harbor/Themes/（.harbortheme），可复制分享。右键终端的背景/文字颜色覆盖仍然有效，主题是基底。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reportThemeAction(_ message: String?, isError: Bool) {
        themeActionMessage = message
        themeActionIsError = isError
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: TerminalThemeStore.fileExtension)].compactMap { $0 }
        panel.message = L("选择 .harbortheme 主题文件")
        panel.prompt = L("导入")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let error = themeStore.importTheme(from: url) {
            reportThemeAction(L("导入失败：%@", error), isError: true)
        } else {
            // If exactly one new theme appeared, select it right away so the
            // import feels immediate; otherwise just rescan quietly.
            if let imported = themeStore.fileThemes.first(where: {
                $0.name == url.deletingPathExtension().lastPathComponent
                    || $0.id == url.deletingPathExtension().lastPathComponent
            }) {
                themeID = imported.id
            }
            reportThemeAction(L("已导入主题「%@」", url.deletingPathExtension().lastPathComponent), isError: false)
        }
    }

    private func exportCurrentTheme() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: TerminalThemeStore.fileExtension)].compactMap { $0 }
        panel.nameFieldStringValue = "\(selectedTheme.id).\(TerminalThemeStore.fileExtension)"
        panel.message = L("导出当前主题为 .harbortheme 文件")
        panel.prompt = L("导出")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let error = themeStore.export(theme: selectedTheme, to: url) {
            reportThemeAction(L("导出失败：%@", error), isError: true)
        } else {
            reportThemeAction(L("已导出到 %@。若存进主题目录即成为可选主题。", url.path), isError: false)
        }
    }
}

/// Preview swatch panel for the selected theme: terminal background, a sample
/// prompt line, the 16 ANSI colors, and fg/cursor/selection chips. Themes with
/// a frosted background also show their opacity/blur.
private struct ThemePreviewPanel: View {
    let theme: TerminalTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("harbor ❯ ssh prod")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.foreground.swiftUIColor)
                .lineLimit(1)
            swatches(0..<8)
            swatches(8..<16)
            HStack(spacing: DS.Space.m) {
                chip(L("光标"), color: theme.cursor.swiftUIColor)
                if let selection = theme.selection {
                    chip(L("选中"), color: selection.swiftUIColor)
                }
                if theme.usesFrostedBackground {
                    Text(L("背景 %@ · 模糊 %@",
                           "\(Int((theme.backgroundOpacity * 100).rounded()))%",
                           "\(Int(theme.backgroundBlur))"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(DS.Space.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.background.swiftUIColor)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.medium)
                .strokeBorder(DS.Colors.separator, lineWidth: 1)
        )
        .padding(.vertical, DS.Space.xs)
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

    private func chip(_ label: String, color: SwiftUI.Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.black.opacity(0.2), lineWidth: 0.5))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 终端

private struct TerminalSettingsView: View {
    @AppStorage(TerminalFontPreference.fontNameKey) private var terminalFontName = TerminalFontPreference.defaultFontName
    @AppStorage(TerminalFontPreference.fontSizeKey) private var terminalFontSize = TerminalFontPreference.defaultFontSize
    @AppStorage(TerminalFontPreference.cjkFontNameKey) private var terminalCJKFontName = TerminalFontPreference.defaultCJKFontName
    @AppStorage("optionAsMeta") private var optionAsMeta = true
    @AppStorage("useMetalRenderer") private var useMetalRenderer = false
    @AppStorage(BackspacePreference.globalDefaultKey) private var backspaceDefaultRaw = ""
    @AppStorage("themeID") private var themeID = TerminalTheme.defaultThemeID
    @AppStorage(TerminalBackgroundPreference.storageKey) private var backgroundRaw = ""

    private static let fontSizeRange = TerminalFontPreference.minFontSize...TerminalFontPreference.maxFontSize

    /// Monospaced font families installed on this machine. `static` so the
    /// enumeration runs once for the app's lifetime, not on every rebuild of
    /// this view struct (SwiftUI recreates the value frequently).
    private static let monospacedFamilies = TerminalSettingsView.availableMonospacedFamilies()

    /// Families covering CJK ideographs (PingFang SC, Sarasa, …), computed once.
    private static let cjkFamilies = TerminalFontCascade.availableCJKFamilies()

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

                Picker("中文字体", selection: $terminalCJKFontName) {
                    Text(L("跟随系统")).tag("")
                    ForEach(cjkFontChoices, id: \.self) { family in
                        Text(family)
                            .font(.custom(family, size: 12))
                            .tag(family)
                    }
                }
                if !terminalCJKFontName.isEmpty {
                    LabeledContent("中文预览") {
                        Text("中文终端 海纳百川 123")
                            .font(.custom(terminalCJKFontName, size: terminalFontSize))
                            .lineLimit(1)
                    }
                } else {
                    Text(L("不选择时，中文等全角字符使用系统默认回退字体。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Stepper(value: $terminalFontSize, in: TerminalSettingsView.fontSizeRange, step: 0.5) {
                    HStack {
                        Text(verbatim: L("字号"))
                        Spacer()
                        Text("\(String(format: "%.1f", terminalFontSize)) pt")
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
                Picker("退格键发送", selection: $backspaceDefaultRaw) {
                    ForEach(SSHHost.BackspaceBehavior.allCases, id: \.self) { behavior in
                        Text(verbatim: behavior == .auto ? L("自动（终端默认 DEL）") : behavior.wireLabel)
                            .tag(behavior == .auto ? "" : behavior.rawValue)
                    }
                }
                Text(L("个别主机退格行为异常时，可在主机编辑窗口的「终端行为」里单独覆盖。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// Same stale-value protection for the CJK font picker.
    private var cjkFontChoices: [String] {
        var families = Self.cjkFamilies
        if !terminalCJKFontName.isEmpty && !families.contains(terminalCJKFontName) {
            families.insert(terminalCJKFontName, at: 0)
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

    /// Tiny thumbnail only. Full wallpaper decode lives in the terminal
    /// renderer; Settings must not keep a second decoded copy around.
    @State private var cachedWallpaperImage: NSImage?
    @State private var wallpaperLoadID = UUID()

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
        .onAppear { reloadWallpaperIfNeeded() }
        .onChange(of: background.imagePath) { _, _ in reloadWallpaperIfNeeded() }
        .onChange(of: background.mode) { _, _ in reloadWallpaperIfNeeded() }
        .onDisappear { dropWallpaper() }
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

    private func reloadWallpaperIfNeeded() {
        guard background.mode == .image else {
            dropWallpaper()
            return
        }
        loadWallpaperPreview()
    }

    private func dropWallpaper() {
        wallpaperLoadID = UUID()
        cachedWallpaperImage = nil
    }

    private func loadWallpaperPreview() {
        let path = background.imagePath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            cachedWallpaperImage = nil
            return
        }
        let token = UUID()
        wallpaperLoadID = token
        Task {
            let preview = await Task.detached(priority: .userInitiated) {
                Self.makePreview(at: path)
            }.value
            guard wallpaperLoadID == token else { return }
            cachedWallpaperImage = preview
        }
    }

    /// Decode only a ~104px thumbnail so Settings never holds the full bitmap.
    private static func makePreview(at path: String) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 104,
            kCGImageSourceShouldCache: false,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
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
