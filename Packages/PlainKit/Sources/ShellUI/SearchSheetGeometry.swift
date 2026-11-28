import BrowserCore
import CoreGraphics
import Foundation

// The search sheet's open and close as plain values, free of UIKit so `swift test` checks them on
// macOS. Measured from Arc Search on the Duo's outer screen, frame by frame
// (docs/research/arc-address-expand.md); the numbers that are Plain's own say so.

/// Where the open search sheet sits and how its parts follow one progress value (0 closed: the
/// resting pill; 1 open).
enum SearchSheetGeometry {
    /// The open sheet's top edge as a share of the screen's height (`FixedChoices`).
    static var topShare: CGFloat { CGFloat(FixedChoices.searchSheetTopShare) }
    /// Under this height the sheet starts right under the safe area (`FixedChoices`).
    static var shortScreen: CGFloat { CGFloat(FixedChoices.searchSheetShortScreen) }
    /// The sheet's top never comes closer to the safe area's top than this.
    static let topMargin: CGFloat = 8
    /// The field's distance under the sheet's top edge (Arc Search: 16 pt); the handle sits in it.
    static let fieldInset: CGFloat = 16
    /// The bar's buttons ride up with the sheet and are gone by this progress (Arc Search: its
    /// bar icons are gone about 100 ms into a 280 ms move).
    static let barFadeEnd: CGFloat = 0.35
    /// A release less open than this collapses the sheet (`FixedChoices`).
    static var collapseProgress: CGFloat { CGFloat(FixedChoices.searchSheetCollapseProgress) }
    /// A flick this fast decides the release (`FixedChoices`).
    static var flickVelocity: CGFloat { CGFloat(FixedChoices.searchSheetFlickVelocity) }

    /// The open sheet's top edge, from the root view's top.
    static func sheetTop(height: CGFloat, safeTop: CGFloat) -> CGFloat {
        let least = safeTop + topMargin
        guard height >= shortScreen else { return least }
        return max(least, (height * topShare).rounded())
    }

    /// The bar's opacity at `progress`.
    static func barAlpha(progress: CGFloat) -> CGFloat {
        1 - min(max(progress / barFadeEnd, 0), 1)
    }

    /// The progress under a finger that has moved `translation` points down from where it took
    /// the sheet at `start`, over a `travel`-point move. It never passes fully open: a pull up on
    /// the open sheet has nowhere to go.
    static func progress(start: CGFloat, translation: CGFloat, travel: CGFloat) -> CGFloat {
        guard travel > 0 else { return start }
        return min(max(start - translation / travel, 0), 1)
    }

    /// Whether a drag released at `progress` with `velocity` (points per second, down positive)
    /// collapses the sheet.
    static func collapses(progress: CGFloat, velocity: CGFloat) -> Bool {
        if velocity >= flickVelocity { return true }
        if velocity <= -flickVelocity { return false }
        return progress < collapseProgress
    }

    /// The transform that shows a view laid out at `open` as if it were at `rest` when `progress`
    /// is 0, and leaves it alone at 1: a move of its center and a scale about it.
    static func transform(open: CGRect, rest: CGRect, progress: CGFloat) -> CGAffineTransform {
        guard open.width > 0, open.height > 0 else { return .identity }
        let closed = 1 - min(max(progress, 0), 1)
        let scaleX = 1 + (rest.width / open.width - 1) * closed
        let scaleY = 1 + (rest.height / open.height - 1) * closed
        return CGAffineTransform(translationX: (rest.midX - open.midX) * closed, y: (rest.midY - open.midY) * closed)
            .scaledBy(x: scaleX, y: scaleY)
    }
}
