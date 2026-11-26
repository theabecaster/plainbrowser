#if canImport(UIKit)
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
