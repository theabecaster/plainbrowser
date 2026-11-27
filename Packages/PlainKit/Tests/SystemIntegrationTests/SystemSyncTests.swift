import Foundation
import PlainShared
import Storage
@testable import SystemSync
import Testing
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

/// Records the index calls instead of touching Spotlight. It can fail the next replace, or hold
/// the first replace until `release()`, to test retries and ordering.
private actor FakeIndex: SpotlightIndexing {
    enum Call: Equatable {
        case replace([String], domain: String)
        case deleteAll
    }

    struct Failure: Error {}

    private(set) var calls: [Call] = []
    var failNext = false
    private var holdFirst = false
    private var held: CheckedContinuation<Void, Never>?
    private var isHolding = false

    init(holdFirst: Bool = false) {
        self.holdFirst = holdFirst
    }

    func setFailNext() { failNext = true }

    func replace(_ items: [SpotlightItem], inDomain domain: String) async throws {
        calls.append(.replace(items.map(\.identifier), domain: domain))
        if holdFirst {
            holdFirst = false
            isHolding = true
            await withCheckedContinuation { held = $0 }
        }
        if failNext {
            failNext = false
            throw Failure()
        }
    }

    func deleteAll() async throws {
        calls.append(.deleteAll)
    }

    var holding: Bool { isHolding && held != nil }

    func release() {
        held?.resume()
        held = nil
    }
}

private final class FakeWidgets: WidgetReloading, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reloads: Int { lock.withLock { count } }
    func reloadWidgets() { lock.withLock { count += 1 } }
}

@Suite struct SystemSyncTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "SystemSync-\(UUID().uuidString)")
    private var file: SharedFavoritesFile { SharedFavoritesFile(url: folder.appending(path: "favorites.json")) }
    private var indexed: SharedFavoritesFile { SharedFavoritesFile(url: folder.appending(path: "spotlight.json")) }

    private func favorite(_ name: String) -> SharedFavorite {
        SharedFavorite(url: URL(string: "https://\(name).example")!, title: name.uppercased())
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
        let file = file
        let sync = SystemSync(file: file, indexed: indexed, index: index, widgets: widgets)
        let following = Task { await sync.follow(database) }
        defer { following.cancel() }

        try await database.addFavorite(url: URL(string: "https://a.example")!, title: "A")
        try await eventually { file.read().map(\.title) == ["A"] }
        try await database.addFavorite(url: URL(string: "https://b.example")!, title: nil)
        try await eventually { file.read().map(\.title) == ["A", "b.example"] }
        try await database.removeFavorite(url: URL(string: "https://a.example")!)
        try await eventually { file.read().map(\.title) == ["b.example"] }
        try await eventually { await index.calls.last == .replace(["favorite:https://b.example"], domain: "favorites") }
        #expect(widgets.reloads >= 3)
        #expect(indexed.read().map(\.title) == ["b.example"])
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func anUnchangedListTouchesNothing() async throws {
        let favorites = [favorite("a")]
        try file.write(favorites)
        try indexed.write(favorites)
        let index = FakeIndex()
        let widgets = FakeWidgets()
        let changes = FakeWidgets()
        let sync = SystemSync(file: file, indexed: indexed, index: index, widgets: widgets) { changes.reloadWidgets() }
        // Launch: the same list as last time.
        await sync.apply(favorites)
        #expect(await index.calls.isEmpty)
        #expect(widgets.reloads == 0)
        await sync.apply([])
        #expect(await index.calls == [.replace([], domain: SpotlightItem.favoritesDomain)])
        #expect(widgets.reloads == 1)
        #expect(changes.reloads == 1)
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func aFailedIndexIsRetried() async throws {
        let index = FakeIndex()
        await index.setFailNext()
        let sync = SystemSync(file: file, indexed: indexed, index: index, widgets: FakeWidgets())
        await sync.apply([favorite("a")])
        #expect(indexed.read().isEmpty, "Spotlight did not take the list, so it is not remembered as indexed")
        #expect(file.read() == [favorite("a")], "the widgets still get it")
        // The same list again (a relaunch): Spotlight is tried again, the file is left alone.
        let relaunched = SystemSync(file: file, indexed: indexed, index: index, widgets: FakeWidgets())
        await relaunched.apply([favorite("a")])
        #expect(await index.calls.count == 2)
        #expect(indexed.read() == [favorite("a")])
        try? FileManager.default.removeItem(at: folder)
    }

    /// A replace that fails halfway may have emptied Spotlight: going back to the earlier list
    /// must index it again, now and after a relaunch.
    @Test func aFailedReplaceForgetsTheEarlierRecord() async throws {
        let index = FakeIndex()
        let sync = SystemSync(file: file, indexed: indexed, index: index, widgets: FakeWidgets())
        await sync.apply([favorite("a")])
        await index.setFailNext()
        await sync.apply([favorite("b")])
        #expect(indexed.read().isEmpty)
        let relaunched = SystemSync(file: file, indexed: indexed, index: index, widgets: FakeWidgets())
        await relaunched.apply([favorite("a")])
        #expect(await index.calls.map { if case .replace(let ids, _) = $0 { ids } else { [] } } == [
            ["favorite:https://a.example"], ["favorite:https://b.example"], ["favorite:https://a.example"],
        ])
        #expect(indexed.read() == [favorite("a")])
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func clearingBrowsingDataEmptiesSpotlightThenKeepsFavorites() async throws {
        let index = FakeIndex()
        let sync = SystemSync(file: nil, index: index, widgets: FakeWidgets())
        await sync.apply([favorite("a")])
        await sync.browsingDataCleared()
        #expect(await index.calls == [
            .replace(["favorite:https://a.example"], domain: "favorites"),
            .deleteAll,
            .replace(["favorite:https://a.example"], domain: "favorites"),
        ])
    }

    @Test func aClearNeverPutsBackAFavoriteRemovedAfterIt() async throws {
        let index = FakeIndex(holdFirst: true)
        let sync = SystemSync(file: nil, index: index, widgets: FakeWidgets())
        let first = Task { await sync.apply([favorite("a")]) }
        try await eventually { await index.holding }
        let clear = Task { await sync.browsingDataCleared() }
        try await Task.sleep(for: .milliseconds(20))
        let removal = Task { await sync.apply([]) }
        try await Task.sleep(for: .milliseconds(20))
        await index.release()
        _ = await (first.value, clear.value, removal.value)
        let calls = await index.calls
        #expect(calls.first == .replace(["favorite:https://a.example"], domain: "favorites"))
        #expect(calls.last == .replace([], domain: "favorites"), "the removal lands last: \(calls)")
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
