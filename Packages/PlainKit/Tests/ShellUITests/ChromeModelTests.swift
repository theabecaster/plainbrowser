import CoreGraphics
@testable import ShellUI
import Testing

@MainActor
struct ChromeGeometryTests {
    // iPhone 17: 874 pt tall, 34 pt home indicator.
    let phone = ChromeGeometry(viewHeight: 874, safeBottom: 34, hasButtonBar: true)
    // iPhone SE: no home indicator.
    let se = ChromeGeometry(viewHeight: 667, safeBottom: 0, hasButtonBar: true)
    // Duo outer screen: buttons in the vertical bar, only the pill at the bottom.
    let duo = ChromeGeometry(viewHeight: 678, safeBottom: 34, hasButtonBar: false)

    @Test func restsAboveTheHomeIndicatorOrAMarginAboveAPlainEdge() {
        #expect(phone.restBottom == 840)
        #expect(se.restBottom == 659)
        #expect(duo.restBottom == 644)
    }

    @Test func pillSitsOnTheButtonBarOnlyWhenThereIsOne() {
        #expect(phone.pillRestBottom == 786)
        #expect(duo.pillRestBottom == duo.restBottom)
    }

    @Test func expandedPillHasNoTransform() {
        let move = phone.pillTransform(progress: 0)
        #expect(move.translationY == 0)
        #expect(move.scale == 1)
    }

    @Test func collapsedPillEndsAtTheCollapsedBottom() {
        for geometry in [phone, se, duo] {
            let move = geometry.pillTransform(progress: 1)
            let restCenter = geometry.pillRestBottom - ChromeGeometry.pillHeight / 2
            let bottom = restCenter + move.translationY + ChromeGeometry.pillHeight * move.scale / 2
            #expect(abs(bottom - geometry.collapsedBottom) < 0.001)
            #expect(move.scale == ChromeGeometry.compactScale)
        }
    }

    @Test func collapsedPillClearsTheHomeIndicator() {
        #expect(phone.collapsedBottom == 856)
        #expect(se.collapsedBottom == se.restBottom)
    }

    @Test func obscuredInsetIsTheCollapsedChromeAndSmallerThanTheExpanded() {
        for geometry in [phone, se, duo] {
            let collapsed = geometry.obscuredBottom(pageBottom: geometry.viewHeight)
            let expanded = geometry.expandedBottom(pageBottom: geometry.viewHeight)
            #expect(collapsed == geometry.viewHeight - geometry.collapsedTop)
            #expect(expanded > collapsed)
        }
    }

    @Test func buttonBarLeavesPastTheEdgeAndFadesFirst() {
        #expect(phone.barTranslation(progress: 0) == 0)
        #expect(phone.barTranslation(progress: 1) == 82)
        #expect(ChromeGeometry.barAlpha(progress: 0) == 1)
        #expect(ChromeGeometry.barAlpha(progress: 0.6) == 0)
        #expect(ChromeGeometry.barAlpha(progress: 1) == 0)
    }
}

@MainActor
struct ChromeCollapseTests {
    @Test func followsTheScrollOneToOne() {
        var collapse = ChromeCollapse(distance: 50)
        collapse.scrolled(to: 100, top: 0, bottom: 1000)
        #expect(collapse.progress == 0)
        collapse.scrolled(to: 125, top: 0, bottom: 1000)
        #expect(collapse.progress == 0.5)
        collapse.scrolled(to: 200, top: 0, bottom: 1000)
        #expect(collapse.progress == 1)
        collapse.scrolled(to: 175, top: 0, bottom: 1000)
        #expect(collapse.progress == 0.5)
    }

    @Test func atTheTopTheBarIsAlwaysOut() {
        var collapse = ChromeCollapse(distance: 50)
        collapse.settle(at: 1)
        collapse.scrolled(to: -30, top: 0, bottom: 1000)
        #expect(collapse.progress == 0)
    }

    @Test func theBottomRubberBandDoesNotBringTheBarBack() {
        var collapse = ChromeCollapse(distance: 50)
        collapse.settle(at: 1)
        collapse.scrolled(to: 1040, top: 0, bottom: 1000)
        collapse.scrolled(to: 1000, top: 0, bottom: 1000)
        collapse.scrolled(to: 1020, top: 0, bottom: 1000)
        #expect(collapse.progress == 1)
    }

    @Test func aFreshDragDoesNotJumpFromTheLastOffset() {
        var collapse = ChromeCollapse(distance: 50)
        collapse.scrolled(to: 100, top: 0, bottom: 1000)
        collapse.resetTracking()
        collapse.scrolled(to: 600, top: 0, bottom: 1000)
        #expect(collapse.progress == 0)
    }

    @Test func settlesAtTheNearerEndUnlessFlicked() {
        var collapse = ChromeCollapse(distance: 50)
        collapse.scrolled(to: 100, top: 0, bottom: 1000)
        collapse.scrolled(to: 120, top: 0, bottom: 1000)
        #expect(collapse.isMidway)
        #expect(collapse.settleTarget() == 0)
        #expect(collapse.settleTarget(velocity: 1) == 1)
        collapse.scrolled(to: 140, top: 0, bottom: 1000)
        #expect(collapse.settleTarget() == 1)
        #expect(collapse.settleTarget(velocity: -1) == 0)
    }
}

@MainActor
struct PullToRefreshTests {
    @Test func armsAtEightyPointsOnceAndDisarmsBelow() {
        var tracker = PullToRefreshTracker()
        #expect(tracker.pulled(40) == nil)
        #expect(tracker.pulled(79.9) == nil)
        #expect(tracker.pulled(80) == .armed)
        #expect(tracker.pulled(120) == nil)
        #expect(tracker.pulled(60) == .disarmed)
        #expect(tracker.isArmed == false)
    }

    @Test func releaseRefreshesOnlyWhenArmed() {
        var tracker = PullToRefreshTracker()
        _ = tracker.pulled(50)
        #expect(tracker.released() == false)
        _ = tracker.pulled(90)
        #expect(tracker.released() == true)
        #expect(tracker.isArmed == false)
        #expect(tracker.released() == false)
    }
}
