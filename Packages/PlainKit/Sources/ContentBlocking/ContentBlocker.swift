import Foundation
import os
import PerfSignposts
import WebKit

/// Ad, tracker and cookie-banner blocking. Always on; the page menu turns it off per site.
///
/// Lifecycle:
/// 1. Create one `ContentBlocker` at launch. `init` does no work.
/// 2. After the first frame, call `prepare()`. It looks each bundled list up in the
///    `WKContentRuleListStore` by `<name>-<hash>` and compiles only the ones that are missing
///    (first launch, or after an app update that changed a list), then removes old versions.
///    Disk reads and hashing run off the main thread; WebKit compiles on its own queue.
/// 3. Call `apply(to:forMainFrameURL:)` for a web view's `WKUserContentController` before its
///    first real navigation and again in `decidePolicyFor navigationAction` for each main-frame
///    navigation. It attaches the lists, or detaches them on a site where blocking is off.
///    Lists that finish compiling later are attached to every controller already registered.
///
/// Per-site off works by detaching, not by an allow-list rule list: WebKit applies
/// `ignore-previous-rules` only to rules in the same compiled list, so a separate list cannot
/// unblock the bundled ones (measured; see docs/decisions.md). Detaching needs each web view to
/// have its own `WKUserContentController`; on a shared controller it would turn blocking off for
/// every tab.
@MainActor
public final class ContentBlocker {
    /// What `prepare()` did, for logs and tests.
    public struct PrepareReport: Sendable {
        public struct ListResult: Sendable {
            public let identifier: String
            public let ruleCount: Int
            /// True when the list was compiled, false when it was found in the store.
            public let compiled: Bool
            public let duration: Duration
        }

        public internal(set) var lists: [ListResult] = []
        /// One line per list that could not be loaded or compiled. Blocking runs without it.
        public internal(set) var failures: [String] = []
        /// Old list versions removed from the store.
        public internal(set) var removedStale: [String] = []
        /// From the start of `prepare()` until every list was available.
        public internal(set) var duration: Duration = .zero
    }

    /// The compiled lists, in manifest order. Empty until `prepare()` has found or compiled them.
    public private(set) var ruleLists: [WKContentRuleList] = []
    /// True once `prepare()` has finished.
    public private(set) var isReady = false

    private let store: WKContentRuleListStore
    private let allowListStore: any SiteAllowListStore
    private let resourceDirectory: URL?
    private let logger = Logger(subsystem: Signposts.subsystem, category: "contentBlocking")

    private var allowedSites: Set<String> = []
    private var allowListLoaded = false
    /// Allow-list edits made before the stored list finished loading, replayed on top of it.
    private var editsBeforeLoad: [(inout Set<String>) -> Void] = []
    private var prepareTask: Task<PrepareReport, Never>?
    private var saveTask: Task<Void, Never>?

    /// The controllers this blocker manages and what it attached to each. Weak keys: a controller
    /// that goes away drops out on its own.
    private let controllers = NSMapTable<WKUserContentController, ControllerState>.weakToStrongObjects()

    private final class ControllerState {
        var mainFrameURL: URL?
        var attached: [WKContentRuleList] = []
    }

    /// - Parameters:
    ///   - allowListStore: persists the sites where blocking is off.
    ///   - store: where compiled lists live. Defaults to `WKContentRuleListStore.default()`.
    ///   - resourceDirectory: the folder with `manifest.json` and the lists. Defaults to the
    ///     lists bundled with this module.
    public init(
        allowListStore: any SiteAllowListStore,
        store: WKContentRuleListStore? = nil,
        resourceDirectory: URL? = nil
    ) {
        self.allowListStore = allowListStore
        self.store = store ?? .default()
        self.resourceDirectory = resourceDirectory
    }

    // MARK: - Preparing

    /// Loads the allow-list and every bundled list: a store lookup when the list's identifier is
    /// there, a compile when it is not. Never call it before the first frame. Safe to call more
    /// than once; later calls wait for the first and return its report.
    @discardableResult
    public func prepare() async -> PrepareReport {
        if let prepareTask { return await prepareTask.value }
        let task = Task { await load() }
        prepareTask = task
        return await task.value
    }

    private func load() async -> PrepareReport {
        let signpost = Signposts.signposter.beginInterval("contentBlocking.prepare")
        defer { Signposts.signposter.endInterval("contentBlocking.prepare", signpost) }
        let clock = ContinuousClock()
        let start = clock.now
        var report = PrepareReport()

        await loadAllowList()

        guard let directory = resourceDirectory ?? RuleListManifest.bundledDirectory else {
            report.failures.append("resources: \(ContentBlockerError.missingResources)")
            return finish(report, start: start)
        }
        let manifest: RuleListManifest
        do {
            manifest = try await RuleListManifest.load(from: directory)
        } catch {
            report.failures.append("manifest: \(error)")
            return finish(report, start: start)
        }

        for list in manifest.lists {
            let listStart = clock.now
            do {
                let (ruleList, compiled) = try await lookUpOrCompile(list, in: directory)
                ruleLists.append(ruleList)
                syncAllControllers()
                report.lists.append(.init(
                    identifier: list.identifier, ruleCount: list.ruleCount, compiled: compiled,
                    duration: clock.now - listStart))
            } catch {
                report.failures.append("\(list.name): \(error)")
                logger.error("Content rule list \(list.identifier, privacy: .public) failed: \(error)")
            }
        }
        report = finish(report, start: start)

        report.removedStale = await removeStaleLists(keeping: Set(manifest.lists.map(\.identifier)))
        return report
    }

    private func finish(_ report: PrepareReport, start: ContinuousClock.Instant) -> PrepareReport {
        var report = report
        report.duration = ContinuousClock.now - start
        isReady = true
        let compiled = report.lists.filter(\.compiled).count
        logger.info(
            "Content blocking ready: \(report.lists.count) lists (\(compiled) compiled) in \(report.duration)")
        return report
    }

    private func lookUpOrCompile(
        _ list: RuleListManifest.List, in directory: URL
    ) async throws -> (WKContentRuleList, compiled: Bool) {
        // A miss throws (WKError.contentRuleListStoreLookUpFailed), as does a list compiled by an
        // older WebKit (contentRuleListStoreVersionMismatch). Both mean: compile it.
        if let found = try? await store.contentRuleList(forIdentifier: list.identifier) {
            return (found, false)
        }
        let signpost = Signposts.signposter.beginInterval("contentBlocking.compile")
        defer { Signposts.signposter.endInterval("contentBlocking.compile", signpost) }
        let json = try await RuleListManifest.readJSON(of: list, in: directory)
        guard
            let compiled = try await store.compileContentRuleList(
                forIdentifier: list.identifier, encodedContentRuleList: json.value as String)
        else {
            throw ContentBlockerError.missingResources
        }
        return (compiled, true)
    }

    /// Removes store entries for bundled lists that the manifest no longer names: old hashes and
    /// lists that are no longer produced. Entries other code added (other prefixes) are left alone.
    private func removeStaleLists(keeping current: Set<String>) async -> [String] {
        let stale = (await store.availableIdentifiers() ?? []).filter {
            $0.hasPrefix(RuleListManifest.namePrefix) && !current.contains($0)
        }
        var removed: [String] = []
        for identifier in stale {
            do {
                try await store.removeContentRuleList(forIdentifier: identifier)
                removed.append(identifier)
            } catch {
                logger.error("Removing stale list \(identifier, privacy: .public) failed: \(error)")
            }
        }
        return removed
    }

    // MARK: - Attaching

    /// Attaches the lists to `controller`, or detaches them when blocking is off for the site of
    /// `mainFrameURL`. Call it before a web view's first real navigation and for every main-frame
    /// navigation (in `decidePolicyFor navigationAction`, before allowing it). Cheap and
    /// idempotent: it only adds or removes what changed.
    ///
    /// `controller` must belong to a single web view. See the type's documentation.
    public func apply(to controller: WKUserContentController, forMainFrameURL mainFrameURL: URL?) {
        let state = controllers.object(forKey: controller) ?? {
            let state = ControllerState()
            controllers.setObject(state, forKey: controller)
            return state
        }()
        state.mainFrameURL = mainFrameURL
        sync(controller, state)
    }

    /// Detaches the lists from `controller` and stops managing it.
    public func release(_ controller: WKUserContentController) {
        guard let state = controllers.object(forKey: controller) else { return }
        for list in state.attached { controller.remove(list) }
        controllers.removeObject(forKey: controller)
    }

    private func sync(_ controller: WKUserContentController, _ state: ControllerState) {
        let wanted = isBlockingEnabled(for: state.mainFrameURL) ? ruleLists : []
        for list in state.attached where !wanted.contains(where: { $0 === list }) {
            controller.remove(list)
        }
        for list in wanted where !state.attached.contains(where: { $0 === list }) {
            controller.add(list)
        }
        state.attached = wanted
    }

    private func syncAllControllers() {
        for case let controller as WKUserContentController in controllers.keyEnumerator().allObjects {
            if let state = controllers.object(forKey: controller) { sync(controller, state) }
        }
    }

    // MARK: - Per-site off

    /// False when the user turned blocking off for this URL's site.
    public func isBlockingEnabled(for url: URL?) -> Bool {
        !SiteKey.host(url?.host(), isIn: allowedSites)
    }

    /// Turns blocking on or off for the site of `host` ("Turn off on this site" in the page menu).
    /// Takes effect at once for every managed controller; reload the page to see it. Turning it
    /// back on also removes an entry for a parent domain that covered `host`.
    public func setBlockingEnabled(_ enabled: Bool, forHost host: String) {
        guard let site = SiteKey.site(forHost: host) else { return }
        let edit: (inout Set<String>) -> Void = { sites in
            if enabled {
                sites = sites.filter { !SiteKey.host(site, isIn: [$0]) }
            } else {
                sites.insert(site)
            }
        }
        edit(&allowedSites)
        if allowListLoaded {
            persistAllowList()
        } else {
            editsBeforeLoad.append(edit)
        }
        syncAllControllers()
    }

    /// Waits until every allow-list change so far is saved. For tests and app suspension.
    public func waitForPendingSaves() async {
        await saveTask?.value
    }

    private func loadAllowList() async {
        do {
            allowedSites = try await allowListStore.loadAllowedSites()
        } catch {
            logger.error("Loading the allow-list failed: \(error)")
            allowedSites = []
        }
        for edit in editsBeforeLoad { edit(&allowedSites) }
        let hadEdits = !editsBeforeLoad.isEmpty
        editsBeforeLoad = []
        allowListLoaded = true
        if hadEdits { persistAllowList() }
        syncAllControllers()
    }

    /// Saves the current set after any save already running, so saves land in order.
    private func persistAllowList() {
        let snapshot = allowedSites
        let previous = saveTask
        let store = allowListStore
        let logger = logger
        saveTask = Task {
            await previous?.value
            do {
                try await store.saveAllowedSites(snapshot)
            } catch {
                logger.error("Saving the allow-list failed: \(error)")
            }
        }
    }
}
