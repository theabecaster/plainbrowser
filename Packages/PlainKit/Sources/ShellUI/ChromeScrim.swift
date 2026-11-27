#if canImport(UIKit)
import DesignSystem
import UIKit

/// A soft paper glow under a floating control's glass, so its text and symbols read over any
/// page (ux-audit item 3; docs/polish-backlog.md, "Hard edge look"). Liquid Glass shows the page
/// through itself almost unblurred, so body text ran under "Not Secure — host" and the buttons.
///
/// It is local, never a band: the shape of each glass shape, its edge softened over `feather`
/// points, and nothing past it, so the capsules still float apart over a colored page. The
/// glass above it then shows mostly paper. It
/// sits inside the control, behind its glass, so it moves, scales and fades with the control
/// (the collapse, the hide, the gallery) with no work of its own per frame. One layer shadow with
/// a fixed path: no offscreen pass.
final class ChromeScrim: UIView {
    /// The glass shapes to glow under, in this view's coordinates.
    var shapes: [CGRect] = [] {
        didSet { if shapes != oldValue { updatePath() } }
    }
    /// The private tint's ground in place of Paper.
    var isPrivate = false {
        didSet { if isPrivate != oldValue { resolveColor() } }
    }

    /// The softening at the glass edge (the shadow's blur radius). Two design review rounds:
    /// any wider glow read as a cream halo joining the capsules over a colored page.
    static let feather: CGFloat = 2
    /// Drawn this far inside the glass edge, so the softening stays under the glass's own rim.
    static let inset: CGFloat = 1
    /// Under the glass the page shows only faintly; at the edge the glow fades out. Denser in
    /// dark mode: light text under the dark ground showed through more than dark text on paper.
    static let opacity: CGFloat = 0.82
    static let darkOpacity: CGFloat = 0.92

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.shadowOffset = .zero
        layer.shadowRadius = Self.feather
        layer.shadowOpacity = 1
        resolveColor()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (scrim: ChromeScrim, _) in scrim.resolveColor() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func resolveColor() {
        let ground = isPrivate ? Palette.privateBackground : Palette.background
        let alpha = traitCollection.userInterfaceStyle == .dark ? Self.darkOpacity : Self.opacity
        layer.shadowColor = ground.resolvedColor(with: traitCollection).withAlphaComponent(alpha).cgColor
    }

    private func updatePath() {
        let path = UIBezierPath()
        for shape in shapes where !shape.isEmpty {
            let rect = shape.insetBy(dx: Self.inset, dy: Self.inset)
            path.append(UIBezierPath(roundedRect: rect, cornerRadius: min(rect.height, rect.width) / 2))
        }
        layer.shadowPath = path.cgPath
    }
}
#endif
