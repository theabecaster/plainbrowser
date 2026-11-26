import BrowserCore
import Foundation
import GRDB
@testable import Storage
import Testing

@Suite struct VisitKindTests {
    @Test func typedVisitsWeighMoreInFrecency() async throws {
        let database = try AppDatabase.inMemory()
        try await database.apply([
            .visit(HistoryVisit(url: URL(string: "https://linked.example/")!, title: nil, visitedAt: t0)),
            .visit(HistoryVisit(url: URL(string: "https://linked.example/")!, title: nil, visitedAt: t0)),
            .visit(HistoryVisit(url: URL(string: "https://typed.example/")!, title: nil, visitedAt: t0, kind: .typed)),
        ])
        let places = try await database.writer.read { db in
            try HistoryPlace.order(Column("url")).fetchAll(db)
        }
        let scores = places.map { Frecency.score(key: $0.frecency, now: t0) }
        #expect(abs(scores[0] - 2) < 1e-9)
        #expect(abs(scores[1] - FixedChoices.typedVisitWeight) < 1e-9)
        let kinds = try await database.recentVisits(limit: 10).map(\.kind)
        #expect(kinds.sorted { $0.rawValue < $1.rawValue } == [.link, .link, .typed])
    }

    @Test func partialClearRebuildsFrecencyWithVisitKinds() async throws {
        let database = try AppDatabase.inMemory()
        let url = URL(string: "https://a.example/")!
        try await database.apply([
            .visit(HistoryVisit(url: url, title: nil, visitedAt: t0, kind: .typed)),
            .visit(HistoryVisit(url: url, title: nil, visitedAt: t0.addingTimeInterval(3600))),
        ])
        try await database.clearHistory(since: t0.addingTimeInterval(60))
        let place = try #require(try await database.writer.read { db in try HistoryPlace.fetchOne(db) })
        #expect(abs(Frecency.score(key: place.frecency, now: t0) - FixedChoices.typedVisitWeight) < 1e-9)
    }

    @Test func v2VisitsBecomeLinks() async throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v2.settings")
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO historyVisit (url, title, visitedAt) VALUES (?, ?, ?)",
                arguments: ["https://a.example/", "A", t0]
            )
        }
        try AppDatabase.migrator.migrate(queue)
        let visits = try await queue.read { db in try HistoryVisit.fetchAll(db) }
        #expect(visits.map(\.kind) == [.link])
    }
}

@Suite struct AdaptiveHistoryTests {
    @Test func pickedPageIsMarkedForInputThatStartsTheSameWay() async throws {
        let database = try AppDatabase.inMemory()
        try await database.apply([
            .visit(visit("https://github.com/", "GitHub")),
            .visit(visit("https://gist.github.com/me/notes", "Notes")),
            .pick(input: "GI", url: URL(string: "https://gist.github.com/me/notes")!, at: t0),
        ])

        // "g" starts "gi": the pick counts. "gis" does not start "gi".
        let candidates = try await database.addressBarCandidates(for: "g")
        let picked = candidates.history.filter { $0.adaptiveUse != nil }
        #expect(picked.map(\.url.absoluteString) == ["https://gist.github.com/me/notes"])
        #expect(try await database.addressBarCandidates(for: "gis").history.allSatisfy { $0.adaptiveUse == nil })

        // Merged, it is the top hit, above the github.com site.
        let merged = AddressBarSuggestions.merge(
            query: "g", history: candidates.history, favorites: candidates.favorites, searches: [])
        #expect(merged.first == .page(url: URL(string: "https://gist.github.com/me/notes")!, title: "Notes", isFavorite: false))
    }

    @Test func repeatedPicksGrowAndNewHabitsTakeOver() async throws {
        let database = try AppDatabase.inMemory()
        let old = URL(string: "https://old.example/")!, new = URL(string: "https://other.example/")!
        try await database.apply((0..<3).map { _ in .pick(input: "o", url: old, at: t0) })
        func uses() async throws -> [String: Double] {
            try await database.writer.read { db in
                Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT url, useCount FROM inputHistory")
                    .map { (row: Row) -> (String, Double) in (row["url"], row["useCount"]) })
            }
        }
        #expect(abs(try await uses()[old.absoluteString]! - 2.71) < 1e-9) // 1, 1.9, 2.71
        try await database.apply((0..<4).map { _ in .pick(input: "o", url: new, at: t0) })
        let after = try await uses()
        #expect(after[new.absoluteString]! > after[old.absoluteString]!)
    }

    @Test func picksGoThroughTheRecorderAndAreClearedWithHistory() async throws {
        let database = try AppDatabase.inMemory()
        let url = URL(string: "https://a.example/")!
        try await database.record(visit("https://a.example/", "A"))
        await database.recordPickedSuggestion(input: "a", url: url, at: t0)
        await database.historyRecorder.flush()
        #expect(try await database.addressBarCandidates(for: "a").history.first?.adaptiveUse == 1)

        try await database.deleteHistory(for: url)
        #expect(try await count(in: database) == 0)

        await database.recordPickedSuggestion(input: "a", url: url, at: t0)
        try await database.clearHistory(since: nil)
        #expect(try await count(in: database) == 0)
    }

    @Test func partialClearDropsPicksMadeInThatTime() async throws {
        let database = try AppDatabase.inMemory()
        try await database.apply([
            .visit(visit("https://a.example/", at: 0)),
            .pick(input: "a", url: URL(string: "https://a.example/")!, at: t0),
            .visit(visit("https://b.example/", at: 0)),
            .pick(input: "b", url: URL(string: "https://b.example/")!, at: t0.addingTimeInterval(3600)),
        ])
        try await database.clearHistory(since: t0.addingTimeInterval(60))
        let left = try await database.writer.read { db in try String.fetchAll(db, sql: "SELECT input FROM inputHistory") }
        #expect(left == ["a"])
    }

    func count(in database: AppDatabase) async throws -> Int {
        try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM inputHistory") ?? 0 }
    }
}

@Suite struct SiteMatchTests {
    @Test func rootPageIsACandidateEvenWhenDeepPagesFillTheList() async throws {
        let database = try AppDatabase.inMemory()
        var changes: [HistoryChange] = [.visit(visit("https://github.com/", "GitHub", at: -40 * 86_400))]
        for index in 0..<10 {
            for _ in 0..<5 { changes.append(.visit(visit("https://github.com/repo\(index)", "Repo \(index)"))) }
        }
        try await database.apply(changes)
        let candidates = try await database.addressBarCandidates(for: "Git", historyLimit: 4)
        #expect(candidates.history.count == 5)
        #expect(candidates.history.contains { $0.url.absoluteString == "https://github.com/" })
        let merged = AddressBarSuggestions.merge(query: "Git", history: candidates.history, favorites: [], searches: [])
        #expect(merged.first == .page(url: URL(string: "https://github.com/")!, title: "GitHub", isFavorite: false))

        // Once the text has a path, the root is no longer looked up.
        #expect(try await database.addressBarCandidates(for: "github.com/r", historyLimit: 4).history.count == 4)
    }

    @Test func rootPageAlreadyInTheListIsNotRepeated() async throws {
        let database = try AppDatabase.inMemory()
        try await database.record(visit("https://news.example/", "News"))
        #expect(try await database.addressBarCandidates(for: "news").history.count == 1)
    }

    @Test func siteLookupUsesThePartialIndex() async throws {
        let database = try AppDatabase.inMemory()
        let plan = try await database.writer.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN SELECT url FROM historyPlace INDEXED BY historyPlace_sites
                WHERE address >= 'g' AND address < 'h' AND instr(address, '/') = 0 AND instr(address, '?') = 0
                ORDER BY frecency DESC LIMIT 1
                """).map { $0["detail"] as String }
        }
        #expect(plan.contains { $0.contains("historyPlace_sites") })
    }
}
