import PerfSignposts
import XCTest

/// The perf gate's measurements (perf/budgets.json). They mean something only on the device, in a
/// Release build: scripts/perf-gate.sh runs them that way through Perf.xctestplan. The smoke plan
/// skips them.
@MainActor
final class PerfTests: XCTestCase {
    private static let iterations = 5

    private var options: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = Self.iterations
        return options
    }

    /// Cold launch until the main thread is responsive after the first frame.
    func testLaunch() {
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            XCUIApplication().launch()
        }
    }

    /// From `main` to the search field becoming first responder (the `launch` interval).
    func testLaunchToSearchFieldReady() {
        let metric = XCTOSSignpostMetric(
            subsystem: Signposts.subsystem, category: Signposts.category, name: Signposts.name(Signposts.launch)
        )
        measure(metrics: [metric], options: options) {
            XCUIApplication().launch()
        }
    }

    /// Scrolling a long real page. Needs the network: it loads a Wikipedia article.
    func testPageScrollHitches() {
        let app = XCUIApplication()
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
