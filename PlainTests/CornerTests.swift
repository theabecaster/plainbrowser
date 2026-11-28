@testable import ShellUI
import UIKit
import XCTest

/// Chrome near the screen's corners is concentric with the display (docs/ui-reference.md,
/// "Corners"): UIKit's `.containerConcentric` resolves against the display's own corners, and the
/// Duo's side-bar panel moves its ends in where its corners can't round enough.
@MainActor
final class CornerTests: XCTestCase {
    /// The panel's end against a display corner: the Duo's outer screen (59 pt, a 72 pt wide
    /// panel), an iPhone SE (square), and a corner the panel can match exactly.
    func testPanelEnd() {
        let duo = VerticalBarBacking.end(display: 59, side: 6, cap: 36)
        XCTAssertEqual(duo.radius, 36)
        XCTAssertEqual(duo.inset, 18, "moves in, up to the limit that keeps room under the system's capsule")
        let square = VerticalBarBacking.end(display: 0, side: 6, cap: 36)
        XCTAssertEqual(square.radius, VerticalBarBacking.radius)
        XCTAssertEqual(square.inset, 6)
        let fits = VerticalBarBacking.end(display: 44, side: 6, cap: 60)
        XCTAssertEqual(fits.radius, 38, "concentric: the display's radius less the inset")
        XCTAssertEqual(fits.inset, 6)
        let near = VerticalBarBacking.end(display: 44, side: 6, cap: 36)
        XCTAssertEqual(near.radius, 36)
        XCTAssertEqual(near.inset, 8, "just far enough in for the 36 pt corner to sit inside")
    }

    /// In the app's window a view covering the screen with concentric corners takes the display's
    /// radius, and a panel inset from it takes that less the inset (up to half its width). Square
    /// displays (iPhone SE) give the minimum.
    func testConcentricFollowsTheDisplay() async throws {
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first)
        let root = try XCTUnwrap(window.rootViewController?.view)
        let backing = VerticalBarBacking()
        root.addSubview(backing)
        defer { backing.removeFromSuperview() }
        backing.place(column: CGRect(x: root.bounds.width - 84, y: 0, width: 84, height: root.bounds.height), in: root.bounds)
        // UIKit resolves the display's corners after the view joins the window.
        try await Task.sleep(for: .milliseconds(500))
        backing.layoutIfNeeded()
        let display = backing.effectiveRadius(corner: .topRight)
        let panel = try XCTUnwrap(backing.subviews.compactMap { $0 as? UIVisualEffectView }.first)
        let corner = panel.effectiveRadius(corner: .topRight)
        let expected = VerticalBarBacking.end(display: display, side: VerticalBarBacking.inset, cap: panel.bounds.width / 2)
        XCTAssertEqual(corner, expected.radius, accuracy: 0.5, "display \(display)")
        XCTAssertEqual(panel.frame.minY, expected.inset, accuracy: 0.5)
        // The page side stays at the minimum.
        XCTAssertEqual(panel.effectiveRadius(corner: .topLeft), min(VerticalBarBacking.radius, panel.bounds.width / 2), accuracy: 0.5)
    }
}
