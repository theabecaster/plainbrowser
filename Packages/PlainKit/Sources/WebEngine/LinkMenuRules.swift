import Foundation

/// One item of the link context menu (docs/ui-reference.md, "Context menus on links").
nonisolated public enum LinkMenuItem: String, Sendable, Equatable, CaseIterable {
    case openInNewTab, openInBackground, openInOtherPane, openInNewWindow
    case copyLink, share
    case downloadLinkedFile
    case saveImage, copyImage

    public var title: String {
        switch self {
        case .openInNewTab: "Open in New Tab"
        case .openInBackground: "Open in Background"
        case .openInOtherPane: "Open in Other Pane"
        case .openInNewWindow: "Open in New Window"
        case .copyLink: "Copy Link"
        case .share: "Share"
        case .downloadLinkedFile: "Download Linked File"
        case .saveImage: "Save Image"
        case .copyImage: "Copy Image"
        }
    }

    public var symbolName: String {
        switch self {
        case .openInNewTab: "plus.square.on.square"
        case .openInBackground: "square.on.square.dashed"
        case .openInOtherPane: "rectangle.split.2x1"
        case .openInNewWindow: "macwindow.badge.plus"
        case .copyLink: "link"
        case .share: "square.and.arrow.up"
        case .downloadLinkedFile: "arrow.down.circle"
        case .saveImage: "square.and.arrow.down"
        case .copyImage: "doc.on.doc"
        }
    }
}

/// What a long press landed on.
nonisolated public struct LinkElement: Sendable, Equatable {
    public var linkURL: URL?
    public var imageURL: URL?

    public init(linkURL: URL?, imageURL: URL?) {
        self.linkURL = linkURL
        self.imageURL = imageURL
    }
}

/// Which items the link menu shows, in sections. Pure, so it tests without a web view.
nonisolated enum LinkMenuRules {
    /// - Parameters:
    ///   - canOpenInOtherPane: the shell has a second pane on screen.
    ///   - canOpenInNewWindow: the system takes another window here (the Duo's inner screen).
    ///   - canSaveImages: the app may add to Photos (it declares `NSPhotoLibraryAddUsageDescription`).
    static func sections(
        for element: LinkElement, canOpenInOtherPane: Bool, canOpenInNewWindow: Bool = false, canSaveImages: Bool
    ) -> [[LinkMenuItem]] {
        var sections: [[LinkMenuItem]] = []
        if let link = element.linkURL {
            let isWeb = NavigationRules.schemeKind(of: link) == .web
            if isWeb {
                sections.append(
                    [.openInNewTab, .openInBackground] + (canOpenInOtherPane ? [.openInOtherPane] : [])
                        + (canOpenInNewWindow ? [.openInNewWindow] : [])
                )
            }
            sections.append([.copyLink, .share])
            if isWeb { sections.append([.downloadLinkedFile]) }
        }
        if element.imageURL != nil {
            sections.append((canSaveImages ? [.saveImage] : []) + [.copyImage])
        }
        return sections
    }

    /// Only web links get a live preview; `mailto:` and app links have nothing to show.
    static func hasPreview(_ element: LinkElement) -> Bool {
        element.linkURL.map { NavigationRules.schemeKind(of: $0) == .web } ?? false
    }

    /// The live preview's size, so the whole menu fits beside or under it on every screen. Left to
    /// itself UIKit made the preview nearly full height, and the menu's last item ("Download
    /// Linked File") ran off the bottom edge of an iPhone. Safari keeps its preview smaller.
    ///
    /// - Parameters:
    ///   - window: the window's size; `safeTop` and `safeBottom` its safe-area insets.
    ///   - rows: the menu's items; `sections` its groups (a gap between each).
    ///   - rowHeight: one item's height at the current text size.
    ///   - menuBeside: the menu sits beside the preview (compact height), not under it.
    /// - Returns: nil when the menu leaves no room for a useful preview: show the menu alone.
    static func previewSize(
        window: CGSize, safeTop: CGFloat, safeBottom: CGFloat, rows: Int, sections: Int, rowHeight: CGFloat,
        menuBeside: Bool
    ) -> CGSize? {
        let margin = previewMargin
        let usableHeight = window.height - safeTop - safeBottom - 2 * margin
        if menuBeside {
            // The menu takes its own column; the preview gets the height and about half the width.
            guard usableHeight >= previewMinimumHeight else { return nil }
            return CGSize(width: (window.width / 2).rounded(), height: usableHeight.rounded())
        }
        let width = window.width - 2 * margin
        let menu = CGFloat(rows) * rowHeight + CGFloat(max(0, sections - 1)) * previewSectionGap + 2 * margin
        let room = usableHeight - menu - margin
        // Never taller than a page-shaped card; none at all when it would be a sliver (the
        // largest text sizes, a long image menu): the menu needs the room more.
        guard room >= previewMinimumHeight else { return nil }
        let height = min(room, width * previewMaximumAspect).rounded()
        return CGSize(width: width.rounded(), height: height)
    }

    /// Around the preview and the menu, and between them.
    static let previewMargin: CGFloat = 16
    /// UIKit's gap between two sections of a context menu, with room to spare.
    static let previewSectionGap: CGFloat = 12
    /// A menu item's height at the default text size, with room to spare (UIKit's is about 44).
    static let menuRowHeight: CGFloat = 48
    static let previewMinimumHeight: CGFloat = 120
    /// Height over width: about a page's shape.
    static let previewMaximumAspect: CGFloat = 1.3

    /// An image address the engine can fetch: http, https or data.
    static func fetchableImageURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return nil }
        return ["http", "https", "data"].contains(scheme) ? url : nil
    }
}
