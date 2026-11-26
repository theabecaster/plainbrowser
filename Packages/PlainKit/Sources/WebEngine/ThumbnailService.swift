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
        configuration.snapshotWidth = NSNumber(value: FixedChoices.thumbnailWidth)
        configuration.afterScreenUpdates = false
        let id = tab.id
        let generation = generations[id, default: 0] + 1
        generations[id] = generation
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.tabSnapshot, id: signposter.makeSignpostID())
        let started = ContinuousClock.now
        webView.takeSnapshot(with: configuration) { [weak self, weak tab] image, _ in
            signposter.endInterval(Signposts.tabSnapshot, interval)
            let snapshotTime = ContinuousClock.now - started
            guard let self, let image, self.generations[id] == generation else { return }
            self.cache.setObject(image, forKey: id as NSUUID, cost: Self.cost(of: image))
            tab?.thumbnailRevision += 1
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
