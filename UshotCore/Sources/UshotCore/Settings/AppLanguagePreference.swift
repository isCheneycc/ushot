import Foundation

/// In-app UI language preference (independent of the system language).
///
/// Stored under Advanced settings. The factory default is Simplified Chinese.
/// English remains the string-catalog source language; translations live in
/// `zh-Hans` localizations.
public enum AppLanguagePreference: String, Codable, CaseIterable, Sendable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public static let `default`: AppLanguagePreference = .simplifiedChinese

    public var id: String { rawValue }

    /// BCP-47 language code used for `Locale` and `AppleLanguages`.
    public var bcp47Code: String { rawValue }

    /// Native language name shown in the language picker (not localized).
    public var nativeDisplayName: String {
        switch self {
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        }
    }

    public var locale: Locale {
        Locale(identifier: bcp47Code)
    }

    /// Applies the preference so Foundation/AppKit localization reads this language.
    ///
    /// Must run before UI that uses `NSLocalizedString` / `String(localized:)` is built.
    /// Changing mid-session requires relaunch for menu-bar and other AppKit strings.
    /// Only `AppleLanguages` is overridden; `AppleLocale` is left alone so region
    /// formats stay system-controlled and invalid locale tags cannot crash launch.
    public static func apply(_ preference: AppLanguagePreference) {
        UserDefaults.standard.set([preference.bcp47Code], forKey: "AppleLanguages")
    }

    /// Reads the stored Advanced language from the settings document without constructing
    /// a full `SettingsStore` (safe at process start before `@MainActor` UI exists).
    public static func loadStoredPreference(
        defaults: UserDefaults = .standard,
        storageKey: String = ProductIdentity.settingsStorageKey
    ) -> AppLanguagePreference {
        guard let data = defaults.data(forKey: storageKey) else {
            return .default
        }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let advanced = root["advanced"] as? [String: Any],
            let raw = advanced["language"] as? String,
            let preference = AppLanguagePreference(rawValue: raw)
        else {
            return .default
        }
        return preference
    }
}
