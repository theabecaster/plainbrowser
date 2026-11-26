// WebKit content-rule tests. They compile the real bundled lists, so they run on an iOS simulator
// only (`xcodebuild test -scheme PlainKit-Package -destination ...`); `swift test` on macOS skips
// them to stay fast.
#if os(iOS)
import ContentBlocking
import Foundation
import Testing
import WebKit

@MainActor
@Suite(.serialized) struct ContentBlockerTests {
    /// Cold compile of every bundled list into an empty store, then a warm launch: a new store
    /// object and a new blocker on the same folder, which must find every list without compiling.
    @Test func compilesOnceThenLooksUp() async throws {
        let (store, url) = try makeTemporaryStore()
        defer { removeStore(at: url) }

        // An old version of a bundled list and a list some other code owns.
        let tiny = #"[{"trigger":{"url-filter":"x"},"action":{"type":"block"}}]"#
        _ = try await store.compileContentRuleList(
            forIdentifier: "blocklist-01-0000000000000000", encodedContentRuleList: tiny)
        _ = try await store.compileContentRuleList(forIdentifier: "other-list", encodedContentRuleList: tiny)

        let cold = ContentBlocker(allowListStore: MemoryAllowListStore(), store: store)
        let coldReport = await cold.prepare()
        #expect(coldReport.failures.isEmpty, "\(coldReport.failures)")
        #expect(!coldReport.lists.isEmpty)
        #expect(coldReport.lists.allSatisfy { $0.compiled })
        #expect(cold.ruleLists.count == coldReport.lists.count)
        #expect(coldReport.removedStale == ["blocklist-01-0000000000000000"])
        let remaining = await store.availableIdentifiers() ?? []
        #expect(remaining.contains("other-list"))
        #expect(Set(remaining.filter { $0.hasPrefix("blocklist-") }) == Set(coldReport.lists.map(\.identifier)))

        let warm = ContentBlocker(allowListStore: MemoryAllowListStore(), store: WKContentRuleListStore(url: url))
        let warmReport = await warm.prepare()
        #expect(warmReport.failures.isEmpty, "\(warmReport.failures)")
        #expect(warmReport.lists.count == coldReport.lists.count)
        #expect(warmReport.lists.allSatisfy { !$0.compiled })

        log("cold compile", coldReport)
        log("warm lookup", warmReport)
    }

    @Test func blocksAdsAndHonorsTheAllowList() async throws {
        let (store, url) = try makeTemporaryStore()
        defer { removeStore(at: url) }
        let allowList = MemoryAllowListStore()
        let blocker = ContentBlocker(allowListStore: allowList, store: store)
        await blocker.prepare()
        let probe = PageProbe()

        // Blocked: the ad image never reaches the network layer, and the ad element is hidden.
        let newsURL = PageProbe.url(host: "news.example")
        let newsController = WKUserContentController()
        blocker.apply(to: newsController, forMainFrameURL: newsURL)
        let newsView = WKWebView(frame: .zero, configuration: probe.configuration(controller: newsController))
        let blocked = try await probe.load(newsURL, in: newsView)
        #expect(blocked == .init(adLoaded: false, ownImageLoaded: true, adElementHidden: true))
        #expect(!probe.requestedURLs.contains { $0.host == "ad.doubleclick.net" })

        // "Turn off on this site", then reload: everything loads.
        #expect(blocker.isBlockingEnabled(for: newsURL))
        blocker.setBlockingEnabled(false, forHost: "www.news.example")
        #expect(!blocker.isBlockingEnabled(for: newsURL))
        let allowed = try await probe.load(newsURL, in: newsView)
        #expect(allowed == .init(adLoaded: true, ownImageLoaded: true, adElementHidden: false))
        #expect(probe.requestedURLs.contains { $0.host == "ad.doubleclick.net" })

        // Another site in another tab is still blocked.
        let otherURL = PageProbe.url(host: "other.example")
        let otherController = WKUserContentController()
        blocker.apply(to: otherController, forMainFrameURL: otherURL)
        let otherView = WKWebView(frame: .zero, configuration: probe.configuration(controller: otherController))
        #expect(try await probe.load(otherURL, in: otherView).adLoaded == false)

        // The same tab navigating away from the allowed site gets blocking back.
        blocker.apply(to: newsController, forMainFrameURL: otherURL)
        #expect(try await probe.load(otherURL, in: newsView).adLoaded == false)

        // The choice was saved, and a new blocker (next launch) reads it back.
        await blocker.waitForPendingSaves()
        #expect(await allowList.sites == ["news.example"])
        let relaunched = ContentBlocker(allowListStore: allowList, store: store)
        await relaunched.prepare()
        #expect(!relaunched.isBlockingEnabled(for: newsURL))

        // Turning it back on removes the entry.
        relaunched.setBlockingEnabled(true, forHost: "news.example")
        await relaunched.waitForPendingSaves()
        #expect(await allowList.sites.isEmpty)
    }

    /// Lists finishing after a controller registered are attached to it then.
    @Test func attachesListsThatFinishLater() async throws {
        let (store, url) = try makeTemporaryStore()
        defer { removeStore(at: url) }
        let blocker = ContentBlocker(allowListStore: MemoryAllowListStore(), store: store)
        let probe = PageProbe()
        let pageURL = PageProbe.url(host: "early.example")
        let controller = WKUserContentController()
        blocker.apply(to: controller, forMainFrameURL: pageURL)
        #expect(blocker.ruleLists.isEmpty)

        await blocker.prepare()
        let webView = WKWebView(frame: .zero, configuration: probe.configuration(controller: controller))
        #expect(try await probe.load(pageURL, in: webView).adLoaded == false)

        // Edits made before the stored allow-list loads are kept on top of it.
        let allowList = MemoryAllowListStore(["kept.example"])
        let early = ContentBlocker(allowListStore: allowList, store: store)
        early.setBlockingEnabled(false, forHost: "early.example")
        await early.prepare()
        await early.waitForPendingSaves()
        #expect(await allowList.sites == ["kept.example", "early.example"])
    }

    /// An edit made before anything loaded is saved by `waitForPendingSaves()` alone.
    @Test func savesEditsMadeBeforePrepare() async throws {
        let (store, url) = try makeTemporaryStore()
        defer { removeStore(at: url) }
        let allowList = MemoryAllowListStore(["kept.example"])
        let blocker = ContentBlocker(allowListStore: allowList, store: store)
        blocker.setBlockingEnabled(false, forHost: "new.example")
        await blocker.waitForPendingSaves()
        #expect(await allowList.sites == ["kept.example", "new.example"])
        #expect(!blocker.isBlockingEnabled(for: URL(string: "https://kept.example/")))
    }

    /// A list whose file does not match the manifest's hash is skipped, not compiled.
    @Test func rejectsAListWithAWrongHash() async throws {
        let (store, url) = try makeTemporaryStore()
        defer { removeStore(at: url) }
        let resources = url.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let json = #"[{"trigger":{"url-filter":"ads"},"action":{"type":"block"}}]"#
        try Data(json.utf8).write(to: resources.appendingPathComponent("blocklist-01.json"))
        let manifest = RuleListManifest(lists: [
            .init(name: "blocklist-01", file: "blocklist-01.json", sha256: String(repeating: "0", count: 64), ruleCount: 1),
        ])
        try JSONEncoder().encode(manifest).write(to: resources.appendingPathComponent("manifest.json"))

        let blocker = ContentBlocker(allowListStore: MemoryAllowListStore(), store: store, resourceDirectory: resources)
        let report = await blocker.prepare()
        #expect(report.lists.isEmpty)
        #expect(report.failures.count == 1)
        #expect(blocker.ruleLists.isEmpty)
        #expect(blocker.isReady)
    }

    private func log(_ label: String, _ report: ContentBlocker.PrepareReport) {
        let lists = report.lists
            .map { "\($0.identifier) (\($0.ruleCount) rules) \(milliseconds($0.duration))" }
            .joined(separator: ", ")
        print("[ContentBlocking] \(label): total \(milliseconds(report.duration)); \(lists)")
    }
}
#endif
