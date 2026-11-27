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
// `obscuredContentInsets` follows its resting state, changed once per rest (`PageInsetState`),
// never per frame. Decision: docs/decisions.md, "Duo inner screen: the bar in the status row".

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

    /// The corner around a camera the status items wrap, where the guide reports none: an
    /// occlusion region (`reservedRegions(kind: .occlusion, options: .includeInactive)`) inside the
    /// top safe area, in the outer quarter of the width at either side. The Duo's inner screen
    /// reports its camera so (37 pt at x 885–922, y 29–66 in landscape), its safe area's top
    /// (81 pt) clears it, and the clock and battery ring sit around it. The corner reaches
    /// `FixedChoices.statusItemsReach` past the camera toward the middle (the clock) and is
    /// centered on the camera's row, at least a row high. Nil for anything else: a full-width
    /// band (the outer screen's Dynamic Island) or a region below the safe area's top.
    static func rect(aroundOcclusions regions: [CGRect], width: CGFloat, safeTop: CGFloat) -> CGRect? {
        let reach = CGFloat(FixedChoices.statusItemsReach)
        for region in regions where region.height > 0 && region.minY < safeTop && region.maxY <= safeTop + 0.5 {
            let half = max(region.height, TopChromeGeometry.rowHeight) / 2
            let top = max(0, region.midY - half)
            let height = region.midY + half - top
            if region.minX >= width * 0.75 {
                return CGRect(x: region.minX - reach, y: top, width: width - region.minX + reach, height: height)
            }
            if region.maxX <= width * 0.25 {
                return CGRect(x: 0, y: top, width: region.maxX + reach, height: height)
            }
        }
        return nil
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
    /// Between the row's end and the status items' corner: the glass never touches the clock.
    static let cornerGap: CGFloat = 12
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

    /// The strip's top, under the row.
    var stripTop: CGFloat { rowBottom + Self.gap }

    /// How far the strip keeps from each edge: the row's clearance where the strip starts beside
    /// the status corner (a corner reaching below the row), else nothing.
    var stripClearance: (leading: CGFloat, trailing: CGFloat) {
        guard let corner, stripTop < corner.maxY else { return (0, 0) }
        return rowClearance
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

    /// The strip's rise at `progress`: up under the row, while it fades. A strip spanning under the
    /// status corner rises only as far as the corner's bottom, so it never passes over the clock
    /// on its way out (it is faded by then anyway).
    func stripTranslation(progress: CGFloat) -> CGFloat {
        var rise = Self.rowHeight + Self.gap
        if let corner, stripClearance.leading == 0, stripClearance.trailing == 0 {
            rise = min(rise, max(0, stripTop - corner.maxY))
        }
        return -rise * min(max(progress, 0), 1)
    }

    /// The hidden bar's height over the page: the smallest top inset the page sees. In the status
    /// zone the status row's bottom, or the corner's if it reaches lower, so the page gets
    /// everything under the clock's row and a fixed header never sits under it; under a
    /// full-width status bar, that bar.
    var hiddenInset: CGFloat {
        guard let corner else { return safeTop }
        return max(rowBottom, corner.maxY)
    }

    /// The collapsed chrome's height over the page. In the status zone the shrunken address stays
    /// on the status row, so the page sees the same as hidden.
    var collapsedInset: CGFloat {
        isInStatusZone ? hiddenInset : collapsedBottom + Self.gap
    }

    /// The expanded chrome's height over the page: the largest top inset the page sees, never equal
    /// to the collapsed one (WebKit wants the maximum viewport inset strictly larger).
    var expandedInset: CGFloat { max(expandedBottom, collapsedInset + 1) }

    /// The page's obscured top inset for the bar resting collapsed or expanded.
    func obscuredInset(collapsed: Bool) -> CGFloat {
        collapsed ? collapsedInset : expandedInset
    }

    /// The page's obscured top inset for the bar resting at `rest`.
    func obscuredInset(rest: ChromeRest) -> CGFloat {
        switch rest {
        case .expanded: expandedInset
        case .pill: collapsedInset
        case .hidden: hiddenInset
        }
    }

    /// The share of `screen` the chrome covers at rest (`collapsed` false) or while reading: the
    /// page's top inset across the full width. For the design record and tests.
    func chromeShare(of screen: CGSize, collapsed: Bool) -> CGFloat {
        guard screen.width > 0, screen.height > 0 else { return 0 }
        return obscuredInset(collapsed: collapsed) / screen.height
    }
}
