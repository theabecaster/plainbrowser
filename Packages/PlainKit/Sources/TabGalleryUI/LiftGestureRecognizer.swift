#if canImport(UIKit)
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// The finger on a gallery card, measured from the moment it touched down: it begins as soon as
/// the finger has moved `CardSwipe.lockDistance` points in a lift's direction (`CardSwipe.isLift`)
/// and fails at once in any other, so a sideways move goes to the gallery's scroll.
///
/// Not a `UIPanGestureRecognizer`: a pan begins only after about 10–25 pt of travel, and its
/// translation starts there, so a card dragged by one stayed that far behind the finger and a
/// short flick (over in one or two touch events) never moved it (docs/research/tab-drag-feel.md).
/// Here the translation and velocity are the finger's own, in `space`'s coordinates.
@MainActor
final class LiftGestureRecognizer: UIGestureRecognizer {
    /// The view whose coordinates `translation` and `velocity` are in (the card).
    weak var space: UIView?

    private weak var tracked: UITouch?
    private var start: CGPoint = .zero
    private var current: CGPoint = .zero
    /// Recent positions with their times, for the velocity.
    private var samples: [(time: TimeInterval, point: CGPoint)] = []

    /// The finger's travel since it touched down.
    var translation: CGPoint { CGPoint(x: current.x - start.x, y: current.y - start.y) }

    /// The finger's speed over its last `velocityWindow`, in points per second; zero when it has
    /// stopped for longer than that.
    var velocity: CGPoint {
        guard let last = samples.last, let first = samples.first(where: { last.time - $0.time <= Self.velocityWindow }),
              last.time > first.time else { return .zero }
        let dt = last.time - first.time
        return CGPoint(x: (last.point.x - first.point.x) / dt, y: (last.point.y - first.point.y) / dt)
    }

    /// The span the release velocity is measured over: UIKit's own pan uses about this much.
    private static let velocityWindow: TimeInterval = 0.08

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracked == nil, let touch = touches.first else {
            // A second finger: this is not a lift.
            if state == .possible { state = .failed }
            return
        }
        tracked = touch
        start = location(of: touch)
        current = start
        samples = [(touch.timestamp, start)]
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = tracked, touches.contains(touch) else { return }
        for sample in event.coalescedTouches(for: touch) ?? [touch] { record(sample) }
        switch state {
        case .possible:
            let travel = translation
            guard hypot(travel.x, travel.y) >= CardSwipe.lockDistance else { return }
            state = CardSwipe.isLift(velocity: travel) ? .began : .failed
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = tracked, touches.contains(touch) else { return }
        record(touch)
        if state == .began || state == .changed {
            // A finger that rested before lifting has no earlier sample in the window: no throw.
            state = .ended
        } else {
            state = .failed
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = tracked, touches.contains(touch) else { return }
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        tracked = nil
        samples.removeAll(keepingCapacity: true)
        start = .zero
        current = .zero
    }

    private func record(_ touch: UITouch) {
        current = location(of: touch)
        samples.append((touch.timestamp, current))
        // Only the recent past matters.
        if let last = samples.last?.time { samples.removeAll { last - $0.time > Self.velocityWindow * 2 } }
    }

    private func location(of touch: UITouch) -> CGPoint {
        touch.location(in: space ?? view)
    }
}
#endif
