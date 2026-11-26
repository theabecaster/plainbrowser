#if canImport(UIKit)
import Foundation

/// What the side tabs sidebar needs from the tabs. The shell implements it over `TabStore`; the
/// sidebar never owns tab state (AGENTS.md, one owner per piece of state). After an action the
/// sidebar reads the lists again, so an action updates them before it returns; changes that start
/// elsewhere reach it through `SideTabsViewController.reloadTabs()`.
@MainActor
public protocol SideTabsDataSource: AnyObject {
    /// The window's regular tabs in order, pinned first.
    var regularTabs: [TabGalleryItem] { get }
    /// The window's private tabs in order; the sidebar shows them in their own section.
    var privateTabs: [TabGalleryItem] { get }
    /// The tab in the focused pane, marked as selected.
    var focusedTabID: UUID? { get }
    /// The tab in a split's other pane, marked as on screen.
    var otherPaneTabID: UUID? { get }
    /// A split can show (the Duo's inner screen): rows offer Open in Other Pane.
    var canOpenInOtherPane: Bool { get }

    func selectTab(_ id: UUID)
    func closeTab(_ id: UUID)
    /// Moves a tab to `index` within its own list (regular or private).
    func moveTab(_ id: UUID, to index: Int)
    func newTab(private isPrivate: Bool)
    func openInOtherPane(_ id: UUID)
}
#endif
