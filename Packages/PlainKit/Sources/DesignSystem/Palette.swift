#if canImport(UIKit)
import UIKit

/// The "Paper & Lagoon" colors (Brand/identity.md) and the semantic colors features use. Features
/// never hard-code a color: they take one from here. Defined in code, not an asset catalog, so
/// reading one at launch costs no bundle lookup.
public enum Palette {
    // MARK: Brand

    /// Lagoon Blue, the tint for controls and links.
    public static let accent = UIColor(rgb: 0x2973FF)
    /// Shallows Mint, the light end of the focus rim and progress gradient.
    public static let mint = UIColor(rgb: 0x33DBC7)
    /// Curl Coral, used sparingly: the one thing that matters on screen (the progress bar's tip).
    public static let coral = UIColor(rgb: 0xFF6E5E)

    // MARK: Surfaces

    /// The window background: Paper in light mode, Deep Lagoon in dark mode.
    /// The app's launch screen color (`LaunchBackground` in Plain/Assets.xcassets) must match it,
    /// so the launch screen hands over to the first frame without a flash.
    public static let background = UIColor(light: UIColor(rgb: 0xFFF6E6), dark: UIColor(rgb: 0x0A2133))

    /// Something that sits on the background: a favorite's tile, a pressed row.
    public static let surface = UIColor(light: .white, dark: UIColor(rgb: 0x16344A))

    /// The tint mixed into Liquid Glass on floating controls: Paper, so the URL pill reads as the
    /// "paper-tinted glass capsule" of the brand. Strong enough that the host stays legible over
    /// body text scrolling underneath.
    public static let glassTint = UIColor(
        light: UIColor(rgb: 0xFFF6E6, alpha: 0.78), dark: UIColor(rgb: 0x16344A, alpha: 0.72)
    )

    /// A lighter tint for glass that floats over the Paper background itself (the tab gallery's
    /// bar), where the full `glassTint` doubles the Paper and reads as gold.
    public static let glassTintOnPaper = UIColor(
        light: UIColor(rgb: 0xFFFFFF, alpha: 0.35), dark: UIColor(rgb: 0x16344A, alpha: 0.45)
    )

    /// Lagoon Blue for text and symbols on glass: in dark mode a lighter step of the same blue,
    /// so labels keep their contrast on the dark glass.
    public static let accentOnGlass = UIColor(light: accent, dark: UIColor(rgb: 0x8DB6FF))

    /// The soft shadow under floating controls, so glass lifts off a white page.
    public static let floatingShadow = UIColor(light: UIColor(rgb: 0x0A2133), dark: .black)

    /// A row or button under the finger.
    public static let pressed = UIColor(light: UIColor(rgb: 0x2973FF, alpha: 0.10), dark: UIColor(rgb: 0x2973FF, alpha: 0.22))

    // MARK: Text and symbols

    /// Body text and symbols. The system's label color, so contrast settings apply.
    public static let textPrimary = UIColor.label
    /// Supporting text: a suggestion's address, a placeholder.
    public static let textSecondary = UIColor.secondaryLabel

    // MARK: Gradients

    /// The URL field's rim while it is focused, start to end.
    public static let focusRim: [UIColor] = [mint, accent]
    /// The load-progress bar, start to end. It ends in a coral tip.
    public static let progress: [UIColor] = [mint, accent, coral]
}

extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }

    convenience init(light: UIColor, dark: UIColor) {
        self.init { $0.userInterfaceStyle == .dark ? dark : light }
    }
}
#endif
