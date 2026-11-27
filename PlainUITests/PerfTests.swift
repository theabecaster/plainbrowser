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

    /// Long enough for the keyboard's rise (about 0.3–0.5 s) to finish, so `keyboardDidShow` ends
    /// the focus and new tab intervals inside the measured block, with a margin for a loaded
    /// simulator. The app is not queried meanwhile.
    private static let keyboardWait: TimeInterval = 1.5
    /// Long enough for the local suggestions (a database read) to reach the screen.
    private static let suggestionsWait: TimeInterval = 1

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
            app.launchArguments += ["-PlainTestStore", Self.splashArgument]
            app.launch()
        }
    }

    /// The measured launches play the launch splash, as a user's cold launch does (an isolated
    /// run has none unless it asks): the splash's window, layers and pictures are inside
    /// `launch.firstFrame`, so the budget holds the launch people get.
    private static let splashArgument = "-PlainSplash"

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
        app.launchArguments += ["-PlainTestStore", splashArgument]
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

    // MARK: Interactions after launch

    /// One local page, in an isolated in-memory store: the start of the interaction tests.
    private func launchOnPage(_ server: TestServer, _ path: String, heading: String) -> XCUIApplication {
        let app = XCUIApplication.introSeen()
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(server.address(path) + "\n")
        XCTAssertTrue(app.webViews.staticTexts[heading].waitForExistence(timeout: 20), "page \"\(heading)\" did not show")
        return app
    }

    /// A tap on the address pill until the keyboard rests under the focused field (`urlBar.ready`).
    /// Each iteration then loads the other page from the field, which closes the search sheet.
    func testAddressBarFocus() throws {
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = launchOnPage(server, "/a", heading: "Page A")
        let pill = app.buttons["addressPill"]
        let field = app.textFields["searchField"]
        let metric = XCTOSSignpostMetric(
            subsystem: Signposts.subsystem, category: Signposts.category, name: Signposts.name(Signposts.urlBarReady)
        )
        var toB = true
        measure(metrics: [metric], options: options) {
            XCTAssertTrue(pill.waitForExistence(timeout: 3))
            pill.tap()
            // The keyboard rises; `urlBar.ready` ends inside this wait. No query meanwhile.
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "keyboard up")], timeout: Self.keyboardWait)
            XCTAssertTrue(field.hasKeyboardFocus, "the tap did not focus the field")
            field.typeText(server.address(toB ? "/b" : "/a") + "\n")
            XCTAssertTrue(app.webViews.staticTexts[toB ? "Page B" : "Page A"].waitForExistence(timeout: 10))
            toB.toggle()
        }
    }

    /// One keystroke until its local suggestions (history) are on screen (`search.suggestions`).
    /// Two visited pages give the history rows. With "Plain Tes" typed, each iteration types the
    /// next letter and stops measuring before deleting it, so one keystroke is measured.
    func testKeystrokeToSuggestions() throws {
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = launchOnPage(server, "/a", heading: "Page A")
        let field = app.textFields["searchField"]
        app.buttons["addressPill"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText(server.address("/b") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Page B"].waitForExistence(timeout: 10))
        // History is written in batches (FixedChoices.historyFlushInterval, 2 s).
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "history written")], timeout: 2.5)
        app.buttons["addressPill"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "keyboard up")], timeout: Self.keyboardWait)
        // The text finds the visited pages ("Plain Test A", "Plain Test B").
        field.typeText("Plain Tes")
        XCTAssertTrue(app.buttons["Plain Test A"].waitForExistence(timeout: 5), "no history suggestion for page A")
        let metric = XCTOSSignpostMetric(
            subsystem: Signposts.subsystem, category: Signposts.category, name: Signposts.name(Signposts.suggestionsShown)
        )
        let options = self.options
        options.invocationOptions = [.manuallyStop]
        measure(metrics: [metric], options: options) {
            field.typeText("t")
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "suggestions shown")], timeout: Self.suggestionsWait)
            stopMeasuring()
            field.typeText(XCUIKeyboardKey.delete.rawValue)
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "suggestions shown")], timeout: Self.suggestionsWait)
        }
    }

    /// A link tap on a local page until the next page's first contentful paint, as the pages
    /// measure it (TestServer `/paint-start`, `/paint-target`): the start page notes the finger
    /// lifting, the target reports its Paint Timing entry. Each iteration goes back by a link.
    func testLinkTapToFirstPaint() throws {
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = launchOnPage(server, "/paint-start", heading: "Paint Start")
        let metric = PageReportedMetric(identifier: "dev.plain.linkPaint", displayName: "Link tap to first paint")
        var previous = ""
        measure(metrics: [metric], options: options) {
            let link = app.webViews.links["Open Paint Target"]
            XCTAssertTrue(link.waitForExistence(timeout: 5))
            link.tap()
            // "Paint <ms> <how> <tap>": the tap's time makes each report new, so a page kept from
            // the iteration before can't answer for this one.
            // Only Paint Timing's own entry counts ("fcp"); the page's animation-frame stand-in
            // ("raf") measures something else, and leaves the iteration without a value.
            let painted = NSPredicate(format: "label MATCHES %@ AND label != %@", "Paint [0-9.]+ [a-z]+ [0-9]+", previous)
            let report = app.webViews.staticTexts.matching(painted).firstMatch
            XCTAssertTrue(report.waitForExistence(timeout: 10), "the target page reported no paint")
            previous = report.label
            let words = previous.split(separator: " ")
            XCTAssertEqual(words.count == 4 ? words[2] : "", "fcp", "no first contentful paint entry: \(previous)")
            metric.record(words.count == 4 && words[2] == "fcp" ? Double(words[1]) : nil)
            let back = app.webViews.links["Back to Paint Start"]
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
            XCTAssertTrue(app.webViews.staticTexts["Paint Start"].waitForExistence(timeout: 10))
        }
    }

    /// A card tapped in the gallery until its page is visibly at rest (`gallery.openTab`: the card
    /// zooming into the page). Alternates between the two tabs.
    func testGalleryTabOpen() throws {
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = try launchWithTwoTabs(server)
        let metric = XCTOSSignpostMetric(
            subsystem: Signposts.subsystem, category: Signposts.category, name: Signposts.name(Signposts.galleryOpenTab)
        )
        let gallery = app.scrollViews["tabGallery"]
        var target = (card: "Plain Test A", heading: "Page A")
        measure(metrics: [metric], options: options) {
            app.buttons["tabs"].tap()
            // The cards move until the zoom settles: a tap before then can land on the wrong one.
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "gallery settles")], timeout: Self.galleryZoomWait)
            XCTAssertTrue(app.buttons["galleryDone"].waitForExistence(timeout: 3), "the gallery did not open")
            let card = gallery.descendants(matching: .any).matching(identifier: "tabCard")
                .matching(NSPredicate(format: "label BEGINSWITH %@", target.card)).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 3))
            // The cascade (compact width, TabGalleryMetrics) focuses the current tab's card and
            // stacks the others over and under it, so the other card's middle is covered. Scroll
            // it into focus first (with two tabs a swipe can only land on it); a focused card's
            // middle shows. A grid shows every card whole and needs no scroll.
            let frame = Self.restingFrame(of: card)
            let current = gallery.descendants(matching: .any).matching(identifier: "tabCard")
                .matching(NSPredicate(format: "NOT (label BEGINSWITH %@)", target.card)).firstMatch.frame
            if frame.intersects(current) {
                if frame.midX < current.midX { gallery.swipeRight() } else { gallery.swipeLeft() }
                // A tap while the scroll still decelerates only stops it.
                _ = XCTWaiter.wait(for: [XCTestExpectation(description: "scroll settles")], timeout: Self.galleryZoomWait)
                _ = Self.restingFrame(of: card)
            }
            card.tap()
            // The card zooms into its page; `gallery.openTab` ends inside this wait.
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "page settles")], timeout: Self.galleryZoomWait)
            XCTAssertTrue(app.webViews.staticTexts[target.heading].waitForExistence(timeout: 3), "the card did not open its tab")
            target = target.card == "Plain Test A" ? ("Plain Long Read", "Long Read") : ("Plain Test A", "Page A")
        }
    }

    /// The tabs menu's New Tab until the keyboard rests under the new tab's focused search field
    /// (`tab.newReady`). Each iteration then loads a page in it, so the next New Tab opens a tab
    /// rather than refocusing an empty one.
    func testNewTabToSearchField() throws {
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = launchOnPage(server, "/a", heading: "Page A")
        let field = app.textFields["searchField"]
        let metric = XCTOSSignpostMetric(
            subsystem: Signposts.subsystem, category: Signposts.category, name: Signposts.name(Signposts.newTabReady)
        )
        measure(metrics: [metric], options: options) {
            openNewTab(app)
            // The keyboard rises; `tab.newReady` ends inside this wait. No query meanwhile.
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "keyboard up")], timeout: Self.keyboardWait)
            XCTAssertTrue(field.hasKeyboardFocus, "the new tab's field is not focused")
            field.typeText(server.address("/c") + "\n")
            XCTAssertTrue(app.webViews.staticTexts["Page C"].firstMatch.waitForExistence(timeout: 20), "page C did not show")
        }
    }

    /// The app's memory with ten tabs (local pages): XCTMemoryMetric's absolute physical footprint
    /// at the end of each block, after the gallery showed all ten cards (the gate reads it; its
    /// peak over the block is reported too). The pages' own memory is in WebKit's processes, not
    /// counted here.
    func testMemoryWithTenTabs() throws {
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let pages = [("/a", "Page A"), ("/b", "Page B"), ("/c", "Page C"), ("/long", "Long Read"), ("/article", "The Quiet Page"),
                     ("/footer", "Footer Page"), ("/light-site", "Light Only"), ("/dark-site", "Own Dark Design"),
                     ("/count", "Load 1"), ("/paint-start", "Paint Start")]
        let app = launchOnPage(server, pages[0].0, heading: pages[0].1)
        let field = app.textFields["searchField"]
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        for (path, heading) in pages.dropFirst() {
            openNewTab(app)
            let typing = XCTNSPredicateExpectation(predicate: focused, object: field)
            XCTAssertEqual(XCTWaiter().wait(for: [typing], timeout: 5), .completed, "the new tab's field is not focused")
            field.typeText(server.address(path) + "\n")
            XCTAssertTrue(app.webViews.staticTexts[heading].firstMatch.waitForExistence(timeout: 10), "page \"\(heading)\" did not show")
        }
        let done = app.buttons["galleryDone"]
        let gallery = app.scrollViews["tabGallery"]
        measure(metrics: [XCTMemoryMetric(application: app)], options: options) {
            app.buttons["tabs"].tap()
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "gallery settles")], timeout: Self.galleryZoomWait)
            XCTAssertTrue(done.waitForExistence(timeout: 3), "the gallery did not open")
            done.tap()
            XCTAssertTrue(gallery.waitForNonExistence(timeout: 3))
        }
    }

    /// Scrolling a large light-only page darkened by dark pages (TestServer `/big`, with Plain's
    /// appearance set to Dark in the isolated store). Local, so no network.
    func testHeavyPageScrollHitches() throws {
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = launchOnPage(server, "/a", heading: "Page A")
        setAppearanceDark(app)
        let field = app.textFields["searchField"]
        app.buttons["addressPill"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText(server.address("/big") + "\n")
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.staticTexts["Big Page"].waitForExistence(timeout: 20), "the big page did not load")
        // Dark pages finish judging the page after load (docs/research/dark-mode.md: well under 1 s).
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "page darkened")], timeout: 2)

        let options = self.options
        options.invocationOptions = [.manuallyStop]
        let metrics: [any XCTMetric] = [XCTHitchMetric(application: app), XCTOSSignpostMetric.scrollingAndDecelerationMetric]
        measure(metrics: metrics, options: options) {
            webView.swipeUp(velocity: .fast)
            stopMeasuring()
            webView.swipeDown(velocity: .fast)
        }
    }

    /// The element's frame once it stops moving (a zoom or scroll can outlast a fixed wait on a
    /// loaded machine), checked every 0.15 s for up to 3 s.
    private static func restingFrame(of element: XCUIElement) -> CGRect {
        var frame = element.frame
        for _ in 0..<20 {
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "at rest")], timeout: 0.15)
            let next = element.frame
            if next == frame { break }
            frame = next
        }
        return frame
    }

    /// The tabs slot's long-press menu, then its New Tab (a regular tab; More's tab item opens a
    /// private one), by identifier, so it works in every layout.
    private func openNewTab(_ app: XCUIApplication) {
        let tabs = app.buttons["tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 3))
        tabs.press(forDuration: 1)
        let newTab = app.buttons["menu.newTab"]
        XCTAssertTrue(newTab.waitForExistence(timeout: 3))
        newTab.tap()
    }

    /// Settings > Appearance > Dark, then Done (the isolated store keeps it for this launch).
    private func setAppearanceDark(_ app: XCUIApplication) {
        let more = app.buttons["more"]
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        more.tap()
        let settings = app.buttons["menu.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()
        let row = app.buttons["settings.appearance"]
        XCTAssertTrue(row.waitForExistence(timeout: 3), "Appearance is in Settings")
        // The row waits for the saved settings.
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: row)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 10), .completed)
        row.tap()
        let dark = app.buttons["Dark"]
        XCTAssertTrue(dark.waitForExistence(timeout: 2))
        dark.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(more.waitForExistence(timeout: 3))
    }

    /// Summarize Page with Apple's on-device model, from the tap to the first words of the summary
    /// on screen (`summary.firstWords`: reading the page, fitting it, the model's first tokens).
    /// Skips where the model can't run (the item is left out): on a simulator it runs only when the
    /// Mac has Apple Intelligence on, and the Mac's model is not the phone's. Report-only: no
    /// budget yet in perf/budgets.json.
    func testSummaryStart() throws {
        let server = try TestServer()
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication.introSeen()
        app.launch()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(server.address("/article") + "\n")
        XCTAssertTrue(app.webViews.staticTexts["The Quiet Page"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        let more = app.buttons["more"]
        more.tap()
        guard app.buttons["menu.summarize"].waitForExistence(timeout: 3) else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
            throw XCTSkip("Apple Intelligence isn't available here")
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        Thread.sleep(forTimeInterval: 0.5)
        let metric = XCTOSSignpostMetric(
            subsystem: Signposts.subsystem, category: Signposts.category, name: Signposts.name(Signposts.summaryFirstWords)
        )
        let options = self.options
        options.invocationOptions = [.manuallyStop]
        measure(metrics: [metric], options: options) {
            more.tap()
            let summarize = app.buttons["menu.summarize"]
            XCTAssertTrue(summarize.waitForExistence(timeout: 3))
            summarize.tap()
            XCTAssertTrue(app.otherElements["summaryText"].firstMatch.waitForExistence(timeout: 60))
            stopMeasuring()
            app.buttons["Done"].tap()
            Thread.sleep(forTimeInterval: 0.8)
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

/// A number the page measured on its own clock (the link test's tap to first paint), handed to
/// XCTest as one measurement per iteration, so it lands in the result bundle like any metric.
/// XCTest asks for every iteration's measurements only after the last one, so each value is kept
/// with the time it was recorded and reported for the iteration whose span holds that time.
final class PageReportedMetric: NSObject, XCTMetric, @unchecked Sendable {
    /// Shared by every copy XCTest makes.
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var values: [(at: Date, value: Double)] = []
    }

    private struct NoValue: Error {}

    let identifier: String
    let displayName: String
    private let box: Box

    init(identifier: String, displayName: String) {
        self.identifier = identifier
        self.displayName = displayName
        box = Box()
    }

    private init(identifier: String, displayName: String, box: Box) {
        self.identifier = identifier
        self.displayName = displayName
        self.box = box
    }

    /// The running iteration's value, in ms; nil when the page reported none (the iteration then
    /// has no measurement, which fails it).
    func record(_ value: Double?) {
        guard let value else { return }
        box.lock.withLock { box.values.append((Date(), value)) }
    }

    func copy(with zone: NSZone? = nil) -> Any {
        PageReportedMetric(identifier: identifier, displayName: displayName, box: box)
    }

    func reportMeasurements(
        from startTime: XCTPerformanceMeasurementTimestamp, to endTime: XCTPerformanceMeasurementTimestamp
    ) throws -> [XCTPerformanceMeasurement] {
        let span = startTime.date...endTime.date
        guard let value = box.lock.withLock({ box.values.last { span.contains($0.at) }?.value }) else { throw NoValue() }
        return [XCTPerformanceMeasurement(identifier: identifier, displayName: displayName, doubleValue: value, unitSymbol: "ms")]
    }
}
