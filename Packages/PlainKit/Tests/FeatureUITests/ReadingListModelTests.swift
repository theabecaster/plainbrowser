import BrowserCore
@testable import FeatureUI
import Foundation
import Storage
import Testing

@MainActor
@Suite struct ReadingListModelTests {
    private func database(_ titles: [String]) async throws -> AppDatabase {
        let database = try AppDatabase.inMemory()
        for (index, title) in titles.enumerated() {
            try await database.saveForLater(
                SavedPage(url: URL(string: "https://news.example/\(index)")!, title: title,
                          copy: Data("{}".utf8), copyLength: 2_500),
                at: Date(timeIntervalSince1970: 1_000 + Double(index))
            )
        }
        return database
    }

    @Test func loadsUnreadNewestFirstWithSiteAndReadingTime() async throws {
        let model = ReadingListModel(store: try await database(["Old", "New"]))
        await model.load()
        #expect(model.isLoaded)
        #expect(model.unread.map(\.title) == ["New", "Old"])
        #expect(model.read.isEmpty)
        #expect(model.unread.first?.detail == "news.example · 2 min")
        #expect(model.unread.first?.hasCopy == true)
    }

    @Test func openingMarksReadAndTheRowMovesToRead() async throws {
        let store = try await database(["A", "B"])
        let model = ReadingListModel(store: store)
        await model.load()
        let row = try #require(model.unread.first)
        model.opened(row)
        #expect(model.unread.map(\.title) == ["A"])
        #expect(model.read.map(\.title) == ["B"])
        // The write lands, and a fresh load agrees.
        await model.load()
        #expect(model.read.map(\.title) == ["B"])
        #expect(try await store.readingListItem(for: row.url)?.isRead == true)
    }

    @Test func toggleAndDeleteAreWrittenInOrder() async throws {
        let store = try await database(["A", "B"])
        let model = ReadingListModel(store: store)
        await model.load()
        let b = try #require(model.unread.first)
        model.toggleRead(b)
        #expect(model.read.map(\.title) == ["B"])
        model.toggleRead(try #require(model.read.first))
        #expect(model.read.isEmpty)
        model.delete(try #require(model.unread.first { $0.title == "A" }))
        #expect(model.unread.map(\.title) == ["B"])
        await model.load()
        #expect(model.unread.map(\.title) == ["B"])
        #expect(model.read.isEmpty)
        #expect(try await store.readingList().count == 1)
    }

    @Test func searchFindsByTitle() async throws {
        let model = ReadingListModel(store: try await database(["Tide Tables", "Slow Software"]))
        await model.load()
        model.query = "tide"
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.unread.map(\.title) == ["Tide Tables"])
    }
}
