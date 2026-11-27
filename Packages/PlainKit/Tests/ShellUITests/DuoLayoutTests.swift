import BrowserCore
import CoreGraphics
@testable import ShellUI
import TabGalleryUI
import Testing

/// Every Duo state from docs/plan.md, section 6, on the layout model. Geometry is the real Duo's:
/// outer 466x678 portrait with the system's vertical bar (about 84 pt) on the trailing edge, inner
/// 951x669 landscape with the crease at the center. On the inner screen Plain turns the vertical
/// bar off and shows a top bar, as Safari does, so the page area is the full width under the
/// status bar.
@MainActor
struct DuoLayoutTests {
    static let bar: CGFloat = 84
    static let statusBar: CGFloat = 24
    static let rail = SidebarState.rail.width
    /// Inner landscape: the full width under the status bar.
    static let innerLandscape = CGRect(x: 0, y: statusBar, width: 951, height: 669 - statusBar)
    /// Inner portrait.
    static let innerPortrait = CGRect(x: 0, y: statusBar, width: 669, height: 951 - statusBar)
    /// Inner landscape with the vertical bar left on (as before the top bar): 867 pt of page.
    static let besideBar = CGRect(x: 0, y: 0, width: 951 - bar, height: 669)
    /// The crease of the inner screen as the simulator reports it (`.includeInactive`), the same
    /// rect flat (inactive) and partly folded (active).
    static let flatFold = CGRect(x: 455.5, y: 0, width: 40, height: 669)
    static let bookFold = flatFold

    func inner(
        layout: TabLayout = .above, sidebar: SidebarState = .rail, panes: Int = 1, tabs: Int = 3, focused: Int = 0,
        fold: CGRect? = flatFold, active: Bool = false, area: CGRect = innerLandscape
    ) -> DuoLayout {
        DuoLayout(DuoLayoutInput(
            pageArea: area, isRegularWidth: true, isRegularHeight: true, tabLayout: layout,
            requestedSidebar: sidebar, paneCount: panes, tabCount: tabs, focusedPane: focused, division: fold,
            isDivisionActive: active
        ))
    }

    @Test func outerScreenShowsOnePaneAndNoSideTabs() {
        let outer = DuoLayout(DuoLayoutInput(
            pageArea: CGRect(x: 0, y: 24, width: 466 - Self.bar, height: 654), isRegularWidth: false, isRegularHeight: true,
            tabLayout: .left, paneCount: 2, focusedPane: 1
        ))
        #expect(!outer.tabLayoutAvailable)
        #expect(!outer.chromeOnTop, "the outer screen keeps the bottom pill and the vertical bar")
        #expect(outer.tabLayout == nil, "the app switcher is the only tab list")
        #expect(!outer.showsStrip)
        #expect(!outer.showsSidebar)
        #expect(!outer.splitAvailable)
        #expect(!outer.splitShown)
        #expect(outer.paneFrames.count == 1)
        #expect(outer.chromeLane == 0...(466 - Self.bar))
    }

    @Test func innerScreenHasATopBarInBothOrientations() {
        #expect(inner().chromeOnTop)
        #expect(inner(area: Self.innerPortrait).chromeOnTop)
        // The page keeps the full width and height: the bar and the strip float over it.
        let above = inner(layout: .above)
        #expect(above.paneFrames == [Self.innerLandscape])
    }

    @Test func innerPortraitHasNoSplitAndShowsTheStripForASidebar() {
        // 669 pt wide: the rail would leave 617 pt, under the 640 pt minimum, and two panes would
        // be 334 pt each. The strip fits, so Left and Right show it there.
        for setting in [TabLayout.left, .right, .above] {
            let portrait = inner(layout: setting, panes: 2, area: Self.innerPortrait)
            #expect(portrait.tabLayoutAvailable)
            #expect(portrait.tabLayout == .above)
            #expect(portrait.showsStrip && !portrait.showsSidebar)
        }
        let portrait = inner(layout: .left, panes: 2, area: Self.innerPortrait)
        #expect(!portrait.splitAvailable)
        #expect(portrait.paneFrames.count == 1)
    }

    @Test func theStripShowsFromTheSecondTab() {
        let one = inner(layout: .above, tabs: 1)
        #expect(one.tabLayout == .above)
        #expect(!one.showsStrip, "one tab has nothing to switch to")
        #expect(one.stripHeight == 0)
        let two = inner(layout: .above, tabs: 2)
        #expect(two.showsStrip)
        #expect(two.stripHeight == CGFloat(FixedChoices.tabStripHeight))
    }

    @Test func compactHeightIsNeverWideEnough() {
        // A Pro Max in landscape: regular width, compact height.
        let phone = DuoLayout(DuoLayoutInput(
            pageArea: CGRect(x: 59, y: 0, width: 838, height: 440), isRegularWidth: true, isRegularHeight: false,
            tabLayout: .left, paneCount: 2
        ))
        #expect(!phone.tabLayoutAvailable)
        #expect(!phone.chromeOnTop)
        #expect(!phone.splitShown)
    }

    @Test func innerLandscapeSplitsOnTheCrease() {
        let split = inner(panes: 2, focused: 1)
        #expect(split.splitShown)
        #expect(split.paneFrames.count == 2)
        #expect(split.paneFrames[0].maxX == 475.5)
        #expect(split.paneFrames[1].minX == 475.5)
        #expect(split.paneFrames[1].maxX == Self.innerLandscape.maxX)
        // The top bar spans both panes and acts on the focused one.
        #expect(split.chromeLane == Self.innerLandscape.minX...Self.innerLandscape.maxX)
    }

    @Test func bookPosePutsOnePaneEachSideOfTheFold() {
        let book = inner(panes: 2, focused: 0, fold: Self.bookFold, active: true)
        #expect(book.paneFrames[0].maxX == Self.bookFold.minX)
        #expect(book.paneFrames[1].minX == Self.bookFold.maxX)
        // Partly folded, the bar keeps to the focused pane, off the fold.
        #expect(book.chromeLane == 0...Self.bookFold.minX)
        let other = inner(panes: 2, focused: 1, fold: Self.bookFold, active: true)
        #expect(other.chromeLane == Self.bookFold.maxX...Self.innerLandscape.maxX)
    }

    @Test func splitFallsBackToHalvesWhenTheCreaseLeavesAPaneTooNarrow() {
        let off = CGRect(x: 820, y: 0, width: 0, height: 669)
        let split = inner(panes: 2, fold: off)
        #expect(split.paneFrames[0].width == split.paneFrames[1].width)
    }

    @Test func leftRailDocksAndExpandedDocksBesideAFullWidthPage() {
        let rail = inner(layout: .left, sidebar: .rail)
        #expect(rail.tabLayoutAvailable)
        #expect(!rail.sidebarOnRight)
        #expect(rail.showsSidebar)
        #expect(rail.sidebar == .rail)
        #expect(rail.sidebarDockWidth == Self.rail)
        #expect(rail.paneFrames[0].minX == Self.rail)
        #expect(rail.paneFrames[0].width >= 640)
        // The top bar sits over the pages, beside the sidebar.
        #expect(rail.chromeLane == Self.rail...Self.innerLandscape.maxX)

        // 951 - 260 = 691 pt of page: Expanded docks.
        let expanded = inner(layout: .left, sidebar: .expanded)
        #expect(expanded.sidebar == .expanded)
        #expect(!expanded.sidebarFloats)
        #expect(expanded.sidebarDockWidth == 260)
    }

    @Test func expandedFloatsWhereThePageWouldBeTooNarrow() {
        // 867 - 260 = 607 pt of page: Expanded floats over it, the page keeps the rail's width.
        let expanded = inner(layout: .left, sidebar: .expanded, area: Self.besideBar)
        #expect(expanded.sidebarFloats)
        #expect(expanded.sidebarDockWidth == Self.rail)
        #expect(expanded.chromeLane == 260...Self.besideBar.maxX, "the bar stays clear of the floating sidebar")

        let right = inner(layout: .right, sidebar: .expanded, area: Self.besideBar)
        #expect(right.sidebarFloats)
        #expect(right.chromeLane == Self.besideBar.minX...(Self.besideBar.maxX - 260))
    }

    @Test func splitAndFoldForceTheRail() {
        let split = inner(layout: .left, sidebar: .expanded, panes: 2)
        #expect(split.sidebar == .rail)
        #expect(split.widestSidebar == .rail)
        #expect(split.splitShown)
        #expect(split.paneFrames.allSatisfy { $0.width >= CGFloat(FixedChoices.splitMinimumPaneWidth) })

        let book = inner(layout: .left, sidebar: .expanded, fold: Self.bookFold, active: true)
        #expect(book.sidebar == .rail)

        let hidden = inner(layout: .left, sidebar: .hidden, panes: 2)
        #expect(hidden.sidebar == .hidden)
        #expect(hidden.sidebarDockWidth == 0)
    }

    @Test func aboveFloatsTheStripOverThePages() {
        let above = inner(layout: .above, sidebar: .expanded, panes: 2)
        #expect(above.showsStrip)
        #expect(!above.showsSidebar)
        #expect(above.sidebarDockWidth == 0)
        #expect(above.stripHeight == CGFloat(FixedChoices.tabStripHeight))
        #expect(above.paneFrames.allSatisfy { $0.minY == Self.innerLandscape.minY }, "the strip floats, the pages keep their height")
        #expect(above.paneFrames[0].maxX == 475.5, "the split stays on the crease")
    }

    @Test func rightDocksTheSidebarOnTheTrailingSide() {
        let rail = inner(layout: .right, sidebar: .rail)
        #expect(rail.sidebarOnRight)
        #expect(rail.paneFrames[0].minX == Self.innerLandscape.minX)
        #expect(rail.paneFrames[0].maxX == Self.innerLandscape.maxX - Self.rail)
        #expect(rail.chromeLane == Self.innerLandscape.minX...(Self.innerLandscape.maxX - Self.rail))
    }

    @Test func bookPoseMovesTheBarOffTheFold() {
        let book = inner(fold: Self.bookFold, active: true)
        #expect(book.chromeLane.upperBound <= Self.bookFold.minX || book.chromeLane.lowerBound >= Self.bookFold.maxX)
        // Flat, the crease is only a position and the bar spans the page.
        let flat = inner()
        #expect(flat.chromeLane == Self.innerLandscape.minX...Self.innerLandscape.maxX)
    }

    @Test func tabletopFoldNeedsNoLayout() {
        let tabletop = CGRect(x: 0, y: 470, width: 669, height: 30)
        let layout = DuoLayout(DuoLayoutInput(
            pageArea: Self.innerPortrait, isRegularWidth: true, isRegularHeight: true,
            division: tabletop, isDivisionActive: true
        ))
        #expect(layout.chromeLane == 0...669)
    }

    @Test func barAvoidsTheCameraOnlyWhereItSits() {
        let camera = CGRect(x: 400, y: 30, width: 60, height: 30)
        var input = DuoLayoutInput(
            pageArea: Self.innerLandscape, isRegularWidth: true, isRegularHeight: true, tabLayout: .above, occlusions: [camera],
            chromeBand: 24...70
        )
        #expect(DuoLayout(input).chromeLane == 460...Self.innerLandscape.maxX)
        input.chromeBand = 600...669
        #expect(DuoLayout(input).chromeLane == Self.innerLandscape.minX...Self.innerLandscape.maxX)
    }

    @Test func laneAvoidanceKeepsTheLargerSide() {
        #expect(DuoLayout.lane(0...100, avoiding: 40...50) == 50...100)
        #expect(DuoLayout.lane(0...100, avoiding: 60...70) == 0...60)
        #expect(DuoLayout.lane(0...100, avoiding: 200...210) == 0...100)
    }
}

/// The top bar's geometry from the root view's width, safe area and status corner. The device's
/// numbers come from the owner's screenshot of the Duo's inner screen (landscape, 951x669 pt): an
/// 81 pt top safe area with the clock and battery only in the top-trailing corner (x 828–928,
/// y 24–69). The simulator's status bar spans the width (24 pt). Decision: docs/decisions.md,
/// "Duo inner screen: the bar in the status row".
@MainActor
struct TopChromeGeometryTests {
    static let landscape = CGSize(width: 951, height: 669)
    static let portrait = CGSize(width: 669, height: 951)
    static let strip = CGFloat(FixedChoices.tabStripHeight)
    /// The device's status items, as measured.
    static let deviceCluster = CGRect(x: 828, y: 24, width: 100, height: 45)

    static func device(strip: CGFloat = 0) -> TopChromeGeometry {
        TopChromeGeometry(width: 951, safeTop: 81, corner: deviceCluster, stripHeight: strip)
    }

    static func simulator(strip: CGFloat = 0) -> TopChromeGeometry {
        TopChromeGeometry(width: 951, safeTop: 24, corner: nil, stripHeight: strip)
    }

    // MARK: Finding the corner

    @Test func cornerAdaptedGuideFindsATrailingCorner() throws {
        // The horizontal guide is shorter than the safe area and reaches in from the trailing edge.
        let corner = try #require(StatusCorner.rect(
            width: 951, safeTop: 81, safeLeft: 0, safeRight: 0, adaptedTop: 0, adaptedLeft: 0, adaptedRight: 135
        ))
        #expect(corner == CGRect(x: 816, y: 0, width: 135, height: 81))
        // Inset on both sides, the side it grew on more holds the corner.
        let both = try #require(StatusCorner.rect(
            width: 951, safeTop: 81, safeLeft: 10, safeRight: 10, adaptedTop: 20, adaptedLeft: 12, adaptedRight: 140
        ))
        #expect(both.minX == 811 && both.maxX == 941 && both.minY == 20 && both.maxY == 81)
    }

    @Test func cornerAdaptedGuideFindsALeadingCorner() throws {
        let corner = try #require(StatusCorner.rect(
            width: 669, safeTop: 70, safeLeft: 0, safeRight: 0, adaptedTop: 10, adaptedLeft: 120, adaptedRight: 0
        ))
        #expect(corner == CGRect(x: 0, y: 10, width: 120, height: 60))
    }

    @Test func cameraInTheSafeAreaGivesTheCornerWhenTheGuideDoesNot() throws {
        // The Duo's inner camera as UIKit reports it (simulator, landscape and portrait): the
        // device's battery ring wraps it, its safe area's top (81) clears it.
        let camera = CGRect(x: 884.67, y: 29.33, width: 37, height: 37)
        let corner = try #require(StatusCorner.rect(aroundOcclusions: [camera], width: 951, safeTop: 81))
        #expect(abs(corner.midY - camera.midY) < 0.001, "the row centers on the camera's row")
        #expect(corner.maxX == 951)
        #expect(abs(corner.minX - (camera.minX - CGFloat(FixedChoices.statusItemsReach))) < 0.001)
        let bar = TopChromeGeometry(width: 951, safeTop: 81, corner: corner, stripHeight: 0)
        // Row 25.8–69.8 around the camera's 47.8; it ends 8 pt before the clock's reach (819.7),
        // 12 pt left of the device's clock (831.7). Page at 73.8 pt.
        #expect(abs(bar.rowTop - 25.83) < 0.01)
        #expect(abs(bar.expandedInset - 73.83) < 0.01)
        #expect(951 - bar.rowClearance.trailing < 828)
        let portrait = try #require(StatusCorner.rect(
            aroundOcclusions: [CGRect(x: 266, y: 0, width: 200, height: 82), CGRect(x: 602.67, y: 29.33, width: 37, height: 37)],
            width: 669, safeTop: 82
        ))
        #expect(portrait.maxX == 669 && abs(portrait.midY - 47.83) < 0.01)
    }

    @Test func occlusionsElsewhereGiveNoCorner() {
        // Below the safe area's top (the simulator's landscape window: 20 pt) the system has not
        // made room for it: the row stays under the status bar, and the lane avoids it when active.
        #expect(StatusCorner.rect(aroundOcclusions: [CGRect(x: 884.67, y: 29.33, width: 37, height: 37)], width: 951, safeTop: 20) == nil)
        // A region across the middle (the outer screen's island) is not a corner.
        #expect(StatusCorner.rect(aroundOcclusions: [CGRect(x: 266, y: 0, width: 200, height: 82)], width: 669, safeTop: 82) == nil)
        #expect(StatusCorner.rect(aroundOcclusions: [], width: 951, safeTop: 81) == nil)
    }

    @Test func fullWidthStatusBarHasNoCorner() {
        // The guide equals the safe area: a phone, the simulator, a wide window.
        #expect(StatusCorner.rect(
            width: 951, safeTop: 24, safeLeft: 0, safeRight: 0, adaptedTop: 24, adaptedLeft: 0, adaptedRight: 0
        ) == nil)
        // Shorter but no wider at either side: still no corner to keep clear of.
        #expect(StatusCorner.rect(
            width: 951, safeTop: 81, safeLeft: 0, safeRight: 0, adaptedTop: 24, adaptedLeft: 0, adaptedRight: 0
        ) == nil)
        // Rounding is not a corner.
        #expect(StatusCorner.rect(
            width: 951, safeTop: 24.3, safeLeft: 0, safeRight: 0, adaptedTop: 24, adaptedLeft: 0, adaptedRight: 0.3
        ) == nil)
        // A corner as wide as the view is a band.
        #expect(TopChromeGeometry(width: 951, safeTop: 81, corner: CGRect(x: 0, y: 0, width: 951, height: 81), stripHeight: 0)
            .isInStatusZone == false)
    }

    // MARK: The device: the row on the status row

    @Test func deviceRowSitsOnTheStatusRowClearOfTheCorner() {
        let bar = Self.device()
        #expect(bar.isInStatusZone)
        // Centered on the clock and battery: 46.5 - 22.
        #expect(bar.rowTop == 24.5)
        #expect(bar.rowBottom == 68.5)
        #expect(abs((bar.rowTop + bar.rowBottom) / 2 - Self.deviceCluster.midY) < 0.001)
        // The trailing capsule stops 8 pt before the status items.
        #expect(bar.rowClearance.leading == 0)
        #expect(bar.rowClearance.trailing == 951 - 828 + TopChromeGeometry.cornerGap)
        #expect(951 - bar.rowClearance.trailing == 820)
    }

    @Test func devicePageStartsUnderTheRowWithoutABand() {
        let bar = Self.device()
        // Was 132 pt (81 pt band + 51 pt row). Safari: 84 pt.
        #expect(bar.expandedInset == 72.5)
        #expect(bar.expandedInset <= 84)
        // The strip starts under the status items (69), not beside them.
        let strip = Self.device(strip: Self.strip)
        #expect(strip.stripTop == 73)
        #expect(strip.expandedInset == 73 + Self.strip + 4)
        #expect(bar.obscuredInset < bar.expandedInset, "WebKit wants the largest viewport inset strictly larger")
        // 10.8% of the screen at rest (Safari 12.6%), 16.5% with the strip.
        #expect(bar.chromeShare(of: Self.landscape, collapsed: false) < 0.11)
        #expect(strip.chromeShare(of: Self.landscape, collapsed: false) < 0.17)
        #expect(bar.chromeShare(of: Self.landscape, collapsed: true) < 0.11)
    }

    @Test func deviceLeavesNoBandAtTheTopInAnyState() {
        // Owner, on the device: "The bar under the URL text field is still there when the text
        // field is present, and the transition to the no-bar state is terrible." In the status
        // zone the page's obscured top inset is 0 in every state, with or without the strip, so
        // WebKit fills no band of a fixed header's color behind the controls at rest, and a
        // collapse or a reveal changes nothing in the page (no jump). The page's first line at
        // rest still starts under the controls: that is the scroll range's start.
        let portrait = TopChromeGeometry(
            width: 669, safeTop: 81, corner: CGRect(x: 546, y: 24, width: 100, height: 45), stripHeight: 0
        )
        for bar in [Self.device(), Self.device(strip: Self.strip), portrait] {
            #expect(bar.obscuredInset == 0)
            #expect(bar.chromeShare(of: Self.landscape, collapsed: true) == 0)
            #expect(bar.expandedInset == bar.expandedBottom)
            #expect(bar.expandedInset > bar.obscuredInset, "WebKit wants the largest viewport inset strictly larger")
        }
        #expect(Self.device().expandedInset == 72.5)
        // Under a full-width status bar (no corner: iPad-size windows) the page keeps clear of the
        // status bar in every state, and of nothing more.
        #expect(Self.simulator().obscuredInset == Self.simulator().safeTop)
    }

    @Test func deviceCollapseShrinksTheAddressInPlaceThenLiftsItOff() {
        let bar = Self.device(strip: Self.strip)
        let collapsed = bar.pillTransform(progress: 1)
        #expect(collapsed.translationY == 0, "the address stays on the status row")
        #expect(collapsed.scale == TopChromeGeometry.compactScale)
        #expect(bar.collapsedBottom <= bar.rowBottom)
        let hidden = bar.pillTransform(progress: 2)
        let center = bar.rowTop + TopChromeGeometry.rowHeight / 2 + hidden.translationY
        #expect(abs(center + bar.collapsedPillHeight / 2 + ChromeGeometry.hiddenClearance) < 0.001)
        #expect(bar.stripTranslation(progress: 1) < 0 && bar.buttonsTranslation(progress: 1) < 0)
    }

    @Test func stripNeverRisesOverTheStatusCorner() {
        // The strip spans under the corner (72.5 > 69): on its way out it rises only to the
        // corner's bottom, at every step of the collapse.
        let bar = Self.device(strip: Self.strip)
        for step in 0...20 {
            let progress = CGFloat(step) / 10
            #expect(bar.stripTop + bar.stripTranslation(progress: progress) >= Self.deviceCluster.maxY)
        }
        // A guide corner down to the safe area (0–81): the strip starts under it (85) and rises
        // only to its bottom too.
        let corner = CGRect(x: 816, y: 0, width: 135, height: 81)
        let beside = TopChromeGeometry(width: 951, safeTop: 81, corner: corner, stripHeight: Self.strip)
        #expect(beside.stripTop == 85)
        #expect(beside.stripTranslation(progress: 1) == -TopChromeGeometry.gap)
        // Under a full-width status bar nothing is in the way.
        #expect(Self.simulator(strip: Self.strip).stripTranslation(progress: 1) == -48)
    }

    @Test func cornerFromTheScreensTopStillBeatsSafari() throws {
        // If the guide's corner runs from the top edge to the safe area (0–81), the row centers on
        // that band (18.5–62.5), and the page never starts above the corner's bottom at rest: 81 pt.
        let corner = try #require(StatusCorner.rect(
            width: 951, safeTop: 81, safeLeft: 0, safeRight: 0, adaptedTop: 0, adaptedLeft: 0, adaptedRight: 135
        ))
        let bar = TopChromeGeometry(width: 951, safeTop: 81, corner: corner, stripHeight: 0)
        #expect(bar.rowTop == 18.5)
        #expect(bar.obscuredInset == 0, "the page runs to the top edge under the floating bar")
        #expect(bar.expandedInset == 81)
        #expect(bar.expandedInset <= 84)
        #expect(951 - bar.rowClearance.trailing == 816 - TopChromeGeometry.cornerGap)
        // The strip starts under that corner (85), never beside it, and so spans the lane: a strip
        // cut short where the status items begin read as broken on the device.
        let strip = TopChromeGeometry(width: 951, safeTop: 81, corner: corner, stripHeight: Self.strip)
        #expect(strip.stripTop == 85)
        #expect(strip.stripFrame(lane: 0...951).maxX == 951 - TopChromeGeometry.edgeMargin)
        #expect(strip.expandedInset == 85 + Self.strip + 4)
    }

    @Test func rowNeverStartsAboveTheCorner() {
        // A short corner (a status bar's height): the row may run below it, never above.
        let bar = TopChromeGeometry(width: 951, safeTop: 30, corner: CGRect(x: 850, y: 6, width: 101, height: 24), stripHeight: 0)
        #expect(bar.rowTop == 6)
        #expect(bar.expandedInset == 54)
    }

    // MARK: The simulator and phones: under a full-width status bar

    @Test func fullWidthStatusBarKeepsTheRowUnderIt() {
        let bar = Self.simulator()
        #expect(!bar.isInStatusZone)
        #expect(bar.rowTop == 26)
        // 2 above the row, 44 row, 4 under, from the top edge (the page runs under the status bar).
        #expect(bar.expandedInset == 74)
        #expect(bar.rowClearance.leading == 0 && bar.rowClearance.trailing == 0)
        let strip = Self.simulator(strip: Self.strip)
        #expect(strip.stripTop == 74)
        #expect(strip.expandedInset == 74 + Self.strip + 4)
    }

    @Test func fullWidthStatusBarTucksThePillUnderIt() {
        let bar = Self.simulator(strip: Self.strip)
        let collapsed = bar.pillTransform(progress: 1)
        let center = bar.rowTop + TopChromeGeometry.rowHeight / 2 + collapsed.translationY
        #expect(abs(center - bar.collapsedPillHeight / 2 - 24) < 0.001, "the collapsed pill's top meets the status bar")
        // The page keeps clear of the status bar in every state; the bar floats over it.
        #expect(bar.obscuredInset == 24)
        #expect(bar.obscuredInset < bar.expandedInset)
    }

    @Test func portraitUsesTheSameRules() {
        // A tall status bar across the width (the simulator's portrait window, ~80 pt).
        let band = TopChromeGeometry(width: 669, safeTop: 80, corner: nil, stripHeight: 0)
        #expect(band.expandedInset == 130)
        // A corner there: on its row, clear of it.
        let corner = TopChromeGeometry(width: 669, safeTop: 81, corner: CGRect(x: 546, y: 24, width: 100, height: 45), stripHeight: 0)
        #expect(corner.rowTop == 24.5 && corner.expandedInset == 72.5)
        #expect(669 - corner.rowClearance.trailing == 538)
        #expect(corner.chromeShare(of: Self.portrait, collapsed: false) < 0.08)
    }
}

/// The Duo's inner screen as the device has it, both orientations: the status items wrap the
/// inner camera in the top-trailing corner (owner's screenshot, landscape, 3x: the time "11:08"
/// at x 831.7–871.7, the indicators above it from 845.7, the battery ring 883–924, all within
/// y 27–69; the camera as UIKit reports it, 884.67–921.67 x 29.33–66.33). Portrait's cluster is
/// taken at the same place around the camera (602.67 in 669 pt, the simulator's report). Owner:
/// "the tabs are getting cut. The tabs should go all the way to under the status bar icons. The
/// tabs, share and options buttons can go all the way to the right as much as they can, spaced
/// properly next to the status bar Wi-Fi and all the other indicators."
@MainActor
struct DuoInnerStatusRowTests {
    struct Screen: Sendable {
        var size: CGSize
        var safeTop: CGFloat
        var camera: CGRect
        /// The status items' extent: time, indicators and battery ring.
        var items: CGRect
    }

    nonisolated static let landscape = Screen(
        size: CGSize(width: 951, height: 669), safeTop: 81,
        camera: CGRect(x: 884.67, y: 29.33, width: 37, height: 37),
        items: CGRect(x: 831.7, y: 27, width: 924 - 831.7, height: 42)
    )
    nonisolated static let portrait = Screen(
        size: CGSize(width: 669, height: 951), safeTop: 82,
        camera: CGRect(x: 602.67, y: 29.33, width: 37, height: 37),
        items: CGRect(x: 602.67 - 53, y: 27, width: 924 - 831.7, height: 42)
    )
    static let strip = CGFloat(FixedChoices.tabStripHeight)
    /// Back and Forward; Tabs, Share and More (`ButtonBar.splitLeadingWidth`, `splitTrailingWidth`).
    static let capsules = (leading: CGFloat(88), trailing: CGFloat(132))

    /// The corner as `readStatusCorner` finds it on the device: the guide equal to the safe area
    /// (no corner of its own), the camera in the occlusion regions.
    static func geometry(_ screen: Screen, strip: CGFloat = strip) throws -> TopChromeGeometry {
        let found = try #require(StatusCorner.read(
            width: screen.size.width, safeTop: screen.safeTop, safeLeft: 0, safeRight: 0,
            adaptedTop: screen.safeTop, adaptedLeft: 0, adaptedRight: 0, occlusions: [screen.camera]
        ))
        #expect(found.source == .camera)
        return TopChromeGeometry(width: screen.size.width, safeTop: screen.safeTop, corner: found.rect, stripHeight: strip)
    }

    /// The layout with the camera reported active, the row's and the strip's bands as the shell
    /// passes them (`layoutInput`).
    static func layout(_ screen: Screen, geometry: TopChromeGeometry) -> DuoLayout {
        DuoLayout(DuoLayoutInput(
            pageArea: CGRect(x: 0, y: screen.safeTop, width: screen.size.width, height: screen.size.height - screen.safeTop),
            isRegularWidth: true, isRegularHeight: true, tabLayout: .above, tabCount: 3,
            division: CGRect(x: screen.size.width / 2 - 20, y: 0, width: 40, height: screen.size.height),
            occlusions: [screen.camera], chromeBand: geometry.rowTop...geometry.rowBottom,
            stripBand: geometry.stripTop...(geometry.stripTop + strip)
        ))
    }

    @Test(arguments: [landscape, portrait])
    func stripSpansTheFullWidthUnderTheStatusItems(_ screen: Screen) throws {
        let bar = try Self.geometry(screen)
        let layout = Self.layout(screen, geometry: bar)
        #expect(layout.showsStrip)
        // The camera cuts the row's lane, never the strip's: the strip sits under it.
        #expect(layout.chromeLane.upperBound == screen.camera.minX)
        #expect(layout.stripLane == 0...screen.size.width)
        let strip = bar.stripFrame(lane: layout.stripLane)
        #expect(strip.maxX == screen.size.width - TopChromeGeometry.edgeMargin, "to the screen's trailing margin")
        #expect(strip.minX == TopChromeGeometry.edgeMargin)
        #expect(strip.minY > screen.items.maxY, "under the status icons, never beside them")
        #expect(strip.minY > screen.camera.maxY)
        // On its way out it never rises over them either.
        for step in 0...20 {
            #expect(strip.minY + bar.stripTranslation(progress: CGFloat(step) / 10) > screen.items.maxY)
        }
    }

    @Test(arguments: [landscape, portrait])
    func trailingCapsuleSitsSnugBesideTheStatusItems(_ screen: Screen) throws {
        let bar = try Self.geometry(screen)
        let layout = Self.layout(screen, geometry: bar)
        let row = bar.rowFrames(lane: layout.chromeLane, leadingCapsule: Self.capsules.leading, trailingCapsule: Self.capsules.trailing)
        let corner = try #require(bar.corner)
        // Its end: the status items' left edge less the gap.
        #expect(abs(row.trailingCapsule.maxX - (corner.minX - TopChromeGeometry.cornerGap)) < 0.001)
        let spacing = screen.items.minX - row.trailingCapsule.maxX
        #expect(spacing >= 8 && spacing <= 12.5, "spaced like the bar's own gaps: \(spacing)")
        // Nothing in the row overlaps the status items.
        for piece in [row.leadingCapsule, row.pill, row.trailingCapsule] {
            #expect(!piece.intersects(screen.items))
        }
        // Centered on the status items' row.
        #expect(abs(row.trailingCapsule.midY - screen.camera.midY) < 0.001)
    }

    @Test func landscapeNumbers() throws {
        let bar = try Self.geometry(Self.landscape)
        let layout = Self.layout(Self.landscape, geometry: bar)
        let row = bar.rowFrames(lane: layout.chromeLane, leadingCapsule: Self.capsules.leading, trailingCapsule: Self.capsules.trailing)
        // Row 25.8–69.8; the trailing capsule 687.7–819.7 (was …808.7), 12 pt before "11:08".
        #expect(abs(bar.rowTop - 25.83) < 0.01)
        #expect(abs(row.trailingCapsule.maxX - 819.67) < 0.01)
        // The address takes its full 560 pt between the capsules, as near the center as that
        // leaves it (fill first, then center): 121.7–681.7, its end 6 pt before the capsule.
        #expect(row.pill.width == CGFloat(FixedChoices.topBarPillMaxWidth))
        #expect(abs(row.pill.maxX - (row.trailingCapsule.minX - ChromeGeometry.gap)) < 0.01)
        #expect(row.pill.minX > row.leadingCapsule.maxX + ChromeGeometry.gap)
        // The strip 12–939 at 73.8; the page's first line at 111.8.
        #expect(abs(bar.stripTop - 73.83) < 0.01)
        #expect(abs(bar.expandedInset - (73.83 + Self.strip + 4)) < 0.01)
    }

    @Test func portraitNumbers() throws {
        let bar = try Self.geometry(Self.portrait)
        let layout = Self.layout(Self.portrait, geometry: bar)
        let row = bar.rowFrames(lane: layout.chromeLane, leadingCapsule: Self.capsules.leading, trailingCapsule: Self.capsules.trailing)
        // The trailing capsule 405.7–537.7; the address fills between the capsules (106–399.7).
        #expect(abs(row.trailingCapsule.maxX - 537.67) < 0.01)
        #expect(abs(row.pill.minX - (row.leadingCapsule.maxX + ChromeGeometry.gap)) < 0.01)
        #expect(abs(row.pill.maxX - (row.trailingCapsule.minX - ChromeGeometry.gap)) < 0.01)
        #expect(bar.stripFrame(lane: layout.stripLane).maxX == 669 - TopChromeGeometry.edgeMargin)
    }

    @Test func guideAndCameraTogether() throws {
        // A guide that reaches in from the trailing edge, down from the top edge (0–81), and the
        // camera: across from the guide, up and down from the camera, so the row and the strip
        // sit by the status items, not by the guide's band.
        let found = try #require(StatusCorner.read(
            width: 951, safeTop: 81, safeLeft: 0, safeRight: 0, adaptedTop: 0, adaptedLeft: 0, adaptedRight: 120,
            occlusions: [Self.landscape.camera]
        ))
        #expect(found.source == .guideAndCamera)
        #expect(found.rect.minX == 831 && found.rect.maxX == 951)
        #expect(abs(found.rect.midY - Self.landscape.camera.midY) < 0.001)
        let bar = TopChromeGeometry(width: 951, safeTop: 81, corner: found.rect, stripHeight: Self.strip)
        #expect(951 - bar.rowClearance.trailing == 831 - TopChromeGeometry.cornerGap)
        #expect(abs(bar.stripTop - 73.83) < 0.01)
        // The guide alone: its band.
        let guide = try #require(StatusCorner.read(
            width: 951, safeTop: 81, safeLeft: 0, safeRight: 0, adaptedTop: 0, adaptedLeft: 0, adaptedRight: 120, occlusions: []
        ))
        #expect(guide.source == .guide && guide.rect == CGRect(x: 831, y: 0, width: 120, height: 81))
        // A camera on the other side from the guide's corner is not combined.
        let apart = try #require(StatusCorner.read(
            width: 951, safeTop: 81, safeLeft: 0, safeRight: 0, adaptedTop: 0, adaptedLeft: 0, adaptedRight: 120,
            occlusions: [CGRect(x: 30, y: 29, width: 37, height: 37)]
        ))
        #expect(apart.source == .guide)
    }
}

/// Phones and the Duo's outer screen keep the bottom pill: nothing of the inner screen's status
/// row reaches them (owner: "ensure the experience is just as good on all other screens and
/// devices we support"). Their numbers are pinned as they were before the status row change.
@MainActor
struct PhonesAndOuterScreenUnchangedTests {
    @Test func phonesAndTheOuterScreenHaveNoTopBarCornerOrStripLane() {
        // iPhone SE (3rd generation), iPhone 17 Pro Max, the Duo's outer screen (vertical bar).
        let areas = [
            CGRect(x: 0, y: 20, width: 375, height: 647),
            CGRect(x: 0, y: 62, width: 440, height: 894),
            CGRect(x: 0, y: 24, width: 466 - 84, height: 654),
        ]
        for area in areas {
            let layout = DuoLayout(DuoLayoutInput(
                pageArea: area, isRegularWidth: false, isRegularHeight: true, tabLayout: .above, tabCount: 3
            ))
            #expect(!layout.chromeOnTop)
            #expect(!layout.showsStrip)
            #expect(layout.chromeLane == area.minX...area.maxX)
            #expect(layout.stripLane == layout.chromeLane)
        }
        // The Dynamic Island (a band across the middle) and the outer screen's sensor region are
        // never a status corner; with no occlusion and a full-width status bar there is none.
        #expect(StatusCorner.read(
            width: 440, safeTop: 62, safeLeft: 0, safeRight: 0, adaptedTop: 62, adaptedLeft: 0, adaptedRight: 0,
            occlusions: [CGRect(x: 157, y: 11, width: 126, height: 37)]
        ) == nil)
        #expect(StatusCorner.read(
            width: 466, safeTop: 62, safeLeft: 0, safeRight: 0, adaptedTop: 62, adaptedLeft: 0, adaptedRight: 0,
            occlusions: [CGRect(x: 133, y: 0, width: 200, height: 62)]
        ) == nil)
        #expect(StatusCorner.read(
            width: 375, safeTop: 20, safeLeft: 0, safeRight: 0, adaptedTop: 20, adaptedLeft: 0, adaptedRight: 0, occlusions: []
        ) == nil)
    }

    @Test func bottomPillNumbersArePinned() {
        // iPhone SE: no home indicator, the button bar under the pill.
        let se = ChromeGeometry(viewHeight: 667, safeBottom: 0, hasButtonBar: true)
        #expect(se.restBottom == 659 && se.pillRestBottom == 605 && se.expandedTop == 557 && se.collapsedBottom == 659)
        // iPhone 17 Pro Max.
        let max = ChromeGeometry(viewHeight: 956, safeBottom: 34, hasButtonBar: true)
        #expect(max.restBottom == 922 && max.pillRestBottom == 868 && max.expandedTop == 820 && max.collapsedBottom == 938)
        #expect(max.expandedInset(pageBottom: 956) == 136)
        // The Duo's outer screen: the vertical bar holds the buttons, the pill alone at the bottom.
        let outer = ChromeGeometry(viewHeight: 678, safeBottom: 20, hasButtonBar: false)
        #expect(outer.restBottom == 658 && outer.pillRestBottom == 658 && outer.expandedTop == 610)
    }
}

@MainActor
struct SidebarDragTests {
    static let rail = SidebarState.rail.width

    @Test func releaseSnapsToTheNearestAllowedState() {
        let drag = SidebarDrag(widest: .expanded)
        #expect(drag.restingState(width: Self.rail + 6, velocity: 0) == .rail)
        #expect(drag.restingState(width: 20, velocity: 0) == .hidden)
        #expect(drag.restingState(width: 200, velocity: 0) == .expanded)
        // A flick carries it on.
        #expect(drag.restingState(width: 80, velocity: 1_200) == .expanded)
        #expect(drag.restingState(width: Self.rail, velocity: -800) == .hidden)
    }

    @Test func railIsTheWidestDuringASplit() {
        let drag = SidebarDrag(widest: .rail)
        #expect(drag.restingState(width: 250, velocity: 900) == .rail)
        #expect(drag.trackedWidth(Self.rail) == Self.rail)
        #expect(drag.trackedWidth(Self.rail + 100) == Self.rail + 25)
        #expect(drag.trackedWidth(-20) == 0)
    }
}
