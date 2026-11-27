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

/// The top bar's geometry and how much of the inner screen the chrome takes (the redesign's
/// target, docs/research/safari-duo.md: about 12% at rest, less while reading).
@MainActor
struct TopChromeGeometryTests {
    static let status: CGFloat = 24
    static let landscape = CGSize(width: 951, height: 669)
    static let portrait = CGSize(width: 669, height: 951)

    @Test func insetsCoverTheRowAndTheStrip() {
        let bar = TopChromeGeometry(pageTop: Self.status, stripHeight: 0)
        // 2 above the row, 44 row, 4 under.
        #expect(bar.expandedInset == 50)
        #expect(bar.rowTop == Self.status + 2)
        let strip = TopChromeGeometry(pageTop: Self.status, stripHeight: CGFloat(FixedChoices.tabStripHeight))
        #expect(strip.stripTop == Self.status + 50)
        #expect(strip.expandedInset == 50 + CGFloat(FixedChoices.tabStripHeight) + 4)
        #expect(strip.collapsedInset < strip.expandedInset)
        #expect(strip.collapsedInset == bar.collapsedInset, "collapsed, only the address is left")
    }

    @Test func collapseShrinksThePillUnderTheStatusBar() {
        let bar = TopChromeGeometry(pageTop: Self.status, stripHeight: 34)
        let rest = bar.pillTransform(progress: 0)
        #expect(rest.translationY == 0 && rest.scale == 1)
        let collapsed = bar.pillTransform(progress: 1)
        #expect(collapsed.scale == TopChromeGeometry.compactScale)
        // The collapsed pill's top meets the page's top.
        let center = bar.rowTop + TopChromeGeometry.rowHeight / 2 + collapsed.translationY
        #expect(abs(center - bar.collapsedPillHeight / 2 - Self.status) < 0.001)
        #expect(bar.stripTranslation(progress: 1) < 0 && bar.buttonsTranslation(progress: 1) < 0)
    }

    @Test func chromeStaysNearTwelvePercentAtRestAndUnderTenWhileReading() {
        let bar = TopChromeGeometry(pageTop: Self.status, stripHeight: 0)
        #expect(bar.chromeShare(of: Self.landscape, collapsed: false) <= 0.12)
        #expect(bar.chromeShare(of: Self.portrait, collapsed: false) <= 0.08)
        #expect(bar.chromeShare(of: Self.landscape, collapsed: true) <= 0.09)
        let strip = TopChromeGeometry(pageTop: Self.status, stripHeight: CGFloat(FixedChoices.tabStripHeight))
        #expect(strip.chromeShare(of: Self.landscape, collapsed: false) <= 0.17)
        #expect(strip.chromeShare(of: Self.portrait, collapsed: false) <= 0.12)
        #expect(strip.chromeShare(of: Self.landscape, collapsed: true) <= 0.09)
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
