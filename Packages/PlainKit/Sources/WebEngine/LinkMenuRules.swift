import Foundation

/// One item of the link context menu (docs/ui-reference.md, "Context menus on links").
nonisolated public enum LinkMenuItem: String, Sendable, Equatable, CaseIterable {
    case openInNewTab, openInBackground, openInOtherPane
    case copyLink, share
    case downloadLinkedFile
    case saveImage, copyImage

    public var title: String {
        switch self {
        case .openInNewTab: "Open in New Tab"
        case .openInBackground: "Open in Background"
        case .openInOtherPane: "Open in Other Pane"
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
    ///   - canSaveImages: the app may add to Photos (it declares `NSPhotoLibraryAddUsageDescription`).
    static func sections(
        for element: LinkElement, canOpenInOtherPane: Bool, canSaveImages: Bool
    ) -> [[LinkMenuItem]] {
        var sections: [[LinkMenuItem]] = []
        if let link = element.linkURL {
            let isWeb = NavigationRules.schemeKind(of: link) == .web
            if isWeb {
                sections.append([.openInNewTab, .openInBackground] + (canOpenInOtherPane ? [.openInOtherPane] : []))
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

    /// An image address the engine can fetch: http, https or data.
    static func fetchableImageURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return nil }
        return ["http", "https", "data"].contains(scheme) ? url : nil
    }
}
