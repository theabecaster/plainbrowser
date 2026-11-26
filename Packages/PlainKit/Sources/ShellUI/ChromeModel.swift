import CoreGraphics
import Foundation

// The shell's chrome rules as plain values, free of UIKit so `swift test` checks them on macOS.
// The view controller feeds them view geometry and scroll offsets and applies what they return.

/// Where the bottom chrome sits, expanded and collapsed, in the root view's coordinates.
///
/// The page never relayouts for the toolbar (docs/plan.md, engine rule 4): the web view's
/// `obscuredContentInsets` is the collapsed chrome, set once, and the expanded chrome overlaps the
/// page while it shows. `setMinimumViewportInset` gets the collapsed and expanded sizes, so CSS
/// `svh`/`lvh` stay stable while the bar moves.
struct ChromeGeometry: Equatable {
    /// The root view's height.
    var viewHeight: CGFloat
    /// The root view's bottom safe-area inset (home indicator), without the keyboard.
    var safeBottom: CGFloat
    /// Whether the bottom button bar shows under the pill (iPhones without a vertical bar).
    var hasButtonBar: Bool

    static let pillHeight: CGFloat = 48
    static let barHeight: CGFloat = 48
    /// Between the pill and the button bar.
    static let gap: CGFloat = 6
    /// Above the bottom edge when there is no home indicator (iPhone SE).
    static let edgeMargin: CGFloat = 8
    /// The collapsed pill's size relative to the expanded one.
    static let compactScale: CGFloat = 0.75
    /// How far above the bottom edge the collapsed pill ends on a phone with a home indicator.
    /// It sits clear above the indicator, which is about 13 pt from the edge.
    static let collapsedLiftOverIndicator: CGFloat = 18

    /// The bottom of the resting chrome: the button bar's bottom, or the pill's.
    var restBottom: CGFloat {
        viewHeight - max(safeBottom, Self.edgeMargin)
    }

    /// The bottom of the expanded, resting pill.
    var pillRestBottom: CGFloat {
        hasButtonBar ? restBottom - Self.barHeight - Self.gap : restBottom
    }

    /// The top of the expanded chrome (the pill's top).
    var expandedTop: CGFloat { pillRestBottom - Self.pillHeight }

    /// The bottom of the collapsed pill: low in the home-indicator zone, like Safari's compact bar.
    var collapsedBottom: CGFloat {
        safeBottom > 0 ? viewHeight - Self.collapsedLiftOverIndicator : restBottom
    }

    /// The top of the collapsed pill.
    var collapsedTop: CGFloat { collapsedBottom - Self.pillHeight * Self.compactScale }

    /// The pill's vertical translation and scale at collapse `progress` (0 expanded, 1 collapsed),
    /// for a transform about its center.
    func pillTransform(progress: CGFloat) -> (translationY: CGFloat, scale: CGFloat) {
        let p = min(max(progress, 0), 1)
        let scale = 1 - (1 - Self.compactScale) * p
        let bottom = pillRestBottom + (collapsedBottom - pillRestBottom) * p
        let restCenter = pillRestBottom - Self.pillHeight / 2
        return (bottom - Self.pillHeight * scale / 2 - restCenter, scale)
    }

    /// The button bar's drop at `progress`: it leaves past the bottom edge.
    func barTranslation(progress: CGFloat) -> CGFloat {
        let p = min(max(progress, 0), 1)
        return (viewHeight - restBottom + Self.barHeight) * p
    }

    /// The bar's opacity at `progress`: gone by 60% of the way, so it never covers the pill.
    static func barAlpha(progress: CGFloat) -> CGFloat {
        max(0, 1 - progress / 0.6)
    }

    /// The page's obscured bottom inset, measured up from `pageBottom` (the web view's bottom in
    /// the same coordinates): the collapsed chrome.
    func obscuredBottom(pageBottom: CGFloat) -> CGFloat {
        max(0, pageBottom - collapsedTop)
    }

    /// The largest bottom inset the page sees: the expanded chrome.
    func expandedBottom(pageBottom: CGFloat) -> CGFloat {
        max(0, pageBottom - expandedTop)
    }
}

/// Tracks how collapsed the toolbar is from the page's scroll, 1:1 with the finger.
struct ChromeCollapse: Equatable {
    /// 0 is expanded, 1 is collapsed.
    private(set) var progress: CGFloat = 0
    /// Scroll distance that takes the bar from expanded to collapsed.
    let distance: CGFloat
    private var lastOffset: CGFloat?

    init(distance: CGFloat = 56) {
        self.distance = distance
    }

    /// Feeds a new content offset. `top` is the offset at the page's top, `bottom` the largest
    /// offset. Returns true when `progress` changed.
    @discardableResult
    mutating func scrolled(to offset: CGFloat, top: CGFloat, bottom: CGFloat) -> Bool {
        defer { lastOffset = offset }
        let before = progress
        if offset <= top {
            // At the top (or pulling past it) the bar is always out.
            progress = 0
        } else if let lastOffset, offset < bottom {
            // The bottom's rubber band must not pull the bar back in.
            progress = min(max(progress + (offset - lastOffset) / distance, 0), 1)
        }
        return progress != before
    }

    /// Forgets the last offset, so the next scroll starts fresh (a new page, a finished snap).
    mutating func resetTracking() {
        lastOffset = nil
    }

    /// Sets the progress outright (a snap, or expanding for a new page).
    mutating func settle(at value: CGFloat) {
        progress = min(max(value, 0), 1)
        lastOffset = nil
    }

    /// Where the bar should settle when the scroll stops: the nearer end, unless the release had
    /// clear velocity (points per millisecond, positive scrolling down the page).
    func settleTarget(velocity: CGFloat = 0) -> CGFloat {
        if velocity > 0.2 { return 1 }
        if velocity < -0.2 { return 0 }
        return progress >= 0.5 ? 1 : 0
    }

    /// True while the bar is between its two resting states.
    var isMidway: Bool { progress > 0 && progress < 1 }
}

/// Pull to refresh's threshold logic (docs/plan.md, motion table: arms at 80 pt, selection haptic
/// at arm).
struct PullToRefreshTracker: Equatable {
    enum Change: Equatable {
        case armed
        case disarmed
    }

    static let threshold: CGFloat = 80
    private(set) var isArmed = false

    /// Feeds how far past the top the page is pulled. Returns the arm state's change, if any.
    mutating func pulled(_ distance: CGFloat) -> Change? {
        if !isArmed, distance >= Self.threshold {
            isArmed = true
            return .armed
        }
        if isArmed, distance < Self.threshold {
            isArmed = false
            return .disarmed
        }
        return nil
    }

    /// The finger lifted. Returns true when the page should reload.
    mutating func released() -> Bool {
        defer { isArmed = false }
        return isArmed
    }
}
