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
        let discardCount = 10 - FixedChoices.extraLiveTabs - EngineChoices.maxSuspendedTabs
        try await waitUntil("discards") { tabs.filter { $0.tier == .discarded }.count == discardCount }
        // Newest first: live, then suspended, then discarded.
        let tiers = tabs.reversed().map(\.tier)
        #expect(tiers == Array(repeating: .live, count: FixedChoices.extraLiveTabs)
            + Array(repeating: .suspended, count: EngineChoices.maxSuspendedTabs)
            + Array(repeating: .discarded, count: discardCount))
        #expect(harness.pool.liveWebViewCount == 10 - discardCount)
        for tab in tabs where tab.tier == .discarded {
            #expect(harness.pool.existingWebView(for: tab) == nil)
            #expect(tab.title == "A")
        }

        // On the Duo split two tabs are visible, so only two others stay live.
        let left = tabs[9], right = tabs[8]
        harness.pool.attach(left, to: harness.container)
        harness.pool.attach(right, to: harness.makePane(size: CGSize(width: 390, height: 780)))
        let liveHidden = tabs.filter { $0.tier == .live && $0 !== left && $0 !== right }
        #expect(liveHidden.count == EngineChoices.maxLiveTabs - 2)
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
        #expect(a.tier == .live && b.tier == .live)
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
        #expect(abs(image.size.width - FixedChoices.thumbnailWidth) < 1)

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

    @Test func hiddenTabReloadsWhenShownAfterACrash() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let tab = harness.pool.makeTab()
        harness.pool.attach(tab, to: harness.container)
        try await harness.load("/a", in: tab)
        harness.pool.detach(tab)
        let webView = try #require(harness.pool.existingWebView(for: tab))
        try kill(webView)
        try await Task.sleep(for: .milliseconds(500))
        #expect(harness.server.requests.filter { $0.path == "/a" }.count == 1)
        harness.pool.attach(tab, to: harness.container)
        try await waitUntil("reloaded on attach") {
            harness.server.requests.filter { $0.path == "/a" }.count == 2 && !tab.isLoading
        }
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
