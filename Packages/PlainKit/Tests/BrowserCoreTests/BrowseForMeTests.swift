@testable import BrowserCore
import Foundation
import Testing

/// Browse for Me's rules without a web view: which results page, which links are results, how
/// the sources fit the context, and the citations a draft may keep.
@Suite struct BrowseForMeTests {
    typealias Link = BrowseForMe.Link

    // MARK: Results pages

    @Test func bingUsersGetBingThenDuckDuckGoLite() throws {
        let pages = BrowseForMe.resultsPages(for: "swift & ui", engine: .bing)
        #expect(pages.map(\.engineName) == ["Bing", "DuckDuckGo"])
        #expect(pages[0].url.absoluteString == "https://www.bing.com/search?q=swift%20%26%20ui")
        #expect(pages[0].needsJavaScript)
        #expect(pages[1].url.absoluteString == "https://lite.duckduckgo.com/lite/?q=swift%20%26%20ui")
        #expect(!pages[1].needsJavaScript)
    }

    @Test func duckDuckGoAndEnginesWithoutARecipeUseTheLitePage() {
        for engine in [SearchEngine.google, .brave, .duckDuckGo, .kagi, .perplexity, .chatGPT, .yahoo] {
            let pages = BrowseForMe.resultsPages(for: "q", engine: engine)
            #expect(pages.map(\.engineName) == ["DuckDuckGo"], "\(engine.name)")
        }
        let custom = try? SearchEngine.custom(name: "Mine", template: "https://search.example/?q=%s")
        #expect(BrowseForMe.resultsPages(for: "q", engine: custom!).count == 1)
    }

    // MARK: Organic results

    @Test func adsTheEngineAndUnreadableSitesAreLeftOut() {
        let links = [
            Link(href: "https://sponsor.example/", title: "Ad", isAd: true),
            Link(href: "https://duckduckgo.com/y.js?ad_domain=x.com&u3=1", title: "Ad link"),
            Link(href: "https://duckduckgo.com/settings", title: "Settings"),
            Link(href: "https://www.youtube.com/watch?v=1", title: "Video"),
            Link(href: "https://m.facebook.com/post", title: "Post"),
            Link(href: "https://www.example.com/a", title: "  First\n result "),
            Link(href: "https://example.com/b", title: "Same site again"),
            Link(href: "mailto:me@example.com", title: "Mail"),
            Link(href: "https://other.example/", title: ""),
        ]
        let results = BrowseForMe.organicResults(links, engineHosts: ["duckduckgo.com"])
        #expect(results.map(\.url.absoluteString) == ["https://www.example.com/a", "https://other.example/"])
        #expect(results.map(\.title) == ["First result", "other.example"])
    }

    @Test func redirectLinksAreUnwrapped() {
        let ddg = Link(href: "https://duckduckgo.com/l/?uddg=https%3A%2F%2Fwebkit.org%2Fblog%2F&rut=abc", title: "WebKit")
        let google = Link(href: "https://www.google.com/url?q=https://swift.org/documentation/&sa=U", title: "Swift")
        // "a1" + base64url("https://developer.apple.com/")
        let bing = Link(href: "https://www.bing.com/ck/a?!&&p=1&u=a1aHR0cHM6Ly9kZXZlbG9wZXIuYXBwbGUuY29tLw&ntb=1", title: "Apple")
        let results = BrowseForMe.organicResults([ddg, google, bing], engineHosts: ["google.", "bing.com", "duckduckgo.com"])
        #expect(results.map(\.url.absoluteString) == [
            "https://webkit.org/blog/", "https://swift.org/documentation/", "https://developer.apple.com/",
        ])
    }

    @Test func adClicksThroughAnEngineAreLeftOut() {
        let links = [
            Link(href: "https://www.bing.com/aclick?ld=1&u=x", title: "Ad"),
            Link(href: "https://www.google.com/aclk?sa=l", title: "Ad"),
            Link(href: "https://www.googleadservices.com/pagead/aclk?x", title: "Ad"),
            Link(href: "https://news.example/story", title: "Story"),
        ]
        #expect(BrowseForMe.organicResults(links, engineHosts: []).map(\.title) == ["Story"])
    }

    @Test func engineHostsMatchEveryCountryDomain() {
        #expect(BrowseForMe.matches("www.google.co.uk", "google."))
        #expect(BrowseForMe.matches("google.com", "google."))
        #expect(!BrowseForMe.matches("googleblog.example", "google."))
        #expect(BrowseForMe.matches("m.youtube.com", "youtube.com"))
        #expect(!BrowseForMe.matches("notyoutube.com", "youtube.com"))
    }

    @Test func resultsStopAtTheLimit() {
        let links = (0..<20).map { Link(href: "https://site\($0).example/", title: "\($0)") }
        #expect(BrowseForMe.organicResults(links, engineHosts: []).count == FixedChoices.browseCandidates)
    }

    // MARK: Fitting

    @Test func shortSourcesGiveTheirRoomToLongOnes() {
        let short = String(repeating: "a", count: 100)
        let long = String(repeating: "b", count: 5_000)
        let fitted = BrowseForMe.fit([short, long, long], budget: 3_100)
        #expect(fitted[0] == short)
        #expect(fitted[1].count == 1_500)
        #expect(fitted[2].count == 1_500)
        #expect(fitted.reduce(0) { $0 + $1.count } <= 3_100)
    }

    @Test func everythingFitsWhenThereIsRoom() {
        let texts = ["one", "two two", "three three three"]
        #expect(BrowseForMe.fit(texts, budget: 10_000) == texts)
        #expect(BrowseForMe.fit([], budget: 10) == [])
        #expect(BrowseForMe.fit(["abc"], budget: 0) == [""])
    }

    @Test func excerptsEndAtAParagraphOrSentence() {
        let text = String(repeating: "x", count: 80) + ". Next sentence goes on and on."
        #expect(BrowseForMe.excerpt(text, limit: 100) == String(repeating: "x", count: 80) + ".")
        let paragraphs = String(repeating: "y", count: 90) + "\n\nSecond paragraph that is long."
        #expect(BrowseForMe.excerpt(paragraphs, limit: 100) == String(repeating: "y", count: 90))
        #expect(BrowseForMe.excerpt("short", limit: 100) == "short")
    }

    @Test func sourceRoomFollowsTheContext() {
        let small = BrowseForMe.sourceCharacters(contextTokens: 4_096)
        let large = BrowseForMe.sourceCharacters(contextTokens: 8_192)
        #expect(small == Int(Double(4_096 - 1_500) * 3))
        #expect(large > small * 2)
        #expect(BrowseForMe.sourceCharacters(contextTokens: 1_000) == 0)
    }

    @Test func condensingKeepsTheOpeningAndSpreadsOverTheRest() {
        let paragraphs = (0..<100).map { "Paragraph \($0) " + String(repeating: "w", count: 90) }
        let text = paragraphs.joined(separator: "\n\n")
        let condensed = BrowseForMe.condense(text, limit: 2_000)
        #expect(condensed.count <= 2_000)
        let kept = condensed.components(separatedBy: "\n\n")
        #expect(kept.first == paragraphs[0])
        // The opening runs in order, then picks reach the end of the page.
        #expect(kept.prefix(5) == paragraphs.prefix(5))
        let lastKept = kept.last.flatMap { paragraphs.firstIndex(of: $0) } ?? 0
        #expect(lastKept > 80)
        #expect(BrowseForMe.condense("short page", limit: 2_000) == "short page")
    }

    // MARK: Drafts

    @Test func citationsOutsideTheSourcesAreDropped() {
        let draft = SummaryDraft(title: " Title ", sections: [
            .init(heading: "Heading", points: [
                .init(text: " A point. ", sources: [2, 9, 2, 0, 1]),
                .init(text: "   ", sources: [1]),
            ]),
            .init(heading: "", points: []),
        ])
        let cleaned = draft.cleaned(sourceCount: 3)
        #expect(cleaned.title == "Title")
        #expect(cleaned.sections.count == 1)
        #expect(cleaned.sections[0].points == [.init(text: "A point.", sources: [1, 2])])
        // A page's own summary cites nothing; Browse for Me with one page read still cites it.
        #expect(draft.cleaned(sourceCount: 1, cites: false).sections[0].points[0].sources == [])
        #expect(draft.cleaned(sourceCount: 1).sections[0].points[0].sources == [1])
    }

    @Test func failuresSayWhatHappenedInPlainWords() {
        let all: [SummaryFailure] = [.noResults, .nothingReadable, .offline, .declined, .unsupportedLanguage, .unavailable, .failed]
        for failure in all {
            #expect(failure.message.hasSuffix("."))
            #expect(!failure.message.contains("Error"))
        }
        #expect(SummaryFailure.offline.canRetry)
        #expect(!SummaryFailure.declined.canRetry)
    }
}
