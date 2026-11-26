#if DEBUG
import BrowserCore
import Foundation
import Observation
import Storage

/// Sample stores for SwiftUI previews and screenshot harnesses. Debug builds only.
public enum PreviewData {
    public static let about = AboutInfo(name: "Plain", version: "0.1.0", build: "1", documents: [])

    public static func settingsModel() -> SettingsModel {
        SettingsModel(store: try! AppDatabase.inMemory(), clearer: NoOpClearer(), about: about)
    }

    public static func historyModel(now: Date = Date()) -> HistoryModel {
        HistoryModel(store: SampleHistory(now: now))
    }

    public static func favoritesModel() -> FavoritesModel {
        FavoritesModel(store: SampleFavorites())
    }

    /// Downloads in every state: running with a known size, starting, finished, cancelled, failed.
    public static func downloads() -> SampleDownloads {
        let folder = FileManager.default.temporaryDirectory.appending(path: "PreviewDownloads")
        return SampleDownloads(directory: folder, downloads: [
            SampleDownload("Quarterly Report.pdf", file: folder.appending(path: "Quarterly Report.pdf"), bytes: 2_400_000),
            SampleDownload("photo-2026-11-20.jpg", file: folder.appending(path: "photo-2026-11-20.jpg"), bytes: 845_000),
            SampleDownload("old-installer.dmg", cancelled: true),
            SampleDownload("archive.zip", failed: true),
            SampleDownload("podcast-episode-214.mp3", running: 31_200_000, of: 58_900_000),
            SampleDownload("dataset.csv", running: 0, of: -1),
        ])
    }

    public static func noDownloads() -> SampleDownloads {
        SampleDownloads(directory: FileManager.default.temporaryDirectory, downloads: [])
    }

    @Observable
    public final class SampleDownloads: DownloadListSource {
        public let directory: URL
        public var downloads: [SampleDownload]

        init(directory: URL, downloads: [SampleDownload]) {
            self.directory = directory
            self.downloads = downloads
        }
    }

    @Observable
    public final class SampleDownload: DownloadListItem {
        public let id = UUID()
        public let filename: String
        public let progress: Progress
        public private(set) var fileURL: URL?
        public private(set) var isInProgress = false
        public private(set) var isCancelled = false

        init(_ name: String, file: URL? = nil, bytes: Int64 = 0, cancelled: Bool = false, failed: Bool = false,
             running completed: Int64? = nil, of total: Int64 = 0) {
            filename = name
            fileURL = file
            isCancelled = cancelled
            isInProgress = completed != nil
            progress = Progress(totalUnitCount: completed == nil ? bytes : total)
            progress.completedUnitCount = completed ?? bytes
        }

        public func cancel() {
            isInProgress = false
            isCancelled = true
        }
    }

    struct NoOpClearer: BrowsingDataClearing {
        func clearHistoryAndData() async throws {}
    }

    /// History in memory, filtered by plain substring match.
    actor SampleHistory: HistoryStoring {
        private var visits: [HistoryVisit]

        init(now: Date) {
            let pages: [(String, String, TimeInterval)] = [
                ("https://www.apple.com/iphone/", "iPhone - Apple", 5 * 60),
                ("https://developer.apple.com/documentation/swiftui", "SwiftUI | Apple Developer Documentation", 40 * 60),
                ("https://github.com/theabecaster/plainbrowser", "theabecaster/plainbrowser", 2 * 3600),
                ("https://en.wikipedia.org/wiki/Web_browser", "Web browser - Wikipedia", 3 * 3600),
                ("https://news.ycombinator.com/", "Hacker News", 26 * 3600),
                ("https://www.nytimes.com/", "The New York Times", 27 * 3600),
                ("https://swift.org/blog/", "Blog - Swift.org", 50 * 3600),
                ("https://www.theverge.com/tech", "Tech - The Verge", 75 * 3600),
            ]
            visits = pages.enumerated().map { index, page in
                var visit = HistoryVisit(url: URL(string: page.0)!, title: page.1, visitedAt: now.addingTimeInterval(-page.2))
                visit.id = Int64(index + 1)
                return visit
            }
        }

        func visits(matching query: String, limit: Int) async throws -> [HistoryVisit] {
            let matches = query.isEmpty ? visits : visits.filter {
                ($0.title ?? "").localizedCaseInsensitiveContains(query)
                    || $0.url.absoluteString.localizedCaseInsensitiveContains(query)
            }
            return Array(matches.prefix(limit))
        }

        func deleteHistory(for url: URL) async throws {
            visits.removeAll { $0.url == url }
        }

        func clearHistory(since start: Date?) async throws {
            visits.removeAll { start == nil || $0.visitedAt >= start! }
        }
    }

    /// Favorites in an in-memory database.
    final class SampleFavorites: FavoritesStoring {
        private let database: AppDatabase

        init() {
            database = try! AppDatabase.inMemory()
        }

        private func seedIfNeeded() async throws {
            guard try await database.favorites().isEmpty else { return }
            for (url, title) in [
                ("https://www.apple.com/", "Apple"),
                ("https://github.com/", "GitHub"),
                ("https://en.wikipedia.org/", "Wikipedia"),
                ("https://news.ycombinator.com/", "Hacker News"),
                ("https://www.theverge.com/", nil as String?),
            ] {
                try await database.addFavorite(url: URL(string: url)!, title: title)
            }
        }

        func favorites() async throws -> [Favorite] {
            try await seedIfNeeded()
            return try await database.favorites()
        }

        func renameFavorite(id: Int64, title: String) async throws {
            try await database.renameFavorite(id: id, title: title)
        }

        func removeFavorite(id: Int64) async throws {
            try await database.removeFavorite(id: id)
        }

        func moveFavorite(id: Int64, to index: Int) async throws {
            try await database.moveFavorite(id: id, to: index)
        }
    }
}
#endif
