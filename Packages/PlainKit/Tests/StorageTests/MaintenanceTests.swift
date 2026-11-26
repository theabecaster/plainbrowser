import BrowserCore
import Foundation
import GRDB
@testable import Storage
import Testing

@Suite(.serialized) struct MaintenanceTests {
    static let day: TimeInterval = 86_400

    func counts(_ database: AppDatabase) async throws -> (visits: Int, places: Int, picks: Int, icons: Int) {
        try await database.writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM historyVisit") ?? 0,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM historyPlace") ?? 0,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM inputHistory") ?? 0,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM favicon") ?? 0)
        }
    }

    @Test func oldVisitsAndPagesExpire() async throws {
        let database = try AppDatabase.inMemory()
        let maxAge = FixedChoices.historyMaxAge
        try await database.apply([
            // Only visited before the cutoff: the page goes.
            .visit(visit("https://old.example/", "Old", at: -maxAge - Self.day)),
            .pick(input: "o", url: URL(string: "https://old.example/")!, at: t0.addingTimeInterval(-maxAge - Self.day)),
            // Visited before and after: the old visit goes, the page stays.
            .visit(visit("https://both.example/", "Both", at: -maxAge - Self.day)),
            .visit(visit("https://both.example/", "Both", at: -Self.day)),
            .visit(visit("https://new.example/", "New", at: 0)),
        ])
        let report = try await database.runMaintenance(now: t0, lastRun: nil)
        #expect(report.expiredVisits == 2)
        #expect(report.removedPlaces == 1)
        let left = try await database.searchHistory("example", limit: 10).map(\.url.host)
        #expect(Set(left) == ["both.example", "new.example"])
        let after = try await counts(database)
        #expect(after.visits == 2 && after.places == 2 && after.picks == 0)
    }

    @Test func historyIsCappedByDroppingTheLeastFrecent() async throws {
        let database = try AppDatabase.inMemory()
        var changes: [HistoryChange] = []
        for index in 0..<6 {
            // Higher index, more visits, higher frecency.
            for _ in 0...index { changes.append(.visit(visit("https://site\(index).example/", at: 0))) }
        }
        changes.append(.pick(input: "s", url: URL(string: "https://site0.example/")!, at: t0))
        try await database.apply(changes)

        let report = try await database.runMaintenance(now: t0, lastRun: nil, maxPlaces: 4)
        #expect(report.removedPlaces == 2)
        let hosts = Set(try await database.searchHistory("site", limit: 10).compactMap(\.url.host))
        #expect(hosts == ["site2.example", "site3.example", "site4.example", "site5.example"])
        let after = try await counts(database)
        #expect(after.visits == 3 + 4 + 5 + 6)
        #expect(after.picks == 0)
    }

    @Test func picksDecayByDaysSinceTheLastRunAndFadeOut() async throws {
        let database = try AppDatabase.inMemory()
        let url = URL(string: "https://a.example/")!
        try await database.apply([.visit(visit("https://a.example/", at: 0)), .pick(input: "a", url: url, at: t0)])
        _ = try await database.runMaintenance(now: t0.addingTimeInterval(10 * Self.day), lastRun: t0)
        let use = try await database.writer.read { db in try Double.fetchOne(db, sql: "SELECT useCount FROM inputHistory") }
        #expect(abs(use! - pow(FixedChoices.inputHistoryDailyDecay, 10)) < 1e-9)

        // About six months unused and it is forgotten.
        _ = try await database.runMaintenance(now: t0.addingTimeInterval(200 * Self.day), lastRun: t0.addingTimeInterval(10 * Self.day))
        #expect(try await counts(database).picks == 0)
    }

    @Test func staleIconsGo() async throws {
        let database = try AppDatabase.inMemory()
        try await database.saveFavicon(Favicon(host: "old.example", data: Data([1]), updatedAt: t0.addingTimeInterval(-FixedChoices.faviconMaxAge - 1)))
        try await database.saveFavicon(Favicon(host: "new.example", data: Data([1]), updatedAt: t0))
        let report = try await database.runMaintenance(now: t0, lastRun: nil)
        #expect(report.removedFavicons == 1)
        #expect(try await database.favicon(forHost: "new.example") != nil)
    }

    @Test func runsAtMostOncePerInterval() async throws {
        let database = try AppDatabase.inMemory()
        #expect(try await database.lastMaintenance() == nil)
        #expect(try await database.runDailyMaintenanceIfDue(now: t0) != nil)
        #expect(try await database.lastMaintenance() == t0)
        #expect(try await database.runDailyMaintenanceIfDue(now: t0.addingTimeInterval(FixedChoices.maintenanceInterval - 1)) == nil)
        #expect(try await database.runDailyMaintenanceIfDue(now: t0.addingTimeInterval(FixedChoices.maintenanceInterval)) != nil)
        // A clock set back is not a reason to wait a long time.
        #expect(try await database.runDailyMaintenanceIfDue(now: t0) != nil)
        // The marker is not a setting.
        #expect(try await database.settings() == BrowserSettings.defaults)
    }

    @Test func clearingEverythingCompactsTheFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "plain-compact-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Plain.sqlite")
        let database = try await AppDatabase.open(at: file)
        let title = String(repeating: "A long page title for padding. ", count: 20)
        try await database.apply((0..<3_000).map { .visit(visit("https://site\($0).example/page", "\(title) \($0)")) })
        try await database.writer.writeWithoutTransaction { db in _ = try db.checkpoint(.truncate) }
        let full = try size(file)

        // Clear History and Data: history, then icons; one compaction afterwards.
        try await database.clearHistory(since: nil)
        try await database.clearFavicons()
        await database.waitForMaintenance()

        let compacted = try size(file)
        let wal = (try? size(URL(filePath: file.path + "-wal"))) ?? 0
        #expect(compacted < full / 4, "\(compacted) of \(full)")
        #expect(wal == 0)
        #expect(try await counts(database).places == 0)
    }

    @Test func partialClearDoesNotCompact() async throws {
        let database = try AppDatabase.inMemory()
        try await database.record(visit("https://a.example/"))
        try await database.clearHistory(since: t0)
        await database.waitForMaintenance()
        #expect(try await counts(database).visits == 0)
    }

    func size(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
    }
}
