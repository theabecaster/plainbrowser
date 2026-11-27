import Foundation

/// Whether this launch is an isolated test run, and where such a run keeps its state.
///
/// UI tests, perf runs and captures run on the owner's own phone, so an isolated run must never
/// read or change the owner's tabs, history, settings, cookies, icon, downloads or clipboard.
/// Every piece of state outside the run goes through this type:
///
/// - the database and tab state: a temporary folder (`directory`), or an in-memory database;
/// - user defaults: `defaults`, a separate suite, never `UserDefaults.standard`;
/// - website data: a non-persistent store (WebEngine, `AppWebsiteData`);
/// - thumbnails, downloads and TipKit's datastore: subfolders of `directory`;
/// - the Home Screen icon, Photos and the general pasteboard: stubbed or a private pasteboard.
///
/// The arguments work in every build configuration, Release included (the perf gate runs
/// Release on the device). They only ever point the app at throwaway state.
public nonisolated enum TestIsolation {
    /// A fresh, empty database in memory and fresh defaults, every launch.
    public static let inMemoryArgument = "-PlainInMemoryStore"
    /// A database, tab state and defaults in a temporary folder that survive relaunches (UI tests
    /// of session restore). Takes precedence over `inMemoryArgument`.
    public static let testStoreArgument = "-PlainTestStore"
    /// With `testStoreArgument`: empty the temporary store first.
    public static let resetArgument = "-PlainResetStore"
    /// The accessibility identifier of the marker every window carries in an isolated run. The UI
    /// tests check for it right after each launch and stop when it is missing.
    public static let markerIdentifier = "plainTestIsolation"
    /// The user-defaults suite isolated runs use instead of the app's own domain.
    public static let defaultsSuiteName = "plain.isolated-tests"
    /// The private pasteboard isolated runs copy to instead of the general one.
    public static let pasteboardName = "plain.isolated-tests"

    public enum Mode: String, Sendable {
        case off
        case inMemory
        case testStore
    }

    public static func mode(for arguments: [String]) -> Mode {
        if arguments.contains(testStoreArgument) { return .testStore }
        if arguments.contains(inMemoryArgument) { return .inMemory }
        return .off
    }

    /// This process's mode, from its launch arguments.
    public static let mode = mode(for: ProcessInfo.processInfo.arguments)

    public static var isActive: Bool { mode != .off }

    /// `-PlainResetStore` with `-PlainTestStore`.
    public static let resetRequested = mode == .testStore
        && ProcessInfo.processInfo.arguments.contains(resetArgument)

    /// The folder for everything an isolated run writes (database, tab state, thumbnails,
    /// downloads, tips), in the app's temporary directory; nil when not isolated. The test store's
    /// folder is fixed so it survives relaunches; an in-memory run gets a new one per launch.
    public static let directory: URL? = {
        let temporary = FileManager.default.temporaryDirectory
        switch mode {
        case .off: return nil
        case .testStore: return temporary.appending(path: "PlainUITestStore", directoryHint: .isDirectory)
        case .inMemory: return temporary.appending(path: "Plain-\(UUID().uuidString)", directoryHint: .isDirectory)
        }
    }()

    /// A subfolder of `directory`, or nil when not isolated.
    public static func folder(_ name: String) -> URL? {
        directory?.appending(path: name, directoryHint: .isDirectory)
    }

    /// The user defaults for every key the app owns: `.standard` normally, a separate suite in an
    /// isolated run. An in-memory run (and a test-store reset) starts the suite empty, so no value
    /// carries over from an earlier test; the test store keeps it across relaunches.
    /// `nonisolated(unsafe)`: `UserDefaults` is documented thread-safe but not marked `Sendable`.
    nonisolated(unsafe) public static let defaults: UserDefaults = {
        guard mode != .off, let suite = UserDefaults(suiteName: defaultsSuiteName) else { return .standard }
        if mode == .inMemory || resetRequested {
            suite.removePersistentDomain(forName: defaultsSuiteName)
        }
        return suite
    }()
}
