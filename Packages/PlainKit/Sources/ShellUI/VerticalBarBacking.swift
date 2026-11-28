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
/// Corners (owner, 2026-11-28, on the Duo: the panel's corners got "cut off by the screen's
/// physical round corners ... only the corner area on the right side"): the panel's corners are
/// concentric with the display's (`Glass.Shape.concentric`, UIKit's `.containerConcentric`). This
/// view covers the whole screen with concentric corners of its own, so its radius at each corner
/// is the display's there (the Duo's outer screen: 59 pt on the right, 8 at the hinge; 0 on an
/// iPhone SE), and the panel inside resolves against it. A corner can't round past half the
/// panel's width, so where the display's corner is the rounder one the panel's ends move in from
/// the top and bottom until its corner sits inside the display's (`end(display:side:cap:)`).
///
/// Cost: one effect view and a shadow path, placed on layout only; no per-frame work.
final class VerticalBarBacking: UIView {
    private let glass = Glass.makeView(shape: .concentric(minimum: VerticalBarBacking.radius))
    /// A soft shadow under the panel, falling into the gap toward the page: the glass sits a
    /// little above the paper, so the page meets a lifted edge rather than a flat change of colour
    /// (design review). Its path is the panel's, so it costs no offscreen pass.
    private let shadow = UIView()
    /// The column the system's bar takes, in this view's coordinates (it covers the screen).
    private var column: CGRect = .zero

    /// Between the panel and the page, and the screen's edges (`FixedChoices.verticalBarPanelInset`).
    static var inset: CGFloat { CGFloat(FixedChoices.verticalBarPanelInset) }
    /// The panel's smallest corner, where it faces the page (`FixedChoices.verticalBarPanelRadius`).
    static var radius: CGFloat { CGFloat(FixedChoices.verticalBarPanelRadius) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        // The display's corners, as the panel's container. Nothing here draws or clips with them.
        cornerConfiguration = .corners(radius: .containerConcentric())
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

    /// Covers `bounds` (the superview's) and puts the panel inside `column`, the bar's side of it.
    func place(column: CGRect, in bounds: CGRect) {
        if frame != bounds { frame = bounds }
        if self.column != column {
            self.column = column
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard column.width > 0, column.height > 0 else { return }
        // The display's corners on the column's outer side. Read here, so UIKit lays this view out
        // again when they change (a fold, a rotation, the first pass in a window).
        let onRight = column.maxX >= bounds.maxX - 0.5
        let side = Self.inset
        let width = column.width - 2 * side
        let cap = max(0, min(width, column.height - 2 * side) / 2)
        let top = Self.end(display: effectiveRadius(corner: onRight ? .topRight : .topLeft), side: side, cap: cap)
        let bottom = Self.end(display: effectiveRadius(corner: onRight ? .bottomRight : .bottomLeft), side: side, cap: cap)
        let panel = CGRect(
            x: column.minX + side, y: column.minY + top.inset,
            width: width, height: column.height - top.inset - bottom.inset
        )
        if glass.frame != panel { glass.frame = panel }
        if shadow.frame != panel {
            shadow.frame = panel
        }
        // The panel's shape as UIKit resolves it, the page side at its minimum.
        let page = min(Self.radius, cap)
        let path = Self.path(
            in: CGRect(origin: .zero, size: panel.size),
            topLeft: onRight ? page : top.radius, topRight: onRight ? top.radius : page,
            bottomLeft: onRight ? page : bottom.radius, bottomRight: onRight ? bottom.radius : page
        )
        if shadow.layer.shadowPath != path { shadow.layer.shadowPath = path }
    }

    /// One end of the panel, against a display corner of radius `display`: the panel's corner
    /// there (concentric, `display - side`, kept between the minimum and `cap`, half the panel's
    /// width) and how far the end sits from the screen's edge. When the concentric radius fits,
    /// the end keeps `side`. When it doesn't, the end moves in to `display - radius`, where the
    /// smaller corner sits inside the display's, but no further than
    /// `FixedChoices.verticalBarPanelEndInsetLimit`.
    static func end(display: CGFloat, side: CGFloat, cap: CGFloat) -> (radius: CGFloat, inset: CGFloat) {
        let concentric = display - side
        let corner = min(max(concentric, Self.radius), cap)
        guard concentric > corner + 0.5 else { return (corner, side) }
        let limit = max(side, CGFloat(FixedChoices.verticalBarPanelEndInsetLimit))
        return (corner, min(max(side, display - corner), limit))
    }

    /// A rounded rectangle with its own radius at each corner (circular arcs: under a 10 pt blur
    /// they match the glass's continuous corners).
    private static func path(
        in rect: CGRect, topLeft: CGFloat, topRight: CGFloat, bottomLeft: CGFloat, bottomRight: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: topRight)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: bottomRight)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: bottomLeft)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: topLeft)
        path.closeSubpath()
        return path
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
