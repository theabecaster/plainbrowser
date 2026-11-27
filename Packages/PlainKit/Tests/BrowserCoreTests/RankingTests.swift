import BrowserCore
import Foundation
import Testing

@Suite struct FrecencyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let halfLife = FixedChoices.frecencyHalfLife

    @Test func scoreDecaysByHalfEveryHalfLife() {
        let key = Frecency.adding(visitAt: now, to: nil)
        #expect(abs(Frecency.score(key: key, now: now) - 1) < 1e-9)
        #expect(abs(Frecency.score(key: key, now: now.addingTimeInterval(halfLife)) - 0.5) < 1e-9)
    }

    @Test func visitsAddUp() {
        var key = Frecency.adding(visitAt: now, to: nil)
        key = Frecency.adding(visitAt: now, to: key)
        key = Frecency.adding(visitAt: now.addingTimeInterval(-halfLife), to: key)
        #expect(abs(Frecency.score(key: key, now: now) - 2.5) < 1e-9)
    }

    @Test func recentBeatsOldEvenWithFewerVisits() {
        // Ten visits four half-lives ago are worth 10/16; one visit today is worth 1.
        var old: Double?
        for _ in 0..<10 { old = Frecency.adding(visitAt: now.addingTimeInterval(-4 * halfLife), to: old) }
        let recent = Frecency.adding(visitAt: now, to: nil)
        #expect(recent > old!)
    }

    @Test func frequentBeatsSlightlyMoreRecent() {
        var frequent: Double?
        for day in 1...5 { frequent = Frecency.adding(visitAt: now.addingTimeInterval(Double(-day) * 86_400), to: frequent) }
        let once = Frecency.adding(visitAt: now, to: nil)
        #expect(frequent! > once)
    }

    @Test func farFutureDatesDoNotOverflow() {
        let far = Date(timeIntervalSinceReferenceDate: 3e9)
        var key = Frecency.adding(visitAt: far, to: nil)
        key = Frecency.adding(visitAt: far, to: key)
        #expect(key.isFinite)
        #expect(abs(Frecency.score(key: key, now: far) - 2) < 1e-6)
    }
}

@Suite struct AddressBarSuggestionsTests {
    func page(_ url: String, _ title: String? = nil, frecency: Double? = nil, favorite: Bool = false) -> PageCandidate {
        PageCandidate(url: URL(string: url)!, title: title, frecency: frecency, isFavorite: favorite)
    }

    @Test func topHitComesFirstThenPagesThenSearches() {
        let result = AddressBarSuggestions.merge(
            query: "git",
            history: [
                page("https://news.example/git-tips", "Git tips", frecency: 50),
                page("https://github.com/", "GitHub", frecency: 10),
            ],
            favorites: [],
            searches: ["git", "github", "gitlab"]
        )
        #expect(result == [
            .page(url: URL(string: "https://github.com/")!, title: "GitHub", isFavorite: false),
            .page(url: URL(string: "https://news.example/git-tips")!, title: "Git tips", isFavorite: false),
            .search("github"),
            .search("gitlab"),
        ])
    }

    @Test func typedSchemeAndWwwStillFindTheTopHit() {
        let result = AddressBarSuggestions.merge(
            query: "https://www.Swift.org/doc",
            history: [page("https://other.example", frecency: 99), page("https://www.swift.org/documentation/", frecency: 1)],
            favorites: [], searches: []
        )
        #expect(result.first == .page(url: URL(string: "https://www.swift.org/documentation/")!, title: nil, isFavorite: false))
    }

    @Test func duplicatesMergeAcrossSchemeWwwSlashAndFragment() {
        let result = AddressBarSuggestions.merge(
            query: "apple",
            history: [
                page("http://www.apple.com/", "Apple", frecency: 3),
                page("https://apple.com#top", nil, frecency: 7),
            ],
            favorites: [page("https://apple.com", "Apple (fav)", favorite: true)],
            searches: []
        )
        #expect(result == [.page(url: URL(string: "https://apple.com")!, title: "Apple (fav)", isFavorite: true)])
    }

    @Test func favoritesRankAboveHistory() {
        let result = AddressBarSuggestions.merge(
            query: "news",
            history: [page("https://a.example/news", frecency: 100)],
            favorites: [page("https://b.example/news", favorite: true)],
            searches: []
        )
        let hosts = result.map { suggestion -> String? in
            if case .page(let url, _, _, _) = suggestion { url.host() } else { nil }
        }
        #expect(hosts == ["b.example", "a.example"])
    }

    @Test func pagesAndTotalAreCapped() {
        let history = (0..<10).map { page("https://site\($0).example/q", frecency: Double($0)) }
        let searches = (0..<10).map { "q \($0)" }
        let result = AddressBarSuggestions.merge(query: "q", history: history, favorites: [], searches: searches, maxPages: 3, maxTotal: 5)
        #expect(result.count == 5)
        #expect(result.prefix(3).allSatisfy { if case .page = $0 { true } else { false } })
        // Highest frecency first.
        #expect(result.first == .page(url: URL(string: "https://site9.example/q")!, title: nil, isFavorite: false))
    }

    @Test func searchesAreDedupedIgnoringCaseAndTheTypedText() {
        let result = AddressBarSuggestions.merge(
            query: "Swift", history: [], favorites: [], searches: ["swift", "Swift UI", "swift ui", " ", "swiftly"]
        )
        #expect(result == [.search("Swift UI"), .search("swiftly")])
    }

    @Test func blankQueryHasNoSuggestions() {
        #expect(AddressBarSuggestions.merge(query: "  ", history: [page("https://a.example")], favorites: [], searches: ["a"]).isEmpty)
    }
}

@Suite struct SettingsTests {
    @Test func defaultsComeFromFixedChoices() {
        #expect(BrowserSettings.defaults == BrowserSettings(searchEngine: .google, tabLayout: .above, archiveAfter: .oneDay, appearance: .system))
    }

    @Test func archiveDueness() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ArchiveAfter.oneDay.isDue(lastActive: now.addingTimeInterval(-86_400), now: now))
        #expect(!ArchiveAfter.oneDay.isDue(lastActive: now.addingTimeInterval(-86_399), now: now))
        #expect(ArchiveAfter.twelveHours.isDue(lastActive: now.addingTimeInterval(-13 * 3600), now: now))
        #expect(!ArchiveAfter.oneWeek.isDue(lastActive: now.addingTimeInterval(-6 * 86_400), now: now))
        #expect(!ArchiveAfter.never.isDue(lastActive: .distantPast, now: now))
    }
}
