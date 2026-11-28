#if canImport(UIKit)
import DesignSystem
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
        // Not under a sheet or an alert either: the toast would be hidden behind it.
        let root = navigationController ?? self
        guard !isShowingGallery, root.presentedViewController == nil,
              tab === currentTab || isShownInOtherPane(tab.id) else { return false }
        // The soft refusal bump, with the toast: the sign-in the user just tried did not happen.
        tabsUI.toast.show(Self.passkeysUnavailableMessage, haptic: .nothingThere)
        return true
    }

    /// True as long as `FixedChoices.passkeysEnabled` is off: with the entitlement, WebKit handles
    /// passkeys for every site and this toast never shows.
    static let passkeysUnavailableMessage = "Passkeys aren't available in Plain yet. Use your password."
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
        // Sheets (Settings, History...) and the previous page's questions close so the new page
        // is what shows. A question closed unanswered gets its safe answer (cancel, deny): its
        // alert is released, and `PromptAnswer` answers with the fallback.
        let root = navigationController ?? self
        if root.presentedViewController != nil { root.dismiss(animated: true) }
        if isShowingGallery { dismissGalleryFading() }
        endAddressEditing()
        let tab = openNewTab()
        tab.load(url)
    }
}
#endif
