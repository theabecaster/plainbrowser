#if canImport(UIKit)
import SwiftUI
import UIKit

extension Motion {
    /// A finger moving something 1:1 (a card being flicked, a page pulled toward the gallery).
    /// Each gesture update animates with it, so the spring that ends the gesture starts with the
    /// finger's velocity (WWDC24, "Enhance your UI animations and transitions").
    public static let tracking = Animation.interactiveSpring(duration: 0.12)

    /// `throwClose` for a property animator that starts with a gesture's velocity (pt/s) over
    /// `distance` points: a thrown card that leaves its cell and flies on as a snapshot.
    public static func throwCloseTiming(distance: CGFloat, velocity: CGFloat) -> UISpringTimingParameters {
        let relative = distance != 0 ? velocity / distance : 0
        return UISpringTimingParameters(duration: 0.3, bounce: 0.15, initialVelocity: CGVector(dx: relative, dy: 0))
    }

    /// A card swiped up and away. Started right after `tracking`, it keeps the finger's velocity;
    /// no bounce, since it ends off screen.
    public static let cardThrow = Animation.spring(duration: 0.3, bounce: 0)
}
#endif
