#if canImport(UIKit)
import PerfSignposts
import SwiftUI
import UIKit

/// The Paper background with its fine paper texture (`PaperTexture`): the one way a Paper
/// surface gets its background. UIKit views call `apply(to:)`; SwiftUI screens put
/// `PaperBackground()` behind their content.
///
/// The texture is an opaque tile baked onto the Paper color, drawn by Core Animation as a pattern
/// in the layer's background color: no extra layer, no blending, no offscreen pass, nothing per
/// frame. Each tile (day, night) is generated once, off the main thread, the first time an
/// appearance needs it, and kept: 400 KB each. Until it is ready, and whenever Increase Contrast
/// or Reduce Transparency is on, the surface is the flat `Palette.background`, which the texture
/// averages to, so the change can't be seen.
///
/// Never put it on web content and never animate it. Glass stays glass: the texture is for the
/// flat surfaces under the controls.
public enum Paper {
    /// The textured Paper color. A dynamic color: it follows light and dark mode, the display
    /// scale and Increase Contrast. Prefer `apply(to:)`, which also refreshes the view when its
    /// tile is ready or Reduce Transparency changes.
    public static var background: UIColor { Surfaces.shared.current }

    static func makeDynamicColor() -> UIColor {
        UIColor { traits in
            // UIKit resolves views' colors on the main thread; anywhere else, the flat color.
            guard Thread.isMainThread else { return flat(for: traits) }
            return MainActor.assumeIsolated { resolved(for: traits) }
        }
    }

    /// Gives `view` the textured Paper background and keeps it current.
    public static func apply(to view: UIView) {
        Surfaces.shared.add(view)
        view.backgroundColor = background
    }

    /// Paper for these traits: the textured pattern when its tile is ready and texture is wanted,
    /// otherwise the flat color. Starts making the tile when it is missing.
    public static func resolved(for traits: UITraitCollection) -> UIColor {
        guard traits.accessibilityContrast != .high, !Surfaces.shared.reduceTransparency else { return flat(for: traits) }
        let sheet: PaperTexture.Sheet = traits.userInterfaceStyle == .dark ? .night : .day
        // A trait collection outside a window has no scale yet; every iPhone Plain runs on is 3x.
        let scale = traits.displayScale > 0 ? traits.displayScale : 3
        return Tiles.shared.pattern(sheet, scale: scale) ?? flat(for: traits)
    }

    /// The memory the generated tiles hold, in bytes.
    public static var tileBytes: Int { Tiles.shared.bytes }

    private nonisolated static func flat(for traits: UITraitCollection) -> UIColor {
        traits.userInterfaceStyle == .dark ? Flat.night : Flat.day
    }

    /// `Palette.background`'s two colors, readable from any thread.
    private nonisolated enum Flat {
        static let day = UIColor(red: 1, green: 246 / 255, blue: 230 / 255, alpha: 1)
        static let night = UIColor(red: 10 / 255, green: 33 / 255, blue: 51 / 255, alpha: 1)
    }
}

/// Paper behind a SwiftUI screen: `.background(PaperBackground())`. A plain UIKit view with
/// `Paper.apply`, so SwiftUI draws the same tile the same way.
public struct PaperBackground: UIViewRepresentable {
    public init() {}

    public func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        Paper.apply(to: view)
        return view
    }

    public func updateUIView(_ view: UIView, context: Context) {}
}

/// The views showing Paper, so they pick up a tile that just finished and follow Reduce
/// Transparency, which is a setting, not a trait.
@MainActor
final class Surfaces {
    static let shared = Surfaces()

    private let views = NSHashTable<UIView>.weakObjects()
    /// The dynamic color the views were given. A refresh swaps in a new one, so UIKit resolves it
    /// again, and only on views that still show the old one (not one since set to clear).
    private(set) var current = Paper.makeDynamicColor()
    private(set) var reduceTransparency = UIAccessibility.isReduceTransparencyEnabled

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                Surfaces.shared.reduceTransparency = UIAccessibility.isReduceTransparencyEnabled
                Surfaces.shared.refresh()
            }
        }
    }

    func add(_ view: UIView) {
        views.add(view)
    }

    func refresh() {
        let old = current
        current = Paper.makeDynamicColor()
        for view in views.allObjects where view.backgroundColor === old {
            view.backgroundColor = current
        }
    }
}

/// The generated tiles and their pattern colors.
@MainActor
private final class Tiles {
    static let shared = Tiles()

    private var images: [PaperTexture.Sheet: CGImage] = [:]
    private struct Key: Hashable { var sheet: PaperTexture.Sheet; var scale: CGFloat }
    private var patterns: [Key: UIColor] = [:]
    private var pending: Set<PaperTexture.Sheet> = []

    var bytes: Int { images.values.reduce(0) { $0 + $1.bytesPerRow * $1.height } }

    /// The pattern color for `sheet` at `scale`, or nil while its tile is being made.
    func pattern(_ sheet: PaperTexture.Sheet, scale: CGFloat) -> UIColor? {
        let key = Key(sheet: sheet, scale: scale)
        if let pattern = patterns[key] { return pattern }
        guard let image = images[sheet] else {
            make(sheet)
            return nil
        }
        let pattern = UIColor(patternImage: UIImage(cgImage: image, scale: scale, orientation: .up))
        patterns[key] = pattern
        return pattern
    }

    /// Generates the tile on a background thread, then refreshes the surfaces.
    private func make(_ sheet: PaperTexture.Sheet) {
        guard pending.insert(sheet).inserted else { return }
        Task.detached(priority: .userInitiated) {
            let state = Signposts.signposter.beginInterval(Signposts.paperTile)
            let image = PaperTexture.makeImage(sheet)
            Signposts.signposter.endInterval(Signposts.paperTile, state)
            await MainActor.run {
                guard let image else { return }
                Tiles.shared.images[sheet] = image
                Surfaces.shared.refresh()
            }
        }
    }
}
#endif
