#if canImport(UIKit)
import BrowserCore
import UIKit
import WebKit

/// The website data store every regular tab shares: the default one, or in an isolated test run
/// (`TestIsolation`) a separate store of its own (`WKWebsiteDataStore(forIdentifier:)`), so tests
/// never read or change the owner's cookies, logins or site storage. Clearing browsing data clears
/// this store, never `.default()` directly.
///
/// The test store is persistent, not `.nonPersistent()`: WebKit keeps no session state for an
/// ephemeral store, so tabs would restore differently from the real app. An in-memory run gets a
/// new store each launch; the test store keeps one across relaunches until `-PlainResetStore`.
/// Every store an isolated run makes is recorded, and older ones are removed in the background
/// at the next isolated launch; stores the app did not record are never touched.
public enum AppWebsiteData {
    public static let store: WKWebsiteDataStore = {
        guard let id = isolatedBase else { return .default() }
        return WKWebsiteDataStore(forIdentifier: id)
    }()

    /// This isolated run's own store id (and the start of pruning older runs' stores); nil when
    /// not isolated.
    private static let isolatedBase: UUID? = {
        guard TestIsolation.isActive else { return nil }
        let ledger = IsolatedStores()
        let id = ledger.storeForThisLaunch()
        Task(priority: .background) { await ledger.prune(keeping: id) }
        return id
    }()

    /// Profiles' stores made this launch, so each profile has one store object.
    @MainActor private static var profileStores: [ProfileID: WKWebsiteDataStore] = [:]

    /// The website data store of a profile (docs/decisions.md, "Profiles, no tab groups"):
    /// Personal's is `store`; every other profile has a store of its own, named by an identifier
    /// (`WKWebsiteDataStore(forIdentifier:)`), so its cookies, logins, caches and site storage
    /// never meet another profile's. Normally the identifier is the profile's id. An isolated run
    /// maps each profile to a fresh identifier recorded with its own store, removed with it, so a
    /// test's profiles never reach a store the owner's profiles use.
    @MainActor
    public static func store(forProfile id: ProfileID) -> WKWebsiteDataStore {
        if id == Profile.defaultID { return store }
        if let made = profileStores[id] { return made }
        let made = WKWebsiteDataStore(forIdentifier: identifier(forProfile: id))
        profileStores[id] = made
        return made
    }

    private static func identifier(forProfile id: ProfileID) -> UUID {
        guard let base = isolatedBase else { return id }
        return IsolatedStores().profileStore(for: id, base: base)
    }

    /// Deletes a deleted profile's website data store with everything in it. Call it once no web
    /// view uses the store. WebKit refuses while a web view is still letting go of it, so it is
    /// tried again a moment later, and a store it still can't remove waits in a list for the next
    /// launch (`removeLeftoverProfileData(keeping:)`).
    @MainActor
    public static func removeProfileData(_ id: ProfileID) async {
        guard id != Profile.defaultID else { return }
        profileStores[id] = nil
        let store = identifier(forProfile: id)
        PendingRemovals.add(store)
        for attempt in 0 ..< 3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            if await remove(store) { return }
        }
    }

    /// Finishes the store removals an earlier launch could not, never for a profile in
    /// `profiles` (the saved list, read): a deletion that never reached the disk left its profile
    /// in place, and its store with it. Run after launch settles.
    @MainActor
    public static func removeLeftoverProfileData(keeping profiles: [ProfileID]) async {
        let live = Set(profiles.filter { $0 != Profile.defaultID }.map(identifier(forProfile:)))
        for store in PendingRemovals.all {
            if live.contains(store) {
                PendingRemovals.remove(store)
            } else {
                _ = await remove(store)
            }
        }
    }

    /// Removes the store; true when it is gone (or never existed). Drops it from the list then.
    @MainActor
    private static func remove(_ store: UUID) async -> Bool {
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: store)
        } catch {
            guard !(await WKWebsiteDataStore.allDataStoreIdentifiers).contains(store) else { return false }
        }
        PendingRemovals.remove(store)
        IsolatedStores.forgetProfileStore(store)
        return true
    }

    /// Clear History and Data: every cookie, cache and storage entry of Personal and of each of
    /// `profiles`. An isolated run clears its own stores only.
    @MainActor
    public static func removeAllData(profiles: [ProfileID]) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        for profile in Set(profiles + [Profile.defaultID]) {
            await store(forProfile: profile).removeData(ofTypes: types, modifiedSince: .distantPast)
        }
    }
}

/// Stores of deleted profiles that WebKit has not removed yet, in the app's defaults (the
/// isolated suite in a test run).
private enum PendingRemovals {
    private static let key = "plain.profileStoresToRemove"

    static var all: [UUID] {
        (TestIsolation.defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:))
    }

    static func add(_ id: UUID) {
        let ids = all.map(\.uuidString)
        guard !ids.contains(id.uuidString) else { return }
        TestIsolation.defaults.set(ids + [id.uuidString], forKey: key)
    }

    static func remove(_ id: UUID) {
        TestIsolation.defaults.set(all.filter { $0 != id }.map(\.uuidString), forKey: key)
    }
}

/// The record of website data stores isolated runs made, in a defaults suite of its own that no
/// isolated run empties.
private struct IsolatedStores {
    private static let suiteName = "plain.isolated-tests.website-data"
    private static let madeKey = "made"
    private static let testStoreKey = "testStore"
    /// Profile stores, "<run's store>|<profile>" to the store's identifier: kept while that run's
    /// store is kept (the test store keeps its profiles across relaunches), removed with it.
    private static let profileStoresKey = "profileStores"

    private var defaults: UserDefaults {
        guard let suite = UserDefaults(suiteName: Self.suiteName) else {
            fatalError("isolated test run without its defaults suite \(Self.suiteName)")
        }
        return suite
    }

    private var made: [String] { defaults.stringArray(forKey: Self.madeKey) ?? [] }

    private var profileStores: [String: String] {
        defaults.dictionary(forKey: Self.profileStoresKey) as? [String: String] ?? [:]
    }

    /// The identifier of `profile`'s store in the run whose own store is `base`; made and
    /// recorded on first use.
    func profileStore(for profile: UUID, base: UUID) -> UUID {
        let key = "\(base.uuidString)|\(profile.uuidString)"
        var stores = profileStores
        if let saved = stores[key].flatMap(UUID.init(uuidString:)) { return saved }
        let id = UUID()
        stores[key] = id.uuidString
        defaults.set(stores, forKey: Self.profileStoresKey)
        return id
    }

    /// A profile store was removed (its profile deleted in a test): no run needs it any more.
    static func forgetProfileStore(_ store: UUID) {
        guard TestIsolation.isActive else { return }
        let ledger = IsolatedStores()
        let stores = ledger.profileStores.filter { $0.value != store.uuidString }
        ledger.defaults.set(stores, forKey: profileStoresKey)
    }

    /// The test store's own store until a reset; a new one for an in-memory run or after a reset.
    func storeForThisLaunch() -> UUID {
        if TestIsolation.mode == .testStore, !TestIsolation.resetRequested,
           let saved = defaults.string(forKey: Self.testStoreKey).flatMap(UUID.init(uuidString:)) {
            return saved
        }
        let id = UUID()
        defaults.set(made + [id.uuidString], forKey: Self.madeKey)
        if TestIsolation.mode == .testStore { defaults.set(id.uuidString, forKey: Self.testStoreKey) }
        return id
    }

    /// Removes the recorded stores no run uses any more: all but this launch's and the test
    /// store's. Only stores this ledger recorded, so nothing else in the app is ever removed.
    @MainActor
    func prune(keeping current: UUID) async {
        let keep = Set([current.uuidString, defaults.string(forKey: Self.testStoreKey)].compactMap { $0 })
        for value in made where !keep.contains(value) {
            guard let id = UUID(uuidString: value) else { continue }
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
            } catch {
                // Not on disk (never written) or still busy: drop it only when it is gone.
                let existing = await WKWebsiteDataStore.allDataStoreIdentifiers
                if existing.contains(id) { continue }
            }
            defaults.set(made.filter { $0 != value }, forKey: Self.madeKey)
        }
        // Profile stores of runs whose own store is gone go with it.
        for (key, value) in profileStores {
            guard let base = key.split(separator: "|").first, !keep.contains(String(base)),
                  let id = UUID(uuidString: value) else { continue }
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
            } catch {
                if await WKWebsiteDataStore.allDataStoreIdentifiers.contains(id) { continue }
            }
            var stores = profileStores
            stores[key] = nil
            defaults.set(stores, forKey: Self.profileStoresKey)
        }
    }
}

extension UIPasteboard {
    /// Where Copy Link and Copy Image write: the general pasteboard, or in an isolated test run a
    /// private one (`TestIsolation.pasteboardName`), so tests never replace the owner's clipboard.
    public static var plain: UIPasteboard {
        guard TestIsolation.isActive else { return .general }
        return UIPasteboard(name: UIPasteboard.Name(TestIsolation.pasteboardName), create: true) ?? .withUniqueName()
    }
}
#endif
