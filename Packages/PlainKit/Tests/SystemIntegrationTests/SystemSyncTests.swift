import Foundation
import PlainShared
import Storage
@testable import SystemSync
import Testing
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

/// Records the index calls instead of touching Spotlight.
private actor FakeIndex: SpotlightIndexing {
    enum Call: Equatable {
        case replace([String], domain: String)
        case deleteAll
    }

    private(set) var calls: [Call] = []

    func replace(_ items: [SpotlightItem], inDomain domain: String) async throws {
        calls.append(.replace(items.map(\.identifier), domain: domain))
    }

    func deleteAll() async throws {
        calls.append(.deleteAll)
    }
}

private final class FakeWidgets: WidgetReloading, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reloads: Int { lock.withLock { count } }
    func reloadWidgets() { lock.withLock { count += 1 } }
}

@Suite struct SystemSyncTests {
    private func temporaryFile() -> SharedFavoritesFile {
        SharedFavoritesFile(url: FileManager.default.temporaryDirectory
            .appending(path: "SystemSync-\(UUID().uuidString)/favorites.json"))
    }

    /// Waits until `condition` holds; the observation delivers on GRDB's queue.
    private func eventually(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0 ..< 200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition never held")
    }

    @Test func followsEveryFavoritesWriter() async throws {
        let database = try AppDatabase.inMemory()
        let index = FakeIndex()
        let widgets = FakeWidgets()
        let file = temporaryFile()
        let sync = SystemSync(file: file, index: index, widgets: widgets)
        let following = Task { await sync.follow(database) }
        defer { following.cancel() }

        try await database.addFavorite(url: URL(string: "https://a.example")!, title: "A")
        try await eventually { file.read().map(\.title) == ["A"] }
        try await database.addFavorite(url: URL(string: "https://b.example")!, title: nil)
        try await eventually { file.read().map(\.title) == ["A", "b.example"] }
        try await database.removeFavorite(url: URL(string: "https://a.example")!)
        try await eventually { file.read().map(\.title) == ["b.example"] }

        let last = await index.calls.last
        #expect(last == .replace(["favorite:https://b.example"], domain: SpotlightItem.favoritesDomain))
        #expect(widgets.reloads >= 3)
        try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
    }

    @Test func anUnchangedListTouchesNothing() async throws {
        let file = temporaryFile()
        let favorites = [SharedFavorite(url: URL(string: "https://a.example")!, title: "A")]
        try file.write(favorites)
        let index = FakeIndex()
        let widgets = FakeWidgets()
        let changes = FakeWidgets()
        let sync = SystemSync(file: file, index: index, widgets: widgets) { changes.reloadWidgets() }
        // Launch: the same list as last time.
        await sync.apply(favorites)
        #expect(await index.calls.isEmpty)
        #expect(widgets.reloads == 0)
        await sync.apply([])
        #expect(await index.calls == [.replace([], domain: SpotlightItem.favoritesDomain)])
        #expect(widgets.reloads == 1)
        #expect(changes.reloads == 1)
        try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
    }

    @Test func clearingBrowsingDataEmptiesSpotlightThenKeepsFavorites() async throws {
        let index = FakeIndex()
        let sync = SystemSync(file: nil, index: index, widgets: FakeWidgets())
        await sync.apply([SharedFavorite(url: URL(string: "https://a.example")!, title: "A")])
        await sync.browsingDataCleared()
        #expect(await index.calls == [
            .replace(["favorite:https://a.example"], domain: "favorites"),
            .deleteAll,
            .replace(["favorite:https://a.example"], domain: "favorites"),
        ])
    }

    @Test func spotlightIdentifiersOpenOnlyWebPages() {
        let item = SpotlightItem(favorite: SharedFavorite(url: URL(string: "https://a.example/x?y=1")!, title: "A"))
        #expect(SpotlightItem.url(fromIdentifier: item.identifier) == URL(string: "https://a.example/x?y=1"))
        #expect(SpotlightItem.url(fromIdentifier: "favorite:javascript:alert(1)") == nil)
        #expect(SpotlightItem.url(fromIdentifier: "other") == nil)
    }

    @Test func activitiesBecomeCommands() {
        let web = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        web.webpageURL = URL(string: "https://example.com/page")
        #expect(SystemActivity.command(from: web) == .open(URL(string: "https://example.com/page")!))
        #if canImport(CoreSpotlight)
        let result = NSUserActivity(activityType: CSSearchableItemActionType)
        result.userInfo = [CSSearchableItemActivityIdentifier: "favorite:https://a.example"]
        #expect(SystemActivity.command(from: result) == .open(URL(string: "https://a.example")!))
        let searchable = CoreSpotlightIndex.searchableItem(
            SpotlightItem(favorite: SharedFavorite(url: URL(string: "https://www.a.example")!, title: "A"))
        )
        #expect(searchable.attributeSet.title == "A")
        #expect(searchable.attributeSet.contentDescription == "a.example")
        #expect(searchable.expirationDate == .distantFuture)
        #endif
        #expect(SystemActivity.command(from: NSUserActivity(activityType: "other")) == nil)
    }
}
