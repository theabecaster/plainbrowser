#if canImport(UIKit)
import SwiftUI
import UIKit

/// Plain's one spring vocabulary (docs/plan.md, section 5, motion table). UIKit and SwiftUI use the
/// same `SwiftUI.Animation` values through `UIView.animate(_:changes:completion:)` (iOS 18), so a
/// spring started from a gesture inherits its velocity.
///
/// Rules: no bounce unless a flick drives the motion; nothing blocks input; under Reduce Motion
/// movement becomes a 0.2 s crossfade.
public enum Motion {
    /// URL bar grows into the search sheet. The table's `.snappy(duration: 0.3)` with bounce 0:
    /// `.snappy` carries 0.15 bounce of its own, so this is the same duration with none.
    public static let urlFocus = Animation.spring(duration: 0.3, bounce: 0)
    /// Small state changes: a row highlight, an armed indicator.
    public static let quick = Animation.snappy(duration: 0.15)
    /// Address-bar suggestions changing while typing: new rows fade in, old ones fade out where
    /// they stand, and a row that changes place crossfades there; nothing slides. A short linear
    /// crossfade, not a spring or an ease: the two opacities always add up to one, so a place
    /// never dims to empty between two texts, and they overlap for only a few frames (a spring's
    /// long tail left old text faintly visible). The next keystroke picks up from what is on
    /// screen.
    public static let suggestionFade: TimeInterval = 0.12
    /// Toolbar snaps collapsed or expanded when a drag ends, from the release velocity. A spring
    /// value, not an `Animation`: `SpringDriver` runs it frame by frame so a new drag can grab it.
    public static let toolbarSnap = Spring.smooth(duration: 0.25)
    /// The pill sinking away once the reader keeps scrolling: a calmer exit than the snap, so the
    /// chrome leaves without drawing the eye. Coming back uses `toolbarSnap`: it answers the user.
    public static let toolbarHide = Spring.smooth(duration: 0.35)
    /// Tab switch by bar swipe (M2), with the gesture's velocity. Damping 0.92: the page reaches
    /// the neighbour a touch quicker than the old 0.35 s / 0.12 spring (95% of the way in
    /// ~0.18 s, was ~0.21 s) and its overshoot stays under half a point, so it is at rest in
    /// ~0.26-0.30 s on any width (device target 320 ms with the hand-off). The old
    /// spring overshot 2–3 pt on the Duo's 951 pt inner page, or after a fast flick on any width,
    /// and crept back for ~0.2 s more (docs/research/perf-gallery-swipe.md).
    public static let tabSwitch = Animation.spring(duration: 0.28, bounce: 0.08)
    /// The same spring as a value, for `SpringDriver`: the bar swipe runs frame by frame so a
    /// finger can grab the page mid-flight.
    public static let tabSwitchSpring = Spring(duration: 0.28, bounce: 0.08)
    /// Back on a link-opened tab's first page: the tab slides off toward the trailing edge, as a
    /// page pops, uncovering its opener. A button drives it, so no bounce.
    public static let backToOpener = Animation.spring(duration: 0.35, bounce: 0)
    /// How far behind the leaving page the opener starts, as a share of the pane's width: the
    /// parallax of a navigation pop, so the opener reads as the page underneath.
    public static let backToOpenerParallax: CGFloat = 0.3
    /// Page zooms into its card in the tab gallery (M2). Damping 0.94, not 1: the same pace
    /// through the first half, the last few points land sooner, and the overshoot is a fifth of a
    /// point at most (none the eye can see). A critically damped spring creeps over its last
    /// half point for ~0.15 s (docs/research/perf-gallery-swipe.md).
    public static let galleryZoom = Animation.spring(duration: 0.42, bounce: 0.06)
    /// A thrown card closing (M2).
    public static let throwClose = Animation.spring(duration: 0.3, bounce: 0.15)
    /// The gallery bar's controls gliding to a re-centred row after one leaves or arrives (UX
    /// audit, 2026-11-27): short, no bounce, after the leaving control has faded.
    public static let barGlide = Animation.spring(duration: 0.3, bounce: 0)
    /// Cards reflowing after a close (M2).
    public static let reflow = Animation.snappy(duration: 0.3)
    /// Tab gallery cards closing a gap or making room, run frame by frame so a scroll or another
    /// close can join in mid-flight. Damping 0.9: the neighbors settle with the faintest give.
    public static let cardReflow = Spring(duration: 0.35, bounce: 0.1)
    /// A card that was swiped up but not far or fast enough springs back, with the release
    /// velocity. Slight bounce: momentum drives it (WWDC18, "Designing Fluid Interfaces").
    public static let cardReturn = Animation.spring(duration: 0.32, bounce: 0.12)
    /// The sidebar springing to Hidden, Rail or Expanded (M3): the tab switch's spring, with bounce
    /// only when a flick released it.
    public static func sidebarSettle(flicked: Bool) -> Animation {
        .spring(duration: 0.35, bounce: flicked ? 0.12 : 0)
    }
    /// The sidebar's edge under the finger: tracks 1:1 and hands its velocity to the settle.
    public static let sidebarTrack = Animation.interactiveSpring
    /// The Reduce Motion replacement for any movement.
    public static let crossfadeDuration: TimeInterval = 0.2

    /// Whether movement should become a crossfade. Read live: the user can change it any time.
    public static var prefersCrossfade: Bool { UIAccessibility.isReduceMotionEnabled }

    /// Runs `changes` with `animation`. Under Reduce Motion the changes instead apply at once
    /// inside a 0.2 s crossfade of `view` (the container whose contents move), so nothing slides.
    /// Without a `view`, Reduce Motion applies the changes at once, with no movement.
    public static func animate(
        _ animation: Animation,
        crossfading view: UIView? = nil,
        changes: @escaping () -> Void,
        completion: (() -> Void)? = nil
    ) {
        if prefersCrossfade, let view {
            crossfade(view, changes: changes, completion: completion)
        } else if prefersCrossfade {
            UIView.performWithoutAnimation(changes)
            completion?()
        } else {
            UIView.animate(animation, changes: changes, completion: completion)
        }
    }

    /// Applies `changes` at once inside a 0.2 s crossfade of `view`: the Reduce Motion form of a
    /// move, for motion that is not a `UIView` animation (a `SpringDriver`).
    public static func crossfade(_ view: UIView, changes: @escaping () -> Void, completion: (() -> Void)? = nil) {
        UIView.transition(
            with: view, duration: crossfadeDuration,
            options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState],
            animations: changes,
            completion: { _ in completion?() }
        )
    }
}
#endif
