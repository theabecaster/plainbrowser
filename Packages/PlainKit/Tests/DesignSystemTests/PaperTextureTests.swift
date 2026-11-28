import CoreGraphics
@testable import DesignSystem
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class PaperTextureTests: XCTestCase {
    private let side = PaperTexture.side

    /// Luminance of every pixel, in 8-bit levels.
    private func luma(_ sheet: PaperTexture.Sheet) -> [Double] {
        let p = PaperTexture.pixels(sheet)
        return (0 ..< side * side).map { 0.2126 * Double(p[$0 * 4]) + 0.7152 * Double(p[$0 * 4 + 1]) + 0.0722 * Double(p[$0 * 4 + 2]) }
    }

    func testSameSeedDrawsTheSameSheet() {
        for sheet in PaperTexture.Sheet.allCases {
            XCTAssertEqual(PaperTexture.pixels(sheet), PaperTexture.pixels(sheet))
        }
    }

    /// The sheet averages to the flat Paper color, so it matches the launch screen.
    func testAveragesToThePaperColor() {
        for (sheet, base) in [(PaperTexture.Sheet.day, (255.0, 246.0, 230.0)), (.night, (10.0, 33.0, 51.0))] {
            let p = PaperTexture.pixels(sheet)
            let count = Double(side * side)
            let mean = (0 ..< 3).map { c in (0 ..< side * side).reduce(0.0) { $0 + Double(p[$1 * 4 + c]) } / count }
            // Red on day paper is already 255, so lighter specks clip there; red moves least on
            // day paper (`channel`), which keeps it within the same half level.
            XCTAssertEqual(mean[0], base.0, accuracy: 0.5, "\(sheet) red")
            XCTAssertEqual(mean[1], base.1, accuracy: 0.5, "\(sheet) green")
            XCTAssertEqual(mean[2], base.2, accuracy: 0.5, "\(sheet) blue")
        }
    }

    /// Visible as paper, never as dirt: the spread sits inside the "material, not dirt" band
    /// (docs/decisions.md, "Paper texture"), night weaker than day. The owner found the first
    /// recipe (σ 1.2 / 0.8 levels, about 1.6 % / 1.0 % noise opacity) barely visible, so the
    /// lower bounds keep it from sliding back there; the upper bounds keep the strongest strands
    /// a shade, not a mark, and secondary text's contrast within a few percent of the flat paper.
    func testVisibleButFaint() {
        for sheet in PaperTexture.Sheet.allCases {
            let l = luma(sheet)
            let mean = l.reduce(0, +) / Double(l.count)
            let spread = l.map { abs($0 - mean) }.sorted()
            let p999 = spread[Int(Double(spread.count) * 0.999)]
            let deviation = (l.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(l.count)).squareRoot()
            XCTAssertLessThan(p999, sheet == .day ? 14 : 11, "\(sheet) 99.9th percentile")
            XCTAssertLessThan(deviation, sheet == .day ? 2.8 : 1.9, "\(sheet) standard deviation")
            XCTAssertGreaterThan(deviation, sheet == .day ? 1.8 : 1.2, "\(sheet) visible as paper")
        }
    }

    /// No repeat: what is left after an arm's-length blur (about 4 pt) is the part of the sheet
    /// that would show the 85 pt tile as a grid. The formation stays small and the strands are
    /// high-passed, so that part stays a fraction of the texture.
    func testNoTileScaleCloud() {
        for sheet in PaperTexture.Sheet.allCases {
            let l = luma(sheet)
            func blur(_ v: [Double]) -> [Double] {
                let r = 6
                var rows = v, out = v
                for y in 0 ..< side {
                    for x in 0 ..< side {
                        rows[y * side + x] = (-r ... r).reduce(0.0) { $0 + v[y * side + (x + $1 + side) % side] } / Double(2 * r + 1)
                    }
                }
                for y in 0 ..< side {
                    for x in 0 ..< side {
                        out[y * side + x] = (-r ... r).reduce(0.0) { $0 + rows[((y + $1 + side) % side) * side + x] } / Double(2 * r + 1)
                    }
                }
                return out
            }
            let low = blur(blur(l))
            let mean = low.reduce(0, +) / Double(low.count)
            let deviation = (low.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(low.count)).squareRoot()
            XCTAssertLessThan(deviation, sheet == .day ? 0.5 : 0.3, "\(sheet) tile-scale cloud")
        }
    }

    /// Tiles meet without a seam: the step across the wrap edge is no larger than the step between
    /// any two neighbouring columns or rows inside the tile.
    func testTilesWithoutASeam() {
        for sheet in PaperTexture.Sheet.allCases {
            let l = luma(sheet)
            func columnStep(_ a: Int, _ b: Int) -> Double {
                (0 ..< side).reduce(0.0) { $0 + abs(l[$1 * side + a] - l[$1 * side + b]) } / Double(side)
            }
            func rowStep(_ a: Int, _ b: Int) -> Double {
                (0 ..< side).reduce(0.0) { $0 + abs(l[a * side + $1] - l[b * side + $1]) } / Double(side)
            }
            let inside = (0 ..< side - 1).map { columnStep($0, $0 + 1) }
            let insideRows = (0 ..< side - 1).map { rowStep($0, $0 + 1) }
            XCTAssertLessThanOrEqual(columnStep(side - 1, 0), inside.max()!, "\(sheet) vertical seam")
            XCTAssertLessThanOrEqual(rowStep(side - 1, 0), insideRows.max()!, "\(sheet) horizontal seam")
        }
    }

    func testMakesAnOpaqueImage() throws {
        let image = try XCTUnwrap(PaperTexture.makeImage(.day))
        XCTAssertEqual(image.width, side)
        XCTAssertEqual(image.alphaInfo, .noneSkipLast)
    }

    /// With `PLAIN_PAPER_PREVIEW=<dir>`, writes previews for review: each tile, a phone screen of
    /// tiles (1206 × 2622, iPhone 17 at 3x), a 3x zoom of a corner where four tiles meet, and the
    /// same corner with the contrast raised 12 times to show any seam.
    func testWritesPreviewsOnRequest() throws {
        guard let dir = ProcessInfo.processInfo.environment["PLAIN_PAPER_PREVIEW"] else {
            throw XCTSkip("set PLAIN_PAPER_PREVIEW to write previews")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for sheet in PaperTexture.Sheet.allCases {
            let p = PaperTexture.pixels(sheet)
            let name = "\(sheet)"
            try write(p, width: side, height: side, to: "\(dir)/tile-\(name).png")
            try write(render(p, width: 1206, height: 2622) { x, y in (x % side, y % side) }, width: 1206, height: 2622,
                      to: "\(dir)/screen-\(name).png")
            let corner = side - 100
            let zoom = render(p, width: 600, height: 600) { x, y in ((corner + x / 3) % side, (corner + y / 3) % side) }
            try write(zoom, width: 600, height: 600, to: "\(dir)/zoom3x-\(name).png")
            let base = (0 ..< 3).map { c in (0 ..< side * side).reduce(0.0) { $0 + Double(p[$1 * 4 + c]) } / Double(side * side) }
            var loud = zoom
            for i in 0 ..< 600 * 600 {
                for c in 0 ..< 3 {
                    loud[i * 4 + c] = UInt8(min(255, max(0, 128 + (Double(zoom[i * 4 + c]) - base[c]) * 12)))
                }
            }
            try write(loud, width: 600, height: 600, to: "\(dir)/seam12x-\(name).png")
        }
    }

    private func render(_ tile: [UInt8], width: Int, height: Int, source: (Int, Int) -> (Int, Int)) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let (sx, sy) = source(x, y)
                for c in 0 ..< 4 { out[(y * width + x) * 4 + c] = tile[(sy * side + sx) * 4 + c] }
            }
        }
        return out
    }

    private func write(_ pixels: [UInt8], width: Int, height: Int, to path: String) throws {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
