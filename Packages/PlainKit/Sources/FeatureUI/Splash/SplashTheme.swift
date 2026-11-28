import CoreGraphics
import Foundation

/// An sRGB color with alpha, as the icon's generator writes them.
nonisolated struct SplashColor: Equatable, Sendable {
    var r, g, b: Double
    var a: Double = 1

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(_ hex: UInt32, alpha: Double = 1) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255, a: alpha)
    }

    func alpha(_ a: Double) -> SplashColor { SplashColor(r: r, g: g, b: b, a: a) }

    var cgColor: CGColor {
        CGColor(colorSpace: SplashColor.space, components: [r, g, b, a]) ?? CGColor(gray: 0, alpha: 1)
    }

    static let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// WCAG relative luminance, 0 (black) to 1 (white).
    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}

/// One app icon's world, for the launch splash: the icon's field, its bloom, the paper of the
/// ring, the fold and the dawn in the window. The values are the generator's
/// (Brand/tools/gen_icon.py: `FILL`, `BLOOM`, `PAPER`, `CURL`, `SCENE`, `COLORWAYS`), so the
/// splash is the icon the user tapped. A test holds them to the generator's file.
///
/// Dawn has dark art, as the icon does; Night, Coral and Paper look the same light and dark.
nonisolated struct SplashTheme: Equatable, Sendable {
    /// The field's gradient, from (0.2, 0) to (0.8, 1) of the screen, as in the icon.
    var field: [SplashColor]
    /// The two blooms over the field: top left and bottom right, each with its strength.
    var bloomNear: SplashColor
    var bloomFar: SplashColor
    /// The ring's paper: top left, middle, lower right.
    var paper: [SplashColor]
    /// The paper's warm lower right, and the flap's contact shadow on it.
    var paperWarm: SplashColor
    var flapShade: SplashColor
    /// The paper's top-left light (an ink ring takes much less).
    var highlight: Double
    /// The fold: crease to free edge, at `curlStops`.
    var curl: [SplashColor]
    /// The dawn in the window: sky (top to horizon), planet, its mint rim, the sun and its glow.
    var sky: [SplashColor]
    var planet: [SplashColor]
    var rim: SplashColor
    var sun: [SplashColor]
    var glow: Double

    static let curlStops: [CGFloat] = [0, 0.18, 0.6, 1]

    /// The status bar's text over the field's top edge: light on a dark field.
    var statusBarIsLight: Bool { field[0].luminance < 0.35 }

    static func theme(for choice: AppIconChoice, dark: Bool) -> SplashTheme {
        switch choice {
        case .dawn: dark ? dawnDark : dawn
        case .night: night
        case .coral: coral
        case .paper: paper
        }
    }

    private static let paperLight = [SplashColor(0xFFFDF8), SplashColor(0xFFF6E6), SplashColor(0xFFE6D2)]
    private static let paperDark = [SplashColor(0xFFF8EE), SplashColor(0xF7EAD8), SplashColor(0xEED8C2)]
    private static let coralCurl = [SplashColor(0xFFB096), SplashColor(0xFF9174), SplashColor(0xFF6E5E), SplashColor(0xEC4A57)]

    /// The app icon: a Lagoon field, cream paper, the coral fold and the dawn.
    static let dawn = SplashTheme(
        field: [SplashColor(r: 0.20, g: 0.86, b: 0.78), SplashColor(r: 0.16, g: 0.45, b: 1.0)],
        bloomNear: SplashColor(0xB8FFE0, alpha: 0.9), bloomFar: SplashColor(0x6B4BFF, alpha: 0.85),
        paper: paperLight, paperWarm: SplashColor(0xFFC9B0), flapShade: SplashColor(0x7A2E22), highlight: 0.9,
        curl: coralCurl,
        sky: [SplashColor(0x3A2FCF), SplashColor(0x3F86FF), SplashColor(0xFFC08E)],
        planet: [SplashColor(0x1B2A8F), SplashColor(0x121552)], rim: SplashColor(0x9CFFE8),
        sun: [SplashColor(0xFFF8E8), SplashColor(0xFF9A78), SplashColor(0xFF5A4C)], glow: 1.0
    )

    /// The app icon's dark art: Deep Lagoon, a warmer, dimmer paper.
    static let dawnDark: SplashTheme = {
        var t = dawn
        t.field = [SplashColor(r: 0.04, g: 0.13, b: 0.20), SplashColor(r: 0.06, g: 0.06, b: 0.20)]
        t.bloomNear = SplashColor(0x1FB5A0, alpha: 0.5)
        t.bloomFar = SplashColor(0x5B3BFF, alpha: 0.6)
        t.paper = paperDark
        t.paperWarm = SplashColor(0xE8B9A4)
        t.flapShade = SplashColor(0x2A0E10)
        t.sky = [SplashColor(0x1E1A80), SplashColor(0x2F6FE8), SplashColor(0xFFBA8E)]
        t.planet = [SplashColor(0x141F70), SplashColor(0x0B0D3A)]
        t.rim = SplashColor(0x7CFFE0)
        t.sun = [SplashColor(0xFFF6E4), SplashColor(0xFF9474), SplashColor(0xFF5A4C)]
        return t
    }()

    /// Deep Lagoon at night: the paper ring around a violet night sky and a pale moon.
    static let night: SplashTheme = {
        var t = dawn
        t.field = [SplashColor(r: 0.04, g: 0.12, b: 0.25), SplashColor(r: 0.10, g: 0.06, b: 0.31)]
        t.bloomNear = SplashColor(0x1FB5A0, alpha: 0.45)
        t.bloomFar = SplashColor(0x5B3BFF, alpha: 0.7)
        t.paper = paperDark
        t.paperWarm = SplashColor(0xE8B9A4)
        t.flapShade = SplashColor(0x2A0E10)
        t.sky = [SplashColor(0x0B0A3A), SplashColor(0x26248A), SplashColor(0x7A6BE8)]
        t.planet = [SplashColor(0x141F70), SplashColor(0x0B0D3A)]
        t.rim = SplashColor(0x7CFFE0)
        t.sun = [SplashColor(0xFFFFFF), SplashColor(0xF1EEFF), SplashColor(0xB9B0FF)]
        t.glow = 0.55
        return t
    }()

    /// Curl Coral as the field, with the fold turned Lagoon Blue.
    static let coral: SplashTheme = {
        var t = dawn
        t.field = [SplashColor(r: 1.0, g: 0.62, b: 0.50), SplashColor(r: 0.93, g: 0.29, b: 0.34)]
        t.bloomNear = SplashColor(0xFFE2C8, alpha: 0.85)
        t.bloomFar = SplashColor(0x6B4BFF, alpha: 0.5)
        t.curl = [SplashColor(0xA9C8FF), SplashColor(0x6FA0FF), SplashColor(0x2973FF), SplashColor(0x1F4FD8)]
        return t
    }()

    /// Cream paper as the field, the ring in Night Lagoon ink, the coral fold and the dawn.
    static let paper: SplashTheme = {
        var t = dawn
        t.field = [SplashColor(r: 1.0, g: 0.97, b: 0.92), SplashColor(r: 0.95, g: 0.88, b: 0.78)]
        t.bloomNear = SplashColor(0xFFFFFF, alpha: 0.8)
        t.bloomFar = SplashColor(0xFFC9B0, alpha: 0.55)
        t.paper = [SplashColor(0x33496E), SplashColor(0x1E3050), SplashColor(0x14223D)]
        t.paperWarm = SplashColor(0x4A3C7A)
        t.flapShade = SplashColor(0x000000)
        t.highlight = 0.25
        return t
    }()
}
