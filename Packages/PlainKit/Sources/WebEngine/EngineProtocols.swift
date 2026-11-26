#if canImport(UIKit)
import Foundation
import WebKit

// The seams the engine needs from the layers around it. Storage implements the stores; the shell
// implements the presenters. Every requirement is small so a test fake is a few lines.

// MARK: - Storage seams (the lead wires real implementations)

/// What a discarded or closed-app tab needs to come back with its history, scroll position and
/// sessionStorage. The pool writes it, encoded with `encoded()`, to Storage's `TabStateStore` when
/// it discards a tab; after a relaunch, decode the file with `init(encoded:)` and pass it to
/// `WebViewPool.makeTab(id:restoring:)`.
nonisolated public struct TabRestorationState: Sendable, Codable, Equatable {
    public var url: URL?
    public var title: String
    /// `WKWebView.interactionState`: back/forward list and scroll position, opaque to us.
    public var interactionState: Data?
    /// `WKWebView.fetchData(of: .sessionStorage)`, opaque to us.
    public var sessionStorage: Data?

    public init(url: URL?, title: String, interactionState: Data?, sessionStorage: Data?) {
        self.url = url
        self.title = title
        self.interactionState = interactionState
        self.sessionStorage = sessionStorage
    }

    /// A binary property list. Encode and decode off the main thread.
    public func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    public init(encoded data: Data) throws {
        self = try PropertyListDecoder().decode(TabRestorationState.self, from: data)
    }
}

/// Site permissions the web can ask for.
nonisolated public enum SitePermission: String, Sendable, Codable, CaseIterable {
    case camera, microphone, location, motion
}

/// Remembers the answer to each permission prompt per site (an origin such as
/// `https://example.com`), so a site asks once. Per-site choices are remembered automatically,
/// never configured (AGENTS.md).
nonisolated public protocol SitePermissionStore: Sendable {
    /// The stored answer, or nil when the user was never asked.
    func isAllowed(_ permission: SitePermission, forSite site: String) async -> Bool?
    func setAllowed(_ allowed: Bool, _ permission: SitePermission, forSite site: String) async
}

/// The desktop or mobile choice the page menu made for a site, remembered automatically.
///
/// Read on every main-frame navigation start, so `contentMode(forSite:)` must answer from memory:
/// load the stored map at launch and write changes behind it.
public protocol SiteContentModeStore: AnyObject {
    func contentMode(forSite site: String) -> ContentMode?
    func setContentMode(_ mode: ContentMode?, forSite site: String)
}

/// Rules applied to each web view's own `WKUserContentController`: content blocking.
/// `ContentBlocker` (ContentBlocking) has exactly these methods, so the shell conforms it with an
/// empty extension.
///
/// Every web view gets its own controller, so detaching rules for one site never touches another
/// tab. The pool calls `apply` once when it creates a web view and again at the start of every
/// main-frame navigation, before allowing it; it calls `release` when the web view goes away.
public protocol UserContentRules: AnyObject {
    func apply(to controller: WKUserContentController, forMainFrameURL mainFrameURL: URL?)
    func release(_ controller: WKUserContentController)
}

// MARK: - Shell seams

/// Child tabs, close requests and crashes. The shell owns the tab list (`TabStore`), so it decides
/// where a child tab goes.
public protocol TabPresenter: AnyObject {
    /// A page opened a popup, `window.open` or a `target=_blank` link. The shell must keep `child`
    /// (it is the only owner) and normally shows it at once; sign-in popups talk to `opener` through
    /// `window.opener`.
    func pool(_ pool: WebViewPool, didOpen child: Tab, from opener: Tab)
    /// A script called `window.close()` on a tab it opened. The shell closes it and shows the opener.
    func pool(_ pool: WebViewPool, tabRequestsClose tab: Tab)
    /// The visible tab's page crashed again right after automatic reloads. The shell shows a
    /// "This page crashed" state with a reload button (`tab.reload()`).
    func pool(_ pool: WebViewPool, tabKeepsCrashing tab: Tab)
}

/// `alert`, `confirm` and `prompt`. Only the visible tab's dialogs reach the shell; background tabs
/// get the dismissed answer, and a tab that shows too many in a row is silenced.
public protocol JavaScriptDialogPresenter: AnyObject {
    func tab(_ tab: Tab, alert message: String, from site: String) async
    func tab(_ tab: Tab, confirm message: String, from site: String) async -> Bool
    func tab(_ tab: Tab, prompt message: String, defaultText: String?, from site: String) async -> String?
}

/// An HTTP authentication request (Basic, Digest, NTLM).
public struct AuthenticationRequest: Sendable {
    public let host: String
    public let port: Int
    public let realm: String?
    /// True when the server will receive the password unencrypted (Basic over http).
    public let isPasswordSentInClear: Bool
    /// How many answers the server already rejected; show "wrong password" when above 0.
    public let previousFailureCount: Int
    public let proposedUser: String?
}

/// A main-frame load that failed because the server's certificate is not trusted.
public struct CertificateError: @unchecked Sendable {
    public let url: URL
    public let host: String
    /// The `NSURLError` code: untrusted, expired, not yet valid, unknown root or bad host.
    public let code: URLError.Code
    /// The server's trust, for showing certificate details.
    public let trust: SecTrust?
}

/// HTTP authentication and the certificate-error interstitial.
public protocol AuthenticationPresenter: AnyObject {
    /// Ask for a user name and password. Nil cancels, and the server's 401 page shows.
    func tab(_ tab: Tab, credentialFor request: AuthenticationRequest) async -> URLCredential?
    /// Show the certificate-error interstitial. True means the user chose to visit anyway: the
    /// pool trusts that certificate for this host until the app quits, then reloads.
    func tab(_ tab: Tab, shouldProceedPast error: CertificateError) async -> Bool
}

/// Links that leave the browser.
public protocol ExternalAppPresenter: AnyObject {
    /// A page wants to open a custom-scheme URL (`mailto:`, `tel:`, another app's scheme). The
    /// shell confirms with the user and opens it; return whether it was opened.
    func tab(_ tab: Tab, openExternally url: URL) async -> Bool
    /// The user tapped a link to another site. If an installed app claims it as a universal link,
    /// open it there (`UIApplication.open(_:options: [.universalLinksOnly: true])`) and return
    /// true; the navigation is then cancelled. Called only for user taps across sites, never for
    /// redirects or scripts.
    func tab(_ tab: Tab, openUniversalLink url: URL) async -> Bool
}

/// Camera, microphone, location and motion prompts. Answers are remembered per site through
/// `SitePermissionStore`, so this is called once per site and permission.
public protocol PermissionPresenter: AnyObject {
    func tab(_ tab: Tab, allow permissions: [SitePermission], forSite site: String) async -> Bool
}

/// Download progress for the shell's downloads list.
public protocol DownloadPresenter: AnyObject {
    func downloadDidStart(_ download: Download)
    /// `download.state` is `.finished` or `.failed`.
    func downloadDidEnd(_ download: Download)
}

/// Everything the shell implements for the engine.
public typealias EngineHost = TabPresenter & JavaScriptDialogPresenter & AuthenticationPresenter
    & ExternalAppPresenter & PermissionPresenter & DownloadPresenter
#endif
