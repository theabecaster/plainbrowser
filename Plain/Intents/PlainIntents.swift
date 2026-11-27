import AppIntents
import BrowserCore
import Foundation
import PlainShared

// Plain's actions for Shortcuts, Siri, Spotlight and the Action button
// (docs/research/system-integration.md). Each one opens Plain and hands a `PlainCommand` to the
// scene through `CommandInbox`; the browser does the rest, as for a tap. They live in the app
// target because App Intents reads its metadata from the target that declares the types.
// `OpenPlainIntent`, the controls' action, is in PlainWidgets/ (compiled into both targets).

/// Search the web with the engine chosen in Settings (`FixedChoices.intentsUseSettingsEngine`).
/// The `system.searchInApp` schema lets Siri and Apple Intelligence say "search in Plain".
@AppIntent(schema: .system.searchInApp)
struct SearchIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Search in Plain"
    static let description = IntentDescription("Searches the web in a new tab, with your search engine.")
    static let searchScopes: [StringSearchScope] = [.general]

    var criteria: StringSearchCriteria

    @MainActor
    func perform() async throws -> some IntentResult {
        let query = criteria.term.trimmingCharacters(in: .whitespacesAndNewlines)
        CommandInbox.shared.send(query.isEmpty ? .focusSearch : .search(query))
        return .result()
    }
}

/// Open a web address. An address without a scheme gets one, as in the address bar.
struct OpenPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Open URL"
    static let description = IntentDescription("Opens a web page in a new tab.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "URL")
    var url: URL

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$url) in Plain")
    }

    init() {}

    init(url: URL) {
        self.url = url
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard case .url(let page)? = AddressBarInput(url.absoluteString) else {
            throw $url.needsValueError("Which web page? Plain opens addresses like apple.com.")
        }
        CommandInbox.shared.send(.open(page))
        return .result()
    }
}

struct NewTabIntent: AppIntent {
    static let title: LocalizedStringResource = "New Tab"
    static let description = IntentDescription("Opens a new tab with the search field ready.")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        CommandInbox.shared.send(.newTab)
        return .result()
    }
}

struct NewPrivateTabIntent: AppIntent {
    static let title: LocalizedStringResource = "New Private Tab"
    static let description = IntentDescription("Opens a private tab: no history, and nothing kept after you close it.")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        CommandInbox.shared.send(.newPrivateTab)
        return .result()
    }
}

struct ShowTabsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Tabs"
    static let description = IntentDescription("Shows your open tabs.")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        CommandInbox.shared.send(.showTabs)
        return .result()
    }
}

// MARK: Favorites

/// A favorite, as Shortcuts and Siri see it. Read from the file the app shares with its widgets
/// (`SharedFavoritesFile`), so a query never opens the database.
nonisolated struct FavoriteEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Favorite"
    static let defaultQuery = FavoriteQuery()

    /// The page's address: unique among favorites.
    let id: String
    let title: String
    let url: URL

    init(_ favorite: SharedFavorite) {
        id = favorite.id
        title = favorite.title
        url = favorite.url
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(url.host() ?? url.absoluteString)")
    }
}

nonisolated struct FavoriteQuery: EntityStringQuery {
    /// Reads the shared file (a small JSON file); never on the main thread.
    var favorites: @Sendable () -> [SharedFavorite] = { SharedFavoritesFile.shared?.read() ?? [] }

    func entities(for identifiers: [FavoriteEntity.ID]) async throws -> [FavoriteEntity] {
        let wanted = Set(identifiers)
        return favorites().filter { wanted.contains($0.id) }.map(FavoriteEntity.init)
    }

    func suggestedEntities() async throws -> [FavoriteEntity] {
        favorites().map(FavoriteEntity.init)
    }

    func entities(matching string: String) async throws -> [FavoriteEntity] {
        let words = string.split(whereSeparator: \.isWhitespace)
        return favorites().filter { favorite in
            let haystack = favorite.title + " " + favorite.url.absoluteString
            return words.allSatisfy { haystack.localizedStandardContains($0) }
        }
        .map(FavoriteEntity.init)
    }
}

struct OpenFavoriteIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Favorite"
    static let description = IntentDescription("Opens one of your favorites in a new tab.")

    @Parameter(title: "Favorite")
    var target: FavoriteEntity

    init() {}

    init(target: FavoriteEntity) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        CommandInbox.shared.send(.open(target.url))
        return .result()
    }
}

// MARK: App Shortcuts

/// Ready-made shortcuts: Siri phrases, the Shortcuts app's Plain section and Spotlight's action
/// tiles, with no setup. Every phrase names the app, as Siri requires.
nonisolated struct PlainShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchIntent(),
            phrases: ["Search in \(.applicationName)", "Search the web in \(.applicationName)", "\(.applicationName) search"],
            shortTitle: "Search", systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: NewTabIntent(),
            phrases: ["New \(.applicationName) tab", "Open a new tab in \(.applicationName)"],
            shortTitle: "New Tab", systemImageName: "plus"
        )
        AppShortcut(
            intent: NewPrivateTabIntent(),
            phrases: ["New private tab in \(.applicationName)", "Open a private tab in \(.applicationName)"],
            shortTitle: "New Private Tab", systemImageName: "hand.raised"
        )
        AppShortcut(
            intent: OpenFavoriteIntent(),
            phrases: ["Open \(\.$target) in \(.applicationName)", "Open a favorite in \(.applicationName)"],
            shortTitle: "Open Favorite", systemImageName: "star"
        )
        AppShortcut(
            intent: ShowTabsIntent(),
            phrases: ["Show my \(.applicationName) tabs", "Show tabs in \(.applicationName)"],
            shortTitle: "Show Tabs", systemImageName: "square.grid.2x2"
        )
        AppShortcut(
            intent: OpenPageIntent(),
            phrases: ["Open a website in \(.applicationName)", "Open a page in \(.applicationName)"],
            shortTitle: "Open URL", systemImageName: "link"
        )
    }
}
