import XCTest

/// The app launches into a focused search field, and a submitted address opens a page.
@MainActor
final class SmokeTests: XCTestCase {
    func testLaunchFocusesSearchField() {
        let app = XCUIApplication.introSeen()
        app.launch()

        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard is not up at launch")
        XCTAssertTrue(field.hasKeyboardFocus, "search field is not first responder at launch")
    }

    func testSubmittingAnAddressOpensAWebView() {
        let app = XCUIApplication.introSeen()
        app.launch()

        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("example.com\n")

        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10), "no web view after submit")
        // After submit the field rests as the URL pill, which carries the full address.
        let pill = app.buttons["addressPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        XCTAssertTrue((pill.value as? String)?.hasPrefix("https://example.com") ?? false)
        XCTAssertFalse(field.exists && field.hasKeyboardFocus, "field should give up focus after submit")
    }
}

@MainActor
extension XCUIApplication {
    /// The app as a returning user launches it: the first-run intro already seen. The argument
    /// sets the same user default the intro writes (argument domain), in Release builds too.
    static func introSeen() -> XCUIApplication {
        let app = XCUIApplication.isolated()
        app.launchArguments += ["-PlainIntroSeen", "YES"]
        return app
    }

    /// Plain with a throwaway database, tab state, defaults, website data, downloads and icon, so
    /// a UI test never touches the device owner's real data (TestIsolation in the app, any build).
    /// `-PlainTestStore` (a temporary on-disk store) takes precedence where a test needs relaunch
    /// persistence. The only way UI tests make Plain: scripts/lib/check-isolation.zsh fails on any
    /// other `XCUIApplication(` or on a `launchArguments =` that could drop the isolation argument.
    static func isolated() -> IsolatedApplication {
        // The test target's app, whatever bundle id it was built with (".dev" on the owner's device).
        let app = IsolatedApplication()
        app.launchArguments = [IsolatedApplication.inMemoryArgument]
        return app
    }
}

/// Plain, launched only in isolation. Before launching it checks that the launch arguments ask for
/// isolation, and launches nothing otherwise; right after, it checks that the app reports it (the
/// marker every isolated window carries) and terminates the app at once if it doesn't, so a build
/// that ignored the arguments (the Release perf run, once) can't go on using the owner's data.
@MainActor
final class IsolatedApplication: XCUIApplication {
    /// TestIsolation's arguments and marker (the UI tests can't import BrowserCore).
    static let inMemoryArgument = "-PlainInMemoryStore"
    static let testStoreArgument = "-PlainTestStore"
    static let markerIdentifier = "plainTestIsolation"
    static let storeReadyValue = "store:ready"

    override func launch() {
        guard isolationRequested else { return }
        applyMatrixRow()
        super.launch()
        checkIsolated()
    }

    /// A launch from a link (a widget or Spotlight result launching Plain cold): the same checks,
    /// before and after.
    override func open(_ url: URL) {
        guard isolationRequested else { return }
        applyMatrixRow()
        super.open(url)
        checkIsolated()
    }

    /// The device matrix row (scripts/matrix.sh, docs/device-matrix.md): extra launch arguments
    /// from `PLAIN_MATRIX_ARGS` (appended, never replacing the isolation argument) and the
    /// orientation from `PLAIN_MATRIX_ORIENTATION` (`landscape` or `portrait`). Unset: nothing.
    private func applyMatrixRow() {
        let environment = ProcessInfo.processInfo.environment
        let extra = (environment["PLAIN_MATRIX_ARGS"] ?? "").split(separator: " ").map(String.init)
        if !extra.isEmpty, !launchArguments.contains(extra[0]) { launchArguments += extra }
        switch environment["PLAIN_MATRIX_ORIENTATION"] {
        case "landscape": XCUIDevice.shared.orientation = .landscapeLeft
        case "portrait": XCUIDevice.shared.orientation = .portrait
        default: break
        }
    }

    private var isolationRequested: Bool {
        guard launchArguments.contains(Self.inMemoryArgument) || launchArguments.contains(Self.testStoreArgument) else {
            XCTFail("refusing to launch Plain without an isolation argument: \(launchArguments)")
            return false
        }
        return true
    }

    private func checkIsolated() {
        let marker = descendants(matching: .any).matching(identifier: Self.markerIdentifier).firstMatch
        guard marker.waitForExistence(timeout: 10) else {
            terminate()
            XCTFail("Plain did not report test isolation; terminated it so it can't touch the owner's data")
            return
        }
    }
}

@MainActor
extension XCUIApplication {
    /// Sends Plain to the background by bringing Settings forward: the app resigns active and
    /// leaves the foreground, which saves its tabs and its launch picture. The Home button does not
    /// do this on the iPhone Duo simulator (Plain stays active there).
    /// On a real phone (the owner's own) it presses Home instead, which does background the app there,
    /// so no other app is opened on it.
    static func leaveForAnotherApp() {
        #if targetEnvironment(simulator)
        XCUIApplication(bundleIdentifier: "com.apple.Preferences").activate()
        #else
        XCUIDevice.shared.press(.home)
        #endif
    }

    /// Waits until the app reports its database open, migrated and attached: the isolation
    /// marker's value gains `store:ready`. Reads the marker only and drives no UI, so it holds in
    /// every layout.
    func waitForStoreReady(timeout: TimeInterval = 10) -> Bool {
        let ready = NSPredicate(
            format: "identifier == %@ AND value CONTAINS %@",
            IsolatedApplication.markerIdentifier, IsolatedApplication.storeReadyValue
        )
        return descendants(matching: .any).matching(ready).firstMatch.waitForExistence(timeout: timeout)
    }

    /// Launch is done: the search field is up (search first) or the pill rests over the last tab.
    func waitForFirstScreen(timeout: TimeInterval = 5) -> Bool {
        let field = textFields["searchField"]
        let pill = buttons["addressPill"]
        let up = NSPredicate { _, _ in field.exists || pill.exists }
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: up, object: nil)], timeout: timeout) == .completed
    }
}

@MainActor
extension XCUIApplication {
    /// `-PlainHapticLog` (an isolated run only): the app records every haptic that passed its
    /// gates on a hidden element, `plainHapticLog`, valued `"<count> <kind>,<kind>,…"` (the last 8).
    static let hapticLogArgument = "-PlainHapticLog"

    /// The haptics played so far: how many, and the last few kinds, oldest first.
    func haptics() -> (count: Int, recent: [String]) {
        let log = descendants(matching: .any).matching(identifier: "plainHapticLog").firstMatch
        guard log.exists, let value = log.value as? String else { return (0, []) }
        let parts = value.split(separator: " ", maxSplits: 1)
        let count = parts.first.flatMap { Int($0) } ?? 0
        let recent = parts.count > 1 ? parts[1].split(separator: ",").map(String.init) : []
        return (count, recent)
    }

    /// Runs `action`, then checks that exactly `kinds` played, in order: it waits for them, then
    /// `settle` seconds more so a double fire or a late one shows up too.
    func expectHaptics(
        _ kinds: [String], timeout: TimeInterval = 5, settle: TimeInterval = 0.8,
        file: StaticString = #filePath, line: UInt = #line, after action: () -> Void
    ) {
        let before = haptics().count
        action()
        let deadline = Date().addingTimeInterval(timeout)
        while haptics().count < before + kinds.count, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        let after = haptics()
        let new = after.count - before
        let played = new > 0 ? Array(after.recent.suffix(min(new, after.recent.count))) : []
        XCTAssertEqual(new, kinds.count, "expected haptics \(kinds), got \(new): \(played)", file: file, line: line)
        XCTAssertEqual(played, kinds, file: file, line: line)
    }
}

@MainActor
extension XCUIElement {
    var hasKeyboardFocus: Bool {
        (value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }
}
