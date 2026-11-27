import BrowserCore
import Foundation
import Observation
import PerfSignposts
import Storage

/// Reads the archive for the Archive screen. `AppDatabase` has it; deletes and restores go
/// through the shell's `TabStore`, the one owner of tabs, so they are callbacks, not store calls.
public nonisolated protocol ArchiveStoring: Sendable {
    /// Archived tabs whose title or address matches `query`, newest first; all of them (up to
    /// `limit`) for an empty query.
    func archivedTabs(matching query: String, limit: Int) async throws -> [ArchivedTab]
}

extension AppDatabase: ArchiveStoring {
    public func archivedTabs(matching query: String, limit: Int) async throws -> [ArchivedTab] {
        try await searchArchivedTabs(query, limit: limit)
    }
}

/// One row on the Archive screen.
public nonisolated struct ArchiveRow: Hashable, Sendable, Identifiable {
    public var id: TabID { tab.id }
    public var tab: ArchivedTab
    /// The page title, else the address, else "Untitled".
    public var title: String
    /// The address without scheme or `www.`.
    public var address: String

    init(_ tab: ArchivedTab) {
        self.tab = tab
        let host = tab.entry.url.flatMap { Self.address(of: $0) } ?? ""
        let title = tab.entry.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = title.isEmpty ? (host.isEmpty ? "Untitled" : host) : title
        address = host
    }

    static func address(of url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

/// When a tab moved to the archive, as the Archive screen's sections name it.
public nonisolated enum ArchivePeriod: Int, Hashable, Sendable, CaseIterable {
    /// Since midnight (or later than now, if the clock moved back).
    case today
    /// The calendar day before.
    case yesterday
    /// The five days before yesterday: with Today and Yesterday, the last seven calendar days.
    case thisWeek
    /// Before that, up to the archive's 30 days.
    case earlier

    public var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .thisWeek: "This Week"
        case .earlier: "Earlier"
        }
    }

    /// The period of a tab archived at `date`, seen at `now`.
    static func of(_ date: Date, now: Date, calendar: Calendar) -> ArchivePeriod {
        let today = calendar.startOfDay(for: now)
        if date >= today { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), date >= yesterday { return .yesterday }
        if let week = calendar.date(byAdding: .day, value: -6, to: today), date >= week { return .thisWeek }
        return .earlier
    }
}

/// One section of the Archive screen: the tabs archived in one period, newest first.
public nonisolated struct ArchiveSection: Hashable, Sendable, Identifiable {
    public var id: ArchivePeriod { period }
    public var period: ArchivePeriod
    public var rows: [ArchiveRow]
    public var title: String { period.title }
}

/// State for the Archive screen: archived tabs, newest first, in sections by when they were
/// archived (Today, Yesterday, This Week, Earlier), searched by title and address. Restoring and
/// deleting are the shell's (`onRestore`, `onDelete`); the row leaves the list at once.
@Observable
public final class ArchiveModel {
    public private(set) var sections: [ArchiveSection] = []
    /// Every row, in order.
    public var rows: [ArchiveRow] { sections.flatMap(\.rows) }
    /// False until the first load finishes, so the screen doesn't flash its empty state.
    public private(set) var isLoaded = false
    /// The search text. Changing it searches after a short pause.
    public var query = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleReload(after: FixedChoices.historySearchDelay)
        }
    }
    public var errorMessage: String?
    /// The last read failed: the screen says so with Try Again, never as the empty state.
    public private(set) var loadFailed = false

    private let store: any ArchiveStoring
    private let onRestore: (ArchivedTab) -> Void
    private let onDelete: ([TabID]) -> Void
    private let now: () -> Date
    private let calendar: Calendar
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    /// Rows deleted here whose delete may not be written yet: never shown again.
    private var deleted: Set<TabID> = []

    public init(
        store: any ArchiveStoring,
        onRestore: @escaping (ArchivedTab) -> Void,
        onDelete: @escaping ([TabID]) -> Void,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.store = store
        self.onRestore = onRestore
        self.onDelete = onDelete
        self.now = now
        self.calendar = calendar
    }

    /// Loads the list. Call from the view's `.task`.
    public func load() async {
        loadTask?.cancel()
        await reload()
    }

    /// One tap: the tab comes back and opens.
    public func restore(_ row: ArchiveRow) {
        Signposts.signposter.emitEvent(Signposts.tabUnarchive)
        remove(row.id)
        onRestore(row.tab)
    }

    /// Swipe to delete: gone for good, no confirmation (docs/ui-reference.md, swipe actions).
    public func delete(_ row: ArchiveRow) {
        remove(row.id)
        onDelete([row.id])
    }

    /// Takes a row off the screen for good; a section left empty goes with it.
    private func remove(_ id: TabID) {
        deleted.insert(id)
        sections = sections.compactMap { section in
            var section = section
            section.rows.removeAll { $0.id == id }
            return section.rows.isEmpty ? nil : section
        }
    }

    private func scheduleReload(after delay: Duration) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    private func reload() async {
        generation += 1
        let current = generation
        let state = Signposts.signposter.beginInterval(Signposts.archiveLoad)
        defer { Signposts.signposter.endInterval(Signposts.archiveLoad, state) }
        // The whole archive with no query (it holds at most `archivedTabLimit`), so every section
        // is complete; a search shows its best matches.
        let isSearch = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let limit = isSearch ? FixedChoices.archiveSearchLimit : FixedChoices.archivedTabLimit
        do {
            let tabs = try await store.archivedTabs(matching: query, limit: limit)
            guard current == generation, !Task.isCancelled else { return }
            let grouped = await Self.group(tabs, leavingOut: deleted, now: now(), calendar: calendar)
            guard current == generation, !Task.isCancelled else { return }
            sections = grouped
            loadFailed = false
        } catch {
            guard current == generation, !(error is CancellationError) else { return }
            // Rows from an earlier read would be stale under the failure; it replaces them.
            sections = []
            loadFailed = true
        }
        isLoaded = true
    }

    /// Rows for `tabs` (newest first) in their periods, off the main thread.
    @concurrent
    nonisolated static func group(
        _ tabs: [ArchivedTab], leavingOut deleted: Set<TabID>, now: Date, calendar: Calendar
    ) async -> [ArchiveSection] {
        var sections: [ArchiveSection] = []
        for tab in tabs where !deleted.contains(tab.id) {
            let period = ArchivePeriod.of(tab.archivedAt, now: now, calendar: calendar)
            if let last = sections.indices.last, sections[last].period == period {
                sections[last].rows.append(ArchiveRow(tab))
            } else if let index = sections.firstIndex(where: { $0.period == period }) {
                // Out of order only if the clock moved: the row still joins its own period.
                sections[index].rows.append(ArchiveRow(tab))
            } else {
                sections.append(ArchiveSection(period: period, rows: [ArchiveRow(tab)]))
            }
        }
        return sections.sorted { $0.period.rawValue < $1.period.rawValue }
    }
}
