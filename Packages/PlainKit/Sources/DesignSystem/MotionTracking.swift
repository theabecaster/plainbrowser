#if canImport(UIKit)
import SwiftUI

extension Motion {
    /// A finger moving something 1:1 (a card being flicked, a page pulled toward the gallery).
    /// Each gesture update animates with it, so the spring that ends the gesture starts with the
    /// finger's velocity (WWDC24, "Enhance your UI animations and transitions").
    public static let tracking = Animation.interactiveSpring(duration: 0.12)
}
#endif
