#if canImport(UIKit)
import DesignSystem
import UIKit

/// A soft paper glow under a floating control's glass, so its text and symbols read over any
/// page (ux-audit item 3; docs/polish-backlog.md, "Hard edge look"). Liquid Glass shows the page
/// through itself almost unblurred, so body text ran under "Not Secure — host" and the buttons.
///
/// It is local, never a band: a blurred capsule the shape of each glass shape, a little larger,
/// fading out over `feather` points around it. The glass above it then shows mostly paper. It
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

    /// How far the glow reaches past the glass (the shadow's blur radius).
    static let feather: CGFloat = 6
    /// How far the solid part reaches past the glass edge, so the edge itself is covered too.
    /// Small on purpose: over a colored page a wider glow read as a cream halo joining the
    /// capsules (design review). The gap between the pill and the bar is the bar's to fill.
    static let outset: CGFloat = 3
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
            let rect = shape.insetBy(dx: -Self.outset, dy: -Self.outset)
            path.append(UIBezierPath(roundedRect: rect, cornerRadius: min(rect.height, rect.width) / 2))
        }
        layer.shadowPath = path.cgPath
    }
}
#endif
