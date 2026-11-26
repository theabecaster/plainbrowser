#if canImport(UIKit)
import UIKit

/// The "Paper & Lagoon" colors (Brand/identity.md). Defined in code, not an asset catalog, so
/// reading one at launch costs no bundle lookup.
public enum Palette {
    /// Lagoon Blue, the tint for controls and links.
    public static let accent = UIColor(rgb: 0x2973FF)
    /// Shallows Mint, the light end of the focus rim and progress gradient.
    public static let mint = UIColor(rgb: 0x33DBC7)
    /// Curl Coral, used sparingly: the one thing that matters on screen.
    public static let coral = UIColor(rgb: 0xFF7F6E)

    /// The window background: Paper in light mode, Deep Lagoon in dark mode.
    /// The app's launch screen color (`LaunchBackground` in Plain/Assets.xcassets) must match it,
    /// so the launch screen hands over to the first frame without a flash.
    public static let background = UIColor(light: UIColor(rgb: 0xFFF6E6), dark: UIColor(rgb: 0x0A2133))

    /// The search field's capsule.
    public static let fieldBackground = UIColor(light: .white, dark: UIColor(rgb: 0x16344A))
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    convenience init(light: UIColor, dark: UIColor) {
        self.init { $0.userInterfaceStyle == .dark ? dark : light }
    }
}
#endif
