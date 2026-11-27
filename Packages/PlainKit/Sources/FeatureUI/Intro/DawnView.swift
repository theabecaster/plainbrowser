#if canImport(UIKit)
import DesignSystem
import SwiftUI
import UIKit

/// The intro's dawn: the Stem mark's view (a sky, a coral sun and the curve of a deep-blue planet
/// with its mint atmosphere) seen through a window in the paper. The window changes shape at each
/// step and the sun rises a little more each time, so the day breaks as the intro goes on.
///
/// All Core Animation: frames move in one UIKit spring and the sky's colors in a matching layer
/// animation, so the render server runs them at up to 120 Hz and the main thread only starts them.
final class DawnView: UIView {
    /// One arrangement of the dawn.
    struct Scene: Equatable {
        /// The window, in this view's coordinates.
        var frame: CGRect
        var cornerRadius: CGFloat
        /// How far the sun is up: 0 just peeking over the planet, 1 well up in a morning sky.
        var rise: CGFloat
        /// The horizon, as a share of the window's height from its top.
        var horizon: CGFloat = 0.72
    }

    private let opening = UIView()
    private let sky = GradientView()
    private let glow = GradientView()
    private let sun = GradientView()
    private let rim = UIView()
    private let planet = GradientView()
    private(set) var scene: Scene?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        opening.clipsToBounds = true
        opening.layer.cornerCurve = .continuous
        addSubview(opening)

        sky.gradient.locations = [0, 0.6, 1]
        sky.gradient.startPoint = CGPoint(x: 0.5, y: 0)
        sky.gradient.endPoint = CGPoint(x: 0.5, y: 1)
        glow.gradient.type = .radial
        glow.gradient.colors = [BrandArt.sun[0].withAlphaComponent(0.85).cgColor, BrandArt.peach.withAlphaComponent(0.35).cgColor,
                                BrandArt.peach.withAlphaComponent(0).cgColor]
        glow.gradient.locations = [0, 0.35, 1]
        glow.gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.gradient.endPoint = CGPoint(x: 1, y: 1)
        sun.gradient.type = .radial
        sun.gradient.colors = BrandArt.sun.map(\.cgColor)
        sun.gradient.locations = [0, 0.42, 1]
        sun.gradient.startPoint = CGPoint(x: 0.5, y: 0.375)
        sun.gradient.endPoint = CGPoint(x: 1.125, y: 1.0)
        sun.clipsToBounds = true
        rim.backgroundColor = BrandArt.rim
        rim.layer.shadowColor = BrandArt.rim.cgColor
        rim.layer.shadowOpacity = 0.8
        rim.layer.shadowRadius = 5
        rim.layer.shadowOffset = .zero
        planet.gradient.type = .radial
        planet.gradient.colors = BrandArt.planet.map(\.cgColor)
        planet.gradient.startPoint = CGPoint(x: 0.5, y: 0)
        planet.gradient.endPoint = CGPoint(x: 0.75, y: 0.25)
        planet.clipsToBounds = true
        for view in [sky, glow, sun, rim, planet] { opening.addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Moves the dawn to `scene`. Animated, it is one soft spring (a 0.2 s crossfade under Reduce
    /// Motion).
    func apply(_ scene: Scene, animation: Animation? = nil) {
        guard scene != self.scene else { return }
        let first = self.scene == nil
        self.scene = scene
        let colors = Self.sky(scene)
        guard let animation, !first else {
            UIView.performWithoutAnimation { layout(scene) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sky.gradient.colors = colors
            CATransaction.commit()
            return
        }
        if Motion.prefersCrossfade {
            Motion.crossfade(self) {
                self.layout(scene)
                self.sky.gradient.colors = colors
            }
            return
        }
        let fade = CABasicAnimation(keyPath: "colors")
        fade.fromValue = (sky.gradient.presentation() ?? sky.gradient).colors
        fade.toValue = colors
        fade.duration = 0.9
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        fade.preferredFrameRateRange = StemMarkView.frameRate
        sky.gradient.add(fade, forKey: "colors")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sky.gradient.colors = colors
        CATransaction.commit()
        Motion.animate(animation) { self.layout(scene) }
    }

    private func layout(_ scene: Scene) {
        let frame = scene.frame
        opening.frame = frame
        opening.layer.cornerRadius = scene.cornerRadius
        let size = frame.size
        sky.frame = CGRect(origin: .zero, size: size)
        let horizonY = size.height * scene.horizon
        // The planet is a wide, shallow curve: a huge circle whose top is the horizon.
        let radius = max(size.width, 320) * 1.5
        let planetCenter = CGPoint(x: size.width * 0.4, y: horizonY + radius)
        planet.frame = CGRect(x: planetCenter.x - radius, y: planetCenter.y - radius, width: 2 * radius, height: 2 * radius)
        planet.layer.cornerRadius = radius
        rim.frame = planet.frame.insetBy(dx: -2.5, dy: -2.5)
        rim.layer.cornerRadius = radius + 2.5
        // The sun: small in a narrow band, larger in a tall window; it climbs with `rise`.
        let sunRadius = min(max(min(size.height, size.width) * 0.09, 10), 34)
        let climb = -0.3 * sunRadius + (horizonY * 0.5 + 0.3 * sunRadius) * scene.rise
        let sunCenter = CGPoint(x: size.width * 0.7, y: horizonY - climb)
        sun.frame = CGRect(x: sunCenter.x - sunRadius, y: sunCenter.y - sunRadius, width: 2 * sunRadius, height: 2 * sunRadius)
        sun.layer.cornerRadius = sunRadius
        let glowRadius = sunRadius * 5
        glow.frame = CGRect(x: sunCenter.x - glowRadius, y: sunCenter.y - glowRadius, width: 2 * glowRadius, height: 2 * glowRadius)
        glow.alpha = 0.55 + 0.35 * scene.rise
    }

    /// The sky lightens from dawn toward morning as the sun rises.
    private static func sky(_ scene: Scene) -> [CGColor] {
        let dawn = BrandArt.dawnSky
        let morning = BrandArt.morningSky
        let t = min(max(scene.rise, 0), 1)
        return zip(dawn, morning).map { $0.mix(with: $1, by: t).cgColor }
    }
}

/// A view whose layer is a gradient, so its frame moves in UIKit animations.
private final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    var gradient: CAGradientLayer { layer as! CAGradientLayer }
}

private extension UIColor {
    func mix(with other: UIColor, by t: CGFloat) -> UIColor {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: a1 + (a2 - a1) * t)
    }
}
#endif
