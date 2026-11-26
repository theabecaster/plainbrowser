import Foundation

/// How tabs are shown. Side tabs apply only where the window is regular in both size classes;
/// elsewhere the app shows regular tabs and keeps this choice for when the window grows.
public enum TabLayout: String, Hashable, Sendable, Codable, CaseIterable {
    case regular
    case sideTabs
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
