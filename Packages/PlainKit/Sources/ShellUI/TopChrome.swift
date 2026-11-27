import BrowserCore
import CoreGraphics
import Foundation

// The top bar on a wide screen (the Duo's inner screen, iPad-size windows), as plain values free of
// UIKit so `swift test` checks them on macOS. Safari puts its bar there on the Duo's inner screen:
// one row under the status bar, the page under it at full width (docs/research/safari-duo.md).
//
// The bar floats over the page like the bottom pill does on a phone: it moves by transform and
// alpha only, and the page's top `obscuredContentInsets` follows its resting state, changed once
// when a snap ends (`PageInsetState`), never per frame.

/// Where the top bar and the strip under it sit, expanded and collapsed, in the root view's
/// coordinates.
struct TopChromeGeometry: Equatable {
    /// The pages' top: under the status bar.
    var pageTop: CGFloat
    /// The strip's height under the bar, 0 when it does not show.
    var stripHeight: CGFloat

    /// The bar's row: one 44 pt control high.
    static var rowHeight: CGFloat { CGFloat(FixedChoices.topBarHeight) }
    /// Between the status bar and the row.
    static let topGap: CGFloat = 2
    /// Between the row and the strip, and under the lowest of them.
    static let gap: CGFloat = 4
    /// The collapsed pill's size relative to the expanded one.
    static var compactScale: CGFloat { CGFloat(FixedChoices.topBarCollapsedScale) }

    /// The row's top (the pill's and the buttons').
    var rowTop: CGFloat { pageTop + Self.topGap }

    /// The strip's top, under the row.
    var stripTop: CGFloat { rowTop + Self.rowHeight + Self.gap }

    /// The bottom of the expanded chrome: the row, or the strip under it.
    var expandedBottom: CGFloat {
        (stripHeight > 0 ? stripTop + stripHeight : rowTop + Self.rowHeight) + Self.gap
    }

    /// The collapsed pill's height.
    var collapsedPillHeight: CGFloat { Self.rowHeight * Self.compactScale }

    /// The collapsed pill tucks under the status bar: only the address is left.
    var collapsedBottom: CGFloat { pageTop + collapsedPillHeight }

    /// The pill's vertical translation and scale at collapse `progress` (0 expanded, 1 collapsed,
    /// 2 hidden), for a transform about its center. Past 1 the tucked pill rises off the top edge,
    /// `ChromeGeometry.hiddenClearance` past it, as the bottom pill sinks off the bottom.
    func pillTransform(progress: CGFloat) -> (translationY: CGFloat, scale: CGFloat) {
        let p = min(max(progress, 0), 1)
        let scale = 1 - (1 - Self.compactScale) * p
        let restCenter = rowTop + Self.rowHeight / 2
        let collapsedCenter = pageTop + collapsedPillHeight / 2
        let rise = (collapsedBottom + ChromeGeometry.hiddenClearance) * min(max(progress - 1, 0), 1)
        return ((collapsedCenter - restCenter) * p - rise, scale)
    }

    /// The buttons' rise at `progress`: half a row, while they fade (`ChromeGeometry.barAlpha`).
    func buttonsTranslation(progress: CGFloat) -> CGFloat {
        -Self.rowHeight / 2 * min(max(progress, 0), 1)
    }

    /// The strip's rise at `progress`: up under the row, while it fades.
    func stripTranslation(progress: CGFloat) -> CGFloat {
        -(Self.rowHeight + Self.gap) * min(max(progress, 0), 1)
    }

    /// The collapsed chrome's height over the page: the smallest top inset the page sees.
    var collapsedInset: CGFloat { collapsedBottom + Self.gap - pageTop }

    /// The expanded chrome's height over the page: the largest top inset the page sees, never equal
    /// to the collapsed one (WebKit wants the maximum viewport inset strictly larger).
    var expandedInset: CGFloat { max(expandedBottom - pageTop, collapsedInset + 1) }

    /// The hidden bar's height over the page: nothing, the page starts under the status bar. The
    /// smallest top inset the page sees.
    var hiddenInset: CGFloat { 0 }

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
    /// status bar (the root view's top `pageTop` points) and the bar, both across the full width. For the design record and tests (target: 12% at rest).
    func chromeShare(of screen: CGSize, collapsed: Bool) -> CGFloat {
        guard screen.width > 0, screen.height > 0 else { return 0 }
        let height = pageTop + obscuredInset(collapsed: collapsed)
        return height / screen.height
    }
}
