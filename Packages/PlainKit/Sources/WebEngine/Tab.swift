#if canImport(UIKit)
import BrowserCore
import Foundation
import Observation
import PerfSignposts
import UIKit
import WebKit

/// One page of a tab's back or forward list: a row of the long-press menu on Back or Forward.
public struct HistoryStep: Sendable, Equatable {
    public let title: String
    public let url: URL
    /// Steps from the page on screen: -1 is the page Back opens, 1 the one Forward opens.
    public let offset: Int
    /// The history entry itself (WebKit keeps one object per entry), so a pick never opens
    /// another entry that came to sit at the same offset, even one with the same address.
    let entry: ObjectIdentifier
}

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
    /// What went wrong in the user's terms, for the error page's sentence.
    public let failure: LoadFailure
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
    /// A private tab: its pages use a separate non-persistent website data store shared by every
    /// private tab, and nothing about it is written to disk (state files, thumbnails, per-site
    /// choices).
    public let isPrivate: Bool
    /// The profile whose website data store the tab's pages use (unless private). A link or a
    /// popup it opens is the same profile's.
    public let profileID: ProfileID

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
    /// A restored form result is waiting: history is back but the page is not loaded. The shell
    /// shows "Reload to send the form again"; `reload()` sends it.
    public internal(set) var isAwaitingResubmit = false
    /// The page's zoom (1 is 100%), remembered per site. Change it with `zoomIn()`, `zoomOut()`
    /// and `resetZoom()`.
    public internal(set) var pageZoom = PageZoom.actualSize
    /// The page is a PDF WebKit shows inline. The page menu offers "Save PDF to Files"
    /// (`saveToDownloads()`).
    public internal(set) var isPDF = false
    /// Audio or video is playing in the page or one of its frames.
    public internal(set) var isPlayingMedia = false
    /// A video from this page is in picture in picture.
    public internal(set) var isInPictureInPicture = false
    /// The page, or a video in it, is fullscreen.
    public internal(set) var isFullscreen = false
    /// The page is using the camera or microphone.
    public internal(set) var isCapturingMedia = false
    /// What dark pages does on the page now: nothing (light colors, or not a web page), the
    /// site's own dark design, Plain's darkening, off for this site by the user's choice, or
    /// available (the page could use it, the switch is off).
    public internal(set) var darkPages = DarkPagesState.inactive
    /// The token of the document `darkPages` was reported by, so a delayed action (the
    /// suggestion) can tell it is still the same page. Nil until the page reports.
    public internal(set) var darkPagesDocument: String?
    /// The site has no light design (made only in dark): Light can't apply to it.
    public internal(set) var isLightless = false
    /// The page's language once recognized (`PageTranslation`); nil until then, or when it can't
    /// be told.
    public internal(set) var pageLanguage: Locale.Language?
    /// What Translate Page would translate into: set only when the page is in a language the user
    /// doesn't read and the device can translate it. Nil leaves the page menu item out.
    public internal(set) var translationTarget: Locale.Language?
    /// Whether the page shows its own text, a translation on its way, or a translation.
    public internal(set) var translation = TranslationState.original

    /// Playing, in picture in picture, fullscreen, capturing or downloading. The pool never
    /// discards such a tab, and the shell must not archive or close it automatically.
    public var isBusy: Bool {
        isPlayingMedia || isInPictureInPicture || isFullscreen || isCapturingMedia
            || (pool?.downloads.hasActiveDownload(fromTab: id) ?? false)
    }

    /// The zoom as the page menu shows it, for example 115.
    public var zoomPercent: Int { PageZoom.percent(pageZoom) }
    public var canZoomIn: Bool { PageZoom.zoomedIn(from: pageZoom) != nil }
    public var canZoomOut: Bool { PageZoom.zoomedOut(from: pageZoom) != nil }

    /// Load progress from 0 to 1. Not observed: read it from `onProgress`.
    @ObservationIgnored public internal(set) var progress: Double = 0
    /// Called on the main thread whenever `progress` changes.
    @ObservationIgnored public var onProgress: ((Double) -> Void)?
    /// Called on the main thread when a main-frame load ends on a page not reported before (a new
    /// back-forward item), with its address and title: what history records. A reload, a load
    /// that failed or stopped before committing, and a restored page report nothing.
    @ObservationIgnored public var onVisit: ((URL, String?) -> Void)?
    /// Called when the title of the page `onVisit` reported last arrives or changes.
    @ObservationIgnored public var onVisitTitleChange: ((URL, String) -> Void)?

    @ObservationIgnored weak var pool: WebViewPool?
    /// What a discarded tab restores from.
    @ObservationIgnored var restoration: TabRestorationState?
    /// The current page came from a form submission (POST).
    @ObservationIgnored var isFormResult = false
    /// `restoration` holds only the address: the full state (history, scroll, sessionStorage) is
    /// in the tab's saved file, read off the main thread when the tab first gets a web view.
    @ObservationIgnored var readsSavedState = false
    /// The pair this tab keeps translating with, page after page, until Show Original
    /// (`FixedChoices.translationFollowsTab`).
    @ObservationIgnored var followsTranslation: (source: Locale.Language, target: Locale.Language)?

    init(
        id: UUID, openerID: UUID?, isPrivate: Bool = false, profileID: ProfileID = Profile.defaultID, pool: WebViewPool,
        restoring state: TabRestorationState?
    ) {
        self.id = id
        self.openerID = openerID
        self.isPrivate = isPrivate
        self.profileID = profileID
        self.pool = pool
        restoration = state
        if let state {
            url = state.url
            title = state.title
            isFormResult = state.isFormResult
        }
    }

    // MARK: Commands

    public func load(_ url: URL) {
        pool?.load(url, in: self)
    }

    public func goBack() {
        pool?.perform(in: self) { $0.goBack() }
    }

    public func goForward() {
        pool?.perform(in: self) { $0.goForward() }
    }

    /// The pages Back (or Forward) can reach, nearest first, at most `limit`: what a long press on
    /// the button lists, as in Safari. Empty for a tab without a web view (it has no list yet).
    public func historySteps(forward: Bool, limit: Int = FixedChoices.historyMenuLimit) -> [HistoryStep] {
        guard let list = pool?.existingWebView(for: self)?.backForwardList else { return [] }
        let items = forward ? Array(list.forwardList.prefix(limit)) : Array(list.backList.reversed().prefix(limit))
        return items.enumerated().map { index, item in
            HistoryStep(
                title: item.title ?? "", url: item.url, offset: forward ? index + 1 : -(index + 1),
                entry: ObjectIdentifier(item)
            )
        }
    }

    /// Goes to `step`, a pick from the long-press list. Nothing when the list changed since it
    /// was read (a navigation or `pushState` moved the pages): the row named one page, and a
    /// different one must never open.
    public func go(to step: HistoryStep) {
        pool?.perform(in: self) { webView in
            guard let item = webView.backForwardList.item(at: step.offset), ObjectIdentifier(item) == step.entry,
                  item.url == step.url else { return }
            webView.go(to: item)
        }
    }

    /// Reloads, restoring a discarded tab first.
    public func reload() {
        pool?.reload(self)
    }

    /// Reload Without Cache (docs/decisions.md, "Reload in the pill"): WebKit's reload from the
    /// origin, which asks the server again for the page and everything on it (`no-cache`) instead
    /// of revalidating what it keeps. A discarded tab is restored first.
    public func reloadFromOrigin() {
        pool?.reloadFromOrigin(self)
    }

    public func stopLoading() {
        pool?.existingWebView(for: self)?.stopLoading()
    }

    /// The page menu's "Request Desktop/Mobile Site". Remembered for the site and applied by
    /// reloading. Nil returns the site to the automatic choice.
    public func setContentModeOverride(_ mode: ContentMode?) {
        pool?.setContentModeOverride(mode, for: self)
    }

    /// Asks WebKit whether anything plays and updates `isPlayingMedia`. The flags follow the
    /// page's play and pause events; call this before an automatic rule (archive, close) acts, so
    /// players the page never put in its document count too.
    public func refreshMediaState() async {
        await pool?.slot(for: self)?.refreshMediaPlayback()
    }

    /// The default page appearance and each site's own, as this tab's kind of tab sees them (a
    /// private tab: the session's own choices over the regular ones).
    public var pageAppearanceChoices: PageAppearanceChoices {
        pool?.pageAppearanceChoices(isPrivate: isPrivate) ?? PageAppearanceChoices()
    }

    /// The site the per-site choices are remembered under (the host without `www.`), nil for a
    /// page that is not on a site.
    public var siteKey: String? { NavigationRules.siteKey(for: url) }

    /// Sets this site's own page appearance (nil: follow the default). Applied to the pages on
    /// screen at once without a reload; returns once they drew it, for the shell's crossfade.
    @discardableResult
    public func setPageAppearance(_ appearance: PageAppearance?, source: String = "menu") async -> Bool {
        await pool?.setPageAppearance(appearance, for: self, source: source) ?? false
    }

    /// The page menu's "Translate Page": into `translationTarget`, on the device. The system may
    /// first ask to download the languages. Later pages of this tab in the same language are
    /// translated too, until `showOriginal()`.
    public func translate() {
        pool?.translate(self)
    }

    /// The page menu's "Show Original": the page's own text back at once, without a reload.
    public func showOriginal() {
        pool?.showOriginal(self)
    }

    /// One step larger (`FixedChoices.pageZoomSteps`), remembered for the site.
    public func zoomIn() {
        if let zoom = PageZoom.zoomedIn(from: pageZoom) { pool?.setPageZoom(zoom, for: self) }
    }

    /// One step smaller, remembered for the site.
    public func zoomOut() {
        if let zoom = PageZoom.zoomedOut(from: pageZoom) { pool?.setPageZoom(zoom, for: self) }
    }

    /// Back to 100%; the site forgets its zoom.
    public func resetZoom() {
        pool?.setPageZoom(PageZoom.actualSize, for: self)
    }

    /// The page menu's "Find on Page": the system find bar (`UIFindInteraction`) over this tab's
    /// page. It sits above the keyboard; matches scroll into view clear of the insets the shell set
    /// with `WebViewPool.setInsets`. Does nothing for a tab without a page on screen.
    public func beginFind() {
        pool?.beginFind(in: self)
    }

    /// "Save PDF to Files": downloads the page's own file into the downloads folder through the
    /// normal download path, so the shell hears `downloadDidStart` and `downloadDidEnd` and can
    /// share or preview the finished file. Meant for PDF tabs (`isPDF`); works for any page URL.
    public func saveToDownloads() {
        guard let url else { return }
        Signposts.signposter.emitEvent(Signposts.savePage)
        pool?.startDownload(url, from: self)
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

    func resetMediaState() {
        set(\.isPlayingMedia, false)
        set(\.isInPictureInPicture, false)
        set(\.isFullscreen, false)
        set(\.isCapturingMedia, false)
    }

    func setProgress(_ value: Double) {
        guard value != progress else { return }
        progress = value
        onProgress?(value)
    }
}
#endif
