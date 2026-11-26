#if canImport(UIKit)
import UIKit

/// Spacing steps. Layout uses these, not ad-hoc numbers.
public enum Spacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
}

/// Corner radii (docs/ui-reference.md: 6–10 pt). Capsules use `Glass` or `.capsule`.
public enum Radius {
    public static let small: CGFloat = 6
    public static let medium: CGFloat = 8
    public static let large: CGFloat = 10
}

/// Fixed sizes of the shell's controls.
public enum Metrics {
    /// The smallest tap target (docs/ui-reference.md).
    public static let tapTarget: CGFloat = 44
    /// A suggestion row's height.
    public static let rowHeight: CGFloat = 52
    /// A favorite's tile above the keyboard.
    public static let favoriteTile: CGFloat = 52
}
#endif
