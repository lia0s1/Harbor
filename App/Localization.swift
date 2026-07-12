import Foundation
import SwiftUI
import os
import HarborKit

// MARK: - Bundle language override

/// A `Bundle` subclass that redirects every localized-string lookup to a chosen
/// `.lproj` bundle. We `object_setClass` `Bundle.main` to this so that EVERY
/// existing `Text("中文")` (which resolves `LocalizedStringKey` against
/// `Bundle.main`) and `String(localized:)` re-reads from the language the user
/// picked — without relaunching the app.
private final class LanguageBundle: Bundle, @unchecked Sendable {
    /// The `.lproj` bundle currently in force, guarded by an unfair lock.
    /// `nil` means "fall back to normal `Bundle.main` behaviour".
    ///
    /// `OSAllocatedUnfairLock` (available from macOS 13+) owns the protected
    /// value directly, so there is no separate unguarded pointer that could be
    /// read or written without holding the lock.
    static let protectedOverride = OSAllocatedUnfairLock<Bundle?>(initialState: nil)

    override func localizedString(
        forKey key: String,
        value: String?,
        table tableName: String?
    ) -> String {
        // withLock returns the bundle while holding the lock, then releases it.
        let override = LanguageBundle.protectedOverride.withLock { $0 }
        if let override {
            return override.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

// MARK: - Localization manager

/// Drives the app's live language switch.
///
/// The user picks `system / 中文 / English` in Settings; this manager:
/// 1. resolves the selection to a concrete `.lproj` (`AppLanguage`),
/// 2. points `Bundle.main`'s localized lookups at that `.lproj` (via the
///    `LanguageBundle` swizzle) so all `Text("…")` / `String(localized:)`
///    re-resolve immediately,
/// 3. exposes a `revision` that bumps on every change so the root view can
///    `.id(revision)` itself and re-render in the new language without relaunch,
/// 4. exposes `locale` so `.environment(\.locale,)` formats dates/numbers to
///    match.
@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    /// The raw stored selection (`system` / `zh-Hans` / `en`). Persisted.
    @Published var language: AppLanguage {
        didSet {
            guard oldValue != language else { return }
            UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.storageKey)
            apply()
        }
    }

    /// Bumps on every applied change; bind a root `.id(localization.revision)`.
    @Published private(set) var revision = 0

    /// The concrete `.lproj` code currently rendering (`zh-Hans` / `en`).
    @Published private(set) var resolvedCode: String

    private init() {
        let stored = UserDefaults.standard.string(forKey: AppLanguage.storageKey)
        let language = AppLanguage(storedValue: stored)
        self.language = language
        self.resolvedCode = language.resolvedLanguageCode()
        installSwizzleOnce()
        applyOverrideBundle()
    }

    /// The locale to inject via `.environment(\.locale,)`.
    var locale: Locale { Locale(identifier: resolvedCode) }

    /// The resolved `.lproj` bundle, cached so `L()` doesn't rebuild it (path
    /// lookup + `Bundle(path:)`) on every call. Recomputed only in
    /// `applyOverrideBundle()`, which runs when the language changes.
    private var cachedBundle: Bundle = .main

    /// The `.lproj` bundle for the resolved language, for manual lookups.
    var bundle: Bundle { cachedBundle }

    /// Re-resolve `system` against the current OS preference and re-apply.
    /// Call when the app becomes active in case the user changed the system
    /// language while we were backgrounded.
    func refreshForSystemChange() {
        guard language == .system else { return }
        let newCode = language.resolvedLanguageCode()
        if newCode != resolvedCode { apply() }
    }

    private func apply() {
        resolvedCode = language.resolvedLanguageCode()
        applyOverrideBundle()
        revision += 1
        objectWillChange.send()
    }

    /// Swap `Bundle.main`'s class exactly once so its string lookups route
    /// through `LanguageBundle`.
    private func installSwizzleOnce() {
        object_setClass(Bundle.main, LanguageBundle.self)
    }

    /// Point the override at the resolved `.lproj`. For `system` we still pin
    /// the resolved catalog (rather than `nil`) so the choice is deterministic
    /// and matches the injected `\.locale`.
    private func applyOverrideBundle() {
        let path = Bundle.main.path(forResource: resolvedCode, ofType: "lproj")
        let lproj = path.flatMap { Bundle(path: $0) }
        cachedBundle = lproj ?? .main
        LanguageBundle.protectedOverride.withLock { $0 = lproj }
        syncAppleLanguages()
    }

    /// AppKit resolves its OWN framework strings — the main-menu titles
    /// (文件/编辑/显示/窗口/帮助), Hide/Quit, Undo/Copy/Paste, open/save panel
    /// buttons — from this app domain's `AppleLanguages`, NOT from our
    /// `Bundle.main` swizzle. The in-window SwiftUI UI switches live; those
    /// framework-owned surfaces pick up the new language on the NEXT launch.
    /// For an explicit selection we pin `AppleLanguages`; for `system` we clear
    /// the override so the OS preference applies again.
    private func syncAppleLanguages() {
        let defaults = UserDefaults.standard
        switch language {
        case .system:
            defaults.removeObject(forKey: "AppleLanguages")
        case .zhHans, .english:
            defaults.set([resolvedCode], forKey: "AppleLanguages")
        }
    }
}

// MARK: - Dynamic-string lookup

/// Localizes a key for strings built at runtime (interpolation, error
/// messages) where a literal `Text("…")` cannot be used. Reads from the
/// manager's currently-selected `.lproj` so it tracks the live language.
///
/// The key IS the Simplified-Chinese source string (the development language),
/// matching the String Catalog. `args` fill `%@` / `%lld` placeholders.
@MainActor
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = LocalizationManager.shared.bundle.localizedString(
        forKey: key, value: key, table: nil
    )
    if args.isEmpty { return format }
    return String(format: format, locale: LocalizationManager.shared.locale, arguments: args)
}

// MARK: - Localized presentation

extension View {
    /// Re-applies the live-language environment to content that SwiftUI presents
    /// in a SEPARATE context — `.sheet` bodies most notably. The root WindowGroup
    /// injects `\.locale` + `.id(revision)` so the in-window UI tracks the
    /// language switch, but a sheet's content is hosted outside that subtree and
    /// would otherwise resolve its literal `Text("中文")` / `Section("中文")`
    /// labels against the SYSTEM locale (stale zh-Hans even when English is
    /// chosen). Applying the same trio here makes those literals resolve in the
    /// selected language and re-render the moment it changes — matching the
    /// Settings scene (HarborApp.swift).
    func localized(_ manager: LocalizationManager) -> some View {
        self
            .environmentObject(manager)
            .environment(\.locale, manager.locale)
            .id(manager.revision)
    }
}
