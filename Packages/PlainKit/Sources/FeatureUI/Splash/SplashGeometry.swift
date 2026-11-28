import BrowserCore
import CoreGraphics
import Foundation

/// The P's counter, the hole the launch dives through, in the icon's 1024 canvas
/// (`StemGeometry`): the ring's window, less the part the coral fold lies over.
///
/// The fold is the ring's own edge turned in over the window's top right, so the opening is a
/// circle with a bite out of it, and the dive goes through what is left. All of it is known in
/// closed form, which is what lets the renderer draw the opening's edge sharp at any zoom.
nonisolated enum SplashGeometry {
    /// The crease's unit normal, pointing out of the ring (up and right; y runs down).
    static let normal: CGPoint = {
        let a = StemGeometry.creaseAngle * .pi / 180
        return CGPoint(x: cos(a), y: sin(a))
    }()

    /// How far along the crease's normal a point is from the ring's centre.
    static func along(_ q: CGPoint) -> CGFloat {
        (q.x - StemGeometry.center.x) * normal.x + (q.y - StemGeometry.center.y) * normal.y
    }

    /// Whether the folded flap covers `q`: the flap is the cap the crease cut off the ring,
    /// mirrored over the crease, so `q` is on it when its mirror image is in the cap.
    static func flapContains(_ q: CGPoint) -> Bool {
        let a = along(q)
        guard a <= StemGeometry.creaseDistance else { return false }
        let k = 2 * (StemGeometry.creaseDistance - a)
        let mirrored = CGPoint(x: q.x + normal.x * k, y: q.y + normal.y * k)
        return hypot(mirrored.x - StemGeometry.center.x, mirrored.y - StemGeometry.center.y) <= StemGeometry.outer
    }

    /// Whether `q` is in the opening: inside the window and clear of the flap.
    static func opens(at q: CGPoint) -> Bool {
        hypot(q.x - StemGeometry.center.x, q.y - StemGeometry.center.y) < StemGeometry.inner && !flapContains(q)
    }

    /// The flap's nearest point to the ring's centre, along the normal: the cap's far edge
    /// (the ring's outer radius) mirrored over the crease.
    static let flapReach = 2 * StemGeometry.creaseDistance - StemGeometry.outer

    /// The centre and radius of the largest circle in the opening: it touches the window's far
    /// side and the flap's edge. The hole grows around this point, so the flap leaves the screen
    /// as surely as the ring does.
    static let pivotRadius = (StemGeometry.inner + flapReach) / 2
    static let pivot: CGPoint = {
        let shift = (flapReach - StemGeometry.inner) / 2
        return CGPoint(x: StemGeometry.center.x + normal.x * shift, y: StemGeometry.center.y + normal.y * shift)
    }()

    /// How far the opening reaches from the pivot before its edge is first met, in
    /// `extent.count` evenly spaced directions: entry `i` looks along the angle `2π i / count`,
    /// from the x axis toward the y axis, which points down.
    ///
    /// Closed form, a few hundred operations: a ray from the pivot leaves the opening where it
    /// first meets the window's circle from inside or the flap's inner edge from outside (the
    /// ring's outer circle mirrored over the crease). The crease itself lies outside the window.
    static let extent: [CGFloat] = {
        let count = 180
        let c = StemGeometry.center
        let k = 2 * StemGeometry.creaseDistance
        let mirrored = CGPoint(x: c.x + normal.x * k, y: c.y + normal.y * k)
        /// Where the ray from the pivot along (dx, dy) crosses the circle: the nearer or the
        /// farther crossing, nil when it misses.
        func crossing(_ centre: CGPoint, _ radius: CGFloat, _ dx: CGFloat, _ dy: CGFloat, far: Bool) -> CGFloat? {
            let fx = pivot.x - centre.x, fy = pivot.y - centre.y
            let b = fx * dx + fy * dy, q = fx * fx + fy * fy - radius * radius
            let disc = b * b - q
            guard disc >= 0 else { return nil }
            let t = far ? -b + disc.squareRoot() : -b - disc.squareRoot()
            return t > 0 ? t : nil
        }
        return (0..<count).map { i in
            let angle = 2 * CGFloat.pi * CGFloat(i) / CGFloat(count)
            let dx = cos(angle), dy = sin(angle)
            let window = crossing(c, StemGeometry.inner, dx, dy, far: true) ?? 0
            let flap = crossing(mirrored, StemGeometry.outer, dx, dy, far: false) ?? .infinity
            return min(window, flap)
        }
    }()

    /// The scale at which the opening, grown around `pivot`, has cleared `bounds`: in every
    /// direction the scaled opening reaches the screen's edge. `extent` is in `bounds`' units.
    static func clearingScale(pivot: CGPoint, in bounds: CGRect, extent: [CGFloat]) -> CGFloat {
        var most: CGFloat = 1
        for (i, reach) in extent.enumerated() where reach > 0 {
            let angle = 2 * CGFloat.pi * CGFloat(i) / CGFloat(extent.count)
            most = max(most, edgeDistance(from: pivot, in: bounds, dx: cos(angle), dy: sin(angle)) / reach)
        }
        return most * clearingMargin
    }

    /// Past the exact fit, so the edge's soft shadow is off the screen too.
    static let clearingMargin: CGFloat = 1.08

    /// From a point inside `bounds` to its edge along a direction.
    static func edgeDistance(from p: CGPoint, in bounds: CGRect, dx: CGFloat, dy: CGFloat) -> CGFloat {
        let tx = dx > 0 ? (bounds.maxX - p.x) / dx : dx < 0 ? (bounds.minX - p.x) / dx : .infinity
        let ty = dy > 0 ? (bounds.maxY - p.y) / dy : dy < 0 ? (bounds.minY - p.y) / dy : .infinity
        return max(min(tx, ty), 0)
    }
}

/// Where the splash's pieces sit on a screen, in points. The mark is centred and snapped to the
/// pixel grid, and its pictures (`SplashArt`) are placed from the mark's corner in whole pixels,
/// so they depend only on the screen's scale: they are drawn before the window has a size.
nonisolated struct SplashLayout: Equatable, Sendable {
    /// Clear space around the mark in its picture, for its shadow on the field. Whole points, so
    /// whole pixels at any scale.
    static let tileMargin: CGFloat = 32
    /// The dawn is drawn this far past the window's edge (canvas units), under the ring: the
    /// rolled-back rim uncovers a little of it. Less than the ring's width.
    static let viewOverscan: CGFloat = 60

    let size: CGSize
    let scale: CGFloat
    /// Points per canvas unit.
    let unit: CGFloat
    /// The mark's box (ring, stem and its drop) on the screen.
    let markRect: CGRect
    /// The mark's picture and the dawn's, on the screen.
    let tileRect: CGRect
    let viewRect: CGRect
    /// The ring's centre, the opening's pivot and the window's radius.
    let center: CGPoint
    let pivot: CGPoint
    let holeRadius: CGFloat
    /// The scale at which the opening has cleared the screen.
    let zoomEnd: CGFloat

    static let unit = CGFloat(FixedChoices.splashMarkWidth) / StemGeometry.box.width

    init(size: CGSize, scale: CGFloat) {
        let s = max(scale, 1), u = Self.unit
        self.size = size
        self.scale = s
        unit = u
        let box = StemGeometry.box
        let mark = CGSize(width: box.width * u, height: box.height * u)
        let origin = CGPoint(x: ((size.width - mark.width) / 2 * s).rounded() / s, y: ((size.height - mark.height) / 2 * s).rounded() / s)
        markRect = CGRect(origin: origin, size: mark)
        let tile = Self.tileFrame(scale: s), view = Self.viewFrame(scale: s)
        tileRect = tile.offsetBy(dx: origin.x, dy: origin.y)
        viewRect = view.offsetBy(dx: origin.x, dy: origin.y)
        center = Self.point(StemGeometry.center, from: origin)
        pivot = Self.point(SplashGeometry.pivot, from: origin)
        holeRadius = StemGeometry.inner * u
        zoomEnd = SplashGeometry.clearingScale(
            pivot: pivot, in: CGRect(origin: .zero, size: size), extent: SplashGeometry.extent.map { $0 * u }
        )
    }

    /// A place in the canvas as a point, measured from the mark's corner at `origin`.
    static func point(_ q: CGPoint, from origin: CGPoint = .zero) -> CGPoint {
        CGPoint(x: origin.x + (q.x - StemGeometry.box.minX) * unit, y: origin.y + (q.y - StemGeometry.box.minY) * unit)
    }

    /// The mark's picture, from the mark's corner: the box and its margin, grown to whole pixels.
    static func tileFrame(scale: CGFloat) -> CGRect {
        let box = StemGeometry.box, m = tileMargin
        let width = ((box.width * unit + 2 * m) * scale).rounded(.up) / scale
        let height = ((box.height * unit + 2 * m) * scale).rounded(.up) / scale
        return CGRect(x: -m, y: -m, width: width, height: height)
    }

    /// The dawn's picture, from the mark's corner: the window and its overscan, on whole pixels.
    static func viewFrame(scale: CGFloat) -> CGRect {
        let c = point(StemGeometry.center), r = (StemGeometry.inner + viewOverscan) * unit
        let minX = ((c.x - r) * scale).rounded(.down) / scale, minY = ((c.y - r) * scale).rounded(.down) / scale
        let maxX = ((c.x + r) * scale).rounded(.up) / scale, maxY = ((c.y + r) * scale).rounded(.up) / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
