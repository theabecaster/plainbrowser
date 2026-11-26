#if canImport(UIKit)
import Foundation
import Observation
import UIKit

/// How much a tab costs right now (docs/plan.md, "Engine rules" 2).
public enum TabTier: Sendable, Equatable {
    /// Has a running web view: visible, or one of the most recent tabs.
    case live
    /// Keeps its web view, but WebKit suspends it (`inactiveSchedulingPolicy = .suspend`).
    case suspended
    /// No web view. Holds `interactionState` and sessionStorage; restores on attach.
    case discarded
}

/// What the address bar shows about the connection.
public enum SecurityState: Sendable, Equatable {
    /// No page, or an internal one (`about:blank`).
    case none
    /// HTTPS, and every resource on the page came over HTTPS.
    case secure
    /// HTTP, or HTTPS with insecure resources mixed in.
    case notSecure
    /// The user chose to visit past a certificate error.
    case certificateBypassed
}

/// A main-frame load that failed, for the shell's error page.
public struct LoadError: Sendable, Equatable {
    public let url: URL?
    public let code: Int
    public let domain: String
    public let message: String
}

/// One tab. The shell's `TabStore` owns it; the `WebViewPool` owns its web view.
///
/// Observed properties change at most a few times per navigation. Progress changes every few
/// frames, so it is kept out of observation and delivered through `onProgress` instead
/// (docs/plan.md, "Models").
@Observable
public final class Tab: Identifiable {
    public let id: UUID
    /// The tab whose page opened this one (popup, `window.open`, `target=_blank`).
    public let openerID: UUID?

    public internal(set) var url: URL?
    public internal(set) var title = ""
    public internal(set) var isLoading = false
    public internal(set) var canGoBack = false
    public internal(set) var canGoForward = false
    public internal(set) var security = SecurityState.none
    public internal(set) var tier = TabTier.discarded
    /// The mode the current page was loaded in, decided when its navigation started.
    public internal(set) var contentMode = ContentMode.mobile
    /// The last main-frame load error, cleared when the next navigation starts.
    public internal(set) var loadError: LoadError?
    /// Bumped when a new thumbnail is stored; read it with `WebViewPool.thumbnail(for:)`.
    public internal(set) var thumbnailRevision = 0

    /// Load progress from 0 to 1. Not observed: read it from `onProgress`.
    @ObservationIgnored public internal(set) var progress: Double = 0
    /// Called on the main thread whenever `progress` changes.
    @ObservationIgnored public var onProgress: ((Double) -> Void)?

    @ObservationIgnored weak var pool: WebViewPool?
    /// What a discarded tab restores from.
    @ObservationIgnored var restoration: TabRestorationState?

    init(id: UUID, openerID: UUID?, pool: WebViewPool, restoring state: TabRestorationState?) {
        self.id = id
        self.openerID = openerID
        self.pool = pool
        restoration = state
        if let state {
            url = state.url
            title = state.title
        }
    }

    // MARK: Commands

    public func load(_ url: URL) {
        pool?.load(url, in: self)
    }

    public func goBack() {
        pool?.webView(for: self)?.goBack()
    }

    public func goForward() {
        pool?.webView(for: self)?.goForward()
    }

    /// Reloads, restoring a discarded tab first.
    public func reload() {
        pool?.reload(self)
    }

    public func stopLoading() {
        pool?.existingWebView(for: self)?.stopLoading()
    }

    /// The page menu's "Request Desktop/Mobile Site". Remembered for the site and applied by
    /// reloading. Nil returns the site to the automatic choice.
    public func setContentModeOverride(_ mode: ContentMode?) {
        pool?.setContentModeOverride(mode, for: self)
    }

    /// The tab's state for session restore after the app quits. Live tabs read it from their web
    /// view; discarded tabs return what they hold.
    public func restorationState() async -> TabRestorationState {
        await pool?.restorationState(for: self)
            ?? TabRestorationState(url: url, title: title, interactionState: nil, sessionStorage: nil)
    }

    // MARK: Updates from the engine (only assign on change, so observers are not invalidated)

    func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<Tab, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    func setProgress(_ value: Double) {
        guard value != progress else { return }
        progress = value
        onProgress?(value)
    }
}
#endif
