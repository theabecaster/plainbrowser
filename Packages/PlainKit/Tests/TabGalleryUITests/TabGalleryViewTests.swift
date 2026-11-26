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

    private func show(_ data: TabGalleryDemoData, size: CGSize = CGSize(width: 402, height: 874)) -> TabGalleryViewController {
        window.frame = CGRect(origin: .zero, size: size)
        let gallery = TabGalleryViewController(dataSource: data)
        window.rootViewController = gallery
        window.makeKeyAndVisible()
        gallery.view.layoutIfNeeded()
        return gallery
    }

    func testShowsEveryTabInOrder() {
        let data = TabGalleryDemoData(count: 30)
        let gallery = show(data)
        let collection = gallery.collectionView!
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 30)
        XCTAssertEqual(gallery.metrics.columns, 1)
        XCTAssertFalse(collection.visibleCells.isEmpty)
    }

    func testRegularWidthIsAGrid() {
        let data = TabGalleryDemoData(count: 30)
        let gallery = show(data, size: CGSize(width: 951, height: 669))
        gallery.traitOverrides.horizontalSizeClass = .regular
        gallery.view.layoutIfNeeded()
        gallery.collectionView.collectionViewLayout.invalidateLayout()
        gallery.collectionView.layoutIfNeeded()
        XCTAssertEqual(gallery.metrics.columns, 4)
        let first = gallery.collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))!.frame
        let second = gallery.collectionView.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))!.frame
        XCTAssertEqual(first.minY, second.minY)
    }

    func testCloseRemovesTheCardAndTheLastCloseCallsBack() {
        let data = TabGalleryDemoData(count: 2)
        let gallery = show(data)
        var emptied = false
        gallery.onLastTabClosed = { emptied = true }
        let first = data.tabs[0].id
        let cell = gallery.collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as! TabCardCell
        cell.onClose?(false)
        XCTAssertFalse(data.tabs.contains { $0.id == first })
        XCTAssertEqual(gallery.collectionView.numberOfItems(inSection: 0), 1)
        XCTAssertFalse(emptied)
        let last = gallery.collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as! TabCardCell
        last.onClose?(false)
        XCTAssertTrue(emptied)
        XCTAssertTrue(data.tabs.isEmpty)
    }

    func testTransitionHidesTheCardAndEndsWhereItHeads() async {
        let data = TabGalleryDemoData(count: 10, selectedIndex: 6)
        let gallery = show(data)
        let id = data.tabs[6].id
        let page = UIView(frame: gallery.view.bounds)
        var ended: TabGalleryTransition.End?
        let transition = TabGalleryTransition(
            tabID: id, gallery: gallery, container: gallery.view, snapshot: page,
            pageFrame: gallery.view.bounds, from: .page
        ) { ended = $0 }
        XCTAssertEqual(transition.destination, .gallery)
        let frame = gallery.thumbnailFrame(for: id, in: gallery.view)!
        XCTAssertTrue(gallery.view.bounds.contains(frame), "the card was scrolled on screen")
        let cell = gallery.collectionView.visibleCells.compactMap { $0 as? TabCardCell }.first { $0.tabID == id }
        XCTAssertEqual(cell?.thumbnailContainer.alpha, 0)
        transition.run()
        transition.reverse()
        XCTAssertEqual(transition.destination, .page)
        transition.cancel()
        XCTAssertEqual(ended, .page)
        XCTAssertEqual(cell?.thumbnailContainer.alpha, 1)
        XCTAssertNil(page.superview?.superview, "the moving snapshot is gone")
    }

    func testReorderMovesTheTab() {
        let data = TabGalleryDemoData(count: 5)
        let gallery = show(data)
        let id = data.tabs[0].id
        data.moveTab(id, to: 3)
        gallery.reloadTabs(animated: false)
        XCTAssertEqual(data.tabs[3].id, id)
    }

    /// Main-thread cost of scrolling 100 tabs, cold: no preview is decoded yet, so images are
    /// prepared and delivered while the scroll runs. The scroll moves one 120 Hz frame (33 pt, a
    /// brisk 4000 pt/s) per step and then yields for the rest of the frame, so image deliveries and
    /// other main-actor work land between steps. Two numbers per frame:
    /// - work: the step itself (cards entering, cells configured, layout);
    /// - late: how far past its 8.3 ms deadline the next step started, which counts any main-thread
    ///   work that ran in between (image assignment, prefetch, diffable).
    func testScrollingHundredTabsFitsTheFrameBudget() async throws {
        let data = TabGalleryDemoData(count: 100)
        let gallery = show(data)
        let collection = gallery.collectionView!
        collection.layoutIfNeeded()
        let maxOffset = collection.contentSize.height - collection.bounds.height + collection.adjustedContentInset.bottom
        XCTAssertGreaterThan(maxOffset, 10_000)
        let step: CGFloat = 4000 / 120
        let frame = Duration.nanoseconds(8_333_333)
        let clock = ContinuousClock()
        var work: [Duration] = []
        var late: [Duration] = []

        var offset: CGFloat = 0
        var deadline = clock.now
        while offset < maxOffset {
            let start = clock.now
            if work.count > 0 { late.append(max(.zero, start - deadline)) }
            offset = min(maxOffset, offset + step)
            collection.contentOffset.y = offset
            collection.layoutIfNeeded()
            work.append(clock.now - start)
            deadline = start + frame
            try await Task.sleep(until: deadline, tolerance: .zero, clock: clock)
        }

        func stats(_ values: [Duration]) -> (p95: Duration, p99: Duration, max: Duration) {
            let sorted = values.sorted()
            return (sorted[Int(Double(sorted.count) * 0.95)], sorted[Int(Double(sorted.count) * 0.99)], sorted.last!)
        }
        let w = stats(work)
        let l = stats(late)
        let ms = { (d: Duration) in String(format: "%.2f", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }
        print("[plain-measure] gallery.scroll100 frames=\(work.count) work p95=\(ms(w.p95))ms p99=\(ms(w.p99))ms max=\(ms(w.max))ms late p95=\(ms(l.p95))ms p99=\(ms(l.p99))ms max=\(ms(l.max))ms")
        XCTAssertLessThan(w.p99, .milliseconds(4), "a frame's scroll work leaves room in 8.3 ms")
        // Sleep wake-ups on the simulator jitter by a millisecond or two; a decode on the main
        // thread would show up as tens of milliseconds.
        XCTAssertLessThan(l.p95, .milliseconds(4), "nothing between frames blocks the main thread")

        // XCTest metrics for the trend: a warm pass, stepped without pausing.
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            var y: CGFloat = 0
            while y < maxOffset {
                y = min(maxOffset, y + step)
                collection.contentOffset.y = y
                collection.layoutIfNeeded()
            }
            collection.contentOffset.y = 0
            collection.layoutIfNeeded()
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
#endif
