import BrowserCore
import Foundation

/// The tab gallery's grid rule (docs/plan.md, section 6). Columns are always even, so on the Duo's
/// inner screen no card straddles the fold. The width comes from the gallery's own bounds, never
/// from the screen or the device model. The values live in `FixedChoices`.
public enum TabGalleryLayout {
    /// Below this width the gallery is a phone-sized card list.
    public static let wideWidth = CGFloat(FixedChoices.tabGalleryWideWidth)

    public static func columnCount(forWidth width: CGFloat) -> Int {
        width < wideWidth ? FixedChoices.tabGalleryColumns.narrow : FixedChoices.tabGalleryColumns.wide
    }
}
