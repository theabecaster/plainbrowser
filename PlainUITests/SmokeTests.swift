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

    override func launch() {
        guard launchArguments.contains(Self.inMemoryArgument) || launchArguments.contains(Self.testStoreArgument) else {
            XCTFail("refusing to launch Plain without an isolation argument: \(launchArguments)")
            return
        }
        super.launch()
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

    /// Launch is done: the search field is up (search first) or the pill rests over the last tab.
    func waitForFirstScreen(timeout: TimeInterval = 5) -> Bool {
        let field = textFields["searchField"]
        let pill = buttons["addressPill"]
        let up = NSPredicate { _, _ in field.exists || pill.exists }
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: up, object: nil)], timeout: timeout) == .completed
    }
}

@MainActor
extension XCUIElement {
    var hasKeyboardFocus: Bool {
        (value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }
}
