import BrowserCore
import Foundation
import GRDB
@testable import Storage
import Testing

@Suite struct HistoryScreenTests {
    @Test func visitsMatchingSearchesTitleAndAddressNewestFirst() async throws {
        let database = try AppDatabase.inMemory()
        try await database.apply([
            .visit(visit("https://swift.org/documentation", "Swift Docs")),
            .visit(visit("https://news.example/", "Café culture", at: 10)),
            .visit(visit("https://swift.org/documentation", "Swift Docs", at: 20)),
            .visit(visit("https://blog.example/swift-tips", "Tips", at: 30)),
        ])
        let swift = try await database.visits(matching: "swift", limit: 10)
        // Every dated visit, not one row per page.
        #expect(swift.map(\.visitedAt) == [t0 + 30, t0 + 20, t0])
        #expect(swift.allSatisfy { $0.id != nil })
        #expect(try await database.visits(matching: "cafe cul", limit: 10).map(\.url.host) == ["news.example"])
        #expect(try await database.visits(matching: "swift", limit: 2).count == 2)
        #expect(try await database.visits(matching: "zzz", limit: 10).isEmpty)
        #expect(try await database.visits(matching: "\"*:(", limit: 10).isEmpty)
        // An empty query is every visit.
        #expect(try await database.visits(matching: "  ", limit: 10).count == 4)
    }

    @Test func clearSinceKeepsOlderVisitsAndRebuildsTheirPages() async throws {
        let database = try AppDatabase.inMemory()
        let kept = "https://kept.example/"
        try await database.apply([
            .visit(visit(kept, "Kept", at: 0)),
            .visit(visit(kept, "Kept", at: 100)),
            .visit(visit("https://new.example/", "New", at: 100)),
            .visit(visit("https://old.example/", "Old", at: -100)),
        ])
        try await database.clearHistory(since: t0 + 50)

        #expect(try await database.recentVisits(limit: 10).map(\.url.host) == ["kept.example", "old.example"])
        #expect(try await database.searchHistory("new").isEmpty)
        let place = try await database.writer.read { db in
            try HistoryPlace.filter(Column("url") == URL(string: kept)!).fetchOne(db)
        }
        #expect(place?.visitCount == 1)
        #expect(place?.lastVisitedAt == t0)
        #expect(place?.frecency == Frecency.adding(visitAt: t0, to: nil))
    }

    @Test func clearSinceRestoresTheTitleOfTheNewestKeptVisit() async throws {
        let database = try AppDatabase.inMemory()
        let url = "https://news.example/today"
        try await database.apply([
            .visit(visit(url, "Monday Headlines", at: 0)),
            .visit(visit(url, "Secret Plans", at: 100)),
        ])
        #expect(try await database.searchHistory("secret").count == 1)
        try await database.clearHistory(since: t0 + 50)
        #expect(try await database.searchHistory("secret").isEmpty)
        #expect(try await database.searchHistory("monday").map(\.title) == ["Monday Headlines"])
    }

    @Test func clearSinceNilRemovesEverything() async throws {
        let database = try AppDatabase.inMemory()
        try await database.apply([.visit(visit("https://a.example/", "A"))])
        try await database.clearHistory(since: nil)
        #expect(try await database.recentVisits(limit: 10).isEmpty)
        #expect(try await database.searchHistory("a").isEmpty)
    }

    @Test func clearSinceDropsBufferedRecentVisitsOnly() async throws {
        let database = try AppDatabase.inMemory()
        let recorder = HistoryRecorder(database: database, interval: .seconds(60), batchSize: 100)
        await recorder.record(visit("https://before.example", at: -100))
        await recorder.record(visit("https://after.example", at: 100))
        try await recorder.clearHistory(since: t0)
        await recorder.flush()
        #expect(try await database.recentVisits(limit: 10).map(\.url.host) == ["before.example"])
    }

    @Test func databaseDeletesGoThroughItsRecorder() async throws {
        let database = try AppDatabase.inMemory()
        let url = URL(string: "https://buffered.example")!
        // Buffered, not on disk yet: a direct delete would miss it and the batch would bring it back.
        await database.historyRecorder.record(visit(url.absoluteString))
        try await database.deleteHistory(for: url)
        await database.historyRecorder.flush()
        #expect(try await database.recentVisits(limit: 10).isEmpty)
    }
}

@Suite struct FavoriteLookupTests {
    @Test func favoriteForURLAndRemoveByURL() async throws {
        let database = try AppDatabase.inMemory()
        let a = URL(string: "https://a.example")!
        try await database.addFavorite(url: a, title: "A")
        try await database.addFavorite(url: URL(string: "https://b.example")!, title: "B")
        #expect(try await database.favorite(for: a)?.title == "A")
        try await database.removeFavorite(url: a)
        #expect(try await database.favorite(for: a) == nil)
        #expect(try await database.favorites().map(\.position) == [0])
    }
}
