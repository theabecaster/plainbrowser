#if canImport(UIKit)
@testable import DesignSystem
import UIKit
import XCTest

/// `Palette.inkSecondary`, the start screen's sentence and the sheets' supporting text, keeps
/// 4.5:1 (WCAG AA, body text) on Paper as it is drawn: the texture averaged at glyph scale (a
/// 3 pt square, about a stroke and its counter at 17 pt), with the start screen's glow at full
/// strength on top, by day and by night, and on the private start screen's paper. The texture is
/// also checked at 2.5 times its strength, so a stronger paper can't quietly break it.
@MainActor
final class InkContrastTests: XCTestCase {
    private typealias RGB = (r: Double, g: Double, b: Double)

    private func traits(_ style: UIUserInterfaceStyle) -> UITraitCollection {
        UITraitCollection(userInterfaceStyle: style)
    }

    private func components(_ color: UIColor, _ traits: UITraitCollection) -> (rgb: RGB, alpha: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return ((Double(r) * 255, Double(g) * 255, Double(b) * 255), Double(a))
    }

    private func over(_ top: RGB, alpha: Double, _ bottom: RGB) -> RGB {
        (top.r * alpha + bottom.r * (1 - alpha), top.g * alpha + bottom.g * (1 - alpha), top.b * alpha + bottom.b * (1 - alpha))
    }

    private func luminance(_ c: RGB) -> Double {
        func linear(_ v: Double) -> Double {
            let s = min(max(v / 255, 0), 1)
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    private func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The tile's 3 pt box means (9 px at 3x, wrapping), with each pixel's distance from the
    /// sheet's mean scaled by `strength`.
    private func boxMeans(_ sheet: PaperTexture.Sheet, strength: Double) -> [RGB] {
        let side = PaperTexture.side
        let p = PaperTexture.pixels(sheet)
        let count = Double(side * side)
        let mean = (0 ..< 3).map { c in (0 ..< side * side).reduce(0.0) { $0 + Double(p[$1 * 4 + c]) } / count }
        let box = 9
        var means: [RGB] = []
        for y in stride(from: 0, to: side, by: 3) {
            for x in stride(from: 0, to: side, by: 3) {
                var sum = [0.0, 0.0, 0.0]
                for dy in 0 ..< box {
                    for dx in 0 ..< box {
                        let i = ((y + dy) % side) * side + (x + dx) % side
                        for c in 0 ..< 3 { sum[c] += mean[c] + (Double(p[i * 4 + c]) - mean[c]) * strength }
                    }
                }
                let n = Double(box * box)
                means.append((sum[0] / n, sum[1] / n, sum[2] / n))
            }
        }
        return means
    }

    /// The lowest contrast of the ink over every box of `sheet`, under the glow.
    private func worstContrast(_ sheet: PaperTexture.Sheet, strength: Double) -> Double {
        let t = traits(sheet == .day ? .light : .dark)
        let ink = components(Palette.inkSecondary, t)
        let glow = components(Palette.startGlow, t)
        return boxMeans(sheet, strength: strength).map { paper in
            let ground = over(glow.rgb, alpha: glow.alpha, paper)
            return contrast(over(ink.rgb, alpha: ink.alpha, ground), ground)
        }.min() ?? 0
    }

    func testSecondaryInkKeepsBodyContrastOnTexturedPaper() {
        for sheet in PaperTexture.Sheet.allCases {
            for strength in [1.0, 2.5] {
                let worst = worstContrast(sheet, strength: strength)
                print("InkContrast \(sheet) x\(strength): \(String(format: "%.2f", worst))")
                XCTAssertGreaterThanOrEqual(worst, 4.5, "\(sheet) paper, texture x\(strength): \(worst)")
            }
        }
    }

    /// The private start screen is drawn dark on its own paper, with the night's glow.
    func testSecondaryInkKeepsBodyContrastOnPrivatePaper() {
        let t = traits(.dark)
        let paper = components(Palette.privateBackground, t).rgb
        let glow = components(Palette.startGlow, t)
        let ink = components(Palette.inkSecondary, t)
        for ground in [paper, over(glow.rgb, alpha: glow.alpha, paper)] {
            let ratio = contrast(over(ink.rgb, alpha: ink.alpha, ground), ground)
            print("InkContrast private: \(String(format: "%.2f", ratio))")
            XCTAssertGreaterThanOrEqual(ratio, 4.5)
        }
    }
}
#endif
