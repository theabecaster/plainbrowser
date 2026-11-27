#if canImport(UIKit)
import BrowserCore
import Foundation
import PerfSignposts
import UIKit
import WebKit

/// Tab thumbnails (docs/plan.md, "Engine rules" 3). Taken once when a tab leaves the screen at
/// `FixedChoices.thumbnailWidth`, never per gallery cell. JPEG encoding and the file write run off
/// the main thread; reads decode off the main thread with `byPreparingForDisplay`. A small memory
/// cache holds recent ones; the rest come back from disk.
public final class ThumbnailService {
    public let directory: URL
    private let cache = NSCache<NSUUID, UIImage>()
    /// Bumped on every capture and removal, so a stale capture is never cached or written.
    private var generations: [UUID: Int] = [:]
    /// File writes and deletes run one after another in the order issued, so an older write can
    /// never land after a newer one or after the removal.
    private var fileWork: Task<Void, Never>?

    /// Test hook: called on the main thread after a capture's file is written, with the time the
    /// main thread waited for the snapshot and the off-main encode-and-write time.
    var onStored: ((UUID, _ snapshot: Duration, _ encodeAndWrite: Duration) -> Void)?

    init(directory: URL) {
        self.directory = directory
        cache.totalCostLimit = EngineChoices.thumbnailMemoryBytes
    }

    func fileURL(for id: UUID) -> URL {
        directory.appending(path: id.uuidString + ".jpg")
    }

    func capture(_ webView: WKWebView, for tab: Tab) {
        guard webView.url != nil, webView.bounds.width > 0 else { return }
        let configuration = WKSnapshotConfiguration()
        // WebKit multiplies `snapshotWidth` by the screen scale; aim for a fixed pixel density.
        let scale = max(1, webView.traitCollection.displayScale)
        configuration.snapshotWidth = NSNumber(
            value: FixedChoices.thumbnailWidth * EngineChoices.thumbnailPixelsPerPoint / scale
        )
        configuration.afterScreenUpdates = false
        // The page as it shows below a top bar that floats over it (the Duo's inner screen): the
        // strip under the bar is the page's empty top at rest, a white band on every card (UX
        // audit, 2026-11-27).
        let top = min(max(0, webView.obscuredContentInsets.top), webView.bounds.height / 2)
        if top > 0 {
            configuration.rect = CGRect(x: 0, y: top, width: webView.bounds.width, height: webView.bounds.height - top)
        }
        let id = tab.id
        let isPrivate = tab.isPrivate
        let generation = generations[id, default: 0] + 1
        generations[id] = generation
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.tabSnapshot, id: signposter.makeSignpostID())
        let started = ContinuousClock.now
        // Started now, while the view is still in the window: a snapshot of a removed view falls
        // back to a slow, large software render. A frozen page may never answer.
        callWithWebKitTimeout(fallback: nil) { done in
            webView.takeSnapshot(with: configuration) { image, _ in done(image) }
        } completion: { [weak self, weak tab] (image: UIImage?) in
            signposter.endInterval(Signposts.tabSnapshot, interval)
            let snapshotTime = ContinuousClock.now - started
            guard let self, let image, self.generations[id] == generation else { return }
            self.cache.setObject(image, forKey: id as NSUUID, cost: Self.cost(of: image))
            tab?.thumbnailRevision += 1
            // A private tab's page never reaches the disk; its thumbnail lives in memory only.
            guard !isPrivate else { return }
            let url = self.fileURL(for: id)
            let directory = self.directory
            self.enqueue {
                // Skip a capture a newer one or a removal already superseded.
                guard self.generations[id] == generation else { return }
                let encodeAndWrite = await Self.write(image, to: url, directory: directory)
                self.onStored?(id, snapshotTime, encodeAndWrite)
            }
        }
    }

    /// The tab's thumbnail if it is decoded in memory now, else nil. Never touches the disk.
    public func cachedThumbnail(for id: UUID) -> UIImage? {
        cache.object(forKey: id as NSUUID)
    }

    /// The tab's thumbnail, ready to draw without a decode on the main thread.
    public func thumbnail(for id: UUID) async -> UIImage? {
        if let image = cache.object(forKey: id as NSUUID) { return image }
        let generation = generations[id]
        guard let image = await Self.read(fileURL(for: id)), generations[id] == generation else { return nil }
        cache.setObject(image, forKey: id as NSUUID, cost: Self.cost(of: image))
        return image
    }

    func remove(_ id: UUID) {
        generations[id, default: 0] += 1
        cache.removeObject(forKey: id as NSUUID)
        let url = fileURL(for: id)
        enqueue { await Self.delete(url) }
    }

    /// Drops the tab's thumbnail from memory and stops a capture in flight, but keeps its file: a
    /// closed or archived tab can come back with its card.
    func forget(_ id: UUID) {
        generations[id, default: 0] += 1
        cache.removeObject(forKey: id as NSUUID)
    }

    /// Deletes thumbnail files of tabs not in `keep` (no row names them any more) that were written
    /// before `cutoff`, so a tab opened meanwhile keeps its new file. Off the main thread; run once
    /// at launch.
    public func prune(keeping keep: Set<UUID>, writtenBefore cutoff: Date) async {
        let directory = directory
        enqueue { await Self.prune(directory, keeping: keep, writtenBefore: cutoff) }
        await fileWork?.value
    }

    @concurrent
    private nonisolated static func prune(_ directory: URL, keeping keep: Set<UUID>, writtenBefore cutoff: Date) async {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in files where file.pathExtension == "jpg" {
            if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), keep.contains(id) { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func enqueue(_ work: @escaping () async -> Void) {
        let previous = fileWork
        fileWork = Task {
            await previous?.value
            await work()
        }
    }

    func dropMemoryCache() {
        cache.removeAllObjects()
    }

    private static func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale) * 4
    }

    @concurrent
    private nonisolated static func write(_ image: UIImage, to url: URL, directory: URL) async -> Duration {
        let started = ContinuousClock.now
        guard let data = image.jpegData(compressionQuality: EngineChoices.thumbnailJPEGQuality) else { return .zero }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        return ContinuousClock.now - started
    }

    @concurrent
    private nonisolated static func read(_ url: URL) async -> UIImage? {
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
        return await image.byPreparingForDisplay()
    }

    @concurrent
    private nonisolated static func delete(_ url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
