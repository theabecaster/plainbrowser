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

    private var options: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = Self.iterations
        return options
    }

    /// Cold launch: from `main` to the first display-link callback after the window is visible
    /// (the `launch.firstFrame` interval). Not XCTApplicationLaunchMetric: on iOS 27 it records nothing
    /// for Plain on the device and only in some runs on a simulator.
    func testLaunch() {
        let metric = XCTOSSignpostMetric(
            subsystem: Signposts.subsystem, category: Signposts.category, name: Signposts.name(Signposts.launchFirstFrame)
        )
        measure(metrics: [metric], options: options) {
            XCUIApplication.introSeen().launch()
        }
    }

    /// From `main` to the search field becoming first responder (the `launch` interval).
    func testLaunchToSearchFieldReady() {
        let metric = XCTOSSignpostMetric(
            subsystem: Signposts.subsystem, category: Signposts.category, name: Signposts.name(Signposts.launch)
        )
        measure(metrics: [metric], options: options) {
            XCUIApplication.introSeen().launch()
        }
    }

    /// Two local pages in two tabs, with the search sheet closed: the start of the tab tests.
    private func launchWithTwoTabs(_ server: TestServer) -> XCUIApplication {
        let app = XCUIApplication.introSeen()
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(server.address("/a") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Page A"].waitForExistence(timeout: 10))
        app.buttons["tabs"].press(forDuration: 1)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New Tab'")).firstMatch.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.typeText(server.address("/long") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Long Read"].waitForExistence(timeout: 10))
        return app
    }

    /// The tabs button to the gallery settled (`gallery.show`: the page zooming into its card).
    func testGalleryOpen() throws {
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = launchWithTwoTabs(server)
        let metric = XCTOSSignpostMetric(
            subsystem: Signposts.subsystem, category: Signposts.category, name: Signposts.name(Signposts.galleryShow)
        )
        let gallery = app.scrollViews["tabGallery"]
        measure(metrics: [metric], options: options) {
            app.buttons["tabs"].tap()
            XCTAssertTrue(gallery.waitForExistence(timeout: 3))
            app.buttons["galleryDone"].tap()
            XCTAssertTrue(gallery.waitForNonExistence(timeout: 3))
        }
    }

    /// A fast swipe along the address bar to the neighbour tab, until the page settles
    /// (`tab.swipe`). Alternates direction, so each iteration has a neighbour.
    func testBarSwipe() throws {
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = launchWithTwoTabs(server)
        let metric = XCTOSSignpostMetric(
            subsystem: Signposts.subsystem, category: Signposts.category, name: Signposts.name(Signposts.tabSwipe)
        )
        let pill = app.buttons["addressPill"]
        var toPrevious = true
        measure(metrics: [metric], options: options) {
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
