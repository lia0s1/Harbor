import Foundation

/// The app's user-selectable interface language.
///
/// Pure data + resolution logic so it stays testable and UI-framework free;
/// the app layer (LocalizationManager) maps a resolved code to the matching
/// `.lproj` bundle and drives the live UI switch.
///
/// `system` follows the OS preferred languages; `zhHans` / `english` force a
/// specific catalog regardless of the system setting.
public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case zhHans = "zh-Hans"
    case english = "en"

    /// Persisted under this UserDefaults key.
    public static let storageKey = "appLanguage"
    public static let defaultValue = AppLanguage.system

    /// The languages the app actually ships catalogs for, in display order.
    /// `system` is intentionally first (it is the default).
    public static let selectable: [AppLanguage] = [.system, .zhHans, .english]

    /// `.lproj` codes the bundle is localized into (excludes `system`).
    public static let bundleLanguageCodes = ["zh-Hans", "en"]

    /// Maps an arbitrary stored raw value back to a known case, tolerating
    /// legacy / corrupt values by falling back to `.system`.
    public init(storedValue: String?) {
        self = AppLanguage(rawValue: storedValue ?? "") ?? .system
    }

    /// The concrete `.lproj` language code this selection resolves to, given
    /// the system's ordered preferred languages. `system` resolves to the
    /// first preferred language that the app ships a catalog for, else falls
    /// back to the development language `zh-Hans`.
    ///
    /// - Parameter preferredLanguages: the OS's ordered language identifiers
    ///   (e.g. `["en-US", "zh-Hans-CN"]`), as `Locale.preferredLanguages`.
    public func resolvedLanguageCode(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        switch self {
        case .zhHans:
            return "zh-Hans"
        case .english:
            return "en"
        case .system:
            return AppLanguage.bestSupportedCode(for: preferredLanguages)
        }
    }

    /// Picks the first preferred language whose base/script matches one of the
    /// shipped catalogs. Chinese in any region/script maps to `zh-Hans`;
    /// English (or anything unrecognized) maps to `en`. Defaults to `zh-Hans`
    /// (the development language) when the list is empty.
    static func bestSupportedCode(for preferredLanguages: [String]) -> String {
        for raw in preferredLanguages {
            let lower = raw.lowercased()
            if lower.hasPrefix("zh") { return "zh-Hans" }
            if lower.hasPrefix("en") { return "en" }
        }
        // Nothing matched a shipped catalog: prefer the development language so
        // a first run with e.g. a French system still gets a coherent UI.
        return preferredLanguages.isEmpty ? "zh-Hans" : "en"
    }

    /// Display label for the picker, in the language's own script so it is
    /// recognizable regardless of the current UI language.
    public var nativeLabel: String {
        switch self {
        case .system: return "system"   // localized by the catalog at the call site
        case .zhHans: return "中文"
        case .english: return "English"
        }
    }
}
