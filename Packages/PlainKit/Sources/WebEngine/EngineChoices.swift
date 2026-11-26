import CoreGraphics
import Foundation

/// Values the web engine decides for the user, each with its reason (AGENTS.md, "Opinionated and
/// simple"). Shared tab values (`extraLiveTabs`, `thumbnailWidth`) are in BrowserCore's
/// `FixedChoices`; these are the engine-only ones, and can move there.
nonisolated public enum EngineChoices {
    // MARK: Tab tiers (docs/plan.md, "Engine rules" 2)

    /// Tabs that keep a running web view, visible ones included: the visible tab plus
    /// `FixedChoices.extraLiveTabs` recent ones, capped here so the Duo split (two visible) keeps
    /// two recent tabs instead of three.
    public static let maxLiveTabs = 4
    /// Tabs after the live ones that keep their web view but have it suspended
    /// (`inactiveSchedulingPolicy = .suspend`). Older tabs are discarded to `interactionState`.
    public static let maxSuspendedTabs = 4

    // MARK: Thumbnails (docs/plan.md, "Engine rules" 3)

    /// JPEG quality on disk: invisible loss at card size, a third of PNG's size and write time.
    public static let thumbnailJPEGQuality: CGFloat = 0.7
    /// Decoded thumbnails kept in memory. About 8 cards; the rest reload from disk on demand.
    public static let thumbnailMemoryBytes = 24 * 1024 * 1024

    // MARK: Desktop or mobile site (docs/plan.md, section 4b)

    /// A pane whose shorter side is at least this wide gets desktop sites: the Duo's inner screen
    /// (951×669, 669×951) does, the outer screen, a split half and a phone in landscape do not.
    public static let desktopMinimumSide: CGFloat = 600

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
