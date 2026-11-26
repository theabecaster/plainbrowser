#if canImport(UIKit)
import UIKit

/// Turns the data source's images into ready-to-draw bitmaps at the size a card shows them.
///
/// Decoding and downsampling run off the main thread (`byPreparingThumbnail(ofSize:)`), so a cell
/// only ever assigns a decoded image and Core Animation never decodes during a scroll. One load per
/// key at a time: a visible cell and a prefetch asking for the same image share one task.
@MainActor
final class ThumbnailPipeline {
    nonisolated struct Key: Hashable, Sendable {
        let id: UUID
        let revision: Int
        /// Pixel width the image is prepared at; a new card width prepares a new copy.
        let pixelWidth: Int
        /// The tallest part kept, as height over width in thousandths (0 keeps all). A card shows
        /// only the top of its page, so only that part is decoded and cached.
        let maxAspectPermille: Int
        let kind: Kind
    }

    nonisolated enum Kind: Hashable, Sendable { case thumbnail, favicon }

    private let cache = NSCache<KeyBox, UIImage>()
    private var inFlight: [Key: Task<UIImage?, Never>] = [:]

    init(costLimit: Int = TabGalleryChoices.thumbnailCacheCost) {
        cache.totalCostLimit = costLimit
    }

    func cached(_ key: Key) -> UIImage? {
        cache.object(forKey: KeyBox(key))
    }

    /// The prepared image for `key`, loading it with `source` when it is not cached.
    func image(for key: Key, source: @escaping @MainActor () async -> UIImage?) async -> UIImage? {
        if let image = cached(key) { return image }
        if let task = inFlight[key] { return await task.value }
        let task = Task { () -> UIImage? in
            guard let original = await source() else { return nil }
            return await Self.prepare(original, pixelWidth: key.pixelWidth, maxAspectPermille: key.maxAspectPermille, opaque: key.kind == .thumbnail)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
            cache.setObject(image, forKey: KeyBox(key), cost: cost)
        }
        return image
    }

    /// Starts loading `key` without waiting for it (prefetching).
    func warm(_ key: Key, source: @escaping @MainActor () async -> UIImage?) {
        guard cached(key) == nil, inFlight[key] == nil else { return }
        Task { _ = await image(for: key, source: source) }
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    /// Downsamples to `pixelWidth`, keeps the top `maxAspectPermille` of it, and decodes, all off
    /// the main thread (`@concurrent`). Drawing into an image renderer leaves a decoded bitmap, so
    /// Core Animation never decodes it during a scroll.
    @concurrent private nonisolated static func prepare(
        _ image: UIImage, pixelWidth: Int, maxAspectPermille: Int, opaque: Bool
    ) async -> UIImage? {
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let width = min(CGFloat(pixelWidth), pixelSize.width).rounded()
        let fullHeight = (width * pixelSize.height / pixelSize.width).rounded()
        var height = fullHeight
        if maxAspectPermille > 0 { height = min(fullHeight, (width * CGFloat(maxAspectPermille) / 1000).rounded(.up)) }
        if width == pixelSize.width, height == fullHeight {
            return await image.byPreparingForDisplay() ?? image
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: fullHeight))
        }
    }
}

/// `NSCache` needs an object key.
private nonisolated final class KeyBox: NSObject {
    let key: ThumbnailPipeline.Key
    init(_ key: ThumbnailPipeline.Key) { self.key = key }
    override var hash: Int { key.hashValue }
    override func isEqual(_ object: Any?) -> Bool { (object as? KeyBox)?.key == key }
}
#endif
