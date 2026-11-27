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
        guard TestIsolation.isActive else { return .default() }
        let ledger = IsolatedStores()
        let id = ledger.storeForThisLaunch()
        Task(priority: .background) { await ledger.prune(keeping: id) }
        return WKWebsiteDataStore(forIdentifier: id)
    }()
}

/// The record of website data stores isolated runs made, in a defaults suite of its own that no
/// isolated run empties.
private struct IsolatedStores {
    private static let suiteName = "plain.isolated-tests.website-data"
    private static let madeKey = "made"
    private static let testStoreKey = "testStore"

    private var defaults: UserDefaults {
        guard let suite = UserDefaults(suiteName: Self.suiteName) else {
            fatalError("isolated test run without its defaults suite \(Self.suiteName)")
        }
        return suite
    }

    private var made: [String] { defaults.stringArray(forKey: Self.madeKey) ?? [] }

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
