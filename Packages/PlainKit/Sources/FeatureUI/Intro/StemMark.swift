#if canImport(UIKit)
import DesignSystem
import UIKit

/// The Stem mark's shapes in the icon's 1024 canvas: the same geometry and values as
/// Brand/tools/gen_icon.py (`P`), so the animated mark lands exactly on the icon.
nonisolated struct StemGeometry {
    static let center = CGPoint(x: 540, y: 488)
    static let outer: CGFloat = 300
    static let inner: CGFloat = 212
    /// The crease: its normal's direction (degrees, y down) and its distance from the centre.
    static let creaseAngle: CGFloat = -45
    static let creaseDistance: CGFloat = 222
    static let stemWidth: CGFloat = 88
    static let stemDrop: CGFloat = 20
    static let footRadius: CGFloat = 14
    static let web: CGFloat = 14
    static let horizon: CGFloat = 0.26
    static let sunOffset: CGFloat = -0.14
    static let sunRadius: CGFloat = 58
    /// The mark's own box in the canvas (ring, stem and its drop), for fitting it into a view.
    static let box = CGRect(x: center.x - outer, y: center.y - outer, width: 2 * outer, height: 2 * outer + stemDrop)

    /// Unit normal of the crease, pointing out of the ring (to the top right).
    let normal: CGPoint
    /// Unit direction along the crease: the fold's rotation axis.
    let axis: CGPoint
    /// A point on the crease, the fold's anchor.
    let creasePoint: CGPoint
    /// The ring (minus the folded-away cap), the stem and the small web between them, with the
    /// window cut out. Non-zero fill.
    let paper: CGPath
    /// The cap the fold removes, flat, where it was before folding.
    let cap: CGPath
    /// The cap mirrored over the crease: where the folded flap lies.
    let flap: CGPath
    /// The window the dawn shows through (a little larger than the hole, so the ring covers its edge).
    let window: CGPath
    /// Horizon height and the sun's centre, in the canvas.
    let horizonY: CGFloat
    let sunCenter: CGPoint

    init() {
        let c = Self.center
        let a = Self.creaseAngle * .pi / 180
        normal = CGPoint(x: cos(a), y: sin(a))
        axis = CGPoint(x: -normal.y, y: normal.x)
        creasePoint = c + normal * Self.creaseDistance

        let circle = Self.circle(c, Self.outer)
        let ringOut = Self.clip(circle, through: creasePoint, normal: normal, keepPositive: false)
        let removed = Self.clip(circle, through: creasePoint, normal: normal, keepPositive: true)

        // The stem hangs from the ring's left tangent, a band's width wide, with a near-square foot.
        let x0 = c.x - Self.outer, x1 = x0 + Self.stemWidth
        let foot = c.y + Self.outer + Self.stemDrop
        let stem = Self.fillet(
            [CGPoint(x: x0, y: c.y), CGPoint(x: x1, y: c.y), CGPoint(x: x1, y: foot), CGPoint(x: x0, y: foot)],
            radii: [0, 0, Self.footRadius, Self.footRadius]
        )
        // The small fillet of paper in the inside corner between the stem and the ring.
        let yj = c.y + sqrt(Self.outer * Self.outer - (x1 - c.x) * (x1 - c.x))
        let tj = atan2(yj - c.y, x1 - c.x)
        let pa = CGPoint(x: x1, y: yj + Self.web), pj = CGPoint(x: x1, y: yj)
        let pb = CGPoint(x: c.x + Self.outer * cos(tj - Self.web / Self.outer),
                         y: c.y + Self.outer * sin(tj - Self.web / Self.outer))
        var web = (0...16).map { k -> CGPoint in
            let t = CGFloat(k) / 16
            return pa * ((1 - t) * (1 - t)) + pj * (2 * (1 - t) * t) + pb * (t * t)
        }
        web.append(CGPoint(x: x1 - 6, y: yj - 6))

        let paper = CGMutablePath()
        for shape in [ringOut, stem, web] { paper.addLines(between: Self.oriented(shape, 1)); paper.closeSubpath() }
        paper.addLines(between: Self.oriented(Self.circle(c, Self.inner), -1))
        paper.closeSubpath()
        self.paper = paper
        cap = Self.polygon(removed)
        flap = Self.polygon(Self.reflect(removed, through: creasePoint, direction: axis))
        window = CGPath(ellipseIn: CGRect(x: c.x - Self.inner - 10, y: c.y - Self.inner - 10,
                                          width: 2 * (Self.inner + 10), height: 2 * (Self.inner + 10)), transform: nil)
        horizonY = c.y + Self.inner * Self.horizon
        sunCenter = CGPoint(x: c.x + Self.inner * Self.sunOffset, y: horizonY)
    }

    // MARK: Polygon helpers (the same as the generator's)

    static func circle(_ c: CGPoint, _ r: CGFloat, segments: Int = 360) -> [CGPoint] {
        (0..<segments).map { k in
            let t = 2 * CGFloat.pi * CGFloat(k) / CGFloat(segments)
            return CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t))
        }
    }

    static func clip(_ points: [CGPoint], through p0: CGPoint, normal n: CGPoint, keepPositive: Bool) -> [CGPoint] {
        func side(_ p: CGPoint) -> CGFloat { (p.x - p0.x) * n.x + (p.y - p0.y) * n.y }
        var out: [CGPoint] = []
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            let sa = side(a), sb = side(b)
            let inA = (sa >= 0) == keepPositive, inB = (sb >= 0) == keepPositive
            if inA { out.append(a) }
            if inA != inB { out.append(a + (b - a) * (sa / (sa - sb))) }
        }
        return out
    }

    static func reflect(_ points: [CGPoint], through p0: CGPoint, direction d: CGPoint) -> [CGPoint] {
        points.map { p in
            let t = (p.x - p0.x) * d.x + (p.y - p0.y) * d.y
            let foot = p0 + d * t
            return foot * 2 - p
        }
    }

    static func fillet(_ points: [CGPoint], radii: [CGFloat], segments: Int = 20) -> [CGPoint] {
        var out: [CGPoint] = []
        for i in points.indices {
            let p = points[i], a = points[(i + points.count - 1) % points.count], b = points[(i + 1) % points.count]
            let r = radii[i]
            guard r > 0 else { out.append(p); continue }
            let u = (a - p).unit, w = (b - p).unit
            let angle = acos(max(-1, min(1, u.x * w.x + u.y * w.y)))
            let d = r / tan(angle / 2)
            let t1 = p + u * d, t2 = p + w * d
            let center = p + (u + w).unit * (r / sin(angle / 2))
            let a1 = atan2(t1.y - center.y, t1.x - center.x), a2 = atan2(t2.y - center.y, t2.x - center.x)
            var da = a2 - a1
            while da > .pi { da -= 2 * .pi }
            while da < -.pi { da += 2 * .pi }
            for k in 0...segments {
                let t = a1 + da * CGFloat(k) / CGFloat(segments)
                out.append(CGPoint(x: center.x + r * cos(t), y: center.y + r * sin(t)))
            }
        }
        return out
    }

    static func area(_ points: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    static func oriented(_ points: [CGPoint], _ sign: CGFloat) -> [CGPoint] {
        area(points) * sign > 0 ? points : points.reversed()
    }

    static func polygon(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }
}

private nonisolated extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
    var unit: CGPoint { let l = hypot(x, y); return CGPoint(x: x / l, y: y / l) }
}

/// The Stem mark drawn with Core Animation layers, so it can assemble on the splash: the stem and
/// ring draw like a written P, the dawn rises in the window, and the coral fold folds over along
/// its crease. Static elsewhere (the default-browser step, the empty-tab card).
///
/// Every animation runs on the render server at up to 120 Hz; the main thread only starts them.
final class StemMarkView: UIView {
    private let geometry = StemGeometry()
    /// Fills the view; the whole mark's settle animates here, apart from the canvas's fit.
    private let stage = CALayer()
    /// The 1024 canvas, scaled to fit the mark's box into the view.
    private let canvas = CALayer()
    /// The assembly's timed steps (mask off, landing, done), cancelled by a skip.
    private var pending: [Task<Void, Never>] = []
    private let viewLayer = CALayer()
    private let sky = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let sun = CAGradientLayer()
    private let rim = CAShapeLayer()
    private let planet = CAGradientLayer()
    /// The ring and the flap; masked by the drawing stroke while the P is written.
    private let ringGroup = CALayer()
    private let paper = CALayer()
    private let flapShadow = CALayer()
    private let flap = CATransformLayer()
    private let flapFront = CALayer()
    private let flapBack = CAGradientLayer()
    private let drawMask = CALayer()
    private let stemStroke = CAShapeLayer()
    private let bowlStroke = CAShapeLayer()
    /// The ring's soft shadow on the paper under it, so cream paper holds its edge on cream paper.
    private let shade = CALayer()
    private let shadowed: Bool

    /// Total length of `assemble()`: under the 1.2 s budget.
    static let assembleDuration: CFTimeInterval = 1.12

    /// - Parameter shadowed: casts the ring's shadow on the paper under it (the intro's paper).
    init(shadowed: Bool = false) {
        self.shadowed = shadowed
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Plain"
        accessibilityTraits = .image
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let box = StemGeometry.box
        let scale = min(bounds.width / box.width, bounds.height / box.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = bounds
        canvas.bounds = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        canvas.anchorPoint = CGPoint(x: box.midX / 1024, y: box.midY / 1024)
        canvas.position = CGPoint(x: bounds.midX, y: bounds.midY)
        canvas.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
    }

    // MARK: Building

    private func build() {
        layer.addSublayer(stage)
        stage.addSublayer(canvas)
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let g = geometry
        let c = StemGeometry.center
        let r = StemGeometry.inner + 10

        if shadowed {
            // A shadow path, not the layers' alpha: no offscreen pass.
            let outline = CGMutablePath()
            outline.addPath(g.paper)
            outline.addPath(g.flap)
            shade.frame = full
            shade.shadowPath = outline
            shade.shadowColor = BrandArt.ink.cgColor
            shade.shadowOpacity = 0.14
            shade.shadowRadius = 40
            shade.shadowOffset = CGSize(width: 0, height: 22)
            canvas.addSublayer(shade)
        }

        // The view: sky, the sun's glow, the sun, the planet's mint rim and the planet.
        viewLayer.frame = full
        let windowMask = CAShapeLayer()
        windowMask.path = g.window
        viewLayer.mask = windowMask
        let viewBox = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        sky.frame = viewBox
        sky.colors = BrandArt.dawnSky.map(\.cgColor)
        sky.locations = [0, 0.6, 1]
        sky.startPoint = CGPoint(x: 0.5, y: 0)
        sky.endPoint = CGPoint(x: 0.5, y: (g.horizonY - viewBox.minY) / viewBox.height)
        glow.type = .radial
        glow.frame = CGRect(x: g.sunCenter.x - 200, y: g.sunCenter.y - 200, width: 400, height: 400)
        glow.colors = [BrandArt.sun[0].cgColor, BrandArt.sun[0].withAlphaComponent(0).cgColor]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        let sr = StemGeometry.sunRadius
        sun.type = .radial
        sun.frame = CGRect(x: g.sunCenter.x - sr, y: g.sunCenter.y - sr, width: 2 * sr, height: 2 * sr)
        sun.cornerRadius = sr
        sun.masksToBounds = true
        sun.colors = BrandArt.sun.map(\.cgColor)
        sun.locations = [0, 0.42, 1]
        sun.startPoint = CGPoint(x: 0.5, y: 0.375)
        sun.endPoint = CGPoint(x: 1.125, y: 1.0)
        let pr: CGFloat = 520
        let planetCenter = CGPoint(x: g.sunCenter.x, y: g.horizonY + pr)
        rim.path = CGPath(ellipseIn: CGRect(x: planetCenter.x - pr - 4, y: planetCenter.y - pr - 4,
                                            width: 2 * pr + 8, height: 2 * pr + 8), transform: nil)
        rim.fillColor = BrandArt.rim.cgColor
        rim.opacity = 0.9
        rim.shadowColor = BrandArt.rim.cgColor
        rim.shadowOpacity = 0.9
        rim.shadowRadius = 6
        rim.shadowOffset = .zero
        planet.type = .radial
        planet.frame = CGRect(x: planetCenter.x - pr, y: planetCenter.y - pr, width: 2 * pr, height: 2 * pr)
        planet.cornerRadius = pr
        planet.masksToBounds = true
        planet.colors = BrandArt.planet.map(\.cgColor)
        // Centred on the sun (the planet's top), reaching the window's bottom.
        planet.startPoint = CGPoint(x: 0.5, y: 0)
        planet.endPoint = CGPoint(x: 0.5 + (viewBox.maxY - g.horizonY + 40) / (2 * pr), y: (viewBox.maxY - g.horizonY + 40) / (2 * pr))
        for sub in [sky, glow, sun, rim, planet] { viewLayer.addSublayer(sub) }
        canvas.addSublayer(viewLayer)

        // The paper: soft top-left light and warm lower right, like the icon's ring.
        ringGroup.frame = full
        paper.frame = full
        let paperMask = CAShapeLayer()
        paperMask.path = g.paper
        paper.mask = paperMask
        for sub in Self.paperFill(full) { paper.addSublayer(sub) }
        // The flap's contact shadow on the ring, under the lifted edge.
        flapShadow.frame = full
        flapShadow.shadowPath = g.flap
        flapShadow.shadowColor = BrandArt.flapShade.cgColor
        flapShadow.shadowRadius = 9
        flapShadow.shadowOffset = CGSize(width: 3, height: 9)
        flapShadow.shadowOpacity = 0.32
        paper.addSublayer(flapShadow)
        ringGroup.addSublayer(paper)

        // The flap turns about the crease: paper on the front, coral on the back. The back is
        // double-sided, so after a half turn its far side shows, mirrored onto the flap's place.
        flap.bounds = full
        flap.anchorPoint = CGPoint(x: g.creasePoint.x / 1024, y: g.creasePoint.y / 1024)
        flap.position = g.creasePoint
        flapBack.frame = full
        flapBack.colors = BrandArt.curl.map(\.cgColor)
        flapBack.locations = [0, 0.18, 0.6, 1]
        let edge = g.creasePoint + g.normal * (StemGeometry.outer - StemGeometry.creaseDistance)
        flapBack.startPoint = CGPoint(x: g.creasePoint.x / 1024, y: g.creasePoint.y / 1024)
        flapBack.endPoint = CGPoint(x: edge.x / 1024, y: edge.y / 1024)
        let backMask = CAShapeLayer()
        backMask.path = g.cap
        flapBack.mask = backMask
        flapBack.isDoubleSided = true
        flapFront.frame = full
        let frontMask = CAShapeLayer()
        frontMask.path = g.cap
        flapFront.mask = frontMask
        for sub in Self.paperFill(full) { flapFront.addSublayer(sub) }
        flapFront.isDoubleSided = false
        flapFront.zPosition = 0.5
        flap.addSublayer(flapBack)
        flap.addSublayer(flapFront)
        ringGroup.addSublayer(flap)
        canvas.addSublayer(ringGroup)

        // The stroke that writes the P: up the stem, then round the bowl, clockwise from the left.
        drawMask.frame = full
        let x = c.x - StemGeometry.outer + StemGeometry.stemWidth / 2
        let stemPath = CGMutablePath()
        stemPath.move(to: CGPoint(x: x, y: StemGeometry.box.maxY + 10))
        stemPath.addLine(to: CGPoint(x: x, y: c.y))
        stemStroke.path = stemPath
        stemStroke.lineWidth = StemGeometry.stemWidth + 24
        let bowl = UIBezierPath(arcCenter: c, radius: 270, startAngle: .pi, endAngle: 3 * .pi, clockwise: true)
        bowlStroke.path = bowl.cgPath
        bowlStroke.lineWidth = 150
        for stroke in [stemStroke, bowlStroke] {
            stroke.frame = full
            stroke.fillColor = nil
            stroke.strokeColor = UIColor.black.cgColor
            stroke.lineCap = .butt
            drawMask.addSublayer(stroke)
        }
        showAssembled()
    }

    /// Paper's linear body, its top-left light and its warm lower right.
    private static func paperFill(_ full: CGRect) -> [CALayer] {
        let box = StemGeometry.box
        let body = CAGradientLayer()
        body.frame = full
        body.colors = BrandArt.paper.map(\.cgColor)
        body.locations = [0, 0.5, 1]
        body.startPoint = CGPoint(x: box.minX / 1024, y: box.minY / 1024)
        body.endPoint = CGPoint(x: (box.minX + box.width * 0.35) / 1024, y: box.maxY / 1024)
        let light = CAGradientLayer()
        light.type = .radial
        let lr = StemGeometry.outer * 1.2
        light.frame = CGRect(x: box.minX + 60 - lr, y: box.minY + 40 - lr, width: 2 * lr, height: 2 * lr)
        light.colors = [UIColor.white.withAlphaComponent(0.9).cgColor, UIColor.white.withAlphaComponent(0).cgColor]
        light.startPoint = CGPoint(x: 0.5, y: 0.5)
        light.endPoint = CGPoint(x: 1, y: 1)
        let warm = CAGradientLayer()
        warm.type = .radial
        let wr = StemGeometry.outer * 1.6
        warm.frame = CGRect(x: box.maxX - wr, y: box.maxY - wr, width: 2 * wr, height: 2 * wr)
        warm.colors = [BrandArt.paperWarm.withAlphaComponent(0.38).cgColor, BrandArt.paperWarm.withAlphaComponent(0).cgColor]
        warm.startPoint = CGPoint(x: 0.5, y: 0.5)
        warm.endPoint = CGPoint(x: 1, y: 1)
        return [body, light, warm]
    }

    // MARK: States

    /// Removes every animation: the mark as the icon shows it.
    func showAssembled() {
        pending.forEach { $0.cancel() }
        pending = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [stage, canvas, viewLayer, sky, glow, sun, ringGroup, flap, flapShadow, stemStroke, bowlStroke, shade] as [CALayer] {
            layer.removeAllAnimations()
        }
        ringGroup.mask = nil
        flap.transform = Self.folded
        flapShadow.opacity = 1
        CATransaction.commit()
    }

    /// The flap after its half turn about the crease.
    private static var folded: CATransform3D {
        let g = StemGeometry()
        return CATransform3DMakeRotation(.pi, g.axis.x, g.axis.y, 0)
    }

    /// Plays the assembly once (about 1.1 s). `onLanded` runs when the fold lands, for a haptic.
    /// Under Reduce Motion it is a short fade-in of the finished mark instead.
    func assemble(onLanded: @escaping @MainActor () -> Void, completion: @escaping @MainActor () -> Void) {
        showAssembled()
        let now = CACurrentMediaTime()
        if Motion.prefersCrossfade {
            add(basic("opacity", from: 0, to: 1, at: now, duration: Motion.crossfadeDuration), to: stage)
            after(Motion.crossfadeDuration, completion)
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Write the P: stem up, then the bowl round from the left.
        ringGroup.mask = drawMask
        flap.transform = CATransform3DIdentity
        flapShadow.opacity = 0
        CATransaction.commit()

        let write = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.25, 1)
        let stem = basic("strokeEnd", from: 0, to: 1, at: now, duration: 0.2, timing: CAMediaTimingFunction(name: .easeIn))
        add(stem, to: stemStroke)
        add(basic("strokeEnd", from: 0, to: 1, at: now + 0.16, duration: 0.46, timing: write), to: bowlStroke)

        // The whole mark settles from slightly small.
        add(spring("transform.scale", from: 0.9, to: 1, at: now, duration: 1.0), to: stage, additive: true)

        // The dawn: the window lights from night, the sun rises, its glow blooms.
        add(basic("opacity", from: 0, to: 1, at: now + 0.18, duration: 0.4), to: viewLayer)
        let night = BrandArt.nightSky.map(\.cgColor)
        add(basic("colors", from: night, to: BrandArt.dawnSky.map(\.cgColor), at: now + 0.2, duration: 0.7, timing: write), to: sky)
        add(basic("position.y", from: sun.position.y + 96, to: sun.position.y, at: now + 0.28, duration: 0.72, timing: write), to: sun)
        add(basic("opacity", from: 0, to: 1, at: now + 0.45, duration: 0.55), to: glow)

        // The fold: a half turn about the crease, starting as the bowl closes.
        let perspective: CATransform3D = {
            var t = CATransform3DIdentity
            t.m34 = -1 / 1500
            return t
        }()
        let foldStart = now + 0.6
        let fold = CAKeyframeAnimation(keyPath: "transform")
        let steps = 24
        // Keyframes so the perspective holds through the turn (a plain interpolation of two
        // matrices would flatten it at the half-way point).
        fold.values = (0...steps).map { k -> NSValue in
            let angle = CGFloat.pi * CGFloat(k) / CGFloat(steps)
            let g = geometry
            return NSValue(caTransform3D: CATransform3DConcat(CATransform3DMakeRotation(angle, g.axis.x, g.axis.y, 0), perspective))
        }
        fold.beginTime = foldStart
        fold.duration = 0.46
        fold.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.2, 1)
        fold.fillMode = .backwards
        fold.preferredFrameRateRange = Self.frameRate
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flap.transform = Self.folded
        flapShadow.opacity = 1
        CATransaction.commit()
        flap.add(fold, forKey: "fold")
        add(basic("opacity", from: 0, to: 1, at: foldStart + 0.32, duration: 0.2), to: flapShadow)
        // The ring's shadow comes as the paper lands.
        add(basic("opacity", from: 0, to: 1, at: foldStart, duration: 0.45), to: shade)

        // The drawing mask must be gone before the flap swings inside the band.
        // The swing stays inside the stroke's wide band until well past a quarter turn.
        after(foldStart - now + 0.04) { [weak self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.ringGroup.mask = nil
            CATransaction.commit()
        }
        after(foldStart + 0.4 - now, onLanded)
        after(Self.assembleDuration, completion)
    }

    /// The window's circle, where the dawn shows through the ring, in `target`'s coordinates.
    func windowRect(in target: UIView) -> CGRect {
        let c = StemGeometry.center, r = StemGeometry.inner
        return canvas.convert(CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), to: target.layer)
    }

    /// Runs `body` after `seconds` unless a skip (`showAssembled`) cancels it first.
    private func after(_ seconds: CFTimeInterval, _ body: @escaping @MainActor () -> Void) {
        pending.append(Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            body()
        })
    }

    static let frameRate = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)

    private func basic(
        _ keyPath: String, from: Any, to: Any, at time: CFTimeInterval, duration: CFTimeInterval,
        timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeOut)
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.beginTime = time
        animation.duration = duration
        animation.timingFunction = timing
        animation.fillMode = .backwards
        animation.preferredFrameRateRange = Self.frameRate
        return animation
    }

    private func spring(_ keyPath: String, from: CGFloat, to: CGFloat, at time: CFTimeInterval, duration: CFTimeInterval) -> CASpringAnimation {
        let animation = CASpringAnimation(perceptualDuration: duration, bounce: 0)
        animation.keyPath = keyPath
        animation.fromValue = from - to
        animation.toValue = 0
        animation.beginTime = time
        animation.duration = animation.settlingDuration
        animation.fillMode = .backwards
        animation.preferredFrameRateRange = Self.frameRate
        return animation
    }

    private func add(_ animation: CAAnimation, to layer: CALayer, additive: Bool = false) {
        if additive, let property = animation as? CAPropertyAnimation { property.isAdditive = true }
        layer.add(animation, forKey: (animation as? CAPropertyAnimation)?.keyPath)
    }
}
#endif
