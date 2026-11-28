import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Values the web engine decides for the user, each with its reason (AGENTS.md, "Opinionated and
/// simple"). Shared tab values (`extraLiveTabs`, `thumbnailWidth`) are in BrowserCore's
/// `FixedChoices`; these are the engine-only ones, and can move there.
nonisolated public enum EngineChoices {
    // MARK: Tab tiers (docs/plan.md, "Engine rules" 2)

    /// Tabs that keep a web view, visible ones included. Hidden ones are suspended by WebKit and
    /// cost about 3-5 MB each, nearly all of it in WebKit's processes (the app's own side of ten
    /// is ~2 MB, docs/research/perf-pass-3.md); switching back to one is instant. Older tabs are discarded
    /// to `interactionState`. Busy tabs (media, capture, downloads) are kept beyond this.
    public static let maxWebViews = 8

    /// After a tab takes the warm web view, the next one is made this long after the take, in the
    /// run loop's default mode (not inside a scroll or a tracked gesture; an animation may still
    /// run, as for the gallery's spare), so the next New Tab or link opened in a new tab finds one
    /// ready instead of making a web view inside its tap (`WKWebView.init` and its attach were ~6 ms
    /// of the tap before the keyboard on the simulator, docs/research/perf-pass-3.md). One second
    /// clears a New Tab's keyboard rise (0.5 s).
    public static let rewarmDelay: Duration = .seconds(1)
    /// A rewarm that comes while the keyboard is rising or falling tries again this much later:
    /// longer than a frame, well under the keyboard's 0.5 s motion, so it lands soon after it ends.
    public static let rewarmRetry: Duration = .milliseconds(150)
    /// At most this many retries (3 s): a keyboard whose `did` notification never comes doesn't
    /// keep the rewarm waiting for ever.
    public static let rewarmRetries = 20

    // MARK: Saving tabs

    /// A tab is saved this long after its last main-frame load or detach, so a burst of loads
    /// writes one file.
    public static let saveDebounce: Duration = .seconds(1)
    /// The longest the engine waits for a WebContent process to answer (`fetchData`,
    /// `restoreData`, `takeSnapshot`). A frozen process may never answer; past this the engine
    /// goes on without sessionStorage or the thumbnail.
    public static let webKitReplyTimeout: Duration = .milliseconds(400)

    /// The link menu waits this long for the page to say which image was pressed. The menu opens
    /// after the long-press delay anyway; past this it opens without the image items rather than
    /// hold the finger on a busy page.
    public static let pressedElementTimeout: Duration = .milliseconds(120)

    // MARK: Thumbnails (docs/plan.md, "Engine rules" 3)

    /// Thumbnails are stored at this many pixels per point of `FixedChoices.thumbnailWidth`: a
    /// 3x screen's pixels on a card (about 780 px wide, 3.8 times the pixels of the old 400 px
    /// capture, about 44% of a 3x full-screen snapshot). At 2x a card upscaled them and read
    /// blurry.
    public static let thumbnailPixelsPerPoint: CGFloat = 3
    /// JPEG quality on disk: invisible loss at card size, a third of PNG's size and write time.
    public static let thumbnailJPEGQuality: CGFloat = 0.7
    /// The bar swipe's full-screen preview of a neighbour tab, in pixels per point (docs/plan.md,
    /// motion table): sharp enough full width, and a third fewer pixels than a 3x screen. Only the
    /// two neighbours of the tab on screen keep one.
    public static let swipeSnapshotPixelsPerPoint: CGFloat = 2
    /// Decoded thumbnails kept in memory. About 8 cards (5 MB each at card size); the rest
    /// reload from disk on demand. Dropped on a memory warning.
    public static let thumbnailMemoryBytes = 40 * 1024 * 1024

    // MARK: Desktop or mobile site (docs/plan.md, section 4b)

    /// A pane whose shorter side is at least this wide gets desktop sites: the Duo's inner screen
    /// (951×669, 669×951) does, the outer screen, a split half and a phone in landscape do not.
    public static let desktopMinimumSide: CGFloat = 600
    /// The page's answer before a desktop/mobile switch (`ContentModeScripts.probe`) may take this
    /// long. Nothing waits on it (the fold has settled), and a busy page that misses it keeps its
    /// mode, so it is longer than `webKitReplyTimeout`.
    public static let contentModeProbeTimeout: Duration = .seconds(1)

    // MARK: Media (docs/research/media-playback.md)

    /// Whether pages may take element fullscreen (the Fullscreen API, `requestFullscreen` on any
    /// element): as Safari allows it, on iPad and Mac but never on iPhone. Without it a site's
    /// player (YouTube, Vimeo, X) falls back to the video's own fullscreen, which on iOS is the
    /// system's native player with its gestures, picture in picture, AirPlay and rotation. With
    /// it, those sites fullscreen their own web player box instead: the odd fullscreen the owner
    /// saw. Decided by the system's idiom, not the window's size: Safari on the Duo is iPhone
    /// Safari on both screens (measured, docs/research/media-playback.md), and a web page must not
    /// see the API appear or vanish with a fold.
    #if canImport(UIKit)
    public static func allowsElementFullscreen(on idiom: UIUserInterfaceIdiom) -> Bool {
        idiom != .phone
    }
    #endif

    // MARK: Abuse limits (idea from firefox-ios `PopupThrottler`, MPL-2.0; no code taken)

    /// Popups one tab may open within `popupWindow`. Sign-in flows open one; spam opens many.
    public static let popupLimit = 2
    public static let popupWindow: Duration = .seconds(2)
    /// JavaScript dialogs one tab may show within `dialogWindow`; then they are dismissed unseen,
    /// which ends `alert()` loops.
    public static let dialogLimit = 5
    public static let dialogWindow: Duration = .seconds(20)
    /// External-app prompts (custom schemes) one tab may raise within `externalAppWindow`.
    public static let externalAppLimit = 2
    public static let externalAppWindow: Duration = .seconds(10)

    // MARK: Crash recovery (docs/plan.md, "Engine rules" 5)

    /// Automatic reloads after a web content crash within `crashWindow`. One more crash shows the
    /// shell's "page crashed" state instead of looping.
    public static let crashReloadLimit = 2
    public static let crashWindow: Duration = .seconds(30)

    // MARK: Identity

    /// Appended to WebKit's user agent so sites see Safari. Google sign-in rejects embedded browser
    /// user agents (docs/research/notes.md). Safari's version follows the OS version.
    public static var applicationNameForUserAgent: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "Version/\(version.majorVersion).\(version.minorVersion) Mobile/15E148 Safari/604.1"
    }

    /// The whole user agent in desktop mode: Safari on a Mac. WebKit's desktop mode would append
    /// `applicationNameForUserAgent`, and its `Mobile` token makes some sites serve mobile pages.
    public static var desktopUserAgent: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(version.majorVersion).\(version.minorVersion) Safari/605.1.15"
    }

    /// The folder in Documents that downloads go to, visible in the Files app.
    public static let downloadsFolderName = "Downloads"
}
