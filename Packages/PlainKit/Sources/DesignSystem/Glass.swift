#if canImport(UIKit)
import UIKit

/// The one way to make Liquid Glass (docs/ui-reference.md): only on floating controls, never glass
/// on glass. Under Reduce Transparency the system swaps the glass for an opaque material itself.
///
/// Floating controls that sit together go in one `makeContainer` view, so the system renders their
/// glass as one surface: they tint as one and merge where they meet. Glass carries its own depth,
/// so there is no extra layer shadow.
public enum Glass {
    public enum Shape {
        case capsule
        case rounded(CGFloat)
    }

    /// A glass background for a floating control. Put the control's content in `contentView`.
    /// - Parameter interactive: the glass reacts to touches (a control that is itself the button).
    /// - Parameter tint: the color mixed into the glass; `Palette.glassTint` unless the control
    ///   floats over a surface that already has it.
    public static func makeView(
        shape: Shape = .capsule, interactive: Bool = false, tint: UIColor = Palette.glassTint
    ) -> UIVisualEffectView {
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = tint
        effect.isInteractive = interactive
        let view = UIVisualEffectView(effect: effect)
        switch shape {
        case .capsule: view.cornerConfiguration = .capsule()
        case .rounded(let radius): view.cornerConfiguration = .uniformCorners(radius: .fixed(radius))
        }
        return view
    }

    /// A container that renders the glass views inside its `contentView` as one combined surface
    /// (`UIGlassContainerEffect`). Controls go anywhere inside `contentView`; the container itself
    /// takes no touches, so it can cover the whole screen and let the page under it scroll.
    /// - Parameter spacing: how close two glass shapes come before they start to merge.
    public static func makeContainer(spacing: CGFloat) -> UIVisualEffectView {
        let effect = UIGlassContainerEffect()
        effect.spacing = spacing
        return PassthroughEffectView(effect: effect)
    }
}

/// A visual effect view that passes touches on its empty area through to the views below.
private final class PassthroughEffectView: UIVisualEffectView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self || hit === contentView ? nil : hit
    }
}
#endif
