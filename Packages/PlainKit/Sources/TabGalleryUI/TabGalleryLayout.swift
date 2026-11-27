import BrowserCore
import CoreGraphics
import Foundation

/// The tab gallery's column rule for the wide grid (docs/plan.md, section 6). Columns are always
/// even, so on the Duo's inner screen the middle gap sits on the fold. The width comes from the
/// gallery's own bounds, never from the screen or the device model. The values live in
/// `FixedChoices`.
public enum TabGalleryLayout {
    /// Below this width the wide grid shows the narrow column count.
    public static let wideWidth = CGFloat(FixedChoices.tabGalleryWideWidth)

    public static func columnCount(forWidth width: CGFloat) -> Int {
        width < wideWidth ? FixedChoices.tabGalleryColumns.narrow : FixedChoices.tabGalleryColumns.wide
    }
}

/// Where a card sits in the app-switcher cascade, as a function of its position relative to the
/// focused card (`r = index - scroll position`, in cards). Distances are in card widths.
/// docs/research/arc-tab-switcher.md has the measurements these numbers come from.
///
/// Later tabs lie on top. Cards to the left bunch up and shrink a little: the first peeks about
/// 0.21 of a card, the second a sliver more. The card to the right sits 0.78 of a card over and
/// covers the focused card's right edge. One smooth curve joins the two sides (the slope matches at
/// r = 0), so a card never changes speed abruptly as it passes the middle: cards to the right move
/// faster than the finger, cards to the left slower, which is the parallax of the iOS app switcher.
enum CascadeCurve {
    /// How far the left stack reaches at most, in card widths.
    static let leftLimit: CGFloat = 0.294
    /// How fast the left stack bunches up: each step left shows about 29% of the step before.
    static let leftDecay: CGFloat = 1.252
    /// Where the next card to the right sits, in card widths.
    static let rightOffset: CGFloat = 0.78
    /// The first card to the left is this much smaller; deeper ones shrink a little more, to 0.93.
    static let firstStepShrink: CGFloat = 0.05

    /// The slope at r = 0, shared by both sides.
    static var slope: CGFloat { leftLimit * leftDecay }
    private static var rightBend: CGFloat { rightOffset - slope }

    /// The horizontal offset of the card's center from the focus point, in card widths.
    static func offset(_ r: CGFloat) -> CGFloat {
        if r >= 0 { return slope * r + rightBend * r * r }
        return -leftLimit * (1 - exp(leftDecay * r))
    }

    /// The card's scale: full size from the focus to the right, a little smaller to the left.
    static func scale(_ r: CGFloat) -> CGFloat {
        1 - firstStepShrink * depth(r) / depth(-1)
    }

    /// How deep in the stack, 0 (the focus or right of it) to 1 (far left).
    static func depth(_ r: CGFloat) -> CGFloat {
        r >= 0 ? 0 : 1 - exp(leftDecay * r)
    }

    /// The farthest a visible card sits to the left and right of the focus, in cards. Beyond these
    /// a card is hidden under its neighbors or off screen.
    static let visibleRange: ClosedRange<CGFloat> = -4.5...3
}

/// The gallery's geometry as plain values, free of UIKit so `swift test` checks it on macOS.
///
/// Compact width (phones, the Duo's outer screen): the app-switcher cascade, one row of
/// page-shaped cards that scrolls sideways. Regular width (the Duo's inner screen): pages of an
/// even-column grid that also scroll sideways, so swiping up closes a card everywhere. Every size
/// is absolute and comes from the gallery's bounds, so a scroll never measures anything.
struct TabGalleryMetrics: Equatable {
    enum Style: Equatable {
        case cascade
        case grid
    }

    /// The gallery's bounds.
    var width: CGFloat
    var height: CGFloat
    /// The safe area, which cards stay inside.
    var safeTop: CGFloat = 0
    var safeLeft: CGFloat = 0
    var safeBottom: CGFloat = 0
    var safeRight: CGFloat = 0
    /// Whether the horizontal size class is compact.
    var isCompactWidth: Bool
    /// The title font's line height at the current Dynamic Type size.
    var titleLineHeight: CGFloat
    /// Room the floating bar takes at the bottom, from the bottom edge of the safe area.
    var bottomChrome: CGFloat = 0
    /// Room a control over the cards takes at the top (the profile switcher), under the safe area.
    var topChrome: CGFloat = 0
    /// In the grid, this many slots (a lone card) sit in one row centered on the screen instead
    /// of filling the grid from its top left; 0 fills the grid as usual.
    var centeredRow = 0

    /// Space around the cards and between grid cards.
    static let margin: CGFloat = 16
    static let spacing: CGFloat = 16
    /// A cascade card is this much of the space it has: the Arc measurement (0.66 of the screen).
    static let cascadeWidthFraction: CGFloat = 0.66
    /// Grid cards take the page's shape, kept inside these bounds (height over width). Taller than
    /// 1.1 and a portrait grid fits only one row.
    static let gridAspect: ClosedRange<CGFloat> = 0.62...1.1
    /// The site icon over each card.
    static let faviconSize: CGFloat = 20
    /// The gap between the title row and its card.
    static let headerGap: CGFloat = 8
    /// The most grid rows a page shows.
    static let maxGridRows = 3

    var style: Style { isCompactWidth ? .cascade : .grid }

    /// The area cards may use: inside the safe area, above the floating bar.
    var contentMinX: CGFloat { safeLeft }
    var contentWidth: CGFloat { max(1, width - safeLeft - safeRight) }
    var contentMinY: CGFloat { safeTop + topChrome + Self.margin }
    var contentHeight: CGFloat { max(1, height - safeBottom - bottomChrome - Self.margin - contentMinY) }

    /// The row above a card with its icon and title.
    var headerHeight: CGFloat {
        (max(Self.faviconSize, titleLineHeight) + Self.headerGap).rounded(.up)
    }

    /// The page's own shape: the shell's page runs from under the status bar to the bottom edge,
    /// beside a vertical bar (the safe area's sides). Thumbnails are pictures of that area, so a
    /// card of this shape shows the whole picture with no strip of card under it.
    var pageAspect: CGFloat {
        guard width > 0 else { return 1 }
        return max(1, height - safeTop) / contentWidth
    }

    /// The page preview's height over its width. In the cascade a card is the whole page, the
    /// way the app switcher shows a whole app, so the zoom into it is one continuous scale.
    var thumbnailAspect: CGFloat {
        guard width > 0 else { return 1 }
        switch style {
        case .cascade: return pageAspect
        case .grid: return min(max(pageAspect, Self.gridAspect.lowerBound), Self.gridAspect.upperBound)
        }
    }

    // MARK: Cascade

    /// The card's width: two-thirds of the space, or less when the height is short.
    var cardWidth: CGFloat {
        switch style {
        case .cascade:
            let byWidth = contentWidth * Self.cascadeWidthFraction
            let byHeight = (contentHeight - headerHeight) / thumbnailAspect
            return max(1, min(byWidth, byHeight).rounded(.down))
        case .grid:
            return gridCardWidth(columns: columns)
        }
    }

    var thumbnailHeight: CGFloat {
        (cardWidth * thumbnailAspect).rounded()
    }

    /// A card with its title row.
    var cardSize: CGSize {
        CGSize(width: cardWidth, height: headerHeight + thumbnailHeight)
    }

    /// Scroll distance per card in the cascade: the distance the next card travels to reach the
    /// focus, so the focused card follows the finger on average.
    var cascadeStep: CGFloat {
        max(1, (CascadeCurve.rightOffset * cardWidth).rounded())
    }

    /// The focused card's preview center, on screen.
    var focusPoint: CGPoint {
        let blockHeight = headerHeight + thumbnailHeight
        let top = contentMinY + ((contentHeight - blockHeight) / 2).rounded()
        return CGPoint(x: (contentMinX + contentWidth / 2).rounded(), y: top + headerHeight + thumbnailHeight / 2)
    }

    // MARK: Grid

    /// Visible grid columns. Even, so the middle gap stays on the Duo's fold.
    var columns: Int {
        let wide = TabGalleryLayout.columnCount(forWidth: contentWidth)
        // Fewer, wider cards when the wide count would leave titles unreadable (the Duo's inner
        // screen in portrait). Still even.
        if wide > FixedChoices.tabGalleryColumns.narrow, gridCardWidth(columns: wide) < TabGalleryChoices.minGridCardWidth {
            return FixedChoices.tabGalleryColumns.narrow
        }
        return wide
    }

    private func gridCardWidth(columns: Int) -> CGFloat {
        let count = CGFloat(columns)
        let available = contentWidth - Self.margin * 2 - Self.spacing * (count - 1)
        return max(1, (available / count).rounded(.down))
    }

    /// Grid rows per page: as many whole cards as fit above the bar.
    var rows: Int {
        let row = headerHeight + thumbnailHeight
        let count = Int(((contentHeight + Self.spacing) / (row + Self.spacing)).rounded(.down))
        return min(max(1, count), Self.maxGridRows)
    }

    var cardsPerPage: Int { columns * rows }

    /// The inset that centers the columns in the safe area. With an even column count the middle
    /// gap sits on the center line, where the Duo folds.
    var sideInset: CGFloat {
        let count = CGFloat(columns)
        let used = cardWidth * count + Self.spacing * (count - 1)
        return ((contentWidth - used) / 2).rounded(.down)
    }

    /// Scroll distance per grid page.
    var pageWidth: CGFloat { contentWidth }

    /// The center of grid card `index`'s preview, in content coordinates (scroll offset 0).
    func gridPoint(_ index: Int) -> CGPoint {
        let rowHeight = headerHeight + thumbnailHeight
        if (1...columns).contains(centeredRow), index >= 0, index < centeredRow {
            let count = CGFloat(centeredRow)
            let used = cardWidth * count + Self.spacing * (count - 1)
            let left = contentMinX + ((contentWidth - used) / 2).rounded(.down)
            let top = contentMinY + ((contentHeight - rowHeight) / 2).rounded()
            return CGPoint(
                x: left + CGFloat(index) * (cardWidth + Self.spacing) + cardWidth / 2,
                y: top + headerHeight + thumbnailHeight / 2
            )
        }
        let perPage = cardsPerPage
        let page = index / perPage
        let within = index % perPage
        let row = within / columns
        let column = within % columns
        let block = CGFloat(rows) * rowHeight + CGFloat(rows - 1) * Self.spacing
        let top = contentMinY + ((contentHeight - block) / 2).rounded()
        let x = CGFloat(page) * pageWidth + contentMinX + sideInset + CGFloat(column) * (cardWidth + Self.spacing) + cardWidth / 2
        let y = top + CGFloat(row) * (rowHeight + Self.spacing) + headerHeight + thumbnailHeight / 2
        return CGPoint(x: x, y: y)
    }

    // MARK: Scrolling

    /// The scroll distance between two resting positions: one card, or one grid page.
    var snapUnit: CGFloat {
        style == .cascade ? cascadeStep : pageWidth
    }

    /// How many resting positions `count` tabs have.
    func stopCount(for count: Int) -> Int {
        guard count > 0 else { return 1 }
        switch style {
        case .cascade: return count
        case .grid: return (count + cardsPerPage - 1) / cardsPerPage
        }
    }

    /// The scroll view's content width for `count` tabs.
    func contentWidth(for count: Int) -> CGFloat {
        width + CGFloat(stopCount(for: count) - 1) * snapUnit
    }

    func maxOffset(for count: Int) -> CGFloat {
        CGFloat(stopCount(for: count) - 1) * snapUnit
    }

    /// The resting scroll offset that shows tab `index`: focused in the cascade, its page in the grid.
    func restingOffset(for index: Int) -> CGFloat {
        switch style {
        case .cascade: return CGFloat(index) * cascadeStep
        case .grid: return CGFloat(index / cardsPerPage) * pageWidth
        }
    }

    /// Where a card at fractional slot `slot` shows when the scroll offset is `offset`, on screen.
    /// Fractional slots are cards moving between places (closing a gap, a reorder).
    func placement(slot: CGFloat, offset: CGFloat) -> CardPlacement {
        switch style {
        case .cascade:
            let r = slot - offset / cascadeStep
            let focus = focusPoint
            let x = focus.x + CascadeCurve.offset(r) * cardWidth
            return CardPlacement(center: CGPoint(x: x, y: focus.y), scale: CascadeCurve.scale(r), depth: CascadeCurve.depth(r), r: r)
        case .grid:
            let lower = max(0, Int(slot.rounded(.down)))
            let fraction = slot - CGFloat(lower)
            var point = gridPoint(lower)
            if fraction > 0.0001 {
                let next = gridPoint(lower + 1)
                point.x += (next.x - point.x) * fraction
                point.y += (next.y - point.y) * fraction
            } else if slot < 0 {
                // Before the first slot: keep going left along the first row.
                point.x += slot * (cardWidth + Self.spacing)
            }
            point.x -= offset
            return CardPlacement(center: point, scale: 1, depth: 0, r: 0)
        }
    }

    /// The tab indices that may be on screen at scroll offset `offset`, before any card moves.
    func candidateRange(offset: CGFloat, count: Int) -> ClosedRange<Int>? {
        guard count > 0 else { return nil }
        switch style {
        case .cascade:
            let p = offset / cascadeStep
            let low = Int((p + CascadeCurve.visibleRange.lowerBound).rounded(.down))
            let high = Int((p + CascadeCurve.visibleRange.upperBound).rounded(.up))
            let lo = max(0, low), hi = min(count - 1, high)
            return lo <= hi ? lo...hi : nil
        case .grid:
            let firstPage = Int((offset / pageWidth).rounded(.down)) - 1
            let lastPage = Int(((offset + width) / pageWidth).rounded(.down))
            let lo = max(0, firstPage * cardsPerPage), hi = min(count - 1, (lastPage + 1) * cardsPerPage - 1)
            return lo <= hi ? lo...hi : nil
        }
    }

    /// Where a scroll released at `velocity` (points per millisecond, UIScrollView's unit) rests:
    /// the system's projected stop, rounded to the nearest card or page. A clear flick always
    /// moves at least one, so a short quick swipe is never swallowed.
    func snappedOffset(projected: CGFloat, current: CGFloat, velocity: CGFloat, count: Int) -> CGFloat {
        let unit = snapUnit
        let last = CGFloat(stopCount(for: count) - 1)
        var stop = (projected / unit).rounded()
        let start = (current / unit).rounded()
        if stop == start, abs(velocity) > ScrollSnap.minimumFlick {
            stop += velocity > 0 ? 1 : -1
        }
        if style == .grid {
            // Pages move one at a time, like the Home Screen: a page is a screenful to read.
            stop = min(max(stop, start - 1), start + 1)
        }
        return min(max(stop, 0), last) * unit
    }
}

/// Where a card shows on screen.
struct CardPlacement: Equatable {
    /// The center of the card's preview.
    var center: CGPoint
    var scale: CGFloat
    /// How deep in the cascade's left stack, 0...1.
    var depth: CGFloat
    /// Position relative to the focus, in cards (cascade only).
    var r: CGFloat
}

enum ScrollSnap {
    /// A release faster than this (points per millisecond) counts as a flick.
    static let minimumFlick: CGFloat = 0.3
}

/// Swipe a card up to close it (docs/plan.md, section 5, "Close tab"; WWDC18 "Designing Fluid
/// Interfaces").
///
/// The card follows the finger 1:1 upward and resists downward. On release, the throw is
/// projected with `UIScrollView.DecelerationRate.fast`. It closes when the projection passes 40%
/// of the card's height, or when the flick is faster than 800 pt/s upward. Otherwise it springs
/// back.
enum CardSwipe {
    static let closeFraction: CGFloat = 0.4
    /// A flick up this fast closes from any height: the app switcher takes a light flick, and
    /// at 800 pt/s a quick thumb flick often fell short (owner feedback, "hard to drag a tab").
    static let closeVelocity: CGFloat = 500
    /// `UIScrollView.DecelerationRate.fast`: a slow release does not carry a card far.
    static let decelerationRate: CGFloat = 0.99
    /// A release moving down faster than this keeps the card, wherever it is.
    static let keepVelocity: CGFloat = 300
    /// UIScrollView's rubber-band constant.
    static let rubberBand: CGFloat = 0.55
    /// A drag up this close to vertical lifts the card (tan 30°: within 60° of straight up);
    /// flatter, the gallery scrolls. Thumbs swipe up in an arc, so an even split (45°) sent many
    /// lifts to the scroll. Down stays at 45°: it only rubber-bands.
    static let liftSlope: CGFloat = 0.577
    /// The finger's travel before its direction decides between lifting the card and scrolling
    /// (`LiftGestureRecognizer`): a few points, under the scroll view's own ~10 pt, so a lift
    /// starts first and the card moves from the first frames of the drag.
    static let lockDistance: CGFloat = 6
    /// The card pays the locking travel back over this much more finger travel, so it neither
    /// jumps on the first frame nor stays behind the finger.
    static let takeUp: CGFloat = 12

    /// Whether a move in `direction` (a velocity or a travel) lifts a card rather than scrolling
    /// the gallery.
    static func isLift(velocity direction: CGPoint) -> Bool {
        if direction.y < 0 { return -direction.y > abs(direction.x) * liftSlope }
        return direction.y > abs(direction.x)
    }

    /// Where a throw released at `velocity` (pt/s) would come to rest, relative to the release.
    static func projectedDistance(velocity: CGFloat) -> CGFloat {
        (velocity / 1000) * decelerationRate / (1 - decelerationRate)
    }

    /// `translation` and `velocity` are vertical, negative upward.
    static func shouldClose(translation: CGFloat, velocity: CGFloat, cardHeight: CGFloat) -> Bool {
        if velocity < -closeVelocity { return true }
        if velocity > keepVelocity { return false }
        return translation + projectedDistance(velocity: velocity) < -cardHeight * closeFraction
    }

    /// The card's offset for a finger `translation` points down: 1:1 upward, resisting downward.
    static func offset(translation: CGFloat, cardHeight: CGFloat) -> CGFloat {
        guard translation > 0, cardHeight > 0 else { return translation }
        return (1 - 1 / (translation * rubberBand / cardHeight + 1)) * cardHeight
    }
}

/// The swipe up from the address bar into the gallery, modeled on the home-indicator swipe into
/// the app switcher (docs/research/arc-tab-switcher.md). The page shrinks with the distance the
/// finger travels and reaches its card's size a little under halfway up; past that it resists.
/// On release the movement is projected like a scroll view's; the thresholds are the shell's
/// (`FixedChoices.gallerySwipeCommit`, `galleryFlickSpeed`).
enum SwitcherSwipe {
    /// The page is card-sized after the finger travels this share of the page's height.
    static let travel: CGFloat = 0.4
    /// How far past the card's size a long drag can shrink the page.
    static let overshoot: CGFloat = 0.15
    /// `UIScrollView.DecelerationRate.fast`: a slow release does not carry far.
    static let decelerationRate: CGFloat = 0.99
    static var commit: CGFloat { CGFloat(FixedChoices.gallerySwipeCommit) }
    /// A swipe up on the gallery's empty space this long goes back to the page, like a swipe up
    /// in the app switcher goes home.
    static let backTravel: CGFloat = 40
    static var flickSpeed: CGFloat { CGFloat(FixedChoices.galleryFlickSpeed) }

    /// 0 (the page) to 1 (the card) for a finger `translationY` points down (negative is up).
    static func progress(translationY: CGFloat, pageHeight: CGFloat) -> CGFloat {
        let raw = -translationY / max(1, pageHeight * travel)
        if raw <= 0 { return max(-0.05, raw * 0.1) }
        if raw <= 1 { return raw }
        // UIScrollView's rubber band past the card's size.
        let excess = raw - 1
        return 1 + (1 - 1 / (excess * CardSwipe.rubberBand / overshoot + 1)) * overshoot
    }

    /// Whether a release at `progress` moving at `velocityY` (pt/s, negative up) lands in the
    /// gallery: any clear flick up does, a release moving down never does, else the projection
    /// must pass `commit`.
    static func opensGallery(progress: CGFloat, velocityY: CGFloat, pageHeight: CGFloat) -> Bool {
        if velocityY < -flickSpeed { return true }
        if velocityY > flickSpeed / 2 { return false }
        let projected = -(velocityY / 1000) * decelerationRate / (1 - decelerationRate)
        return progress + projected / max(1, pageHeight * travel) > commit
    }
}

/// When a card's title shows. Covered cards in the cascade show only their icon, as in Arc: a
/// title needs most of the card's width to say anything.
enum CardTitle {
    /// Below this visible fraction of the card, the title is hidden; above `shown`, fully visible.
    static let hidden: CGFloat = 0.55
    static let shown: CGFloat = 0.7

    static func alpha(visibleFraction: CGFloat) -> CGFloat {
        ((visibleFraction - hidden) / (shown - hidden)).clamped(to: 0...1)
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

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
