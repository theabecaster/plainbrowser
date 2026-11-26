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
        let data = LiveAddressBarData { SuggestionClient(http: FakeEngine(body: #"["swift.o", ["swift.org", "swift ownership"]]"#)) }
        await data.attach(database)
        data.pageVisited(url: URL(string: "https://swift.org/documentation")!, title: "Swift Docs")
        await data.flush()

        var updates: [[AddressBarSuggestion]] = []
        await data.suggestions(for: "swift.o") { updates.append($0) }

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
