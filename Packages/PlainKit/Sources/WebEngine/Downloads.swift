#if canImport(UIKit)
import Foundation
import Observation
import PerfSignposts
import UIKit
import WebKit

/// One download, for the shell's downloads list.
@Observable
public final class Download: Identifiable {
    public enum State: Equatable, Sendable {
        case inProgress
        /// The file, in the downloads folder.
        case finished(URL)
        case failed(String)
        case cancelled
    }

    public let id = UUID()
    public let sourceURL: URL?
    /// The tab whose page started it.
    public let tabID: UUID?
    public internal(set) var filename: String
    public internal(set) var state = State.inProgress
    /// WebKit's progress, updated many times a second, so it is not observed: bind it with
    /// `UIProgressView.observedProgress`.
    @ObservationIgnored public let progress: Progress

    @ObservationIgnored weak var webKitDownload: WKDownload?
    @ObservationIgnored var destination: URL?
    @ObservationIgnored weak var coordinator: DownloadCoordinator?

    init(sourceURL: URL?, tabID: UUID?, progress: Progress) {
        self.sourceURL = sourceURL
        self.tabID = tabID
        self.progress = progress
        filename = sourceURL?.lastPathComponent ?? "download"
    }

    public func cancel() {
        guard state == .inProgress, let download = webKitDownload else { return }
        coordinator?.cancel(download)
    }
}

/// Runs every `WKDownload` (docs/plan.md, M4): picks a unique file name in the downloads folder,
/// reports start and end to the shell, and falls back to reading `blob:` URLs from the page when
/// WebKit can't download them itself (a page that revokes the blob URL too early, for one).
public final class DownloadCoordinator: NSObject, WKDownloadDelegate {
    public let directory: URL
    /// Downloads since launch, newest last.
    public private(set) var downloads: [Download] = []

    weak var pool: WebViewPool?
    private var active: [ObjectIdentifier: Download] = [:]
    private var frames: [ObjectIdentifier: WKFrameInfo] = [:]
    /// Blob fallbacks in progress (they no longer have a `WKDownload`).
    private var blobReads: Set<UUID> = []
    /// Destinations handed to WebKit but not written yet, so two downloads of the same name in
    /// flight get different files.
    private var reserved: Set<URL> = []
    /// Keeps the app running while downloads are in progress after it leaves the screen.
    private var backgroundTask: UIBackgroundTaskIdentifier?

    init(directory: URL) {
        self.directory = directory
    }

    func adopt(_ download: WKDownload, from tab: Tab?) {
        download.delegate = self
        let item = Download(sourceURL: download.originalRequest?.url, tabID: tab?.id, progress: download.progress)
        item.webKitDownload = download
        item.coordinator = self
        active[ObjectIdentifier(download)] = item
        frames[ObjectIdentifier(download)] = download.originatingFrame
        downloads.append(item)
        if backgroundTask == nil { backgroundTask = BackgroundWork.begin("Plain.downloads") }
        Signposts.signposter.emitEvent(Signposts.download, "started")
        pool?.host?.downloadDidStart(item)
    }

    // MARK: WKDownloadDelegate

    public func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String
    ) async -> URL? {
        guard let item = active[ObjectIdentifier(download)] else { return nil }
        let name = NavigationRules.sanitizedFilename(suggestedFilename)
        item.filename = name
        guard let destination = await reserveDestination(for: name) else { return nil }
        item.destination = destination
        return destination
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let item = take(download) else { return }
        if let destination = item.destination {
            end(item, .finished(destination))
        } else {
            end(item, .failed("No destination"))
        }
    }

    public func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        let frame = frames[ObjectIdentifier(download)]
        guard let item = take(download) else { return }
        if let url = item.sourceURL, url.scheme == "blob", let frame, let webView = frame.webView {
            readBlob(url, from: webView, frame: frame, into: item)
        } else {
            end(item, .failed(error.localizedDescription))
        }
    }

    /// WebKit sends no failure callback after a cancel, so the cancel's completion ends it.
    func cancel(_ download: WKDownload) {
        download.cancel { [weak self] _ in
            guard let self, let item = self.take(download) else { return }
            if let destination = item.destination { try? FileManager.default.removeItem(at: destination) }
            self.end(item, .cancelled)
        }
    }

    // MARK: Blob fallback

    func readBlob(_ url: URL, from webView: WKWebView, frame: WKFrameInfo, into item: Download) {
        blobReads.insert(item.id)
        Task {
            do {
                let value = try await webView.callAsyncJavaScript(
                    UserScripts.readBlobSource, arguments: ["url": url.absoluteString], in: frame,
                    contentWorld: UserScripts.world
                )
                guard let result = value as? [String: Any], let base64 = result["data"] as? String else {
                    throw URLError(.cannotDecodeContentData)
                }
                guard let destination = await reserveDestination(for: item.filename) else {
                    throw URLError(.cannotCreateFile)
                }
                item.destination = destination
                try await Self.write(base64: base64, to: destination)
                item.progress.totalUnitCount = 1
                item.progress.completedUnitCount = 1
                end(item, .finished(destination))
            } catch {
                end(item, .failed(error.localizedDescription))
            }
        }
    }

    // MARK: Helpers

    private func take(_ download: WKDownload) -> Download? {
        frames[ObjectIdentifier(download)] = nil
        return active.removeValue(forKey: ObjectIdentifier(download))
    }

    func hasActiveDownload(fromTab id: UUID) -> Bool {
        active.values.contains { $0.tabID == id }
    }

    private func end(_ item: Download, _ state: Download.State) {
        if let destination = item.destination { reserved.remove(destination) }
        blobReads.remove(item.id)
        if active.isEmpty, blobReads.isEmpty {
            BackgroundWork.end(backgroundTask)
            backgroundTask = nil
        }
        item.state = state
        Signposts.signposter.emitEvent(Signposts.download, "\(Self.label(state), privacy: .public)")
        pool?.host?.downloadDidEnd(item)
    }

    /// A free file name, reserved until the download ends. The disk check runs off the main
    /// thread; the reservation is checked again after it, so concurrent picks never collide.
    private func reserveDestination(for name: String) async -> URL? {
        while true {
            let taken = reserved
            guard let candidate = try? await Self.uniqueDestination(in: directory, filename: name, excluding: taken) else {
                return nil
            }
            if !reserved.contains(candidate) {
                reserved.insert(candidate)
                return candidate
            }
        }
    }

    private static func label(_ state: Download.State) -> String {
        switch state {
        case .inProgress: "inProgress"
        case .finished: "finished"
        case .failed: "failed"
        case .cancelled: "cancelled"
        }
    }

    /// `name.ext`, or `name 2.ext`, `name 3.ext`... when taken. Disk work, so off the main thread.
    @concurrent
    nonisolated static func uniqueDestination(
        in directory: URL, filename: String, excluding taken: Set<URL> = []
    ) async throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appending(path: filename)
        var number = 2
        while files.fileExists(atPath: candidate.path) || taken.contains(candidate) {
            let name = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            candidate = directory.appending(path: name)
            number += 1
        }
        return candidate
    }

    @concurrent
    nonisolated static func write(base64: String, to destination: URL) async throws {
        guard let data = Data(base64Encoded: base64) else { throw URLError(.cannotDecodeContentData) }
        try data.write(to: destination, options: .withoutOverwriting)
    }
}
#endif
