import CoreGraphics
import Foundation

/// A picture drawn once with Core Graphics: premultiplied BGRA in sRGB, top row first. The same
/// pixels go to a layer (`image`) and to a GPU texture (`bytes`), which is what makes the swap
/// from one to the other invisible.
///
/// `@unchecked Sendable`: nothing draws into the context after `init`, so it is only read.
nonisolated final class SplashBitmap: @unchecked Sendable {
    let width: Int
    let height: Int
    let image: CGImage
    private let context: CGContext

    /// The pixels, `bytesPerRow` apart, for as long as this object lives.
    var bytes: UnsafeRawPointer? { UnsafeRawPointer(context.data) }
    var bytesPerRow: Int { context.bytesPerRow }

    /// `draw` gets a context whose y axis runs down, in pixels.
    init?(width: Int, height: Int, draw: (CGContext) -> Void) {
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: SplashColor.space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        guard let image = context.makeImage() else { return nil }
        self.width = width
        self.height = height
        self.context = context
        self.image = image
    }

    /// One pixel as premultiplied (r, g, b, a) in 0...255, for tests.
    func pixel(x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        guard let bytes, x >= 0, y >= 0, x < width, y < height else { return (0, 0, 0, 0) }
        let p = bytes.advanced(by: y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
        return (Int(p[2]), Int(p[1]), Int(p[0]), Int(p[3]))
    }
}

/// The launch splash's pictures: the chosen icon's world, drawn from the same shapes and colors
/// as the icon (`StemGeometry`, `SplashTheme`; Brand/tools/gen_icon.py).
///
/// - `field`: the icon's background gradient and bloom, a small square stretched over the screen
///   (it has no detail, and the square is the icon's own shape).
/// - `mark`: the ring, the stem and the fold, with their shadow on the field, at the screen's
///   scale. The window is a real hole in it.
/// - `view`: the dawn in the window, drawn a little past the window's edge so it lies under the
///   ring.
///
/// They depend only on the theme and the screen's scale (`SplashLayout`), so they are drawn off
/// the main thread from the moment the scene connects, before any window has a size.
nonisolated struct SplashArt: Sendable {
    let theme: SplashTheme
    let scale: CGFloat
    let field: SplashBitmap
    let mark: SplashBitmap
    let view: SplashBitmap

    /// The field's size in pixels. Its gradients turn slowly: stretched to the largest screen,
    /// neighbouring pixels still differ by less than one 8-bit step.
    static let fieldSize = 256

    static func draw(theme: SplashTheme, scale: CGFloat) -> SplashArt? {
        let s = max(scale, 1)
        let tile = SplashLayout.tileFrame(scale: s), window = SplashLayout.viewFrame(scale: s)
        let k = s * SplashLayout.unit
        let box = StemGeometry.box
        guard let field = SplashBitmap(width: fieldSize, height: fieldSize, draw: { ctx in
                  ctx.scaleBy(x: CGFloat(fieldSize), y: CGFloat(fieldSize))
                  drawField(ctx, theme: theme)
              }),
              let mark = SplashBitmap(width: Int((tile.width * s).rounded()), height: Int((tile.height * s).rounded()), draw: { ctx in
                  ctx.scaleBy(x: s, y: s)
                  ctx.translateBy(x: -tile.minX, y: -tile.minY)
                  ctx.scaleBy(x: SplashLayout.unit, y: SplashLayout.unit)
                  ctx.translateBy(x: -box.minX, y: -box.minY)
                  drawMark(ctx, theme: theme, pixelsPerUnit: k)
              }),
              let view = SplashBitmap(width: Int((window.width * s).rounded()), height: Int((window.height * s).rounded()), draw: { ctx in
                  ctx.scaleBy(x: s, y: s)
                  ctx.translateBy(x: -window.minX, y: -window.minY)
                  ctx.scaleBy(x: SplashLayout.unit, y: SplashLayout.unit)
                  ctx.translateBy(x: -box.minX, y: -box.minY)
                  drawView(ctx, theme: theme)
              }) else { return nil }
        return SplashArt(theme: theme, scale: s, field: field, mark: mark, view: view)
    }

    // MARK: Field

    /// The icon's fill and bloom in the unit square (y down), as the icon document lays them out.
    static func drawField(_ ctx: CGContext, theme: SplashTheme) {
        linear(ctx, theme.field, [0, 1], from: CGPoint(x: 0.2, y: 0), to: CGPoint(x: 0.8, y: 1))
        radial(ctx, [theme.bloomNear, theme.bloomNear.alpha(0)], [0, 1], center: CGPoint(x: 150.0 / 1024, y: 120.0 / 1024), radius: 640.0 / 1024)
        radial(ctx, [theme.bloomFar, theme.bloomFar.alpha(0)], [0, 1], center: CGPoint(x: 960.0 / 1024, y: 980.0 / 1024), radius: 660.0 / 1024)
    }

    // MARK: Mark

    /// The mark's shadow on the field: soft and low, so the paper sits on the field as it does in
    /// the icon. Canvas units.
    static let markShadow = (drop: CGFloat(10), blur: CGFloat(16), alpha: 0.24)

    /// The ring, the stem and the fold in the icon's canvas. `pixelsPerUnit` sizes the shadows,
    /// which Core Graphics measures in pixels.
    static func drawMark(_ ctx: CGContext, theme: SplashTheme, pixelsPerUnit k: CGFloat) {
        let g = StemGeometry()
        let c = StemGeometry.center, box = StemGeometry.box, outer = StemGeometry.outer, inner = StemGeometry.inner
        let window = CGRect(x: c.x - inner, y: c.y - inner, width: 2 * inner, height: 2 * inner)

        // The shadow on the field. None in the window: the dawn is far behind the ring.
        ctx.saveGState()
        ctx.addRect(box.insetBy(dx: -400, dy: -400))
        ctx.addEllipse(in: window)
        ctx.clip(using: .evenOdd)
        ctx.setShadow(offset: CGSize(width: 0, height: -markShadow.drop * k), blur: 2 * markShadow.blur * k,
                      color: SplashColor(0x000000, alpha: markShadow.alpha).cgColor)
        ctx.addPath(g.paper)
        ctx.addPath(g.flap)
        ctx.setFillColor(theme.paper[1].cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // The paper: soft top-left light, warm lower right, and the flap's contact shadow (tight
        // at the hinge, softer under the lift).
        ctx.saveGState()
        ctx.addPath(g.paper)
        ctx.clip()
        linear(ctx, theme.paper, [0, 0.5, 1], from: CGPoint(x: box.minX, y: box.minY),
               to: CGPoint(x: box.minX + box.width * 0.35, y: box.maxY))
        let white = SplashColor(0xFFFFFF)
        radial(ctx, [white.alpha(theme.highlight), white.alpha(0)], [0, 1],
               center: CGPoint(x: box.minX + 60, y: box.minY + 40), radius: outer * 1.2)
        radial(ctx, [theme.paperWarm.alpha(0.38), theme.paperWarm.alpha(0)], [0, 1],
               center: CGPoint(x: box.maxX, y: box.maxY), radius: outer * 1.6)
        // A blurred copy of the flap: the flap itself is drawn far off the picture and only its
        // shadow, thrown back by the same distance, lands on the paper.
        let far: CGFloat = 8192
        for (dx, dy, deviation, opacity) in [(CGFloat(3), CGFloat(10), CGFloat(12), 0.28), (1, 3, 2.5, 0.36)] {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: far + dx * k, height: -dy * k), blur: 2 * deviation * k,
                          color: theme.flapShade.alpha(opacity).cgColor)
            ctx.translateBy(x: -far / k, y: 0)
            ctx.addPath(g.flap)
            ctx.setFillColor(SplashColor(0x000000).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.restoreGState()

        // The fold, its underside up: crease to free edge.
        ctx.saveGState()
        ctx.addPath(g.flap)
        ctx.clip()
        let reach = outer - StemGeometry.creaseDistance
        linear(ctx, theme.curl, SplashTheme.curlStops, from: g.creasePoint,
               to: CGPoint(x: g.creasePoint.x - g.normal.x * reach, y: g.creasePoint.y - g.normal.y * reach))
        ctx.restoreGState()
    }

    // MARK: View

    /// The part of the canvas the dawn is drawn in: the window and its overscan, cut at the
    /// crease, past which the ring's paper is folded away and the field shows.
    static func viewClip() -> CGPath {
        let c = StemGeometry.center, r = StemGeometry.inner + SplashLayout.viewOverscan
        let n = SplashGeometry.normal, axis = CGPoint(x: -n.y, y: n.x)
        let onCrease = CGPoint(x: c.x + n.x * StemGeometry.creaseDistance, y: c.y + n.y * StemGeometry.creaseDistance)
        let far: CGFloat = 2000
        let side = CGMutablePath()
        side.move(to: CGPoint(x: onCrease.x + axis.x * far, y: onCrease.y + axis.y * far))
        side.addLine(to: CGPoint(x: onCrease.x - axis.x * far, y: onCrease.y - axis.y * far))
        side.addLine(to: CGPoint(x: onCrease.x - axis.x * far - n.x * far, y: onCrease.y - axis.y * far - n.y * far))
        side.addLine(to: CGPoint(x: onCrease.x + axis.x * far - n.x * far, y: onCrease.y + axis.y * far - n.y * far))
        side.closeSubpath()
        return CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil).intersection(side)
    }

    /// The dawn seen through the ring, in the icon's canvas.
    static func drawView(_ ctx: CGContext, theme: SplashTheme) {
        let g = StemGeometry()
        let c = StemGeometry.center, r = StemGeometry.inner + 10
        let top = c.y - r, bottom = c.y + r
        let horizon = g.horizonY, sun = g.sunCenter, sunRadius = StemGeometry.sunRadius, planetRadius: CGFloat = 520
        ctx.saveGState()
        ctx.addPath(viewClip())
        ctx.clip()

        linear(ctx, theme.sky, [0, 0.6, 1], from: CGPoint(x: c.x, y: top), to: CGPoint(x: c.x, y: horizon))
        radial(ctx, [theme.sun[0].alpha(theme.glow), theme.sun[0].alpha(0)], [0, 1], center: sun, radius: 200)

        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: sun.x - sunRadius, y: sun.y - sunRadius, width: 2 * sunRadius, height: 2 * sunRadius))
        ctx.clip()
        radial(ctx, theme.sun, [0, 0.42, 1], center: CGPoint(x: sun.x, y: sun.y - sunRadius * 0.25), radius: sunRadius * 1.25, extend: true)
        ctx.restoreGState()

        // The planet's thin mint atmosphere: a soft line just outside its edge.
        let planet = CGPoint(x: sun.x, y: horizon + planetRadius)
        if let rim = gradient([theme.rim.alpha(0.9), theme.rim.alpha(0.45), theme.rim.alpha(0)], [0, 0.5, 1]) {
            ctx.drawRadialGradient(rim, startCenter: planet, startRadius: planetRadius - 7, endCenter: planet,
                                   endRadius: planetRadius + 17, options: [])
        }
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: planet.x - planetRadius, y: planet.y - planetRadius, width: 2 * planetRadius, height: 2 * planetRadius))
        ctx.clip()
        radial(ctx, theme.planet, [0, 1], center: CGPoint(x: sun.x, y: horizon), radius: bottom - horizon + 40, extend: true)
        ctx.restoreGState()

        // The ring's shade on the top of the view.
        let shade = SplashColor(0x0A0830)
        linear(ctx, [shade.alpha(0.45), shade.alpha(0)], [0, 1], from: CGPoint(x: c.x, y: top), to: CGPoint(x: c.x, y: top + 60))
        ctx.restoreGState()
    }

    // MARK: Gradients

    static func gradient(_ colors: [SplashColor], _ stops: [CGFloat]) -> CGGradient? {
        CGGradient(colorsSpace: SplashColor.space, colors: colors.map(\.cgColor) as CFArray, locations: stops)
    }

    static func linear(_ ctx: CGContext, _ colors: [SplashColor], _ stops: [CGFloat], from: CGPoint, to: CGPoint) {
        guard let gradient = gradient(colors, stops) else { return }
        ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    static func radial(_ ctx: CGContext, _ colors: [SplashColor], _ stops: [CGFloat], center: CGPoint, radius: CGFloat, extend: Bool = false) {
        guard let gradient = gradient(colors, stops) else { return }
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                               options: extend ? [.drawsAfterEndLocation] : [])
    }
}

/// What only the Core Animation iris needs (`LaunchSplashView`, when the GPU dive isn't ready in
/// time), drawn off the main thread once the window has its size:
///
/// - the field again, with a hole under the ring where the app will show through. Its soft edge
///   lies under the ring's band and under the flap, never in sight;
/// - the hole's depth: what makes the opening read as a hole whatever shows through it. The
///   splash is a sheet with some thickness lying over the app, lit from the top left: it shades
///   what is under it (a soft shadow inside the opening, deepest under the top-left edge, and a
///   little dimming all over), and the cut edge catches the light (a thin rim, brightest on the
///   far side). One bitmap, drawn once; it scales with the hole.
nonisolated struct SplashIrisArt: Sendable {
    let field: SplashBitmap
    let depth: SplashBitmap
    /// Where `depth` lies on the screen, in points.
    let depthRect: CGRect

    /// Depth bitmap pixels per point: sharp up to a few times zoom; past that the edge moves fast.
    static let depthScale: CGFloat = 6
    /// The field's hole: a circle through the middle of the ring's band, cut straight under the
    /// flap (canvas units).
    static let fieldHoleRadius = (StemGeometry.inner + StemGeometry.outer) / 2
    static let fieldHoleCut = (SplashGeometry.flapReach + StemGeometry.creaseDistance) / 2 + 7

    /// Dimming over the whole opening: the app sits below the sheet, out of the light.
    static let ambient: CGFloat = 0.20
    /// The sheet's shadow on the app, cast down and right, away from the light (points).
    static let shadowAlpha: CGFloat = 0.5
    static let shadowBlur: CGFloat = 6
    static let shadowOffset = CGSize(width: 2.2, height: 3)
    /// The rim's width in points, and its strength on the edges facing away from the light and
    /// toward it.
    static let rimWidth: CGFloat = 0.7
    static let rimNear: CGFloat = 0.34
    static let rimFar: CGFloat = 0.62

    /// The opening in screen points: the window less the flap, drawn in by half a point so its
    /// edge stays under the mark's own.
    static func opening(in layout: SplashLayout) -> CGPath {
        let g = StemGeometry()
        let u = layout.unit, box = StemGeometry.box
        var toScreen = CGAffineTransform(translationX: layout.markRect.minX, y: layout.markRect.minY)
            .scaledBy(x: u, y: u).translatedBy(x: -box.minX, y: -box.minY)
        let r = layout.holeRadius, c = layout.center
        let window = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
        let flap = g.flap.copy(using: &toScreen) ?? g.flap
        let open = window.subtracting(flap)
        let edge = open.copy(strokingWithWidth: 1, lineCap: .round, lineJoin: .round, miterLimit: 1)
        return open.subtracting(edge)
    }

    static func draw(theme: SplashTheme, layout: SplashLayout) -> SplashIrisArt? {
        let size = SplashArt.fieldSize
        let u = layout.unit, c = layout.center, n = SplashGeometry.normal
        guard layout.size.width > 0, layout.size.height > 0,
              let field = SplashBitmap(width: size, height: size, draw: { ctx in
                  ctx.saveGState()
                  ctx.scaleBy(x: CGFloat(size), y: CGFloat(size))
                  SplashArt.drawField(ctx, theme: theme)
                  ctx.restoreGState()
                  // The hole, in screen points.
                  ctx.scaleBy(x: CGFloat(size) / layout.size.width, y: CGFloat(size) / layout.size.height)
                  let r = fieldHoleRadius * u, cut = fieldHoleCut * u, far: CGFloat = 4000
                  let axis = CGPoint(x: -n.y, y: n.x)
                  let p = CGPoint(x: c.x + n.x * cut, y: c.y + n.y * cut)
                  let side = CGMutablePath()
                  side.move(to: CGPoint(x: p.x + axis.x * far, y: p.y + axis.y * far))
                  side.addLine(to: CGPoint(x: p.x - axis.x * far, y: p.y - axis.y * far))
                  side.addLine(to: CGPoint(x: p.x - axis.x * far - n.x * far, y: p.y - axis.y * far - n.y * far))
                  side.addLine(to: CGPoint(x: p.x + axis.x * far - n.x * far, y: p.y + axis.y * far - n.y * far))
                  side.closeSubpath()
                  ctx.addPath(CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil).intersection(side))
                  ctx.setBlendMode(.clear)
                  ctx.fillPath()
              }) else { return nil }

        let k = depthScale
        let pad = shadowBlur + 4
        let rect = CGRect(x: c.x - layout.holeRadius - pad, y: c.y - layout.holeRadius - pad,
                          width: 2 * (layout.holeRadius + pad), height: 2 * (layout.holeRadius + pad))
        let open = opening(in: layout)
        guard let depth = SplashBitmap(width: Int((rect.width * k).rounded(.up)), height: Int((rect.height * k).rounded(.up)), draw: { ctx in
            ctx.scaleBy(x: k, y: k)
            ctx.translateBy(x: -rect.minX, y: -rect.minY)
            ctx.addPath(open)
            ctx.clip()
            ctx.setFillColor(SplashColor(0x000000, alpha: Double(ambient)).cgColor)
            ctx.fill(rect)

            // The sheet around the opening, filled only so that it casts its shadow into it.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: shadowOffset.width * k, height: -shadowOffset.height * k), blur: 2 * shadowBlur * k / 2,
                          color: SplashColor(0x000000, alpha: Double(shadowAlpha)).cgColor)
            ctx.addRect(rect.insetBy(dx: -4 * pad, dy: -4 * pad))
            ctx.addPath(open)
            ctx.setFillColor(SplashColor(0x000000).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()

            // The lit edge: the inner half of a stroke along the opening, stronger down and right.
            ctx.saveGState()
            ctx.addPath(open.copy(strokingWithWidth: rimWidth * 2, lineCap: .round, lineJoin: .round, miterLimit: 1))
            ctx.clip()
            let white = SplashColor(0xFFFFFF)
            SplashArt.linear(ctx, [white.alpha(Double(rimNear)), white.alpha(Double(rimFar))], [0, 1],
                             from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY))
            ctx.restoreGState()
        }) else { return nil }
        return SplashIrisArt(field: field, depth: depth, depthRect: rect)
    }
}
