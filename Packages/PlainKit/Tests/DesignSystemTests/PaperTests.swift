#if canImport(UIKit)
@testable import DesignSystem
import UIKit
import XCTest

/// The Paper background on a real view (iOS simulator): Core Animation gets the tile as a pattern
/// color and nothing that forces an offscreen pass, the tiles stay small, and Increase Contrast
/// drops the texture.
@MainActor
final class PaperTests: XCTestCase {
    private func waitForTile(_ traits: UITraitCollection) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while Paper.resolved(for: traits).cgColor.pattern == nil {
            guard ContinuousClock.now < deadline else { return XCTFail("the tile never arrived") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testThePatternGoesStraightToTheLayer() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let view = UIView(frame: window.bounds)
        window.addSubview(view)
        window.isHidden = false
        Paper.apply(to: view)
        try await waitForTile(view.traitCollection)
        view.layoutIfNeeded()

        let layer = view.layer
        XCTAssertNotNil(layer.backgroundColor?.pattern, "the tile is the layer's background color")
        // No drawn contents, mask, shadow, rasterizing or extra layers: nothing that costs an
        // offscreen pass or a full-size bitmap.
        XCTAssertNil(layer.contents)
        XCTAssertNil(layer.mask)
        XCTAssertFalse(layer.shouldRasterize)
        XCTAssertEqual(layer.shadowOpacity, 0)
        XCTAssertTrue(layer.sublayers?.isEmpty ?? true)
    }

    func testTilesStayUnderAMegabyte() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            try await waitForTile(UITraitCollection { $0.userInterfaceStyle = style; $0.displayScale = 3 })
        }
        XCTAssertLessThan(Paper.tileBytes, 1_000_000)
        XCTAssertEqual(Paper.tileBytes, 2 * PaperTexture.side * PaperTexture.side * 4)
    }

    func testIncreaseContrastIsFlatPaper() {
        let traits = UITraitCollection { $0.accessibilityContrast = .high; $0.userInterfaceStyle = .light }
        let color = Paper.resolved(for: traits)
        XCTAssertNil(color.cgColor.pattern)
        XCTAssertEqual(color, Palette.background.resolvedColor(with: traits))
    }

    /// A refresh (a tile arriving, Reduce Transparency changing) gives Paper views the new color
    /// and leaves a view alone once something else set its color.
    func testARefreshKeepsAViewSetToClear() {
        let paper = UIView(), cleared = UIView()
        Paper.apply(to: paper)
        Paper.apply(to: cleared)
        cleared.backgroundColor = .clear
        Surfaces.shared.refresh()
        XCTAssertTrue(paper.backgroundColor === Paper.background)
        XCTAssertEqual(cleared.backgroundColor, .clear)
    }
}
#endif
