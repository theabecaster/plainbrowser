import BrowserCore
import DesignSystem
import Foundation
import Observation
import PerfSignposts
import Storage

/// One row on the History screen.
public nonisolated struct HistoryRow: Hashable, Sendable, Identifiable {
    public var id: Int64
    public var url: URL
    public var title: String
    /// The address without scheme or `www.`, shown under the title.
    public var address: String
    public var visitedAt: Date
}

/// One day of history, newest first.
public nonisolated struct HistoryDay: Hashable, Sendable, Identifiable {
    /// The day's start.
    public var id: Date
    /// "Today", "Yesterday" or the date.
    public var title: String
    public var rows: [HistoryRow]
}

/// State for the History screen: visits grouped by day, searched through the history index.
@Observable
public final class HistoryModel {
    public private(set) var days: [HistoryDay] = []
    /// False until the first load finishes, so the screen doesn't flash its empty state.
    public private(set) var isLoaded = false
    /// The search text. Changing it searches after a short pause.
    public var query = "" {
        didSet {
            guard query != oldValue else { return }
            limit = FixedChoices.historyPageSize
            scheduleReload(after: FixedChoices.historySearchDelay)
        }
    }
    public var errorMessage: String?
    /// The last read failed: the screen says so with Try Again, never as the empty state.
    public private(set) var loadFailed = false
    /// Whether there is any history at all, whatever the search shows. Clear dims only when there
    /// is known to be none (docs/state-rules.md §6, Sheets), so it starts true and a failed read
    /// leaves it as it was.
    public private(set) var hasHistory = true

    public var isEmpty: Bool { days.isEmpty }

    private let store: any HistoryStoring
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let locale: Locale
    private var limit = FixedChoices.historyPageSize
    /// Whether the last load filled `limit`, so there may be more to load.
    private var mayHaveMore = false
    private var loadTask: Task<Void, Never>?
    /// Bumped by every load; an older load that finishes late is dropped.
    private var generation = 0

    public init(
        store: any HistoryStoring,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) {
        self.store = store
        self.now = now
        self.calendar = calendar
        self.locale = locale
    }

    /// Loads the first page. Call from the view's `.task`.
    public func load() async {
        loadTask?.cancel()
        await reload()
    }

    /// Records that the user opened a row's page. The view calls the presenter's open callback.
    public func opened(_ row: HistoryRow) {
        Signposts.signposter.emitEvent(Signposts.historyOpen)
    }

    /// Loads the next page when `row` is the last one shown.
    public func rowAppeared(_ row: HistoryRow) {
        guard mayHaveMore, row.id == days.last?.rows.last?.id else { return }
        mayHaveMore = false
        limit += FixedChoices.historyPageSize
        scheduleReload(after: nil)
    }

    /// Removes every visit to the row's page.
    public func delete(_ row: HistoryRow) async {
        let state = Signposts.signposter.beginInterval(Signposts.historyDelete)
        defer { Signposts.signposter.endInterval(Signposts.historyDelete, state) }
        let url = row.url
        // A load already under way may still hold this page; drop it, and reload once the
        // page is gone from the store.
        loadTask?.cancel()
        generation += 1
        days = days.compactMap { day in
            var day = day
            day.rows.removeAll { $0.url == url }
            return day.rows.isEmpty ? nil : day
        }
        do {
            try await store.deleteHistory(for: url)
        } catch {
            errorMessage = Wording.historyEditFailed
        }
        await reload()
    }

    public func clear(_ range: HistoryClearRange) async {
        let state = Signposts.signposter.beginInterval(Signposts.historyClear)
        defer { Signposts.signposter.endInterval(Signposts.historyClear, state) }
        let cleared: Bool
        do {
            try await store.clearHistory(since: range.start(now: now(), calendar: calendar))
            cleared = true
        } catch {
            errorMessage = Wording.historyEditFailed
            cleared = false
        }
        await reload()
        // With the rows gone: "All History" can take a moment, and the dialog asked first.
        if cleared { Haptic.success.play() }
    }

    // MARK: Loading

    private func scheduleReload(after delay: Duration?) {
        loadTask?.cancel()
        // Results for the old query or page are stale from now on, even if they arrive first.
        generation += 1
        loadTask = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.reload()
        }
    }

    private func reload() async {
        generation += 1
        let current = generation
        let state = Signposts.signposter.beginInterval(Signposts.historyLoad)
        defer { Signposts.signposter.endInterval(Signposts.historyLoad, state) }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = limit
        do {
            let visits = try await store.visits(matching: query, limit: limit)
            // A search that finds nothing says nothing about the rest of history: one more read of
            // a single visit tells whether there is any.
            let anyHistory = if visits.isEmpty, !query.isEmpty {
                try await !store.visits(matching: "", limit: 1).isEmpty
            } else {
                !visits.isEmpty
            }
            let grouped = await Self.group(visits, now: now(), calendar: calendar, locale: locale)
            guard current == generation else { return }
            days = grouped
            mayHaveMore = visits.count >= limit
            hasHistory = anyHistory
            loadFailed = false
            isLoaded = true
        } catch {
            guard current == generation, !(error is CancellationError) else { return }
            // Rows from an earlier read would be stale under the failure; it replaces them.
            days = []
            mayHaveMore = false
            loadFailed = true
            isLoaded = true
        }
    }

    /// Groups visits (newest first) by calendar day, off the main thread.
    @concurrent
    nonisolated static func group(_ visits: [HistoryVisit], now: Date, calendar: Calendar, locale: Locale) async -> [HistoryDay] {
        var days: [HistoryDay] = []
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let base = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let sameYear = base.weekday(.wide).month(.wide).day()
        let otherYear = sameYear.year()
        for (index, visit) in visits.enumerated() {
            let start = calendar.startOfDay(for: visit.visitedAt)
            let row = HistoryRow(
                id: visit.id ?? Int64(-1 - index),
                url: visit.url,
                title: visit.title.flatMap { $0.isEmpty ? nil : $0 } ?? displayAddress(visit.url),
                address: displayAddress(visit.url),
                visitedAt: visit.visitedAt
            )
            if days.last?.id == start {
                days[days.count - 1].rows.append(row)
            } else {
                let title: String = if start == today {
                    "Today"
                } else if start == yesterday {
                    "Yesterday"
                } else if calendar.isDate(start, equalTo: today, toGranularity: .year) {
                    start.formatted(sameYear)
                } else {
                    start.formatted(otherYear)
                }
                days.append(HistoryDay(id: start, title: title, rows: [row]))
            }
        }
        return days
    }

    /// The address as people read it: host and path, no scheme, `www.` or trailing slash.
    nonisolated static func displayAddress(_ url: URL) -> String {
        guard var host = url.host() else { return url.absoluteString }
        if host.lowercased().hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path()
        while path.hasSuffix("/") { path.removeLast() }
        return host + path
    }
}
