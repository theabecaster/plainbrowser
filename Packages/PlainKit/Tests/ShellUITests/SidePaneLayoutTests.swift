import BrowserCore
import CoreGraphics
@testable import ShellUI
import TabGalleryUI
import Testing

/// The side pane (Reader, Find, History next to the page) on the layout model: where it can show,
/// its column, what it does to the pages, a split and a partly folded crease.
@MainActor
struct SidePaneLayoutTests {
    static let statusBar: CGFloat = 24
    static let landscape = CGRect(x: 0, y: statusBar, width: 951, height: 669 - statusBar)
    static let portrait = CGRect(x: 0, y: statusBar, width: 669, height: 951 - statusBar)
    static let fold = CGRect(x: 455.5, y: 0, width: 40, height: 669)

    func layout(
        open: Bool = true, area: CGRect = landscape, tabLayout: TabLayout = .above, sidebar: SidebarState = .rail,
        panes: Int = 1, focused: Int = 0, active: Bool = false, regular: Bool = true
    ) -> DuoLayout {
        DuoLayout(DuoLayoutInput(
            pageArea: area, isRegularWidth: regular, isRegularHeight: true, tabLayout: tabLayout,
            requestedSidebar: sidebar, paneCount: panes, tabCount: 3, focusedPane: focused, division: Self.fold,
            isDivisionActive: active, sidePaneOpen: open
        ))
    }

    @Test func onlyWhereTheTopBarIs() {
        #expect(layout().sidePaneAvailable)
        #expect(layout(area: Self.portrait).sidePaneAvailable)
        let outer = layout(area: CGRect(x: 0, y: 24, width: 382, height: 654), regular: false)
        #expect(!outer.sidePaneAvailable)
        #expect(outer.sidePaneColumn == nil, "the outer screen keeps Reader, Find and History full screen")
        #expect(outer.paneFrames == [CGRect(x: 0, y: 24, width: 382, height: 654)])
    }

    @Test func closedChangesNothing() {
        let closed = layout(open: false)
        #expect(closed.sidePaneColumn == nil)
        #expect(closed.sidePaneDockWidth == 0)
        #expect(closed.paneFrames == [Self.landscape])
    }

    @Test func landscapeTakesThirtyPercentBesideThePage() {
        let open = layout()
        #expect(open.sidePaneColumn == CGRect(x: 666, y: Self.statusBar, width: 285, height: Self.landscape.height))
        #expect(open.sidePaneDockWidth == 285)
        #expect(open.paneFrames == [CGRect(x: 0, y: Self.statusBar, width: 666, height: Self.landscape.height)])
        #expect(open.chromeLane == 0...666, "the top bar acts on the page and stays over it")
    }

    @Test func portraitTakesTheMinimumWidth() {
        let open = layout(area: Self.portrait)
        #expect(open.sidePaneColumn?.width == 250)
        #expect(open.paneFrames[0].width == 419, "wider than the outer screen's page")
    }

    @Test func aSidebarStaysARailAndThePaneSitsInsideARightOne() {
        let left = layout(tabLayout: .left, sidebar: .expanded)
        #expect(left.sidebar == .rail, "the pane and the page share what the rail leaves")
        let pages = 951 - SidebarState.rail.width
        let width = (pages * 0.3).rounded()
        #expect(left.sidePaneColumn?.maxX == 951)
        #expect(left.sidePaneColumn?.width == width)
        #expect(left.paneFrames[0].minX == SidebarState.rail.width)
        let right = layout(tabLayout: .right)
        #expect(right.sidePaneColumn?.maxX == 951 - SidebarState.rail.width, "between the page and the sidebar")
        #expect(right.paneFrames[0].minX == 0)
    }

    @Test func aSplitGivesTheSecondPanesPlace() {
        let split = layout(panes: 2, focused: 1)
        #expect(split.splitShown)
        #expect(split.sidePaneCoversSecondPane)
        #expect(split.sidePaneDockWidth == 0, "the panes keep their frames: no page relayouts")
        #expect(split.sidePaneColumn == split.paneFrames[1])
        #expect(split.focusedPaneFrame == split.paneFrames[0], "the first pane is the page the pane serves")
        #expect(split.chromeLane == split.paneFrames[0].minX...split.paneFrames[0].maxX)
    }

    @Test func bookPoseGivesEachSideOfTheFold() {
        let book = layout(active: true)
        #expect(book.paneFrames == [CGRect(x: 0, y: Self.statusBar, width: Self.fold.minX, height: Self.landscape.height)])
        #expect(book.sidePaneColumn == CGRect(x: Self.fold.maxX, y: Self.statusBar, width: 951 - Self.fold.maxX, height: Self.landscape.height))
        #expect(book.chromeLane.upperBound <= Self.fold.minX, "no chrome on the crease")
        // Flat, the crease is only a position: the 30% column.
        #expect(layout(active: false).sidePaneColumn?.minX == 666)
    }
}
