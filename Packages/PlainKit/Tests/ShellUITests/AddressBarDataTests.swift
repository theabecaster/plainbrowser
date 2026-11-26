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

    @Test func visitedPagesBecomeSuggestions() async throws {
        let database = try AppDatabase.inMemory()
        let data = LiveAddressBarData()
        await data.attach(database)
        data.pageVisited(url: URL(string: "https://swift.org/documentation")!, title: "Swift Docs")
        // Give the queued record a turn, then write it.
        try await Task.sleep(for: .milliseconds(50))
        await data.flush()

        var first: [AddressBarSuggestion]?
        let task = Task {
            await data.suggestions(for: "swift.o") { if first == nil { first = $0 } }
        }
        // The engine request may fail without a network; the local pass is all this test needs.
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = await task.value
        let pages = (first ?? []).compactMap { suggestion -> URL? in
            if case .page(let url, _, _) = suggestion { return url }
            return nil
        }
        #expect(pages.map(\.absoluteString) == ["https://swift.org/documentation"])
    }

    @Test func onlyWebPagesAreRecorded() {
        #expect(LiveAddressBarData.isRecordable(URL(string: "https://example.com")!))
        #expect(LiveAddressBarData.isRecordable(URL(string: "http://localhost:8080/a")!))
        #expect(!LiveAddressBarData.isRecordable(URL(string: "about:blank")!))
    }
}
