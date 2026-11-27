import Foundation

/// Whether a page's language is one the user reads, from iOS's preferred languages. Pure, so it
/// is tested on macOS; the language itself is recognized in WebEngine.
public enum PageLanguage {
    /// True when `page` (a BCP 47 code such as "fr", "pt-BR", "zh-Hant") is the same language as
    /// one of `preferred` (`Locale.preferredLanguages`). Regions don't matter (a reader of "en-US"
    /// reads "en-GB"); Chinese scripts do (Simplified and Traditional are read separately).
    public static func isRead(_ page: String, preferred: [String]) -> Bool {
        let pageKey = key(page)
        return preferred.contains { key($0) == pageKey }
    }

    /// The language and, for Chinese, the script: "zh-TW" and "zh-Hant-HK" are both "zh-Hant".
    static func key(_ code: String) -> String {
        let parts = code.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").map(String.init)
        guard let language = parts.first, !language.isEmpty else { return "" }
        guard language == "zh" else { return language }
        if parts.contains("hant") { return "zh-hant" }
        if parts.contains("hans") { return "zh-hans" }
        let traditionalRegions: Set<String> = ["tw", "hk", "mo"]
        return parts.contains(where: traditionalRegions.contains) ? "zh-hant" : "zh-hans"
    }

    /// The `<html lang>` value as a language code, or nil when it is empty or not a language
    /// ("x-default", "und").
    public static func declared(_ lang: String) -> String? {
        let trimmed = lang.trimmingCharacters(in: .whitespaces)
        let language = key(trimmed)
        guard (2...3).contains(language.prefix(while: { $0 != "-" }).count), language != "und",
              language.allSatisfy({ $0.isLetter || $0 == "-" })
        else { return nil }
        return trimmed
    }
}
