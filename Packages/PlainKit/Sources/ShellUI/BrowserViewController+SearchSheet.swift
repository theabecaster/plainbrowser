#if canImport(UIKit)
import BrowserCore
import DesignSystem
import os
import PerfSignposts
import UIKit

/// The search sheet's open and close (docs/research/arc-address-expand.md).
final class SearchSheetUIState: NSObject, UIGestureRecognizerDelegate {
    /// The same drag, begun on the field itself (the pill floats over the card).
    let fieldPan = UIPanGestureRecognizer()
    var fieldPanMayBegin: (UIPanGestureRecognizer) -> Bool = { _ in false }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        return fieldPanMayBegin(pan)
    }

    /// 0 closed (the resting pill), 1 open. Always what is on screen.
    let driver = SpringDriver(spring: Motion.searchSheet, restDistance: 0.001)
    /// The pill is laid out as the open sheet's field (and the sheet is in the view): from the
    /// first frame of an open to the last frame of a close.
    var isLaidOutOpen = false
    /// The resting pill's frame, in the root view: where the field comes from and goes back to.
    /// Nil until the resting layout was seen (a launch straight into search).
    var rest: CGRect?
    /// The open field's frame, as last laid out.
    var open = CGRect.zero
    var style = SheetPlacement.Style.sheet
    /// How far the sheet rides (`.sheet`): the field's travel between rest and open.
    var travel: CGFloat = 0
    /// The bar's shape (beside the pill or under it) held while the sheet has the pill: the shape
    /// it had at rest when the sheet opened, then the one it will rest in, measured when a close
    /// or a drag starts. Nil at rest.
    var barBeside: Bool?
    /// True while the resting layout is being measured (two passes, nothing shown).
    var isMeasuring = false
    /// The progress when a finger took the sheet.
    var dragStart: CGFloat = 1
    var dragInterval: OSSignpostIntervalState?
    var morphInterval: OSSignpostIntervalState?
    /// A release's velocity (progress per second) for the close it started.
    var releaseVelocity: CGFloat?
    /// Counts Reduce Motion crossfades, so only the newest one finishes a close.
    var crossfades = 0
}

// MARK: - The search sheet: the pill grows into it

/// One spring, one progress value. On a phone (and the Duo's outer screen) the bottom bar grows
/// into a sheet: the pill rides up to the sheet's top and becomes the field, the card rides with
/// it, the bar's buttons ride up and fade, the page stays sharp and dims. Under a top bar (the
/// Duo's inner screen) the pill stays in the bar and the card grows down from it. Everything is
/// laid out open before the first frame; the progress only moves, scales and fades.
extension BrowserViewController {
    /// The open field's top, from the root view's top (`.sheet`).
    var searchFieldTop: CGFloat {
        SearchSheetGeometry.sheetTop(height: view.bounds.height, safeTop: view.safeAreaInsets.top)
            + SearchSheetGeometry.fieldInset
    }

    /// The pill's frame as laid out, whatever its transform, in the root view (`pillFrameGuide`).
    private var pillLayoutFrame: CGRect { pillFrameGuide.layoutFrame }

    /// The sheet's drag also starts on the field: a swipe down from the pill closes it too.
    func installSearchSheetGestures() {
        let ui = sheetUI
        ui.fieldPan.delegate = ui
        ui.fieldPan.addTarget(self, action: #selector(fieldPanned(_:)))
        ui.fieldPanMayBegin = { [weak self] pan in
            guard let self, self.isEditingAddress, self.sheetUI.style == .sheet else { return false }
            let velocity = pan.velocity(in: self.view)
            return velocity.y > 0 && velocity.y > abs(velocity.x)
        }
        pill.addGestureRecognizer(ui.fieldPan)
    }

    @objc private func fieldPanned(_ pan: UIPanGestureRecognizer) {
        searchSheetPanned(pan)
    }

    // MARK: Open and close

    /// Lays the sheet out open and grows it from the pill. Called with the mode already switched.
    func openSearchSheet(animated: Bool) {
        let ui = sheetUI
        ui.releaseVelocity = nil
        sheet.isHidden = false
        sheet.isUserInteractionEnabled = true
        // A toast would sit over the sheet's rows (Reopen over the closed tabs it offers).
        tabsUI.toast.hide(animated: animated)
        if !ui.isLaidOutOpen {
            // The resting pill as it is on screen now: where the field starts from.
            ui.rest = view.window == nil || view.bounds.isEmpty ? nil : pillLayoutFrame
            // The bar keeps its resting shape while it rides up and fades.
            ui.barBeside = buttonBar.isBesidePill
            ui.isLaidOutOpen = true
            ui.driver.jump(to: 0)
            updatePillRestConstraint()
            view.setNeedsLayout()
            // Before the first frame of the motion: the field, the card and the rows in place.
            if view.window != nil {
                UIView.performWithoutAnimation { view.layoutIfNeeded() }
            }
        }
        driveSearchSheet(to: 1, animated: animated && ui.rest != nil)
    }

    /// Shrinks the sheet back into the pill, then gives the pill back to the resting layout.
    func closeSearchSheet(animated: Bool) {
        let ui = sheetUI
        sheet.isUserInteractionEnabled = false
        // A finger still on the sheet no longer moves it: the close owns the motion now.
        if let interval = ui.dragInterval {
            Signposts.signposter.endInterval(Signposts.searchSheetDrag, interval, "closed")
            ui.dragInterval = nil
        }
        guard ui.isLaidOutOpen else {
            sheet.isHidden = true
            return
        }
        guard animated, view.window != nil else {
            ui.driver.jump(to: 0)
            finishClosingSearchSheet()
            return
        }
        // Where the pill will rest now: the page, the bar's shape or the screen may have changed
        // while the sheet was open.
        measureRestingPill()
        let velocity = ui.releaseVelocity
        ui.releaseVelocity = nil
        driveSearchSheet(to: 0, animated: true, velocity: velocity)
    }

    private func driveSearchSheet(to target: CGFloat, animated: Bool, velocity: CGFloat? = nil) {
        let ui = sheetUI
        let signposter = Signposts.signposter
        if let interval = ui.morphInterval {
            signposter.endInterval(Signposts.searchSheetMorph, interval, "retargeted")
            ui.morphInterval = nil
        }
        ui.crossfades += 1
        let finish = { [weak self] in
            guard let self else { return }
            if let interval = ui.morphInterval {
                signposter.endInterval(Signposts.searchSheetMorph, interval)
                ui.morphInterval = nil
            }
            // Only a close that was not turned around ends the open layout.
            if target == 0, !self.isEditingAddress { self.finishClosingSearchSheet() }
            if target == 1, self.isEditingAddress { self.searchSheetDidSettleOpen() }
        }
        guard animated, view.window != nil else {
            ui.driver.jump(to: target)
            applyFocusProgress(target)
            finish()
            return
        }
        let direction = target == 1 ? "open" : "close"
        ui.morphInterval = signposter.beginInterval(
            Signposts.searchSheetMorph, id: signposter.makeSignpostID(), "\(direction, privacy: .public)"
        )
        if Motion.prefersCrossfade {
            // Reduce Motion: the sheet crossfades to its place instead of growing.
            let crossfade = ui.crossfades
            ui.driver.jump(to: target)
            Motion.crossfade(view, changes: { self.applyFocusProgress(target) }, completion: {
                guard crossfade == ui.crossfades else { return }
                finish()
            })
            return
        }
        // From the first frame: the layout and the keyboard's start share this turn with the tap,
        // and the motion must not lose its first frames to them.
        ui.driver.animate(to: target, velocity: velocity, fromFirstFrame: true, in: view, onFrame: { [weak self] progress in
            self?.applyFocusProgress(progress)
        }, completion: finish)
    }

    /// The open is over: the field is at rest, so its text is selected now (during the motion a
    /// keystroke replaced it all the same) and the caret shows.
    private func searchSheetDidSettleOpen() {
        pill.holdSelectionHighlight(false)
        if let opened = focusUI.pendingSelection {
            focusUI.pendingSelection = nil
            if pill.textField.text == opened { pill.textField.selectAll(nil) }
        }
    }

    /// The close is over: the pill goes back to the resting layout, exactly where the motion
    /// left it, and the sheet leaves the screen.
    private func finishClosingSearchSheet() {
        let ui = sheetUI
        guard ui.isLaidOutOpen else { return }
        ui.isLaidOutOpen = false
        ui.driver.jump(to: 0)
        sheet.setProgress(0)
        sheet.isHidden = true
        // The next open starts from an empty list: its rows are there on its first frame, with
        // nothing of this search to crossfade from.
        sheet.clear()
        launchUI.frost.alpha = 0
        pill.setFocusProgress(0)
        pill.transform = .identity
        buttonBar.transform = .identity
        // The resting layout as measured, so nothing moves in this frame.
        updatePillRestConstraint()
        view.setNeedsLayout()
        UIView.performWithoutAnimation {
            view.layoutIfNeeded()
            restoreChromePlacement()
        }
        // The bar's shape changed since (a page committed during the close): it reflows now.
        ui.barBeside = nil
        updateBarShapeIfNeeded()
    }

    /// Reads where the pill rests now by laying the resting chrome out once and the open one
    /// again, in one turn, with nothing shown in between.
    private func measureRestingPill() {
        let ui = sheetUI
        guard ui.isLaidOutOpen, view.window != nil else { return }
        ui.isMeasuring = true
        // The shape the bar rests in, by the rules without the field (`restingBarBeside`).
        ui.barBeside = restingBarBeside
        UIView.performWithoutAnimation {
            ui.isLaidOutOpen = false
            updatePillRestConstraint()
            view.setNeedsLayout()
            view.layoutIfNeeded()
            ui.rest = pillLayoutFrame
            ui.isLaidOutOpen = true
            updatePillRestConstraint()
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
        ui.isMeasuring = false
        layOutSearchSheet()
    }

    // MARK: Layout

    /// Places the open sheet for the bounds, the lane and the pill as just laid out. Runs after
    /// every layout pass while the sheet is open (a rotation, a fold, the keyboard).
    func layOutSearchSheet() {
        let ui = sheetUI
        guard ui.isLaidOutOpen, !ui.isMeasuring, !view.bounds.isEmpty else { return }
        let open = pillLayoutFrame
        let bounds = view.bounds
        let placement: SheetPlacement
        if chromeOnTop {
            // The card around the field, down to the bottom edge; Cancel beside the field where
            // the row has room for it (the bar's trailing buttons have faded).
            let margin = SearchSheet.dropdownMargin
            let lane = duo.chromeLane.layoutFrame
            let clearance = duo.topGeometry?.rowClearance.trailing ?? 0
            let limit = min(lane.maxX - Spacing.m, bounds.width - clearance)
            let cancel = sheet.cancelWidth
            let showsCancel = open.maxX + cancel + margin <= limit + 0.5
            let top = max(0, open.minY - margin)
            placement = SheetPlacement(
                style: .dropdown,
                card: CGRect(
                    x: open.minX - margin, y: top, width: open.width + 2 * margin + (showsCancel ? cancel : 0),
                    height: bounds.height - top
                ),
                field: open, travel: 0, closedHeight: open.maxY + margin - top, showsCancel: showsCancel
            )
            ui.travel = 0
            // From a sheet (an unfold while open): nothing of its move stays on the bar.
            if ui.style == .sheet, buttonBar.superview != nil { restoreTopBarButtons() }
        } else {
            let row = chromeRow.layoutFrame
            let top = open.minY - SearchSheetGeometry.fieldInset
            let rest = ui.rest ?? open
            ui.travel = max(0, rest.minY - open.minY)
            placement = SheetPlacement(
                style: .sheet,
                card: CGRect(x: row.minX - Spacing.m, y: top, width: row.width + 2 * Spacing.m, height: bounds.height - top),
                field: open, travel: ui.travel, closedHeight: 0, showsCancel: false
            )
        }
        ui.open = open
        ui.style = placement.style
        sheet.place(placement)
        sheet.layoutIfNeeded()
        applyFocusProgress(ui.driver.value)
    }

    /// Places everything for `progress` (0 the resting pill, 1 the open sheet): transform and
    /// alpha only.
    func applyFocusProgress(_ progress: CGFloat) {
        let ui = sheetUI
        guard ui.isLaidOutOpen else { return }
        let p = min(max(progress, 0), 1)
        sheet.setProgress(p)
        launchUI.frost.alpha = p
        pill.setFocusProgress(p)
        pill.alpha = 1
        pill.isCompact = false
        let barAlpha = SearchSheetGeometry.barAlpha(progress: p)
        switch ui.style {
        case .dropdown:
            // The field widens in its row, from the pill between the bar's buttons.
            pill.transform = SearchSheetGeometry.transform(open: ui.open, rest: ui.rest ?? ui.open, progress: p)
            if buttonBar.superview != nil { buttonBar.alpha = barAlpha }
        case .sheet:
            pill.transform = SearchSheetGeometry.transform(open: ui.open, rest: ui.rest ?? ui.open, progress: p)
            guard buttonBar.superview != nil else { return }
            // The bar's buttons ride up with the sheet and fade (Arc Search).
            buttonBar.transform = CGAffineTransform(translationX: 0, y: -ui.travel * p)
            buttonBar.alpha = barAlpha
        }
    }

    /// Whether the bar rests beside the pill (the start screen's shape), by the rules without the
    /// open field: editing never has a bar shape of its own.
    var restingBarBeside: Bool {
        var state = rules.state
        state.isEditing = false
        return !chromeOnTop && ControlRules(state).barBesidePill && buttonBar.superview != nil
    }

    /// The bar's buttons back at their top bar place (the sheet's ride no longer applies).
    private func restoreTopBarButtons() {
        buttonBar.transform = .identity
    }

    // MARK: Dismissing

    /// The sheet was asked to close without going anywhere.
    func dismissSearchSheet(_ how: SearchSheet.Dismissal) {
        guard isEditingAddress else { return }
        Signposts.signposter.emitEvent(Signposts.searchSheetDismiss, "\(how.rawValue, privacy: .public)")
        // An untouched New Tab goes back to its page (`+Tabs`) first, so the sheet collapses
        // into that page's pill and bar, not the start screen's it is leaving.
        returnFromUntouchedNewTab(tabsUI.newTabReturn, untouched: (pill.textField.text ?? "").isEmpty)
        endEditing()
    }

    /// A finger on the sheet: the progress follows it down, and the release collapses the sheet
    /// or springs it back, with the finger's speed.
    func searchSheetPanned(_ pan: UIPanGestureRecognizer) {
        let ui = sheetUI
        let signposter = Signposts.signposter
        switch pan.state {
        case .began:
            guard isEditingAddress, ui.style == .sheet else { return }
            // Take the sheet from where it is on screen.
            ui.driver.stop()
            if let interval = ui.morphInterval {
                signposter.endInterval(Signposts.searchSheetMorph, interval, "grabbed")
                ui.morphInterval = nil
            }
            measureRestingPill()
            ui.dragStart = ui.driver.value
            ui.dragInterval = signposter.beginInterval(Signposts.searchSheetDrag, id: signposter.makeSignpostID())
        case .changed:
            guard ui.dragInterval != nil, isEditingAddress else { return }
            let progress = SearchSheetGeometry.progress(
                start: ui.dragStart, translation: pan.translation(in: view).y, travel: ui.travel
            )
            ui.driver.jump(to: progress)
            applyFocusProgress(progress)
        case .ended, .cancelled, .failed:
            guard let interval = ui.dragInterval, isEditingAddress else { return }
            ui.dragInterval = nil
            let velocity = pan.velocity(in: view).y
            let collapses = pan.state == .ended && ui.travel > 0
                && SearchSheetGeometry.collapses(progress: ui.driver.value, velocity: velocity)
            let outcome = collapses ? "collapsed" : "kept"
            signposter.endInterval(Signposts.searchSheetDrag, interval, "\(outcome, privacy: .public)")
            let progressVelocity = ui.travel > 0 ? -velocity / ui.travel : 0
            if collapses {
                // No haptic: the sheet's own motion says it collapsed.
                ui.releaseVelocity = progressVelocity
                dismissSearchSheet(.swipe)
            } else {
                driveSearchSheet(to: 1, animated: true, velocity: progressVelocity)
            }
        default:
            break
        }
    }

    // MARK: The field's options

    /// What sits at the field's trailing end now: Copy on the page's own address, the empty
    /// field's options (dictation, Browse for Me), or nothing (the clear button while typing).
    func updateFieldAccessory() {
        let text = pill.textField.text ?? ""
        let untouched = isEditingAddress && focusUI.intent == .pageAddress && !text.isEmpty
            && text == focusUI.openedAddress
        // VoiceOver reads the address as the field's value, then what typing does.
        pill.textField.accessibilityHint = !untouched ? nil : focusUI.selectsAllOnOpen
            ? String(localized: "Type to search in a new tab; edit to change this page")
            : String(localized: "Edit to change this page; clear it to search in a new tab")
        guard isEditingAddress else { return pill.setAccessory(.none) }
        if untouched { return pill.setAccessory(.copy) }
        let dictation = focusUI.dictation
        // Listening: the microphone stays, filled, whatever was heard so far.
        if dictation.isListening { return pill.setAccessory(.dictating) }
        let browse = session.summaries.isAvailable
        if !browse { focusUI.browseArmed = false }
        // Armed, Browse for Me stays in the field while typing, so what Return does is in sight.
        guard text.isEmpty || focusUI.browseArmed else { return pill.setAccessory(.none) }
        let mic = dictation.isAvailable && text.isEmpty
        guard mic || browse else { return pill.setAccessory(.none) }
        pill.setAccessory(.options(mic: mic, browse: browse, armed: focusUI.browseArmed))
    }

    /// The field's microphone: wires it once and finds out whether dictation can run here.
    func prepareDictation() {
        let dictation = focusUI.dictation
        dictation.onChange = { [weak self] in self?.updateFieldAccessory() }
        dictation.onText = { [weak self] text in
            guard let self, self.isEditingAddress else { return }
            self.pill.textField.text = text
            self.queryChanged()
        }
        dictation.prepare()
    }

    func toggleDictation() {
        let dictation = focusUI.dictation
        let option = dictation.isListening ? "micStop" : "mic"
        Signposts.signposter.emitEvent(Signposts.fieldOption, "\(option, privacy: .public)")
        Haptic.tap.play()
        dictation.toggle()
    }

    /// Browse for Me in the empty field: armed, Return browses for what is typed instead of
    /// searching; a second tap takes it back.
    func toggleBrowseArmed() {
        focusUI.browseArmed.toggle()
        let option = focusUI.browseArmed ? "browseArm" : "browseDisarm"
        Signposts.signposter.emitEvent(Signposts.fieldOption, "\(option, privacy: .public)")
        Haptic.selection.play()
        updateFieldAccessory()
    }
}
#endif
