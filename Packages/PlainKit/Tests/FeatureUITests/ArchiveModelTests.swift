import BrowserCore
@testable import FeatureUI
import Foundation
import Storage
import Testing

/// The archive in memory, filtered like the database: words in the title or address.
actor FakeArchive: ArchiveStoring {
    var tabs: [ArchivedTab]
    private(set) var queries: [String] = []
    var failNextRead = false

    init(_ tabs: [ArchivedTab]) {
        self.tabs = tabs
    }

    func failNextReadCall() { failNextRead = true }

    func archivedTabs(matching query: String, limit: Int) async throws -> [ArchivedTab] {
        queries.append(query)
        if failNextRead { failNextRead = false; throw URLError(.cannotOpenFile) }
        let matches = query.isEmpty ? tabs : tabs.filter {
            ($0.entry.title ?? "").localizedCaseInsensitiveContains(query)
                || ($0.entry.url?.absoluteString ?? "").localizedCaseInsensitiveContains(query)
        }
        return Array(matches.prefix(limit))
    }
}

@MainActor
struct ArchiveModelTests {
    private static func tab(_ title: String?, _ address: String, archivedHoursAgo hours: Double) -> ArchivedTab {
        ArchivedTab(
            entry: TabEntry(id: TabID(), url: URL(string: address), title: title, createdAt: Date()),
            archivedAt: Date().addingTimeInterval(-hours * 3600)
        )
    }

    @Test func listsRowsWithTitleOrAddress() async {
        let archive = FakeArchive([
            Self.tab("Swift Forums", "https://forums.swift.org/latest", archivedHoursAgo: 1),
            Self.tab(nil, "https://www.example.com/", archivedHoursAgo: 2),
        ])
        let model = ArchiveModel(store: archive, onRestore: { _ in }, onDelete: { _ in })
        await model.load()
        #expect(model.isLoaded)
        #expect(model.rows.map(\.title) == ["Swift Forums", "example.com"])
        #expect(model.rows.map(\.address) == ["forums.swift.org/latest", "example.com"])
    }

    @Test func failedReadShowsTryAgainNotTheEmptyState() async {
        let archive = FakeArchive([Self.tab("Swift Forums", "https://forums.swift.org/latest", archivedHoursAgo: 1)])
        let model = ArchiveModel(store: archive, onRestore: { _ in }, onDelete: { _ in })
        await archive.failNextReadCall()
        await model.load()
        #expect(model.loadFailed)
        #expect(model.isLoaded)
        await model.load()
        #expect(!model.loadFailed)
        #expect(model.rows.count == 1)
        await archive.failNextReadCall()
        await model.load()
        #expect(model.rows.isEmpty, "stale rows don't stay under the failure")
    }

    @Test func restoreAndDeleteLeaveTheListAndReachTheShell() async {
        let first = Self.tab("A", "https://a.example", archivedHoursAgo: 1)
        let second = Self.tab("B", "https://b.example", archivedHoursAgo: 2)
        let archive = FakeArchive([first, second])
        var restored: [TabID] = []
        var deleted: [TabID] = []
        let model = ArchiveModel(store: archive, onRestore: { restored.append($0.id) }, onDelete: { deleted += $0 })
        await model.load()
        model.restore(model.rows[0])
        #expect(restored == [first.id])
        #expect(model.rows.map(\.id) == [second.id])
        model.delete(model.rows[0])
        #expect(deleted == [second.id])
        #expect(model.rows.isEmpty)
        // A reload before the store writes the delete still leaves them out.
        await model.load()
        #expect(model.rows.isEmpty)
    }

    // MARK: Sections

    /// Friday 27 November 2026, 15:00 in New York.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 15))!

    private static func tab(_ title: String, archivedAt date: Date) -> ArchivedTab {
        ArchivedTab(entry: TabEntry(id: TabID(), url: URL(string: "https://\(title.lowercased()).example"), title: title, createdAt: date), archivedAt: date)
    }

    private static func date(day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    @Test func sectionsFollowWhenTabsWereArchivedNewestFirst() async {
        let archive = FakeArchive([
            Self.tab("Morning", archivedAt: Self.date(day: 27, hour: 9)),
            Self.tab("Midnight", archivedAt: Self.date(day: 27, hour: 0)),
            Self.tab("LateYesterday", archivedAt: Self.date(day: 26, hour: 23)),
            Self.tab("Yesterday", archivedAt: Self.date(day: 26, hour: 0)),
            Self.tab("TwoDaysAgo", archivedAt: Self.date(day: 25, hour: 12)),
            Self.tab("SixDaysAgo", archivedAt: Self.date(day: 21, hour: 0)),
            Self.tab("SevenDaysAgo", archivedAt: Self.date(day: 20, hour: 23)),
            Self.tab("Weeks", archivedAt: Self.date(day: 2, hour: 8)),
        ])
        let model = ArchiveModel(
            store: archive, onRestore: { _ in }, onDelete: { _ in }, now: { Self.now }, calendar: Self.calendar
        )
        await model.load()
        #expect(model.sections.map(\.title) == ["Today", "Yesterday", "This Week", "Earlier"])
        #expect(model.sections.map { $0.rows.map(\.title) } == [
            ["Morning", "Midnight"], ["LateYesterday", "Yesterday"], ["TwoDaysAgo", "SixDaysAgo"], ["SevenDaysAgo", "Weeks"],
        ])
        #expect(model.rows.count == 8)
    }

    @Test func onlyPeriodsWithTabsShowAndAnEmptiedOneLeaves() async {
        let archive = FakeArchive([
            Self.tab("Today", archivedAt: Self.date(day: 27, hour: 10)),
            Self.tab("Old", archivedAt: Self.date(day: 10, hour: 10)),
        ])
        var deleted: [TabID] = []
        let model = ArchiveModel(
            store: archive, onRestore: { _ in }, onDelete: { deleted += $0 }, now: { Self.now }, calendar: Self.calendar
        )
        await model.load()
        #expect(model.sections.map(\.period) == [.today, .earlier])
        let today = model.sections[0].rows[0]
        model.delete(today)
        #expect(deleted == [today.id])
        #expect(model.sections.map(\.period) == [.earlier])
    }

    @Test func aClockMovedBackKeepsFutureTabsInToday() {
        let later = Self.now.addingTimeInterval(3_600 * 30)
        #expect(ArchivePeriod.of(later, now: Self.now, calendar: Self.calendar) == .today)
    }

    @Test func theWholeArchiveLoadsWithNoQueryAndASearchIsCapped() async throws {
        let base = Self.now
        let tabs = (0 ..< FixedChoices.archivedTabLimit).map {
            Self.tab("Page\($0)", archivedAt: base.addingTimeInterval(-Double($0) * 2_000))
        }
        let archive = FakeArchive(tabs)
        let model = ArchiveModel(
            store: archive, onRestore: { _ in }, onDelete: { _ in }, now: { Self.now }, calendar: Self.calendar
        )
        await model.load()
        #expect(model.rows.count == FixedChoices.archivedTabLimit)
        #expect(model.rows.map(\.id) == tabs.map(\.id), "newest first across sections")
        model.query = "page"
        try await Task.sleep(for: FixedChoices.historySearchDelay * 4)
        #expect(model.rows.count == FixedChoices.archiveSearchLimit)
    }

    @Test func groupingAFullArchiveIsQuick() async {
        let tabs = (0 ..< FixedChoices.archivedTabLimit).map {
            Self.tab("Page\($0)", archivedAt: Self.now.addingTimeInterval(-Double($0) * 2_500))
        }
        var times: [Duration] = []
        for _ in 0 ..< 10 {
            let start = ContinuousClock.now
            let sections = await ArchiveModel.group(tabs, leavingOut: [], now: Self.now, calendar: Self.calendar)
            times.append(ContinuousClock.now - start)
            #expect(sections.reduce(0) { $0 + $1.rows.count } == tabs.count)
        }
        let median = times.sorted()[times.count / 2]
        print("[perf] archive grouping (\(tabs.count) rows, off main), median of 10: \(median)")
        #expect(median < .milliseconds(50))
    }

    @Test func footerSaysWhenTabsMoveHereAndThatTheyLeave() {
        #expect(ArchiveAfter.oneWeek.archiveFooter == "Tabs you haven't opened in a week move here, and leave after 30 days.")
        #expect(ArchiveAfter.oneDay.archiveFooter.contains("in a day"))
        #expect(ArchiveAfter.twelveHours.archiveFooter.contains("in 12 hours"))
        #expect(ArchiveAfter.never.archiveFooter == "Tabs here leave after 30 days.", "Never says nothing about moving")
        #expect(FixedChoices.archivedTabLifetime == 30 * 86_400, "the footers say 30 days")
    }

    @Test func searchWaitsForThePauseThenFilters() async throws {
        let archive = FakeArchive([
            Self.tab("Recipes", "https://recipes.example", archivedHoursAgo: 1),
            Self.tab("News", "https://news.example", archivedHoursAgo: 2),
        ])
        let model = ArchiveModel(store: archive, onRestore: { _ in }, onDelete: { _ in })
        await model.load()
        model.query = "rec"
        try await Task.sleep(for: FixedChoices.historySearchDelay * 4)
        #expect(model.rows.map(\.title) == ["Recipes"])
        #expect(await archive.queries.last == "rec")
    }
}
