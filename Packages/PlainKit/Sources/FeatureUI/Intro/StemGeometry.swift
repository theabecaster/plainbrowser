import CoreGraphics
import Foundation

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

nonisolated extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
    var unit: CGPoint { let l = hypot(x, y); return CGPoint(x: x / l, y: y / l) }
}
