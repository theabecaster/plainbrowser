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

/// State for the Archive screen: archived tabs, newest first, searched by title and address.
/// Restoring and deleting are the shell's (`onRestore`, `onDelete`); the row leaves the list at once.
@Observable
public final class ArchiveModel {
    public private(set) var rows: [ArchiveRow] = []
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
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    /// Rows deleted here whose delete may not be written yet: never shown again.
    private var deleted: Set<TabID> = []

    public init(
        store: any ArchiveStoring,
        onRestore: @escaping (ArchivedTab) -> Void,
        onDelete: @escaping ([TabID]) -> Void
    ) {
        self.store = store
        self.onRestore = onRestore
        self.onDelete = onDelete
    }

    /// Loads the list. Call from the view's `.task`.
    public func load() async {
        loadTask?.cancel()
        await reload()
    }

    /// One tap: the tab comes back and opens.
    public func restore(_ row: ArchiveRow) {
        Signposts.signposter.emitEvent(Signposts.tabUnarchive)
        rows.removeAll { $0.id == row.id }
        deleted.insert(row.id)
        onRestore(row.tab)
    }

    /// Swipe to delete: gone for good, no confirmation (docs/ui-reference.md, swipe actions).
    public func delete(_ row: ArchiveRow) {
        rows.removeAll { $0.id == row.id }
        deleted.insert(row.id)
        onDelete([row.id])
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
        do {
            let tabs = try await store.archivedTabs(matching: query, limit: FixedChoices.archiveSearchLimit)
            guard current == generation, !Task.isCancelled else { return }
            rows = tabs.filter { !deleted.contains($0.id) }.map(ArchiveRow.init)
            loadFailed = false
        } catch {
            guard current == generation, !(error is CancellationError) else { return }
            // Rows from an earlier read would be stale under the failure; it replaces them.
            rows = []
            loadFailed = true
        }
        isLoaded = true
    }
}
