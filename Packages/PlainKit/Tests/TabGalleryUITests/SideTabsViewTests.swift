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

    /// New Tab and Show Titles are plain controls: a touch that ends inside is their action.
    func testTheSidebarsOwnRowsAnswerATouch() throws {
        let data = FakeSideTabs(count: 3, cached: true)
        let sidebar = showSidebar(data, width: SidebarState.rail.width)
        sidebar.canShowTitles = true
        var toggles = 0
        sidebar.onToggleTitles = { toggles += 1 }
        func control(_ identifier: String, in view: UIView) -> UIControl? {
            if let control = view as? UIControl, control.accessibilityIdentifier == identifier { return control }
            for child in view.subviews { if let found = control(identifier, in: child) { return found } }
            return nil
        }
        let titles = try XCTUnwrap(control("sideTabs.titles", in: sidebar.view))
        titles.sendActions(for: .touchUpInside)
        XCTAssertEqual(toggles, 1, "Show Titles answers a tap")
        let newTab = try XCTUnwrap(control("sideTabs.newTab", in: sidebar.view))
        newTab.sendActions(for: .touchUpInside)
        XCTAssertEqual(data.newTabs, 1, "New Tab answers a tap")
        // VoiceOver and UI tests touch a row on its tile, which shows in the rail too.
        let point = sidebar.view.convert(titles.accessibilityActivationPoint, from: nil)
        XCTAssertLessThan(point.x, SidebarState.rail.width)
    }

    /// The strip is as wide as its tabs (the host sizes it to `preferredWidth`), and the tabs
    /// fill it: when it grows for a new tab, each keeps its resting width in the same pass.
    func testTheStripsTabsFillItWhenItGrows() {
        let data = FakeSideTabs(count: 2, cached: true)
        let strip = TabStripViewController(dataSource: data)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.addChild(strip)
        host.view.addSubview(strip.view)
        strip.didMove(toParent: host)
        func tabWidths() -> [CGFloat] {
            strip.collectionView.layoutIfNeeded()
            return strip.collectionView.visibleCells.map(\.frame.width)
        }
        // The Private | Tabs switch ends the strip, 2 pt in from its edge.
        let switchWidth = strip.modeSwitch.sizeThatFits(.zero).width
        XCTAssertGreaterThan(switchWidth, 100)
        XCTAssertEqual(strip.preferredWidth, 378 + switchWidth + 2, "two tabs at 180 pt, their gaps and the switch")
        strip.view.frame = CGRect(x: 12, y: 80, width: strip.preferredWidth, height: 34)
        strip.view.layoutIfNeeded()
        XCTAssertEqual(tabWidths().count, 2)
        for width in tabWidths() { XCTAssertEqual(width, 180, accuracy: 1) }

        var resized = 0
        strip.onPreferredWidthChange = {
            resized += 1
            // The host: the strip takes its new width, laid out at once.
            strip.view.frame.size.width = strip.preferredWidth
            strip.view.layoutIfNeeded()
        }
        data.regularTabs.append(TabGalleryItem(id: UUID(), title: "Third", url: URL(string: "https://third.example")))
        strip.reloadTabs()
        XCTAssertEqual(resized, 1)
        XCTAssertEqual(strip.preferredWidth, 564 + switchWidth + 2)
        strip.view.layoutIfNeeded()
        XCTAssertEqual(tabWidths().count, 3)
        for width in tabWidths() { XCTAssertEqual(width, 180, accuracy: 1, "a grown strip leaves no empty glass") }

        // Past the lane the tabs share what there is, down to the narrowest.
        strip.onPreferredWidthChange = nil
        strip.view.frame.size.width = 500
        strip.view.layoutIfNeeded()
        // The switch keeps its room, so a 500 pt strip holds three tabs at their narrowest (140).
        let share = floor((500 - 6 - switchWidth - 2 - 18) / 3)
        for width in tabWidths() { XCTAssertEqual(width, max(140, share), accuracy: 1) }
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

extension SideTabsViewTests {
    private func control(_ identifier: String, in view: UIView) -> UIControl? {
        if let control = view as? UIControl, control.accessibilityIdentifier == identifier { return control }
        for child in view.subviews { if let found = control(identifier, in: child) { return found } }
        return nil
    }

    /// Private is a mode on wide screens: the sidebar lists one mode's tabs, never both, and its
    /// head's Private and Tabs rows switch between them, one tap each way; the shown side does
    /// nothing (docs/decisions.md, "Private as a clear mode on wide screens").
    func testTheSidebarShowsOneModeAndItsHeadSwitchesIt() throws {
        let data = FakeSideTabs(count: 3, cached: true)
        data.privateTabs = (0..<2).map { TabGalleryItem(id: UUID(), title: "Private \($0)", url: URL(string: "https://p\($0).example"), isPrivate: true) }
        let sidebar = showSidebar(data, width: SidebarState.expanded.width)
        XCTAssertEqual(cells(sidebar).count, 3, "the regular tabs only")
        let privateRow = try XCTUnwrap(control("sideTabs.private", in: sidebar.view))
        let tabsRow = try XCTUnwrap(control("sideTabs.regular", in: sidebar.view))
        XCTAssertTrue(tabsRow.accessibilityTraits.contains(.selected))
        XCTAssertEqual(privateRow.accessibilityValue, "2 tabs")
        tabsRow.sendActions(for: .touchUpInside)
        XCTAssertEqual(data.modeRequests, [], "the shown side does nothing")
        privateRow.sendActions(for: .touchUpInside)
        XCTAssertEqual(data.modeRequests, [true])
        sidebar.collectionView.layoutIfNeeded()
        XCTAssertEqual(cells(sidebar).count, 2, "the private tabs only")
        XCTAssertTrue(privateRow.accessibilityTraits.contains(.selected))
        XCTAssertFalse(tabsRow.accessibilityTraits.contains(.selected))
        tabsRow.sendActions(for: .touchUpInside)
        XCTAssertEqual(data.modeRequests, [true, false])
        sidebar.collectionView.layoutIfNeeded()
        XCTAssertEqual(cells(sidebar).count, 3)
    }

    /// The strip: one mode's tabs, the switch at its end.
    func testTheStripShowsOneModeAndItsEndSwitchesIt() throws {
        let data = FakeSideTabs(count: 3, cached: true)
        data.privateTabs = [TabGalleryItem(id: UUID(), title: "Private", url: URL(string: "https://p.example"), isPrivate: true)]
        let strip = TabStripViewController(dataSource: data)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.addChild(strip)
        host.view.addSubview(strip.view)
        strip.didMove(toParent: host)
        strip.view.frame = CGRect(x: 12, y: 80, width: 900, height: 34)
        strip.view.layoutIfNeeded()
        strip.collectionView.layoutIfNeeded()
        XCTAssertEqual(strip.collectionView.numberOfItems(inSection: 0), 3)
        XCTAssertFalse(strip.modeSwitch.isPrivate)
        strip.modeSwitch.privateSide.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(data.modeRequests, [true])
        XCTAssertEqual(strip.collectionView.numberOfItems(inSection: 0), 1, "the private tab only")
        XCTAssertTrue(strip.modeSwitch.isPrivate)
        strip.modeSwitch.privateSide.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(data.modeRequests, [true], "the shown side does nothing")
        strip.modeSwitch.tabsSide.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(strip.collectionView.numberOfItems(inSection: 0), 3)
    }
}

/// Tabs for the sidebar and the strip, with an icon each.
@MainActor
private final class FakeSideTabs: SideTabsDataSource {
    var regularTabs: [TabGalleryItem]
    var privateTabs: [TabGalleryItem] = []
    var showsPrivate = false
    var tabs: [TabGalleryItem] { showsPrivate ? privateTabs : regularTabs }
    var regularCount: Int { regularTabs.count }
    var privateCount: Int { privateTabs.count }
    private(set) var modeRequests: [Bool] = []
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
    private(set) var newTabs = 0
    func newTab(private isPrivate: Bool) { newTabs += 1 }
    func openInOtherPane(_ id: UUID) {}
    func showMode(private isPrivate: Bool) {
        modeRequests.append(isPrivate)
        showsPrivate = isPrivate
        focusedTabID = tabs.last?.id
    }
    func closeAllPrivateTabs() { privateTabs = [] }
}
#endif
