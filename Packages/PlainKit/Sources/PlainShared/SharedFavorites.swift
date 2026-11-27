import Foundation

/// The App Group the app and its widget extension share. Both targets list it in their
/// entitlements; automatic signing registers it (docs/development.md, "Widgets and App Group").
public enum AppGroup {
    public static let identifier = "group.dev.abrahamgonzalez.plainbrowser"

    /// The shared folder, or nil when the process is not signed with the group (unit tests on
    /// macOS, an unsigned build).
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// A favorite as the widgets, the Open Favorite intent and Spotlight see it: a name and a page.
public struct SharedFavorite: Hashable, Sendable, Codable, Identifiable {
    public var url: URL
    public var title: String

    public var id: String { url.absoluteString }

    /// The favorite's name is its title, or the site's host without "www." when it has none. The
    /// same rule as the favorites above the keyboard, so a favorite reads the same everywhere.
    public init(url: URL, title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.url = url
        self.title = trimmed.isEmpty ? Self.siteName(url) : trimmed
    }

    /// The disc's letter: the name's first letter or digit, uppercased.
    public var monogram: String {
        title.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "•"
    }

    static func siteName(_ url: URL) -> String {
        guard var host = url.host(), !host.isEmpty else { return url.absoluteString }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}

/// The favorites list written for other processes: the widget extension and App Intents read it
/// without opening the database. The app writes it whenever favorites change (`SystemSync`).
///
/// One small JSON file in the App Group folder. Reads and writes touch the disk, so callers run
/// them off the main thread.
public struct SharedFavoritesFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The file in the App Group folder, or nil when the group is not available.
    public static var shared: SharedFavoritesFile? {
        AppGroup.containerURL.map { SharedFavoritesFile(url: $0.appending(path: "favorites.json")) }
    }

    /// The saved favorites in order; empty when there is no file or it can't be read.
    public func read() -> [SharedFavorite] {
        readIfPresent() ?? []
    }

    /// The saved favorites, or nil when there is no file or it can't be read: "unknown", which an
    /// empty list is not.
    public func readIfPresent() -> [SharedFavorite]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([SharedFavorite].self, from: data)
    }

    /// Replaces the file atomically, so a widget never reads half a list.
    public func write(_ favorites: [SharedFavorite]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(favorites).write(to: url, options: [.atomic])
    }
}

/// What the search widget shows: the first favorites that fit its row. Plain values, so the
/// widget's timeline is tested on macOS.
public struct SearchWidgetContent: Hashable, Sendable {
    /// The medium widget's row holds four 44 pt targets with their names.
    public static let favoriteSlots = 4

    public var favorites: [SharedFavorite]

    public init(favorites: [SharedFavorite]) {
        self.favorites = Array(favorites.prefix(Self.favoriteSlots))
    }

    /// From the App Group file (empty when there is none).
    public init(file: SharedFavoritesFile?) {
        self.init(favorites: file?.read() ?? [])
    }

    /// The widget gallery's sample, before the user has favorites of their own.
    public static let sample = SearchWidgetContent(favorites: [
        SharedFavorite(url: URL(string: "https://en.wikipedia.org")!, title: "Wikipedia"),
        SharedFavorite(url: URL(string: "https://news.ycombinator.com")!, title: "Hacker News"),
        SharedFavorite(url: URL(string: "https://github.com")!, title: "GitHub"),
        SharedFavorite(url: URL(string: "https://www.theverge.com")!, title: "The Verge"),
    ])
}
