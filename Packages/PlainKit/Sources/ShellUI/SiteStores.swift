#if canImport(UIKit)
import BrowserCore
import ContentBlocking
import Foundation
import Reader
import Storage
import WebEngine
import WebKit

// Adapters between the engine-layer seams (WebEngine, ContentBlocking, Reader) and Storage. They
// live in the shell because it is the one layer that sees both sides: Storage never imports the
// engine, and engine targets never import each other.

/// The app's database, once it has opened off the main thread. Every store below works before
/// then: reads wait for it, and the content mode map fills when it arrives.
public typealias DatabaseProvider = @Sendable () async -> AppDatabase?

/// Permission answers (camera, microphone, location, motion) remembered per site in Storage.
nonisolated struct StorageSitePermissionStore: SitePermissionStore {
    let database: DatabaseProvider

    func isAllowed(_ permission: SitePermission, forSite site: String) async -> Bool? {
        guard let database = await database() else { return nil }
        return try? await database.sitePermission(permission.rawValue, forSite: site)
    }

    func setAllowed(_ allowed: Bool, _ permission: SitePermission, forSite site: String) async {
        guard let database = await database() else { return }
        try? await database.setSitePermission(allowed, permission.rawValue, forSite: site)
    }

    func answers(forSite site: String) async -> [SitePermission: Bool] {
        guard let database = await database(), let stored = try? await database.sitePermissions(forSite: site) else {
            return [:]
        }
        var answers: [SitePermission: Bool] = [:]
        for (name, allowed) in stored {
            if let permission = SitePermission(rawValue: name) { answers[permission] = allowed }
        }
        return answers
    }
}

/// Desktop or mobile per site. The engine asks on every navigation start, so answers come from an
/// in-memory map, loaded once from Storage after launch; changes go to the map at once and to
/// Storage behind it, in order.
final class StorageSiteContentModeStore: SiteContentModeStore {
    private var modes: [String: ContentMode] = [:]
    /// Choices made before the stored map arrived, applied on top of it.
    private var editsBeforeLoad: [String: ContentMode?] = [:]
    private var isLoaded = false
    private var lastWrite: Task<Void, Never>?
    private let database: DatabaseProvider

    init(database: @escaping DatabaseProvider) {
        self.database = database
    }

    /// Reads the stored choices off the main thread. Call once, after the first frame.
    func load() async {
        guard !isLoaded, let database = await database() else { return }
        let stored = (try? await database.siteContentModes()) ?? [:]
        guard !isLoaded else { return }
        modes = stored.compactMapValues(ContentMode.init(rawValue:))
        for (site, mode) in editsBeforeLoad { modes[site] = mode }
        editsBeforeLoad = [:]
        isLoaded = true
    }

    func contentMode(forSite site: String) -> ContentMode? {
        modes[site]
    }

    func setContentMode(_ mode: ContentMode?, forSite site: String) {
        modes[site] = mode
        if !isLoaded { editsBeforeLoad[site] = mode }
        let previous = lastWrite
        let database = database
        lastWrite = Task {
            await previous?.value
            try? await database()?.setSiteContentMode(mode?.rawValue, forSite: site)
        }
    }
}

/// Page zoom per site. The engine reads it at every page commit, so answers come from an in-memory
/// map loaded once from Storage after launch; changes go to the map at once and to Storage behind
/// it, in order. Private tabs never reach it (the pool keeps their zooms in memory).
final class StorageSitePageZoomStore: SitePageZoomStore {
    private var zooms: [String: Double] = [:]
    /// Choices made before the stored map arrived, applied on top of it.
    private var editsBeforeLoad: [String: Double?] = [:]
    private var isLoaded = false
    private var lastWrite: Task<Void, Never>?
    private let database: DatabaseProvider

    init(database: @escaping DatabaseProvider) {
        self.database = database
    }

    /// Reads the stored zooms off the main thread. Call once, after the first frame.
    func load() async {
        guard !isLoaded, let database = await database() else { return }
        let stored = (try? await database.sitePageZooms()) ?? [:]
        guard !isLoaded else { return }
        zooms = stored
        for (site, zoom) in editsBeforeLoad { zooms[site] = zoom }
        editsBeforeLoad = [:]
        isLoaded = true
    }

    func pageZoom(forSite site: String) -> Double? {
        zooms[site]
    }

    func setPageZoom(_ zoom: Double?, forSite site: String) {
        zooms[site] = zoom
        if !isLoaded { editsBeforeLoad[site] = .some(zoom) }
        let previous = lastWrite
        let database = database
        lastWrite = Task {
            await previous?.value
            try? await database()?.setSitePageZoom(zoom, forSite: site)
        }
    }
}

/// Dark Pages' switch and the sites with a choice of their own: the one owner of the policy the
/// engine builds each page's script from (docs/research/dark-pages-optin.md, "State model").
///
/// The engine needs the whole policy at document start, before the database opens, so the last
/// one is kept as a launch copy in user defaults (`TestIsolation.defaults`) and read as the app
/// starts: a restored tab never darkens a site the user turned off, nor misses one turned on.
/// Storage stays the store of record: the switch is a setting (`BrowserSettings.darkPages`, given
/// here by the shell as it is read or saved), the site choices two tables, read once after the
/// first frame to reconcile. Changes go to memory and the copy at once, to Storage behind them in
/// order; a choice made before the stored list arrived wins over it. Private tabs never reach it
/// (the pool keeps theirs in memory). Every window's pool follows it (`observe`).
final class StorageSiteDarkPagesStore: SiteDarkPagesStore {
    static let launchKey = "PlainDarkPages"
    private(set) var choices: DarkPagesChoices
    /// Choices made before the stored list arrived, applied on top of it.
    private var editsBeforeLoad: [String: DarkPagesSiteChoice] = [:]
    private var isLoaded = false
    private var lastWrite: Task<Void, Never>?
    private let database: DatabaseProvider
    private let defaults: UserDefaults
    private var observers: [() -> Void] = []

    init(database: @escaping DatabaseProvider, defaults: UserDefaults = TestIsolation.defaults) {
        self.database = database
        self.defaults = defaults
        choices = Self.launchCopy(defaults.dictionary(forKey: Self.launchKey))
    }

    /// `observer` runs on the main thread after every change of the policy (each window's pool
    /// rebuilds its scripts and tells the pages on screen).
    func observe(_ observer: @escaping () -> Void) {
        observers.append(observer)
    }

    /// Reads the stored site choices off the main thread. Call once, after the first frame.
    /// Returns whether the policy changed, so the pools can update their pages.
    func load() async -> Bool {
        guard !isLoaded, let database = await database() else { return false }
        // A failed read keeps the launch copy (and the next launch reads again): an empty list
        // would darken sites the user turned off.
        guard let stored = try? await database.darkPagesSiteChoices(), !isLoaded else { return false }
        var loaded = DarkPagesChoices(enabled: choices.enabled, onSites: stored.on, offSites: stored.off)
        for (site, choice) in editsBeforeLoad { loaded.setChoice(choice, for: site) }
        editsBeforeLoad = [:]
        isLoaded = true
        return replace(with: loaded)
    }

    func setChoice(_ choice: DarkPagesSiteChoice, forSite site: String) {
        var next = choices
        next.setChoice(choice, for: site)
        if !isLoaded { editsBeforeLoad[site] = choice }
        // Every window follows; the acting pool also awaits its own pages for the crossfade.
        _ = replace(with: next)
        let previous = lastWrite
        let database = database
        lastWrite = Task {
            await previous?.value
            try? await database()?.setDarkPagesChoice(choice, forSite: site)
        }
    }

    /// The switch, from the settings in effect (read at launch, or saved). Returns whether it
    /// changed; the observers have run by then.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        var next = choices
        next.enabled = enabled
        return replace(with: next)
    }

    /// Puts `next` in effect, keeps the launch copy and tells the observers, when it changed.
    private func replace(with next: DarkPagesChoices) -> Bool {
        guard next != choices else { return false }
        choices = next
        defaults.set(Self.launchCopy(next), forKey: Self.launchKey)
        for observer in observers { observer() }
        return true
    }

    /// The launch copy as plain property-list values (no coding on the main thread).
    private static func launchCopy(_ choices: DarkPagesChoices) -> [String: Any] {
        ["enabled": choices.enabled, "on": Array(choices.onSites), "off": Array(choices.offSites)]
    }

    private static func launchCopy(_ stored: [String: Any]?) -> DarkPagesChoices {
        guard let stored else { return DarkPagesChoices() }
        return DarkPagesChoices(
            enabled: stored["enabled"] as? Bool ?? FixedChoices.darkPagesDefaultEnabled,
            onSites: Set(stored["on"] as? [String] ?? []), offSites: Set(stored["off"] as? [String] ?? [])
        )
    }
}

/// The sites where cookie banner handling is off. Every page's first message is answered from
/// memory, loaded once from Storage after launch; changes go to memory at once and to Storage
/// behind it, in order. Private tabs never reach it (`CookieBanners` keeps theirs in memory).
final class StorageSiteCookieBannersStore: SiteCookieBannersStore {
    private(set) var offSites: Set<String> = []
    /// Choices made before the stored list arrived, applied on top of it.
    private var editsBeforeLoad: [String: Bool] = [:]
    private var isLoaded = false
    private var lastWrite: Task<Void, Never>?
    private let database: DatabaseProvider

    init(database: @escaping DatabaseProvider) {
        self.database = database
    }

    /// Reads the stored list off the main thread. Call once, after the first frame.
    func load() async {
        guard !isLoaded, let database = await database() else { return }
        let stored = (try? await database.cookieBannersOffSites()) ?? []
        guard !isLoaded else { return }
        var sites = stored
        for (site, off) in editsBeforeLoad {
            if off { sites.insert(site) } else { sites.remove(site) }
        }
        editsBeforeLoad = [:]
        isLoaded = true
        offSites = sites
    }

    func setCookieBannersOff(_ off: Bool, forSite site: String) {
        if off { offSites.insert(site) } else { offSites.remove(site) }
        if !isLoaded { editsBeforeLoad[site] = off }
        let previous = lastWrite
        let database = database
        lastWrite = Task {
            await previous?.value
            try? await database()?.setCookieBannersOff(off, forSite: site)
        }
    }
}

/// `CookieBanners` already has `PageScripts`' one method.
extension CookieBanners: PageScripts {}

/// The shell's page scripts, in order: Reader's check, then cookie banners.
final class ShellPageScripts: PageScripts {
    let parts: [any PageScripts]

    init(_ parts: [any PageScripts]) {
        self.parts = parts
    }

    func install(in controller: WKUserContentController) {
        for part in parts { part.install(in: controller) }
    }
}

/// The sites where blocking is off, in Storage.
nonisolated struct StorageSiteAllowListStore: SiteAllowListStore {
    let database: DatabaseProvider

    func loadAllowedSites() async throws -> Set<String> {
        guard let database = await database() else { return [] }
        return try await database.blockingAllowList()
    }

    func saveAllowedSites(_ sites: Set<String>) async throws {
        guard let database = await database() else { return }
        try await database.saveBlockingAllowList(sites)
    }
}

/// `ContentBlocker` already has `UserContentRules`' two methods.
extension ContentBlocker: UserContentRules {}

/// Adds Reader's readerable check to every tab's controller. The check's source is read off the
/// main thread after launch; controllers made before that (the warm web view) get it when it is
/// ready, from their next page on.
final class ReaderPageScripts: PageScripts {
    let extractor: ReaderExtractor
    private let waiting = NSHashTable<WKUserContentController>.weakObjects()

    init(extractor: ReaderExtractor) {
        self.extractor = extractor
    }

    func install(in controller: WKUserContentController) {
        if !extractor.installPrepared(in: controller) { waiting.add(controller) }
    }

    /// Reads the check, then installs it in every controller made while it was being read.
    func prepare() async {
        guard (try? await extractor.prepare()) != nil else { return }
        for controller in waiting.allObjects { extractor.installPrepared(in: controller) }
        waiting.removeAllObjects()
    }
}
#endif
