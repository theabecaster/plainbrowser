#if canImport(UIKit)
import Foundation
import PerfSignposts
import UIKit
import WebEngine

/// Sign-in (docs/research/sign-in.md). Passwords need nothing from the shell: iOS AutoFill offers
/// them in the keyboard's suggestion bar, on web fields once Apple grants the web-browser
/// entitlement. Passkeys wait for it too; until then a site that asks for one anyway gets one
/// toast that says why.
extension BrowserViewController {
    /// Only a page on screen says it: a background tab's request is not something the user just
    /// tried. The engine asks again on the site's next request until this returns true.
    public func tab(_ tab: Tab, couldNotUsePasskeysOn site: String) -> Bool {
        guard !isShowingGallery, tab === currentTab || isShownInOtherPane(tab.id) else { return false }
        tabsUI.toast.show(Self.passkeysUnavailableMessage)
        return true
    }

    /// True as long as `FixedChoices.passkeysEnabled` is off: with the entitlement, WebKit handles
    /// passkeys for every site and this toast never shows.
    static let passkeysUnavailableMessage = "Passkeys will work once Apple approves Plain"
}

// MARK: - Links from other apps

extension BrowserViewController {
    /// A web link another app opened in Plain (as the default browser, docs/research/sign-in.md):
    /// it opens in a new tab, on screen, in place of a sheet or the gallery. Before the saved tabs are in, the
    /// tab joins them and stays on screen (`EngineTabs.restoreSession`). Anything but http and
    /// https is ignored.
    public func open(externalURL url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        Signposts.signposter.emitEvent(Signposts.linkFromOtherApp)
        // Sheets (Settings, History...) close so the page is what shows. An alert stays: it is a
        // page's question waiting for its answer.
        let root = navigationController ?? self
        if let presented = root.presentedViewController, !(presented is UIAlertController) {
            root.dismiss(animated: true)
        }
        if isShowingGallery { dismissGalleryFading() }
        endAddressEditing()
        let tab = openNewTab()
        tab.load(url)
    }
}
#endif
