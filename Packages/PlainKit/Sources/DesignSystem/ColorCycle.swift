import Foundation

// Color math for the pull to refresh arrow's cycle (docs/research/gestures.md, "Pull to
// refresh"): Björn Ottosson's OKLab, so a blend between two brand colors keeps an even lightness
// and never dips through grey the way an sRGB blend of blue and coral does. Pure, so it tests on
// macOS; the UIKit side only reads the finished table.

/// An sRGB color with components from 0 to 1.
nonisolated public struct SRGB: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// From a 0xRRGGBB value, as `Palette` writes its colors.
    public init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255
        )
    }
}

/// A color in OKLab: `lightness` from 0 to 1, `a` green to red, `b` blue to yellow.
nonisolated public struct OKLab: Sendable, Equatable {
    public var lightness: Double
    public var a: Double
    public var b: Double

    public init(lightness: Double, a: Double, b: Double) {
        self.lightness = lightness
        self.a = a
        self.b = b
    }

    public init(_ color: SRGB) {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = linear(color.red), g = linear(color.green), bl = linear(color.blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
        lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    /// Linear sRGB, unclamped: outside 0...1 the color is outside the sRGB gamut.
    private var linear: (red: Double, green: Double, blue: Double) {
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    /// The color can be shown in sRGB as it is.
    public var isInGamut: Bool {
        let c = linear
        return [c.red, c.green, c.blue].allSatisfy { $0 >= -0.0001 && $0 <= 1.0001 }
    }

    /// The same lightness and hue with as much of its chroma as sRGB can show: a color moved to a
    /// lightness its hue can't reach there gives up saturation, never lightness (clamping each
    /// channel would change both).
    public var intoGamut: OKLab {
        guard !isInGamut else { return self }
        var low = 0.0, high = 1.0
        for _ in 0..<20 {
            let mid = (low + high) / 2
            if OKLab(lightness: lightness, a: a * mid, b: b * mid).isInGamut { low = mid } else { high = mid }
        }
        return OKLab(lightness: lightness, a: a * low, b: b * low)
    }

    /// Back to sRGB, clamped into the gamut.
    public var srgb: SRGB {
        let c = linear
        func gamma(_ c: Double) -> Double {
            let v = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
            return min(max(v, 0), 1)
        }
        return SRGB(red: gamma(c.red), green: gamma(c.green), blue: gamma(c.blue))
    }

    public func mixed(with other: OKLab, _ t: Double) -> OKLab {
        OKLab(lightness: lightness + (other.lightness - lightness) * t, a: a + (other.a - a) * t, b: b + (other.b - b) * t)
    }
}

/// A closed loop through brand colors, sampled once into a table, so the pull's scroll callbacks
/// only index it: no color math and no allocation per frame.
nonisolated public struct ColorCycle: Sendable, Equatable {
    /// The loop, evenly sampled: entry 0 is the first stop, and the loop runs back to it.
    public let table: [SRGB]

    /// - Parameters:
    ///   - stops: the colors in order; the last blends back into the first.
    ///   - lightness: the band the samples are kept in, so every color reads on the indicator's
    ///     ground (darker by day, lighter by night) while keeping its hue.
    ///   - samples: entries in the table.
    public init(stops: [SRGB], lightness: ClosedRange<Double> = 0...1, samples: Int = 96) {
        precondition(!stops.isEmpty && samples > 0)
        let labs = stops.map(OKLab.init)
        table = (0..<samples).map { index in
            let position = Double(index) / Double(samples) * Double(labs.count)
            let from = Int(position) % labs.count
            let to = (from + 1) % labs.count
            var color = labs[from].mixed(with: labs[to], position - position.rounded(.down))
            color.lightness = min(max(color.lightness, lightness.lowerBound), lightness.upperBound)
            return color.intoGamut.srgb
        }
    }

    /// Where in the loop the pull is: `turns` times the square of how far it has come, so the
    /// colors change faster the nearer the pull is to its threshold (the speed grows with it), and
    /// a pull just begun barely moves.
    public static func phase(fraction: Double, turns: Double) -> Double {
        let clamped = min(max(fraction, 0), 1)
        return turns * clamped * clamped
    }

    /// The table entry for `phase` (whole turns wrap around).
    public func index(atPhase phase: Double) -> Int {
        let wrapped = phase - phase.rounded(.down)
        return min(Int(wrapped * Double(table.count)), table.count - 1)
    }
}
