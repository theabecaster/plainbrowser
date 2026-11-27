#if canImport(UIKit)
import BrowserCore
import Foundation
import PerfSignposts
import PlainShared
import UIKit
import WebEngine

// MARK: - Commands from the system

extension BrowserViewController {
    /// Does what Shortcuts, Siri, a widget, a control or a Spotlight result asked
    /// (docs/research/system-integration.md). Whatever was on screen (a sheet, the gallery) gives
    /// way first, as for a link from another app. Each command ends on the screen a tap in Plain
    /// would reach: a new tab with the search field, a page, or the tab switcher.
    public func perform(_ command: PlainCommand) {
        Signposts.signposter.emitEvent(Signposts.systemCommand, "\(command.signpostName, privacy: .public)")
        // A later command supersedes a Show Tabs still waiting for the saved tabs: the gallery
        // must not pop up over what the user asked for next.
        if command != .showTabs { showTabsAwaitingSession = false }
        if case .open(let url) = command { return open(externalURL: url) }
        let root = navigationController ?? self
        // Not animated: the app is coming forward, and the gallery checks for a sheet at once.
        if root.presentedViewController != nil { root.dismiss(animated: false) }
        switch command {
        case .focusSearch, .newTab:
            openNewTab(private: false)
        case .newPrivateTab:
            openNewTab(private: true)
        case .search(let query):
            if isShowingGallery { dismissGalleryFading() }
            guard let url = data.searchEngine.resultsURL(for: query) else { return }
            // An empty regular tab on screen takes the results; otherwise a new tab does.
            let reusable = currentTab.map { !$0.isPrivate && session.tabs.isEmpty($0.id) } ?? false
            if !reusable { _ = openNewTab() }
            load(url, kind: .typed)
        case .showTabs:
            // On a cold launch the saved tabs come in after the first frame; the switcher waits.
            guard session.tabs.isSessionLoaded else {
                showTabsAwaitingSession = true
                return
            }
            guard !isShowingGallery else { return }
            endAddressEditing()
            // With nothing to switch to, the gallery has no cards and stays shut: the search
            // field, where Plain starts, is what shows.
            if presentGallery(source: "system") == nil { beginAddressEditing() }
        case .open:
            break
        }
    }

    /// The saved tabs are in: a Show Tabs that waited for them runs now.
    func sessionDidLoadForCommands() {
        guard showTabsAwaitingSession else { return }
        showTabsAwaitingSession = false
        perform(.showTabs)
    }
}

extension PlainCommand {
    var signpostName: String {
        switch self {
        case .focusSearch: "focusSearch"
        case .search: "search"
        case .open: "open"
        case .newTab: "newTab"
        case .newPrivateTab: "newPrivateTab"
        case .showTabs: "showTabs"
        }
    }
}

// MARK: - Handoff

extension BrowserViewController {
    /// Offers the page on screen to the user's other devices: Safari on a Mac, or the default
    /// browser on an iPad, picks it up from the Dock or the app switcher. A private tab offers
    /// nothing (`FixedChoices.handoffInPrivateTabs`), nor does the start screen, a failed load or
    /// the reader's own page. The activity is never eligible for search or Siri suggestions, so
    /// iOS keeps no record of it. An isolated test run (`TestIsolation`) offers nothing: its pages
    /// would show up on the owner's Mac and iPad.
    func updateHandoff(page: URL?, title: String, isPrivate: Bool) {
        let shared: URL? = {
            guard !TestIsolation.isActive, !isPrivate || FixedChoices.handoffInPrivateTabs, let page,
                  let scheme = page.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return page
        }()
        guard let shared else {
            userActivity?.invalidate()
            userActivity = nil
            return
        }
        if let activity = userActivity, activity.webpageURL == shared, activity.title == title { return }
        let activity = userActivity ?? Self.makeHandoffActivity()
        activity.webpageURL = shared
        activity.title = title.isEmpty ? nil : title
        userActivity = activity
        activity.becomeCurrent()
    }

    private static func makeHandoffActivity() -> NSUserActivity {
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPrediction = false
        activity.isEligibleForPublicIndexing = false
        return activity
    }
}
#endif
