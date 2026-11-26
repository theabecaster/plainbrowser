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

    // MARK: For the downloads list and Quick Look

    /// The saved file once the download finished: open it in Quick Look, share it or show it in
    /// Files. Nil while in progress and after a failure or cancel.
    public var fileURL: URL? {
        if case .finished(let url) = state { url } else { nil }
    }

    public var isInProgress: Bool { state == .inProgress }

    public var isCancelled: Bool { state == .cancelled }
}

/// Runs every `WKDownload` (docs/plan.md, M4): picks a unique file name in the downloads folder,
/// reports start and end to the shell, and falls back to reading `blob:` URLs from the page when
/// WebKit can't download them itself (a page that revokes the blob URL too early, for one).
@Observable
public final class DownloadCoordinator: NSObject, WKDownloadDelegate {
    @ObservationIgnored public let directory: URL
    /// Downloads since launch, newest last. Observed, so a downloads list updates as they start.
    public private(set) var downloads: [Download] = []

    @ObservationIgnored weak var pool: WebViewPool?
    @ObservationIgnored private var active: [ObjectIdentifier: Download] = [:]
    @ObservationIgnored private var frames: [ObjectIdentifier: WKFrameInfo] = [:]
    /// Blob fallbacks in progress (they no longer have a `WKDownload`).
    /// Download id to tab id.
    @ObservationIgnored private var blobReads: [UUID: UUID?] = [:]
    /// Destinations handed to WebKit but not written yet, so two downloads of the same name in
    /// flight get different files.
    @ObservationIgnored private var reserved: Set<URL> = []
    /// Keeps the app running while downloads are in progress after it leaves the screen.
    @ObservationIgnored private var backgroundTask: BackgroundWork?

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
        // Cancelled while the name was being picked.
        guard active[ObjectIdentifier(download)] === item else {
            reserved.remove(destination)
            return nil
        }
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
            Task {
                // The partial file goes off the main thread; the name stays reserved until then.
                if let destination = item.destination { await Self.delete(destination) }
                self.end(item, .cancelled)
            }
        }
    }

    // MARK: Blob fallback

    func readBlob(_ url: URL, from webView: WKWebView, frame: WKFrameInfo, into item: Download) {
        blobReads[item.id] = item.tabID
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
                let bytes = try await Self.write(base64: base64, to: destination)
                // The list shows the size from the progress, as for WebKit's downloads.
                item.progress.totalUnitCount = Int64(bytes)
                item.progress.completedUnitCount = Int64(bytes)
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
        active.values.contains { $0.tabID == id } || blobReads.values.contains(id)
    }

    private func end(_ item: Download, _ state: Download.State) {
        if let destination = item.destination { reserved.remove(destination) }
        blobReads[item.id] = nil
        if active.isEmpty, blobReads.isEmpty {
            backgroundTask?.end()
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
    nonisolated static func delete(_ url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }

    @concurrent
    nonisolated static func write(base64: String, to destination: URL) async throws -> Int {
        guard let data = Data(base64Encoded: base64) else { throw URLError(.cannotDecodeContentData) }
        try data.write(to: destination, options: .withoutOverwriting)
        return data.count
    }
}
#endif
