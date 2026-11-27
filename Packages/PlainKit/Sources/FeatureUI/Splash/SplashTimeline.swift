import BrowserCore
import CoreGraphics
import Foundation
import simd

/// Mirrors `Uniforms` in SplashShader.swift, field for field.
nonisolated struct SplashUniforms {
    /// Screen centre and size (points).
    var view: SIMD4<Float>
    /// The ring's centre, the window's radius, unused.
    var hole: SIMD4<Float>
    /// The pivot the camera closes in on, the zoom, the eye's distance.
    var cam: SIMD4<Float>
    /// The fold line's radius, the roll's radius, the most the rim wraps, how much of it has lifted.
    var curl: SIMD4<Float>
    /// The crease's normal, its distance from the centre and the ring's outer radius (points).
    var flap: SIMD4<Float>
    /// The mark's picture and the dawn's on the screen: origin and size.
    var tile: SIMD4<Float>
    var vtile: SIMD4<Float>
    /// The dawn's opacity and zoom, the depth's strength, and 1 while nothing has moved yet.
    var shade: SIMD4<Float>
    /// The sheet's shadow in the opening: offset, blur, and the opening's radius.
    var depth: SIMD4<Float>
    /// The rolled rim: its outer reach, its shadow's strength on the sheet, how far it has rolled.
    var lip: SIMD4<Float>
    /// The paper's underside, crease to free edge.
    var back0: SIMD4<Float>
    var back1: SIMD4<Float>
    var back2: SIMD4<Float>
    var back3: SIMD4<Float>
    /// The rim's shadow color on the sheet.
    var shadeColor: SIMD4<Float>
}

/// The dive's choreography, in seconds after it starts. Pure math: no Metal, no views.
///
/// 0.00–0.16  the dawn in the window comes a little nearer and clears: the app is behind it
/// 0.02–0.34  the window's cut edge lifts and rolls back, underside up (the icon's fold, all
///            the way round, except under the fold that is already there)
/// 0.10–0.66  the camera goes through: the opening grows around its pivot until it has cleared
///            the screen, and the app settles from a little large to its size
/// 0.00–0.38  the sheet's shadow lies in the opening, then lifts as the app comes up into the light
nonisolated struct SplashTimeline: Sendable {
    static let duration = FixedChoices.splashDive
    static let dawnClear = 0.16
    static let curlStart = 0.02
    static let curlEnd = 0.34
    static let diveStart = 0.10
    static let depthIn = 0.10
    static let depthOut = diveStart + (duration - diveStart) * 0.5
    /// How much nearer the dawn comes as it clears.
    static let dawnZoom: Float = 0.3
    /// How far the fold line travels out from the window's edge, the roll's radius as it starts
    /// and ends, and how far round the rim wraps (points; degrees). About half the ring's band:
    /// the rim reads as the icon's fold, and the ring stays a ring.
    static let foldReach: Float = 12
    static let roll: (from: Float, to: Float) = (1.2, 2.6)
    static let wrap: (from: Float, to: Float) = (100, 165)
    /// Eye distance in points: the rim rises toward the viewer as it passes.
    static let eye: Float = 500
    /// The rim's shadow on the sheet beside it, as strong as the icon's flap shadow.
    static let lipShadow: Float = 0.34
    /// The sheet's shadow in the opening (points), as the Core Animation iris draws it.
    static let depthOffset = SIMD2<Float>(Float(SplashIrisArt.shadowOffset.width), Float(SplashIrisArt.shadowOffset.height))
    static let depthBlur = Float(SplashIrisArt.shadowBlur)

    let layout: SplashLayout
    let theme: SplashTheme

    /// The zoom at `t`. Zooming reads as constant speed when the scale moves evenly in log space,
    /// so the exponent eases (smoothstep): the opening grows gently, rushes through the screen's
    /// edges, then lands.
    static func zoom(at t: Double, end: Double) -> Double {
        let u = smooth((t - diveStart) / (duration - diveStart))
        return exp(log(max(end, 1)) * u)
    }

    /// The zoom's keyframes for Core Animation, `steps + 1` of them, evenly spaced over the dive.
    static func zoomKeyframes(end: Double, steps: Int = 48) -> [Double] {
        (0...steps).map { i in
            zoom(at: diveStart + (duration - diveStart) * Double(i) / Double(steps), end: end)
        }
    }

    /// How strong the opening's depth is at `t`: in as the dawn clears, out as the hole opens.
    static func depth(at t: Double) -> Double {
        let rise = smooth(t / depthIn)
        let u = clamp((t - diveStart) / (depthOut - diveStart))
        return rise * (1 - u * u)
    }

    /// How much of the dawn is left at `t`.
    static func dawn(at t: Double) -> Double { 1 - smooth(t / dawnClear) }

    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
    static func smooth(_ x: Double) -> Double {
        let u = clamp(x)
        return u * u * (3 - 2 * u)
    }

    /// Uniforms for time `t`; before 0 nothing has moved.
    func uniforms(at t: Double) -> SplashUniforms {
        let still = t < 0
        let time = max(t, 0)
        let r0 = Float(layout.holeRadius)
        let n = SplashGeometry.normal
        let u = Float(layout.unit)

        // The rim: the fold line leaves the window's edge fast and slows (ease out), the roll
        // grows rounder as more paper is in it.
        let k = Self.clamp((time - Self.curlStart) / (Self.curlEnd - Self.curlStart))
        let progress = Float(1 - pow(1 - k, 3))
        let amount = still ? 0 : Float(Self.smooth((time - Self.curlStart) / 0.06))
        let p = r0 + Self.foldReach * progress
        let roll = Self.roll.from + (Self.roll.to - Self.roll.from) * progress
        let wrap = (Self.wrap.from + (Self.wrap.to - Self.wrap.from) * progress) * .pi / 180
        // Where the rolled rim's free edge has got to, seen from above.
        let rolled = p - r0
        let phi = min(rolled / roll, wrap)
        let tail = rolled - roll * phi
        let outer = max(p, p - (roll * sin(phi) + tail * cos(phi)))
        let lift = min(phi, .pi / 2)
        let opening = r0 + amount * (p - roll * sin(lift) - r0)

        let zoom = still ? 1 : Float(Self.zoom(at: time, end: Double(layout.zoomEnd)))
        func color(_ c: SplashColor) -> SIMD4<Float> { SIMD4(Float(c.r), Float(c.g), Float(c.b), Float(c.a)) }
        return SplashUniforms(
            view: SIMD4(Float(layout.size.width / 2), Float(layout.size.height / 2), Float(layout.size.width), Float(layout.size.height)),
            hole: SIMD4(Float(layout.center.x), Float(layout.center.y), r0, 0),
            cam: SIMD4(Float(layout.pivot.x), Float(layout.pivot.y), zoom, Self.eye),
            curl: SIMD4(p, roll, wrap, amount),
            flap: SIMD4(Float(n.x), Float(n.y), Float(StemGeometry.creaseDistance) * u, Float(StemGeometry.outer) * u),
            tile: SIMD4(Float(layout.tileRect.minX), Float(layout.tileRect.minY), Float(layout.tileRect.width), Float(layout.tileRect.height)),
            vtile: SIMD4(Float(layout.viewRect.minX), Float(layout.viewRect.minY), Float(layout.viewRect.width), Float(layout.viewRect.height)),
            shade: SIMD4(still ? 1 : Float(Self.dawn(at: time)), still ? 1 : 1 + Self.dawnZoom * Float(Self.smooth(time / 0.22)),
                         still ? 0 : Float(Self.depth(at: time)), still ? 1 : 0),
            depth: SIMD4(Self.depthOffset.x, Self.depthOffset.y, Self.depthBlur, opening),
            lip: SIMD4(outer, Self.lipShadow * amount, max(rolled, 0.001), 0),
            back0: color(theme.curl[0]), back1: color(theme.curl[1]), back2: color(theme.curl[2]), back3: color(theme.curl[3]),
            shadeColor: color(theme.flapShade)
        )
    }
}

/// The sheet's mesh: rings around the window in the P, each vertex its distance and angle from
/// the ring's centre. Dense where the rim rolls (half a point a ring, so the tightest roll's arc
/// spans several cells), a few rings inside the window for the icon's fold lying over it, and a
/// few more reaching past the screen's corners. The counts are constants, so a new screen never
/// changes what the dive costs.
nonisolated enum SplashMesh {
    static let segments = 160
    /// Rings inside the window, in the rim's band and out to the screen's corners.
    static let inside = 4
    static let rim = 36
    static let field = 12
    static let rings = inside + rim + field
    /// The mesh starts this far in (of the window's radius; the icon's fold reaches 0.68) and
    /// the rim's band runs from just inside the window's edge to past the fold's reach (points).
    static let innerEdge: Float = 0.6
    static let rimStart: Float = -1.5
    static let rimEnd: Float = SplashTimeline.foldReach + 4

    static func radii(window r0: Float, far: Float) -> [Float] {
        var out: [Float] = []
        let a = r0 * innerEdge, b = r0 + rimStart, c = r0 + rimEnd
        for i in 0..<inside { out.append(a + (b - a) * Float(i) / Float(inside)) }
        for i in 0..<rim { out.append(b + (c - b) * Float(i) / Float(rim - 1)) }
        // Geometric steps to the far edge: flat paper needs no detail.
        let ratio = pow(max(far, c + 1) / c, 1 / Float(field))
        for i in 1...field { out.append(c * pow(ratio, Float(i))) }
        return out
    }

    static func vertices(window r0: Float, far: Float) -> [SIMD2<Float>] {
        let radii = radii(window: r0, far: far)
        var out: [SIMD2<Float>] = []
        out.reserveCapacity(radii.count * (segments + 1))
        for rho in radii {
            for s in 0...segments { out.append(SIMD2(rho, 2 * .pi * Float(s) / Float(segments))) }
        }
        return out
    }

    static func indices() -> [UInt16] {
        let n = segments + 1
        var idx: [UInt16] = []
        idx.reserveCapacity((rings - 1) * segments * 6)
        for ring in 0..<(rings - 1) {
            for s in 0..<segments {
                let i = UInt16(ring * n + s), out = i + UInt16(n), round = i + 1
                // Clockwise on screen while flat, so the printed side is the front face.
                idx += [i, out, round, out, out + 1, round]
            }
        }
        return idx
    }
}
