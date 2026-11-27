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

    /// The app mark's colors (Brand/identity.md), for the mark drawn in the app: the start screen
    /// and a new tab's card.
    public enum Mark {
        /// The paper ring.
        public static let paper = UIColor(rgb: 0xFFF6E6)
        /// The dawn sky, top to horizon.
        public static let sky: [UIColor] = [UIColor(rgb: 0x3A2FCF), UIColor(rgb: 0x3F86FF), UIColor(rgb: 0xFFC08E)]
        /// The planet, rim to depth, and its thin atmosphere line.
        public static let planet: [UIColor] = [UIColor(rgb: 0x1B2A8F), UIColor(rgb: 0x121552)]
        public static let atmosphere = UIColor(rgb: 0x9CFFE8)
        /// The rising sun, core to edge.
        public static let sun: [UIColor] = [UIColor(rgb: 0xFFF8E8), UIColor(rgb: 0xFF5A4C)]
        /// The ring's shadow on the page under it.
        public static let shadow = UIColor(rgb: 0x0A2133)
        /// The coral fold, crease to free edge.
        public static let fold: [UIColor] = [UIColor(rgb: 0xFFB096), UIColor(rgb: 0xFF6E5E), UIColor(rgb: 0xEC4A57)]
    }

    /// The start screen's quiet dawn: the background warming toward Lagoon at the bottom, behind
    /// the mark.
    public static let startGlow = UIColor(
        light: UIColor(rgb: 0x33DBC7, alpha: 0.16), dark: UIColor(rgb: 0x3A2FCF, alpha: 0.28)
    )
    /// What dims the page behind the tab gallery's blur, as the app switcher dims the Home Screen.
    public static let galleryDim = UIColor(rgb: 0x0A2133, alpha: 0.42)

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
        light: UIColor(rgb: 0xFFF6E6, alpha: 0.88), dark: UIColor(rgb: 0x16344A, alpha: 0.84)
    )

    /// A lighter tint for glass that floats over the Paper background itself (the tab gallery's
    /// bar), where the full `glassTint` doubles the Paper and reads as gold.
    public static let glassTintOnPaper = UIColor(
        light: UIColor(rgb: 0xFFFFFF, alpha: 0.35), dark: UIColor(rgb: 0x16344A, alpha: 0.45)
    )

    // MARK: Private browsing

    /// The glass tint of the chrome while a private tab is on screen: a quiet dusk violet instead
    /// of Paper, so private browsing is plain to see without a banner or badge.
    public static let privateGlassTint = UIColor(
        light: UIColor(rgb: 0xE4E0F2, alpha: 0.9), dark: UIColor(rgb: 0x2A2445, alpha: 0.86)
    )

    /// The tab gallery's background while it shows private tabs.
    public static let privateBackground = UIColor(light: UIColor(rgb: 0xEEEBF6), dark: UIColor(rgb: 0x15122A))

    /// Lagoon Blue for text and symbols on glass: in dark mode a lighter step of the same blue,
    /// so labels keep their contrast on the dark glass.
    public static let accentOnGlass = UIColor(light: accent, dark: UIColor(rgb: 0x8DB6FF))

    /// The soft shadow under tab cards, so they lift off the Paper background.
    public static let floatingShadow = UIColor(light: UIColor(rgb: 0x0A2133), dark: .black)

    /// A row or button under the finger.
    public static let pressed = UIColor(light: UIColor(rgb: 0x2973FF, alpha: 0.10), dark: UIColor(rgb: 0x2973FF, alpha: 0.22))

    // MARK: Text and symbols

    /// Body text and symbols. The system's label color, so contrast settings apply.
    public static let textPrimary = UIColor.label
    /// Supporting text: a suggestion's address, a placeholder.
    public static let textSecondary = UIColor.secondaryLabel

    // MARK: Paper sheets

    // Settings, History, Favorites, Archive and Downloads sit on the textured Paper ground
    // (`PaperBackground()`) with their rows grouped on flat cards a hair lifted from it. Each color
    // also has an Increase Contrast step: flatter, plainer cards and stronger lines.

    /// Ink on paper: the sheets' text. Deep Lagoon ink by day, Paper by night.
    public static let ink = UIColor(light: UIColor(rgb: 0x0A2133), dark: UIColor(rgb: 0xFFF6E6))

    /// Supporting text on paper: a row's address or value, a footer. Ink thinned to keep 4.5:1 on
    /// the ground and the cards.
    public static let inkSecondary = UIColor { traits in
        let high = traits.accessibilityContrast == .high
        return traits.userInterfaceStyle == .dark
            ? UIColor(rgb: 0xFFF6E6, alpha: high ? 0.82 : 0.66)
            : UIColor(rgb: 0x0A2133, alpha: high ? 0.82 : 0.68)
    }

    /// A card of rows on the Paper ground: a hair lighter by day, a hair lifted by night. Flat
    /// and opaque, so a row costs no texture and no blending.
    public static let paperCard = UIColor { traits in
        let high = traits.accessibilityContrast == .high
        return traits.userInterfaceStyle == .dark
            ? UIColor(rgb: high ? 0x1A3850 : 0x11293D)
            : UIColor(rgb: high ? 0xFFFFFF : 0xFFFBF4)
    }

    /// The hairline between rows on a card, in the ink's own tone.
    public static let paperHairline = UIColor { traits in
        let high = traits.accessibilityContrast == .high
        return traits.userInterfaceStyle == .dark
            ? UIColor(rgb: 0xFFF6E6, alpha: high ? 0.42 : 0.14)
            : UIColor(rgb: 0x0A2133, alpha: high ? 0.38 : 0.12)
    }

    /// Lagoon Blue for actions and checkmarks on paper: a step deeper by day (`#2366F0`, 4.7:1 on
    /// the card, where Lagoon itself gives 4.1:1) and the lighter glass step by night.
    public static let accentOnPaper = UIColor { traits in
        let high = traits.accessibilityContrast == .high
        return traits.userInterfaceStyle == .dark
            ? UIColor(rgb: high ? 0xB3CEFF : 0x8DB6FF)
            : UIColor(rgb: high ? 0x1A52D0 : 0x2366F0)
    }

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
