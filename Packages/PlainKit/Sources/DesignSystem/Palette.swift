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

    /// The glass tint of the chrome while a private tab is on screen: a deep dusk violet in both
    /// appearances, drawn with the dark style (light text and glyphs), as Safari darkens its bar.
    /// Owner, 2026-11-27: "it's hard to tell when you are in it and when you're not"; the old
    /// lilac read as Paper in light mode. White text on it is above 10:1.
    public static let privateGlassTint = UIColor(
        light: UIColor(rgb: 0x2E2560, alpha: 0.9), dark: UIColor(rgb: 0x3A2D7A, alpha: 0.86)
    )

    /// The private mark (`hand.raised.fill`) on the private glass and the start screen: a light
    /// violet, 5:1 or more on `privateGlassTint`.
    public static let privateAccent = UIColor(rgb: 0xC2B4FF)

    /// The tab switcher's selected Private segment: white text on it is about 5:1.
    public static let privateSelection = UIColor(rgb: 0x6E5AE6)

    /// The tab switcher's selected Tabs segment (on the always-dark gallery) and the text on it.
    public static let galleryModeLight = UIColor(rgb: 0xF4F1EA)
    public static let galleryModeInk = UIColor(rgb: 0x0A2133)

    /// The tab gallery's background while it shows private tabs, the private start screen (always
    /// drawn dark) and the strip behind the status bar.
    public static let privateBackground = UIColor(light: UIColor(rgb: 0xEEEBF6), dark: UIColor(rgb: 0x15122A))

    /// Lagoon Blue for text and symbols on glass: in dark mode a lighter step of the same blue,
    /// so labels keep their contrast on the dark glass.
    public static let accentOnGlass = UIColor(light: accent, dark: UIColor(rgb: 0x8DB6FF))

    /// The soft shadow under tab cards, so they lift off the Paper background.
    public static let floatingShadow = UIColor(light: UIColor(rgb: 0x0A2133), dark: .black)

    /// A row or button under the finger.
    public static let pressed = UIColor(light: UIColor(rgb: 0x2973FF, alpha: 0.10), dark: UIColor(rgb: 0x2973FF, alpha: 0.22))

    /// What dims the page and the bar under the sidebar's drawer (portrait), so the drawer reads as
    /// a layer over them: Deep Lagoon, lighter than the gallery's dim.
    public static let drawerScrim = UIColor(light: UIColor(rgb: 0x0A2133, alpha: 0.22), dark: UIColor(rgb: 0x000000, alpha: 0.4))

    // MARK: Tab plates

    /// The plate under a tab that is not on screen, in the strip and in the sidebar's titled rows:
    /// a veil of the card's color, so each tab reads as its own thing on the glass over any page
    /// (owner, on the Duo: "non-selected tabs [...] are just part of the whole bar"). Half the
    /// card's weight: the tab on screen stays the one solid card.
    public static let tabPlate = UIColor(light: UIColor(rgb: 0xFFFFFF, alpha: 0.5), dark: UIColor(rgb: 0x16344A, alpha: 0.55))
    /// A private tab's plate: the dusk tint, as its page.
    public static let privateTabPlate = UIColor(light: UIColor(rgb: 0xEEEBF6, alpha: 0.85), dark: UIColor(rgb: 0x15122A, alpha: 0.85))
    /// The hairline around a tab's plate: it keeps the plate's edge over a white page or a dark one.
    public static let tabPlateEdge = UIColor(light: UIColor(rgb: 0x0A2133, alpha: 0.12), dark: UIColor(rgb: 0xFFF6E6, alpha: 0.14))

    // MARK: Site icons

    /// The tile under a site icon that is one dark shape on a clear ground (a black logo): white
    /// by day, and still light at night, where the shape would be lost on Deep Lagoon.
    public static let iconTileForDarkMark = UIColor(light: .white, dark: UIColor(rgb: 0xDCE5EC))
    /// The tile under a site icon that is one light shape on a clear ground (a white logo): dark
    /// by day too, where the shape would be lost on white.
    public static let iconTileForLightMark = UIColor(light: UIColor(rgb: 0x16344A), dark: UIColor(rgb: 0x16344A))
    /// The hairline around a site icon's tile, so a white icon keeps its edge on white.
    public static let iconTileEdge = UIColor(light: UIColor(rgb: 0x0A2133, alpha: 0.10), dark: UIColor(rgb: 0xFFF6E6, alpha: 0.12))

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
    public static let inkSecondary = UIColor.anyThread { traits in
        let high = traits.accessibilityContrast == .high
        return traits.userInterfaceStyle == .dark
            ? UIColor(rgb: 0xFFF6E6, alpha: high ? 0.9 : 0.76)
            : UIColor(rgb: 0x0A2133, alpha: high ? 0.88 : 0.72)
    }

    /// A card of rows on the Paper ground: a hair lighter by day, a hair lifted by night. Flat
    /// and opaque, so a row costs no texture and no blending.
    public static let paperCard = UIColor.anyThread { traits in
        let high = traits.accessibilityContrast == .high
        return traits.userInterfaceStyle == .dark
            ? UIColor(rgb: high ? 0x1A3850 : 0x11293D)
            : UIColor(rgb: high ? 0xFFFFFF : 0xFFFBF4)
    }

    /// The hairline between rows on a card, in the ink's own tone.
    public static let paperHairline = UIColor.anyThread { traits in
        let high = traits.accessibilityContrast == .high
        return traits.userInterfaceStyle == .dark
            ? UIColor(rgb: 0xFFF6E6, alpha: high ? 0.42 : 0.14)
            : UIColor(rgb: 0x0A2133, alpha: high ? 0.38 : 0.12)
    }

    /// The search sheet's card: paper over a blur of the page, so it reads as Plain's paper with
    /// the page's colors faintly through it (Arc Search's frosted sheet, in paper). Opaque paper
    /// under Increase Contrast.
    public static let sheetTint = UIColor { traits in
        let high = traits.accessibilityContrast == .high
        return traits.userInterfaceStyle == .dark
            ? UIColor(rgb: 0x11293D, alpha: high ? 1 : 0.78)
            : UIColor(rgb: 0xFFFBF4, alpha: high ? 1 : 0.8)
    }

    /// The search sheet's handle: quiet ink, about 3:1 on the card (it is the one visible way out).
    public static let sheetGrabber = UIColor { traits in
        let high = traits.accessibilityContrast == .high
        return traits.userInterfaceStyle == .dark
            ? UIColor(rgb: 0xFFF6E6, alpha: high ? 0.75 : 0.5)
            : UIColor(rgb: 0x0A2133, alpha: high ? 0.65 : 0.42)
    }

    /// Over the page while the search sheet is open: the page stays sharp and readable, a step
    /// dimmer, so the sheet is in front and the page is clearly a place to tap back to.
    public static let sheetScrim = UIColor(light: UIColor(rgb: 0x0A2133, alpha: 0.22), dark: UIColor(rgb: 0x000000, alpha: 0.36))

    /// Lagoon Blue for actions and checkmarks on paper: a step deeper by day (`#2366F0`, 4.7:1 on
    /// the card, where Lagoon itself gives 4.1:1) and the lighter glass step by night.
    public static let accentOnPaper = UIColor.anyThread { traits in
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
    /// A dynamic color whose provider may run on any thread. SwiftUI resolves colors on its render
    /// thread during some animations, where a provider isolated to the main actor (the module's
    /// default) traps; these providers only pick between fixed colors, so they need no actor.
    nonisolated static func anyThread(_ provider: @escaping @Sendable (UITraitCollection) -> UIColor) -> UIColor {
        UIColor(dynamicProvider: provider)
    }

    nonisolated convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }

    nonisolated convenience init(light: UIColor, dark: UIColor) {
        self.init(dynamicProvider: { @Sendable traits in traits.userInterfaceStyle == .dark ? dark : light })
    }
}
#endif
