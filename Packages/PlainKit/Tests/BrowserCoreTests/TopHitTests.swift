import BrowserCore
import Foundation
import Testing

@Suite struct TopHitTests {
    func page(_ url: String, _ title: String? = nil, frecency: Double? = nil, adaptive: Double? = nil) -> PageCandidate {
        PageCandidate(url: URL(string: url)!, title: title, frecency: frecency, isFavorite: false, adaptiveUse: adaptive)
    }

    func urls(_ suggestions: [AddressBarSuggestion]) -> [String] {
        suggestions.compactMap { if case .page(let url, _, _) = $0 { url.absoluteString } else { nil } }
    }

    @Test func siteRootBeatsDeepPagesWhileTypingAHost() {
        let history = [
            page("https://github.com/apple/swift", "apple/swift", frecency: 90),
            page("https://github.com/", "GitHub", frecency: 5),
        ]
        for typed in ["g", "git", "github.co", "GitHub.com"] {
            let result = AddressBarSuggestions.merge(query: typed, history: history, favorites: [], searches: [])
            #expect(urls(result).first == "https://github.com/", "\(typed)")
        }
    }

    @Test func siteIsMadeFromADeepPageWhenTheRootWasNeverVisited() {
        let result = AddressBarSuggestions.merge(
            query: "git",
            history: [page("https://www.github.com/apple/swift?tab=readme#top", "apple/swift", frecency: 9)],
            favorites: [], searches: []
        )
        #expect(urls(result) == ["https://www.github.com/", "https://www.github.com/apple/swift?tab=readme#top"])
    }

    @Test func onceThePathStartsTheBestMatchingPageWins() {
        let history = [
            page("https://github.com/", "GitHub", frecency: 50),
            page("https://github.com/apple/swift", "apple/swift", frecency: 10),
            page("https://github.com/apple/swift-testing", "swift-testing", frecency: 20),
        ]
        let result = AddressBarSuggestions.merge(query: "github.com/apple/swift", history: history, favorites: [], searches: [])
        #expect(urls(result).first == "https://github.com/apple/swift-testing")
    }

    @Test func textThatOnlyMatchesAPathIsNotASite() {
        // "news.example/git-tips" starts with "news", so "news" gets the site; "git" matches no host.
        let history = [page("https://news.example/git-tips", "Git tips", frecency: 50)]
        #expect(urls(AddressBarSuggestions.merge(query: "news", history: history, favorites: [], searches: [])).first
            == "https://news.example/")
        #expect(urls(AddressBarSuggestions.merge(query: "git", history: history, favorites: [], searches: []))
            == ["https://news.example/git-tips"])
    }

    @Test func thePageLastPickedForThisInputComesFirst() {
        let history = [
            page("https://github.com/", "GitHub", frecency: 50),
            page("https://gist.github.com/me/notes", "Notes", frecency: 1, adaptive: 1.9),
            page("https://gitlab.com/", "GitLab", frecency: 5, adaptive: 1),
        ]
        let result = AddressBarSuggestions.merge(query: "gi", history: history, favorites: [], searches: [])
        #expect(urls(result) == ["https://gist.github.com/me/notes", "https://github.com/", "https://gitlab.com/"])
    }

    @Test func adaptiveUseSurvivesMergingVariants() {
        let result = AddressBarSuggestions.merge(
            query: "ex",
            history: [
                page("https://example.com/", "Example", frecency: 80),
                page("https://other.example/a", nil, frecency: 1),
                page("http://other.example/a#x", nil, frecency: nil, adaptive: 2),
            ],
            favorites: [], searches: []
        )
        #expect(urls(result).first == "https://other.example/a")
    }

    @Test func typedVisitsWeighMoreThanLinks() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var linked: Double?
        for _ in 0..<3 { linked = Frecency.adding(visitAt: now, weight: VisitKind.link.weight, to: linked) }
        let typed = Frecency.adding(visitAt: now, weight: VisitKind.typed.weight, to: nil)
        #expect(typed > linked!)
        #expect(abs(Frecency.score(key: typed, now: now) - FixedChoices.typedVisitWeight) < 1e-9)
    }
}
