#if canImport(UIKit)
import UIKit

/// Plain's haptics (docs/ui-reference.md). Haptics follow the system setting, which UIKit's
/// generators already respect. Use them only on a threshold cross and on a commit.
public enum Haptic {
    /// A light tap for a committed action (a menu action that has no other visual result).
    case tap
    /// A selection tick: crossing a threshold while a finger still moves (pull to refresh arming).
    case selection
    /// A firmer cross: a gesture past its commit point (swiping past the last tab).
    case threshold
    /// Something worked that leaves nothing on screen (Copy Link).
    case success
    /// A soft bump when there is nothing to do (Return in an empty field). Rate-limited, so
    /// repeated presses never buzz.
    case nothingThere

    /// The shortest gap between two `nothingThere` bumps.
    static let nothingThereInterval: TimeInterval = 1

    public func play() {
        switch self {
        case .tap: Generators.light.impactOccurred()
        case .selection: Generators.selection.selectionChanged()
        case .threshold: Generators.rigid.impactOccurred(intensity: 0.7)
        case .success: Generators.notification.notificationOccurred(.success)
        case .nothingThere:
            let now = CACurrentMediaTime()
            guard now - Generators.lastNothingThere >= Self.nothingThereInterval else { return }
            Generators.lastNothingThere = now
            Generators.soft.impactOccurred(intensity: 0.5)
        }
    }

    /// Readies the engine for a haptic that is about to play (a pull nearing its threshold).
    public func prepare() {
        switch self {
        case .selection: Generators.selection.prepare()
        default: break
        }
    }
}

/// One generator per kind, made on first use: none is created at launch.
@MainActor
private enum Generators {
    static let light = UIImpactFeedbackGenerator(style: .light)
    static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    static let soft = UIImpactFeedbackGenerator(style: .soft)
    static let selection = UISelectionFeedbackGenerator()
    static let notification = UINotificationFeedbackGenerator()
    static var lastNothingThere: CFTimeInterval = 0
}
#endif
