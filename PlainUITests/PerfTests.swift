import PerfSignposts
import XCTest

/// The perf gate's measurements (perf/budgets.json). They mean something only on the device, in a
/// Release build: scripts/perf-gate.sh runs them that way through Perf.xctestplan. The smoke plan
/// skips them.
@MainActor
final class PerfTests: XCTestCase {
    private static let iterations = 5
    /// Long enough for the bar swipe's spring (`Motion.tabSwitchSpring`, 0.35 s) to settle with a
    /// wide margin for a loaded simulator; the interval ends well inside it.
    private static let swipeSettleWait: TimeInterval = 2
    /// Long enough for the gallery's zoom (`Motion.galleryZoom`, 0.42 s; Core Animation settles it
    /// near 1 s) to bring the gallery's bar in, with a margin for a loaded simulator.
    private static let galleryZoomWait: TimeInterval = 1.5

    private struct SetupFailed: Error {}

    private var options: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = Self.iterations
        return options
    }

    /// Cold launch with no tab (search first): from `main` to the first display-link callback after
    /// the window is visible (the `launch.firstFrame` interval). Not XCTApplicationLaunchMetric: on
    /// iOS 27 it records nothing for Plain on the device and only in some runs on a simulator. The
    /// test store holds no tab (`prepareLaunchStore`), so it stays a search-first launch.
    func testLaunch() {
        let metric = XCTOSSignpostMetric(
            subsystem: Signposts.subsystem, category: Signposts.category, name: Signposts.name(Signposts.launchFirstFrame)
        )
        prepareLaunchStore()
        measure(metrics: [metric], options: options) {
            Self.launchOnDiskStore().launch()
        }
    }

    /// From `main` to the search field becoming first responder (the `launch` interval), no tab.
    func testLaunchToSearchFieldReady() {
        let metric = XCTOSSignpostMetric(
            subsystem: Signposts.subsystem, category: Signposts.category, name: Signposts.name(Signposts.launch)
        )
        prepareLaunchStore()
        measure(metrics: [metric], options: options) {
            Self.launchOnDiskStore().launch()
        }
    }

    private static func emptyStoreApp() -> XCUIApplication {
        let app = XCUIApplication.introSeen()
        app.launchArguments += ["-PlainTestStore", "-PlainResetStore"]
        return app
    }

    /// Cold launch with a last tab: from `main` to the first frame with the tab's picture and the
    /// resting bar on it (`launch.firstFrame`; the picture's decode, and any wait for it, is
    /// inside). The tab is left once in a fresh test store; each iteration relaunches into it.
    func testLaunchToLastTab() throws {
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let setup = Self.emptyStoreApp()
        setup.launch()
        let field = setup.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(server.address("/long") + "\n")
        XCTAssertTrue(setup.webViews.staticTexts["Long Read"].waitForExistence(timeout: 10))
        // Leaving the app keeps the page and its picture for the next launch.
        XCUIApplication.leaveForAnotherApp()
        Thread.sleep(forTimeInterval: 3)
        setup.terminate()

        let metric = XCTOSSignpostMetric(
            subsystem: Signposts.subsystem, category: Signposts.category, name: Signposts.name(Signposts.launchFirstFrame)
        )
        measure(metrics: [metric], options: options) {
            let app = XCUIApplication.introSeen()
            app.launchArguments += ["-PlainTestStore"]
            app.launch()
        }
    }

    /// The launch tests open a database on disk like a real launch, not the in-memory one: the
    /// isolated test store, emptied and migrated once here, then reopened by every measured launch.
    private func prepareLaunchStore() {
        let app = XCUIApplication.introSeen()
        app.launchArguments += ["-PlainTestStore", "-PlainResetStore"]
        app.launch()
        // The search field shows before the database opens. The isolation marker reports the
        // store once it is created, migrated and attached; no UI is driven, so any layout works
        // (the Duo's outer bottom bar or inner top bar, any keyboard).
        XCTAssertTrue(app.waitForStoreReady(), "the test store did not open")
        app.terminate()
    }

    private static func launchOnDiskStore() -> XCUIApplication {
        let app = XCUIApplication.introSeen()
        app.launchArguments += ["-PlainTestStore"]
        return app
    }

    /// Two local pages in two tabs, side by side and both live, with the search sheet closed: the
    /// start of the tab tests. Always the same: the store starts empty each launch
    /// (`-PlainTestStore -PlainResetStore`, honored in Release), so tabs left by earlier runs (or,
    /// on the device, the owner's own) are never restored, archived at launch or made neighbours.
    private func launchWithTwoTabs(_ server: TestServer) throws -> XCUIApplication {
        let app = XCUIApplication.introSeen()
        app.launchArguments += ["-PlainTestStore", "-PlainResetStore"]
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(server.address("/a") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Page A"].waitForExistence(timeout: 10))
        // The tabs slot's long-press menu (in every layout: the outer bottom bar, the inner top
        // bar), then its New Tab by identifier: a label match could find another "New Tab".
        app.buttons["tabs"].press(forDuration: 1)
        let newTab = app.buttons["menu.newTab"]
        XCTAssertTrue(newTab.waitForExistence(timeout: 3))
        newTab.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.typeText(server.address("/long") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Long Read"].waitForExistence(timeout: 10))
        // Two tabs: the slot is Tabs, so a tap opens the gallery (docs/state-rules.md §3).
        let tabs = app.buttons["tabs"]
        guard tabs.waitForExistence(timeout: 3), tabs.label == "Tabs" else {
            XCTFail("setup did not reach two tabs; the tabs slot reads \(tabs.label)")
            throw SetupFailed()
        }
        return app
    }

    /// The tabs button to the gallery settled (`gallery.show`: the page zooming into its card).
    func testGalleryOpen() throws {
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = try launchWithTwoTabs(server)
        let metric = XCTOSSignpostMetric(
            subsystem: Signposts.subsystem, category: Signposts.category, name: Signposts.name(Signposts.galleryShow)
        )
        let gallery = app.scrollViews["tabGallery"]
        let done = app.buttons["galleryDone"]
        measure(metrics: [metric], options: options) {
            app.buttons["tabs"].tap()
            // The cards' scroll view exists from the first frame, but the gallery's bar (Done)
            // fades in over the zoom's second half: until then Done is not on screen, and a tap
            // finds no match. Wait out the zoom without querying the app (a query costs its main
            // thread mid-interval; `gallery.show` ends inside this wait), then wait for Done.
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "gallery settles")], timeout: Self.galleryZoomWait)
            XCTAssertTrue(done.waitForExistence(timeout: 3), "the gallery did not open")
            done.tap()
            XCTAssertTrue(gallery.waitForNonExistence(timeout: 3))
        }
    }

    /// A fast swipe along the address bar to the neighbour tab, from the finger lifting until the
    /// page settles (`tab.swipeSettle`; the drag itself is the test's scripted gesture). Alternates direction, so each iteration has a neighbour.
    func testBarSwipe() throws {
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = try launchWithTwoTabs(server)
        let metric = XCTOSSignpostMetric(
            subsystem: Signposts.subsystem, category: Signposts.category, name: Signposts.name(Signposts.tabSwipeSettle)
        )
        let pill = app.buttons["addressPill"]
        var toPrevious = true
        // The hand-off inside it (the new tab taking the page), for the per-step numbers.
        let handoff = XCTOSSignpostMetric(
            subsystem: Signposts.subsystem, category: Signposts.category, name: Signposts.name(Signposts.tabSwipeHandoff)
        )
        measure(metrics: [metric, handoff], options: options) {
            if toPrevious { pill.swipeRight(velocity: .fast) } else { pill.swipeLeft(velocity: .fast) }
            // The swipe call returns when the finger lifts, while the page still springs. The
            // metric only counts an interval that ends inside this block, so wait out the settle
            // here, without querying the app (a query costs its main thread mid-interval).
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "page settles")], timeout: Self.swipeSettleWait)
            // Then check the swipe really switched: the page it left is out of the window.
            let left = toPrevious ? "Long Read" : "Page A"
            XCTAssertFalse(app.webViews.staticTexts[left].exists, "the bar swipe did not switch tabs")
            toPrevious.toggle()
        }
    }

    /// Scrolling a long real page. Needs the network: it loads a Wikipedia article.
    func testPageScrollHitches() {
        let app = XCUIApplication.introSeen()
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("en.wikipedia.org/wiki/Web_browser\n")

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 10))
        // Wait for real content, not just the view.
        XCTAssertTrue(webView.staticTexts["Web browser"].firstMatch.waitForExistence(timeout: 20),
                      "page did not load; the hitch test needs the network")

        let options = self.options
        options.invocationOptions = [.manuallyStop]
        // XCTHitchMetric gives the hitch time ratio (ms/s) the budget is set in;
        // scrollingAndDecelerationMetric adds the scroll's duration and, on a device, its frame stats.
        let metrics: [any XCTMetric] = [XCTHitchMetric(application: app), XCTOSSignpostMetric.scrollingAndDecelerationMetric]
        measure(metrics: metrics, options: options) {
            webView.swipeUp(velocity: .fast)
            stopMeasuring()
            webView.swipeDown(velocity: .fast)
        }
    }
}
