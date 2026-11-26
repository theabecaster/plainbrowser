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
