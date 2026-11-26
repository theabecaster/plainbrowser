import Foundation

/// Where the tab list sits on a wide screen: a strip above the pages, or a sidebar on their left
/// or right. It applies only where the window is regular in both size classes and wide enough;
/// elsewhere (the Duo's outer screen, iPhones) the app switcher is the only tab list, and the
/// choice is kept for when the window grows. The app switcher (a swipe up from the address bar)
/// stays in every layout.
public enum TabLayout: String, Hashable, Sendable, Codable, CaseIterable {
    case above
    case left
    case right

    /// The layout stored under `raw`, including the values before M3's Above/Left/Right
    /// ("sideTabs" was the left sidebar; "regular" had no tab list and takes the default).
    public init?(stored raw: String) {
        switch raw {
        case "sideTabs": self = .left
        case "regular": self = FixedChoices.defaultTabLayout
        default: self.init(rawValue: raw)
        }
    }

    /// A sidebar layout (left or right).
    public var isSidebar: Bool { self != .above }
}

/// When an unused tab moves to the archive.
public enum ArchiveAfter: String, Hashable, Sendable, Codable, CaseIterable {
    case twelveHours
    case oneDay
    case oneWeek
    case never

    /// How long a tab may go unopened before it is archived. Nil means never.
    public var interval: TimeInterval? {
        switch self {
        case .twelveHours: 12 * 3600
        case .oneDay: 24 * 3600
        case .oneWeek: 7 * 24 * 3600
        case .never: nil
        }
    }

    /// Whether a tab last opened at `lastActive` is due for the archive at `now`.
    public func isDue(lastActive: Date, now: Date) -> Bool {
        guard let interval else { return false }
        return now.timeIntervalSince(lastActive) >= interval
    }
}

/// Every user setting Plain has (docs/plan.md, section 4b). "Clear History and Data" is an action,
/// not a stored value, so it is not here. Nothing else belongs in this type.
public struct BrowserSettings: Hashable, Sendable, Codable {
    public var searchEngine: SearchEngine
    public var tabLayout: TabLayout
    public var archiveAfter: ArchiveAfter

    public init(searchEngine: SearchEngine, tabLayout: TabLayout, archiveAfter: ArchiveAfter) {
        self.searchEngine = searchEngine
        self.tabLayout = tabLayout
        self.archiveAfter = archiveAfter
    }

    /// First-launch values.
    public static let defaults = BrowserSettings(
        searchEngine: FixedChoices.defaultSearchEngine,
        tabLayout: FixedChoices.defaultTabLayout,
        archiveAfter: FixedChoices.defaultArchiveAfter
    )
}
