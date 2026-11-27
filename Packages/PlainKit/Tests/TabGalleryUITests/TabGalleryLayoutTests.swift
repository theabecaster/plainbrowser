import CoreGraphics
import Foundation
import Testing
@testable import TabGalleryUI

@MainActor
struct CascadeCurveTests {
    @Test func matchesTheArcMeasurements() {
        // The next card sits 0.78 of a card to the right; the first card to the left peeks about
        // 0.21, the second about 0.06 more.
        #expect(abs(CascadeCurve.offset(1) - 0.78) < 0.001)
        #expect(abs(CascadeCurve.offset(-1) + 0.21) < 0.005)
        #expect(abs(CascadeCurve.offset(-2) - CascadeCurve.offset(-1) + 0.06) < 0.005)
        #expect(abs(CascadeCurve.scale(-1) - 0.95) < 0.001)
        #expect(CascadeCurve.scale(0.5) == 1)
    }

    @Test func isSmoothThroughTheFocus() {
        // The same slope on both sides of r = 0, so a card never jerks as it passes the middle.
        let h: CGFloat = 0.0001
        let left = (CascadeCurve.offset(0) - CascadeCurve.offset(-h)) / h
        let right = (CascadeCurve.offset(h) - CascadeCurve.offset(0)) / h
        #expect(abs(left - right) < 0.001)
    }

    @Test func cardsKeepTheirOrderAndTheLeftStackBunchesUp() {
        var previous = CascadeCurve.offset(-6)
        var previousGap: CGFloat = 0
        for step in -59...30 {
            let r = CGFloat(step) / 10
            let x = CascadeCurve.offset(r)
            #expect(x > previous)
            // Gaps only grow to the right: the right side moves faster than the left.
            let gap = x - previous
            #expect(gap >= previousGap - 0.0001)
            previous = x
            previousGap = gap
        }
        #expect(CascadeCurve.offset(-20) > -CascadeCurve.leftLimit - 0.0001)
    }
}

@MainActor
struct TabGalleryMetricsTests {
    // iPhone 17 portrait, compact width.
    let phone = TabGalleryMetrics(
        width: 402, height: 874, safeTop: 62, safeBottom: 34, isCompactWidth: true, titleLineHeight: 20, bottomChrome: 68
    )
    // Duo outer screen, with the system's side bar.
    let outer = TabGalleryMetrics(
        width: 466, height: 678, safeTop: 24, safeLeft: 84, safeBottom: 20, isCompactWidth: true, titleLineHeight: 20,
        bottomChrome: 68
    )
    // Duo inner screen, landscape and portrait.
    let innerLandscape = TabGalleryMetrics(
        width: 951, height: 669, safeTop: 24, safeBottom: 20, isCompactWidth: false, titleLineHeight: 18, bottomChrome: 68
    )
    let innerPortrait = TabGalleryMetrics(
        width: 669, height: 951, safeTop: 24, safeBottom: 20, isCompactWidth: false, titleLineHeight: 18, bottomChrome: 68
    )

    @Test func compactWidthIsTheCascadeOfPageShapedCards() {
        for metrics in [phone, outer] {
            #expect(metrics.style == .cascade)
            #expect(metrics.cardWidth <= (metrics.contentWidth * TabGalleryMetrics.cascadeWidthFraction).rounded(.down))
            // The card is the page's shape (under the status bar, beside a vertical bar), so
            // opening it is one continuous zoom and the page's picture fills it.
            let page = (metrics.height - metrics.safeTop) / (metrics.width - metrics.safeLeft - metrics.safeRight)
            #expect(abs(metrics.thumbnailHeight / metrics.cardWidth - page) < 0.01)
            // It fits between the status bar and the floating bar.
            #expect(metrics.cardSize.height <= metrics.contentHeight)
            let focus = metrics.focusPoint
            #expect(focus.y - metrics.thumbnailHeight / 2 - metrics.headerHeight >= metrics.contentMinY)
            #expect(focus.y + metrics.thumbnailHeight / 2 <= metrics.contentMinY + metrics.contentHeight)
        }
        // A phone gets the measured two-thirds width.
        #expect(phone.cardWidth == (phone.contentWidth * 0.66).rounded(.down))
    }

    @Test func theFocusedCardRestsInTheMiddleOfTheSafeArea() {
        let placement = outer.placement(slot: 3, offset: outer.restingOffset(for: 3))
        #expect(placement.center.x == outer.safeLeft + outer.contentWidth / 2)
        #expect(placement.scale == 1)
        let left = outer.placement(slot: 2, offset: outer.restingOffset(for: 3))
        #expect(left.center.x < placement.center.x)
        #expect(left.scale < 1)
    }

    @Test func scrollingOneStepBringsTheNextCardToTheFocus() {
        let next = phone.placement(slot: 4, offset: phone.restingOffset(for: 3))
        #expect(abs(next.center.x - phone.focusPoint.x - phone.cardWidth * CascadeCurve.rightOffset) < 0.5)
        let after = phone.placement(slot: 4, offset: phone.restingOffset(for: 4))
        #expect(abs(after.center.x - phone.focusPoint.x) < 0.01)
    }

    @Test func regularWidthIsPagesOfAnEvenGrid() {
        #expect(innerLandscape.style == .grid)
        #expect(innerLandscape.columns == 4)
        #expect(innerLandscape.rows == 2)
        // Four columns would make 147 pt cards in portrait: two instead.
        #expect(innerPortrait.columns == 2)
        #expect(innerPortrait.rows == 2)
        #expect(innerPortrait.cardWidth >= TabGalleryChoices.minGridCardWidth)
        for metrics in [innerLandscape, innerPortrait] {
            #expect(metrics.columns % 2 == 0)
            let lastRow = metrics.gridPoint(metrics.cardsPerPage - 1)
            #expect(lastRow.y + metrics.thumbnailHeight / 2 <= metrics.contentMinY + metrics.contentHeight)
            // The next page starts one screen over.
            #expect(metrics.gridPoint(metrics.cardsPerPage).x - metrics.gridPoint(0).x == metrics.pageWidth)
        }
    }

    @Test func theMiddleGapSitsOnTheFold() {
        for metrics in [innerLandscape, innerPortrait] {
            let half = metrics.columns / 2
            let leftCard = metrics.gridPoint(half - 1).x + metrics.cardWidth / 2
            let rightCard = metrics.gridPoint(half).x - metrics.cardWidth / 2
            #expect(abs((leftCard + rightCard) / 2 - metrics.width / 2) <= 1)
        }
    }

    @Test func aLoneCardAndItsNewTabCardCenterOnTheFold() {
        for var metrics in [innerLandscape, innerPortrait] {
            metrics.centeredRow = 2
            let card = metrics.gridPoint(0), newTab = metrics.gridPoint(1)
            // Side by side in one row, meeting on the fold, in the middle of the space top to bottom.
            #expect(card.y == newTab.y)
            let gapCenter = (card.x + metrics.cardWidth / 2 + newTab.x - metrics.cardWidth / 2) / 2
            #expect(abs(gapCenter - metrics.width / 2) <= 1)
            let middle = metrics.contentMinY + metrics.contentHeight / 2
            let blockCenter = card.y - metrics.thumbnailHeight / 2 - metrics.headerHeight + metrics.cardSize.height / 2
            #expect(abs(blockCenter - middle) <= 1)
        }
        // The cascade ignores it: the lone card rests in the focus.
        var phone = phone
        phone.centeredRow = 2
        #expect(phone.placement(slot: 0, offset: 0).center == phone.focusPoint)
    }

    @Test func gridCardsTakeThePageShapeWithinBounds() {
        #expect(abs(innerLandscape.thumbnailAspect - (669.0 - 24) / 951) < 0.001)
        #expect(innerPortrait.thumbnailAspect == TabGalleryMetrics.gridAspect.upperBound)
    }

    @Test func titleRowGrowsWithText() {
        #expect(phone.headerHeight == 28)
        let large = TabGalleryMetrics(width: 402, height: 874, isCompactWidth: true, titleLineHeight: 53)
        #expect(large.headerHeight == 61)
        #expect(large.cardSize.height == large.thumbnailHeight + 61)
    }

    @Test func aFlickSnapsToACardAndAlwaysMovesAtLeastOne() {
        let step = phone.cascadeStep
        // A slow release rests on the nearest card.
        #expect(phone.snappedOffset(projected: step * 2.4, current: step * 2, velocity: 0.1, count: 10) == step * 2)
        // A quick short swipe still moves one card.
        #expect(phone.snappedOffset(projected: step * 2.2, current: step * 2, velocity: 0.8, count: 10) == step * 3)
        #expect(phone.snappedOffset(projected: step * 1.9, current: step * 2, velocity: -0.8, count: 10) == step * 1)
        // A long fling goes far, and stops at the ends.
        #expect(phone.snappedOffset(projected: step * 7.3, current: step * 2, velocity: 4, count: 10) == step * 7)
        #expect(phone.snappedOffset(projected: step * 40, current: step * 2, velocity: 9, count: 10) == step * 9)
        #expect(phone.snappedOffset(projected: -500, current: step, velocity: -5, count: 10) == 0)
    }

    @Test func gridPagesMoveOneAtATime() {
        let page = innerLandscape.pageWidth
        #expect(innerLandscape.snappedOffset(projected: page * 4, current: 0, velocity: 6, count: 100) == page)
        #expect(innerLandscape.stopCount(for: 17) == 3)
        #expect(innerLandscape.maxOffset(for: 17) == page * 2)
    }

    @Test func onlyCardsNearTheFocusAreCandidates() {
        let range = phone.candidateRange(offset: phone.restingOffset(for: 50), count: 100)
        #expect(range == 45...53)
        #expect(phone.candidateRange(offset: 0, count: 0) == nil)
        #expect(phone.candidateRange(offset: 0, count: 3) == 0...2)
    }
}

@MainActor
struct CardSwipeTests {
    let height: CGFloat = 560

    @Test func aSmallSlowDragSpringsBack() {
        #expect(!CardSwipe.shouldClose(translation: -60, velocity: -100, cardHeight: height))
        #expect(!CardSwipe.shouldClose(translation: -150, velocity: 0, cardHeight: height))
    }

    @Test func aDragPastFortyPercentCloses() {
        #expect(CardSwipe.shouldClose(translation: -230, velocity: 0, cardHeight: height))
    }

    @Test func aFastFlickClosesEvenWhenShort() {
        #expect(CardSwipe.shouldClose(translation: -20, velocity: -900, cardHeight: height))
    }

    @Test func theProjectionCounts() {
        // 180 pt plus a 600 pt/s throw projects past 224 pt (40%).
        #expect(CardSwipe.shouldClose(translation: -180, velocity: -600, cardHeight: height))
    }

    @Test func flickingBackDownKeepsTheCard() {
        #expect(!CardSwipe.shouldClose(translation: -300, velocity: 500, cardHeight: height))
    }

    @Test func draggingDownResists() {
        #expect(CardSwipe.offset(translation: -100, cardHeight: height) == -100)
        let down = CardSwipe.offset(translation: 100, cardHeight: height)
        #expect(down > 0 && down < 100)
        #expect(CardSwipe.offset(translation: 10_000, cardHeight: height) < height)
    }

    @Test func titlesShowOnlyWithRoom() {
        #expect(CardTitle.alpha(visibleFraction: 0.21) == 0)
        #expect(CardTitle.alpha(visibleFraction: 0.78) == 1)
    }
}

@MainActor
struct SwitcherSwipeTests {
    let height: CGFloat = 874

    @Test func thePageShrinksWithTheFingerAndResistsPastTheCard() {
        #expect(SwitcherSwipe.progress(translationY: 0, pageHeight: height) == 0)
        #expect(abs(SwitcherSwipe.progress(translationY: -height * 0.2, pageHeight: height) - 0.5) < 0.001)
        #expect(SwitcherSwipe.progress(translationY: -height * 0.4, pageHeight: height) == 1)
        let far = SwitcherSwipe.progress(translationY: -height * 2, pageHeight: height)
        #expect(far > 1 && far < 1 + SwitcherSwipe.overshoot)
        // Down barely moves it.
        #expect(SwitcherSwipe.progress(translationY: 300, pageHeight: height) >= -0.05)
    }

    @Test func releaseDecidesByProjection() {
        // A clear flick up opens, however short.
        #expect(SwitcherSwipe.opensGallery(progress: 0.05, velocityY: -900, pageHeight: height))
        // Paused past the mark opens; short of it goes back.
        #expect(SwitcherSwipe.opensGallery(progress: 0.5, velocityY: 0, pageHeight: height))
        #expect(!SwitcherSwipe.opensGallery(progress: 0.15, velocityY: 0, pageHeight: height))
        // Moving back down goes back, even from far up.
        #expect(!SwitcherSwipe.opensGallery(progress: 0.8, velocityY: 500, pageHeight: height))
        // A slow push up near the mark is carried over it.
        #expect(SwitcherSwipe.opensGallery(progress: 0.25, velocityY: -400, pageHeight: height))
    }
}

@MainActor
struct TabGalleryItemTests {
    @Test func displayTitleFallsBackToHostThenNewTab() {
        let id = UUID()
        #expect(TabGalleryItem(id: id, title: "  ", url: URL(string: "https://www.example.com/a")).displayTitle == "example.com")
        #expect(TabGalleryItem(id: id, title: "", url: nil).displayTitle == "New Tab")
        #expect(TabGalleryItem(id: id, title: "Hello", url: nil).displayTitle == "Hello")
    }
}
