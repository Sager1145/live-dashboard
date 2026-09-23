import Foundation

/// The user's chosen translation target. `followApp` resolves from the
/// app's current display language; `off` hides all translation UI.
public enum TranslationTargetLanguage: String, CaseIterable, Codable, Sendable {
    case followApp
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en
    case ja
    case off

    /// Source language is fixed to Japanese for this version — every
    /// scraped field is official Japanese text.
    public static let sourceLanguage = Locale.Language(identifier: "ja")

    /// The concrete language to translate into, or `nil` when translation
    /// should not run at all (`off`).
    public var localeLanguage: Locale.Language? {
        switch self {
        case .off: return nil
        case .zhHans: return Locale.Language(identifier: "zh-Hans")
        case .zhHant: return Locale.Language(identifier: "zh-Hant")
        case .en: return Locale.Language(identifier: "en")
        case .ja: return Locale.Language(identifier: "ja")
        case .followApp: return Self.resolveFollowApp().localeLanguage
        }
    }

    /// Maps the app's current display language to one of the four concrete
    /// targets. Falls back to Simplified Chinese for anything unrecognised.
    static func resolveFollowApp(preferredLanguages: [String] = Locale.preferredLanguages, kitPreferredLocalizations: [String] = Bundle.kit.preferredLocalizations) -> TranslationTargetLanguage {
        let candidate = kitPreferredLocalizations.first ?? preferredLanguages.first ?? "zh-Hans"
        let lowered = candidate.lowercased()
        if lowered.hasPrefix("ja") { return .ja }
        if lowered.hasPrefix("en") { return .en }
        if lowered.hasPrefix("zh") {
            if lowered.contains("hant") || lowered.contains("-tw") || lowered.contains("-hk") { return .zhHant }
            return .zhHans
        }
        return .zhHans
    }

    /// True when this target ultimately resolves to Japanese — translation
    /// UI stays hidden in that case since source text is already Japanese.
    public var resolvesToJapanese: Bool {
        localeLanguage?.languageCode?.identifier == "ja"
    }

    public var displayName: String {
        switch self {
        case .followApp: return String(localized: "跟随 App 语言", bundle: .kit)
        case .zhHans: return String(localized: "简体中文", bundle: .kit)
        case .zhHant: return String(localized: "繁體中文", bundle: .kit)
        case .en: return String(localized: "English", bundle: .kit)
        case .ja: return String(localized: "日本語", bundle: .kit)
        case .off: return String(localized: "关闭翻译", bundle: .kit)
        }
    }
}
