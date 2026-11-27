@testable import BrowserCore
import Testing

@Suite struct PageLanguageTests {
    @Test func regionsDontMatter() {
        #expect(PageLanguage.isRead("en-GB", preferred: ["en-US"]))
        #expect(PageLanguage.isRead("pt", preferred: ["es-US", "pt-BR"]))
        #expect(!PageLanguage.isRead("fr", preferred: ["en-US", "es-MX"]))
    }

    @Test func chineseScriptsAreReadSeparately() {
        #expect(PageLanguage.isRead("zh-TW", preferred: ["zh-Hant-US"]))
        #expect(PageLanguage.isRead("zh-CN", preferred: ["zh-Hans"]))
        #expect(!PageLanguage.isRead("zh-Hant", preferred: ["zh-Hans-CN"]))
        #expect(PageLanguage.isRead("zh", preferred: ["zh-Hans"]), "plain zh is Simplified")
    }

    @Test func declaredLanguageMustBeALanguage() {
        #expect(PageLanguage.declared("fr") == "fr")
        #expect(PageLanguage.declared(" de-DE ") == "de-DE")
        #expect(PageLanguage.declared("") == nil)
        #expect(PageLanguage.declared("und") == nil)
        #expect(PageLanguage.declared("x-default") == nil)
    }
}
