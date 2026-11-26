#if canImport(UIKit)
import UIKit

/// The one way to make Liquid Glass (docs/ui-reference.md): only on floating controls, never glass
/// on glass. Under Reduce Transparency the system swaps the glass for an opaque material itself.
public enum Glass {
    public enum Shape {
        case capsule
        case rounded(CGFloat)
    }

    /// A glass background for a floating control. Put the control's content in `contentView`.
    /// - Parameter interactive: the glass reacts to touches (a control that is itself the button).
    public static func makeView(shape: Shape = .capsule, interactive: Bool = false) -> UIVisualEffectView {
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = Palette.glassTint
        effect.isInteractive = interactive
        let view = UIVisualEffectView(effect: effect)
        switch shape {
        case .capsule: view.cornerConfiguration = .capsule()
        case .rounded(let radius): view.cornerConfiguration = .uniformCorners(radius: .fixed(radius))
        }
        return view
    }

    /// Lifts a floating control off the page with a soft shadow. Call `updateShadowPath` from the
    /// view's `layoutSubviews`, so the shadow never needs an offscreen pass.
    public static func addShadow(to view: UIView) {
        view.layer.shadowColor = Palette.floatingShadow.resolvedColor(with: view.traitCollection).cgColor
        view.layer.shadowOpacity = 0.14
        view.layer.shadowRadius = 10
        view.layer.shadowOffset = CGSize(width: 0, height: 3)
    }

    /// The capsule shadow path for `view`'s bounds.
    public static func updateShadowPath(of view: UIView) {
        let bounds = view.bounds
        view.layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
    }
}
#endif
