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
    /// they stand, and a row that changes place crossfades there; nothing slides. An ease-out
    /// fade of this duration, not a spring: a spring's long tail leaves the old text faintly
    /// visible for a while. The next keystroke picks it up from what is on screen.
    public static let suggestionsDuration: TimeInterval = 0.18
    /// Toolbar snaps collapsed or expanded when a drag ends, from the release velocity. A spring
    /// value, not an `Animation`: `SpringDriver` runs it frame by frame so a new drag can grab it.
    public static let toolbarSnap = Spring.smooth(duration: 0.25)
    /// Tab switch by bar swipe (M2), with the gesture's velocity.
    public static let tabSwitch = Animation.spring(duration: 0.35, bounce: 0.12)
    /// The same spring as a value, for `SpringDriver`: the bar swipe runs frame by frame so a
    /// finger can grab the page mid-flight.
    public static let tabSwitchSpring = Spring(duration: 0.35, bounce: 0.12)
    /// Page zooms into its card in the tab gallery (M2).
    public static let galleryZoom = Animation.spring(duration: 0.42, bounce: 0)
    /// A thrown card closing (M2).
    public static let throwClose = Animation.spring(duration: 0.3, bounce: 0.15)
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
