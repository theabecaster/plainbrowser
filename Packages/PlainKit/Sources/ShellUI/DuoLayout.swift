import BrowserCore
import CoreGraphics
import Foundation
import TabGalleryUI

// The Duo layout system (docs/plan.md, section 6) as plain values, free of UIKit so `swift test`
// checks every state on macOS. The browser feeds it the root view's geometry, size classes and the
// fold's reserved regions, never the device or the screen, and applies what it returns.

/// What the layout is decided from. All rects are in the root view's coordinates.
struct DuoLayoutInput: Equatable {
    /// The area pages may use: below the status bar, beside the system's vertical bar, down to the
    /// bottom edge (the chrome floats over it).
    var pageArea: CGRect
    /// Both size classes are regular (the Duo's inner screen, an iPad-size window).
    var isRegularWidth: Bool
    var isRegularHeight: Bool
    var tabLayout: TabLayout
    /// The sidebar state the user left it in.
    var requestedSidebar: SidebarState
    /// Panes in the window (TabStore): one, or two for a split.
    var paneCount: Int
    /// Page tabs in the window (regular and private): the strip shows only for two or more.
    var tabCount: Int
    var focusedPane: Int
    /// The fold's region (`reservedRegions(kind: .division, options: .includeInactive)`): its
    /// position even when the screen is flat, where its width is zero.
    var division: CGRect?
    /// The fold is active: the screen is partly folded (book pose).
    var isDivisionActive: Bool
    /// Regions controls must avoid (`.occlusion`: the inner camera).
    var occlusions: [CGRect] = []
    /// The vertical band the floating pill and toast occupy, to test against occlusions.
    var chromeBand: ClosedRange<CGFloat> = 0...0
    /// The vertical band the tab strip occupies under a top bar, to test against occlusions; nil
    /// to use `chromeBand`. The strip sits under the status items (`TopChromeGeometry.stripTop`),
    /// so the camera beside the row is not in its way.
    var stripBand: ClosedRange<CGFloat>?
    /// The status items' corner under a top bar (`StatusCorner`), nil elsewhere. The top bar keeps
    /// clear of it itself (`TopChromeGeometry.rowClearance`, the strip under it), so the
    /// occlusion regions inside it (the status items' own region, the camera they wrap) cut
    /// neither lane: their frames pad the items for interactive content, and cutting the lane
    /// there left Tabs, Share and More and the strip short of the corner (owner, on the device).
    var statusCorner: CGRect?
    /// The user opened the side pane (Reader, Find, History next to the page) in this window.
    var sidePaneOpen = false

    init(
        pageArea: CGRect, isRegularWidth: Bool, isRegularHeight: Bool, tabLayout: TabLayout = FixedChoices.defaultTabLayout,
        requestedSidebar: SidebarState = .rail, paneCount: Int = 1, tabCount: Int = 2, focusedPane: Int = 0,
        division: CGRect? = nil, isDivisionActive: Bool = false, occlusions: [CGRect] = [],
        chromeBand: ClosedRange<CGFloat> = 0...0, stripBand: ClosedRange<CGFloat>? = nil,
        statusCorner: CGRect? = nil, sidePaneOpen: Bool = false
    ) {
        self.stripBand = stripBand
        self.statusCorner = statusCorner
        self.sidePaneOpen = sidePaneOpen
        self.pageArea = pageArea
        self.isRegularWidth = isRegularWidth
        self.isRegularHeight = isRegularHeight
        self.tabLayout = tabLayout
        self.requestedSidebar = requestedSidebar
        self.paneCount = paneCount
        self.tabCount = tabCount
        self.focusedPane = focusedPane
        self.division = division
        self.isDivisionActive = isDivisionActive
        self.occlusions = occlusions
        self.chromeBand = chromeBand
    }
}

/// Where everything goes for one `DuoLayoutInput`.
struct DuoLayout: Equatable {
    /// Tab Layout applies here: regular in both size classes and a page at least
    /// `FixedChoices.sideTabsMinimumPageWidth` wide. Elsewhere the app switcher is the only tab
    /// list (the Settings row says so).
    var tabLayoutAvailable: Bool
    /// The layout in effect: the setting, or Above where a sidebar would leave the page too narrow
    /// (inner portrait); nil where Tab Layout does not apply.
    var tabLayout: TabLayout?
    /// The sidebar is on screen (Left or Right in effect).
    var showsSidebar: Bool
    /// The sidebar is on the trailing side (Right).
    var sidebarOnRight: Bool
    /// The chrome is a top bar (Safari on the Duo's inner screen, iPad): wherever Tab Layout
    /// applies. Elsewhere it is the bottom pill (and its button bar or the system's vertical bar).
    var chromeOnTop: Bool
    /// The tab strip is on screen under the top bar (Above in effect, two or more tabs).
    var showsStrip: Bool
    /// The state the sidebar rests in now (the request, limited by split and fold).
    var sidebar: SidebarState
    /// The widest state the sidebar may take now: Rail while a split shows or the screen is
    /// partly folded.
    var widestSidebar: SidebarState
    /// How far the sidebar pushes the pages: its width when docked, the rail's when Expanded
    /// floats over the page.
    var sidebarDockWidth: CGFloat
    /// Expanded floats over the page: docked, it would leave the page under the minimum width.
    var sidebarFloats: Bool
    /// The strip's height. It floats under the top bar, over the pages, and hides with the bar.
    var stripHeight: CGFloat
    /// A split can show here (regular both ways, each pane at least the minimum width).
    var splitAvailable: Bool
    /// Both panes are on screen. A window with two panes where the split can't show (the outer
    /// screen, inner portrait) shows only the focused one, and the pair comes back on unfold.
    var splitShown: Bool
    /// The panes' frames: one, or two side by side (primary, then secondary).
    var paneFrames: [CGRect]
    /// The horizontal lane for the pill, the search field and toasts: the focused pane (all the
    /// pages under a top bar, which acts on the focused one), moved off a floating sidebar, an
    /// active fold and the camera.
    var chromeLane: ClosedRange<CGFloat>
    /// The tab strip's lane: `chromeLane`, except that only occlusions in the strip's own band
    /// (`DuoLayoutInput.stripBand`) cut it. Under the top bar the camera sits beside the row,
    /// above the strip, so the strip runs on under the status items to the screen's margin.
    var stripLane: ClosedRange<CGFloat>

    /// The focused pane's frame.
    var focusedPaneFrame: CGRect

    /// The side pane can open here: wherever the top bar is (both size classes regular, a page of
    /// at least `FixedChoices.sideTabsMinimumPageWidth`). Elsewhere Reader, Find and History keep
    /// their full-screen forms.
    var sidePaneAvailable: Bool
    /// The column the side pane takes, nil while it is closed or can't show. Beside the page at
    /// the trailing end of the pages (`FixedChoices.sidePaneFraction`, at least
    /// `sidePaneMinimumWidth`); in a split, the second pane's place; partly folded, the half after
    /// the fold, so neither the page nor the pane crosses it.
    var sidePaneColumn: CGRect?
    /// How far the side pane pushes the pages' trailing edge in (0 when it covers a split's second
    /// pane).
    var sidePaneDockWidth: CGFloat
    /// The side pane is over the split's second pane, which keeps its page but is out of sight.
    var sidePaneCoversSecondPane: Bool

    init(_ input: DuoLayoutInput) {
        let area = input.pageArea
        let regular = input.isRegularWidth && input.isRegularHeight
        let rail = SidebarState.rail.width
        let minimumPage = CGFloat(FixedChoices.sideTabsMinimumPageWidth)
        tabLayoutAvailable = regular && area.width >= minimumPage
        let sidebarFits = regular && area.width - rail >= minimumPage
        if !tabLayoutAvailable {
            tabLayout = nil
        } else if input.tabLayout.isSidebar && !sidebarFits {
            tabLayout = .above
        } else {
            tabLayout = input.tabLayout
        }
        chromeOnTop = tabLayoutAvailable
        showsSidebar = tabLayout?.isSidebar ?? false
        sidebarOnRight = tabLayout == .right
        // One tab has nothing to switch to: the strip earns its place from the second.
        showsStrip = tabLayout == .above && input.tabCount > 1
        stripHeight = showsStrip ? CGFloat(FixedChoices.tabStripHeight) : 0

        let vertical = input.division.flatMap { Self.verticalFold($0) }
        let minimumPane = CGFloat(FixedChoices.splitMinimumPaneWidth)
        // A split needs two panes of the minimum width beside the narrowest docked sidebar.
        let widthForPanes = area.width - (showsSidebar ? rail : 0)
        splitAvailable = regular && widthForPanes >= 2 * minimumPane
        splitShown = splitAvailable && input.paneCount > 1

        if showsSidebar {
            widestSidebar = splitShown || input.isDivisionActive || (chromeOnTop && input.sidePaneOpen) ? .rail : .expanded
            sidebar = min(input.requestedSidebar, widestSidebar)
            let expandedLeavesRoom = area.width - SidebarState.expanded.width >= minimumPage
            sidebarFloats = sidebar == .expanded && !expandedLeavesRoom
            sidebarDockWidth = sidebarFloats ? rail : sidebar.width
        } else {
            widestSidebar = .hidden
            sidebar = .hidden
            sidebarFloats = false
            sidebarDockWidth = 0
        }

        // The strip floats with the top bar; only a docked sidebar and the side pane move the pages.
        let allPanes = CGRect(
            x: area.minX + (sidebarOnRight ? 0 : sidebarDockWidth), y: area.minY,
            width: max(0, area.width - sidebarDockWidth), height: area.height
        )
        sidePaneAvailable = chromeOnTop
        sidePaneCoversSecondPane = sidePaneAvailable && input.sidePaneOpen && splitShown
        var panes = allPanes
        if sidePaneAvailable, input.sidePaneOpen, !splitShown {
            let minimum = CGFloat(FixedChoices.sidePaneMinimumWidth)
            let width = max(minimum, (allPanes.width * CGFloat(FixedChoices.sidePaneFraction)).rounded())
            var pageEnd = allPanes.maxX - width
            var column = CGRect(x: pageEnd, y: allPanes.minY, width: width, height: allPanes.height)
            // Partly folded, the page and the pane each take one side of the fold.
            if input.isDivisionActive, let fold = vertical, fold.minX - allPanes.minX >= minimum,
               allPanes.maxX - fold.maxX >= minimum {
                pageEnd = fold.minX
                column = CGRect(x: fold.maxX, y: allPanes.minY, width: allPanes.maxX - fold.maxX, height: allPanes.height)
            }
            panes.size.width = max(0, pageEnd - allPanes.minX)
            sidePaneColumn = column
            sidePaneDockWidth = allPanes.maxX - pageEnd
        } else {
            sidePaneColumn = nil
            sidePaneDockWidth = 0
        }
        if splitShown {
            // Flat: on the crease when it leaves both panes their minimum, else halves. Partly
            // folded: one pane each side of the fold (UIArrangementViewController places them so).
            var splitX = panes.midX
            var gap: CGFloat = 0
            if let fold = vertical, fold.midX - panes.minX >= minimumPane, panes.maxX - fold.midX >= minimumPane {
                splitX = fold.midX
                if input.isDivisionActive { gap = fold.width }
            }
            let first = CGRect(x: panes.minX, y: panes.minY, width: splitX - gap / 2 - panes.minX, height: panes.height)
            let second = CGRect(x: splitX + gap / 2, y: panes.minY, width: panes.maxX - splitX - gap / 2, height: panes.height)
            paneFrames = [first, second]
            focusedPaneFrame = input.focusedPane == 1 ? second : first
            if sidePaneCoversSecondPane {
                // The pane takes the second pane's place; the first one is the page it serves.
                sidePaneColumn = second
                focusedPaneFrame = first
            }
        } else {
            paneFrames = [panes]
            focusedPaneFrame = panes
        }

        // A top bar spans the pages: a pane of a split is too narrow for a bar of its own. Partly
        // folded, the panes sit either side of the fold and the bar keeps to the focused one.
        let spansPanes = chromeOnTop && !(splitShown && input.isDivisionActive) && !sidePaneCoversSecondPane
        var lane = spansPanes ? panes.minX...panes.maxX : focusedPaneFrame.minX...focusedPaneFrame.maxX
        // Expanded floating over the page: the pill stays clear of it.
        if sidebarFloats {
            let width = SidebarState.expanded.width
            let covered = sidebarOnRight ? (area.maxX - width)...area.maxX : area.minX...(area.minX + width)
            lane = Self.lane(lane, avoiding: covered)
        }
        // Book pose: the pill and toasts keep off the fold. A flat fold has no width and is
        // only used for its position (the split above).
        if input.isDivisionActive, let fold = vertical {
            lane = Self.lane(lane, avoiding: fold.minX...fold.maxX)
        }
        var strip = lane
        let corner = chromeOnTop ? input.statusCorner : nil
        let occlusions = input.occlusions.filter { region in corner.map { !region.intersects($0) } ?? true }
        for region in occlusions where region.minY < input.chromeBand.upperBound
            && region.maxY > input.chromeBand.lowerBound {
            lane = Self.lane(lane, avoiding: region.minX...region.maxX)
        }
        let stripBand = input.stripBand ?? input.chromeBand
        for region in occlusions where region.minY < stripBand.upperBound && region.maxY > stripBand.lowerBound {
            strip = Self.lane(strip, avoiding: region.minX...region.maxX)
        }
        chromeLane = lane
        stripLane = strip
    }

    /// The division as a vertical crease (book pose), or nil for a horizontal one (tabletop),
    /// which needs no layout of its own: the page keeps spanning the screen.
    static func verticalFold(_ division: CGRect) -> CGRect? {
        division.height > division.width ? division : nil
    }

    /// `lane` without `obstacle`: the larger side left, or `lane` when they don't meet.
    static func lane(_ lane: ClosedRange<CGFloat>, avoiding obstacle: ClosedRange<CGFloat>) -> ClosedRange<CGFloat> {
        guard obstacle.lowerBound < lane.upperBound, obstacle.upperBound > lane.lowerBound else { return lane }
        let leading = lane.lowerBound...max(lane.lowerBound, obstacle.lowerBound)
        let trailing = min(lane.upperBound, obstacle.upperBound)...lane.upperBound
        let leadingWidth = leading.upperBound - leading.lowerBound
        let trailingWidth = trailing.upperBound - trailing.lowerBound
        return leadingWidth >= trailingWidth ? leading : trailing
    }
}
