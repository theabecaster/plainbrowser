import BrowserCore
import CoreGraphics
import Foundation

// The side tabs sidebar's states and drag rules as plain values, free of UIKit so `swift test`
// checks them on macOS (docs/plan.md, section 6, "Side tabs design").

/// The sidebar's resting states. Hidden shows no sidebar; Rail shows favicons only; Expanded shows
/// favicons and titles.
public enum SidebarState: String, Sendable, CaseIterable, Comparable {
    case hidden
    case rail
    case expanded

    /// The sidebar's width at rest.
    public var width: CGFloat {
        switch self {
        case .hidden: 0
        case .rail: CGFloat(FixedChoices.sidebarRailWidth)
        case .expanded: CGFloat(FixedChoices.sidebarExpandedWidth)
        }
    }

    private var order: Int {
        switch self {
        case .hidden: 0
        case .rail: 1
        case .expanded: 2
        }
    }

    public static func < (lhs: SidebarState, rhs: SidebarState) -> Bool { lhs.order < rhs.order }
}

/// How a drag on the sidebar's edge moves it between states: the edge follows the finger 1:1
/// between Hidden and the widest allowed state and rubber-bands past it; on release it springs to
/// the state nearest the width the release velocity projects to.
public struct SidebarDrag: Equatable, Sendable {
    /// The widest state the sidebar may rest in now (Rail while a split shows or the screen is
    /// partly folded).
    public var widest: SidebarState

    /// How far ahead the release velocity projects, in seconds: about a spring's quarter period,
    /// so a flick reaches the next state but a slow release stays where the finger left it.
    public static let projection: CGFloat = 0.18
    /// Past the widest state the edge moves at this fraction of the finger.
    public static let rubberBand: CGFloat = 0.25

    public init(widest: SidebarState) {
        self.widest = widest
    }

    /// The sidebar's width while the finger has moved it to `proposed`.
    public func trackedWidth(_ proposed: CGFloat) -> CGFloat {
        let maximum = widest.width
        if proposed > maximum { return maximum + (proposed - maximum) * Self.rubberBand }
        return max(0, proposed)
    }

    /// Where the sidebar rests when the finger lifts at `width` moving at `velocity` points per
    /// second (positive widens).
    public func restingState(width: CGFloat, velocity: CGFloat) -> SidebarState {
        let projected = width + velocity * Self.projection
        let candidates = SidebarState.allCases.filter { $0 <= widest }
        return candidates.min { abs($0.width - projected) < abs($1.width - projected) } ?? .hidden
    }
}
