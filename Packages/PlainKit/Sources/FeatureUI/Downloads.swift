import Foundation

/// One row of the Downloads list. WebEngine's `Download` has exactly these members, so the shell
/// conforms it with an empty extension (`extension Download: DownloadListItem {}`); FeatureUI
/// can't import WebEngine.
public protocol DownloadListItem: AnyObject {
    var id: UUID { get }
    var filename: String { get }
    /// Bytes so far and in all (`totalUnitCount` is -1 or 0 while unknown).
    var progress: Progress { get }
    /// The saved file, once finished.
    var fileURL: URL? { get }
    var isInProgress: Bool { get }
    var isCancelled: Bool { get }
    func cancel()
}

/// Where the list comes from. WebEngine's `DownloadCoordinator` has these members
/// (`extension DownloadCoordinator: DownloadListSource {}`). `downloads` must be observable, so the
/// list updates as downloads start.
public protocol DownloadListSource: AnyObject {
    associatedtype Item: DownloadListItem
    /// Oldest first; the list shows the newest on top.
    var downloads: [Item] { get }
    /// The downloads folder, for "Show in Files".
    var directory: URL { get }
}

/// What a row says under the file name.
nonisolated enum DownloadStatusText {
    static func subtitle(
        isInProgress: Bool, isCancelled: Bool, isFinished: Bool, completed: Int64, total: Int64
    ) -> String {
        if isInProgress {
            guard completed > 0 else { return "Starting…" }
            return total > 0 ? "\(bytes(completed)) of \(bytes(total))" : bytes(completed)
        }
        if isFinished { return completed > 0 ? bytes(completed) : "Downloaded" }
        return isCancelled ? "Cancelled" : "Failed"
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// The Files app's address for a folder in the app's Documents.
    static func filesAppURL(for folder: URL) -> URL? {
        URL(string: "shareddocuments://" + folder.path(percentEncoded: true))
    }
}

#if os(iOS)
import PerfSignposts
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The Downloads sheet: newest first, with progress and Cancel while running; tap a finished file
/// to open it in Quick Look, or long-press for Show in Files and Share. Low frequency, so SwiftUI.
public struct DownloadsView<Source: DownloadListSource>: View {
    private let source: Source
    private let onDone: (() -> Void)?
    @State private var preview: URL?
    @Environment(\.openURL) private var openURL

    public init(source: Source, onDone: (() -> Void)? = nil) {
        self.source = source
        self.onDone = onDone
    }

    public var body: some View {
        let items = Array(source.downloads.reversed())
        NavigationStack {
            List(items, id: \.id) { item in
                DownloadRow(item: item, open: open, showInFiles: showInFiles)
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("Files you download show up here.", systemImage: "arrow.down.circle")
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Show in Files") { showInFiles(source.directory) }
                }
                DoneButton(onDone: onDone)
            }
            .quickLookPreview($preview, in: items.compactMap(\.fileURL))
        }
        .tint(Style.accent)
        .onAppear { Signposts.signposter.emitEvent(Signposts.downloadsShow) }
    }

    private func open(_ url: URL) {
        Signposts.signposter.emitEvent(Signposts.downloadPreview)
        preview = url
    }

    private func showInFiles(_ url: URL) {
        Signposts.signposter.emitEvent(Signposts.downloadShowInFiles)
        let folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        if let files = DownloadStatusText.filesAppURL(for: folder) { openURL(files) }
    }
}

struct DownloadRow<Item: DownloadListItem>: View {
    let item: Item
    let open: (URL) -> Void
    let showInFiles: (URL) -> Void

    var body: some View {
        let file = item.fileURL
        HStack(spacing: 12) {
            Button {
                if let file { open(file) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(file == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Style.accent))
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        // An ended download with no file (failed, cancelled) reads as inactive,
                        // but stays legible: secondary, not the disabled dimming.
                        Text(item.filename)
                            .foregroundStyle(file == nil && !item.isInProgress ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if item.isInProgress {
                            // Progress changes many times a second; redraw twice a second, only
                            // while this row is running.
                            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                                VStack(alignment: .leading, spacing: 4) {
                                    ProgressView(value: fraction)
                                        .tint(Style.accent)
                                    status
                                }
                            }
                        } else {
                            status
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .tint(.primary)
            if item.isInProgress {
                Button("Cancel Download", systemImage: "xmark.circle.fill") { item.cancel() }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.borderless)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .contextMenu {
            if let file {
                Button("Open", systemImage: "eye") { open(file) }
                Button("Show in Files", systemImage: "folder") { showInFiles(file) }
                ShareLink(item: file)
            }
            if item.isInProgress {
                Button("Cancel Download", systemImage: "xmark", role: .destructive) { item.cancel() }
            }
        }
    }

    private var status: some View {
        Text(DownloadStatusText.subtitle(
            isInProgress: item.isInProgress, isCancelled: item.isCancelled, isFinished: item.fileURL != nil,
            completed: item.progress.completedUnitCount, total: item.progress.totalUnitCount
        ))
        .font(.footnote)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private var fraction: Double {
        let total = item.progress.totalUnitCount
        guard total > 0 else { return 0 }
        return min(1, Double(item.progress.completedUnitCount) / Double(total))
    }

    private var symbol: String {
        if item.isInProgress { return "arrow.down.circle" }
        if item.fileURL == nil { return item.isCancelled ? "xmark.circle" : "exclamationmark.circle" }
        guard let type = UTType(filenameExtension: (item.filename as NSString).pathExtension) else { return "doc" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        return "doc"
    }
}

/// Quick Look for finished downloads, for the shell to present from UIKit (for example from a
/// "Download finished" toast). Starts at `selected` and swipes through `files`.
public final class FilePreviewController: QLPreviewController, QLPreviewControllerDataSource {
    private let files: [URL]

    public init(files: [URL], selected: URL? = nil) {
        self.files = files
        super.init(nibName: nil, bundle: nil)
        dataSource = self
        if let selected, let index = files.firstIndex(of: selected) { currentPreviewItemIndex = index }
        Signposts.signposter.emitEvent(Signposts.downloadPreview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Whether Quick Look can show `file`.
    public static func canPreview(_ file: URL) -> Bool {
        QLPreviewController.canPreview(file as NSURL)
    }

    public nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        MainActor.assumeIsolated { files.count }
    }

    public nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        MainActor.assumeIsolated { files[index] as NSURL }
    }
}

#if DEBUG
#Preview("Downloads") {
    DownloadsView(source: PreviewData.downloads())
}
#endif
#endif
