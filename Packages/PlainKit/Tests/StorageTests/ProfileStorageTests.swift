import BrowserCore
import Foundation
import GRDB
@testable import Storage
import Testing

/// Profiles on disk: the list and each tab's profile in the main database, the archive per
/// profile, and each extra profile's own history database (docs/decisions.md, "Profiles, no
/// tab groups").
@MainActor
@Suite struct ProfileStorageTests {
    func url(_ name: String) -> URL { URL(string: "https://\(name).example/")! }

    @Test func profilesAndEachTabsProfileRoundTrip() async throws {
        let database = try AppDatabase.inMemory()
        let store = TabStore(session: try await database.loadTabSession(), persistence: database.tabSession, now: { t0 })
        let work = try #require(store.addProfile(named: "Work"))
        #expect(store.renameProfile(Profile.defaultID, to: "Home"))
        let a = store.open(url("a"))
        let w = store.open(url("w"), profile: work)
        let closed = store.open(url("closed"), inBackground: true, profile: work)
        store.close(closed)
        await store.flush()

        let restored = TabStore(session: try await database.loadTabSession())
        #expect(restored.session == store.session)
        #expect(restored.profiles.map(\.name) == ["Home", "Work"])
        #expect(restored.tabs[a]?.profileID == Profile.defaultID)
        #expect(restored.tabs[w]?.profileID == work)
        #expect(restored.profileID(of: restored.windows[0].id) == work)
        #expect(restored.lastClosedBatch(in: work)?.tabs.first?.entry.profileID == work)
    }

    @Test func theArchiveIsPerProfileAndGoesWithItsProfile() async throws {
        let database = try AppDatabase.inMemory()
        let clock = TestDate()
        let store = TabStore(session: try await database.loadTabSession(), persistence: database.tabSession, now: { clock.now })
        let work = try #require(store.addProfile(named: "Work"))
        _ = store.open(url("personal-old"), title: "Recipes", inBackground: true)
        _ = store.open(url("work-old"), title: "Recipes at work", inBackground: true, profile: work)
        _ = store.open(url("shown"))
        clock.advance(2 * 86_400)
        #expect(await store.archiveIdleTabs(after: .oneDay).count == 2)
        await store.flush()

        #expect(try await database.archivedTabCount() == 2)
        #expect(try await database.archivedTabCount(profile: work) == 1)
        #expect(try await database.archivedTabs(profile: Profile.defaultID).map(\.entry.title) == ["Recipes"])
        #expect(try await database.searchArchivedTabs("recipes", profile: work).map(\.entry.title) == ["Recipes at work"])
        #expect(try await database.searchArchivedTabs("recipes").count == 2)

        store.deleteProfile(work)
        await store.flush()
        #expect(try await database.archivedTabCount(profile: work) == 0)
        #expect(try await database.archivedTabCount() == 1)
        #expect(try await database.loadTabSession().profiles == [.personal])
    }

    @Test func rowsFromBeforeProfilesArePersonal() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v8.cookieBannersOff")
        let id = UUID(), window = UUID()
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO tab (id, url, position, lastActiveAt, isArchived, windowID) VALUES (?, ?, 0, ?, 0, ?)",
                arguments: [id.uuidString, "https://old.example/", t0, window.uuidString]
            )
            try db.execute(
                sql: "INSERT INTO tabWindow (id, position, panes, focusedPane) VALUES (?, 0, ?, 0)",
                arguments: [window.uuidString, id.uuidString]
            )
        }
        try AppDatabase.migrator.migrate(queue)
        let session = try queue.read { db in try AppDatabase.readTabSession(db) }
        #expect(session.profiles.isEmpty)
        #expect(session.tabs.first?.profileID == Profile.defaultID)
        #expect(session.windows.first?.profileID == Profile.defaultID)
        let store = TabStore(session: session)
        #expect(store.profiles == [.personal])
        #expect(store.selectedTabID(in: window) == id)
    }

    @Test func eachProfileHasItsOwnHistoryDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "PlainProfiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let location = ProfileDataLocation(directory: root)
        let work = UUID(), gone = UUID()
        let database = try await location.open(work)
        _ = try await database.addFavorite(url: url("work"), title: "Work")
        #expect(try await database.favorites().map(\.title) == ["Work"])
        _ = try await location.open(gone)
        let folder = try #require(location.folder(for: work))
        #expect(FileManager.default.fileExists(atPath: folder.path))

        #expect(Set(await location.storedProfiles()) == [work, gone])
        await location.remove(gone)
        #expect(!FileManager.default.fileExists(atPath: location.folder(for: gone)!.path))
        #expect(await location.storedProfiles() == [work])
        #expect(FileManager.default.fileExists(atPath: folder.path))
        await location.remove(work)
        #expect(!FileManager.default.fileExists(atPath: folder.path))

        let memory = ProfileDataLocation(directory: nil)
        #expect(memory.folder(for: work) == nil)
        #expect(try await memory.open(work).favorites().isEmpty)
    }
}
