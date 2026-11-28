#if canImport(UIKit)
import Foundation
import WebEngine

/// What the side tabs sidebar and the strip need from the tabs. The shell implements it over
/// `TabStore`; neither owns tab state (AGENTS.md, one owner per piece of state). After an action
/// they read the list again, so an action updates it before it returns; changes that start
/// elsewhere reach them through `reloadTabs()`.
///
/// Private is a mode, as on the phone (docs/decisions.md, "Private as a clear mode on wide
/// screens"): the window shows one list at a time, the one of the tab on screen, never the two
/// mixed. The Private | Tabs switch at the list's head moves between them.
@MainActor
public protocol SideTabsDataSource: AnyObject {
    /// The window is in private mode: the tab on screen (or, on an empty pane, the split's other
    /// one) is private. The list, New Tab and the look follow it.
    var showsPrivate: Bool { get }
    /// The shown mode's tabs in order (regular: pinned first; private: the private list).
    var tabs: [TabGalleryItem] { get }
    /// Page tabs in each list, for the switch's counts.
    var regularCount: Int { get }
    var privateCount: Int { get }
    /// The tab in the focused pane, marked as selected.
    var focusedTabID: UUID? { get }
    /// The tab in a split's other pane, marked as on screen.
    var otherPaneTabID: UUID? { get }
    /// A split can show (the Duo's inner screen): rows offer Open in Other Pane.
    var canOpenInOtherPane: Bool { get }

    /// The tab's site icon at `pixelSize` square if it is decoded in memory now: assigned at once,
    /// so a row never shows its letter first.
    func cachedIcon(for item: TabGalleryItem, pixelSize: Int) -> SiteIcon?
    /// The tab's site icon, read and decoded off the main thread; nil when the site has none.
    func icon(for item: TabGalleryItem, pixelSize: Int) async -> SiteIcon?

    func selectTab(_ id: UUID)
    func closeTab(_ id: UUID)
    /// Moves a tab to `index` within the shown list.
    func moveTab(_ id: UUID, to index: Int)
    func newTab(private isPrivate: Bool)
    func openInOtherPane(_ id: UUID)
    /// The switch: into private (`true`) or out of it. The list's tab seen last comes on screen,
    /// else a new empty tab of that kind; the tabs of the list left stay open.
    func showMode(private isPrivate: Bool)
    /// Close All Private Tabs (the Private side's menu): every private tab goes, none come back.
    func closeAllPrivateTabs()
}
#endif
