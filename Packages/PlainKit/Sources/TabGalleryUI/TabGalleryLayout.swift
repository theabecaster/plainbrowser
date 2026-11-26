import BrowserCore
import CoreGraphics
import Foundation

/// The tab gallery's grid rule (docs/plan.md, section 6). Columns are always even, so on the Duo's
/// inner screen no card straddles the fold. The width comes from the gallery's own bounds, never
/// from the screen or the device model. The values live in `FixedChoices`.
public enum TabGalleryLayout {
    /// Below this width the gallery is a phone-sized card list.
    public static let wideWidth = CGFloat(FixedChoices.tabGalleryWideWidth)

    public static func columnCount(forWidth width: CGFloat) -> Int {
        width < wideWidth ? FixedChoices.tabGalleryColumns.narrow : FixedChoices.tabGalleryColumns.wide
    }
}

/// The gallery's geometry as plain values, free of UIKit so `swift test` checks it on macOS.
///
/// Compact width (phones, the Duo's outer screen): one column of large cards, Arc style, each
/// showing the top of its page. Regular width (the Duo's inner screen): an even-column grid whose
/// cards take the page's own shape. Every size is absolute, so scrolling never measures a cell.
struct TabGalleryMetrics: Equatable {
    /// The gallery's bounds.
    var width: CGFloat
    var height: CGFloat
    /// Whether the horizontal size class is compact.
    var isCompactWidth: Bool
    /// The title font's line height at the current Dynamic Type size.
    var titleLineHeight: CGFloat

    /// Space around the cards and between them.
    static let margin: CGFloat = 16
    static let spacing: CGFloat = 16
    /// The single-column card shows this much of its page: height over width.
    static let listAspect: CGFloat = 0.72
    /// Grid cards take the page's shape, kept inside these bounds (height over width). Taller
    /// than 1.1 and a portrait grid shows barely more than one row.
    static let gridAspect: ClosedRange<CGFloat> = 0.62...1.1
    /// The title row is a 44 pt tap target at least (docs/ui-reference.md), and grows with the font.
    static let minTitleRow: CGFloat = 44
    static let titleRowPadding: CGFloat = 12

    var columns: Int {
        if isCompactWidth { return 1 }
        let wide = TabGalleryLayout.columnCount(forWidth: width)
        // Fewer, wider cards when the wide count would leave titles unreadable (the Duo's inner
        // screen in portrait). Still even, so the middle gap stays on the fold.
        if wide > FixedChoices.tabGalleryColumns.narrow, cardWidth(columns: wide) < TabGalleryChoices.minGridCardWidth {
            return FixedChoices.tabGalleryColumns.narrow
        }
        return wide
    }

    /// The card's full width.
    var cardWidth: CGFloat {
        cardWidth(columns: columns)
    }

    private func cardWidth(columns: Int) -> CGFloat {
        let count = CGFloat(columns)
        let available = width - Self.margin * 2 - Self.spacing * (count - 1)
        return max(1, (available / count).rounded(.down))
    }

    /// The page preview's height over its width.
    var thumbnailAspect: CGFloat {
        if isCompactWidth { return Self.listAspect }
        guard width > 0 else { return 1 }
        let pageAspect = height / width
        return min(max(pageAspect, Self.gridAspect.lowerBound), Self.gridAspect.upperBound)
    }

    var thumbnailHeight: CGFloat {
        (cardWidth * thumbnailAspect).rounded()
    }

    var titleRowHeight: CGFloat {
        max(Self.minTitleRow, (titleLineHeight + Self.titleRowPadding).rounded(.up))
    }

    var cardSize: CGSize {
        CGSize(width: cardWidth, height: thumbnailHeight + titleRowHeight)
    }

    /// The leading and trailing inset that centers the columns. With an even column count and
    /// symmetric insets, the middle gap sits on the window's center line, where the Duo folds.
    var sideInset: CGFloat {
        let count = CGFloat(columns)
        let used = cardWidth * count + Self.spacing * (count - 1)
        return ((width - used) / 2).rounded(.down)
    }
}

/// When a flicked card closes its tab (docs/plan.md, section 5, "Close tab").
///
/// The card follows the finger 1:1. On release, the throw is projected with the scroll view's
/// normal deceleration. It closes when the projection passes 40% of the card's width, or when the
/// flick is faster than 800 pt/s in the direction it moved. Otherwise it springs back.
enum CardFlick {
    static let closeFraction: CGFloat = 0.4
    static let closeVelocity: CGFloat = 800
    /// `UIScrollView.DecelerationRate.normal`.
    static let decelerationRate: CGFloat = 0.998

    /// Where a throw released at `velocity` (pt/s) would come to rest, relative to the release.
    static func projectedDistance(velocity: CGFloat) -> CGFloat {
        (velocity / 1000) * decelerationRate / (1 - decelerationRate)
    }

    static func shouldClose(translation: CGFloat, velocity: CGFloat, cardWidth: CGFloat) -> Bool {
        let projected = translation + projectedDistance(velocity: velocity)
        if abs(velocity) > closeVelocity, velocity.sign == translation.sign || translation == 0 {
            return true
        }
        return abs(projected) > cardWidth * closeFraction && projected.sign == translation.sign
    }

    /// The card's opacity while it is dragged `translation` points: it fades as it leaves.
    static func alpha(translation: CGFloat, cardWidth: CGFloat) -> CGFloat {
        guard cardWidth > 0 else { return 1 }
        return max(0.35, 1 - abs(translation) / cardWidth * 0.65)
    }
}

/// Values the gallery decides on its own (AGENTS.md: decided values carry a reason). They belong
/// in `FixedChoices` once the gallery is wired into the shell (docs/polish-backlog.md).
enum TabGalleryChoices {
    /// The "Reopen" toast stays this long after a close: long enough to read and reach, short
    /// enough that it is gone before the next close.
    static let reopenToastDuration: TimeInterval = 4
    /// Decoded previews kept in memory. 100 phone-size previews at 3x are about 60 MB; the cache
    /// evicts under pressure, and the rest decode again in about a frame each.
    static let thumbnailCacheCost = 64 * 1024 * 1024
    /// A grid card is never narrower than this: below it a title shows only a word or two. The Duo's
    /// inner screen gets four columns in landscape (217 pt cards) and two in portrait.
    static let minGridCardWidth: CGFloat = 180
}
