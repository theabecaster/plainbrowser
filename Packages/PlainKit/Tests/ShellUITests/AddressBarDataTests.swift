import BrowserCore
import Foundation
@testable import ShellUI
import Storage
import Testing

@MainActor
struct AddressBarDataTests {
    @Test func worksEmptyBeforeTheDatabaseOpens() async {
        let data = LiveAddressBarData()
        #expect(data.searchEngine == FixedChoices.defaultSearchEngine)
        #expect(await data.favorites().isEmpty)
        // Recording before attach is a no-op, not a crash.
        data.pageVisited(url: URL(string: "https://example.com")!, title: "Example")
    }

    @Test func favoritesComeFromTheDatabaseInOrder() async throws {
        let database = try AppDatabase.inMemory()
        try await database.addFavorite(url: URL(string: "https://a.example")!, title: "A")
        try await database.addFavorite(url: URL(string: "https://b.example")!, title: nil)
        let data = LiveAddressBarData()
        await data.attach(database)
        let favorites = await data.favorites()
        #expect(favorites.map(\.url.absoluteString) == ["https://a.example", "https://b.example"])
        #expect(favorites.first?.title == "A")
    }

    @Test func visitedPagesComeFirstThenEngineSuggestions() async throws {
        let database = try AppDatabase.inMemory()
        let data = LiveAddressBarData { SuggestionClient(http: FakeEngine(body: #"["swift docs", ["swift.org", "swift ownership"]]"#)) }
        await data.attach(database)
        data.pageVisited(url: URL(string: "https://swift.org/documentation")!, title: "Swift Docs")
        await data.flush()

        var updates: [[AddressBarSuggestion]] = []
        // Words, not an address: "swift.o" would be held back from the engine (SuggestionPolicy).
        await data.suggestions(for: "swift docs") { updates.append($0) }

        #expect(updates.count == 2)
        #expect(updates.first == [.page(url: URL(string: "https://swift.org/documentation")!, title: "Swift Docs", isFavorite: false)])
        #expect(updates.last?.dropFirst() == [.search("swift.org"), .search("swift ownership")])
    }

    @Test func savedSettingsTakeEffectForTheNextSearch() async throws {
        let database = try AppDatabase.inMemory()
        let data = LiveAddressBarData()
        await data.attach(database)
        let store = LiveSettingsStore(database: database) { data.apply($0) }
        var settings = try await store.settings()
        settings.searchEngine = .duckDuckGo
        settings.archiveAfter = .oneWeek
        try await store.saveSettings(settings)
        #expect(data.searchEngine == .duckDuckGo)
        #expect(data.settings.archiveAfter == .oneWeek)
        // Stored too, for the next launch.
        #expect(try await database.settings().searchEngine == .duckDuckGo)
        #expect(AddressBarInput("plain browser")?.destination(searchingWith: data.searchEngine)?.host() == "duckduckgo.com")
    }

    @Test func favoritesAreAddedAndRemovedByAddress() async throws {
        let database = try AppDatabase.inMemory()
        let data = LiveAddressBarData()
        let url = URL(string: "https://a.example/page")!
        #expect(await data.setFavorite(true, url: url, title: "A") == false, "nothing to write to before attach")
        await data.attach(database)
        #expect(await data.isFavorite(url) == false)
        #expect(await data.setFavorite(true, url: url, title: "  "))
        #expect(await data.isFavorite(url))
        #expect(await data.favorites().first?.title == nil, "a blank title falls back to the address")
        #expect(await data.setFavorite(false, url: url, title: nil))
        #expect(await data.isFavorite(url) == false)
    }

    @Test func historyGoesThroughTheDatabaseRecorder() async throws {
        let database = try AppDatabase.inMemory()
        let data = LiveAddressBarData()
        await data.attach(database)
        let url = URL(string: "https://example.com/x")!
        data.pageVisited(url: url, title: nil)
        data.pageTitleChanged(url: url, title: "Example X")
        await data.flush()
        #expect(try await database.visits(matching: "example x", limit: 10).map(\.title) == ["Example X"])
    }

    @Test func historyScreenSeesAndDeletesVisitsStillQueuedInTheShell() async throws {
        let database = try AppDatabase.inMemory()
        let data = LiveAddressBarData()
        await data.attach(database)
        let sheets = FeatureSheets(addressBar: data)
        sheets.attach(database)
        let store = try #require(sheets.makeHistoryStore())

        let url = URL(string: "https://just.example/now")!
        data.pageVisited(url: url, title: "Just Now")
        // No flush and no wait: the screen still shows the page.
        #expect(try await store.visits(matching: "", limit: 10).map(\.url) == [url])

        data.pageVisited(url: url, title: "Again")
        try await store.deleteHistory(for: url)
        await data.flush()
        #expect(try await database.recentVisits(limit: 10).isEmpty, "a queued visit must not come back after a delete")

        data.pageVisited(url: url, title: "Third")
        try await store.clearHistory(since: nil)
        await data.flush()
        #expect(try await database.recentVisits(limit: 10).isEmpty)
    }

    @Test func settingsModelIsSharedAcrossPresentations() async throws {
        let database = try AppDatabase.inMemory()
        let sheets = FeatureSheets(addressBar: LiveAddressBarData())
        #expect(sheets.makeSettingsModel() == nil, "nothing before the database opens")
        sheets.attach(database)
        let first = try #require(sheets.makeSettingsModel())
        #expect(sheets.makeSettingsModel() === first)
    }

    @Test func typedVisitsAndPickedSuggestionsRankFirst() async throws {
        let database = try AppDatabase.inMemory()
        let data = LiveAddressBarData { SuggestionClient(http: FakeEngine(body: #"["x", []]"#)) }
        await data.attach(database)
        let linked = URL(string: "https://example.com/linked")!
        let typed = URL(string: "https://example.com/typed")!
        // Same visit count; the typed one weighs more.
        data.pageVisited(url: linked, title: "Example Page")
        data.pageVisited(url: typed, title: "Example Page", kind: .typed)
        await data.flush()
        var pages: [URL] = []
        await data.suggestions(for: "example page") { updates in
            pages = updates.compactMap { if case .page(let url, _, _) = $0 { url } else { nil } }
        }
        #expect(pages.first == typed)

        // Picking the other page for an input makes it first for that input.
        data.suggestionPicked(input: "example page", url: linked)
        await data.flush()
        await data.suggestions(for: "example page") { updates in
            pages = updates.compactMap { if case .page(let url, _, _) = $0 { url } else { nil } }
        }
        #expect(pages.first == linked)
    }

    @Test func onlyWebPagesAreRecorded() {
        #expect(LiveAddressBarData.isRecordable(URL(string: "https://example.com")!))
        #expect(LiveAddressBarData.isRecordable(URL(string: "http://localhost:8080/a")!))
        #expect(!LiveAddressBarData.isRecordable(URL(string: "about:blank")!))
    }
}

/// An engine endpoint that answers every request with `body`, without the network.
private struct FakeEngine: HTTPLoading {
    let body: String

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}
