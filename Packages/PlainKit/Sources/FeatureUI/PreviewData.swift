#if DEBUG
import BrowserCore
import Foundation
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
