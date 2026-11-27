#if canImport(UIKit)
import BrowserCore
import UIKit
import WebKit

/// The website data store every regular tab shares: the default, persistent one, or in an isolated
/// test run (`TestIsolation`) one non-persistent store for the whole process, so tests never read
/// or change the owner's cookies, logins or site storage. Clearing browsing data clears this
/// store, never `.default()` directly.
public enum AppWebsiteData {
    public static let store: WKWebsiteDataStore = TestIsolation.isActive ? .nonPersistent() : .default()
}

extension UIPasteboard {
    /// Where Copy Link and Copy Image write: the general pasteboard, or in an isolated test run a
    /// private one (`TestIsolation.pasteboardName`), so tests never replace the owner's clipboard.
    public static var plain: UIPasteboard {
        guard TestIsolation.isActive else { return .general }
        return UIPasteboard(name: UIPasteboard.Name(TestIsolation.pasteboardName), create: true) ?? .withUniqueName()
    }
}
#endif
