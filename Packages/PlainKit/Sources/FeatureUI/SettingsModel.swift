import BrowserCore
import DesignSystem
import Foundation
import Observation
import PerfSignposts

/// State for the Settings sheet: the four stored settings, the custom search engine form and the
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
    /// A tab list fits here (the Duo's inner screen). Elsewhere the Tab Layout row is disabled and
    /// its footer says why; the stored choice stays, so it comes back on a wide window.
    public var isTabLayoutAvailable = true
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
        let store = store
        do {
            // Queued behind any save still running, so it reads what the user last chose.
            let (loaded, savedCustom) = try await writes.perform {
                async let settings = store.settings()
                async let custom = store.savedCustomSearchEngine()
                return try await (settings, custom)
            }
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
        save { $0.searchEngine = engine }
        // The checkmark moved: a tick (docs/ui-reference.md, "Haptics").
        Haptic.selection.play()
    }

    public func setTabLayout(_ layout: TabLayout) {
        guard isLoaded, layout != settings.tabLayout else { return }
        settings.tabLayout = layout
        save { $0.tabLayout = layout }
    }

    public func setArchiveAfter(_ archive: ArchiveAfter) {
        guard isLoaded, archive != settings.archiveAfter else { return }
        settings.archiveAfter = archive
        save { $0.archiveAfter = archive }
    }

    /// Saves the choice; the shell applies it to every window as the save is handed to it.
    public func setAppearance(_ appearance: Appearance) {
        guard isLoaded, appearance != settings.appearance else { return }
        settings.appearance = appearance
        save { $0.appearance = appearance }
    }

    /// Settings > Appearance > Dark Pages. Saved like the rest; the shell applies it to every page
    /// as the save is handed to it, and counts turning it on as the suggestion's answer.
    public func setDarkPages(_ on: Bool) {
        guard isLoaded, on != settings.darkPages else { return }
        settings.darkPages = on
        save { $0.darkPages = on }
    }

    /// Dark Pages does nothing while Plain is set to Light: the switch keeps its value, disabled.
    public var isDarkPagesAvailable: Bool { settings.appearance != .light }

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
            save { $0.searchEngine = engine }
            Haptic.selection.play()
            return true
        } catch {
            customError = Wording.message(for: error)
            // Refused at once, and the footer says why.
            Haptic.nothingThere.play()
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
            // It worked, and the wait is over (a failure's alert is its own feedback).
            Haptic.success.play()
        } catch {
            errorMessage = Wording.clearFailed
        }
        Signposts.signposter.endInterval(Signposts.clearBrowsingData, state)
        isClearing = false
    }

    // MARK: Saving

    /// Saves one change over what is stored now, not this model's whole copy: another window's
    /// Settings, or the Dark Pages suggestion, may have saved a different setting meanwhile.
    private func save(_ change: @escaping @Sendable (inout BrowserSettings) -> Void) {
        edits += 1
        Signposts.signposter.emitEvent(Signposts.settingsChange)
        let store = store
        writes.enqueue({
            var stored = try await store.settings()
            change(&stored)
            try await store.saveSettings(stored)
        }) { [weak self] _ in
            guard let self else { return }
            errorMessage = Wording.saveFailed
            // Show what is really stored, so the failed choice can be made again.
            reconcile()
        }
    }

    /// Re-reads the store after every queued write and shows it, unless the user changed
    /// something since; then it tries again after that change's write.
    private func reconcile() {
        let mark = edits
        let store = store
        writes.enqueue({ [weak self] in
            let stored = try await store.settings()
            await self?.apply(stored, ifUnchangedSince: mark)
        }, onError: { _ in })
    }

    private func apply(_ stored: BrowserSettings, ifUnchangedSince mark: Int) {
        if edits == mark { settings = stored } else { reconcile() }
    }

    /// Returns when every change so far is saved.
    public func waitForSaves() async {
        await writes.drain()
    }
}

// MARK: - Wording

extension TabLayout {
    /// The row value and picker label.
    public var title: String {
        switch self {
        case .above: "Above"
        case .left: "Left"
        case .right: "Right"
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
        case .twelveHours: "Tabs you haven't opened in 12 hours move to the archive."
        case .oneDay: "Tabs you haven't opened in a day move to the archive."
        case .oneWeek: "Tabs you haven't opened in a week move to the archive."
        case .never: "Tabs stay open until you close them."
        }
    }

    /// The Archive screen's footer: when tabs move there under this choice, and that they leave
    /// after the archive's 30 days (`FixedChoices.archivedTabLifetime`). With Never, nothing moves
    /// there, so it says only how long tabs already there stay.
    public var archiveFooter: String {
        switch self {
        case .twelveHours: "Tabs you haven't opened in 12 hours move here and leave 30 days later."
        case .oneDay: "Tabs you haven't opened in a day move here and leave 30 days later."
        case .oneWeek: "Tabs you haven't opened in a week move here and leave 30 days later."
        case .never: "Tabs here leave after 30 days."
        }
    }
}

extension Appearance {
    /// The row value and picker label.
    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The section footer: one sentence on what the current choice does.
    public var footer: String {
        switch self {
        case .system: "Plain and websites follow your iPhone's light or dark setting."
        case .light: "Plain and websites stay light."
        case .dark: "Plain stays dark, and so do websites with a dark design."
        }
    }
}

/// Every sentence the FeatureUI screens show, in one place.
enum Wording {
    static let loadFailed = "Plain couldn't read your settings. Try again."
    static let saveFailed = "Plain couldn't save that change. Try again."
    static let clearFailed = "Plain couldn't clear everything. Try again."
    static let historyReadFailed = "Plain couldn't load your history."
    static let archiveReadFailed = "Plain couldn't load your archived tabs."
    static let favoritesReadFailed = "Plain couldn't load your favorites."
    static let historyEditFailed = "Plain couldn't change your history. Try again."
    /// The words of the empty states that show More's symbol (Style.swift); VoiceOver reads these.
    static let favoritesEmpty = "Tap More on a page, then Favorite."
    static let readingListEmpty = "Tap More on a page, then Read Later."
    static let favoritesFooter = "Swipe right to rename, left to delete. Tap Edit to reorder."
    static let favoritesFailed = "Plain couldn't change your favorites. Try again."
    static let readingListReadFailed = "Plain couldn't load your reading list."
    static let readingListEditFailed = "Plain couldn't change your reading list. Try again."

    /// Shown only where a tab list fits, which has a top bar and no swipe up from the address bar:
    /// the Tabs button shows them all.
    static let tabLayoutFooter = "Where your tabs show on this wide screen. The Tabs button shows them all."
    static let darkPagesFooter = "Darkens websites that have no dark mode of their own, while Plain is dark. Choices you make for a site stay."
    static let darkPagesLightFooter = "Plain is set to Light. Dark Pages works while Plain is dark."
    static let tabLayoutUnavailableFooter = "This screen is too narrow for a tab list. Swipe up from the address bar to see your tabs."
    static let searchEngineFooter = "Searches from the address bar use this engine."
    static let customEngineFooter = "Paste a search results address with %s where the search words go."
    static let clearFooter = "Removes your history, cookies and website data from this device."
    static let clearConfirmTitle = "Clear History and Data?"
    static let clearConfirmMessage = "Your history, cookies and website data will be removed. Open tabs, favorites and your reading list stay."

    static func message(for error: any Error) -> String {
        switch error as? SearchEngine.TemplateError {
        case .missingPlaceholder?: "Add %s where the search words go."
        case .notAWebURL?, .emptyName?: "Enter a web address, like https://example.com/search?q=%s."
        case nil: "That address doesn't work. Try another."
        }
    }
}
