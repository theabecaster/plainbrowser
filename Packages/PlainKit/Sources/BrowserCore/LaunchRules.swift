import Foundation

/// What a window showed when the app last left the foreground, kept for the next launch so its
/// first frame can show the same page before the database and the web view are back
/// (docs/decisions.md, "Launch: the last tab first"). Small: it is read on the main thread before
/// the first frame, from memory (user defaults).
public struct LaunchHint: Codable, Equatable, Sendable {
    /// The tab on screen. Launch shows its picture only if the restored session selects it.
    public var tabID: UUID
    /// The window that showed it.
    public var windowID: UUID
    /// The page's picture, a file beside the thumbnails. A new name for each save, so a hint
    /// always names the picture written for it.
    public var picture: String
    public var url: URL
    /// When the app left the foreground.
    public var leftAt: Date
    /// The bar as it rested over the page, so the first frame's buttons are the ones the restored
    /// page gets and nothing in the bar moves when it arrives.
    public var canGoBack: Bool
    public var canGoForward: Bool
    /// Open page tabs besides this one (the rules' `others`).
    public var others: Int
    /// The page was not secure (http, or a certificate the user bypassed).
    public var notSecure: Bool

    public init(
        tabID: UUID, windowID: UUID, picture: String = "", url: URL, leftAt: Date, canGoBack: Bool = false, canGoForward: Bool = false, others: Int = 0,
        notSecure: Bool = false
    ) {
        self.tabID = tabID
        self.windowID = windowID
        self.picture = picture
        self.url = url
        self.leftAt = leftAt
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.others = others
        self.notSecure = notSecure
    }
}

/// What the screen opens to (docs/state-rules.md, "Launch and return").
public enum OpeningScreen: Equatable, Sendable {
    /// Search first, keyboard up: there is no tab to go back to.
    case search
    /// The last tab, exactly as it was: bar resting, no keyboard.
    case lastTab
    /// A fresh search, keyboard up, over the last tab, which shows behind it under frosted paper;
    /// swipe down or tap outside to get back to it.
    case searchOverLastTab
}

/// When Plain opens to the last tab and when to a fresh search over it (docs/research/launch.md).
public enum LaunchRules {
    /// A cold launch. `hint` is what the window showed when the app left; `now` the launch time.
    /// A link from another app is opened by the caller instead and never asks.
    public static func opening(hint: LaunchHint?, now: Date) -> OpeningScreen {
        guard let hint else { return .search }
        return isLongAway(since: hint.leftAt, now: now) ? .searchOverLastTab : .lastTab
    }

    /// A return from the background with the app still running. Short absences change nothing; a
    /// long one opens a fresh search over the page on screen, unless the user is in the middle of
    /// something (the gallery, a sheet, the search field) or the page is busy (media, fullscreen,
    /// a download), as Chrome leaves the tab grid alone.
    public static func onReturn(
        awayFrom leftAt: Date, now: Date, showsPage: Bool, isOccupied: Bool
    ) -> OpeningScreen? {
        guard isLongAway(since: leftAt, now: now), !isOccupied else { return nil }
        return showsPage ? .searchOverLastTab : .search
    }

    /// Away for at least `FixedChoices.freshSearchAfter`. A clock that went backwards counts as
    /// a short absence.
    public static func isLongAway(since leftAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(leftAt) >= FixedChoices.freshSearchAfter
    }
}
