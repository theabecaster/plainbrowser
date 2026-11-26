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
    /// Toolbar snaps collapsed or expanded when a scroll ends.
    public static let toolbarSnap = Animation.smooth(duration: 0.25)
    /// Tab switch by bar swipe (M2), with the gesture's velocity.
    public static let tabSwitch = Animation.spring(duration: 0.35, bounce: 0.12)
    /// Page zooms into its card in the tab gallery (M2).
    public static let galleryZoom = Animation.spring(duration: 0.42, bounce: 0)
    /// A thrown card closing (M2).
    public static let throwClose = Animation.spring(duration: 0.3, bounce: 0.15)
    /// Cards reflowing after a close (M2).
    public static let reflow = Animation.snappy(duration: 0.3)
    /// The Reduce Motion replacement for any movement.
    public static let crossfadeDuration: TimeInterval = 0.2

    /// Whether movement should become a crossfade. Read live: the user can change it any time.
    public static var prefersCrossfade: Bool { UIAccessibility.isReduceMotionEnabled }

    /// Runs `changes` with `animation`. Under Reduce Motion the changes instead apply at once
    /// inside a 0.2 s crossfade of `view` (the container whose contents move), so nothing slides.
    /// Without a `view`, Reduce Motion gets a plain 0.2 s ease instead of the spring.
    public static func animate(
        _ animation: Animation,
        crossfading view: UIView? = nil,
        changes: @escaping () -> Void,
        completion: (() -> Void)? = nil
    ) {
        if prefersCrossfade, let view {
            UIView.transition(
                with: view, duration: crossfadeDuration,
                options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState],
                animations: changes,
                completion: { _ in completion?() }
            )
        } else if prefersCrossfade {
            UIView.animate(Animation.easeInOut(duration: crossfadeDuration), changes: changes, completion: completion)
        } else {
            UIView.animate(animation, changes: changes, completion: completion)
        }
    }
}
#endif
