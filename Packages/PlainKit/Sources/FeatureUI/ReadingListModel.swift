import BrowserCore
import Foundation
import Observation
import PerfSignposts
import Storage

/// The reading list for the Reading List screen. `AppDatabase` has it.
public nonisolated protocol ReadingListStoring: Sendable {
    /// Unread pages first (newest saved first), then read ones; only matches for a non-empty `query`.
    func readingList(matching query: String, limit: Int) async throws -> [ReadingListItem]
    /// Marks the item read at `date`, or unread with nil.
    func setReadingListItemRead(id: Int64, at date: Date?) async throws
    func removeReadingListItem(id: Int64) async throws
}

extension AppDatabase: ReadingListStoring {}

/// One row on the Reading List screen.
public nonisolated struct ReadingListRow: Hashable, Sendable, Identifiable {
    public var id: Int64
    public var url: URL
    /// The page title, else its address.
    public var title: String
    /// The site, and the reading time when a copy is saved: "nytimes.com · 6 min".
    public var detail: String
    public var isRead: Bool
    /// A reader copy is saved, so the page opens offline.
    public var hasCopy: Bool

    init?(_ item: ReadingListItem) {
        guard let id = item.id else { return nil }
        self.id = id
        url = item.url
        let address = HistoryModel.displayAddress(item.url)
        let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = title.isEmpty ? address : title
        let site = item.url.host().map { $0.lowercased().hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? address
        detail = [site, item.readingMinutes.map { "\($0) min" }].compactMap { $0 }.joined(separator: " · ")
        isRead = item.isRead
        hasCopy = item.hasCopy
    }
}

/// State for the Reading List screen: unread pages, then read ones, searched by title and address.
/// Every edit shows at once and is written in order behind it (`WriteQueue`).
@Observable
public final class ReadingListModel {
    public private(set) var unread: [ReadingListRow] = []
    public private(set) var read: [ReadingListRow] = []
    /// False until the first load finishes, so the screen doesn't flash its empty state.
    public private(set) var isLoaded = false
    /// The last read failed: the screen says so with Try Again, never as the empty state.
    public private(set) var loadFailed = false
    public var errorMessage: String?
    /// The search text. Changing it searches after a short pause.
    public var query = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleReload(after: FixedChoices.historySearchDelay)
        }
    }

    public var isEmpty: Bool { unread.isEmpty && read.isEmpty }

    private let store: any ReadingListStoring
    private let now: @Sendable () -> Date
    private let writes = WriteQueue()
    private var loadTask: Task<Void, Never>?
    private var generation = 0

    public init(store: any ReadingListStoring, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// Loads the list. Call from the view's `.task`.
    public func load() async {
        loadTask?.cancel()
        await reload()
    }

    /// The user opened the row's page: it is read now (`FixedChoices.readingListMarksReadOnOpen`).
    /// The view hands the address to the presenter, which closes the sheet and loads it.
    public func opened(_ row: ReadingListRow) {
        Signposts.signposter.emitEvent(Signposts.readingListOpen)
        guard FixedChoices.readingListMarksReadOnOpen, !row.isRead else { return }
        setRead(true, row, signpost: false)
    }

    /// Swipe or menu: Mark as Read / Mark as Unread. The row moves to its section at once.
    public func toggleRead(_ row: ReadingListRow) {
        setRead(!row.isRead, row, signpost: true)
    }

    /// Swipe to delete: gone for good, no confirmation (docs/ui-reference.md, swipe actions).
    public func delete(_ row: ReadingListRow) {
        Signposts.signposter.emitEvent(Signposts.readingListEdit, "delete")
        unread.removeAll { $0.id == row.id }
        read.removeAll { $0.id == row.id }
        let store = store, id = row.id
        writes.enqueue({ try await store.removeReadingListItem(id: id) }, onError: { [weak self] _ in self?.failed() })
        reloadAfterEdit()
    }

    private func setRead(_ isRead: Bool, _ row: ReadingListRow, signpost: Bool) {
        if signpost {
            if isRead {
                Signposts.signposter.emitEvent(Signposts.readingListEdit, "read")
            } else {
                Signposts.signposter.emitEvent(Signposts.readingListEdit, "unread")
            }
        }
        var moved = row
        moved.isRead = isRead
        unread.removeAll { $0.id == row.id }
        read.removeAll { $0.id == row.id }
        if isRead {
            // Most recently read first.
            read.insert(moved, at: 0)
        } else {
            // Back among the unread, where its save date puts it; the next load sorts it exactly.
            unread.insert(moved, at: 0)
        }
        let store = store, id = row.id, date: Date? = isRead ? now() : nil
        writes.enqueue({ try await store.setReadingListItemRead(id: id, at: date) }, onError: { [weak self] _ in self?.failed() })
        reloadAfterEdit()
    }

    /// A load already under way holds the old state: its answer is dropped, and the list is read
    /// again once the edit is written (reads wait for writes), so a search in flight still lands
    /// and the moved row takes its exact place.
    private func reloadAfterEdit() {
        scheduleReload(after: .zero)
    }

    /// A write failed: say so, and show what the store holds.
    private func failed() {
        errorMessage = Wording.readingListEditFailed
        scheduleReload(after: .zero)
    }

    private func scheduleReload(after delay: Duration) {
        loadTask?.cancel()
        generation += 1
        loadTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.reload()
        }
    }

    private func reload() async {
        generation += 1
        let current = generation
        let state = Signposts.signposter.beginInterval(Signposts.readingListLoad)
        defer { Signposts.signposter.endInterval(Signposts.readingListLoad, state) }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = store
        do {
            // Reads wait for the edits already made, so a row never comes back before its write.
            let items = try await writes.perform { try await store.readingList(matching: query, limit: FixedChoices.readingListLimit) }
            guard current == generation else { return }
            let rows = items.compactMap(ReadingListRow.init)
            unread = rows.filter { !$0.isRead }
            read = rows.filter(\.isRead)
            loadFailed = false
        } catch {
            guard current == generation, !(error is CancellationError) else { return }
            unread = []
            read = []
            loadFailed = true
        }
        isLoaded = true
    }
}
