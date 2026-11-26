#if canImport(UIKit)
import BrowserCore
import Darwin
import Foundation
import Storage
import Testing
import UIKit
import WebKit
@testable import WebEngine

/// Tab tiers, discard and restore, crash recovery and thumbnails, with timings.
@Suite(.serialized) @MainActor
struct TierTests {
    @Test func leastRecentlyUsedTabsAreSuspendedThenDiscarded() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        var tabs: [Tab] = []
        for _ in 0..<10 {
            let tab = harness.pool.makeTab()
            harness.pool.attach(tab, to: harness.container)
            try await harness.load("/a", in: tab)
            harness.pool.detach(tab)
            tabs.append(tab)
        }
        let discardCount = 10 - EngineChoices.maxWebViews
        try await waitUntil("discards") { tabs.filter { $0.tier == .discarded }.count == discardCount }
        // Newest first: suspended (kept), then discarded.
        let tiers = tabs.reversed().map(\.tier)
        #expect(tiers == Array(repeating: .suspended, count: EngineChoices.maxWebViews)
            + Array(repeating: .discarded, count: discardCount))
        #expect(harness.pool.liveWebViewCount == EngineChoices.maxWebViews)
        for tab in tabs where tab.tier == .discarded {
            #expect(harness.pool.existingWebView(for: tab) == nil)
            #expect(tab.title == "A")
        }

        // The Duo split: two visible tabs count toward the web view limit.
        let left = tabs[0], right = tabs[1]
        harness.pool.attach(left, to: harness.container)
        harness.pool.attach(right, to: harness.makePane(size: CGSize(width: 390, height: 780)))
        #expect(left.tier == .live && right.tier == .live)
        try await waitUntil("limit kept") { harness.pool.liveWebViewCount == EngineChoices.maxWebViews }
        // A memory warning discards every hidden tab, never either pane of the split.
        harness.pool.handleMemoryWarning()
        try await waitUntil("hidden tabs discarded") { harness.pool.liveWebViewCount == 2 }
        #expect(left.tier == .live && right.tier == .live)
        #expect(harness.pool.existingWebView(for: left) != nil && harness.pool.existingWebView(for: right) != nil)
    }

    @Test func discardThenRestoreKeepsHistoryScrollAndSessionStorage() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let states = TabStateStore(directory: harness.directory.appending(path: "TabStates"))
        let pool = WebViewPool(
            dataStore: .nonPersistent(), tabStates: states,
            thumbnailDirectory: harness.directory.appending(path: "T2")
        )
        pool.host = harness.host
        let tab = pool.makeTab()
        pool.attach(tab, to: harness.container)
        tab.load(harness.server.url("/a"))
        try await waitUntil("A") { tab.title == "A" && !tab.isLoading }
        tab.load(harness.server.url("/tall"))
        try await waitUntil("Tall") { tab.title == "Tall" && !tab.isLoading }
        let webView = try #require(pool.existingWebView(for: tab))
        _ = try await webView.evaluateJavaScript("window.scrollTo(0, 600); sessionStorage.setItem('k', 'kept'); 0")
        try await waitUntil("scrolled") { webView.scrollView.contentOffset.y > 500 }
        // WebKit copies the scroll position into the history item a few hundred ms after scrolling
        // (measured: not at 200 ms, always by 350 ms). A tab is discarded long after it was
        // scrolled, so wait like a real one.
        try await Task.sleep(for: .milliseconds(500))

        pool.detach(tab)
        // A memory-warning discard skips the sessionStorage fetch; the last save (here the
        // resign-active flush) supplies it.
        await pool.saveAllTabs()
        let discardStart = ContinuousClock.now
        pool.handleMemoryWarning()
        try await waitUntil("discarded") { tab.tier == .discarded }
        let discardTime = ContinuousClock.now - discardStart
        #expect(pool.existingWebView(for: tab) == nil)
        let saved = try #require(tab.restoration)
        report("discard: \(String(format: "%.2f", ms(discardTime))) ms; interactionState \(saved.interactionState?.count ?? 0) B, sessionStorage \(saved.sessionStorage?.count ?? 0) B")
        #expect(saved.interactionState != nil)
        try await waitUntil("state file") { (try? Data(contentsOf: states.fileURL(for: tab.id))) != nil }
        let file = try #require(try await states.read(for: tab.id))
        #expect(try TabRestorationState(encoded: file) == saved)

        let restoreStart = ContinuousClock.now
        pool.attach(tab, to: harness.container)
        let attachTime = ContinuousClock.now - restoreStart
        let restored = try #require(pool.existingWebView(for: tab))
        try await waitUntil("restored page") { restored.url?.path() == "/tall" && !restored.isLoading }
        let restoreTime = ContinuousClock.now - restoreStart
        try? await waitUntil("scroll restored", timeout: .seconds(5)) { restored.scrollView.contentOffset.y > 500 }
        report("restored scroll offset: \(restored.scrollView.contentOffset.y)")
        #expect(restored.scrollView.contentOffset.y > 500)
        let scrollTime = ContinuousClock.now - restoreStart
        report(String(
            format: "restore discarded tab: attach call %.2f ms, page loaded %.2f ms, scroll back %.2f ms",
            ms(attachTime), ms(restoreTime), ms(scrollTime)
        ))
        #expect(tab.canGoBack)
        #expect(tab.tier == .live)
        let session = try await restored.evaluateJavaScript("sessionStorage.getItem('k')") as? String
        #expect(session == "kept")
        tab.goBack()
        try await waitUntil("back to A") { tab.title == "A" }
    }

    @Test func tabRestoredFromAPreviousLaunch() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let first = harness.pool.makeTab()
        harness.pool.attach(first, to: harness.container)
        try await harness.load("/a", in: first)
        try await harness.load("/b", in: first)
        let state = await first.restorationState()
        harness.pool.close(first)

        let reopened = harness.pool.makeTab(restoring: try TabRestorationState(encoded: state.encoded()))
        #expect(reopened.title == "B")
        #expect(reopened.tier == .discarded)
        harness.pool.attach(reopened, to: harness.container)
        try await harness.waitForLoad(of: harness.server.url("/b"), in: reopened)
        #expect(reopened.canGoBack)

        // Back on a tab that is still discarded restores it first, then goes back.
        let another = harness.pool.makeTab(restoring: state)
        another.goBack()
        try await waitUntil("restored, then back") { another.title == "A" && !another.isLoading }
        #expect(another.canGoForward)
    }

    @Test func discardDuringARestoreKeepsTheSavedState() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let source = harness.pool.makeTab()
        harness.pool.attach(source, to: harness.container)
        try await harness.load("/a", in: source)
        try await harness.load("/b", in: source)
        _ = try await harness.evaluate("sessionStorage.setItem('k', 'v'); 0", in: source)
        let state = await source.restorationState()
        #expect(state.sessionStorage != nil)
        harness.pool.close(source)

        let tab = harness.pool.makeTab(restoring: state)
        tab.reload()  // starts the restore in a hidden web view; sessionStorage restores first
        harness.pool.handleMemoryWarning()
        try await waitUntil("discarded again") { tab.tier == .discarded }
        #expect(tab.restoration == state)
    }

    @Test func attachingALiveTabIsFast() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let a = harness.pool.makeTab(), b = harness.pool.makeTab()
        for tab in [a, b] {
            harness.pool.attach(tab, to: harness.container)
            try await harness.load("/tall", in: tab)
            harness.pool.detach(tab)
        }
        var samples: [Duration] = []
        for round in 0..<20 {
            let tab = round.isMultiple(of: 2) ? a : b
            let start = ContinuousClock.now
            harness.pool.attach(tab, to: harness.container)
            samples.append(ContinuousClock.now - start)
            try await Task.sleep(for: .milliseconds(20))
            harness.pool.detach(tab)
        }
        report("attach live tab: \(describe(samples))")
        #expect(a.tier == .suspended && b.tier == .suspended)
    }

    @Test func thumbnailIsTakenWhenATabLeavesTheScreen() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        var timings: [(snapshot: Duration, write: Duration)] = []
        harness.pool.thumbnails.onStored = { _, snapshot, write in timings.append((snapshot, write)) }
        let tab = harness.pool.makeTab()
        for round in 0..<10 {
            harness.pool.attach(tab, to: harness.container)
            if round == 0 { try await harness.load("/tall", in: tab) }
            try await Task.sleep(for: .milliseconds(50))
            harness.pool.detach(tab)
            try await waitUntil("thumbnail \(round)") { timings.count == round + 1 }
        }
        report("thumbnail snapshot (main thread wait): \(describe(timings.map(\.snapshot)))")
        report("thumbnail encode+write (off main): \(describe(timings.map(\.write)))")
        #expect(tab.thumbnailRevision == 10)
        let image = try #require(await harness.pool.thumbnail(for: tab))
        report("thumbnail size \(image.size) @\(image.scale)x")
        let pixels = image.size.width * image.scale
        #expect(abs(pixels - FixedChoices.thumbnailWidth * EngineChoices.thumbnailPixelsPerPoint) < 2)

        // From disk after the memory cache is dropped.
        harness.pool.thumbnails.dropMemoryCache()
        let start = ContinuousClock.now
        let fromDisk = try #require(await harness.pool.thumbnail(for: tab))
        report(String(format: "thumbnail read+decode from disk: %.2f ms", ms(ContinuousClock.now - start)))
        #expect(fromDisk.size.width > 0)

        harness.pool.close(tab)
        try await waitUntil("file removed") {
            !FileManager.default.fileExists(atPath: harness.pool.thumbnails.fileURL(for: tab.id).path)
        }
    }

    // MARK: Crash recovery

    @Test func visibleTabReloadsAfterItsProcessIsKilled() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/a", in: tab)
        let webView = try #require(harness.pool.existingWebView(for: tab))
        _ = try await webView.evaluateJavaScript("window.marker = 1; 0")
        try kill(webView)
        try await waitUntil("reloaded") {
            harness.server.requests.filter { $0.path == "/a" }.count == 2 && !tab.isLoading
        }
        let marker = try await webView.evaluateJavaScript("window.marker === undefined")
        #expect(marker as? Bool == true)
        #expect(harness.host.keepsCrashing.isEmpty)
    }

    @Test func hiddenTabWhoseProcessIsKilledIsDiscardedThenRestored() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/a", in: tab)
        try await harness.load("/b", in: tab)
        harness.pool.detach(tab)
        let webView = try #require(harness.pool.existingWebView(for: tab))
        try kill(webView)
        // A kill of a suspended process is memory pressure, not a crash: the tab is discarded.
        try await waitUntil("discarded") { tab.tier == .discarded }
        #expect(harness.server.requests.filter { $0.path == "/b" }.count == 1)
        #expect(harness.host.keepsCrashing.isEmpty)
        harness.pool.attach(tab, to: harness.container)
        try await waitUntil("restored on attach") {
            harness.server.requests.filter { $0.path == "/b" }.count == 2 && !tab.isLoading && tab.title == "B"
        }
        #expect(tab.canGoBack)
    }

    @Test func tabsAreSavedAfterLoadingAndWhenTheAppLeaves() async throws {
        let harness = try await Harness(tabStates: true)
        defer { harness.cleanUp() }
        let store = TabStateStore(directory: harness.directory.appending(path: "TabStates"))
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/a", in: tab)
        try await waitUntil("debounced save", timeout: .seconds(5)) {
            FileManager.default.fileExists(atPath: store.fileURL(for: tab.id).path)
        }
        let saved = try TabRestorationState(encoded: try #require(try await store.read(for: tab.id)))
        #expect(saved.url == harness.server.url("/a"))
        #expect(saved.interactionState != nil)

        let other = harness.pool.makeTab()
        try await harness.load("/b", in: other)
        _ = try await harness.evaluate("sessionStorage.setItem('k', 'v'); 0", in: tab)
        await harness.pool.saveAllTabs()
        let flushed = try TabRestorationState(encoded: try #require(try await store.read(for: other.id)))
        #expect(flushed.url == harness.server.url("/b"))
        let withSession = try TabRestorationState(encoded: try #require(try await store.read(for: tab.id)))
        #expect(withSession.sessionStorage != nil)
    }

    @Test func restoredFormResultAsksBeforeSendingTheFormAgain() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/form", in: tab)
        _ = try await harness.evaluate("document.getElementById('f').submit(); 0", in: tab)
        try await waitUntil("form result") { tab.title == "B" && !tab.isLoading }
        let state = await tab.restorationState()
        #expect(state.isFormResult)
        harness.pool.close(tab)
        let posts = { harness.server.requests.filter { $0.method == "POST" }.count }
        #expect(posts() == 1)

        let restored = harness.pool.makeTab(restoring: state)
        harness.pool.attach(restored, to: harness.container)
        try await waitUntil("asked") { harness.host.resubmitAsks == 1 }
        try await waitUntil("awaiting resubmit") { restored.isAwaitingResubmit }
        try await Task.sleep(for: .milliseconds(300))
        #expect(posts() == 1)
        #expect(restored.canGoBack)

        harness.host.resubmitAnswer = true
        let again = harness.pool.makeTab(restoring: state)
        harness.pool.attach(again, to: harness.container)
        try await waitUntil("sent again") { posts() == 2 && again.title == "B" }
    }

    @Test func unreadableHistoryFallsBackToTheSavedURL() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let state = TabRestorationState(
            url: harness.server.url("/b"), title: "B", interactionState: Data("junk".utf8), sessionStorage: nil
        )
        let tab = harness.pool.makeTab(restoring: state)
        harness.pool.attach(tab, to: harness.container)
        try await harness.waitForLoad(of: harness.server.url("/b"), in: tab)
    }

    @Test func busyTabIsNeverDiscarded() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/a", in: tab)
        _ = try await harness.evaluate("location.href = '/big.bin'; 0", in: tab)
        try await waitUntil("download start") { !harness.host.startedDownloads.isEmpty }
        harness.pool.detach(tab)
        harness.pool.handleMemoryWarning()
        try await Task.sleep(for: .milliseconds(300))
        #expect(tab.tier == .suspended)
        #expect(harness.pool.existingWebView(for: tab) != nil)
        harness.host.startedDownloads[0].cancel()
        try await waitUntil("download end") { !harness.host.endedDownloads.isEmpty }
        harness.pool.handleMemoryWarning()
        try await waitUntil("discarded once idle") { tab.tier == .discarded }
    }

    @Test func crashLoopStopsAutomaticReloads() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/a", in: tab)
        for _ in 0...EngineChoices.crashReloadLimit {
            harness.pool.webContentProcessDidTerminate(tab)
        }
        #expect(harness.host.keepsCrashing.count == 1)
    }

    /// Kills the web view's WebContent process. Test only: reads WebKit's private process id.
    private func kill(_ webView: WKWebView) throws {
        let pid = try #require(webView.value(forKey: "_webProcessIdentifier") as? Int32)
        #expect(pid > 0)
        #expect(Darwin.kill(pid, SIGKILL) == 0)
    }
}
#endif
