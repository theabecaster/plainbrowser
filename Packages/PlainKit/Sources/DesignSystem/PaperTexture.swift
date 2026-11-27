import CoreGraphics
import Foundation

/// The fine paper under Plain's Paper surfaces: one seamless, opaque tile, generated in code
/// (docs/decisions.md, "Paper texture"). No UIKit, so tests and tools can render it on macOS;
/// `Paper` turns it into the background UIKit and SwiftUI surfaces use.
///
/// The recipe is three layers of very low contrast, added to the Paper color in 8-bit levels:
/// - **Formation:** soft cloudiness a few points across, like pulp settling unevenly.
/// - **Tooth:** fine grain at device-pixel scale, slightly softened so it reads as surface, not
///   as digital noise.
/// - **Fibres:** short, thin, gently curved strands, mostly a shade darker (day) or lighter
///   (night).
///
/// Every layer wraps around the tile's edges (the lattice and the fibres live on a torus), so
/// tiles meet without a seam. The result is deterministic: the same seed draws the same sheet.
public nonisolated enum PaperTexture {
    /// The two sheets: day paper on Paper, night paper on Deep Lagoon.
    public enum Sheet: Sendable, CaseIterable {
        case day, night
    }

    /// The tile's side in pixels. At 3x that is about 85 pt, wide enough that the eye finds no
    /// repeat in a texture this faint, and small enough that a tile is 256 KB (256 × 256 × 4).
    public static let side = 256

    /// The recipe for one sheet. Amplitudes are in 8-bit levels of the base color.
    struct Recipe {
        /// The flat color under the texture. Equal to `Palette.background` for this appearance,
        /// so the textured surface averages to the launch screen's color.
        var base: (r: Double, g: Double, b: Double)
        /// How much each channel moves per level: warmer shadows on day paper (blue moves most),
        /// a cool sheen on night paper.
        var channel: (r: Double, g: Double, b: Double)
        /// Standard deviation of the formation and the tooth, in levels.
        var formation: Double
        var tooth: Double
        /// Fibres per tile and their strength range in levels. Negative darkens.
        var fibres: Int
        var fibreStrength: ClosedRange<Double>
        /// The share of fibres that go the other way (lighter on day paper, darker at night).
        var fibreContrary: Double

        static let day = Recipe(
            base: (255, 246, 230), channel: (0.85, 1.0, 1.2),
            formation: 0.7, tooth: 1.0, fibres: 115, fibreStrength: -5.0 ... -2.2, fibreContrary: 0.3
        )
        static let night = Recipe(
            base: (10, 33, 51), channel: (0.75, 0.9, 1.0),
            formation: 0.35, tooth: 0.5, fibres: 102, fibreStrength: 1.2 ... 2.6, fibreContrary: 0.25
        )
    }

    /// The tile, opaque RGB (no alpha), `side` × `side` pixels. About 1.5 ms optimized;
    /// call it off the main thread.
    public static func makeImage(_ sheet: Sheet) -> CGImage? {
        let bytes = pixels(sheet)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// The tile's pixels, RGBX, row by row.
    public static func pixels(_ sheet: Sheet) -> [UInt8] {
        let recipe: Recipe = sheet == .day ? .day : .night
        var random = SplitMix(seed: sheet == .day ? 0x5041_5045_5201 : 0x4E49_4748_5401)
        let n = side
        let formation = normalized(valueNoise(cell: 16, &random), weight: 0.6)
            .add(normalized(valueNoise(cell: 8, &random), weight: 0.4))
        let tooth = normalized(softGrain(&random), weight: 1)
        let fibres = fibreField(recipe, &random)

        var out = [UInt8](repeating: 255, count: n * n * 4)
        let formationScale = recipe.formation / max(formation.deviation, 1e-9)
        for i in 0 ..< n * n {
            let level = formation.values[i] * formationScale + tooth.values[i] * recipe.tooth + fibres[i]
            // A triangular dither of ±1 level hides the 8-bit steps of the gentle formation.
            let dither = random.unit() - random.unit()
            out[i * 4] = channel(recipe.base.r + level * recipe.channel.r + dither)
            out[i * 4 + 1] = channel(recipe.base.g + level * recipe.channel.g + dither)
            out[i * 4 + 2] = channel(recipe.base.b + level * recipe.channel.b + dither)
        }
        return out
    }

    // MARK: Layers

    /// Smooth value noise on a lattice of `cell`-pixel squares that wraps at the tile's edge.
    private static func valueNoise(cell: Int, _ random: inout SplitMix) -> [Double] {
        let n = side, cells = side / cell
        let lattice = (0 ..< cells * cells).map { _ in random.unit() * 2 - 1 }
        var values = [Double](repeating: 0, count: n * n)
        for y in 0 ..< n {
            let fy = Double(y) / Double(cell)
            let y0 = Int(fy) % cells, y1 = (y0 + 1) % cells
            let ty = smooth(fy - Double(Int(fy)))
            for x in 0 ..< n {
                let fx = Double(x) / Double(cell)
                let x0 = Int(fx) % cells, x1 = (x0 + 1) % cells
                let tx = smooth(fx - Double(Int(fx)))
                let top = lerp(lattice[y0 * cells + x0], lattice[y0 * cells + x1], tx)
                let bottom = lerp(lattice[y1 * cells + x0], lattice[y1 * cells + x1], tx)
                values[y * n + x] = lerp(top, bottom, ty)
            }
        }
        return values
    }

    /// White noise softened by a wrapping [1 2 1] blur in both directions: grain about a pixel
    /// and a half across, which reads as tooth instead of digital static.
    private static func softGrain(_ random: inout SplitMix) -> [Double] {
        let n = side
        let white = (0 ..< n * n).map { _ in random.unit() * 2 - 1 }
        var rows = [Double](repeating: 0, count: n * n)
        for y in 0 ..< n {
            for x in 0 ..< n {
                let left = white[y * n + (x + n - 1) % n], right = white[y * n + (x + 1) % n]
                rows[y * n + x] = (left + 2 * white[y * n + x] + right) / 4
            }
        }
        var out = rows
        for y in 0 ..< n {
            let up = (y + n - 1) % n, down = (y + 1) % n
            for x in 0 ..< n {
                out[y * n + x] = (rows[up * n + x] + 2 * rows[y * n + x] + rows[down * n + x]) / 4
            }
        }
        return out
    }

    /// Short, gently curving strands, splatted with bilinear weights every half pixel and wrapped
    /// at the edges. Already in levels.
    private static func fibreField(_ recipe: Recipe, _ random: inout SplitMix) -> [Double] {
        let n = side
        var field = [Double](repeating: 0, count: n * n)
        for _ in 0 ..< recipe.fibres {
            var x = random.unit() * Double(n), y = random.unit() * Double(n)
            var angle = random.unit() * 2 * .pi
            // Mostly short strands, a few long ones: 12 to 64 pixels, weighted toward short.
            let length = 12 + 52 * pow(random.unit(), 2)
            let range = recipe.fibreStrength
            var strength = range.lowerBound + random.unit() * (range.upperBound - range.lowerBound)
            if random.unit() < recipe.fibreContrary { strength *= -0.6 }
            let bend = (random.unit() - 0.5) * 0.012
            var travelled = 0.0
            while travelled < length {
                // Strands fade in and out at their ends instead of stopping bluntly.
                let t = travelled / length
                let taper = sin(t * .pi)
                splat(&field, x, y, strength * taper)
                angle += bend + (random.unit() - 0.5) * 0.05
                x += cos(angle) * 0.5
                y += sin(angle) * 0.5
                travelled += 0.5
            }
        }
        return field
    }

    private static func splat(_ field: inout [Double], _ x: Double, _ y: Double, _ amount: Double) {
        let n = side
        let fx = x.rounded(.down), fy = y.rounded(.down)
        let tx = x - fx, ty = y - fy
        let x0 = wrap(Int(fx)), y0 = wrap(Int(fy)), x1 = wrap(x0 + 1), y1 = wrap(y0 + 1)
        field[y0 * n + x0] += amount * (1 - tx) * (1 - ty)
        field[y0 * n + x1] += amount * tx * (1 - ty)
        field[y1 * n + x0] += amount * (1 - tx) * ty
        field[y1 * n + x1] += amount * tx * ty
    }

    // MARK: Helpers

    /// A field scaled to unit standard deviation around zero, times `weight`.
    private struct Field {
        var values: [Double]
        var deviation: Double {
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
            return variance.squareRoot()
        }

        func add(_ other: Field) -> Field {
            Field(values: zip(values, other.values).map { $0 + $1 })
        }
    }

    private static func normalized(_ values: [Double], weight: Double) -> Field {
        let mean = values.reduce(0, +) / Double(values.count)
        let centered = values.map { $0 - mean }
        let deviation = Field(values: centered).deviation
        return Field(values: centered.map { $0 / max(deviation, 1e-9) * weight })
    }

    private static func wrap(_ i: Int) -> Int { ((i % side) + side) % side }
    private static func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }
    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private static func channel(_ value: Double) -> UInt8 { UInt8(min(255, max(0, value.rounded()))) }

    /// A small, fast, seedable generator (SplitMix64), so the sheet is the same on every launch.
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// Uniform in [0, 1).
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }
}
