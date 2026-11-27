import CoreGraphics
import Foundation
import Testing
@testable import BrowserCore
@testable import FeatureUI

/// The launch splash's rules, shapes, colors, timing and pictures: everything of it that is plain
/// values, so it runs on macOS. The dive itself is checked on a simulator (PlainUITests/SplashTests).
@Suite struct SplashTests {
    // MARK: When it plays

    @Test func playsOnAColdLaunchOnly() {
        #expect(SplashGate.shouldPlay(arguments: [], alreadyPlayed: false, launchedForCommand: false, isNewWindow: false))
        // A second window, or anything later in the same process.
        #expect(!SplashGate.shouldPlay(arguments: [], alreadyPlayed: true, launchedForCommand: false, isNewWindow: false))
        // A link from another app, a widget, a shortcut: the page comes first.
        #expect(!SplashGate.shouldPlay(arguments: [], alreadyPlayed: false, launchedForCommand: true, isNewWindow: false))
        #expect(!SplashGate.shouldPlay(arguments: [], alreadyPlayed: false, launchedForCommand: false, isNewWindow: true))
    }

    /// Isolated runs (any build) have no splash unless they ask for it.
    @Test func isolatedRunsAskForIt() {
        for isolation in ["-PlainInMemoryStore", "-PlainTestStore"] {
            #expect(!SplashGate.shouldPlay(arguments: [isolation], alreadyPlayed: false, launchedForCommand: false, isNewWindow: false))
            #expect(SplashGate.shouldPlay(arguments: [isolation, SplashGate.argument], alreadyPlayed: false, launchedForCommand: false,
                                          isNewWindow: false))
        }
    }

    #if DEBUG
    @Test func debugArguments() {
        let debug = SplashDebug(arguments: ["-PlainSplashIcon", "night", "-PlainSplashSlow", "6", "-PlainSplashHold", "1.5", "-PlainSplashPath", "iris"])
        #expect(debug.icon == .night)
        #expect(debug.slow == 6)
        #expect(debug.hold == 1.5)
        #expect(debug.irisOnly)
        let none = SplashDebug(arguments: ["-PlainSplashIcon", "Plaid", "-PlainSplashSlow", "0"])
        #expect(none.icon == nil)
        #expect(none.slow == 1)
        #expect(!none.irisOnly)
    }
    #endif

    // MARK: Colors

    /// Every color of every world is one the icon's generator writes: the splash is the icon.
    @Test func themesUseTheGeneratorsColors() throws {
        let generator = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Brand/tools/gen_icon.py")
        let source = try String(contentsOf: generator, encoding: .utf8).uppercased()
        func hex(_ c: SplashColor) -> String {
            String(format: "#%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
        }
        func fill(_ c: SplashColor) -> String {
            func n(_ v: Double) -> String { v == v.rounded() ? String(format: "%.1f", v) : String(format: "%.2f", v) }
            return "SRGB:\(n(c.r)),\(n(c.g)),\(n(c.b)),1.0"
        }
        for choice in AppIconChoice.allCases {
            for dark in [false, true] {
                let t = SplashTheme.theme(for: choice, dark: dark)
                for c in t.field { #expect(source.contains(fill(c)), "\(choice) field \(fill(c))") }
                let colors = [t.bloomNear, t.bloomFar, t.paperWarm, t.flapShade, t.rim] + t.paper + t.curl + t.sky + t.planet + t.sun
                for c in colors { #expect(source.contains(hex(c)), "\(choice) \(hex(c))") }
            }
        }
    }

    /// Dawn has dark art, as the icon does; the alternates look the same light and dark.
    @Test func onlyDawnHasDarkArt() {
        #expect(SplashTheme.theme(for: .dawn, dark: true) != SplashTheme.theme(for: .dawn, dark: false))
        for choice in [AppIconChoice.night, .coral, .paper] {
            #expect(SplashTheme.theme(for: choice, dark: true) == SplashTheme.theme(for: choice, dark: false))
        }
        #expect(SplashTheme.theme(for: .coral, dark: false).curl != SplashTheme.dawn.curl)
        #expect(SplashTheme.paper.paper != SplashTheme.dawn.paper)
    }

    @Test func statusBarTextSuitsTheField() {
        #expect(!SplashTheme.dawn.statusBarIsLight)
        #expect(SplashTheme.dawnDark.statusBarIsLight)
        #expect(SplashTheme.night.statusBarIsLight)
        #expect(!SplashTheme.paper.statusBarIsLight)
        #expect(!SplashTheme.coral.statusBarIsLight)
    }

    // MARK: The opening

    @Test func theOpeningIsTheWindowLessTheFold() {
        let c = StemGeometry.center, n = SplashGeometry.normal
        func along(_ d: CGFloat) -> CGPoint { CGPoint(x: c.x + n.x * d, y: c.y + n.y * d) }
        #expect(SplashGeometry.opens(at: c))
        #expect(SplashGeometry.opens(at: along(-200)))
        // The fold lies over the window's top right, from 144 to the crease at 222.
        #expect(SplashGeometry.flapReach == 144)
        #expect(!SplashGeometry.opens(at: along(150)))
        #expect(SplashGeometry.flapContains(along(150)))
        #expect(SplashGeometry.flapContains(along(221)))
        #expect(!SplashGeometry.flapContains(along(223)))
        #expect(!SplashGeometry.flapContains(along(140)))
        // Outside the window.
        #expect(!SplashGeometry.opens(at: along(-213)))
    }

    /// The pivot is the centre of the largest circle in the opening: no edge is nearer than its radius.
    @Test func thePivotSitsInTheMiddleOfTheOpening() {
        #expect(SplashGeometry.opens(at: SplashGeometry.pivot))
        let nearest = SplashGeometry.extent.min() ?? 0
        #expect(abs(nearest - SplashGeometry.pivotRadius) < 1.5, "nearest edge \(nearest)")
        #expect((SplashGeometry.extent.max() ?? 0) <= 2 * StemGeometry.inner)
    }

    // MARK: Layout

    static let screens: [(CGSize, CGFloat)] = [
        (CGSize(width: 375, height: 667), 2), (CGSize(width: 402, height: 874), 3), (CGSize(width: 440, height: 956), 3),
        (CGSize(width: 874, height: 402), 3), (CGSize(width: 951, height: 669), 3), (CGSize(width: 669, height: 951), 3),
        (CGSize(width: 393.5, height: 852.5), 3),
    ]

    @Test func theMarkIsCentredOnThePixelGridOnEveryScreen() {
        for (size, scale) in Self.screens {
            let layout = SplashLayout(size: size, scale: scale)
            #expect(abs(layout.markRect.midX - size.width / 2) <= 0.5 / scale + 0.001)
            #expect(abs(layout.markRect.midY - size.height / 2) <= 0.5 / scale + 0.001)
            #expect(layout.markRect.width == CGFloat(FixedChoices.splashMarkWidth))
            for rect in [layout.tileRect, layout.viewRect] {
                for value in [rect.minX, rect.minY, rect.width, rect.height] {
                    #expect(abs(value * scale - (value * scale).rounded()) < 0.001, "\(size) \(rect)")
                }
            }
            // The pictures hold what they are for.
            #expect(layout.tileRect.contains(layout.markRect))
            let r = (StemGeometry.inner + SplashLayout.viewOverscan) * layout.unit
            #expect(layout.viewRect.contains(CGRect(x: layout.center.x - r, y: layout.center.y - r, width: 2 * r, height: 2 * r)))
        }
    }

    /// The pictures are the same whatever the screen's size: they are drawn before it is known.
    @Test func thePicturesDependOnlyOnTheScale() {
        let a = SplashLayout(size: CGSize(width: 402, height: 874), scale: 3)
        let b = SplashLayout(size: CGSize(width: 951, height: 669), scale: 3)
        #expect(a.tileRect.size == b.tileRect.size)
        #expect(a.viewRect.size == b.viewRect.size)
        #expect(abs((a.viewRect.minX - a.markRect.minX) - (b.viewRect.minX - b.markRect.minX)) < 0.0001)
        #expect(a.tileRect.size == SplashLayout.tileFrame(scale: 3).size)
    }

    /// At the dive's end the opening covers the whole screen, whichever way it is held.
    @Test func theOpeningClearsEveryScreen() {
        for (size, scale) in Self.screens {
            let layout = SplashLayout(size: size, scale: scale)
            let bounds = CGRect(origin: .zero, size: size)
            for (i, reach) in SplashGeometry.extent.enumerated() {
                let angle = 2 * CGFloat.pi * CGFloat(i) / CGFloat(SplashGeometry.extent.count)
                let edge = SplashGeometry.edgeDistance(from: layout.pivot, in: bounds, dx: cos(angle), dy: sin(angle))
                #expect(reach * layout.unit * layout.zoomEnd >= edge, "\(size) direction \(i)")
            }
            #expect(layout.zoomEnd > 4 && layout.zoomEnd < 24, "\(size): \(layout.zoomEnd)")
        }
    }

    // MARK: Timing

    @Test func theDiveIsShortAndEndsWide() {
        #expect(SplashTimeline.duration <= 0.7)
        #expect(SplashTimeline.zoom(at: 0, end: 10) == 1)
        #expect(SplashTimeline.zoom(at: SplashTimeline.diveStart, end: 10) == 1)
        #expect(abs(SplashTimeline.zoom(at: SplashTimeline.duration, end: 10) - 10) < 0.0001)
        var last = 1.0
        for step in 0...66 {
            let z = SplashTimeline.zoom(at: Double(step) / 100, end: 10)
            #expect(z >= last)
            last = z
        }
        let frames = SplashTimeline.zoomKeyframes(end: 10)
        #expect(frames.first == 1 && abs((frames.last ?? 0) - 10) < 0.0001)
    }

    @Test func theDawnClearsAndTheDepthComesAndGoes() {
        #expect(SplashTimeline.dawn(at: 0) == 1)
        #expect(SplashTimeline.dawn(at: SplashTimeline.dawnClear) == 0)
        #expect(SplashTimeline.depth(at: 0) == 0)
        #expect(SplashTimeline.depth(at: SplashTimeline.depthIn) == 1)
        #expect(SplashTimeline.depth(at: SplashTimeline.depthOut) == 0)
        #expect(SplashTimeline.depth(at: SplashTimeline.duration) == 0)
    }

    @Test func nothingHasMovedBeforeTheStart() {
        let layout = SplashLayout(size: CGSize(width: 402, height: 874), scale: 3)
        let timeline = SplashTimeline(layout: layout, theme: .dawn)
        let still = timeline.uniforms(at: -1)
        #expect(still.shade.w == 1)          // the pictures' own edges
        #expect(still.shade.x == 1)          // the dawn is whole
        #expect(still.shade.z == 0)          // no depth yet
        #expect(still.curl.w == 0)           // nothing lifted
        #expect(still.cam.z == 1)            // no zoom
        let end = timeline.uniforms(at: SplashTimeline.duration)
        #expect(end.shade.w == 0)
        #expect(abs(end.cam.z - Float(layout.zoomEnd)) < 0.001)
        #expect(end.curl.w == 1)
        #expect(abs(end.curl.x - (Float(layout.holeRadius) + SplashTimeline.foldReach)) < 0.001)
        // The rolled rim never reaches past the ring's band.
        #expect(end.lip.x < Float(StemGeometry.outer * layout.unit))
        // Sixteen-byte rows, as the shader's struct lays them out.
        #expect(MemoryLayout<SplashUniforms>.stride == 15 * 16)
    }

    @Test func theMeshIsWholeAndFixedInSize() {
        let radii = SplashMesh.radii(window: 53.7, far: 1200)
        #expect(radii.count == SplashMesh.rings)
        #expect(zip(radii.dropFirst(), radii).allSatisfy { $0 > $1 })
        #expect((radii.first ?? 0) < 53.7 * Float(SplashGeometry.flapReach / StemGeometry.inner))   // reaches under the fold
        #expect(abs((radii.last ?? 0) - 1200) < 1)
        let vertices = SplashMesh.vertices(window: 53.7, far: 1200)
        let indices = SplashMesh.indices()
        #expect(vertices.count == SplashMesh.rings * (SplashMesh.segments + 1))
        #expect(vertices.count < Int(UInt16.max))
        #expect(indices.count == (SplashMesh.rings - 1) * SplashMesh.segments * 6)
        #expect(Int(indices.max() ?? 0) == vertices.count - 1)
    }

    // MARK: Pictures

    @Test func thePicturesShowTheIconsWorld() throws {
        for choice in AppIconChoice.allCases {
            let theme = SplashTheme.theme(for: choice, dark: false)
            let art = try #require(SplashArt.draw(theme: theme, scale: 2))
            let tile = SplashLayout.tileFrame(scale: 2)
            func markPixel(_ q: CGPoint) -> (r: Int, g: Int, b: Int, a: Int) {
                let p = SplashLayout.point(q)
                return art.mark.pixel(x: Int((p.x - tile.minX) * 2), y: Int((p.y - tile.minY) * 2))
            }
            let c = StemGeometry.center, n = SplashGeometry.normal
            // The window is a hole; the band is solid paper; the fold is solid and not paper.
            #expect(markPixel(c).a == 0, "\(choice)")
            let band = markPixel(CGPoint(x: c.x - 256, y: c.y))
            #expect(band.a == 255, "\(choice)")
            let fold = markPixel(CGPoint(x: c.x + n.x * 180, y: c.y + n.y * 180))
            #expect(fold.a == 255, "\(choice)")
            #expect(abs(fold.r - band.r) + abs(fold.g - band.g) + abs(fold.b - band.b) > 60, "\(choice): fold \(fold) band \(band)")
            // The paper is the theme's: cream, or ink for Paper.
            let paper = theme.paper[1]
            #expect(abs(Double(band.r) / 255 - paper.r) < 0.2 && abs(Double(band.b) / 255 - paper.b) < 0.2, "\(choice): \(band)")
            // Nothing at the picture's corner but a trace of shadow.
            #expect(art.mark.pixel(x: 1, y: 1).a < 12)

            // The dawn fills the window: opaque at its centre, sky above the planet.
            let frame = SplashLayout.viewFrame(scale: 2)
            let centre = SplashLayout.point(c)
            let mid = art.view.pixel(x: Int((centre.x - frame.minX) * 2), y: Int((centre.y - frame.minY) * 2))
            #expect(mid.a == 255)
            #expect(art.view.pixel(x: 0, y: 0).a == 0)

            // The field runs from the fill's first color (with the near bloom over it) to its second.
            #expect(art.field.pixel(x: 128, y: 128).a == 255)
        }
    }

    @Test func theFieldIsTheIconsFill() throws {
        let art = try #require(SplashArt.draw(theme: .night, scale: 2))
        // Night's field is dark everywhere; Paper's is light everywhere.
        for (x, y) in [(10, 10), (128, 128), (245, 245)] {
            let p = art.field.pixel(x: x, y: y)
            #expect(p.r + p.g + p.b < 330, "\(p)")
        }
        let paper = try #require(SplashArt.draw(theme: .paper, scale: 2))
        for (x, y) in [(10, 10), (128, 128), (245, 245)] {
            let p = paper.field.pixel(x: x, y: y)
            #expect(p.r + p.g + p.b > 600, "\(p)")
        }
    }

    /// The Core Animation iris's pictures: the field's hole lies under the ring, and the depth
    /// shades the opening without touching the sheet.
    @Test func theIrisPicturesKeepToTheOpening() throws {
        let size = CGSize(width: 402, height: 874)
        let layout = SplashLayout(size: size, scale: 3)
        let iris = try #require(SplashIrisArt.draw(theme: .dawn, layout: layout))
        func fieldPixel(_ p: CGPoint) -> Int {
            iris.field.pixel(x: Int(p.x / size.width * 256), y: Int(p.y / size.height * 256)).a
        }
        #expect(fieldPixel(layout.center) == 0)
        #expect(fieldPixel(CGPoint(x: 20, y: 20)) == 255)
        // Just outside the ring the field is whole.
        let outside = CGPoint(x: layout.center.x - (StemGeometry.outer + 12) * layout.unit, y: layout.center.y)
        #expect(fieldPixel(outside) == 255)

        let k = SplashIrisArt.depthScale
        func depthPixel(_ p: CGPoint) -> Int {
            iris.depth.pixel(x: Int((p.x - iris.depthRect.minX) * k), y: Int((p.y - iris.depthRect.minY) * k)).a
        }
        // Almost clear in the middle, shaded under the top-left edge, clear on the sheet.
        let middle = depthPixel(layout.pivot)
        #expect(middle < 40, "\(middle)")
        let r = layout.holeRadius
        let underEdge = depthPixel(CGPoint(x: layout.center.x - (r - 2.5) * 0.7071, y: layout.center.y - (r - 2.5) * 0.7071))
        #expect(underEdge > middle + 20, "\(underEdge) vs \(middle)")
        #expect(depthPixel(CGPoint(x: layout.center.x - r - 3, y: layout.center.y)) == 0)
    }

    // MARK: Hand-off between threads

    @Test func aFutureHandsItsValueOver() async {
        let future = SplashFuture<Int>()
        #expect(!future.isDone)
        #expect(future.take() == nil)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            future.whenReady { value in
                #expect(value == 7)
                done.resume()
            }
            DispatchQueue.global().async { future.fulfill(7) }
        }
        #expect(future.isDone)
        #expect(future.take() == 7)
        #expect(future.wait() == 7)
        // Fulfilled once: a second value is ignored.
        future.fulfill(9)
        #expect(future.take() == 7)
        // One that could not be made answers nil at once.
        let failed = SplashFuture<Int>()
        failed.fulfill(nil)
        #expect(failed.isDone && failed.take() == nil)
    }
}
