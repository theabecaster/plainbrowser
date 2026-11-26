import CoreGraphics
import Foundation
import Testing
@testable import TabGalleryUI

@MainActor
struct TabGalleryMetricsTests {
    // iPhone 17 portrait, compact width.
    let phone = TabGalleryMetrics(width: 402, height: 874, isCompactWidth: true, titleLineHeight: 20)
    // Duo outer screen.
    let outer = TabGalleryMetrics(width: 382, height: 678, isCompactWidth: true, titleLineHeight: 20)
    // Duo inner screen, landscape and portrait.
    let innerLandscape = TabGalleryMetrics(width: 951, height: 669, isCompactWidth: false, titleLineHeight: 18)
    let innerPortrait = TabGalleryMetrics(width: 669, height: 951, isCompactWidth: false, titleLineHeight: 18)

    @Test func compactWidthIsOneColumnOfLargeCards() {
        for metrics in [phone, outer] {
            #expect(metrics.columns == 1)
            #expect(metrics.cardWidth == metrics.width - TabGalleryMetrics.margin * 2)
            #expect(metrics.thumbnailHeight == (metrics.cardWidth * TabGalleryMetrics.listAspect).rounded())
        }
    }

    @Test func regularWidthIsAnEvenGrid() {
        #expect(innerLandscape.columns == 4)
        // Four columns would make 147 pt cards in portrait: two instead.
        #expect(innerPortrait.columns == 2)
        #expect(innerPortrait.cardWidth >= TabGalleryChoices.minGridCardWidth)
        #expect(TabGalleryMetrics(width: 600, height: 800, isCompactWidth: false, titleLineHeight: 18).columns == 2)
        for metrics in [innerLandscape, innerPortrait] {
            #expect(metrics.columns % 2 == 0)
        }
    }

    @Test func theMiddleGapSitsOnTheFold() {
        for metrics in [innerLandscape, innerPortrait] {
            let half = metrics.columns / 2
            let gapStart = metrics.sideInset + CGFloat(half) * metrics.cardWidth + CGFloat(half - 1) * TabGalleryMetrics.spacing
            let gapMid = gapStart + TabGalleryMetrics.spacing / 2
            #expect(abs(gapMid - metrics.width / 2) <= 1)
        }
    }

    @Test func gridCardsTakeThePageShapeWithinBounds() {
        #expect(abs(innerLandscape.thumbnailAspect - 669.0 / 951) < 0.001)
        #expect(innerPortrait.thumbnailAspect == TabGalleryMetrics.gridAspect.upperBound)
        let wide = TabGalleryMetrics(width: 1400, height: 400, isCompactWidth: false, titleLineHeight: 18)
        #expect(wide.thumbnailAspect == TabGalleryMetrics.gridAspect.lowerBound)
    }

    @Test func titleRowIsATapTargetAndGrowsWithText() {
        #expect(phone.titleRowHeight == 44)
        let large = TabGalleryMetrics(width: 402, height: 874, isCompactWidth: true, titleLineHeight: 53)
        #expect(large.titleRowHeight == 65)
        #expect(large.cardSize.height == large.thumbnailHeight + 65)
    }
}

@MainActor
struct CardFlickTests {
    let width: CGFloat = 370

    @Test func aSmallSlowDragSpringsBack() {
        #expect(!CardFlick.shouldClose(translation: 40, velocity: 50, cardWidth: width))
        #expect(!CardFlick.shouldClose(translation: -60, velocity: 0, cardWidth: width))
    }

    @Test func aDragPastFortyPercentCloses() {
        #expect(CardFlick.shouldClose(translation: 160, velocity: 0, cardWidth: width))
        #expect(CardFlick.shouldClose(translation: -160, velocity: 0, cardWidth: width))
    }

    @Test func aFastFlickClosesEvenWhenShort() {
        #expect(CardFlick.shouldClose(translation: 20, velocity: 900, cardWidth: width))
        #expect(CardFlick.shouldClose(translation: -20, velocity: -900, cardWidth: width))
    }

    @Test func theProjectionCounts() {
        // 100 pt plus a 300 pt/s throw projects past 148 pt (40%).
        #expect(CardFlick.shouldClose(translation: 100, velocity: 300, cardWidth: width))
    }

    @Test func flickingBackKeepsTheCard() {
        #expect(!CardFlick.shouldClose(translation: 120, velocity: -900, cardWidth: width))
    }

    @Test func theCardFadesAsItLeaves() {
        #expect(CardFlick.alpha(translation: 0, cardWidth: width) == 1)
        #expect(CardFlick.alpha(translation: width, cardWidth: width) == 0.35)
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
