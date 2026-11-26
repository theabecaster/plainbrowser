#if canImport(UIKit)
import UIKit

/// The brand's art colors (Brand/identity.md, Brand/tools/gen_icon.py): the Stem mark's paper, fold
/// and dawn, and the first-run intro's gradient field. Only the mark and the intro use these; the
/// rest of the app takes its colors from `Palette`.
public enum BrandArt {
    // MARK: The mark (the icon's Dawn colorway)

    /// Paper, top-left to lower right.
    public static let paper = [UIColor(rgb: 0xFFFDF8), UIColor(rgb: 0xFFF6E6), UIColor(rgb: 0xFFE6D2)]
    /// The paper's warm lower right.
    public static let paperWarm = UIColor(rgb: 0xFFC9B0)
    /// The flap's contact shadow on the ring.
    public static let flapShade = UIColor(rgb: 0x7A2E22)
    /// Curl Coral: crease to free edge.
    public static let curl = [UIColor(rgb: 0xFFB096), UIColor(rgb: 0xFF9174), UIColor(rgb: 0xFF6E5E), UIColor(rgb: 0xEC4A57)]
    /// The dawn sky, top to horizon.
    public static let dawnSky = [UIColor(rgb: 0x3A2FCF), UIColor(rgb: 0x3F86FF), UIColor(rgb: 0xFFC08E)]
    /// The same sky before the sun is up (the splash starts here).
    public static let nightSky = [UIColor(rgb: 0x0B0A3A), UIColor(rgb: 0x1B1D6E), UIColor(rgb: 0x3A2FCF)]
    /// Night Lagoon, the planet: its top to its far side.
    public static let planet = [UIColor(rgb: 0x1B2A8F), UIColor(rgb: 0x121552)]
    /// The planet's thin mint atmosphere.
    public static let rim = UIColor(rgb: 0x9CFFE8)
    /// Sunrise: core, middle, edge.
    public static let sun = [UIColor(rgb: 0xFFF8E8), UIColor(rgb: 0xFF9A78), UIColor(rgb: 0xFF5A4C)]

    // MARK: The intro's field

    /// Deep dawn violet, the field's darkest color.
    public static let dawnViolet = UIColor(rgb: 0x3A2FCF)
    /// The icon's violet bloom.
    public static let bloomViolet = UIColor(rgb: 0x6B4BFF)
    /// Lagoon Blue.
    public static let lagoon = UIColor(rgb: 0x2973FF)
    /// Shallows Mint.
    public static let mint = UIColor(rgb: 0x33DBC7)
    /// Curl Coral.
    public static let coral = UIColor(rgb: 0xFF6E5E)
    /// The horizon's peach.
    public static let peach = UIColor(rgb: 0xFFC08E)
    /// Night Lagoon, for the darkest corner of the field.
    public static let nightLagoon = UIColor(rgb: 0x121552)
    /// Paper, the light field of the default-browser step.
    public static let paperField = UIColor(rgb: 0xFFF6E6)
    /// Ink on paper: text on the light field.
    public static let ink = UIColor(rgb: 0x0A2133)
    /// Text on the vivid field.
    public static let onField = UIColor.white
}
#endif
