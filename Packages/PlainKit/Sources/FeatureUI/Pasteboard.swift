#if os(iOS)
import BrowserCore
import UIKit

extension UIPasteboard {
    /// Where Copy Link writes: the general pasteboard, or in an isolated test run a private one, so
    /// tests never replace the owner's clipboard. The same rule as WebEngine's `UIPasteboard.plain`
    /// (FeatureUI can't import WebEngine).
    static var plain: UIPasteboard {
        guard TestIsolation.isActive else { return .general }
        return UIPasteboard(name: UIPasteboard.Name(TestIsolation.pasteboardName), create: true) ?? .withUniqueName()
    }
}
#endif
