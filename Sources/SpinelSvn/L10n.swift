import Foundation

enum Localization {
    /// "ja" or "en", resolved once at launch from the setting (or the system language).
    static let language: String = {
        let setting = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        if setting == "ja" || setting == "en" { return setting }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("ja") ? "ja" : "en"
    }()
}

/// Returns the UI string for the current language. Keys are the English texts.
func L(_ key: String) -> String {
    guard Localization.language == "ja" else { return key }
    return japanese[key] ?? key
}
