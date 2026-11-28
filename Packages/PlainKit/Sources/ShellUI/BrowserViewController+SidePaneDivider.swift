#if canImport(UIKit)
import BrowserCore
import DesignSystem
import os
import PerfSignposts
import SwiftUI
import UIKit

// MARK: - The divider between the page and the side pane

/// The seam between the page and the side pane, made to be moved (docs/research/resizable-pane.md,
/// docs/decisions.md "The side pane's divider"): drag it and it rests at Narrow, Half or Two Thirds
/// (the ones that fit), drag the pane thin and it closes, drag the page thin and the pane takes the
/// whole width. A flick carries on to the next rest. It ticks at each rest it passes and gives the
/// threshold where closing or taking over arms; a tick when that disarms.
///
/// Performance: the page's web views and the pane's sections never lay out while the divider
/// moves. The pane's column moves (its header follows, its content keeps its width, clipped or
/// with paper beside it), the page keeps its frame under the pane or shows its own background
/// past its edge, and each side gets its new frame once per settle: the side that grows when the
/// settle starts (its new part is under the other side), the side that shrinks when it ends.
@MainActor
final class SidePaneDividerController: NSObject, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate,
    UIPointerInteractionDelegate {
    private weak var browser: BrowserViewController?
    private weak var pane: SidePaneController?
    /// The strip the divider takes touches and the pointer in, and the handle on the seam.
    private let stripView = SidePaneDividerStrip()
    private let handle = SidePaneDividerHandle()
    /// The page's own background past its frame while the page grows under the finger.
    private let fill = UIView()
    /// Dims the page while a drag would hand the pane the whole width.
    private let veil = UIView()
    private let pan = UIPanGestureRecognizer()
    private let driver = SpringDriver(spring: Motion.sidePaneSettle(flicked: false), restDistance: 0.5)
    private var drag: SidePaneDividerDrag?
    /// The geometry the drag or settle runs on (the layout's when it began).
    private var geometry: SidePaneDividerGeometry?
    /// The column's top and height while it moves.
    private var columnBand: (minY: CGFloat, height: CGFloat) = (0, 0)
    /// What the settle running now still commits when it ends.
    private var pending: Pending?
    /// Whether the bar spans the pane now (the take-over line armed, or the pane has the width).
    private var barSpansPane = false
    private var dragInterval: OSSignpostIntervalState?
    private var settleInterval: OSSignpostIntervalState?
    #if DEBUG
    private var meter: SidePaneDividerMeter?
    #endif

    private struct Pending {
        var outcome: SidePaneDividerOutcome
        var commitsPage: Bool
        var commitsPane: Bool
    }

    /// The touches and the pointer the divider takes, in the root view.
    private(set) var strip: CGRect = .null

    /// A finger has the divider, or it is settling.
    var isActive: Bool { drag != nil || driver.isRunning }

    init(browser: BrowserViewController, pane: SidePaneController) {
        self.browser = browser
        self.pane = pane
        super.init()
        let root = browser.view!
        fill.isUserInteractionEnabled = false
        fill.isHidden = true
        veil.isUserInteractionEnabled = false
        veil.backgroundColor = Palette.galleryDim
        veil.alpha = 0
        root.insertSubview(fill, belowSubview: pane.view)
        root.insertSubview(veil, belowSubview: pane.view)
        root.insertSubview(stripView, aboveSubview: pane.view)
        stripView.handle = handle
        stripView.addSubview(handle)
        stripView.isHidden = true
        stripView.addInteraction(UIPointerInteraction(delegate: self))

        pan.addTarget(self, action: #selector(panned(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        root.addGestureRecognizer(pan)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        handle.addGestureRecognizer(doubleTap)
        handle.addInteraction(UIContextMenuInteraction(delegate: self))
        handle.onAdjust = { [weak self] wider in self?.step(wider: wider) ?? false }
        handle.onHide = { [weak self] in self?.browser?.closeSidePane(animated: true) }
        handle.onToggleFullWidth = { [weak self] in self?.browser?.toggleSidePaneTakeOver() }
    }

    // MARK: Placement (every layout pass)

    /// Puts the strip and the handle on the pane's leading edge, or hides them where the divider
    /// can't move (the pane closed, partly folded, while it opens or closes).
    func place(column: CGRect?, layout: DuoLayout) {
        guard let browser, let column, let divider = layout.sidePaneDivider ?? geometry,
              !browser.sidePaneUI.isAnimating else {
            stripView.isHidden = true
            strip = .null
            return
        }
        let target = CGFloat(FixedChoices.sidePaneDividerTarget)
        // With the whole width the seam is at the pages' leading edge: the strip stays on the pane,
        // off a rail beside it (whose own drag resizes the sidebar), and the grip sits inside it.
        let minX = max(divider.span.lowerBound, column.minX - target / 2)
        strip = CGRect(x: minX, y: column.minY, width: max(column.minX, minX + target / 2) + target / 2 - minX, height: column.height)
        stripView.frame = strip
        let handleHeight = target * 2
        let grip = max(column.minX, strip.minX + target / 2)
        handle.frame = CGRect(
            x: grip - strip.minX - target / 2, y: (column.height - handleHeight) / 2, width: target, height: handleHeight
        )
        handle.update(value: valueText(layout: layout), takesOver: layout.sidePaneTakesOver)
        stripView.isHidden = false
    }

    private func valueText(layout: DuoLayout) -> String {
        guard let browser, let divider = layout.sidePaneDivider else { return "" }
        if layout.sidePaneTakesOver { return String(localized: "Full Width") }
        let rest = divider.rests.count == 1 ? divider.rests[0] : divider.rest(for: browser.sidePaneUI.restWidth)
        let share = Int((rest.paneWidth / max(divider.width, 1) * 100).rounded())
        return divider.rests.count == 1 ? String(localized: "Beside the page, \(share) percent")
            : String(localized: "\(rest.width.title), \(share) percent")
    }

    // MARK: Drag

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard let browser else { return }
        switch pan.state {
        case .began:
            guard begin() else { return }
            dragInterval = Signposts.signposter.beginInterval(Signposts.sidePaneDrag, id: Signposts.signposter.makeSignpostID())
            Haptic.selection.prepare(in: browser.view)
            Haptic.threshold.prepare(in: browser.view)
            handle.state = .dragging
            #if DEBUG
            meter = SidePaneDividerMeter(view: browser.view)
            #endif
            move(travel: pan.translation(in: browser.view).x)
        case .changed:
            move(travel: pan.translation(in: browser.view).x)
        case .ended, .cancelled, .failed:
            guard self.drag != nil else { return }
            move(travel: pan.translation(in: browser.view).x)
            guard let drag else { return }
            let velocityX = pan.state == .ended ? pan.velocity(in: browser.view).x : 0
            let outcome = pan.state == .ended ? drag.outcome(velocity: -velocityX) : restingOutcome()
            if pan.state == .ended, let haptic = drag.releaseHaptic(for: outcome) { haptic.play(in: browser.view) }
            if let dragInterval {
                Signposts.signposter.endInterval(Signposts.sidePaneDrag, dragInterval, "\(Self.name(outcome))")
                self.dragInterval = nil
            }
            self.drag = nil
            let flicked = abs(velocityX) >= CGFloat(FixedChoices.sidePaneDividerFlick)
            settle(to: outcome, velocity: velocityX, flicked: flicked)
        default:
            break
        }
    }

    /// Takes the divider from where it is (at rest, or mid-settle: the spring stops under the
    /// finger) and readies the sides to move without laying out.
    private func begin() -> Bool {
        guard let browser, let layout = browser.duo.layout else { return false }
        let x: CGFloat
        if driver.isRunning {
            x = driver.stop()
            if let settleInterval { Signposts.signposter.endInterval(Signposts.sidePaneSettle, settleInterval, "caught") }
            settleInterval = nil
            pending = nil
        } else {
            guard let column = layout.sidePaneColumn, let divider = layout.sidePaneDivider else { return false }
            geometry = divider
            x = column.minX
            columnBand = (column.minY, column.height)
        }
        guard let geometry else { return false }
        prepareMove(layout: layout)
        drag = SidePaneDividerDrag(geometry: geometry, startWidth: geometry.paneWidth(dividerX: x))
        barSpansPane = drag?.isTakeOverArmed ?? false
        return true
    }

    /// The sides about to move: the pane's content keeps its width, a page out of sight comes
    /// back under the pane, and the page's background is ready for past its edge.
    private func prepareMove(layout: DuoLayout) {
        guard let browser, let pane else { return }
        if geometry == nil {
            geometry = layout.sidePaneDivider
            if let column = layout.sidePaneColumn { columnBand = (column.minY, column.height) }
        }
        pane.freezeContent()
        if browser.sidePaneUI.takesOver { browser.sidePaneUI.revealsPage = true }
        fill.backgroundColor = browser.sidePanePageBackground
    }

    private func move(travel: CGFloat) {
        guard var drag, let browser else { return }
        let haptic = drag.move(travel: travel)
        self.drag = drag
        if let haptic { haptic.play(in: browser.view) }
        apply(x: drag.geometry.dividerX(paneWidth: drag.paneWidth), closeArmed: drag.isCloseArmed,
              takeOverArmed: drag.isTakeOverArmed)
    }

    /// Puts the divider at `x` this frame: the pane's column, the page's background past its edge,
    /// the bar's lane and the dims. Constants and frames only: the page and the pane's content keep
    /// their frames.
    private func apply(x proposed: CGFloat, closeArmed: Bool = false, takeOverArmed: Bool = false) {
        guard let browser, let geometry else { return }
        #if DEBUG
        let started = CACurrentMediaTime()
        #endif
        let span = geometry.span
        let x = min(span.upperBound, max(span.lowerBound, proposed))
        browser.sidePaneUI.dragColumn = CGRect(x: x, y: columnBand.minY, width: span.upperBound - x, height: columnBand.height)
        // The page's background beyond the frame it keeps, while it grows.
        // In a split the page the pane serves is the first pane; the second is out of sight.
        let covers = browser.duo.layout?.sidePaneCoversSecondPane == true
        let pageEnd = browser.panes.view.isHidden ? span.lowerBound
            : covers ? (browser.duo.layout?.paneFrames.first?.maxX ?? span.lowerBound) : browser.panes.view.frame.maxX
        if x > pageEnd + 0.5 {
            fill.frame = CGRect(x: pageEnd, y: 0, width: x - pageEnd, height: browser.view.bounds.height)
            fill.isHidden = false
        } else if !fill.isHidden {
            fill.isHidden = true
        }
        veil.frame = CGRect(x: span.lowerBound, y: 0, width: max(0, x - span.lowerBound), height: browser.view.bounds.height)
        #if DEBUG
        if SidePaneDividerMeter.resizesLive, browser.duo.layout?.sidePaneCoversSecondPane == false {
            // The naive way, for the measurement only: the page's web view follows every frame.
            browser.duo.panesTrailing.constant = -(span.upperBound - x)
        }
        #endif
        // The bar keeps to the page while the page reads (at least its minimum), and spans the
        // pane once the pane would take the whole width.
        let minimumPage = geometry.minimumPage
        let laneEnd = takeOverArmed ? span.upperBound : min(span.upperBound, max(x, span.lowerBound + minimumPage))
        let spans = takeOverArmed
        setLane(span.lowerBound...laneEnd)
        browser.view.setNeedsLayout()
        if spans != barSpansPane {
            // The line crossed: the bar slides across (or back) and the header moves with it.
            barSpansPane = spans
            Motion.animate(Motion.sidePaneArm, changes: { browser.view.layoutIfNeeded() })
        } else {
            browser.view.layoutIfNeeded()
        }
        setArmed(close: closeArmed, takeOver: takeOverArmed)
        #if DEBUG
        meter?.record(work: CACurrentMediaTime() - started)
        #endif
    }

    private func setLane(_ lane: ClosedRange<CGFloat>) {
        guard let browser else { return }
        let width = lane.upperBound - lane.lowerBound
        if browser.duo.laneLeading.constant != lane.lowerBound { browser.duo.laneLeading.constant = lane.lowerBound }
        if browser.duo.laneWidth.constant != width { browser.duo.laneWidth.constant = width }
    }

    private var armedClose = false
    private var armedTakeOver = false

    /// The side that would go answers: the pane turns see-through, or the page dims, and the
    /// handle takes the accent.
    private func setArmed(close: Bool, takeOver: Bool) {
        guard close != armedClose || takeOver != armedTakeOver, let pane else { return }
        armedClose = close
        armedTakeOver = takeOver
        handle.isArmed = close || takeOver
        Motion.animate(Motion.sidePaneArm, changes: { [veil] in
            pane.view.alpha = close ? 0.55 : 1
            veil.alpha = takeOver ? 1 : 0
        })
    }

    /// Where a cancelled drag goes: back to the rest it left.
    private func restingOutcome() -> SidePaneDividerOutcome {
        guard let browser else { return .rest(.narrow) }
        return browser.sidePaneUI.takesOver ? .takeOver : .rest(browser.sidePaneUI.restWidth)
    }

    // MARK: Settle

    /// Moves the divider to `outcome` (a release, a double tap, the menu, a key, VoiceOver, the
    /// expand button): one spring from where it is, with `velocity` (pt/s along x). The growing
    /// side gets its new frame as it starts, the shrinking side as it ends.
    func settle(to outcome: SidePaneDividerOutcome, velocity: CGFloat = 0, flicked: Bool = false) {
        guard let browser, let geometry, let pane else { return }
        let signposter = Signposts.signposter
        if let settleInterval { signposter.endInterval(Signposts.sidePaneSettle, settleInterval, "replaced") }
        settleInterval = signposter.beginInterval(Signposts.sidePaneSettle, id: signposter.makeSignpostID(), "\(Self.name(outcome))")
        let span = geometry.span
        let restWidth: CGFloat? = switch outcome {
        case .rest(let width): geometry.rests.count == 1 ? geometry.rests[0].paneWidth : geometry.rest(for: width).paneWidth
        case .close: 0
        case .takeOver: nil
        }
        let targetX = restWidth.map { geometry.dividerX(paneWidth: $0) } ?? span.lowerBound
        let currentX = browser.sidePaneUI.dragColumn?.minX ?? browser.duo.layout?.sidePaneColumn?.minX ?? targetX
        // The page's width after: the span less the pane (a split keeps its panes; with the whole
        // width the page keeps its frame out of sight).
        let pageFrame = browser.panes.view.frame
        let pageAfter: CGFloat? = switch outcome {
        case .close: span.upperBound - span.lowerBound
        case .takeOver: nil
        case .rest: browser.duo.layout?.sidePaneCoversSecondPane == true ? nil : targetX - span.lowerBound
        }
        let pageGrows = pageAfter.map { $0 > pageFrame.width + 0.5 } ?? false
        let paneGrows = span.upperBound - targetX > pane.contentWidthNow + 0.5
        pending = Pending(outcome: outcome, commitsPage: true, commitsPane: true)
        if outcome == .close {
            // Closing is one motion: the page takes its width under the leaving pane at once.
            browser.sidePaneWillCloseFromDivider()
            commitPage(outcome)
        } else if pageGrows {
            commitPage(outcome)
        }
        if paneGrows, outcome != .close { commitPane() }
        handle.state = .resting
        setArmed(close: false, takeOver: outcome == .takeOver && armedTakeOver)
        let spring = Motion.sidePaneSettle(flicked: flicked)
        let finish: () -> Void = { [weak self] in self?.finish() }
        let frame = { [weak self] (x: CGFloat) in
            guard let self else { return }
            apply(x: x, takeOverArmed: outcome == .takeOver)
        }
        if Motion.prefersCrossfade {
            Motion.crossfade(browser.view) { [weak self] in
                self?.driver.jump(to: targetX)
                frame(targetX)
                finish()
            }
            return
        }
        driver.jump(to: currentX)
        driver.animate(to: targetX, velocity: velocity, spring: spring, in: browser.view, onFrame: frame, completion: finish)
    }

    /// The settle reached its rest: what it still owes is committed and the moving parts go.
    private func finish() {
        guard let browser, let pending else { return }
        // What is still owed (the commits clear their flags in `self.pending`).
        commitPage(pending.outcome)
        if pending.outcome == .close {
            browser.sidePaneDidCloseFromDivider()
        } else {
            commitPane()
        }
        self.pending = nil
        endMove()
        if let settleInterval {
            Signposts.signposter.endInterval(Signposts.sidePaneSettle, settleInterval)
            self.settleInterval = nil
        }
        if pending.outcome != .close {
            Signposts.signposter.emitEvent(Signposts.sidePaneWidth, "\(Self.name(pending.outcome))")
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
        #if DEBUG
        meter?.report()
        meter = nil
        #endif
    }

    /// The page's frames and the layout take `outcome` (one layout pass for the page's web views).
    private func commitPage(_ outcome: SidePaneDividerOutcome) {
        guard let browser, pending?.commitsPage == true else { return }
        pending?.commitsPage = false
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.sidePaneCommit, id: signposter.makeSignpostID(), "page")
        switch outcome {
        case .rest(let width):
            // A split's one rest is the split line: the window's own width stays as it was.
            if browser.duo.layout?.sidePaneCoversSecondPane != true { browser.sidePaneUI.restWidth = width }
            browser.sidePaneUI.takesOver = false
        case .takeOver:
            browser.sidePaneUI.takesOver = true
        case .close:
            break
        }
        browser.updateDuoLayout()
        if outcome == .takeOver { browser.expandChrome(animated: true) }
        // The settle still moves the bar: it keeps following the divider until the end.
        browser.view.layoutIfNeeded()
        signposter.endInterval(Signposts.sidePaneCommit, interval)
    }

    /// The pane's content takes the column's width (one layout pass for the section).
    private func commitPane() {
        guard let pane, pending?.commitsPane == true else { return }
        pending?.commitsPane = false
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.sidePaneCommit, id: signposter.makeSignpostID(), "pane")
        pane.unfreezeContent()
        browser?.view.layoutIfNeeded()
        signposter.endInterval(Signposts.sidePaneCommit, interval)
    }

    /// Back to rest: the layout places everything again.
    private func endMove() {
        guard let browser else { return }
        browser.sidePaneUI.dragColumn = nil
        browser.sidePaneUI.revealsPage = false
        pane?.unfreezeContent()
        pane?.view.alpha = 1
        fill.isHidden = true
        veil.alpha = 0
        armedClose = false
        armedTakeOver = false
        handle.isArmed = false
        handle.state = .resting
        geometry = nil
        barSpansPane = false
        if let layout = browser.duo.layout {
            setLane(layout.chromeLane)
            #if DEBUG
            if SidePaneDividerMeter.resizesLive {
                browser.duo.panesTrailing.constant = (layout.sidebarOnRight ? -layout.sidebarDockWidth : 0) - layout.sidePaneDockWidth
            }
            #endif
        }
        browser.view.setNeedsLayout()
        browser.view.layoutIfNeeded()
        browser.updatePageInsets()
        browser.updateButtons()
        browser.saveSidePaneState()
    }

    /// Stops a drag or settle where it is and puts everything at the window's state at once: the
    /// pane closing, a fold or a rotation.
    func cancel() {
        guard isActive || pending != nil else { return }
        if drag != nil {
            drag = nil
            pan.isEnabled = false
            pan.isEnabled = true
            if let dragInterval { Signposts.signposter.endInterval(Signposts.sidePaneDrag, dragInterval, "cancelled") }
            dragInterval = nil
        }
        driver.stop()
        if let settleInterval { Signposts.signposter.endInterval(Signposts.sidePaneSettle, settleInterval, "cancelled") }
        settleInterval = nil
        pending = nil
        #if DEBUG
        meter = nil
        #endif
        endMove()
    }

    // MARK: Taps, menu, keys, VoiceOver

    /// Double tap on the handle: back to the opening width (AppKit's double click on a split's
    /// divider restores the ideal width). Already there, nothing to do.
    @objc private func doubleTapped() {
        guard let browser, browser.sidePaneDividerMayAct, let layout = browser.duo.layout,
              let divider = layout.sidePaneDivider else { return }
        let atDefault = !layout.sidePaneTakesOver && (divider.rests.count == 1 || browser.sidePaneUI.restWidth == .narrow)
        if atDefault {
            Haptic.nothingThere.play(in: handle)
            handle.bump()
            return
        }
        move(to: .rest(divider.rests.count == 1 ? divider.rests[0].width : .narrow))
    }

    /// Moves to `outcome` from rest, without a finger (the menu, a key, VoiceOver, the button).
    func move(to outcome: SidePaneDividerOutcome) {
        guard let browser, let layout = browser.duo.layout, layout.sidePaneDivider != nil else { return }
        if driver.isRunning {
            driver.stop()
            pending = nil
        } else {
            geometry = nil
        }
        prepareMove(layout: layout)
        if outcome == .takeOver { setArmed(close: false, takeOver: true) }
        settle(to: outcome)
    }

    /// One step wider or narrower (VoiceOver's adjust, the keyboard). false at the end.
    @discardableResult
    func step(wider: Bool) -> Bool {
        guard let browser, browser.sidePaneDividerMayAct, let divider = browser.duo.layout?.sidePaneDivider,
              let next = SidePaneDividerStep.step(
                  from: browser.sidePaneUI.restWidth, takesOver: browser.sidePaneUI.takesOver, wider: wider, geometry: divider
              ) else { return false }
        Haptic.withoutFeedback { move(to: next.takesOver ? .takeOver : .rest(next.width)) }
        return true
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let browser, browser.sidePaneDividerMayAct, let layout = browser.duo.layout,
              let divider = layout.sidePaneDivider else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self, weak browser] _ in
            guard let browser else { return nil }
            var items: [UIMenuElement] = []
            let takesOver = layout.sidePaneTakesOver
            if divider.rests.count > 1 {
                let shown = divider.rest(for: browser.sidePaneUI.restWidth).width
                for rest in divider.rests {
                    let item = UIAction(title: rest.width.title) { _ in self?.move(to: .rest(rest.width)) }
                    item.state = !takesOver && rest.width == shown ? .on : .off
                    item.accessibilityIdentifier = "menu.sidePaneWidth.\(rest.width.rawValue)"
                    items.append(item)
                }
            } else {
                let beside = UIAction(title: String(localized: "Beside the Page")) { _ in
                    self?.move(to: .rest(divider.rests[0].width))
                }
                beside.state = takesOver ? .off : .on
                beside.accessibilityIdentifier = "menu.sidePaneWidth.beside"
                items.append(beside)
            }
            let full = UIAction(title: String(localized: "Full Width")) { _ in self?.move(to: .takeOver) }
            full.state = takesOver ? .on : .off
            full.accessibilityIdentifier = "menu.sidePaneWidth.full"
            items.append(full)
            let hide = UIAction(title: String(localized: "Hide Side Pane"), image: UIImage(systemName: "sidebar.trailing")) {
                [weak browser] _ in browser?.closeSidePane(animated: true)
            }
            hide.accessibilityIdentifier = "menu.sidePaneWidth.hide"
            return UIMenu(children: [UIMenu(options: .displayInline, children: items), hide])
        }
    }

    // MARK: Pointer (iPad, a trackpad or mouse)

    func pointerInteraction(
        _ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest, defaultRegion: UIPointerRegion
    ) -> UIPointerRegion? {
        guard browser?.sidePaneDividerMayAct == true || isActive else { return nil }
        return UIPointerRegion(rect: stripView.bounds, identifier: "sidePane.divider")
    }

    /// A short vertical beam held to the seam: the pointer reads as the divider's grip.
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(shape: .verticalBeam(length: 32), constrainedAxes: .horizontal)
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction, willEnter region: UIPointerRegion, animator: any UIPointerInteractionAnimating
    ) {
        animator.addAnimations { [handle] in handle.isHovered = true }
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction, willExit region: UIPointerRegion, animator: any UIPointerInteractionAnimating
    ) {
        animator.addAnimations { [handle] in handle.isHovered = false }
    }

    // MARK: Gesture rules

    /// Only touches that start on the strip, while the divider may move (or is settling).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let browser, !strip.isNull, browser.sidePaneDividerMayAct || driver.isRunning else { return false }
        return strip.contains(touch.location(in: browser.view))
    }

    /// Sideways only: a page or list scrolled up or down near the seam still scrolls.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let browser else { return false }
        let velocity = pan.velocity(in: browser.view)
        return abs(velocity.x) > abs(velocity.y)
    }

    /// The page's and the pane's own pans that start on the strip wait for the divider to decide.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        guard let browser, other !== pan, other is UIPanGestureRecognizer, !(other is UIScreenEdgePanGestureRecognizer),
              let view = other.view, view.isDescendant(of: browser.view) else { return false }
        return strip.contains(other.location(in: browser.view))
    }

    private static func name(_ outcome: SidePaneDividerOutcome) -> String {
        switch outcome {
        case .rest(let width): width.rawValue
        case .takeOver: "full"
        case .close: "close"
        }
    }
}

// MARK: - The browser's side

extension BrowserViewController {
    /// The expand button (and the handle's VoiceOver action): the pane takes the whole width, or
    /// gives the page back beside it at the window's width.
    func toggleSidePaneTakeOver() {
        guard sidePaneDividerMayAct, let divider = sidePaneUI.divider else { return }
        divider.move(to: sidePaneUI.takesOver ? .rest(sidePaneUI.restWidth) : .takeOver)
    }

    /// The page is wanted (a match tapped in Find): with the whole width, the pane gives the page
    /// back beside it.
    func showPageBesideSidePane() {
        guard sidePaneUI.isRequested, sidePaneUI.takesOver, sidePaneDividerMayAct else { return }
        sidePaneUI.divider?.move(to: .rest(sidePaneUI.restWidth))
    }

    /// A link in the pane's Reader or a History row: it opens in the page, which comes back
    /// beside the pane if the pane had the whole width.
    func openFromSidePane(_ url: URL) {
        showPageBesideSidePane()
        load(url)
    }

    /// What shows past the page's edge while it grows under the divider: its own background (what
    /// WebKit shows past the page's end), else paper.
    var sidePanePageBackground: UIColor {
        guard let tab = currentTab, let webView = session.pool.webView(for: tab) else { return Palette.background }
        return webView.underPageBackgroundColor ?? webView.backgroundColor ?? Palette.background
    }

    /// The divider closes the pane: the window's state says closed, Find's marks come off, and the
    /// page takes its width under the leaving pane (`SidePaneDividerController.settle`).
    func sidePaneWillCloseFromDivider() {
        let signposter = Signposts.signposter
        sidePaneUI.closeInterval = signposter.beginInterval(Signposts.sidePaneClose, id: signposter.makeSignpostID(), "divider")
        sidePaneUI.controller?.paneWillHide()
        sidePaneUI.isRequested = false
        sidePaneUI.takesOver = false
        saveSidePaneState()
    }

    /// The pane has left: it hides, and the bar and the page menu follow.
    func sidePaneDidCloseFromDivider() {
        sidePaneUI.controller?.view.isHidden = true
        sidePaneUI.controller?.view.alpha = 1
        if let interval = sidePaneUI.closeInterval {
            Signposts.signposter.endInterval(Signposts.sidePaneClose, interval)
            sidePaneUI.closeInterval = nil
        }
    }

    /// A hardware keyboard (any iPhone, the iPad): Control-Command-S shows or hides the pane,
    /// Control-Command-] and -[ step its width (Narrow, Half, Two Thirds, Full Width and back).
    /// Keys play no haptics (docs/ui-reference.md, "Haptics", rule 8).
    func sidePaneKeyCommands() -> [UIKeyCommand] {
        guard duo.layout?.sidePaneAvailable == true, !isEditingAddress, !isShowingGallery,
              presentedViewController == nil else { return [] }
        let title = sidePaneUI.isRequested ? String(localized: "Hide Side Pane") : String(localized: "Show Side Pane")
        var commands = [UIKeyCommand(title: title, action: #selector(sidePaneKeyToggle), input: "s", modifierFlags: [.control, .command])]
        if sidePaneDividerMayAct {
            commands.append(UIKeyCommand(
                title: String(localized: "Wider Side Pane"), action: #selector(sidePaneKeyWider), input: "]",
                modifierFlags: [.control, .command]
            ))
            commands.append(UIKeyCommand(
                title: String(localized: "Narrower Side Pane"), action: #selector(sidePaneKeyNarrower), input: "[",
                modifierFlags: [.control, .command]
            ))
        }
        return commands
    }

    @objc func sidePaneKeyToggle() {
        Haptic.withoutFeedback { toggleSidePane() }
    }

    @objc func sidePaneKeyWider() {
        sidePaneUI.divider?.step(wider: true)
    }

    @objc func sidePaneKeyNarrower() {
        sidePaneUI.divider?.step(wider: false)
    }
}

// MARK: - The strip and the handle

/// The strip on the seam: touches pass through it (the root view's pan takes them there) except
/// on the handle, and the pointer stops on it.
final class SidePaneDividerStrip: UIView {
    weak var handle: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, self.point(inside: point, with: event) else { return nil }
        if let handle, handle.frame.contains(point) { return handle }
        return event?.type == .hover ? self : nil
    }
}

/// The divider's handle: a short ink capsule on the seam's hairline, inside a 44 x 88 pt target.
/// It grows under the pointer and the finger, and takes the accent where letting go would close
/// the pane or hand it the whole width. VoiceOver adjusts it (wider, narrower) and reads the width.
final class SidePaneDividerHandle: UIView {
    enum State { case resting, dragging }

    private let pill = UIView()
    var onAdjust: ((Bool) -> Bool)?
    var onHide: (() -> Void)?
    var onToggleFullWidth: (() -> Void)?
    private var takesOver = false

    var state: State = .resting { didSet { if state != oldValue { restyle(animated: true) } } }
    var isHovered = false { didSet { if isHovered != oldValue { restyle(animated: false) } } }
    var isArmed = false { didSet { if isArmed != oldValue { restyle(animated: true) } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        pill.isUserInteractionEnabled = false
        pill.layer.cornerCurve = .continuous
        // A paper edge keeps the ink readable over the page as well as the pane.
        pill.layer.borderColor = Palette.background.cgColor
        pill.layer.borderWidth = 1
        addSubview(pill)
        isAccessibilityElement = true
        accessibilityIdentifier = "sidePane.divider"
        accessibilityLabel = String(localized: "Side Pane Width")
        accessibilityTraits = .adjustable
        restyle(animated: false)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.pill.layer.borderColor = Palette.background.resolvedColor(with: self.traitCollection).cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        placePill()
    }

    func update(value: String, takesOver: Bool) {
        if accessibilityValue != value { accessibilityValue = value }
        self.takesOver = takesOver
    }

    private var pillSize: CGSize {
        if isArmed || state == .dragging { return CGSize(width: 6, height: 52) }
        if isHovered { return CGSize(width: 6, height: 44) }
        return CGSize(width: 4, height: 36)
    }

    private func placePill() {
        let size = pillSize
        pill.bounds = CGRect(origin: .zero, size: size)
        pill.center = CGPoint(x: bounds.midX, y: bounds.midY)
        pill.layer.cornerRadius = size.width / 2
    }

    private func restyle(animated: Bool) {
        let color: UIColor = isArmed ? Palette.accent : (state == .dragging || isHovered ? .secondaryLabel : .tertiaryLabel)
        let changes = { [self] in
            pill.backgroundColor = color
            placePill()
        }
        if animated { Motion.animate(Motion.quick, changes: changes) } else { changes() }
    }

    /// Nothing to do (a double tap at the opening width): the pill gives a little and comes back.
    func bump() {
        guard !Motion.prefersCrossfade else { return }
        UIView.animate(Motion.quick, changes: { self.pill.transform = CGAffineTransform(scaleX: 1.5, y: 0.8) }) {
            UIView.animate(Motion.sidebarSettle(flicked: true)) { self.pill.transform = .identity }
        }
    }

    override func accessibilityIncrement() { _ = onAdjust?(true) }
    override func accessibilityDecrement() { _ = onAdjust?(false) }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            [
                UIAccessibilityCustomAction(name: takesOver ? String(localized: "Show Page") : String(localized: "Full Width")) {
                    [weak self] _ in
                    self?.onToggleFullWidth?()
                    return true
                },
                UIAccessibilityCustomAction(name: String(localized: "Hide Side Pane")) { [weak self] _ in
                    self?.onHide?()
                    return true
                },
            ]
        }
        set {}
    }
}

#if DEBUG
// MARK: - Measuring the drag (Debug builds, `-PlainMeasureDivider`)

/// Frame times while the divider moves, and the main thread's work per frame, logged as
/// `[plain-measure]` lines for the perf proof (docs/research/resizable-pane.md, "Measured").
/// `-PlainDividerLive` instead resizes the page's web view every frame, the way this avoids.
@MainActor
final class SidePaneDividerMeter {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-PlainMeasureDivider")
    static let resizesLive = ProcessInfo.processInfo.arguments.contains("-PlainDividerLive")
    private static let logger = Logger(subsystem: Signposts.subsystem, category: "measure")
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var intervals: [CFTimeInterval] = []
    private var work: [CFTimeInterval] = []
    private var nominal: CFTimeInterval = 1 / 120

    init?(view: UIView) {
        guard Self.isOn else { return nil }
        let link = CADisplayLink(target: Proxy(self), selector: #selector(Proxy.tick(_:)))
        link.preferredFrameRateRange = SpringDriver.frameRateRange
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    fileprivate func tick(_ link: CADisplayLink) {
        nominal = max(link.targetTimestamp - link.timestamp, 1 / 120)
        if last > 0 { intervals.append(link.timestamp - last) }
        last = link.timestamp
    }

    func record(work seconds: CFTimeInterval) { work.append(seconds) }

    func report() {
        link?.invalidate()
        link = nil
        guard !intervals.isEmpty else { return }
        let long = intervals.filter { $0 > nominal * 1.5 }.count
        let maxFrame = (intervals.max() ?? 0) * 1000
        let sortedWork = work.sorted()
        let p95 = sortedWork.isEmpty ? 0 : sortedWork[min(sortedWork.count - 1, Int(Double(sortedWork.count) * 0.95))] * 1000
        let maxWork = (sortedWork.last ?? 0) * 1000
        let mode = Self.resizesLive ? "live" : "frozen"
        Self.logger.notice("""
            [plain-measure] divider \(mode, privacy: .public) frames \(self.intervals.count) long \(long) \
            maxFrameMs \(String(format: "%.1f", maxFrame), privacy: .public) \
            workP95Ms \(String(format: "%.2f", p95), privacy: .public) workMaxMs \(String(format: "%.2f", maxWork), privacy: .public) \
            nominalMs \(String(format: "%.1f", self.nominal * 1000), privacy: .public)
            """)
    }

    private final class Proxy: NSObject {
        weak var meter: SidePaneDividerMeter?
        init(_ meter: SidePaneDividerMeter) { self.meter = meter }
        @objc func tick(_ link: CADisplayLink) { meter?.tick(link) }
    }
}
#endif
#endif
