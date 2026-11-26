import BrowserCore
@testable import FeatureUI
import Foundation
import Storage
import Testing

/// History in memory with the calls the model makes recorded.
actor FakeHistory: HistoryStoring {
    var visits: [HistoryVisit]
    private(set) var queries: [String] = []
    private(set) var clearedSince: [Date?] = []
    var failNext = false

    init(_ visits: [HistoryVisit]) {
        self.visits = visits.sorted { $0.visitedAt > $1.visitedAt }
    }

    func failNextCall() { failNext = true }

    func visits(matching query: String, limit: Int) async throws -> [HistoryVisit] {
        queries.append(query)
        if failNext { failNext = false; throw CancellationError() }
        let matches = query.isEmpty ? visits : visits.filter { ($0.title ?? "").localizedCaseInsensitiveContains(query) }
        return Array(matches.prefix(limit))
    }

    func deleteHistory(for url: URL) async throws {
        if failNext { failNext = false; throw URLError(.unknown) }
        visits.removeAll { $0.url == url }
    }

    func clearHistory(since start: Date?) async throws {
        clearedSince.append(start)
        visits.removeAll { start == nil || $0.visitedAt >= start! }
    }
}

/// History whose next read waits until released, returning what was stored when it started.
actor GatedHistory: HistoryStoring {
    var visits: [HistoryVisit]
    private var armed = false
    private var waiting: CheckedContinuation<Void, Never>?

    init(_ visits: [HistoryVisit]) { self.visits = visits }

    func arm() { armed = true }
    var isWaiting: Bool { waiting != nil }
    func release() { waiting?.resume(); waiting = nil }

    func visits(matching query: String, limit: Int) async throws -> [HistoryVisit] {
        let snapshot = Array(visits.filter { query.isEmpty || ($0.title ?? "").contains(query) }.prefix(limit))
        if armed {
            armed = false
            await withCheckedContinuation { waiting = $0 }
        }
        return snapshot
    }

    private var deleteArmed = false
    private var deleteWaiting: CheckedContinuation<Void, Never>?
    func armDelete() { deleteArmed = true }
    var isDeleteWaiting: Bool { deleteWaiting != nil }
    func releaseDelete() { deleteWaiting?.resume(); deleteWaiting = nil }

    func deleteHistory(for url: URL) async throws {
        if deleteArmed {
            deleteArmed = false
            await withCheckedContinuation { deleteWaiting = $0 }
        }
        visits.removeAll { $0.url == url }
    }
    func clearHistory(since start: Date?) async throws { visits.removeAll() }
}

@MainActor
@Suite struct HistoryModelTests {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    /// Wednesday 2026-11-25, 15:00 New York.
    static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 15))!

    static func visit(_ id: Int64, _ host: String, _ title: String?, hoursAgo: Double) -> HistoryVisit {
        var visit = HistoryVisit(url: URL(string: "https://www.\(host)/page/")!, title: title, visitedAt: now.addingTimeInterval(-hoursAgo * 3600))
        visit.id = id
        return visit
    }

    static let sample = [
        visit(1, "a.example", "Alpha", hoursAgo: 0.5),
        visit(2, "b.example", nil, hoursAgo: 2),
        visit(3, "c.example", "Gamma", hoursAgo: 20),
        visit(4, "d.example", "Delta", hoursAgo: 24 * 5),
        visit(5, "e.example", "Epsilon", hoursAgo: 24 * 400),
    ]

    func makeModel(_ store: any HistoryStoring) -> HistoryModel {
        let now = Self.now
        return HistoryModel(store: store, now: { now }, calendar: Self.calendar, locale: Locale(identifier: "en_US"))
    }

    @Test func groupsByDayWithReadableTitles() async {
        let model = makeModel(FakeHistory(Self.sample))
        await model.load()
        #expect(model.isLoaded)
        #expect(model.days.map(\.title) == ["Today", "Yesterday", "Friday, November 20", "Tuesday, October 21, 2025"])
        #expect(model.days[0].rows.map(\.id) == [1, 2])
        #expect(model.days[0].rows[1].title == "b.example/page", "untitled rows show the address")
        #expect(model.days[0].rows[0].address == "a.example/page")
    }

    @Test func searchWaitsForTypingToPause() async throws {
        let store = FakeHistory(Self.sample)
        let model = makeModel(store)
        await model.load()
        model.query = "g"
        model.query = "ga"
        model.query = "gam"
        try await Task.sleep(for: FixedChoices.historySearchDelay * 4)
        #expect(await store.queries == ["", "gam"])
        #expect(model.days.flatMap(\.rows).map(\.id) == [3])
    }

    @Test func emptySearchResultIsEmpty() async throws {
        let model = makeModel(FakeHistory(Self.sample))
        await model.load()
        model.query = "zzz"
        try await Task.sleep(for: FixedChoices.historySearchDelay * 4)
        #expect(model.isEmpty)
    }

    @Test func deleteRemovesEveryRowForThePage() async {
        var again = Self.visit(9, "a.example", "Alpha", hoursAgo: 30)
        again.id = 9
        let store = FakeHistory(Self.sample + [again])
        let model = makeModel(store)
        await model.load()
        let row = model.days[0].rows[0]
        await model.delete(row)
        #expect(!model.days.flatMap(\.rows).contains { $0.url == row.url })
        #expect(await store.visits.count == 4)
    }

    @Test func aLoadStartedBeforeADeleteCannotBringTheRowBack() async throws {
        let store = GatedHistory(Self.sample)
        let model = makeModel(store)
        await model.load()
        let row = model.days[0].rows[0]
        await store.arm()
        let slowLoad = Task { await model.load() }
        while await !store.isWaiting { await Task.yield() }
        // The stale read lands while the delete is still in the store.
        await store.armDelete()
        let deleting = Task { await model.delete(row) }
        while await !store.isDeleteWaiting { await Task.yield() }
        await store.release()
        await slowLoad.value
        #expect(!model.days.flatMap(\.rows).contains { $0.url == row.url })
        await store.releaseDelete()
        await deleting.value
        #expect(!model.days.flatMap(\.rows).contains { $0.url == row.url })
    }

    @Test func anOldSearchCannotReplaceANewerOne() async throws {
        let store = GatedHistory(Self.sample)
        let model = makeModel(store)
        await store.arm()
        let slowLoad = Task { await model.load() }
        while await !store.isWaiting { await Task.yield() }
        model.query = "Gamma"
        // The old read lands during the search pause, before the new search starts.
        await store.release()
        await slowLoad.value
        #expect(model.days.isEmpty, "the old results are not shown for the new query")
        try await Task.sleep(for: FixedChoices.historySearchDelay * 4)
        #expect(model.days.flatMap(\.rows).map(\.id) == [3])
    }

    @Test func failedDeleteReloadsAndShowsAMessage() async {
        let store = FakeHistory(Self.sample)
        let model = makeModel(store)
        await model.load()
        await store.failNextCall()
        await model.delete(model.days[0].rows[0])
        #expect(model.errorMessage != nil)
        #expect(model.days.flatMap(\.rows).count == 5, "the row comes back")
    }

    @Test(arguments: [
        (HistoryClearRange.lastHour, 4),
        (.today, 3),
        (.all, 0),
    ])
    func clearRanges(range: HistoryClearRange, remaining: Int) async {
        let store = FakeHistory(Self.sample)
        let model = makeModel(store)
        await model.load()
        await model.clear(range)
        #expect(model.days.flatMap(\.rows).count == remaining)
        #expect(await store.clearedSince == [range.start(now: Self.now, calendar: Self.calendar)])
    }

    @Test func rangeStarts() {
        #expect(HistoryClearRange.lastHour.start(now: Self.now, calendar: Self.calendar) == Self.now.addingTimeInterval(-3600))
        #expect(HistoryClearRange.today.start(now: Self.now, calendar: Self.calendar) == Self.calendar.startOfDay(for: Self.now))
        #expect(HistoryClearRange.all.start(now: Self.now, calendar: Self.calendar) == nil)
    }

    @Test func loadsMoreWhenTheLastRowAppears() async throws {
        let many = (0..<(FixedChoices.historyPageSize + 10)).map {
            Self.visit(Int64($0 + 1), "p\($0).example", "Page \($0)", hoursAgo: Double($0) / 60)
        }
        let store = FakeHistory(many)
        let model = makeModel(store)
        await model.load()
        #expect(model.days.flatMap(\.rows).count == FixedChoices.historyPageSize)
        model.rowAppeared(model.days.first!.rows.first!)
        #expect(await store.queries.count == 1, "only the last row loads more")
        model.rowAppeared(model.days.last!.rows.last!)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.days.flatMap(\.rows).count == many.count)
    }
}

@MainActor
@Suite struct FavoritesModelTests {
    let database: AppDatabase

    init() async throws {
        database = try AppDatabase.inMemory()
        for name in ["a", "b", "c", "d", "e"] {
            try await database.addFavorite(url: URL(string: "https://\(name).example/")!, title: name.uppercased())
        }
    }

    func titles(_ model: FavoritesModel) -> [String] {
        model.favorites.map(FavoritesModel.displayTitle)
    }

    func storedTitles() async throws -> [String] {
        try await database.favorites().map { $0.title ?? "" }
    }

    @Test(arguments: [
        ([0], 3, ["B", "C", "A", "D", "E"]),
        ([4], 0, ["E", "A", "B", "C", "D"]),
        ([1, 3], 5, ["A", "C", "E", "B", "D"]),
        ([2], 2, ["A", "B", "C", "D", "E"]),
    ])
    func moveMatchesTheStore(source: [Int], destination: Int, expected: [String]) async throws {
        let model = FavoritesModel(store: database)
        await model.load()
        model.move(fromOffsets: IndexSet(source), toOffset: destination)
        #expect(titles(model) == expected)
        await model.waitForSaves()
        #expect(try await storedTitles() == expected)
    }

    @Test func renameAndDelete() async throws {
        let model = FavoritesModel(store: database)
        await model.load()
        model.rename(model.favorites[1], to: "  Bravo ")
        model.rename(model.favorites[2], to: "   ")
        model.delete(atOffsets: IndexSet([0, 4]))
        #expect(titles(model) == ["Bravo", "C", "D"])
        await model.waitForSaves()
        #expect(try await storedTitles() == ["Bravo", "C", "D"])
        #expect(try await database.favorites().map(\.position) == [0, 1, 2])
    }

    @Test func untitledFavoriteShowsItsAddress() async throws {
        try await database.addFavorite(url: URL(string: "https://www.example.com/start/")!, title: nil)
        let model = FavoritesModel(store: database)
        await model.load()
        #expect(titles(model).last == "example.com/start")
    }

    @Test func failedWriteReloadsFromTheStore() async throws {
        let model = FavoritesModel(store: FailingFavorites(database: database))
        await model.load()
        model.delete(atOffsets: IndexSet([0]))
        await model.waitForSaves()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.errorMessage != nil)
        #expect(titles(model) == ["A", "B", "C", "D", "E"])
    }
}

struct FailingFavorites: FavoritesStoring {
    let database: AppDatabase
    func favorites() async throws -> [Favorite] { try await database.favorites() }
    func renameFavorite(id: Int64, title: String) async throws { throw URLError(.unknown) }
    func removeFavorite(id: Int64) async throws { throw URLError(.unknown) }
    func moveFavorite(id: Int64, to index: Int) async throws { throw URLError(.unknown) }
}
