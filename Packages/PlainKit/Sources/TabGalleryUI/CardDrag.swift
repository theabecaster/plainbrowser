#if canImport(UIKit)
import DesignSystem
import PerfSignposts
import SwiftUI
import UIKit

/// A gallery card lifted by a finger: the swipe up that closes a tab
/// (docs/research/tab-drag-feel.md).
///
/// Like the app switcher's cards: the card stays under the finger from the first frame it moves,
/// with no smoothing spring between them; it can be grabbed again mid-flight from where it is on
/// screen; the release is projected with the scroll view's deceleration and springs on with the
/// finger's velocity (`SpringDriver`, frame by frame).
///
/// It moves `body` (the card's content view) with its transform; the gallery owns the card's own
/// center and transform. Offsets are in the card's coordinates (the card may be scaled), so the
/// body moves exactly as far as the finger on screen.
@MainActor
final class CardDrag: NSObject, UIGestureRecognizerDelegate {
    let lift = LiftGestureRecognizer()
    /// The card was lifted far or fast enough to close.
    var onClose: (() -> Void)?

    private weak var body: UIView?
    /// The height a close is measured against: the card's page preview.
    private let closeHeight: () -> CGFloat
    /// The body's vertical offset on screen, in the card's coordinates (negative is up).
    private let driver = SpringDriver(spring: Motion.cardReturnSpring, restDistance: CGFloat(Signposts.visualSettle))
    /// Where the card was when the finger caught it, as finger travel (a card below its place is
    /// rubber-banded, so its offset is turned back into the travel that shows it), and the
    /// finger's travel when the lift began (the direction lock's few points, paid back over
    /// `CardSwipe.takeUp` so the card does not jump).
    private var startOffset: CGFloat = 0
    private var takeUp: CGFloat = 0
    /// The last release's velocity in pt/s (negative up), for a throw that follows it.
    private var releaseVelocity: CGFloat = 0

    init(body: UIView, closeHeight: @escaping () -> CGFloat) {
        self.body = body
        self.closeHeight = closeHeight
        super.init()
        lift.delegate = self
        // The card's coordinates, which the body moves in: measured in the body's own, the
        // finger would seem to move as the body follows it.
        lift.space = body.superview
        lift.addTarget(self, action: #selector(handle(_:)))
        body.addGestureRecognizer(lift)
    }

    /// A finger is moving the card, or it is still springing back.
    var isActive: Bool { lift.state == .began || lift.state == .changed || driver.isRunning }

    /// Back at rest with nothing running (the card goes back to the pool).
    func reset() {
        driver.jump(to: 0)
        releaseVelocity = 0
        apply(0)
    }

    /// Sends the body to `offset` with `spring`, carrying the last release's velocity, then calls
    /// `completion` (a closing card flying off the screen).
    func fly(to offset: CGFloat, spring: Spring, completion: @escaping () -> Void) {
        guard let body else { return completion() }
        let velocity = releaseVelocity
        releaseVelocity = 0
        driver.animate(to: offset, velocity: velocity, spring: spring, in: body, onFrame: { [weak self] in self?.apply($0) }, completion: completion)
    }

    // MARK: Gesture

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    @objc private func handle(_ gesture: LiftGestureRecognizer) {
        let translation = gesture.translation.y
        switch gesture.state {
        case .began:
            // Grabbed where it is on screen, even mid-spring.
            startOffset = CardSwipe.translation(forOffset: driver.stop(), cardHeight: closeHeight())
            takeUp = translation
            Haptic.close.prepare()
            set(offset(for: translation))
        case .changed:
            set(offset(for: translation))
        case .ended:
            release(at: offset(for: translation), velocity: gesture.velocity.y, canClose: true)
        case .cancelled, .failed:
            // Interrupted (a call, a system gesture): the card goes back, it never closes.
            release(at: offset(for: translation), velocity: 0, canClose: false)
        default:
            break
        }
    }

    /// The finger's travel, with the lock's few points taken up, as the card's offset: 1:1 up,
    /// rubber-banded down.
    private func offset(for translation: CGFloat) -> CGFloat {
        let travel = translation - takeUp * max(0, 1 - abs(translation - takeUp) / CardSwipe.takeUp)
        let raw = startOffset + travel
        return raw > 0 ? CardSwipe.offset(translation: raw, cardHeight: closeHeight()) : raw
    }

    private func set(_ offset: CGFloat) {
        driver.jump(to: offset)
        apply(offset)
    }

    private func release(at offset: CGFloat, velocity: CGFloat, canClose: Bool) {
        guard let body else { return }
        releaseVelocity = velocity
        if canClose, CardSwipe.shouldClose(translation: offset, velocity: velocity, cardHeight: closeHeight()) {
            onClose?()
            return
        }
        Signposts.signposter.emitEvent(Signposts.galleryCardKept)
        releaseVelocity = 0
        let back = { [weak self] in
            guard let self else { return }
            driver.animate(to: 0, velocity: velocity, in: body, onFrame: { [weak self] in self?.apply($0) })
        }
        if Motion.prefersCrossfade { Motion.crossfade(body, changes: back) } else { back() }
    }

    private func apply(_ offset: CGFloat) {
        guard let body else { return }
        let transform = CGAffineTransform(translationX: 0, y: offset)
        if body.transform != transform { body.transform = transform }
    }
}
#endif
