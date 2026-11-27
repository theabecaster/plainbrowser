#if canImport(UIKit)
import UIKit
import WebEngine
import XCTest
@testable import TabGalleryUI

/// The sidebar's and the strip's rows: site icons, the rail widening to titles, and the scroll
/// cost with 50 tabs. iOS simulator only:
/// `xcodebuild test -scheme PlainKit-Package -destination id=<udid> -only-testing:TabGalleryUITests`.
@MainActor
final class SideTabsViewTests: XCTestCase {
    private var window: UIWindow!

    override func setUp() async throws {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 951, height: 669))
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
    }

    private func showSidebar(_ data: FakeSideTabs, width: CGFloat) -> SideTabsViewController {
        let sidebar = SideTabsViewController(dataSource: data)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.addChild(sidebar)
        sidebar.view.frame = CGRect(x: 0, y: 0, width: width, height: 669)
        host.view.addSubview(sidebar.view)
        sidebar.didMove(toParent: host)
        sidebar.visibleWidth = width
        sidebar.view.layoutIfNeeded()
        sidebar.collectionView.layoutIfNeeded()
        return sidebar
    }

    private func cells(_ sidebar: SideTabsViewController) -> [SideTabCell] {
        sidebar.collectionView.visibleCells.compactMap { $0 as? SideTabCell }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    private func subview<View: UIView>(_ type: View.Type, in view: UIView) -> View? {
        for child in view.subviews {
            if let match = child as? View { return match }
            if let match = subview(type, in: child) { return match }
        }
        return nil
    }

    func testARowShowsItsIconAtOnceWhenItIsInMemory() throws {
        let data = FakeSideTabs(count: 3, cached: true)
        let sidebar = showSidebar(data, width: SidebarState.rail.width)
        let row = try XCTUnwrap(cells(sidebar).first)
        let tile = try XCTUnwrap(subview(SiteIconView.self, in: row))
        let image = try XCTUnwrap(subview(UIImageView.self, in: tile))
        XCTAssertNotNil(image.image, "assigned in the same pass as the row: no letter first")
        XCTAssertEqual(image.alpha, 1)
        XCTAssertEqual(data.loads, 0, "nothing read for an icon already decoded")
        // 20 pt at the window's scale, the size the row shows it at.
        XCTAssertEqual(data.askedPixelSizes, [Int(SideTabMetrics.iconSize * window.traitCollection.displayScale)])
    }

    func testAnIconThatHasToBeReadReplacesTheLetter() async throws {
        let data = FakeSideTabs(count: 2, cached: false)
        let sidebar = showSidebar(data, width: SidebarState.rail.width)
        let row = try XCTUnwrap(cells(sidebar).first)
        let tile = try XCTUnwrap(subview(SiteIconView.self, in: row))
        let image = try XCTUnwrap(subview(UIImageView.self, in: tile))
        let letter = try XCTUnwrap(subview(UILabel.self, in: tile))
        XCTAssertNil(image.image)
        XCTAssertEqual(letter.text, "S", "the site's letter until the icon is decoded")
        for _ in 0..<50 where image.image == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(image.image)
        XCTAssertEqual(data.loads, 2, "one read a row")
        // The same rows again (a title changed): nothing is read twice.
        sidebar.reloadTabs()
        sidebar.collectionView.layoutIfNeeded()
        XCTAssertEqual(data.loads, 2)
    }

    func testTheRailWidensToTitlesWithoutLayingRowsOutAgain() throws {
        let data = FakeSideTabs(count: 5, cached: true)
        let rail = SidebarState.rail.width
        let expanded = SidebarState.expanded.width
        let sidebar = showSidebar(data, width: rail)
        let row = try XCTUnwrap(cells(sidebar).first)
        XCTAssertEqual(row.frame.width, expanded, "rows are laid out at the expanded width and clipped")
        let title = try XCTUnwrap(row.contentView.subviews.compactMap { $0 as? UILabel }.first)
        XCTAssertEqual(title.alpha, 0, "the rail shows tiles only")
        let frameBefore = row.frame
        sidebar.visibleWidth = expanded
        XCTAssertEqual(title.alpha, 1)
        XCTAssertEqual(row.frame, frameBefore, "no row moved or resized")
        sidebar.visibleWidth = rail + (expanded - rail) * 0.2
        XCTAssertEqual(title.alpha, 0, "no clipped fragments while there is no room for words")
        sidebar.visibleWidth = rail + (expanded - rail) * 0.85
        XCTAssertEqual(title.alpha, 1, "titles are in before the edge rests")
    }

    func testTheSelectionMarkSpansWhatShows() {
        let rail = SidebarState.rail.width
        let expanded = SidebarState.expanded.width
        let inRail = SideTabMetrics.markFrame(rowHeight: 44, visibleWidth: rail)
        XCTAssertEqual(inRail, CGRect(x: 4, y: 2, width: rail - 8, height: 40))
        XCTAssertTrue(inRail.contains(SideTabMetrics.tileFrame(rowHeight: 44)), "the mark wraps the tile")
        XCTAssertEqual(SideTabMetrics.markFrame(rowHeight: 44, visibleWidth: expanded).maxX, expanded - 4)
        // Never past the rows, never narrower than the rail (a rubber-banded or closing sidebar).
        XCTAssertEqual(SideTabMetrics.markFrame(rowHeight: 44, visibleWidth: expanded + 40).maxX, expanded - 4)
        XCTAssertEqual(SideTabMetrics.markFrame(rowHeight: 44, visibleWidth: 10), inRail)
        XCTAssertEqual(SideTabMetrics.titleAlpha(visibleWidth: rail), 0)
        XCTAssertEqual(SideTabMetrics.titleAlpha(visibleWidth: expanded), 1)
    }

    /// Scrolls the rail (and then the strip) of 50 tabs at 4000 pt/s in 120 Hz steps and measures
    /// what each step costs the main thread: every row entering configures its title, its mark and
    /// its icon. The icons are in memory, as after the first pass on the device; a decode on the
    /// main thread would show as tens of milliseconds.
    func testScrollingFiftyTabsFitsTheFrameBudget() async throws {
        let data = FakeSideTabs(count: 50, cached: true)
        let sidebar = showSidebar(data, width: SidebarState.rail.width)
        let rail = try await scrollCost(of: sidebar.collectionView, vertical: true)

        let strip = TabStripViewController(dataSource: data)
        let host = try XCTUnwrap(window.rootViewController)
        host.addChild(strip)
        strip.view.frame = CGRect(x: 60, y: 80, width: 880, height: 34)
        host.view.addSubview(strip.view)
        strip.didMove(toParent: host)
        strip.view.layoutIfNeeded()
        let above = try await scrollCost(of: strip.collectionView, vertical: false)

        let ms = { (d: Duration) in String(format: "%.2f", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }
        print("[plain-measure] sidebar.scroll50 rail frames=\(rail.count) work p95=\(ms(rail.p95))ms max=\(ms(rail.max))ms; strip frames=\(above.count) work p95=\(ms(above.p95))ms max=\(ms(above.max))ms; icon reads on the main thread=\(data.loads)")
        XCTAssertLessThan(rail.p95, .milliseconds(4), "a frame of the rail's scroll leaves room in 8.3 ms")
        XCTAssertLessThan(above.p95, .milliseconds(4), "a frame of the strip's scroll leaves room in 8.3 ms")
        XCTAssertEqual(data.loads, 0, "icons in memory are assigned, never read, during a scroll")
    }

    private func scrollCost(of scroll: UIScrollView, vertical: Bool) async throws -> (count: Int, p95: Duration, max: Duration) {
        scroll.layoutIfNeeded()
        let end = vertical
            ? scroll.contentSize.height - scroll.bounds.height
            : scroll.contentSize.width - scroll.bounds.width
        XCTAssertGreaterThan(end, 500, "50 tabs scroll")
        let step: CGFloat = 4000 / 120
        let frame = Duration.nanoseconds(8_333_333)
        let clock = ContinuousClock()
        var work: [Duration] = []
        // There and back, twice: rows are made on the first pass and reused after.
        for pass in 0..<4 {
            var offset: CGFloat = pass % 2 == 0 ? 0 : end
            while pass % 2 == 0 ? offset < end : offset > 0 {
                let start = clock.now
                offset = pass % 2 == 0 ? min(end, offset + step) : max(0, offset - step)
                scroll.contentOffset = vertical ? CGPoint(x: 0, y: offset) : CGPoint(x: offset, y: 0)
                scroll.layoutIfNeeded()
                work.append(clock.now - start)
                try await Task.sleep(until: start + frame, tolerance: .zero, clock: clock)
            }
        }
        let sorted = work.sorted()
        return (sorted.count, sorted[Int(Double(sorted.count) * 0.95)], sorted.last!)
    }
}

/// Tabs for the sidebar and the strip, with an icon each.
@MainActor
private final class FakeSideTabs: SideTabsDataSource {
    var regularTabs: [TabGalleryItem]
    var privateTabs: [TabGalleryItem] = []
    var focusedTabID: UUID?
    var otherPaneTabID: UUID?
    var canOpenInOtherPane = false
    /// Icons are decoded in memory already (`cachedIcon` answers).
    let cached: Bool
    private(set) var loads = 0
    private(set) var askedPixelSizes: Set<Int> = []
    private let icon: SiteIcon

    init(count: Int, cached: Bool) {
        self.cached = cached
        regularTabs = (0..<count).map { index in
            TabGalleryItem(id: UUID(), title: "Tab \(index) - Site\(index)", url: URL(string: "https://site\(index).example/page"))
        }
        focusedTabID = regularTabs.first?.id
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 60), format: format).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 6, y: 6, width: 48, height: 48))
        }
        icon = SiteIcon(image: image, style: .glyph)
    }

    func cachedIcon(for item: TabGalleryItem, pixelSize: Int) -> SiteIcon? {
        askedPixelSizes.insert(pixelSize)
        return cached ? icon : nil
    }

    func icon(for item: TabGalleryItem, pixelSize: Int) async -> SiteIcon? {
        loads += 1
        return icon
    }

    func selectTab(_ id: UUID) { focusedTabID = id }
    func closeTab(_ id: UUID) { regularTabs.removeAll { $0.id == id } }
    func moveTab(_ id: UUID, to index: Int) {}
    func newTab(private isPrivate: Bool) {}
    func openInOtherPane(_ id: UUID) {}
}
#endif
