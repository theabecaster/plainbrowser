import BrowserCore
import Foundation
import GRDB
@testable import Storage
import Testing

@MainActor
@Suite struct TabSessionTests {
    func url(_ name: String) -> URL { URL(string: "https://\(name).example/")! }

    func makeStore(_ database: AppDatabase, clock: @escaping @Sendable () -> Date = { t0 }) async throws -> TabStore {
        TabStore(session: try await database.loadTabSession(), persistence: database.tabSession, now: clock)
    }

    @Test func sessionRoundTripsThroughTheDatabase() async throws {
        let database = try AppDatabase.inMemory()
        let store = try await makeStore(database)
        let window = store.windows[0].id
        let a = store.open(url("a"), title: "A")
        let b = store.open(url("b"), inBackground: true)
        store.setPinned(true, for: b)
        let child = store.open(url("c"), opener: a, inBackground: true)
        let closed = store.open(url("closed"), inBackground: true)
        store.close(closed)
        store.open(url("private"), isPrivate: true)
        store.split(window, showing: child)
        store.updatePage(a, url: url("a2"), title: "A2")
        store.setThumbnail(TabThumbnail(fileName: "x.jpg", revision: 3), for: a)
        let second = store.addWindow()
        store.open(url("w2"), in: second)
        await store.flush()

        let restored = TabStore(session: try await database.loadTabSession())
        #expect(restored.session == store.session)
        #expect(restored.windows[0].tabIDs == [b, a, child])
        #expect(restored.windows[0].privateTabIDs.isEmpty, "private tabs are never written")
        #expect(restored.windows[0].panes == [nil, child])
        #expect(restored.tabs[a]?.thumbnail == TabThumbnail(fileName: "x.jpg", revision: 3))
        #expect(restored.tabs[child]?.openerID == a)
        #expect(restored.recentlyClosed.map { $0.tabs.map(\.entry.id) } == [[closed]])
        #expect(restored.reopenLastClosed() == [closed])
        #expect(restored.windows[0].tabIDs == [b, a, child, closed])
    }

    @Test func laterChangesUpdateAndRemoveRows() async throws {
        let database = try AppDatabase.inMemory()
        let store = try await makeStore(database)
        let window = store.windows[0].id
        let a = store.open(url("a")), b = store.open(url("b")), c = store.open(url("c"))
        await store.flush()
        store.move(c, to: 0)
        store.close(b)
        store.closeAllTabs(in: window)
        await store.flush()
        var loaded = try await database.loadTabSession()
        #expect(loaded.tabs.isEmpty)
        #expect(loaded.recentlyClosed.count == 2)

        // Reopening pops the newest batch: Close All's [c, a].
        let restored = TabStore(session: loaded, persistence: database.tabSession)
        #expect(restored.reopenLastClosed() == [c, a])
        restored.clearRecentlyClosed()
        await restored.flush()
        loaded = try await database.loadTabSession()
        #expect(loaded.windows[0].tabIDs == [c, a])
        #expect(loaded.recentlyClosed.isEmpty)
    }

    @Test func manyQuickChangesAreOneConsistentWrite() async throws {
        let database = try AppDatabase.inMemory()
        let store = try await makeStore(database)
        var ids: [TabID] = []
        for index in 0 ..< 50 { ids.append(store.open(url("t\(index)"))) }
        for (index, id) in ids.enumerated() { store.updatePage(id, url: url("t\(index)"), title: "Title \(index)") }
        await store.flush()
        let loaded = try await database.loadTabSession()
        #expect(loaded.windows[0].tabIDs == ids)
        #expect(Set(loaded.tabs.map(\.title)) == Set((0 ..< 50).map { "Title \($0)" }))
        #expect(database.tabSession.lastError == nil)
    }

    @Test func aTitleChangeWritesOneRow() async throws {
        let database = try AppDatabase.inMemory()
        let store = try await makeStore(database)
        for index in 0 ..< 100 { store.open(url("t\(index)"), inBackground: true) }
        let first = store.windows[0].tabIDs[0]
        let before = store.session
        store.updatePage(first, url: url("new"), title: "New")
        let after = store.session
        let (full, diff) = try await database.writer.write { db in
            var start = db.totalChangesCount
            _ = try TabSessionWriter.apply([.session(before)], written: nil, archiveLimit: 10, in: db)
            let full = db.totalChangesCount - start
            start = db.totalChangesCount
            _ = try TabSessionWriter.apply([.session(after)], written: before, archiveLimit: 10, in: db)
            return (full, db.totalChangesCount - start)
        }
        // One row, plus the full-text index triggers that follow it, against 100 rows and more.
        #expect(full >= 100)
        #expect(diff > 0 && diff < 10)
    }

    // MARK: Archive

    @Test func archivedTabsAreSearchableAndRestorable() async throws {
        let database = try AppDatabase.inMemory()
        let clock = TestDate()
        let store = try await makeStore(database, clock: { clock.now })
        let soup = store.open(URL(string: "https://recipes.example/soup")!, title: "Tomato soup at the Café", inBackground: true)
        let news = store.open(url("news"), title: "Morning news", inBackground: true)
        let open = store.open(url("open"), title: "Open soup")
        clock.advance(2 * 86_400)
        store.select(open)
        #expect(Set(await store.archiveIdleTabs(after: .oneDay)) == [soup, news])

        #expect(try await database.archivedTabCount() == 2)
        #expect(try await database.searchArchivedTabs("cafe").map(\.id) == [soup], "diacritics ignored")
        #expect(try await database.searchArchivedTabs("tom so").map(\.id) == [soup], "word prefixes")
        #expect(try await database.searchArchivedTabs("recipes.ex").map(\.id) == [soup], "address")
        #expect(try await database.searchArchivedTabs("soup").map(\.id) == [soup], "open tabs are not in the archive")
        #expect(try await database.searchArchivedTabs("caf\" OR \"news").isEmpty, "typed syntax is text, not FTS operators")
        #expect(Set(try await database.searchArchivedTabs("  ").map(\.id)) == [soup, news])
        let found = try #require(try await database.archivedTabs().first { $0.id == soup })
        #expect(found.archivedAt == clock.now)
        #expect(found.entry.title == "Tomato soup at the Café")

        store.restoreArchived(found.entry)
        #expect(try await database.archivedTabs().map(\.id) == [news])
        let loaded = try await database.loadTabSession()
        #expect(loaded.windows[0].tabIDs == [open, soup])
    }

    @Test func archiveOverTheCapDropsTheOldestWithTheirStateFiles() async throws {
        let database = try AppDatabase.inMemory()
        defer { try? FileManager.default.removeItem(at: database.tabStates.directory) }
        let writer = TabSessionWriter(writer: database.writer, tabStates: database.tabStates, delay: .zero, archiveLimit: 2)
        let entries = (0 ..< 3).map { TabEntry(url: url("t\($0)"), createdAt: t0) }
        for entry in entries { try await database.tabStates.write(Data([1]), for: entry.id) }
        for (index, entry) in entries.enumerated() {
            writer.enqueue(.archive([entry], at: t0.addingTimeInterval(Double(index))))
        }
        await writer.flush()
        #expect(try await database.archivedTabs().map(\.id) == [entries[2].id, entries[1].id])
        #expect(try await database.tabStates.read(for: entries[0].id) == nil)
        #expect(try await database.tabStates.read(for: entries[1].id) != nil)
    }

    @Test func deletingArchivedTabsRemovesRowsAndStateFiles() async throws {
        let database = try AppDatabase.inMemory()
        defer { try? FileManager.default.removeItem(at: database.tabStates.directory) }
        let store = try await makeStore(database)
        let entries = (0 ..< 3).map { TabEntry(url: url("t\($0)"), createdAt: t0) }
        for entry in entries { try await database.tabStates.write(Data([1]), for: entry.id) }
        database.tabSession.enqueue(.archive(entries, at: t0))
        store.deleteArchived([entries[0].id])
        #expect(try await database.archivedTabCount() == 2)
        #expect(try await database.tabStates.read(for: entries[0].id) == nil)
        store.clearArchive()
        #expect(try await database.archivedTabCount() == 0)
        #expect(try await database.tabStates.read(for: entries[2].id) == nil)
    }

    // MARK: State files

    @Test func closedTabsKeepStateFilesUntilTheyLeaveTheStack() async throws {
        let database = try AppDatabase.inMemory()
        defer { try? FileManager.default.removeItem(at: database.tabStates.directory) }
        let store = try await makeStore(database)
        let first = store.open(url("first"))
        await store.flush()
        try await database.tabStates.write(Data([1]), for: first)
        store.close(first)
        await store.flush()
        #expect(try await database.tabStates.read(for: first) != nil, "Reopen Closed Tab still needs it")
        try await database.removeOrphanedTabStates()
        #expect(try await database.tabStates.read(for: first) != nil)
        #expect(try await database.referencedTabIDs().contains(first))

        for index in 0 ..< FixedChoices.recentlyClosedLimit { store.close(store.open(url("t\(index)"))) }
        await store.flush()
        #expect(try await database.tabStates.read(for: first) == nil)
        #expect(try await !database.referencedTabIDs().contains(first))
    }

    // MARK: Migration

    @Test func tabsSavedBeforeWindowsLoadIntoTheFirstWindowInOrder() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v3.siteIndex")
        let ids = [UUID(), UUID()]
        try queue.write { db in
            for (position, id) in ids.enumerated().reversed() {
                try db.execute(
                    sql: "INSERT INTO tab (id, url, title, position, lastActiveAt, isArchived) VALUES (?, ?, ?, ?, ?, 0)",
                    arguments: [id.uuidString, "https://old\(position).example/", "Old \(position)", position, t0]
                )
            }
        }
        try AppDatabase.migrator.migrate(queue)
        let session = try queue.read { db in try AppDatabase.readTabSession(db) }
        #expect(session.windows.isEmpty)
        let store = TabStore(session: session)
        #expect(store.windows[0].tabIDs == ids)
        #expect(store.tabs[ids[1]]?.createdAt == t0)
        #expect(store.tabs[ids[1]]?.title == "Old 1")
    }
}

/// A date the test moves by hand.
final class TestDate: @unchecked Sendable {
    private let lock = NSLock()
    private var date = t0
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
}
