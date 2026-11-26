import Foundation
import Storage
import Testing

@Suite struct AppDatabaseTests {
    @Test func recordedVisitsComeBackNewestFirst() async throws {
        let database = try AppDatabase.inMemory()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try await database.record(HistoryVisit(url: URL(string: "https://a.example")!, title: "A", visitedAt: start))
        try await database.record(HistoryVisit(
            url: URL(string: "https://b.example")!, title: nil, visitedAt: start.addingTimeInterval(60)
        ))

        let visits = try await database.recentVisits(limit: 10)
        #expect(visits.map(\.url.host) == ["b.example", "a.example"])
        #expect(visits.allSatisfy { $0.id != nil })
    }

    @Test func limitIsHonored() async throws {
        let database = try AppDatabase.inMemory()
        for minute in 0..<5 {
            try await database.record(HistoryVisit(
                url: URL(string: "https://example.com/\(minute)")!, title: nil,
                visitedAt: Date(timeIntervalSince1970: Double(minute * 60))
            ))
        }
        #expect(try await database.recentVisits(limit: 2).count == 2)
    }
}
