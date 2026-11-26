#if canImport(UIKit)
import Foundation
import PerfSignposts
import UIKit
import WebEngine

/// Sign-in (docs/research/sign-in.md). Passwords need nothing from the shell: iOS AutoFill offers
/// them in the keyboard's suggestion bar on its own. Passkeys wait for Apple's web-browser
/// entitlement; until then a site that asks for one anyway gets one toast that says why.
extension BrowserViewController {
    /// The engine calls this at most once per site per launch. Only a page on screen says it: a
    /// background tab's failed request is not something the user just tried.
    public func tab(_ tab: Tab, couldNotUsePasskeysOn site: String) {
        guard !isShowingGallery, tab === currentTab || isShownInOtherPane(tab.id) else { return }
        tabsUI.toast.show(Self.passkeysUnavailableMessage)
    }

    /// True as long as `FixedChoices.passkeysEnabled` is off: with the entitlement, WebKit handles
    /// passkeys for every site and this toast never shows.
    static let passkeysUnavailableMessage = "Passkeys will work once Apple approves Plain"
}

// MARK: - Links from other apps

extension BrowserViewController {
    /// A web link another app opened in Plain (as the default browser, docs/research/sign-in.md):
    /// it opens in a new tab, on screen, over whatever was up. Before the saved tabs are in, the
    /// tab joins them and stays on screen (`EngineTabs.restoreSession`). Anything but http and
    /// https is ignored.
    public func open(externalURL url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        Signposts.signposter.emitEvent(Signposts.linkFromOtherApp)
        if isShowingGallery { dismissGalleryFading() }
        endAddressEditing()
        let tab = openNewTab()
        tab.load(url)
    }
}
#endif
