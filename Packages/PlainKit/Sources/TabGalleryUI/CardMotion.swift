#if canImport(UIKit)
import DesignSystem
import SwiftUI
import UIKit

/// The gallery's frame-by-frame motion: cards sliding into a gap or out of the way, new cards
/// growing in, and the scroll position easing back after the content shrank.
///
/// Every value is a displacement that springs to zero (`Motion.cardReflow`). A new change adds to
/// what is still moving and keeps its velocity, so a second close during the first one never
/// jumps, and a scroll during the motion simply adds to it: the gallery recomputes each card from
/// its index, its displacement and the scroll offset on every frame. Only transforms and
/// positions change, never a layout pass.
@MainActor
final class CardMotion {
    private struct Value {
        var value: CGFloat
        var velocity: CGFloat = 0
    }

    /// Called on every frame the motion runs, after the values moved.
    var onFrame: (() -> Void)?

    private var slots: [UUID: Value] = [:]
    private var appear: [UUID: Value] = [:]
    private var shift = Value(value: 0)
    private var link: UIUpdateLink?
    /// Run when everything has settled (or was reset).
    private var settled: [() -> Void] = []
    private var lastTime: TimeInterval?
    private let spring = Motion.cardReflow

    var isRunning: Bool { link != nil }

    /// The card's displacement in slots: it shows at `index + slotOffset(id)`.
    func slotOffset(_ id: UUID) -> CGFloat {
        slots[id]?.value ?? 0
    }

    /// 0 while a card is about to grow in, 1 once it is in place.
    func appearance(_ id: UUID) -> CGFloat {
        appear[id].map { 1 + $0.value } ?? 1
    }

    /// Added to the scroll offset while it eases back to where the scroll view really is.
    var scrollShift: CGFloat { shift.value }

    var hasMovingCards: Bool { !slots.isEmpty || !appear.isEmpty }

    /// Each moving card's id with its current displacement.
    func forEachMovingCard(_ body: (UUID, CGFloat) -> Void) {
        for (id, value) in slots { body(id, value.value) }
        for (id, _) in appear where slots[id] == nil { body(id, 0) }
    }

    /// The card moved by `delta` slots in the list; it shows where it was and springs to its new place.
    func displace(_ id: UUID, by delta: CGFloat) {
        guard delta != 0 else { return }
        slots[id, default: Value(value: 0)].value += delta
    }

    /// The card is new: it grows in where it lands.
    func grow(_ id: UUID) {
        appear[id] = Value(value: -1)
    }

    /// The scroll offset jumped by `delta` points (the content got shorter); the cards stay put
    /// on screen and then ease to the new offset.
    func shiftScroll(by delta: CGFloat) {
        shift.value += delta
    }

    /// Drops a card's motion (it left the list).
    func forget(_ id: UUID) {
        slots[id] = nil
        appear[id] = nil
    }

    /// Stops everything where it should end.
    func reset() {
        slots.removeAll()
        appear.removeAll()
        shift = Value(value: 0)
        stop()
        finishSettled()
    }

    private func finishSettled() {
        let pending = settled
        settled.removeAll()
        for completion in pending { completion() }
    }

    /// Starts the frame loop if anything is displaced. Under Reduce Motion everything lands at
    /// once; the caller crossfades.
    func run(in view: UIView, completion: (() -> Void)? = nil) {
        if let completion { settled.append(completion) }
        guard !slots.isEmpty || !appear.isEmpty || shift.value != 0 else {
            if link == nil { finishSettled() }
            return
        }
        guard !Motion.prefersCrossfade, view.window != nil else {
            reset()
            onFrame?()
            return
        }
        guard link == nil else { return }
        let link = UIUpdateLink(view: view)
        link.addAction { [weak self] _, info in self?.step(to: info.modelTime) }
        link.preferredFrameRateRange = SpringDriver.frameRateRange
        link.requiresContinuousUpdates = true
        link.isEnabled = true
        self.link = link
        lastTime = nil
    }

    private func stop() {
        link?.isEnabled = false
        link = nil
        lastTime = nil
    }

    private func step(to time: TimeInterval) {
        // The first frame only takes the time: its delta would include the wait before it.
        let delta = lastTime.map { min(max(time - $0, 0), 1.0 / 30) } ?? 0
        lastTime = time
        advance(by: delta)
    }

    /// Runs the motion to its end in 120 Hz steps, without a display (tests).
    func settleForTesting() {
        var frames = 0
        while !slots.isEmpty || !appear.isEmpty || shift.value != 0, frames < 600 {
            advance(by: 1.0 / 120)
            frames += 1
        }
    }

    private func advance(by delta: TimeInterval) {
        if delta > 0 {
            for id in Array(slots.keys) {
                if let next = advance(slots[id]!, by: delta) { slots[id] = next } else { slots[id] = nil }
            }
            for id in Array(appear.keys) {
                if let next = advance(appear[id]!, by: delta) { appear[id] = next } else { appear[id] = nil }
            }
            shift = advance(shift, by: delta, epsilon: 0.25) ?? Value(value: 0)
        }
        onFrame?()
        if slots.isEmpty, appear.isEmpty, shift.value == 0 {
            stop()
            finishSettled()
        }
    }

    /// One frame of a spring toward zero; nil once it has settled.
    private func advance(_ current: Value, by delta: TimeInterval, epsilon: CGFloat = 0.002) -> Value? {
        var value = current.value
        var velocity = current.velocity
        spring.update(value: &value, velocity: &velocity, target: 0, deltaTime: delta)
        if abs(value) < epsilon, abs(velocity) < epsilon * 10 { return nil }
        return Value(value: value, velocity: velocity)
    }
}
#endif
