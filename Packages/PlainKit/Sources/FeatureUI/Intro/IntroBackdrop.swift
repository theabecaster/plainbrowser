#if canImport(UIKit)
import DesignSystem
import UIKit

/// The intro's one continuous field: a dawn gradient with three soft blooms that drift slowly and
/// move to a new arrangement at each step, so the background never cuts between screens.
///
/// All Core Animation: the drift and the moves run on the render server, not the main thread.
final class IntroBackdrop: UIView {
    /// One arrangement of the field.
    struct Mood: Equatable {
        /// The base gradient, top leading to bottom trailing.
        var base: [UIColor]
        /// Three blooms: color, opacity, and centre in unit coordinates of the view.
        var blooms: [Bloom]

        struct Bloom: Equatable {
            var color: UIColor
            var alpha: CGFloat
            var center: CGPoint
        }
    }

    private let base = CAGradientLayer()
    private let blooms = (0..<3).map { _ in CAGradientLayer() }
    private(set) var mood: Mood
    /// Each bloom's diameter, as a share of the view's longer side.
    private static let bloomSize: CGFloat = 1.25

    init(mood: Mood) {
        self.mood = mood
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        base.startPoint = CGPoint(x: 0.1, y: 0)
        base.endPoint = CGPoint(x: 0.9, y: 1)
        layer.addSublayer(base)
        for bloom in blooms {
            bloom.type = .radial
            bloom.startPoint = CGPoint(x: 0.5, y: 0.5)
            bloom.endPoint = CGPoint(x: 1, y: 1)
            layer.addSublayer(bloom)
        }
        apply(mood)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.frame = bounds
        let side = max(bounds.width, bounds.height) * Self.bloomSize
        for (layer, bloom) in zip(blooms, mood.blooms) {
            layer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            layer.position = point(bloom.center)
        }
        CATransaction.commit()
        startDrift()
    }

    private func point(_ unit: CGPoint) -> CGPoint {
        CGPoint(x: bounds.width * unit.x, y: bounds.height * unit.y)
    }

    private func apply(_ mood: Mood) {
        base.colors = mood.base.map(\.cgColor)
        for (layer, bloom) in zip(blooms, mood.blooms) {
            layer.colors = [bloom.color.withAlphaComponent(bloom.alpha).cgColor, bloom.color.withAlphaComponent(0).cgColor]
            layer.position = point(bloom.center)
        }
    }

    /// Moves the field to `mood` over `duration`; under Reduce Motion it crossfades in 0.2 s.
    func setMood(_ mood: Mood, duration: CFTimeInterval = 0.9) {
        guard mood != self.mood else { return }
        let reduce = Motion.prefersCrossfade
        let length = reduce ? Motion.crossfadeDuration : duration
        let timing = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        func animate(_ layer: CALayer, _ keyPath: String, to value: Any?) {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = (layer.presentation() ?? layer).value(forKeyPath: keyPath)
            animation.toValue = value
            animation.duration = length
            animation.timingFunction = timing
            animation.preferredFrameRateRange = StemMarkView.frameRate
            layer.add(animation, forKey: "mood." + keyPath)
        }
        self.mood = mood
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let colors = mood.base.map(\.cgColor)
        animate(base, "colors", to: colors)
        base.colors = colors
        for (layer, bloom) in zip(blooms, mood.blooms) {
            let bloomColors = [bloom.color.withAlphaComponent(bloom.alpha).cgColor, bloom.color.withAlphaComponent(0).cgColor]
            animate(layer, "colors", to: bloomColors)
            layer.colors = bloomColors
            // Under Reduce Motion the blooms change color in place; they never travel.
            // Additive, like the drift: a move that interrupts another adds to it instead of
            // jumping, and the drift keeps running underneath.
            if !reduce {
                let target = point(bloom.center)
                let move = CABasicAnimation(keyPath: "position")
                move.fromValue = NSValue(cgPoint: CGPoint(x: layer.position.x - target.x, y: layer.position.y - target.y))
                move.toValue = NSValue(cgPoint: .zero)
                move.isAdditive = true
                move.duration = length
                move.timingFunction = timing
                move.preferredFrameRateRange = StemMarkView.frameRate
                layer.add(move, forKey: nil)
                layer.position = target
            }
        }
        CATransaction.commit()
    }

    /// A slow additive wander for each bloom, so the field is alive but never busy. None under
    /// Reduce Motion.
    private func startDrift() {
        guard !Motion.prefersCrossfade, bounds.width > 0 else { return }
        let reach = min(bounds.width, bounds.height) * 0.08
        let periods: [CFTimeInterval] = [11, 13.5, 9.5]
        for (index, layer) in blooms.enumerated() where layer.animation(forKey: "drift") == nil {
            let drift = CAKeyframeAnimation(keyPath: "position")
            let sign: CGFloat = index.isMultiple(of: 2) ? 1 : -1
            drift.values = [
                CGPoint.zero, CGPoint(x: reach * sign, y: reach * 0.6), CGPoint(x: reach * 0.3, y: -reach * sign),
                CGPoint(x: -reach * 0.7 * sign, y: reach * 0.2), CGPoint.zero,
            ].map { NSValue(cgPoint: $0) }
            drift.isAdditive = true
            drift.calculationMode = .cubic
            drift.duration = periods[index]
            drift.repeatCount = .infinity
            // A slow drift needs no high frame rate; let the system pick a low one.
            drift.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 30)
            layer.add(drift, forKey: "drift")
        }
    }
}

extension IntroBackdrop.Mood {
    private typealias B = Bloom
    private typealias A = BrandArt

    /// The splash: night turning to dawn.
    static let splash = Self(base: [A.nightLagoon, A.dawnViolet], blooms: [
        B(color: A.lagoon, alpha: 0.75, center: CGPoint(x: 0.15, y: 0.2)),
        B(color: A.bloomViolet, alpha: 0.8, center: CGPoint(x: 0.9, y: 0.7)),
        B(color: A.coral, alpha: 0.35, center: CGPoint(x: 0.6, y: 1.15)),
    ])
    /// The promise: the sun comes up on the trailing side.
    static let promise = Self(base: [A.dawnViolet, A.lagoon], blooms: [
        B(color: A.mint, alpha: 0.75, center: CGPoint(x: 0.0, y: 0.05)),
        B(color: A.coral, alpha: 0.9, center: CGPoint(x: 1.05, y: 0.72)),
        B(color: A.peach, alpha: 0.6, center: CGPoint(x: 0.55, y: 1.1)),
    ])
    /// What's inside: mint light from the top, violet and coral below.
    static let inside = Self(base: [A.lagoon, A.dawnViolet], blooms: [
        B(color: A.mint, alpha: 0.8, center: CGPoint(x: 0.05, y: 0.0)),
        B(color: A.bloomViolet, alpha: 0.85, center: CGPoint(x: 0.95, y: 0.5)),
        B(color: A.coral, alpha: 0.7, center: CGPoint(x: 0.9, y: 1.05)),
    ])
    /// The icon picker: coral on the trailing edge, mint low.
    static let icons = Self(base: [A.dawnViolet, A.lagoon], blooms: [
        B(color: A.bloomViolet, alpha: 0.8, center: CGPoint(x: 0.35, y: 0.0)),
        B(color: A.coral, alpha: 0.85, center: CGPoint(x: 1.05, y: 0.4)),
        B(color: A.mint, alpha: 0.75, center: CGPoint(x: 0.0, y: 0.95)),
    ])
    /// The blocking demo: darker, so the white page stands out.
    static let blocking = Self(base: [A.nightLagoon, A.dawnViolet], blooms: [
        B(color: A.coral, alpha: 0.7, center: CGPoint(x: 1.0, y: 0.05)),
        B(color: A.bloomViolet, alpha: 0.75, center: CGPoint(x: 0.45, y: 0.5)),
        B(color: A.lagoon, alpha: 0.9, center: CGPoint(x: 0.15, y: 0.95)),
    ])
    /// The default-browser step: daylight on paper.
    static let paper = Self(base: [A.paperField, A.paperField], blooms: [
        B(color: A.mint, alpha: 0.35, center: CGPoint(x: 0.05, y: 0.0)),
        B(color: A.coral, alpha: 0.3, center: CGPoint(x: 1.0, y: 0.2)),
        B(color: A.lagoon, alpha: 0.25, center: CGPoint(x: 0.5, y: 1.1)),
    ])
}
#endif
