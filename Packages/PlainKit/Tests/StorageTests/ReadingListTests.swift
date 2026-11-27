import BrowserCore
import Foundation
@testable import Storage
import Testing

@Suite struct ReadingListTests {
    private func page(_ path: String, _ title: String, copy: String? = nil) -> SavedPage {
        SavedPage(
            url: URL(string: "https://news.example/\(path)")!, title: title, siteName: "News", excerpt: "First lines",
            copy: copy.map { Data($0.utf8) }, copyLength: copy?.count
        )
    }

    @Test func savingIsUnreadNewestFirstAndSavingAgainMovesItUp() async throws {
        let database = try AppDatabase.inMemory()
        let now = Date()
        let first = try await database.saveForLater(page("a", "Alpha"), at: now.addingTimeInterval(-60))
        try await database.saveForLater(page("b", "Beta"), at: now)
        #expect(try await database.readingList().map(\.title) == ["Beta", "Alpha"])
        try await database.setReadingListItemRead(id: first.id!, at: now)
        // Read pages follow the unread ones.
        #expect(try await database.readingList().map(\.title) == ["Beta", "Alpha"])
        #expect(try await database.readingList().map(\.isRead) == [false, true])
        #expect(try await database.hasUnreadReadingList())

        // Saved again: unread, on top, same row.
        let again = try await database.saveForLater(page("a", "Alpha 2"), at: now.addingTimeInterval(60))
        #expect(again.id == first.id)
        #expect(try await database.readingList().map(\.title) == ["Alpha 2", "Beta"])
        #expect(try await database.readingList().allSatisfy { !$0.isRead })
    }

    @Test func theCopyRoundTripsCompressedAndGoesWithItsItem() async throws {
        let database = try AppDatabase.inMemory()
        let article = String(repeating: "<p>Plain words for a long read.</p>", count: 500)
        let item = try await database.saveForLater(page("a", "Alpha", copy: article))
        #expect(item.hasCopy)
        #expect(item.readingMinutes == max(1, Int((Double(article.count) / 1_250).rounded())))
        let url = URL(string: "https://news.example/a")!
        #expect(try await database.savedCopy(for: url) == Data(article.utf8))
        let stored = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT length(data) FROM readingListCopy")
        }
        #expect((stored ?? .max) < article.utf8.count / 4, "the copy is stored compressed")

        // Saved again as a link only (no article this time): the copy stays.
        try await database.saveForLater(page("a", "Alpha"))
        #expect(try await database.savedCopy(for: url) == Data(article.utf8))

        try await database.removeFromReadingList(url: url)
        #expect(try await database.readingListItem(for: url) == nil)
        #expect(try await database.savedCopy(for: url) == nil)
        let copies = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM readingListCopy")
        }
        #expect(copies == 0, "the copy is deleted with its item")
    }

    @Test func searchMatchesTitleAndAddressWithDiacriticsFolded() async throws {
        let database = try AppDatabase.inMemory()
        try await database.saveForLater(page("cafe-guide", "Le Guide du Café"))
        try await database.saveForLater(page("tides", "How Tides Work"))
        #expect(try await database.readingList(matching: "cafe").map(\.title) == ["Le Guide du Café"])
        #expect(try await database.readingList(matching: "news.example/tid").map(\.title) == ["How Tides Work"])
        #expect(try await database.readingList(matching: "nothing").isEmpty)
    }

    @Test func marksReadOnlyWhenUnreadAndRemovesById() async throws {
        let database = try AppDatabase.inMemory()
        let item = try await database.saveForLater(page("a", "Alpha"))
        let url = URL(string: "https://news.example/a")!
        let readAt = Date(timeIntervalSince1970: 1_000_000)
        try await database.markReadingListRead(url: url, at: readAt)
        try await database.markReadingListRead(url: url, at: readAt.addingTimeInterval(500))
        #expect(try await database.readingListItem(for: url)?.readAt == readAt, "the first read is kept")
        try await database.setReadingListItemRead(id: item.id!, at: nil)
        #expect(try await database.readingListItem(for: url)?.isRead == false)
        try await database.removeReadingListItem(id: item.id!)
        #expect(try await database.readingList().isEmpty)
    }

    @Test func marksReadBothListsInOneRead() async throws {
        let database = try AppDatabase.inMemory()
        let url = URL(string: "https://news.example/a")!
        #expect(try await database.marks(for: url) == (false, false))
        try await database.addFavorite(url: url, title: "A")
        try await database.saveForLater(page("a", "Alpha"))
        #expect(try await database.marks(for: url) == (true, true))
    }

    @Test func unreadSavedPagesRankRightAfterFavoritesInTheAddressBar() async throws {
        let database = try AppDatabase.inMemory()
        // A page visited often, and a saved page never visited.
        var changes: [HistoryChange] = []
        for _ in 0..<10 {
            changes.append(.visit(HistoryVisit(url: URL(string: "https://ocean.example/tides-often")!, title: "Tides Often", visitedAt: Date())))
        }
        try await database.apply(changes)
        try await database.saveForLater(SavedPage(url: URL(string: "https://slow.example/tides")!, title: "Tides, Slowly"))
        let read = try await database.saveForLater(SavedPage(url: URL(string: "https://done.example/tides")!, title: "Tides Done"))
        try await database.setReadingListItemRead(id: read.id!, at: Date())

        let candidates = try await database.addressBarCandidates(for: "tides")
        #expect(candidates.saved.count == 2)
        #expect(candidates.saved.first { $0.url.host() == "slow.example" }?.isSaved == true)
        #expect(candidates.saved.first { $0.url.host() == "done.example" }?.isSaved == false, "read pages are plain matches")
        let merged = AddressBarSuggestions.merge(
            query: "tides", history: candidates.history, favorites: candidates.favorites, saved: candidates.saved,
            searches: []
        )
        #expect(merged.first == .page(url: URL(string: "https://slow.example/tides")!, title: "Tides, Slowly", isFavorite: false, isSaved: true))
    }

    @Test func migrationAddsTheReadingListToAnExistingDatabase() async throws {
        // Every migration runs in order on an empty database; the reading list's tables exist after.
        let database = try AppDatabase.inMemory()
        let tables = try await database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE name LIKE 'readingList%' ORDER BY name")
        }
        #expect(tables.contains("readingListItem"))
        #expect(tables.contains("readingListCopy"))
        #expect(tables.contains("readingListSearch"))
    }
}
