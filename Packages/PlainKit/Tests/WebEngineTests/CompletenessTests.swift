#if canImport(UIKit)
import BrowserCore
import Foundation
import QuickLook
import Testing
import UIKit
import UniformTypeIdentifiers
import WebKit
@testable import WebEngine

/// Link menus, page zoom, find, PDFs, Quick Look and media state (docs/plan.md, M4).
@Suite(.serialized) @MainActor
struct CompletenessTests {
    // MARK: Link context menu

    @Test func webLinkMenuHasOpenCopyShareAndDownloadWithAPreview() async throws {
        let harness = try await Harness(route: M4Pages.route)
        defer { harness.cleanUp() }
        let tab = try await harness.loadedTab("/linked")
        let link = harness.server.url("/b")

        let menu = try #require(await harness.pool.linkMenu(for: link, in: tab))
        #expect(menu.sections == [[.openInNewTab, .openInBackground], [.copyLink, .share], [.downloadLinkedFile]])
        #expect(menu.hasPreview)
        #expect(menu.element.imageURL == nil)
        let titles = menu.menu { _ in }.children.compactMap { $0 as? UIMenu }.map { $0.children.map(\.title) }
        #expect(titles == [["Open in New Tab", "Open in Background"], ["Copy Link", "Share"], ["Download Linked File"]])

        // The shell says a second pane is on screen.
        harness.host.hasOtherPane = true
        let split = try #require(await harness.pool.linkMenu(for: link, in: tab))
        #expect(split.sections[0] == [.openInNewTab, .openInBackground, .openInOtherPane])
    }

    @Test func pressedImageInALinkAddsImageItems() async throws {
        let harness = try await Harness(route: M4Pages.route)
        defer { harness.cleanUp() }
        let tab = try await harness.loadedTab("/linked")
        _ = try await harness.evaluate(M4Pages.press("#pic"), in: tab)

        let menu = try #require(await harness.pool.linkMenu(for: harness.server.url("/b"), in: tab))
        #expect(menu.element.imageURL == harness.server.url("/image.png"))
        #expect(menu.sections.last == M4Pages.imageItems)
        #expect(menu.items.contains(.openInNewTab))
    }

    @Test func imageWithoutALinkGetsOnlyImageItems() async throws {
        let harness = try await Harness(route: M4Pages.route)
        defer { harness.cleanUp() }
        let tab = try await harness.loadedTab("/linked")
        _ = try await harness.evaluate(M4Pages.press("#lone"), in: tab)

        let menu = try #require(await harness.pool.linkMenu(for: nil, in: tab))
        #expect(menu.sections == [M4Pages.imageItems])
        #expect(!menu.hasPreview)
    }

    @Test func imageFromAnotherPressIsIgnored() async throws {
        let harness = try await Harness(route: M4Pages.route)
        defer { harness.cleanUp() }
        let tab = try await harness.loadedTab("/linked")
        // The last finger down was on the image inside /b's link; the menu is for another link.
        _ = try await harness.evaluate(M4Pages.press("#pic"), in: tab)
        let menu = try #require(await harness.pool.linkMenu(for: harness.server.url("/a"), in: tab))
        #expect(menu.element.imageURL == nil)
        // An unlinked image pressed last is not a link's image either (a press inside an iframe
        // never reaches the main document).
        _ = try await harness.evaluate(M4Pages.press("#lone"), in: tab)
        let framed = try #require(await harness.pool.linkMenu(for: harness.server.url("/b"), in: tab))
        #expect(framed.element.imageURL == nil)
    }

    @Test func pressInAnIframeHidesTheMainFramesOlderImage() async throws {
        let harness = try await Harness(route: M4Pages.route)
        defer { harness.cleanUp() }
        let tab = try await harness.loadedTab("/framed")
        _ = try await harness.evaluate(M4Pages.press("#lone"), in: tab)
        // Before any iframe press, the unlinked image counts.
        #expect(try #require(await harness.pool.linkMenu(for: nil, in: tab)).element.imageURL != nil)

        try await Task.sleep(for: .milliseconds(5))
        _ = try await harness.evaluate("""
            document.querySelector('iframe').contentDocument.body
              .dispatchEvent(new PointerEvent('pointerdown', { bubbles: true })); 0
            """, in: tab)
        let slot = try #require(harness.pool.slot(for: tab))
        try await waitUntil("iframe press reported") { slot.lastSubframePress > 0 }
        #expect(await harness.pool.linkMenu(for: nil, in: tab) == nil)
    }

    @Test func playersOutsideTheDocumentCountAfterARefresh() async throws {
        let harness = try await Harness(route: M4Pages.route)
        defer { harness.cleanUp() }
        let tab = try await harness.loadedTab("/media")
        _ = try await harness.evaluate("window.detached = new Audio('/tone.wav'); detached.loop = true; detached.play(); 0", in: tab)
        try await Task.sleep(for: .milliseconds(500))
        await tab.refreshMediaState()
        #expect(tab.isPlayingMedia && tab.isBusy)
        _ = try await harness.evaluate("detached.pause(); 0", in: tab)
        try await Task.sleep(for: .milliseconds(300))
        await tab.refreshMediaState()
        #expect(!tab.isPlayingMedia)
    }

    @Test func appLinkMenuHasNoOpenItemsAndNoPreview() async throws {
        let harness = try await Harness(route: M4Pages.route)
        defer { harness.cleanUp() }
        let tab = try await harness.loadedTab("/linked")
        let mail = try #require(URL(string: "mailto:someone@example.com"))
        let menu = try #require(await harness.pool.linkMenu(for: mail, in: tab))
        #expect(menu.sections == [[.copyLink, .share]])
        #expect(!menu.hasPreview)
        #expect(await harness.pool.linkMenu(for: nil, in: tab) == nil)
    }

    @Test func linkActionsReachTheHostOrRunInTheEngine() async throws {
        let harness = try await Harness(route: M4Pages.route)
        defer { harness.cleanUp() }
        let tab = try await harness.loadedTab("/linked")
        let link = harness.server.url("/doc.pdf")
        let element = LinkElement(linkURL: link, imageURL: harness.server.url("/image.png"))
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        harness.pool.pasteboard = pasteboard

        harness.pool.perform(.openInBackground, on: element, in: tab)
        harness.pool.perform(.openInOtherPane, on: element, in: tab)
        #expect(harness.host.openedLinks.map(\.placement) == [.backgroundTab, .otherPane])
        #expect(harness.host.openedLinks.allSatisfy { $0.url == link })

        harness.pool.perform(.share, on: element, in: tab)
        #expect(harness.host.sharedLinks == [link])

        harness.pool.perform(.copyLink, on: element, in: tab)
        #expect(pasteboard.url == link)

        harness.pool.perform(.downloadLinkedFile, on: element, in: tab)
        try await waitUntil("linked file download") { !harness.host.endedDownloads.isEmpty }
        #expect(harness.host.endedDownloads[0].fileURL?.lastPathComponent == "doc.pdf")
        #expect(harness.host.endedDownloads[0].tabID == tab.id)

        harness.pool.perform(.copyImage, on: element, in: tab)
        try await waitUntil("copy image") { harness.host.completedLinkActions.contains { $0.action == .copyImage } }
        #expect(harness.host.completedLinkActions.last?.succeeded == true)
        #expect(pasteboard.data(forPasteboardType: UTType.png.identifier) == M4Pages.png)
    }

    @Test func previewLoadsTheLinkInItsOwnWebView() async throws {
        let rules = RecordingRules()
        let harness = try await Harness(contentRules: rules, route: M4Pages.route)
        defer { harness.cleanUp() }
        let tab = try await harness.loadedTab("/linked")
        let link = harness.server.url("/b")
        var preview: UIViewController? = harness.pool.makeLinkPreview(link)
        let webView = try #require(preview?.view as? WKWebView)
        #expect(webView !== harness.pool.existingWebView(for: tab))
        #expect(webView.uiDelegate == nil && webView.navigationDelegate == nil)
        try await waitUntil("preview load") { webView.url == link && !webView.isLoading }
        let controller = ObjectIdentifier(webView.configuration.userContentController)
        #expect(rules.applied.contains { $0.controller == controller && $0.url == link })
        preview = nil
        #expect(rules.released.contains(controller))
    }

    // MARK: Page zoom

    @Test func zoomIsRememberedPerSiteAndAppliedOnCommit() async throws {
        let store = InMemorySitePageZoomStore()
        let harness = try await Harness(pageZooms: store, route: M4Pages.route)
        defer { harness.cleanUp() }
        let tab = try await harness.loadedTab("/a")
        let webView = try #require(harness.pool.existingWebView(for: tab))
        #expect(tab.pageZoom == 1 && tab.zoomPercent == 100)

        tab.zoomIn()
        tab.zoomIn()
        #expect(tab.pageZoom == 1.25 && tab.zoomPercent == 125)
        #expect(webView.pageZoom == 1.25)
        #expect(store.pageZoom(forSite: "127.0.0.1") == 1.25)

        // Same site: kept.
        try await harness.load("/b", in: tab)
        #expect(webView.pageZoom == 1.25 && tab.pageZoom == 1.25)
        // A page with no site: 100%.
        tab.load(try #require(URL(string: "about:blank")))
        try await waitUntil("about:blank") { tab.url?.scheme == "about" && !tab.isLoading }
        #expect(webView.pageZoom == 1 && tab.pageZoom == 1)

        // Another tab on the same site starts at the remembered zoom.
        let other = harness.pool.makeTab()
        harness.pool.attach(other, to: harness.makePane(size: CGSize(width: 390, height: 780)))
        try await harness.load("/a", in: other)
        #expect(other.pageZoom == 1.25)
        #expect(try #require(harness.pool.existingWebView(for: other)).pageZoom == 1.25)

        other.resetZoom()
        #expect(other.pageZoom == 1)
        #expect(store.pageZoom(forSite: "127.0.0.1") == nil)

        // The ends of the steps.
        for _ in 0..<20 { other.zoomOut() }
        #expect(other.pageZoom == FixedChoices.pageZoomSteps.first)
        #expect(!other.canZoomOut && other.canZoomIn)
    }

    // MARK: Find

    @Test func findUsesTheSystemFindInteraction() async throws {
        let harness = try await Harness(route: M4Pages.route)
        defer { harness.cleanUp() }
        let tab = try await harness.loadedTab("/a")
        let webView = try #require(harness.pool.existingWebView(for: tab))
        #expect(webView.isFindInteractionEnabled)
        #expect(webView.findInteraction != nil)
        harness.window.makeKeyAndVisible()
        tab.beginFind()
        try await waitUntil("find bar", timeout: .seconds(5)) {
            webView.findInteraction?.isFindNavigatorVisible == true
        }
        webView.findInteraction?.dismissFindNavigator()

        // A tab that is not on screen can't show it.
        harness.pool.detach(tab)
        tab.beginFind()
        #expect(webView.findInteraction?.isFindNavigatorVisible != true)
    }

    // MARK: PDFs and Quick Look

    @Test func pdfTabIsDetectedAndSavesThroughDownloads() async throws {
        let harness = try await Harness(route: M4Pages.route)
        defer { harness.cleanUp() }
        let tab = try await harness.loadedTab("/doc.pdf")
        #expect(tab.isPDF)

        tab.saveToDownloads()
        try await waitUntil("pdf saved") { !harness.host.endedDownloads.isEmpty }
        let download = harness.host.endedDownloads[0]
        let file = try #require(download.fileURL)
        #expect(file.lastPathComponent == "doc.pdf")
        #expect(FileManager.default.contents(atPath: file.path) == Pages.minimalPDF)
        #expect(!download.isInProgress && !download.isCancelled)

        try await harness.load("/a", in: tab)
        #expect(!tab.isPDF)
    }

    @Test func finishedDownloadIsAQuickLookItem() async throws {
        let harness = try await Harness(route: M4Pages.route)
        defer { harness.cleanUp() }
        let tab = try await harness.loadedTab("/a")
        tab.load(harness.server.url("/report.pdf"))
        try await waitUntil("download end") { !harness.host.endedDownloads.isEmpty }
        let download = harness.host.endedDownloads[0]
        let file = try #require(download.fileURL)
        #expect(QLPreviewController.canPreview(file as NSURL))
        #expect(harness.pool.downloads.downloads.contains { $0 === download })
        #expect(download.progress.completedUnitCount == Int64(Pages.minimalPDF.count))
    }

    // MARK: Media

    @Test func mediaConfigurationAllowsInlinePictureInPictureAndFullscreen() async throws {
        let harness = try await Harness(route: M4Pages.route)
        defer { harness.cleanUp() }
        let tab = try await harness.loadedTab("/a")
        let configuration = try #require(harness.pool.existingWebView(for: tab)).configuration
        #expect(configuration.allowsInlineMediaPlayback)
        #expect(configuration.allowsPictureInPictureMediaPlayback)
        #expect(configuration.preferences.isElementFullscreenEnabled)
        #expect(configuration.mediaTypesRequiringUserActionForPlayback == .audio)
    }

    @Test func playingMediaIsReportedAndKeepsTheTabFromBeingDiscarded() async throws {
        let harness = try await Harness(route: M4Pages.route)
        defer { harness.cleanUp() }
        let tab = try await harness.loadedTab("/media")
        #expect(!tab.isPlayingMedia && !tab.isBusy)

        // evaluateJavaScript counts as a user gesture, so audio may start.
        _ = try await harness.evaluate("document.getElementById('a').play(); 0", in: tab)
        try await waitUntil("playing") { tab.isPlayingMedia }
        #expect(tab.isBusy)

        // Push it out of the live tiers: it stays, because it plays.
        harness.pool.detach(tab)
        var others: [Tab] = []
        for _ in 0..<EngineChoices.maxWebViews {
            let other = harness.pool.makeTab()
            harness.pool.attach(other, to: harness.container)
            try await harness.load("/a", in: other)
            harness.pool.detach(other)
            others.append(other)
        }
        try await Task.sleep(for: .milliseconds(600))
        #expect(tab.tier == .suspended)
        #expect(harness.pool.existingWebView(for: tab) != nil)

        harness.pool.attach(tab, to: harness.container)
        _ = try await harness.evaluate("document.getElementById('a').pause(); 0", in: tab)
        try await waitUntil("paused") { !tab.isPlayingMedia }
        #expect(!tab.isBusy)

        // A new page starts silent.
        _ = try await harness.evaluate("document.getElementById('a').play(); 0", in: tab)
        try await waitUntil("playing again") { tab.isPlayingMedia }
        try await harness.load("/a", in: tab)
        #expect(!tab.isPlayingMedia)
    }
}

extension Harness {
    /// A new tab on the main pane with `path` loaded.
    func loadedTab(_ path: String) async throws -> Tab {
        let tab = pool.makeTab()
        pool.attach(tab, to: container)
        try await load(path, in: tab)
        return tab
    }
}

/// Pages for these tests; the rest come from `Pages`.
enum M4Pages {
    @Sendable static func route(_ request: TestServer.Request) -> TestServer.Response {
        switch request.path {
        case "/linked":
            return .html(Pages.page(title: "Linked", body: """
                <a id=link href='/b'><img id=pic src='/image.png' width=40 height=40></a>
                <a id=other href='/a'>A</a>
                <img id=lone src='/image.png' width=40 height=40>
                """))
        case "/framed":
            return .html(Pages.page(title: "Framed", body: """
                <img id=lone src='/image.png' width=40 height=40>
                <iframe src='/b' width=200 height=100></iframe>
                """))
        case "/image.png":
            return .data(png, type: "image/png")
        case "/report.pdf":
            return .data(Pages.minimalPDF, type: "application/pdf",
                         headers: ["Content-Disposition": "attachment; filename=\"report.pdf\""])
        case "/media":
            return .html(Pages.page(title: "Media", body: "<audio id=a src='/tone.wav' loop></audio>"))
        case "/tone.wav":
            return .data(wav, type: "audio/wav")
        default:
            return Pages.route(request)
        }
    }

    /// Save Image shows only when the host app declares the Photos usage text (the simulator's
    /// test runner does).
    @MainActor static var imageItems: [LinkMenuItem] {
        WebViewPool.canSaveToPhotos ? [.saveImage, .copyImage] : [.copyImage]
    }

    /// A finger landing on `selector`, as far as the page can tell.
    static func press(_ selector: String) -> String {
        "document.querySelector('\(selector)').dispatchEvent(new PointerEvent('pointerdown', { bubbles: true })); 0"
    }

    static let png: Data = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    /// Two seconds of a quiet 440 Hz tone, 8 kHz mono 16-bit PCM.
    static let wav: Data = {
        let rate = 8_000
        let samples = (0..<(rate * 2)).map { index in
            Int16(sin(Double(index) * 2 * .pi * 440 / Double(rate)) * 1_000)
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(samples.count * 2))
        for sample in samples { append(sample) }
        return data
    }()
}
#endif
