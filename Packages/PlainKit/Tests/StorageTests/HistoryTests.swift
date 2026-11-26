import BrowserCore
import Foundation
import GRDB
@testable import Storage
import Testing

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func visit(_ url: String, _ title: String? = nil, at offset: TimeInterval = 0) -> HistoryVisit {
    HistoryVisit(url: URL(string: url)!, title: title, visitedAt: t0.addingTimeInterval(offset))
}

@Suite struct MigrationTests {
    @Test func v1VisitsAreCarriedIntoSearchablePlaces() async throws {
        let queue = try DatabaseQueue()
        // Build the database as the first release left it.
        try AppDatabase.migrator.migrate(queue, upTo: "v1.history")
        try await queue.write { db in
            for (url, title, offset) in [
                ("https://github.com/apple/swift", "Swift", 0.0),
                ("https://github.com/apple/swift", nil, 60),
                ("https://www.example.com/", "Example", 120),
            ] {
                try db.execute(
                    sql: "INSERT INTO historyVisit (url, title, visitedAt) VALUES (?, ?, ?)",
                    arguments: [url, title, t0.addingTimeInterval(offset)]
                )
            }
        }
        try AppDatabase.migrator.migrate(queue)

        let places = try await queue.read { db in try HistoryPlace.order(Column("url")).fetchAll(db) }
        #expect(places.map(\.visitCount) == [2, 1])
        #expect(places.map(\.title) == ["Swift", "Example"])
        #expect(places.map(\.address) == ["github.com/apple/swift", "example.com"])

        let found = try await queue.read { db in
            try AppDatabase.historyMatches(HistoryQuery("git sw").pattern!, addressPrefix: nil, limit: 5, in: db)
        }
        #expect(found.map(\.url.absoluteString) == ["https://github.com/apple/swift"])
    }

    @Test func everyMigrationRunsOnAFileDatabase() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "plain-migrate-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await AppDatabase.open(at: folder.appending(path: "Plain.sqlite"))
        // Reopening an up-to-date database is a no-op.
        let database = try await AppDatabase.open(at: folder.appending(path: "Plain.sqlite"))
        let applied = try await database.writer.read { db in try AppDatabase.migrator.appliedMigrations(db) }
        #expect(applied == AppDatabase.migrator.migrations)
    }
}

@Suite struct HistoryTests {
    @Test func recordedVisitsComeBackNewestFirst() async throws {
        let database = try AppDatabase.inMemory()
        try await database.record(visit("https://a.example", "A"))
        try await database.record(visit("https://b.example", at: 60))

        let visits = try await database.recentVisits(limit: 10)
        #expect(visits.map(\.url.host) == ["b.example", "a.example"])
        #expect(visits.allSatisfy { $0.id != nil })
        #expect(try await database.recentVisits(limit: 1).count == 1)
    }

    @Test func prefixSearchMatchesTitleAndAddress() async throws {
        let database = try AppDatabase.inMemory()
        try await database.apply([
            .visit(visit("https://github.com/apple/swift-testing", "Swift Testing")),
            .visit(visit("https://www.swift.org/documentation/", "Documentation")),
            .visit(visit("https://news.example/", "Café culture")),
        ])
        func urls(_ text: String) async throws -> Set<String> {
            Set(try await database.searchHistory(text, limit: 10).map(\.url.absoluteString))
        }
        #expect(try await urls("swi") == ["https://github.com/apple/swift-testing", "https://www.swift.org/documentation/"])
        #expect(try await urls("swift doc") == ["https://www.swift.org/documentation/"])
        #expect(try await urls("git") == ["https://github.com/apple/swift-testing"])
        #expect(try await urls("cafe") == ["https://news.example/"])
        #expect(try await urls("CAFÉ cul") == ["https://news.example/"])
        #expect(try await urls("www").isEmpty)
        #expect(try await urls("https").isEmpty)
        #expect(try await urls("zzz").isEmpty)
        #expect(try await urls("  ").isEmpty)
        #expect(try await urls("\"*:(") .isEmpty)
        // One character matches only addresses that start with it, never title words.
        #expect(try await urls("s") == ["https://www.swift.org/documentation/"])
        #expect(try await urls("G") == ["https://github.com/apple/swift-testing"])
        #expect(try await urls("c").isEmpty)
        #expect(try await urls("/").isEmpty)
        // Typed schemes and www. are dropped, as the index holds addresses without them.
        #expect(try await urls("https://www.swift.org/doc") == ["https://www.swift.org/documentation/"])
        #expect(try await urls("HTTP://github.com/apple") == ["https://github.com/apple/swift-testing"])
    }

    @Test func addressPrefixMatchesAreNotCrowdedOutByFrecency() async throws {
        let database = try AppDatabase.inMemory()
        var changes: [HistoryChange] = (0..<6).flatMap { index in
            (0..<10).map { _ in .visit(visit("https://blog.example/git-tip-\(index)", "Git tip \(index)")) }
        }
        changes.append(.visit(visit("https://github.com/", "GitHub", at: -30 * 86_400)))
        try await database.apply(changes)

        let found = try await database.searchHistory("git", limit: 4)
        #expect(found.first?.url.absoluteString == "https://github.com/")
        #expect(found.count == 4)

        // End to end through the merge: github.com is the top hit.
        let candidates = try await database.addressBarCandidates(for: "git")
        let merged = AddressBarSuggestions.merge(
            query: "git", history: candidates.history, favorites: candidates.favorites, searches: []
        )
        #expect(merged.first == .page(url: URL(string: "https://github.com/")!, title: "GitHub", isFavorite: false))
    }

    @Test func urlVariantsDoNotShortenTheMergedList() async throws {
        let database = try AppDatabase.inMemory()
        var changes: [HistoryChange] = []
        // Twenty well-visited variants of one page outrank everything else.
        for index in 0..<20 {
            for _ in 0..<5 { changes.append(.visit(visit("https://top.example/news#section-\(index)"))) }
        }
        for host in ["a", "b", "c", "d"] {
            for variant in ["https://\(host).example/news", "http://\(host).example/news", "https://www.\(host).example/news/"] {
                changes.append(.visit(visit(variant, at: -86_400)))
            }
        }
        try await database.apply(changes)
        let candidates = try await database.addressBarCandidates(for: "news")
        #expect(candidates.history.count == FixedChoices.maxPageSuggestions)
        #expect(Set(candidates.history.compactMap { $0.url.host() }).count == FixedChoices.maxPageSuggestions)
        let merged = AddressBarSuggestions.merge(query: "news", history: candidates.history, favorites: [], searches: [])
        #expect(merged.count == FixedChoices.maxPageSuggestions)
    }

    @Test func historyDedupesWithTheMergeKey() async throws {
        let database = try AppDatabase.inMemory()
        try await database.apply([
            .visit(visit("https://a.example/news/?x=1")),
            .visit(visit("http://www.A.example/news?x=1")),
            .visit(visit("https://a.example/News?x=1")),
        ])
        let found = try await database.searchHistory("news", limit: 10)
        // Paths are case-sensitive, so /News is its own page; the other two are one page.
        #expect(found.count == 2)
    }

    @Test func controlCharactersInInputAreHarmless() async throws {
        let database = try AppDatabase.inMemory()
        try await database.record(visit("https://a.example/b", "A B"))
        #expect(try await database.searchHistory("a\u{0000}b").map(\.title) == ["A B"])
        #expect(try await database.searchHistory("\u{0000}").isEmpty)
        #expect(try await database.searchHistory("\"a\" OR NEAR(b) *").isEmpty)
    }

    @Test func resultsAreRankedByFrecency() async throws {
        let database = try AppDatabase.inMemory()
        try await database.apply([
            .visit(visit("https://once.example/news")),
            .visit(visit("https://often.example/news")),
            .visit(visit("https://often.example/news", at: 10)),
            .visit(visit("https://often.example/news", at: 20)),
            .visit(visit("https://old.example/news", at: -365 * 86_400)),
        ])
        let found = try await database.searchHistory("news", limit: 2)
        #expect(found.map(\.url.host) == ["often.example", "once.example"])
        #expect(found.allSatisfy { $0.frecency != nil && !$0.isFavorite })
    }

    @Test func titleArrivingAfterTheVisitIsSearchable() async throws {
        let database = try AppDatabase.inMemory()
        let url = URL(string: "https://example.com/page")!
        try await database.apply([.visit(visit(url.absoluteString)), .title("Quarterly Report", url: url)])
        #expect(try await database.searchHistory("quarter").map(\.title) == ["Quarterly Report"])
        #expect(try await database.recentVisits(limit: 1).first?.title == "Quarterly Report")

        try await database.apply([.title("Annual Report", url: url)])
        #expect(try await database.searchHistory("quarter").isEmpty)
        #expect(try await database.searchHistory("annual").count == 1)
    }

    @Test func deleteAndClearRemoveFromSearch() async throws {
        let database = try AppDatabase.inMemory()
        try await database.apply([.visit(visit("https://a.example/x", "Alpha")), .visit(visit("https://b.example/x", "Alpine"))])
        try await database.deleteHistory(for: URL(string: "https://a.example/x")!)
        #expect(try await database.searchHistory("alp").map(\.title) == ["Alpine"])
        try await database.clearHistory()
        #expect(try await database.searchHistory("alp").isEmpty)
        #expect(try await database.recentVisits(limit: 10).isEmpty)
    }
}

@Suite struct HistoryRecorderTests {
    @Test func flushWritesBufferedChangesInOrder() async throws {
        let database = try AppDatabase.inMemory()
        let recorder = HistoryRecorder(database: database, interval: .seconds(60), batchSize: 100)
        let url = URL(string: "https://example.com")!
        await recorder.record(visit(url.absoluteString))
        await recorder.recordTitle("Example Domain", for: url)
        #expect(try await database.recentVisits(limit: 10).isEmpty)

        await recorder.flush()
        #expect(try await database.searchHistory("example").map(\.title) == ["Example Domain"])
    }

    /// Waits up to 5 s for `count` visits to be on disk, without calling `flush()`.
    func waitForVisits(_ count: Int, in database: AppDatabase) async throws -> Int {
        let deadline = ContinuousClock.now + .seconds(5)
        var found = 0
        while ContinuousClock.now < deadline {
            found = try await database.recentVisits(limit: 100).count
            if found >= count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        return found
    }

    @Test func fullBufferIsWrittenWithoutAFlush() async throws {
        let database = try AppDatabase.inMemory()
        let recorder = HistoryRecorder(database: database, interval: .seconds(60), batchSize: 3)
        for index in 0..<3 { await recorder.record(visit("https://e.example/\(index)")) }
        #expect(try await waitForVisits(3, in: database) == 3)
    }

    @Test func timerFlushesAfterTheInterval() async throws {
        let database = try AppDatabase.inMemory()
        let recorder = HistoryRecorder(database: database, interval: .milliseconds(20), batchSize: 100)
        await recorder.record(visit("https://e.example"))
        #expect(try await waitForVisits(1, in: database) == 1)
        #expect(await recorder.lastError == nil)
    }

    @Test func clearDropsBufferedAndInFlightVisits() async throws {
        let database = try AppDatabase.inMemory()
        let recorder = HistoryRecorder(database: database, interval: .seconds(60), batchSize: 2)
        // The first two start writing; the third waits in the buffer.
        for index in 0..<3 { await recorder.record(visit("https://e.example/\(index)")) }
        try await recorder.clearHistory()
        await recorder.flush()
        #expect(try await database.recentVisits(limit: 10).isEmpty)

        await recorder.record(visit("https://after.example"))
        await recorder.flush()
        #expect(try await database.recentVisits(limit: 10).map(\.url.host) == ["after.example"])
    }

    @Test func deleteDropsBufferedChangesForThatPageOnly() async throws {
        let database = try AppDatabase.inMemory()
        let recorder = HistoryRecorder(database: database, interval: .seconds(60), batchSize: 100)
        let gone = URL(string: "https://gone.example")!
        await recorder.record(visit(gone.absoluteString))
        await recorder.flush()
        await recorder.record(visit(gone.absoluteString, at: 10))
        await recorder.recordTitle("Gone", for: gone)
        await recorder.record(visit("https://kept.example", at: 20))

        try await recorder.deleteHistory(for: gone)
        await recorder.flush()
        #expect(try await database.recentVisits(limit: 10).map(\.url.host) == ["kept.example"])
        #expect(try await database.searchHistory("gone").isEmpty)
    }
}
