#if canImport(UIKit)
import BrowserCore
import DesignSystem
import UIKit

/// The glass behind the system's vertical bar (the Duo's outer screen): the column beside the page
/// that holds the status items and the page buttons' capsule.
///
/// The system draws the bar's items but nothing behind them, so the column showed Plain's root
/// background, a flat paper slab cut straight against the page. Owner, 2026-11-28: "The sidebar on
/// the Duo outer screen should keep the theme colors we are using but be more like Apple glass, so
/// the change from the page to it is less abrupt", and the page "should still not show [through
/// it] ... but it'll transition better to the eye like that". So the layout stays: the page ends
/// where it did and nothing of it is behind the column. The column becomes one floating panel of
/// Liquid Glass in Plain's tint (`Palette.glassTint`; Night drawn dark in a private
/// tab), inset a few points from the page and the screen's edges with round corners, as the
/// sidebars of Apple's own apps float in glass: the page meets a soft rounded glass edge with its
/// rim light, not a hard seam.
///
/// Cost: one effect view, placed on layout only; no per-frame work.
final class VerticalBarBacking: UIView {
    private let glass = Glass.makeView(shape: .rounded(VerticalBarBacking.radius))
    /// A soft shadow under the panel, falling into the gap toward the page: the glass sits a
    /// little above the paper, so the page meets a lifted edge rather than a flat change of colour
    /// (design review). Its path is the panel's, so it costs no offscreen pass.
    private let shadow = UIView()

    /// Between the panel and the page, and the screen's edges (`FixedChoices.verticalBarPanelInset`).
    static var inset: CGFloat { CGFloat(FixedChoices.verticalBarPanelInset) }
    /// The panel's corners (`FixedChoices.verticalBarPanelRadius`).
    static var radius: CGFloat { CGFloat(FixedChoices.verticalBarPanelRadius) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        shadow.isUserInteractionEnabled = false
        shadow.layer.shadowColor = UIColor.black.cgColor
        shadow.layer.shadowOffset = .zero
        shadow.layer.shadowRadius = CGFloat(FixedChoices.verticalBarPanelShadow.radius)
        addSubview(shadow)
        addSubview(glass)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: VerticalBarBacking, _) in view.updateShadow() }
        updateShadow()
    }

    private var isPrivate = false

    private func updateShadow() {
        // Stronger in dark mode and on the always-dark private glass, where a faint one vanishes.
        shadow.layer.shadowOpacity = Float(traitCollection.userInterfaceStyle == .dark || isPrivate
            ? FixedChoices.verticalBarPanelShadow.dark : FixedChoices.verticalBarPanelShadow.light)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Places the panel inside `column` (the superview's coordinates).
    func place(column: CGRect) {
        if frame != column { frame = column }
        let panel = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        if glass.frame != panel {
            glass.frame = panel
            shadow.frame = panel
            shadow.layer.shadowPath = UIBezierPath(
                roundedRect: shadow.bounds, cornerRadius: Self.radius
            ).cgPath
        }
    }

    /// Paper glass, or Night drawn dark (as the pill and the buttons).
    func setPrivate(_ isPrivate: Bool) {
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = isPrivate ? Palette.privateGlassTint : Palette.glassTint
        glass.effect = effect
        glass.overrideUserInterfaceStyle = isPrivate ? .dark : .unspecified
        self.isPrivate = isPrivate
        updateShadow()
    }
}
#endif
