import CoreGraphics
import Foundation
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

    @Test func collapsedInsetIsTheCollapsedChromeAndSmallerThanTheExpanded() {
        for geometry in [phone, se, duo] {
            let collapsed = geometry.collapsedInset(pageBottom: geometry.viewHeight)
            let expanded = geometry.expandedInset(pageBottom: geometry.viewHeight)
            #expect(collapsed == geometry.viewHeight - geometry.collapsedTop)
            #expect(expanded > collapsed)
        }
    }

    @Test func obscuredInsetFollowsTheRestingBar() {
        for geometry in [phone, se, duo] {
            let bottom = geometry.viewHeight
            // Expanded, the inset reaches the pill's top: nothing under the bar is hidden.
            #expect(geometry.obscuredInset(pageBottom: bottom, rest: .expanded) == bottom - geometry.expandedTop)
            #expect(geometry.obscuredInset(pageBottom: bottom, rest: .pill) == geometry.collapsedInset(pageBottom: bottom))
            #expect(geometry.obscuredInset(pageBottom: bottom, rest: .hidden) == geometry.hiddenInset(pageBottom: bottom))
        }
        // iPhone 17: the expanded pill and bar cover 136 pt of the page, the collapsed pill 54 pt,
        // the hidden bar only the home-indicator zone.
        #expect(phone.obscuredInset(pageBottom: 874, rest: .expanded) == 136)
        #expect(phone.obscuredInset(pageBottom: 874, rest: .pill) == 54)
        #expect(phone.obscuredInset(pageBottom: 874, rest: .hidden) == 34)
        // No home indicator: a 16 pt edge strip.
        #expect(se.obscuredInset(pageBottom: 667, rest: .hidden) == 16)
    }

    @Test func hiddenInsetIsTheSmallestAndTheViewportSpansHiddenToExpanded() {
        for geometry in [phone, se, duo] {
            let bottom = geometry.viewHeight
            let hidden = geometry.hiddenInset(pageBottom: bottom)
            #expect(hidden < geometry.collapsedInset(pageBottom: bottom))
            #expect(hidden < geometry.expandedInset(pageBottom: bottom))
        }
    }

    @Test func hiddenPillSinksPastTheEdgeAndFades() {
        for geometry in [phone, se, duo] {
            let move = geometry.pillTransform(progress: 2)
            let restCenter = geometry.pillRestBottom - ChromeGeometry.pillHeight / 2
            let top = restCenter + move.translationY - ChromeGeometry.pillHeight * move.scale / 2
            #expect(abs(top - geometry.viewHeight - ChromeGeometry.hiddenClearance) < 0.001)
            // Off screen well before the spring's tail: by 85% of the way.
            let early = geometry.pillTransform(progress: 1.85)
            #expect(restCenter + early.translationY - ChromeGeometry.pillHeight * early.scale / 2 > geometry.viewHeight)
            #expect(move.scale == ChromeGeometry.compactScale)
        }
        #expect(ChromeGeometry.pillAlpha(progress: 1) == 1)
        #expect(ChromeGeometry.pillAlpha(progress: 1.5) == 0.5)
        #expect(ChromeGeometry.pillAlpha(progress: 2) == 0)
        #expect(ChromeGeometry.pillAlpha(progress: 0) == 1)
    }

    @Test func glassMergesOnlyBelowTheRestingGap() {
        #expect(ChromeGeometry.glassMergeSpacing < ChromeGeometry.gap)
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
        #expect(collapse.settleTarget() == .expanded)
        #expect(collapse.settleTarget(velocity: 1) == .pill)
        collapse.scrolled(to: 140, top: 0, bottom: 1000)
        #expect(collapse.settleTarget() == .pill)
        #expect(collapse.settleTarget(velocity: -1) == .expanded)
    }
}

@MainActor
struct ChromeHideTests {
    /// A collapse that has reached the pill, on a 5000 pt page.
    private func atThePill() -> ChromeCollapse {
        var collapse = ChromeCollapse(distance: 50, hideDistance: 100)
        collapse.scrolled(to: 100, top: 0, bottom: 5000, canHide: true)
        collapse.scrolled(to: 150, top: 0, bottom: 5000, canHide: true)
        #expect(collapse.progress == 1)
        return collapse
    }

    @Test func keepScrollingPastThePillHides() {
        var collapse = atThePill()
        #expect(collapse.scrolled(to: 200, top: 0, bottom: 5000, canHide: true) == .none)
        #expect(collapse.scrolled(to: 250, top: 0, bottom: 5000, canHide: true) == .hide)
    }

    @Test func hidingAddsUpOverSeveralDrags() {
        var collapse = atThePill()
        collapse.settle(at: 1)
        collapse.scrolled(to: 150, top: 0, bottom: 5000, canHide: true)
        #expect(collapse.scrolled(to: 220, top: 0, bottom: 5000, canHide: true) == .none)
        collapse.resetTracking()
        collapse.scrolled(to: 220, top: 0, bottom: 5000, canHide: true)
        #expect(collapse.scrolled(to: 260, top: 0, bottom: 5000, canHide: true) == .hide)
    }

    @Test func neverHidesWhenTheStateOrPageSaysNo() {
        var collapse = atThePill()
        #expect(collapse.scrolled(to: 600, top: 0, bottom: 5000, canHide: false) == .none)
        #expect(collapse.progress == 1)
    }

    @Test func aCoastAtThePillHidesToo() {
        var collapse = atThePill()
        collapse.head(to: .pill)
        collapse.scrolled(to: 200, top: 0, bottom: 5000, tracking: false, snapping: true, canHide: true)
        #expect(collapse.scrolled(to: 260, top: 0, bottom: 5000, tracking: false, canHide: true) == .hide)
    }

    @Test func aDeliberateMoveUpBringsAHiddenBarBackAndJitterDoesNot() {
        var collapse = atThePill()
        collapse.settle(at: 2)
        #expect(collapse.rest == .hidden)
        collapse.scrolled(to: 1000, top: 0, bottom: 5000)
        #expect(collapse.scrolled(to: 990, top: 0, bottom: 5000) == .none)
        #expect(collapse.scrolled(to: 995, top: 0, bottom: 5000) == .none)
        // The move down at 995 started the count again: 15, then 20 pt up is not enough.
        #expect(collapse.scrolled(to: 980, top: 0, bottom: 5000) == .none)
        #expect(collapse.scrolled(to: 975, top: 0, bottom: 5000) == .none)
        #expect(collapse.scrolled(to: 970, top: 0, bottom: 5000) == .reveal)
        #expect(collapse.progress == 2)
    }

    @Test func aFastMoveUpBringsItBackSooner() {
        var collapse = atThePill()
        collapse.settle(at: 2)
        collapse.scrolled(to: 1000, top: 0, bottom: 5000)
        #expect(collapse.scrolled(to: 995, top: 0, bottom: 5000, velocity: -1) == .none)
        #expect(collapse.scrolled(to: 990, top: 0, bottom: 5000, velocity: -1) == .reveal)
    }

    @Test func aHiddenBarStaysHiddenWhileCoasting() {
        var collapse = atThePill()
        collapse.settle(at: 2)
        collapse.scrolled(to: 1000, top: 0, bottom: 5000, tracking: false)
        #expect(collapse.scrolled(to: 900, top: 0, bottom: 5000, tracking: false) == .none)
    }

    @Test func theTopAndThePageEndBringItBack() {
        var collapse = atThePill()
        collapse.settle(at: 2)
        collapse.scrolled(to: 30, top: 0, bottom: 5000, tracking: false)
        #expect(collapse.scrolled(to: 0, top: 0, bottom: 5000, tracking: false) == .reveal)

        var atEnd = atThePill()
        atEnd.settle(at: 2)
        atEnd.scrolled(to: 4800, top: 0, bottom: 5000, pageEnd: 4966, tracking: false)
        #expect(atEnd.scrolled(to: 4970, top: 0, bottom: 5000, pageEnd: 4966, tracking: false) == .reveal)
    }

    @Test func nearThePageEndTheBarNeitherCollapsesNorHides() {
        var collapse = ChromeCollapse(distance: 50, hideDistance: 100)
        collapse.scrolled(to: 4900, top: 0, bottom: 5000, pageEnd: 4930, canHide: true)
        #expect(collapse.scrolled(to: 4920, top: 0, bottom: 5000, pageEnd: 4930, canHide: true) == .none)
        #expect(collapse.progress == 0)
        // The expanded bar arriving at the end stays as it is.
        #expect(collapse.scrolled(to: 4940, top: 0, bottom: 5000, pageEnd: 4930, canHide: true) == .none)
    }

    @Test func aRevealEndsTheHideTravel() {
        var collapse = atThePill()
        collapse.scrolled(to: 230, top: 0, bottom: 5000, canHide: true)
        collapse.head(to: .expanded)
        #expect(collapse.downTravel == 0)
    }

    @Test func aFlickPastTheHideTravelGoesStraightToHidden() {
        var collapse = ChromeCollapse(distance: 50, hideDistance: 100)
        collapse.scrolled(to: 100, top: 0, bottom: 5000)
        collapse.scrolled(to: 130, top: 0, bottom: 5000)
        #expect(collapse.settleTarget(velocity: 2, coast: 400, canHide: true) == .hidden)
        #expect(collapse.settleTarget(velocity: 2, coast: 400, canHide: false) == .pill)
        #expect(collapse.settleTarget(velocity: 2, coast: 400, canHide: true, coastReachesEnd: true) == .pill)
        // A flick against the end, where the bar is out, keeps it out.
        #expect(collapse.settleTarget(velocity: 2, coast: 0, canHide: true, coastReachesEnd: true, atEnd: true) == .expanded)
        #expect(collapse.settleTarget(velocity: 0.5, coast: 60, canHide: true) == .pill)
    }

    @Test func aReleaseWhileHiddenStaysHiddenUnlessFlickedUp() {
        var collapse = atThePill()
        collapse.settle(at: 2)
        #expect(collapse.settleTarget(velocity: 0) == .hidden)
        #expect(collapse.settleTarget(velocity: 1) == .hidden)
        #expect(collapse.settleTarget(velocity: -1) == .expanded)
    }

    @Test func restsFromProgress() {
        #expect(ChromeRest(progress: 0) == .expanded)
        #expect(ChromeRest(progress: 0.7) == .expanded)
        #expect(ChromeRest(progress: 1) == .pill)
        #expect(ChromeRest(progress: 2) == .hidden)
    }
}

@MainActor
struct ToolbarSnapTests {
    @Test func snapKeepsTheSpeedTheBarHadUnderTheFinger() {
        var collapse = ChromeCollapse(distance: 50)
        collapse.scrolled(to: 100, top: 0, bottom: 1000)
        collapse.scrolled(to: 125, top: 0, bottom: 1000)
        // 0.2 pt/ms over a 50 pt collapse is 4 progress per second.
        #expect(collapse.snapVelocity(scrollVelocity: 0.2, toward: 1) == 4)
        #expect(collapse.snapVelocity(scrollVelocity: -0.2, toward: 0) == -4)
    }

    @Test func snapVelocityIsCappedAndNeverAwayFromTheTarget() {
        var collapse = ChromeCollapse(distance: 50)
        collapse.scrolled(to: 100, top: 0, bottom: 1000)
        collapse.scrolled(to: 125, top: 0, bottom: 1000)
        #expect(collapse.snapVelocity(scrollVelocity: 5, toward: 1) == ChromeCollapse.maxSnapVelocity)
        #expect(collapse.snapVelocity(scrollVelocity: 0.1, toward: 0) == 0)
    }
}

@MainActor
struct PageInsetStateTests {
    @Test func startsExpandedAndFollowsEachRest() {
        var inset = PageInsetState()
        #expect(inset.rest == .expanded)
        inset.barRested(.pill)
        #expect(inset.applyIfSettled(offset: 300, top: 0, bottom: 2000) == true)
        #expect(inset.rest == .pill)
        inset.barRested(.pill)
        #expect(inset.pending == nil)
        #expect(inset.applyIfSettled(offset: 300, top: 0, bottom: 2000) == false)
    }

    @Test func waitsWhileThePageBouncesPastAnEdge() {
        var inset = PageInsetState()
        inset.barRested(.pill)
        #expect(inset.applyIfSettled(offset: -40, top: 0, bottom: 2000) == false)
        #expect(inset.applyIfSettled(offset: 2030, top: 0, bottom: 2000) == false)
        #expect(inset.rest == .expanded)
        #expect(inset.applyIfSettled(offset: 0, top: 0, bottom: 2000) == true)
        #expect(inset.rest == .pill)
    }

    @Test func aNewMoveDropsAChangeThatWaitedForABounce() {
        var inset = PageInsetState()
        inset.barRested(.pill)
        #expect(inset.applyIfSettled(offset: 2030, top: 0, bottom: 2000) == false)
        inset.barMoved()
        #expect(inset.applyIfSettled(offset: 1990, top: 0, bottom: 2000) == false)
        #expect(inset.rest == .expanded)
    }

    @Test func followsTheHiddenRestToo() {
        var inset = PageInsetState()
        inset.barRested(.hidden)
        #expect(inset.applyIfSettled(offset: 300, top: 0, bottom: 2000) == true)
        #expect(inset.rest == .hidden)
        inset.barRested(.expanded)
        #expect(inset.applyIfSettled(offset: 300, top: 0, bottom: 2000) == true)
        #expect(inset.rest == .expanded)
    }

    @Test func aShortPageRestsAtItsTop() {
        var inset = PageInsetState()
        inset.barRested(.pill)
        #expect(inset.applyIfSettled(offset: 0, top: 0, bottom: -300) == true)
    }

    /// A reveal moves the inset as the bar starts back, so a fixed footer rises with the bar; a
    /// hide waits for the bar to rest.
    @Test func aRevealMovesTheInsetAtItsStartAHideAtItsEnd() {
        var inset = PageInsetState()
        inset.barHeading(to: .hidden)
        #expect(inset.pending == nil, "a hide waits for the rest")
        inset.barRested(.hidden)
        #expect(inset.applyIfSettled(offset: 300, top: 0, bottom: 2000) == true)
        inset.barHeading(to: .expanded)
        #expect(inset.pending == .expanded, "a reveal applies now")
        #expect(inset.applyIfSettled(offset: 300, top: 0, bottom: 2000) == true)
        #expect(inset.rest == .expanded)
        inset.barRested(.expanded)
        #expect(inset.pending == nil, "nothing left for the rest")
        // The pill back to expanded is a reveal too; hidden to the pill grows the inset as well.
        inset.barRested(.pill)
        _ = inset.applyIfSettled(offset: 300, top: 0, bottom: 2000)
        inset.barHeading(to: .expanded)
        #expect(inset.pending == .expanded)
    }

    @Test func aRevealStillWaitsForABounce() {
        var inset = PageInsetState()
        inset.barRested(.hidden)
        _ = inset.applyIfSettled(offset: 300, top: 0, bottom: 2000)
        inset.barHeading(to: .expanded)
        #expect(inset.applyIfSettled(offset: 2040, top: 0, bottom: 2000) == false)
        #expect(inset.rest == .hidden)
        #expect(inset.applyIfSettled(offset: 1990, top: 0, bottom: 2000) == true)
        #expect(inset.rest == .expanded)
    }

    @Test func aHideThatTurnsAroundDropsAWaitingReveal() {
        var inset = PageInsetState()
        inset.barRested(.hidden)
        _ = inset.applyIfSettled(offset: 300, top: 0, bottom: 2000)
        inset.barHeading(to: .expanded)
        #expect(inset.applyIfSettled(offset: -30, top: 0, bottom: 2000) == false)
        inset.barHeading(to: .hidden)
        #expect(inset.pending == nil)
        #expect(inset.applyIfSettled(offset: 0, top: 0, bottom: 2000) == false)
        #expect(inset.rest == .hidden)
    }

    @Test func aRestBackToTheShownStateCancelsTheWait() {
        var inset = PageInsetState()
        inset.barRested(.pill)
        #expect(inset.applyIfSettled(offset: -40, top: 0, bottom: 2000) == false)
        inset.barRested(.expanded)
        #expect(inset.pending == nil)
        #expect(inset.applyIfSettled(offset: 0, top: 0, bottom: 2000) == false)
        #expect(inset.rest == .expanded)
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
        // Hysteresis: just under the line stays armed, 10 pt under disarms.
        #expect(tracker.pulled(75) == nil)
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

/// Try Again that fails again: the warning once, when the retried load ends (haptics plan, §4.7).
struct RetryWatchTests {
    let tab = UUID()

    @Test func warnsOnceWhenTheRetriedLoadFailsAgain() {
        var watch = RetryWatch()
        #expect(watch.update(tab: tab, isLoading: false, isFailed: true) == false, "no Try Again yet")
        watch.begin(tab)
        #expect(watch.update(tab: tab, isLoading: false, isFailed: true) == false, "the old failure, before the load starts")
        #expect(watch.update(tab: tab, isLoading: true, isFailed: false) == false)
        #expect(watch.update(tab: tab, isLoading: false, isFailed: true) == true)
        #expect(watch.tab == nil)
        #expect(watch.update(tab: tab, isLoading: false, isFailed: true) == false, "once")
    }

    @Test func aRetryThatLoadsIsSilent() {
        var watch = RetryWatch()
        watch.begin(tab)
        _ = watch.update(tab: tab, isLoading: true, isFailed: false)
        #expect(watch.update(tab: tab, isLoading: false, isFailed: false) == false)
        #expect(watch.tab == nil, "the load ended: the watch with it")
    }

    @Test func anotherTabOnScreenEndsTheWatch() {
        var watch = RetryWatch()
        watch.begin(tab)
        _ = watch.update(tab: tab, isLoading: true, isFailed: false)
        #expect(watch.update(tab: UUID(), isLoading: false, isFailed: true) == false)
        #expect(watch.update(tab: tab, isLoading: false, isFailed: true) == false, "back on the tab: the watch is gone")
    }

    @Test func aNewFailureCountsEvenIfTheLoadWasNeverSeen() {
        var watch = RetryWatch()
        watch.begin(tab)
        #expect(watch.update(tab: tab, isLoading: false, isFailed: true, errorChanged: true) == true)
    }
}
