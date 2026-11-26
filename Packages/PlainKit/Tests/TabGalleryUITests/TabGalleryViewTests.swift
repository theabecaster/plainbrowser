#if canImport(UIKit)
import UIKit
import XCTest
@testable import TabGalleryUI

/// The gallery's UIKit behavior and its scroll cost with 100 tabs. iOS simulator only:
/// `xcodebuild test -scheme PlainKit-Package -destination id=<udid> -only-testing:TabGalleryUITests`.
@MainActor
final class TabGalleryViewTests: XCTestCase {
    private var window: UIWindow!

    override func setUp() async throws {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
    }

    private func show(_ data: any TabGalleryDataSource, size: CGSize = CGSize(width: 402, height: 874)) -> TabGalleryViewController {
        window.frame = CGRect(origin: .zero, size: size)
        let gallery = TabGalleryViewController(dataSource: data)
        window.rootViewController = gallery
        window.makeKeyAndVisible()
        gallery.view.layoutIfNeeded()
        return gallery
    }

    private func screenX(_ card: TabCardView, in gallery: TabGalleryViewController) -> CGFloat {
        card.center.x - gallery.scrollView.contentOffset.x
    }

    func testShowsTheCascadeWithTheSelectedTabInFocus() {
        let data = TabGalleryDemoData(count: 30, selectedIndex: 12)
        let gallery = show(data)
        XCTAssertEqual(gallery.metrics.style, .cascade)
        XCTAssertEqual(gallery.order.count, 30)
        let focused = gallery.cards[data.tabs[12].id]
        XCTAssertNotNil(focused)
        XCTAssertEqual(screenX(focused!, in: gallery), gallery.metrics.focusPoint.x, accuracy: 0.5)
        // A few cards around it, not all 30.
        XCTAssertLessThanOrEqual(gallery.cards.count, 8)
        XCTAssertNotNil(gallery.cards[data.tabs[11].id], "the card to the left peeks")
        XCTAssertNotNil(gallery.cards[data.tabs[13].id], "the card to the right peeks")
        // Later tabs lie on top.
        XCTAssertGreaterThan(gallery.cards[data.tabs[13].id]!.layer.zPosition, focused!.layer.zPosition)
    }

    func testScrollingMovesCardsAtTheirOwnSpeed() {
        let data = TabGalleryDemoData(count: 30, selectedIndex: 5)
        let gallery = show(data)
        let right = gallery.cards[data.tabs[6].id]!
        let left = gallery.cards[data.tabs[4].id]!
        let rightBefore = screenX(right, in: gallery)
        let leftBefore = screenX(left, in: gallery)
        gallery.scrollView.contentOffset.x -= 20
        // Scrolling back: the card right of the focus moves faster than the finger, the one to
        // the left slower (the cascade's parallax).
        XCTAssertGreaterThan(screenX(right, in: gallery) - rightBefore, 20)
        XCTAssertLessThan(screenX(left, in: gallery) - leftBefore, 20)
    }

    func testRegularWidthIsAGrid() {
        let data = TabGalleryDemoData(count: 30)
        let gallery = show(data, size: CGSize(width: 951, height: 669))
        gallery.traitOverrides.horizontalSizeClass = .regular
        gallery.view.setNeedsLayout()
        gallery.view.layoutIfNeeded()
        XCTAssertEqual(gallery.metrics.style, .grid)
        XCTAssertEqual(gallery.metrics.columns, 4)
        let first = gallery.cards[data.tabs[0].id]!.center
        let second = gallery.cards[data.tabs[1].id]!.center
        XCTAssertEqual(first.y, second.y)
        XCTAssertNil(gallery.cards[data.tabs[29].id], "only the pages near the screen have cards")
    }

    func testCloseClosesTheGapAndTheLastCloseCallsBack() async throws {
        let data = TabGalleryDemoData(count: 3, selectedIndex: 0)
        let gallery = show(data)
        var emptied = false
        gallery.onLastTabClosed = { emptied = true }
        let first = data.tabs[0].id
        let second = data.tabs[1].id
        gallery.closeTab(first, velocity: -1500)
        XCTAssertFalse(data.tabs.contains { $0.id == first })
        XCTAssertEqual(gallery.order.count, 2)
        // The next card starts where it was and springs into the gap.
        XCTAssertEqual(gallery.motion.slotOffset(second), 1)
        // Tests have no display to pace the frames: step the springs by hand.
        gallery.motion.settleForTesting()
        XCTAssertEqual(gallery.motion.slotOffset(second), 0)
        XCTAssertEqual(screenX(gallery.cards[second]!, in: gallery), gallery.metrics.focusPoint.x, accuracy: 0.5)
        XCTAssertFalse(emptied)
        gallery.closeTab(second)
        gallery.closeTab(data.tabs[0].id)
        XCTAssertTrue(emptied)
        XCTAssertTrue(data.tabs.isEmpty)
    }

    func testClosingTheLastCardSlidesTheStackOver() {
        let data = TabGalleryDemoData(count: 5, selectedIndex: 4)
        let gallery = show(data)
        let previous = data.tabs[3].id
        let before = screenX(gallery.cards[previous]!, in: gallery)
        gallery.closeTab(data.tabs[4].id)
        // The scroll offset moved back one card, but the cards have not jumped.
        XCTAssertEqual(gallery.scrollView.contentOffset.x, gallery.metrics.restingOffset(for: 3), accuracy: 0.5)
        XCTAssertGreaterThan(gallery.motion.scrollShift, 0)
        XCTAssertEqual(screenX(gallery.cards[previous]!, in: gallery), before, accuracy: 0.5)
    }

    func testTransitionZoomsTheGalleryAroundTheCard() async {
        let data = TabGalleryDemoData(count: 10, selectedIndex: 6)
        let gallery = show(data)
        gallery.scrollView.contentOffset.x = 0
        let id = data.tabs[6].id
        let page = UIView(frame: gallery.view.bounds)
        var ended: TabGalleryTransition.End?
        let transition = TabGalleryTransition(
            tabID: id, gallery: gallery, container: gallery.view, snapshot: page,
            pageFrame: gallery.view.bounds, from: .page
        ) { ended = $0 }
        XCTAssertEqual(transition.destination, .gallery)
        let card = gallery.cards[id]
        XCTAssertNotNil(card, "the card was brought into focus")
        XCTAssertEqual(card?.thumbnailContainer.alpha, 0)
        // At the page end the gallery is zoomed so that the card covers the page.
        let zoomed = gallery.thumbnailFrame(for: id, in: gallery.view)!
        XCTAssertEqual(zoomed.width, gallery.view.bounds.width, accuracy: 1)
        XCTAssertEqual(zoomed.minX, 0, accuracy: 1)
        XCTAssertEqual(zoomed.minY, 0, accuracy: 1)
        transition.run()
        transition.reverse()
        XCTAssertEqual(transition.destination, .page)
        transition.cancel()
        XCTAssertEqual(ended, .page)
        XCTAssertEqual(card?.thumbnailContainer.alpha, 1)
        XCTAssertEqual(gallery.scrollView.transform, .identity)
        let rest = gallery.thumbnailFrame(for: id, in: gallery.view)!
        XCTAssertEqual(rest.midX, gallery.metrics.focusPoint.x, accuracy: 1)
        XCTAssertNil(page.superview?.superview, "the moving snapshot is gone")
    }

    /// An image that is not there yet is asked for again once the tab says it has one.
    func testAFaviconThatArrivesLaterShows() async throws {
        let data = LateIconData()
        let gallery = show(data)
        try await Task.sleep(for: .milliseconds(300))
        let card = gallery.cards[data.tabs[0].id]!
        XCTAssertEqual(data.faviconRequests, 1)
        XCTAssertNil(card.faviconKey, "a missing icon leaves no request behind")
        data.iconReady = true
        data.tabs[0].faviconRevision += 1
        gallery.reloadTabs(animated: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(data.faviconRequests, 2)
        XCTAssertNotNil(card.faviconKey)
    }

    func testReorderMakesRoomAndCancelPutsCardsBack() {
        let data = TabGalleryDemoData(count: 6, selectedIndex: 2)
        let gallery = show(data)
        let dragged = data.tabs[2].id
        let neighbor = data.tabs[3].id
        gallery.reorder = (dragged, 2)
        // The finger over the card to the right: it makes room by moving into slot 2.
        let target = gallery.cards[neighbor]!.thumbnailContainer
        let point = target.convert(CGPoint(x: target.bounds.width * 0.6, y: target.bounds.midY), to: gallery.view)
        XCTAssertEqual(gallery.slot(at: point), 3)
        gallery.reorder = nil
        data.moveTab(dragged, to: 3)
        gallery.reloadTabs(animated: false)
        XCTAssertEqual(gallery.order[3], dragged)
    }

    /// Main-thread cost of scrolling 100 tabs, cold: no preview is decoded yet, so images are
    /// prepared and delivered while the scroll runs. The scroll moves one 120 Hz frame (33 pt, a
    /// brisk 4000 pt/s) per step and then yields for the rest of the frame, so image deliveries and
    /// other main-actor work land between steps. Two numbers per frame:
    /// - work: the step itself (every card placed from the new offset, cards entering and leaving);
    /// - late: how far past its 8.3 ms deadline the next step started, which counts any main-thread
    ///   work that ran in between (image assignment, prefetch).
    /// Then the same with a close in flight, so every frame also moves the cards closing the gap.
    func testScrollingHundredTabsFitsTheFrameBudget() async throws {
        let data = TabGalleryDemoData(count: 100)
        let gallery = show(data)
        let scroll = gallery.scrollView!
        let maxOffset = gallery.metrics.maxOffset(for: 100)
        XCTAssertGreaterThan(maxOffset, 10_000)
        let step: CGFloat = 4000 / 120
        let frame = Duration.nanoseconds(8_333_333)
        let clock = ContinuousClock()
        var work: [Duration] = []
        var late: [Duration] = []

        // The timer's own lateness with the main thread idle: the floor the scroll is held to.
        var idle: [Duration] = []
        var idleDeadline = clock.now + frame
        for _ in 0..<120 {
            try await Task.sleep(until: idleDeadline, tolerance: .zero, clock: clock)
            idle.append(max(.zero, clock.now - idleDeadline))
            idleDeadline = clock.now + frame
        }

        var offset: CGFloat = 0
        var deadline = clock.now
        while offset < maxOffset {
            let start = clock.now
            if work.count > 0 { late.append(max(.zero, start - deadline)) }
            offset = min(maxOffset, offset + step)
            scroll.contentOffset.x = offset
            scroll.layoutIfNeeded()
            work.append(clock.now - start)
            deadline = start + frame
            try await Task.sleep(until: deadline, tolerance: .zero, clock: clock)
        }

        // Scrolling back while closed cards' neighbors spring into their gaps.
        var reflow: [Duration] = []
        for round in 0..<40 {
            if round % 8 == 0, let id = gallery.cards.keys.first { gallery.closeTab(id, velocity: -1200) }
            let start = clock.now
            offset = max(0, offset - step)
            scroll.contentOffset.x = offset
            scroll.layoutIfNeeded()
            reflow.append(clock.now - start)
            try await Task.sleep(until: start + frame, tolerance: .zero, clock: clock)
        }

        func stats(_ values: [Duration]) -> (p95: Duration, p99: Duration, max: Duration) {
            let sorted = values.sorted()
            return (sorted[Int(Double(sorted.count) * 0.95)], sorted[Int(Double(sorted.count) * 0.99)], sorted.last!)
        }
        let w = stats(work)
        let l = stats(late)
        let r = stats(reflow)
        let floor = stats(idle)
        let ms = { (d: Duration) in String(format: "%.2f", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }
        print("[plain-measure] gallery.scroll100 frames=\(work.count) work p95=\(ms(w.p95))ms p99=\(ms(w.p99))ms max=\(ms(w.max))ms late p95=\(ms(l.p95))ms p99=\(ms(l.p99))ms max=\(ms(l.max))ms reflow p95=\(ms(r.p95))ms idle-late p95=\(ms(floor.p95))ms")
        XCTAssertLessThan(w.p95, .milliseconds(4), "a frame's scroll work leaves room in 8.3 ms")
        XCTAssertLessThan(r.p95, .milliseconds(4), "scrolling during a close stays in budget")
        // Sleep wake-ups on the simulator run a few milliseconds late even when idle; a decode on
        // the main thread would add tens of milliseconds on top.
        XCTAssertLessThan(l.p95 - floor.p95, .milliseconds(2), "nothing between frames blocks the main thread")

        // XCTest metrics for the trend: a warm pass, stepped without pausing.
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            var x: CGFloat = 0
            let end = gallery.metrics.maxOffset(for: gallery.order.count)
            while x < end {
                x = min(end, x + step)
                scroll.contentOffset.x = x
                scroll.layoutIfNeeded()
            }
            scroll.contentOffset.x = 0
            scroll.layoutIfNeeded()
        }
    }

    /// Thumbnails decode off the main thread: 100 cards' previews prepared through the pipeline.
    func testThumbnailPipelineDecodesHundredPreviews() async {
        let data = TabGalleryDemoData(count: 100)
        let pipeline = ThumbnailPipeline()
        let clock = ContinuousClock()
        let ids = data.tabs.map(\.id)
        let elapsed = await clock.measure {
            for id in ids {
                let key = ThumbnailPipeline.Key(id: id, revision: 0, pixelWidth: 1110, maxAspectPermille: 720, kind: .thumbnail)
                let image = await pipeline.image(for: key) { await data.thumbnail(for: id) }
                XCTAssertNotNil(image)
            }
        }
        print("[plain-measure] gallery.thumbnails100 \(elapsed)")
        // Only the top of each page is kept (600 x 432 px here), and the most recent stay cached.
        let key = ThumbnailPipeline.Key(id: ids[ids.count - 1], revision: 0, pixelWidth: 1110, maxAspectPermille: 720, kind: .thumbnail)
        let first = pipeline.cached(key)
        XCTAssertNotNil(first)
        XCTAssertEqual(first.map { $0.size.height / $0.size.width } ?? 0, 0.72, accuracy: 0.01)
    }
}

/// One tab whose icon is missing until `iconReady`.
@MainActor
private final class LateIconData: TabGalleryDataSource {
    var tabs = [TabGalleryItem(id: UUID(), title: "Late", url: URL(string: "https://example.com"))]
    var selectedTabID: UUID? { tabs.first?.id }
    var canReopenClosedTab: Bool { false }
    var iconReady = false
    var faviconRequests = 0

    func thumbnail(for id: UUID) async -> UIImage? { nil }
    func favicon(for id: UUID) async -> UIImage? {
        faviconRequests += 1
        return iconReady ? UIImage(systemName: "star") : nil
    }
    func selectTab(_ id: UUID) {}
    func closeTab(_ id: UUID) {}
    func closeAllTabs() {}
    func moveTab(_ id: UUID, to index: Int) {}
    func newTab() -> UUID { UUID() }
    func reopenClosedTab() -> UUID? { nil }
}
#endif
