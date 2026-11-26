import BrowserCore
import Foundation
import Testing

@Suite struct SearchEngineTests {
    @Test func queryIsPercentEncoded() {
        let url = SearchEngine.google.resultsURL(for: "a&b=c d+e#f")
        #expect(url?.absoluteString == "https://www.google.com/search?q=a%26b%3Dc%20d%2Be%23f")
    }

    @Test func searchInputResolvesThroughEngine() {
        let input = AddressBarInput("plain browser")
        #expect(input?.destination(searchingWith: .google)?.absoluteString
            == "https://www.google.com/search?q=plain%20browser")
    }

    @Test func urlInputIgnoresEngine() {
        let input = AddressBarInput("example.com")
        #expect(input?.destination(searchingWith: .google)?.absoluteString == "https://example.com")
    }

    @Test func catalogHasTheTenEnginesWithGoogleFirstAndDefault() {
        #expect(SearchEngine.catalog.map(\.name) == [
            "Google", "DuckDuckGo", "Bing", "Brave Search", "Kagi", "Ecosia", "Startpage", "Yahoo",
            "Perplexity", "ChatGPT",
        ])
        #expect(Set(SearchEngine.catalog.map(\.id)).count == SearchEngine.catalog.count)
        #expect(FixedChoices.defaultSearchEngine == .google)
        #expect(BrowserSettings.defaults.searchEngine == .google)
        #expect(SearchEngine.builtIn(id: "kagi") == .kagi)
        #expect(SearchEngine.builtIn(id: "custom") == nil)
    }

    @Test(arguments: [
        (SearchEngine.google, "https://www.google.com/search?q=caf%C3%A9%20au%20lait"),
        (.duckDuckGo, "https://duckduckgo.com/?q=caf%C3%A9%20au%20lait"),
        (.bing, "https://www.bing.com/search?q=caf%C3%A9%20au%20lait"),
        (.brave, "https://search.brave.com/search?q=caf%C3%A9%20au%20lait"),
        (.kagi, "https://kagi.com/search?q=caf%C3%A9%20au%20lait"),
        (.ecosia, "https://www.ecosia.org/search?q=caf%C3%A9%20au%20lait"),
        (.startpage, "https://www.startpage.com/sp/search?query=caf%C3%A9%20au%20lait"),
        (.yahoo, "https://search.yahoo.com/search?p=caf%C3%A9%20au%20lait"),
        (.perplexity, "https://www.perplexity.ai/search?q=caf%C3%A9%20au%20lait"),
        (.chatGPT, "https://chatgpt.com/?q=caf%C3%A9%20au%20lait"),
    ])
    func resultsURLs(engine: SearchEngine, expected: String) {
        #expect(engine.resultsURL(for: "café au lait")?.absoluteString == expected)
    }

    @Test func enginesWithoutAWorkingEndpointUseDuckDuckGoSuggestions() {
        #expect(SearchEngine.google.suggestionSource == .google)
        #expect(SearchEngine.brave.suggestionSource == .brave)
        #expect(SearchEngine.kagi.suggestionSource == .kagi)
        #expect(SearchEngine.startpage.suggestionSource == .startpage)
        for engine in [SearchEngine.bing, .ecosia, .yahoo, .perplexity, .chatGPT, .duckDuckGo] {
            #expect(engine.suggestionSource == .duckDuckGo, "\(engine.name)")
        }
    }

    @Test func customEngineBuildsURLsAndUsesDuckDuckGoSuggestions() throws {
        let engine = try SearchEngine.custom(name: " Wiki ", template: " https://en.wikipedia.org/w/index.php?search=%s ")
        #expect(engine.name == "Wiki")
        #expect(engine.isCustom)
        #expect(engine.suggestionSource == .duckDuckGo)
        #expect(engine.resultsURL(for: "a b")?.absoluteString == "https://en.wikipedia.org/w/index.php?search=a%20b")
    }

    @Test func customEngineReplacesEveryPlaceholder() throws {
        let engine = try SearchEngine.custom(name: "X", template: "https://x.example/%s?q=%s")
        #expect(engine.resultsURL(for: "z")?.absoluteString == "https://x.example/z?q=z")
    }

    @Test(arguments: [
        ("Name", "https://example.com/search?q=", SearchEngine.TemplateError.missingPlaceholder),
        ("Name", "example.com/search?q=%s", .notAWebURL),
        ("Name", "ftp://example.com/?q=%s", .notAWebURL),
        ("Name", "javascript:alert(%s)", .notAWebURL),
        ("Name", "https:///?q=%s", .notAWebURL),
        ("  ", "https://example.com/?q=%s", .emptyName),
    ])
    func invalidCustomTemplates(name: String, template: String, error: SearchEngine.TemplateError) {
        #expect(throws: error) { try SearchEngine.custom(name: name, template: template) }
    }
}
