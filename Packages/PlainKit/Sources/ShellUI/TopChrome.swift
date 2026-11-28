import BrowserCore
import CoreGraphics
import Foundation

// The top bar on a wide screen (the Duo's inner screen, iPad-size windows), as plain values free of
// UIKit so `swift test` checks them on macOS. Safari puts its bar there on the Duo's inner screen:
// one row at the top, the page under it at full width (docs/research/safari-duo.md).
//
// Where the system keeps its status items to a corner (the Duo's inner screen: clock and battery in
// the top-trailing corner of an 81 pt safe area), the row sits in that zone, on the status items'
// row and clear of their corner, and the page runs to the top edge under it. Where the status bar
// spans the width, the row sits under it. Either way the bar floats over the page like the bottom
// pill does on a phone: it moves by transform and alpha only, and the page's top
// `obscuredContentInsets` never follows it (`TopChromeGeometry.obscuredInset`). Decisions:
// docs/decisions.md, "Duo inner screen: the bar in the status row" and "The page's top inset
// never follows the bar".

/// The corner the system's status items keep to, read from the root view's safe area and its
/// corner-adaptive variant (`UIView.edgeInsets(for: .safeArea(cornerAdaptation: .horizontal))`,
/// the guide for bar-like content beside a corner element). Never from the device or the screen.
enum StatusCorner {
    /// The corner as a rect in the root view's coordinates, or nil where the status bar spans the
    /// width (the adapted guide is no shorter than the safe area, or no wider at either side).
    ///
    /// The adapted guide's top is what the row may use beside the corner; its leading or trailing
    /// inset is how far the corner reaches in. The corner then runs from that inset to the edge,
    /// from the adapted top down to the safe area's top.
    static func rect(
        width: CGFloat, safeTop: CGFloat, safeLeft: CGFloat, safeRight: CGFloat,
        adaptedTop: CGFloat, adaptedLeft: CGFloat, adaptedRight: CGFloat
    ) -> CGRect? {
        // Half a point either way is rounding, not a corner.
        let slack: CGFloat = 0.5
        guard width > 0, adaptedTop < safeTop - slack else { return nil }
        let top = max(adaptedTop, 0)
        let height = safeTop - top
        // The side the guide grew on more holds the corner.
        if adaptedRight > safeRight + slack, adaptedRight - safeRight >= adaptedLeft - safeLeft {
            return CGRect(x: width - adaptedRight, y: top, width: adaptedRight - safeRight, height: height)
        }
        if adaptedLeft > safeLeft + slack {
            return CGRect(x: safeLeft, y: top, width: adaptedLeft - safeLeft, height: height)
        }
        return nil
    }

    /// An occlusion region as UIKit reports it (`UIView.ReservedRegion`): its frame, which
    /// includes the margins it keeps around the element for interactive content, and the
    /// element's own rect inside them (the frame less `margins`).
    struct Region: Equatable, Sendable {
        var frame: CGRect
        var reserved: CGRect

        init(frame: CGRect, reserved: CGRect? = nil) {
            self.frame = frame
            self.reserved = reserved ?? frame
        }
    }

    /// What the corner was read from, for the `duo` log.
    enum Source: String, Sendable {
        /// The status items' own occlusion region (the Duo's inner screen, Device Hub's simulator).
        case statusRegion
        /// The corner-adaptive guide alone.
        case guide
        /// The camera the status items wrap, plus `FixedChoices.statusItemsReach`.
        case camera
        /// The guide's reach across, the camera's row up and down.
        case guideAndCamera
    }

    /// The corner from everything the system reports, in order:
    /// 1. The status items' own occlusion region (`statusRegion(in:...)`): the most direct word.
    /// 2. The guide (`rect(width:safeTop:...)`), which says how far across the status items reach;
    ///    with a camera they wrap on the same side (`camera(in:...)`), the camera's row up and down:
    ///    the battery ring is drawn around it, the clock beside it (the device: items at y 27–69,
    ///    the camera's middle at 47.8), where a guide band from the screen's top to the safe
    ///    area's (0–81) would put the row above the items.
    /// 3. The camera alone.
    static func read(
        width: CGFloat, safeTop: CGFloat, safeLeft: CGFloat, safeRight: CGFloat,
        adaptedTop: CGFloat, adaptedLeft: CGFloat, adaptedRight: CGFloat, occlusions: [Region]
    ) -> (rect: CGRect, source: Source)? {
        if let region = statusRegion(in: occlusions, width: width, safeTop: safeTop) {
            return (region, .statusRegion)
        }
        let guide = rect(
            width: width, safeTop: safeTop, safeLeft: safeLeft, safeRight: safeRight,
            adaptedTop: adaptedTop, adaptedLeft: adaptedLeft, adaptedRight: adaptedRight
        )
        let camera = camera(in: occlusions, width: width, safeTop: safeTop)
        switch (guide, camera) {
        case let (guide?, camera?) where (guide.midX > width / 2) == (camera.midX > width / 2):
            return (CGRect(x: guide.minX, y: camera.minY, width: guide.width, height: camera.height), .guideAndCamera)
        case let (guide?, _):
            return (guide, .guide)
        case let (nil, camera?):
            return (camera, .camera)
        case (nil, nil):
            return nil
        }
    }

    /// `read` with plain frames (no margins), for tests.
    static func read(
        width: CGFloat, safeTop: CGFloat, safeLeft: CGFloat, safeRight: CGFloat,
        adaptedTop: CGFloat, adaptedLeft: CGFloat, adaptedRight: CGFloat, occlusions: [CGRect]
    ) -> (rect: CGRect, source: Source)? {
        read(
            width: width, safeTop: safeTop, safeLeft: safeLeft, safeRight: safeRight, adaptedTop: adaptedTop,
            adaptedLeft: adaptedLeft, adaptedRight: adaptedRight, occlusions: occlusions.map { Region(frame: $0) }
        )
    }

    /// A region that can hold the status items: inside the top safe area, in the outer quarter
    /// of the width at either side (true for the trailing side), nil for anything else: a
    /// full-width band (the outer screen's Dynamic Island) or a region below the safe area's top.
    private static func cornerSide(_ region: Region, width: CGFloat, safeTop: CGFloat) -> Bool? {
        let frame = region.frame
        // A point or two past the safe area's top is rounding (`FixedChoices.statusZoneRounding`).
        let rounding = CGFloat(FixedChoices.statusZoneRounding)
        guard frame.height > 0, frame.minY < safeTop, frame.maxY <= safeTop + rounding else { return nil }
        if frame.minX >= width * 0.75 { return true }
        if frame.maxX <= width * 0.25 { return false }
        return nil
    }

    /// The row a corner element sits on: centered on it, at least a row high, never above the top.
    private static func band(around rect: CGRect) -> (top: CGFloat, height: CGFloat) {
        let half = max(rect.height, TopChromeGeometry.rowHeight) / 2
        let top = max(0, rect.midY - half)
        return (top, rect.midY + half - top)
    }

    /// The status items' own region: a corner region that reaches the screen's side edge. The
    /// Duo's inner screen reports one (Device Hub's simulator, landscape: 807–951 x 0–82, the
    /// safe area's height, active) around the time, the indicators and the battery ring, which
    /// are drawn at 831–924 x 27–69, as on the device. The frame includes margins kept for
    /// interactive content; the items start `FixedChoices.statusRegionPadding` inside it, or where
    /// the region's own margins say, whichever is further in. The row is centered on the items:
    /// on the region's reserved rect where its margins make that shorter than the frame, else a
    /// row high, `FixedChoices.statusRegionBottomPadding` above the region's bottom (the items'
    /// middle at 48 in 0–82; the frame's own middle, 41, put the row 7 pt above them).
    static func statusRegion(in regions: [Region], width: CGFloat, safeTop: CGFloat) -> CGRect? {
        let padding = CGFloat(FixedChoices.statusRegionPadding)
        for region in regions {
            guard let trailing = cornerSide(region, width: width, safeTop: safeTop) else { continue }
            let frame = region.frame
            let reserved = region.reserved
            let rowHeight = TopChromeGeometry.rowHeight
            let items = reserved.height < frame.height - 0.5 ? reserved : CGRect(
                x: reserved.minX, y: frame.maxY - CGFloat(FixedChoices.statusRegionBottomPadding) - rowHeight,
                width: reserved.width, height: rowHeight
            )
            let band = band(around: items)
            if trailing, frame.maxX >= width - 0.5 {
                let left = min(max(region.reserved.minX, frame.minX + padding), width)
                return CGRect(x: left, y: band.top, width: width - left, height: band.height)
            }
            if !trailing, frame.minX <= 0.5 {
                let right = max(min(region.reserved.maxX, frame.maxX - padding), 0)
                return CGRect(x: 0, y: band.top, width: right, height: band.height)
            }
        }
        return nil
    }

    /// The corner around a camera the status items wrap: a corner region clear of the side
    /// edge. The simulator's resizable window reports the Duo's inner camera so (37 pt at
    /// x 885–922, y 29–66 in landscape), its safe area's top (81 pt) clears it, and the clock and
    /// battery ring sit around it. The corner reaches `FixedChoices.statusItemsReach` past the
    /// camera toward the middle (the clock's left edge) and is centered on the camera's row, at
    /// least a row high.
    static func camera(in regions: [Region], width: CGFloat, safeTop: CGFloat) -> CGRect? {
        let reach = CGFloat(FixedChoices.statusItemsReach)
        for region in regions {
            guard let trailing = cornerSide(region, width: width, safeTop: safeTop) else { continue }
            let camera = region.reserved
            let band = band(around: camera)
            if trailing {
                return CGRect(x: camera.minX - reach, y: band.top, width: width - camera.minX + reach, height: band.height)
            }
            return CGRect(x: 0, y: band.top, width: camera.maxX + reach, height: band.height)
        }
        return nil
    }

    /// The corner from occlusion frames alone (no guide): the status items' region, else a
    /// camera. For tests.
    static func rect(aroundOcclusions frames: [CGRect], width: CGFloat, safeTop: CGFloat) -> CGRect? {
        let regions = frames.map { Region(frame: $0) }
        return statusRegion(in: regions, width: width, safeTop: safeTop) ?? camera(in: regions, width: width, safeTop: safeTop)
    }
}

/// Where the top bar and the strip under it sit, expanded and collapsed, in the root view's
/// coordinates. The pages start at the root view's top edge under a top bar, so the insets are
/// measured from there too.
struct TopChromeGeometry: Equatable {
    /// The root view's width.
    var width: CGFloat
    /// The safe area's top: under every status item.
    var safeTop: CGFloat
    /// The corner the status items keep to (`StatusCorner`), nil under a full-width status bar.
    var corner: CGRect?
    /// The strip's height under the bar, 0 when it does not show.
    var stripHeight: CGFloat

    init(width: CGFloat, safeTop: CGFloat, corner: CGRect? = nil, stripHeight: CGFloat) {
        self.width = width
        self.safeTop = safeTop
        self.stripHeight = stripHeight
        // A corner too thin to hold the row's controls beside it is a full-width status bar.
        if let corner, corner.width > 0, corner.height > 0, corner.minX > 0 || corner.maxX < width {
            self.corner = corner
        } else {
            self.corner = nil
        }
    }

    /// The bar's row: one 44 pt control high.
    static var rowHeight: CGFloat { CGFloat(FixedChoices.topBarHeight) }
    /// Between a full-width status bar and the row.
    static let topGap: CGFloat = 2
    /// Between the row and the strip, and under the lowest of them.
    static let gap: CGFloat = 4
    /// Between the screen's (the lane's) edges and the capsules, the pill and the strip:
    /// `Spacing.m`.
    static let edgeMargin: CGFloat = 12
    /// Between the row's end and the status items' left edge (`FixedChoices.statusItemsGap`).
    static var cornerGap: CGFloat { CGFloat(FixedChoices.statusItemsGap) }
    /// The collapsed pill's size relative to the expanded one.
    static var compactScale: CGFloat { CGFloat(FixedChoices.topBarCollapsedScale) }

    /// The row sits in the status zone, beside the status items, rather than under it.
    var isInStatusZone: Bool { corner != nil }

    /// The row's top (the pill's and the buttons'). In the status zone: centered on the corner's
    /// middle, never above the corner's top; under a full-width status bar: just under it.
    var rowTop: CGFloat {
        guard let corner else { return safeTop + Self.topGap }
        return max(corner.midY - Self.rowHeight / 2, corner.minY)
    }

    /// The row's bottom.
    var rowBottom: CGFloat { rowTop + Self.rowHeight }

    /// How far the row keeps from the leading and trailing edges of the root view: past the
    /// corner and `cornerGap`, or 0 where nothing is in the way.
    var rowClearance: (leading: CGFloat, trailing: CGFloat) {
        guard let corner else { return (0, 0) }
        let onTrailing = corner.midX > width / 2
        let clearance = onTrailing ? width - corner.minX + Self.cornerGap : corner.maxX + Self.cornerGap
        return onTrailing ? (0, clearance) : (clearance, 0)
    }

    /// Where the row's pieces land in `lane` (the chrome lane's x range), as the top bar's
    /// constraints place them (`makeTopBarConstraints`): the button bar from the lane's margin to
    /// the status corner's clearance, its two capsules (`leadingCapsule` and `trailingCapsule`
    /// wide) at its ends; the address pill as wide as the room between them allows, up to
    /// `FixedChoices.topBarPillMaxWidth`, then as near the lane's center as that leaves it. For
    /// tests: the device's numbers in both orientations.
    func rowFrames(
        lane: ClosedRange<CGFloat>, leadingCapsule: CGFloat, trailingCapsule: CGFloat
    ) -> (leadingCapsule: CGRect, pill: CGRect, trailingCapsule: CGRect) {
        let clearance = rowClearance
        let margin = Self.edgeMargin
        let gap = ChromeGeometry.gap
        let barStart = max(lane.lowerBound + margin, clearance.leading)
        let barEnd = min(lane.upperBound - margin, width - clearance.trailing)
        let pillStart = max(barStart, barStart + leadingCapsule + gap)
        let pillEnd = min(barEnd, barEnd - trailingCapsule - gap)
        let pillWidth = max(0, min(CGFloat(FixedChoices.topBarPillMaxWidth), pillEnd - pillStart))
        let centered = (lane.lowerBound + lane.upperBound) / 2 - pillWidth / 2
        let pillX = min(max(centered, pillStart), pillEnd - pillWidth)
        let height = Self.rowHeight
        return (
            CGRect(x: barStart, y: rowTop, width: leadingCapsule, height: height),
            CGRect(x: pillX, y: rowTop, width: pillWidth, height: height),
            CGRect(x: barEnd - trailingCapsule, y: rowTop, width: trailingCapsule, height: height)
        )
    }

    /// The strip's frame in `lane` (`DuoLayout.stripLane`), under the row (`placeStrip`): from
    /// the lane's leading margin, as wide as its tabs (`contentWidth`,
    /// `TabStripViewController.preferredWidth`), at most the lane's full width less its margins.
    /// From the leading edge rather than centered under the address: a tab keeps its place when
    /// another opens or closes, and only the bar's end (and New Tab on it) moves.
    func stripFrame(lane: ClosedRange<CGFloat>, contentWidth: CGFloat? = nil) -> CGRect {
        let full = max(0, lane.upperBound - lane.lowerBound - 2 * Self.edgeMargin)
        return CGRect(
            x: lane.lowerBound + Self.edgeMargin, y: stripTop,
            width: min(full, contentWidth ?? full), height: stripHeight
        )
    }

    /// The strip's top: under the row, and in the status zone under the status items too, so the
    /// strip always spans its lane, right under the clock and battery (owner, on the
    /// device: "The tabs should go all the way to under the status bar icons"). It never stops
    /// short beside the corner: a strip cut where the status items begin read as broken. On the
    /// device the corner is the row's height around the camera, so this is the row's bottom + 4.
    ///
    /// Under the status items it keeps `FixedChoices.tabStripStatusGap` from their bottom, more
    /// than the gap under the row: their backing reaches below the region the system reports,
    /// and the strip's edge must never sit under it. A corner that already runs down to the safe
    /// area's top (the guide's band, which holds the items and their backing) needs only the
    /// row's gap under it.
    var stripTop: CGFloat {
        guard let corner else { return rowBottom + Self.gap }
        let underItems = min(corner.maxY + CGFloat(FixedChoices.tabStripStatusGap), max(corner.maxY, safeTop) + Self.gap)
        return max(rowBottom + Self.gap, underItems)
    }

    /// The bottom of the expanded chrome: the row, or the strip under it.
    var expandedBottom: CGFloat {
        (stripHeight > 0 ? stripTop + stripHeight : rowBottom) + Self.gap
    }

    /// The collapsed pill's height.
    var collapsedPillHeight: CGFloat { Self.rowHeight * Self.compactScale }

    /// The collapsed pill's center: in place on the status row, or tucked under a full-width
    /// status bar.
    var collapsedCenter: CGFloat {
        isInStatusZone ? rowTop + Self.rowHeight / 2 : safeTop + collapsedPillHeight / 2
    }

    /// The collapsed pill's bottom.
    var collapsedBottom: CGFloat { collapsedCenter + collapsedPillHeight / 2 }

    /// The pill's vertical translation and scale at collapse `progress` (0 expanded, 1 collapsed,
    /// 2 hidden), for a transform about its center. Past 1 the pill rises off the top edge,
    /// `ChromeGeometry.hiddenClearance` past it, as the bottom pill sinks off the bottom.
    func pillTransform(progress: CGFloat) -> (translationY: CGFloat, scale: CGFloat) {
        let p = min(max(progress, 0), 1)
        let scale = 1 - (1 - Self.compactScale) * p
        let restCenter = rowTop + Self.rowHeight / 2
        let rise = (collapsedBottom + ChromeGeometry.hiddenClearance) * min(max(progress - 1, 0), 1)
        return ((collapsedCenter - restCenter) * p - rise, scale)
    }

    /// The buttons' rise at `progress`: half a row, while they fade (`ChromeGeometry.barAlpha`).
    func buttonsTranslation(progress: CGFloat) -> CGFloat {
        -Self.rowHeight / 2 * min(max(progress, 0), 1)
    }

    /// The strip's rise at `progress`: up under the row, while it fades. It spans under the status
    /// corner, so in the status zone it rises only as far as the corner's bottom: it never passes
    /// over the clock on its way out (it is faded by then anyway).
    func stripTranslation(progress: CGFloat) -> CGFloat {
        var rise = Self.rowHeight + Self.gap
        if let corner { rise = min(rise, max(0, stripTop - corner.maxY - Self.gap)) }
        return -rise * min(max(progress, 0), 1)
    }

    /// The page's obscured top inset (`obscuredContentInsets.top`), the same in every state of
    /// the bar: in the status zone nothing, under a full-width status bar that bar. The bar
    /// floats over the page and leaves it no inset of its own: a fixed or sticky header keeps to
    /// the top edge (or under the status bar) whatever the bar does, except at the page's top,
    /// where it rests under the expanded controls with the page and rides up with it (WebKit
    /// keeps the layout viewport inside the document while the page sits above its origin). WebKit, which
    /// fills an obscured inset above such a header with the header's color (its fixed color
    /// extension, `WKWebView.h`: it "adjusts how fixed and sticky elements are rendered near
    /// edges with non-zero obscured insets"), paints no band behind the controls, and nothing
    /// jumps when they go or come back, because nothing changes. The page's first line still
    /// starts under the controls: that is the scroll range's start (`expandedInset`,
    /// `setPageTopStart`, `UIScrollView.keepPageTopUnderBar`). Decision: docs/decisions.md,
    /// "The page's top inset never follows the bar".
    var obscuredInset: CGFloat {
        isInStatusZone ? 0 : safeTop
    }

    /// The expanded chrome's height over the page: where the page's first line rests (the scroll
    /// range's start) and the largest viewport inset (`maximumViewportInset`), never equal to
    /// the obscured one (WebKit wants the maximum viewport inset strictly larger). In the status
    /// zone never above the corner's bottom, so the page's first line at rest starts clear of the
    /// clock.
    var expandedInset: CGFloat { max(expandedBottom, corner?.maxY ?? 0, obscuredInset + 1) }

    /// The share of `screen` the chrome covers at rest (`collapsed` false) or while reading: the
    /// page's first line at rest, its obscured inset while reading, across the full width. For
    /// the design record and tests.
    func chromeShare(of screen: CGSize, collapsed: Bool) -> CGFloat {
        guard screen.width > 0, screen.height > 0 else { return 0 }
        return (collapsed ? obscuredInset : expandedInset) / screen.height
    }
}
