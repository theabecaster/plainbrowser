import BrowserCore
import Foundation
import Observation
import PerfSignposts

/// State for the Settings sheet: the three stored settings, the custom search engine form and the
/// Clear History and Data action. Every change is saved at once; there is no Save button.
@Observable
public final class SettingsModel {
    /// The current settings. Shows the defaults until `load()` finishes; `isLoaded` says which.
    public private(set) var settings: BrowserSettings = .defaults
    public private(set) var isLoaded = false
    /// The custom engine the user defined, kept after switching away so it can be picked again.
    public private(set) var customEngine: SearchEngine?
    /// The custom engine address being typed.
    public var customTemplate = "" {
        didSet { customError = nil }
    }
    /// Why the typed custom address was rejected, as a sentence for the footer.
    public private(set) var customError: String?
    public private(set) var isClearing = false
    /// A one-sentence error for an alert, or nil.
    public var errorMessage: String?

    public let about: AboutInfo

    private let store: any SettingsStoring
    private let clearer: any BrowsingDataClearing
    private let writes = WriteQueue()
    /// Bumped by every change the user makes, so a read that started before it is not applied
    /// over it.
    private var edits = 0

    public init(store: any SettingsStoring, clearer: any BrowsingDataClearing, about: AboutInfo = .current) {
        self.store = store
        self.clearer = clearer
        self.about = about
    }

    /// Reads the stored settings. Safe to call more than once. The choices stay disabled until
    /// the first read finishes, so a change can never save defaults over the stored values.
    public func load() async {
        let editsAtStart = edits
        do {
            async let settings = store.settings()
            async let custom = store.savedCustomSearchEngine()
            let (loaded, savedCustom) = try await (settings, custom)
            // A change made while reading is newer than what was read.
            guard edits == editsAtStart else { return }
            self.settings = loaded
            customEngine = savedCustom ?? (loaded.searchEngine.isCustom ? loaded.searchEngine : nil)
            if customTemplate.isEmpty, let customEngine { customTemplate = customEngine.template }
            isLoaded = true
        } catch {
            errorMessage = Wording.loadFailed
        }
    }

    // MARK: Choices

    /// The engines offered: the catalog, then the custom engine when there is one.
    public var engineChoices: [SearchEngine] {
        SearchEngine.catalog + (customEngine.map { [$0] } ?? [])
    }

    public func selectSearchEngine(_ engine: SearchEngine) {
        guard isLoaded, engine != settings.searchEngine else { return }
        settings.searchEngine = engine
        save()
    }

    public func setTabLayout(_ layout: TabLayout) {
        guard isLoaded, layout != settings.tabLayout else { return }
        settings.tabLayout = layout
        save()
    }

    public func setArchiveAfter(_ archive: ArchiveAfter) {
        guard isLoaded, archive != settings.archiveAfter else { return }
        settings.archiveAfter = archive
        save()
    }

    /// Validates the typed address and, when it is good, makes it the search engine. Returns
    /// whether it was accepted; otherwise `customError` says why.
    @discardableResult
    public func useCustomTemplate() -> Bool {
        guard isLoaded else { return false }
        do {
            let engine = try Self.customEngine(from: customTemplate)
            customEngine = engine
            customTemplate = engine.template
            settings.searchEngine = engine
            save()
            return true
        } catch {
            customError = Wording.message(for: error)
            return false
        }
    }

    /// A custom engine from a typed results-page address. The name is the site's host, so the
    /// user types one thing. An address without a scheme gets `https://`.
    nonisolated static func customEngine(from typed: String) throws(SearchEngine.TemplateError) -> SearchEngine {
        var template = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !template.isEmpty, !template.contains("://") { template = "https://" + template }
        let sample = template.replacingOccurrences(of: SearchEngine.queryPlaceholder, with: "test")
        var host = URLComponents(string: sample)?.host ?? ""
        if host.lowercased().hasPrefix("www.") { host.removeFirst(4) }
        do {
            return try SearchEngine.custom(name: host, template: template)
        } catch .emptyName {
            // No host means the address is not a web address, not that a name is missing.
            throw .notAWebURL
        }
    }

    // MARK: Clear History and Data

    public func clearHistoryAndData() async {
        guard !isClearing else { return }
        isClearing = true
        let state = Signposts.signposter.beginInterval(Signposts.clearBrowsingData)
        do {
            try await clearer.clearHistoryAndData()
        } catch {
            errorMessage = Wording.clearFailed
        }
        Signposts.signposter.endInterval(Signposts.clearBrowsingData, state)
        isClearing = false
    }

    // MARK: Saving

    private func save() {
        edits += 1
        Signposts.signposter.emitEvent(Signposts.settingsChange)
        let snapshot = settings
        let store = store
        writes.enqueue({ try await store.saveSettings(snapshot) }) { [weak self] _ in
            guard let self else { return }
            errorMessage = Wording.saveFailed
            // Show what is really stored, so the failed choice can be made again.
            writes.enqueue({ [weak self] in await self?.reloadAfterFailure() }, onError: { _ in })
        }
    }

    private func reloadAfterFailure() async {
        let editsAtStart = edits
        guard let stored = try? await store.settings(), edits == editsAtStart else { return }
        settings = stored
    }

    /// Returns when every change so far is saved.
    func waitForSaves() async {
        await writes.drain()
    }
}

// MARK: - Wording

extension TabLayout {
    /// The row value and picker label.
    public var title: String {
        switch self {
        case .regular: "Regular"
        case .sideTabs: "Side Tabs"
        }
    }
}

extension ArchiveAfter {
    /// The row value and picker label.
    public var title: String {
        switch self {
        case .twelveHours: "After 12 Hours"
        case .oneDay: "After 1 Day"
        case .oneWeek: "After 1 Week"
        case .never: "Never"
        }
    }

    /// The section footer: one sentence on what the current choice does.
    public var footer: String {
        switch self {
        case .twelveHours: "Tabs you haven't used in 12 hours move to the archive."
        case .oneDay: "Tabs you haven't used in a day move to the archive."
        case .oneWeek: "Tabs you haven't used in a week move to the archive."
        case .never: "Tabs stay open until you close them."
        }
    }
}

/// Every sentence the FeatureUI screens show, in one place.
enum Wording {
    static let loadFailed = "Plain couldn't read your settings. Try again."
    static let saveFailed = "Plain couldn't save that change. Try again."
    static let clearFailed = "Plain couldn't clear everything. Try again."
    static let historyFailed = "Plain couldn't load your history. Try again."
    static let historyEditFailed = "Plain couldn't change your history. Try again."
    static let favoritesFooter = "Tap a favorite to rename it."
    static let favoritesFailed = "Plain couldn't change your favorites. Try again."

    static let tabLayoutFooter = "Side Tabs moves your tabs to a sidebar when the window is wide."
    static let searchEngineFooter = "Searches from the address bar use this engine."
    static let customEngineFooter = "Paste a search results address with %s where the search words go."
    static let clearFooter = "Removes your history, cookies and website data from this device."
    static let clearConfirmTitle = "Clear History and Data?"
    static let clearConfirmMessage = "Your history, cookies and website data will be removed. Open tabs and favorites stay."

    static func message(for error: any Error) -> String {
        switch error as? SearchEngine.TemplateError {
        case .missingPlaceholder?: "Add %s where the search words go."
        case .notAWebURL?, .emptyName?: "Enter a web address, like https://example.com/search?q=%s."
        case nil: "That address doesn't work. Try another."
        }
    }
}
