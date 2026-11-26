import BrowserCore
import Foundation
@testable import Storage
import Testing

@Suite struct FavoritesTests {
    @Test func addIsOrderedAndIdempotent() async throws {
        let database = try AppDatabase.inMemory()
        let a = try await database.addFavorite(url: URL(string: "https://a.example")!, title: "A")
        try await database.addFavorite(url: URL(string: "https://b.example")!, title: "B")
        let again = try await database.addFavorite(url: URL(string: "https://a.example")!, title: "A2")
        #expect(again == a)
        #expect(try await database.favorites().map(\.title) == ["A", "B"])
        #expect(try await database.favorites().map(\.position) == [0, 1])
    }

    @Test func moveRenameAndRemoveKeepPositionsDense() async throws {
        let database = try AppDatabase.inMemory()
        var ids: [Int64] = []
        for name in ["a", "b", "c", "d"] {
            ids.append(try await database.addFavorite(url: URL(string: "https://\(name).example")!, title: name).id!)
        }
        try await database.moveFavorite(id: ids[3], to: 0)
        #expect(try await database.favorites().map(\.title) == ["d", "a", "b", "c"])
        try await database.moveFavorite(id: ids[3], to: 99)
        #expect(try await database.favorites().map(\.title) == ["a", "b", "c", "d"])
        try await database.removeFavorite(id: ids[1])
        try await database.renameFavorite(id: ids[2], title: "C")
        let favorites = try await database.favorites()
        #expect(favorites.map(\.title) == ["a", "C", "d"])
        #expect(favorites.map(\.position) == [0, 1, 2])
    }

    @Test func addressBarCandidatesIncludeMatchingFavoritesWithFrecency() async throws {
        let database = try AppDatabase.inMemory()
        try await database.addFavorite(url: URL(string: "https://news.example/")!, title: "Morning Café")
        try await database.addFavorite(url: URL(string: "https://other.example/")!, title: "Other")
        try await database.record(visit("https://news.example/", "News"))

        let candidates = try await database.addressBarCandidates(for: "cafe morn")
        #expect(candidates.favorites.map(\.url.host) == ["news.example"])
        #expect(candidates.favorites.first?.isFavorite == true)
        #expect(candidates.favorites.first?.frecency != nil)
        #expect(candidates.history.isEmpty)

        // One letter matches the start of the address only, never title words.
        #expect(try await database.addressBarCandidates(for: "m").favorites.isEmpty)
        #expect(try await database.addressBarCandidates(for: "N").favorites.map(\.url.host) == ["news.example"])

        let byAddress = try await database.addressBarCandidates(for: "news")
        #expect(byAddress.favorites.count == 1)
        #expect(byAddress.history.map(\.url.host) == ["news.example"])
    }
}

@Suite struct FaviconTests {
    @Test func saveFetchAndPrune() async throws {
        let database = try AppDatabase.inMemory()
        try await database.saveFavicon(Favicon(host: "Apple.com", data: Data([1, 2]), updatedAt: t0))
        try await database.saveFavicon(Favicon(host: "old.example", data: Data([3]), updatedAt: t0.addingTimeInterval(-100)))
        #expect(try await database.favicon(forHost: "APPLE.COM")?.data == Data([1, 2]))

        try await database.saveFavicon(Favicon(host: "apple.com", data: Data([9]), updatedAt: t0))
        #expect(try await database.favicon(forHost: "apple.com")?.data == Data([9]))

        try await database.removeFavicons(updatedBefore: t0.addingTimeInterval(-50))
        #expect(try await database.favicon(forHost: "old.example") == nil)
        try await database.clearFavicons()
        #expect(try await database.favicon(forHost: "apple.com") == nil)
    }
}

@Suite struct SettingsStoreTests {
    @Test func freshDatabaseHasDefaults() async throws {
        let database = try AppDatabase.inMemory()
        #expect(try await database.settings() == .defaults)
        #expect(try await database.savedCustomSearchEngine() == nil)
    }

    @Test func settingsRoundTrip() async throws {
        let database = try AppDatabase.inMemory()
        let settings = BrowserSettings(searchEngine: .kagi, tabLayout: .sideTabs, archiveAfter: .never)
        try await database.saveSettings(settings)
        #expect(try await database.settings() == settings)
    }

    @Test func customEngineIsKeptAfterSwitchingAway() async throws {
        let database = try AppDatabase.inMemory()
        let custom = try SearchEngine.custom(name: "Wiki", template: "https://en.wikipedia.org/w/index.php?search=%s")
        try await database.saveSettings(BrowserSettings(searchEngine: custom, tabLayout: .regular, archiveAfter: .oneDay))
        #expect(try await database.settings().searchEngine == custom)

        try await database.saveSettings(.defaults)
        #expect(try await database.settings().searchEngine == .google)
        #expect(try await database.savedCustomSearchEngine() == custom)
    }

    @Test func unknownStoredValuesFallBackToDefaults() async throws {
        let database = try AppDatabase.inMemory()
        try await database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO setting (key, value) VALUES
                ('searchEngine', 'altavista'), ('tabLayout', 'ribbon'), ('archiveAfter', 'fortnight')
                """)
        }
        #expect(try await database.settings() == .defaults)

        try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE setting SET value = 'custom' WHERE key = 'searchEngine';
                INSERT INTO setting (key, value) VALUES ('customSearchEngine', '{"name":"Bad","template":"ftp://x/%s"}');
                """)
        }
        #expect(try await database.settings().searchEngine == .google)
    }
}
