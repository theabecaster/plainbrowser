#if canImport(UIKit)
import QuartzCore
import SwiftUI
import UIKit

/// Moves one value along a spring, frame by frame, from an update link tied to the view's display
/// and asking for 80–120 Hz (docs/plan.md, frame rate budget).
///
/// For motion the user can grab mid-flight: `value` is always what is on screen (the caller applies
/// it in `onFrame`), so a gesture that starts during the motion takes over from it with no jump,
/// and a new target keeps the current velocity. Callers apply `value` with transform and alpha only.
public final class SpringDriver {
    /// Big motion asks for the display's top rate; 80 is the floor before it reads as stutter.
    public static let frameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)

    /// The value on screen.
    public private(set) var value: CGFloat
    /// Where the running spring ends; equal to `value` at rest.
    public private(set) var target: CGFloat
    public var isRunning: Bool { link != nil }

    /// The running spring: the one given at init, or the one the last `animate` asked for.
    private var spring: Spring
    /// When set, the spring lands on its target once the value is within this distance of it and
    /// moves less than this a frame (the motion is visibly over), instead of after the
    /// spring's long sub-point tail. The jump to the target is below what the eye can see.
    private let restDistance: CGFloat?
    private let defaultSpring: Spring
    private var link: UIUpdateLink?
    private var origin: CGFloat = 0
    private var initialVelocity: CGFloat = 0
    private var startTime: TimeInterval = 0
    private var duration: TimeInterval = 0
    private var lastTime: TimeInterval = 0
    private var onFrame: ((CGFloat) -> Void)?
    private var completion: (() -> Void)?

    /// - Parameter restDistance: lands on the target, and completes, once the motion is visibly
    ///   over (see `restDistance`); nil runs the spring to its full settle.
    public init(spring: Spring, value: CGFloat = 0, restDistance: CGFloat? = nil) {
        self.spring = spring
        self.defaultSpring = spring
        self.restDistance = restDistance
        self.value = value
        self.target = value
    }

    /// The current velocity, in value units per second.
    public var velocity: CGFloat {
        guard isRunning else { return 0 }
        return spring.velocity(target: target - origin, initialVelocity: initialVelocity, time: lastTime - startTime)
    }

    /// Springs from the on-screen value to `target`. Called while running, it retargets from where
    /// the value is, keeping the current velocity unless `velocity` is given.
    ///
    /// - Parameters:
    ///   - velocity: the starting velocity in value units per second (a gesture's release).
    ///   - spring: this motion's spring, when it is not the driver's own (a calmer exit than the
    ///     snap, for example). A retarget starts from the current velocity either way.
    ///   - view: the view whose display paces the frames.
    ///   - onFrame: applies a value; runs once per frame, and once with `target` at the end.
    ///   - completion: runs when the spring settles (or comes to rest, with `restDistance`), not
    ///     when it is stopped or retargeted.
    ///
    /// Under Reduce Motion, or with the view off screen, the value jumps to `target`; under Reduce
    /// Motion the caller wraps the call in `Motion.crossfade`.
    public func animate(
        to target: CGFloat, velocity: CGFloat? = nil, spring: Spring? = nil, in view: UIView,
        onFrame: @escaping (CGFloat) -> Void, completion: (() -> Void)? = nil
    ) {
        let now = CACurrentMediaTime()
        let startVelocity = velocity ?? self.velocity(at: now)
        self.spring = spring ?? defaultSpring
        self.onFrame = onFrame
        self.completion = completion
        guard !Motion.prefersCrossfade, view.window != nil, target != value || startVelocity != 0 else {
            finish(at: target)
            return
        }
        origin = value
        self.target = target
        initialVelocity = startVelocity
        startTime = now
        lastTime = now
        duration = self.spring.settlingDuration(target: target - origin, initialVelocity: startVelocity, epsilon: 0.001)
        if link == nil {
            let link = UIUpdateLink(view: view)
            link.addAction { [weak self] _, info in self?.step(to: info.modelTime) }
            link.preferredFrameRateRange = Self.frameRateRange
            link.requiresContinuousUpdates = true
            link.isEnabled = true
            self.link = link
        }
    }

    /// Stops where the value is now and returns it. The completion does not run.
    @discardableResult
    public func stop() -> CGFloat {
        endLink()
        target = value
        onFrame = nil
        completion = nil
        return value
    }

    /// Sets the value without motion, stopping a running spring. Nothing is called back.
    public func jump(to value: CGFloat) {
        stop()
        self.value = value
        target = value
    }

    private func velocity(at time: TimeInterval) -> CGFloat {
        guard isRunning else { return 0 }
        return spring.velocity(target: target - origin, initialVelocity: initialVelocity, time: time - startTime)
    }

    private func step(to time: TimeInterval) {
        let previousTime = lastTime
        lastTime = max(time, startTime)
        let elapsed = lastTime - startTime
        guard elapsed < duration else {
            finish(at: target)
            return
        }
        let next = origin + spring.value(target: target - origin, initialVelocity: initialVelocity, time: elapsed)
        if let restDistance, elapsed > 0, abs(target - next) <= restDistance {
            // Moving less than `restDistance` a frame, from the spring's own velocity over this
            // frame's interval (at least a 120 Hz frame): a sample that repeats a time, or a start
            // near the target with a flick's velocity, never reads as rest.
            let frame = max(lastTime - previousTime, Self.shortestFrame)
            let speed = abs(spring.velocity(target: target - origin, initialVelocity: initialVelocity, time: elapsed))
            if speed * frame <= restDistance {
                finish(at: target)
                return
            }
        }
        value = next
        onFrame?(value)
    }

    /// The top rate's frame (`frameRateRange`), the shortest interval a rest check assumes.
    private static let shortestFrame: TimeInterval = 1 / 120

    private func finish(at target: CGFloat) {
        endLink()
        value = target
        self.target = target
        let onFrame = self.onFrame
        let completion = self.completion
        self.onFrame = nil
        self.completion = nil
        onFrame?(target)
        completion?()
    }

    private func endLink() {
        link?.isEnabled = false
        link = nil
    }
}
#endif
