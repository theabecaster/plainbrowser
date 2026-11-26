import BrowserCore
import CoreGraphics
@testable import ShellUI
import TabGalleryUI
import Testing

/// Every Duo state from docs/plan.md, section 6, on the layout model. Geometry is the real Duo's:
/// outer 466x678 portrait, inner 951x669 landscape with the crease at the center, and the system's
/// vertical bar (about 84 pt) on the trailing edge where the system shows one.
@MainActor
struct DuoLayoutTests {
    static let bar: CGFloat = 84
    /// Inner landscape, beside the vertical bar (the status bar sits in the bar's column).
    static let innerLandscape = CGRect(x: 0, y: 0, width: 951 - bar, height: 669)
    /// The crease of the inner screen as the simulator reports it (`.includeInactive`), the same
    /// rect flat (inactive) and partly folded (active).
    static let flatFold = CGRect(x: 455.5, y: 0, width: 40, height: 669)
    static let bookFold = flatFold

    func inner(
        layout: TabLayout = .regular, sidebar: SidebarState = .rail, panes: Int = 1, focused: Int = 0,
        fold: CGRect? = flatFold, active: Bool = false
    ) -> DuoLayout {
        DuoLayout(DuoLayoutInput(
            pageArea: Self.innerLandscape, isRegularWidth: true, isRegularHeight: true, tabLayout: layout,
            requestedSidebar: sidebar, paneCount: panes, focusedPane: focused, division: fold, isDivisionActive: active
        ))
    }

    @Test func outerScreenShowsOnePaneAndNoSideTabs() {
        let outer = DuoLayout(DuoLayoutInput(
            pageArea: CGRect(x: 0, y: 24, width: 466 - Self.bar, height: 654), isRegularWidth: false, isRegularHeight: true,
            tabLayout: .sideTabs, paneCount: 2, focusedPane: 1
        ))
        #expect(!outer.sideTabsAvailable)
        #expect(!outer.showsSidebar)
        #expect(!outer.splitAvailable)
        #expect(!outer.splitShown)
        #expect(outer.paneFrames.count == 1)
        #expect(outer.chromeLane == 0...(466 - Self.bar))
    }

    @Test func innerPortraitHasNoSplitAndNoSideTabs() {
        // 669 pt wide: the rail would leave 605 pt, under the 640 pt minimum, and two panes would
        // be 334 pt each.
        let portrait = DuoLayout(DuoLayoutInput(
            pageArea: CGRect(x: 0, y: 24, width: 669, height: 927), isRegularWidth: true, isRegularHeight: true,
            tabLayout: .sideTabs, paneCount: 2
        ))
        #expect(!portrait.sideTabsAvailable)
        #expect(!portrait.splitAvailable)
        #expect(portrait.paneFrames.count == 1)
    }

    @Test func compactHeightIsNeverWideEnough() {
        // A Pro Max in landscape: regular width, compact height.
        let phone = DuoLayout(DuoLayoutInput(
            pageArea: CGRect(x: 59, y: 0, width: 838, height: 440), isRegularWidth: true, isRegularHeight: false,
            tabLayout: .sideTabs, paneCount: 2
        ))
        #expect(!phone.sideTabsAvailable)
        #expect(!phone.splitShown)
    }

    @Test func innerLandscapeSplitsOnTheCrease() {
        let split = inner(panes: 2, focused: 1)
        #expect(split.splitShown)
        #expect(split.paneFrames.count == 2)
        #expect(split.paneFrames[0].maxX == 475.5)
        #expect(split.paneFrames[1].minX == 475.5)
        #expect(split.paneFrames[1].maxX == Self.innerLandscape.maxX)
        // The pill rides over the focused pane.
        #expect(split.chromeLane == 475.5...Self.innerLandscape.maxX)
    }

    @Test func bookPosePutsOnePaneEachSideOfTheFold() {
        let book = inner(panes: 2, focused: 0, fold: Self.bookFold, active: true)
        #expect(book.paneFrames[0].maxX == Self.bookFold.minX)
        #expect(book.paneFrames[1].minX == Self.bookFold.maxX)
        #expect(book.chromeLane == 0...Self.bookFold.minX)
    }

    @Test func splitFallsBackToHalvesWhenTheCreaseLeavesAPaneTooNarrow() {
        let off = CGRect(x: 820, y: 0, width: 0, height: 669)
        let split = inner(panes: 2, fold: off)
        #expect(split.paneFrames[0].width == split.paneFrames[1].width)
    }

    @Test func sideTabsRailDocksAndExpandedFloatsWhenThePageWouldBeTooNarrow() {
        let rail = inner(layout: .sideTabs, sidebar: .rail)
        #expect(rail.sideTabsAvailable)
        #expect(rail.showsSidebar)
        #expect(rail.sidebar == .rail)
        #expect(rail.sidebarDockWidth == 64)
        #expect(rail.paneFrames[0].minX == 64)
        #expect(rail.paneFrames[0].width >= 640)

        // 867 - 260 = 607 pt of page: Expanded floats over it, the page keeps the rail's width.
        let expanded = inner(layout: .sideTabs, sidebar: .expanded)
        #expect(expanded.sidebar == .expanded)
        #expect(expanded.sidebarFloats)
        #expect(expanded.sidebarDockWidth == 64)

        // A window with room beside it docks Expanded.
        let wide = DuoLayout(DuoLayoutInput(
            pageArea: CGRect(x: 0, y: 24, width: 1180, height: 796), isRegularWidth: true, isRegularHeight: true,
            tabLayout: .sideTabs, requestedSidebar: .expanded
        ))
        #expect(!wide.sidebarFloats)
        #expect(wide.sidebarDockWidth == 260)
    }

    @Test func splitAndFoldForceTheRail() {
        let split = inner(layout: .sideTabs, sidebar: .expanded, panes: 2)
        #expect(split.sidebar == .rail)
        #expect(split.widestSidebar == .rail)
        #expect(split.splitShown)
        #expect(split.paneFrames.allSatisfy { $0.width >= CGFloat(FixedChoices.splitMinimumPaneWidth) })

        let book = inner(layout: .sideTabs, sidebar: .expanded, fold: Self.bookFold, active: true)
        #expect(book.sidebar == .rail)

        let hidden = inner(layout: .sideTabs, sidebar: .hidden, panes: 2)
        #expect(hidden.sidebar == .hidden)
        #expect(hidden.sidebarDockWidth == 0)
    }

    @Test func regularTabsNeverShowTheSidebar() {
        let regular = inner(layout: .regular, sidebar: .expanded)
        #expect(regular.sideTabsAvailable)
        #expect(!regular.showsSidebar)
        #expect(regular.sidebarDockWidth == 0)
    }

    @Test func bookPoseMovesThePillOffTheFold() {
        let book = inner(fold: Self.bookFold, active: true)
        #expect(book.chromeLane.upperBound <= Self.bookFold.minX || book.chromeLane.lowerBound >= Self.bookFold.maxX)
        // Flat, the crease has no width and the pill stays centered on the page.
        let flat = inner()
        #expect(flat.chromeLane == Self.innerLandscape.minX...Self.innerLandscape.maxX)
    }

    @Test func tabletopFoldNeedsNoLayout() {
        let tabletop = CGRect(x: 0, y: 470, width: 669, height: 30)
        let layout = DuoLayout(DuoLayoutInput(
            pageArea: CGRect(x: 0, y: 24, width: 669, height: 927), isRegularWidth: true, isRegularHeight: true,
            division: tabletop, isDivisionActive: true
        ))
        #expect(layout.chromeLane == 0...669)
    }

    @Test func pillAvoidsTheCameraOnlyWhereItSits() {
        let camera = CGRect(x: 400, y: 600, width: 60, height: 40)
        var input = DuoLayoutInput(
            pageArea: Self.innerLandscape, isRegularWidth: true, isRegularHeight: true, occlusions: [camera],
            chromeBand: 580...669
        )
        #expect(DuoLayout(input).chromeLane == 460...Self.innerLandscape.maxX)
        input.chromeBand = 0...20
        #expect(DuoLayout(input).chromeLane == Self.innerLandscape.minX...Self.innerLandscape.maxX)
    }

    @Test func laneAvoidanceKeepsTheLargerSide() {
        #expect(DuoLayout.lane(0...100, avoiding: 40...50) == 50...100)
        #expect(DuoLayout.lane(0...100, avoiding: 60...70) == 0...60)
        #expect(DuoLayout.lane(0...100, avoiding: 200...210) == 0...100)
    }
}

@MainActor
struct SidebarDragTests {
    @Test func releaseSnapsToTheNearestAllowedState() {
        let drag = SidebarDrag(widest: .expanded)
        #expect(drag.restingState(width: 70, velocity: 0) == .rail)
        #expect(drag.restingState(width: 20, velocity: 0) == .hidden)
        #expect(drag.restingState(width: 200, velocity: 0) == .expanded)
        // A flick carries it on.
        #expect(drag.restingState(width: 80, velocity: 1_200) == .expanded)
        #expect(drag.restingState(width: 64, velocity: -800) == .hidden)
    }

    @Test func railIsTheWidestDuringASplit() {
        let drag = SidebarDrag(widest: .rail)
        #expect(drag.restingState(width: 250, velocity: 900) == .rail)
        #expect(drag.trackedWidth(64) == 64)
        #expect(drag.trackedWidth(164) == CGFloat(89))
        #expect(drag.trackedWidth(-20) == 0)
    }
}
