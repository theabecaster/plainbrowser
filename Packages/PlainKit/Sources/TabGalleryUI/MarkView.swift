#if canImport(UIKit)
import DesignSystem
import PerfSignposts
import UIKit

/// Plain's Stem mark, drawn in the app (Brand/identity.md): a thick paper ring around a dawn (a
/// coral sun rising over the rim of a deep-blue planet), a short paper stem down its left side so a
/// P hides in it, and the ring's top-right edge folded in, coral side up. Layers only, built once
/// per size, so showing it costs nothing. With `isSpinnable`, a finger spins it around the ring and
/// it keeps turning with the flick's momentum: the start screen answers a touch.
public final class MarkView: UIView {
    /// Whether a finger can spin it.
    public var isSpinnable = false {
        didSet { spinGesture.isEnabled = isSpinnable }
    }

    private let spinner = UIView()
    private let paper = CAShapeLayer()
    private let dawn = CALayer()
    private let dawnMask = CAShapeLayer()
    private let sky = CAGradientLayer()
    private let sun = CAGradientLayer()
    private let planet = CAGradientLayer()
    private let planetMask = CAShapeLayer()
    private let atmosphere = CAShapeLayer()
    private let fold = CAGradientLayer()
    private let foldMask = CAShapeLayer()
    private let spinGesture = UIPanGestureRecognizer()
    private var laidOutSize: CGSize = .zero
    /// The ring's center in this view, the spin's pivot.
    private var ringCenter: CGPoint = .zero

    private var angle: CGFloat = 0
    private var angularVelocity: CGFloat = 0
    private var lastTouchAngle: CGFloat = 0
    private var link: UIUpdateLink?
    private var lastTime: TimeInterval?
    /// How much spin is left after one second: a flick turns for about two seconds.
    private static let spinFriction: CGFloat = 0.12

    /// The mark's proportions, from the icon (Brand/tools/gen_icon.py): width over height.
    public static let aspect: CGFloat = 600.0 / 620.0

    override public init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        addSubview(spinner)
        spinner.isUserInteractionEnabled = false

        paper.fillColor = Palette.Mark.paper.cgColor
        paper.shadowColor = Palette.Mark.shadow.cgColor
        paper.shadowOpacity = 0.2
        paper.shadowOffset = CGSize(width: 0, height: 3)
        paper.shadowRadius = 6

        sky.colors = Palette.Mark.sky.map(\.cgColor)
        sky.locations = [0, 0.5, 0.82]
        sun.type = .radial
        sun.colors = Palette.Mark.sun.map(\.cgColor)
        sun.startPoint = CGPoint(x: 0.5, y: 0.5)
        sun.endPoint = CGPoint(x: 1, y: 1)
        planet.colors = Palette.Mark.planet.map(\.cgColor)
        planet.mask = planetMask
        atmosphere.fillColor = UIColor.clear.cgColor
        atmosphere.strokeColor = Palette.Mark.atmosphere.cgColor
        fold.colors = Palette.Mark.fold.map(\.cgColor)
        fold.mask = foldMask
        fold.shadowColor = Palette.Mark.shadow.cgColor

        dawn.mask = dawnMask
        for layer in [sky, sun, planet, atmosphere] { dawn.addSublayer(layer) }
        spinner.layer.addSublayer(dawn)
        spinner.layer.addSublayer(paper)
        spinner.layer.addSublayer(fold)

        spinGesture.addTarget(self, action: #selector(spun(_:)))
        spinGesture.isEnabled = false
        addGestureRecognizer(spinGesture)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override public func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size != laidOutSize, size.width > 0, size.height > 0 else { return }
        laidOutSize = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        buildLayers(in: size)
        CATransaction.commit()
    }

    /// The geometry in the icon's own units (a 600 x 620 box: ring radius 300, band 90, the stem
    /// one band wide down the left), scaled to fit `size`.
    private func buildLayers(in size: CGSize) {
        let unit = min(size.width / 600, size.height / 620)
        let origin = CGPoint(x: (size.width - 600 * unit) / 2, y: (size.height - 620 * unit) / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * unit, y: origin.y + y * unit) }
        let center = p(300, 300)
        ringCenter = center
        let outer = 300 * unit, inner = 210 * unit

        spinner.layer.anchorPoint = CGPoint(x: center.x / size.width, y: center.y / size.height)
        spinner.bounds = CGRect(origin: .zero, size: size)
        spinner.center = center

        // Paper: the ring and the stem, less the corner folded over the crease.
        let ring = UIBezierPath(arcCenter: center, radius: outer, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
        let hole = UIBezierPath(arcCenter: center, radius: inner, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
        let stem = UIBezierPath(
            roundedRect: CGRect(origin: p(0, 300), size: CGSize(width: 90 * unit, height: 320 * unit)),
            byRoundingCorners: [.bottomLeft, .bottomRight], cornerRadii: CGSize(width: 10 * unit, height: 10 * unit)
        ).cgPath
        let band = ring.subtracting(hole).union(stem)
        // The crease runs across the band's top-right, about 45 degrees.
        let creaseA = p(318, -40), creaseB = p(640, 282)
        let beyond = CGMutablePath()
        beyond.move(to: creaseA)
        beyond.addLine(to: creaseB)
        beyond.addLine(to: p(900, 282))
        beyond.addLine(to: p(900, -300))
        beyond.addLine(to: p(318, -300))
        beyond.closeSubpath()
        let cut = band.subtracting(beyond)
        let flapShape = band.intersection(beyond)
        paper.path = cut
        paper.shadowPath = cut

        // The flap is the folded-over paper: the removed corner mirrored across the crease.
        let dx = creaseB.x - creaseA.x, dy = creaseB.y - creaseA.y
        let length = max(1, hypot(dx, dy))
        let ux = dx / length, uy = dy / length
        let reflect = CGAffineTransform(
            a: ux * ux - uy * uy, b: 2 * ux * uy, c: 2 * ux * uy, d: uy * uy - ux * ux, tx: 0, ty: 0
        )
        var transform = CGAffineTransform(translationX: -creaseA.x, y: -creaseA.y)
            .concatenating(reflect)
            .concatenating(CGAffineTransform(translationX: creaseA.x, y: creaseA.y))
        let flap = flapShape.copy(using: &transform) ?? flapShape
        let flapBox = flap.boundingBoxOfPath
        fold.frame = flapBox
        var toFold = CGAffineTransform(translationX: -flapBox.minX, y: -flapBox.minY)
        foldMask.path = flap.copy(using: &toFold)
        // The coral runs from the crease out to the free edge.
        fold.startPoint = CGPoint(x: 1, y: 0)
        fold.endPoint = CGPoint(x: 0, y: 1)
        fold.shadowPath = foldMask.path
        fold.shadowOpacity = 0.25
        fold.shadowRadius = 4 * unit
        fold.shadowOffset = CGSize(width: -2 * unit, height: 3 * unit)

        // The dawn inside the ring.
        let disc = CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2)
        dawn.frame = disc
        let local = CGRect(origin: .zero, size: disc.size)
        dawnMask.path = UIBezierPath(ovalIn: local).cgPath
        sky.frame = local
        let horizon = inner * 1.3
        let sunRadius = inner * 0.28
        sun.frame = CGRect(x: inner - sunRadius, y: horizon - sunRadius * 1.25, width: sunRadius * 2, height: sunRadius * 2)
        sun.cornerRadius = sunRadius
        let planetRadius = inner * 3
        let planetCircle = CGRect(x: inner - planetRadius, y: horizon, width: planetRadius * 2, height: planetRadius * 2)
        planet.frame = local
        planetMask.path = UIBezierPath(ovalIn: planetCircle).cgPath
        atmosphere.frame = local
        atmosphere.lineWidth = max(1, inner * 0.03)
        atmosphere.path = UIBezierPath(ovalIn: planetCircle.insetBy(dx: -atmosphere.lineWidth / 2, dy: -atmosphere.lineWidth / 2)).cgPath
    }

    // MARK: Spin

    private func touchAngle(_ gesture: UIGestureRecognizer) -> CGFloat {
        let point = gesture.location(in: self)
        return atan2(point.y - ringCenter.y, point.x - ringCenter.x)
    }

    @objc private func spun(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopSpinning()
            lastTouchAngle = touchAngle(gesture)
            Signposts.signposter.emitEvent(Signposts.startMarkSpin)
        case .changed:
            let now = touchAngle(gesture)
            var delta = now - lastTouchAngle
            if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
            lastTouchAngle = now
            setAngle(angle + delta)
        case .ended, .cancelled:
            // The flick's speed around the pivot: the finger's velocity across the radius.
            let point = gesture.location(in: self)
            let rx = point.x - ringCenter.x, ry = point.y - ringCenter.y
            let velocity = gesture.velocity(in: self)
            angularVelocity = (rx * velocity.y - ry * velocity.x) / max(rx * rx + ry * ry, 400)
            if !Motion.prefersCrossfade, abs(angularVelocity) > 0.3 { startSpinning() }
        default:
            break
        }
    }

    private func setAngle(_ value: CGFloat) {
        angle = value.truncatingRemainder(dividingBy: 2 * .pi)
        spinner.transform = CGAffineTransform(rotationAngle: angle)
    }

    private func startSpinning() {
        guard link == nil else { return }
        let link = UIUpdateLink(view: self)
        link.addAction { [weak self] _, info in self?.step(to: info.modelTime) }
        link.preferredFrameRateRange = SpringDriver.frameRateRange
        link.requiresContinuousUpdates = true
        link.isEnabled = true
        self.link = link
        lastTime = nil
    }

    private func step(to time: TimeInterval) {
        let delta = lastTime.map { min(time - $0, 1.0 / 30) } ?? 0
        lastTime = time
        guard delta > 0 else { return }
        setAngle(angle + angularVelocity * delta)
        angularVelocity *= pow(Self.spinFriction, delta)
        if abs(angularVelocity) < 0.05 { stopSpinning() }
    }

    private func stopSpinning() {
        link?.isEnabled = false
        link = nil
        lastTime = nil
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopSpinning() }
    }
}
#endif
