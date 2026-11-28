#if canImport(UIKit)
import BrowserCore
import Foundation
import Photos
import PerfSignposts
import UIKit
import UniformTypeIdentifiers
import WebKit

/// The link context menu: what a long press on a link or an image offers, with a live preview of
/// the link. Built by `WebViewPool.linkMenu(for:in:)`, turned into UIKit by `configuration`.
struct LinkMenu {
    let element: LinkElement
    let sections: [[LinkMenuItem]]

    var items: [LinkMenuItem] { sections.flatMap(\.self) }
    var hasPreview: Bool { LinkMenuRules.hasPreview(element) }

    /// The menu, one inline group per section. `perform` runs the chosen item.
    func menu(perform: @escaping (LinkMenuItem) -> Void) -> UIMenu {
        UIMenu(children: sections.map { section in
            UIMenu(options: .displayInline, children: section.map { item in
                let action = UIAction(title: item.title, image: UIImage(systemName: item.symbolName)) { _ in
                    perform(item)
                }
                action.accessibilityIdentifier = "linkMenu.\(item.rawValue)"
                return action
            })
        })
    }
}

private struct PressedImageReply: Sendable {
    let src: String?
    let href: String?
    let time: Double
}

/// A live preview of a link: a web view from the pool loading it. Released with the controller.
final class LinkPreviewController: UIViewController {
    private let webView: WKWebView
    private let onRelease: (WKWebView) -> Void

    init(webView: WKWebView, onRelease: @escaping (WKWebView) -> Void) {
        self.webView = webView
        self.onRelease = onRelease
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = webView
    }

    isolated deinit {
        onRelease(webView)
    }
}

extension WebViewPool {
    // MARK: - Building the menu

    /// The menu for a long press in `tab`. `linkURL` is what WebKit reports; the pressed image, if
    /// any, comes from the page (one round trip, capped at `EngineChoices.pressedElementTimeout`).
    /// Nil when there is nothing to offer.
    func linkMenu(for linkURL: URL?, in tab: Tab) async -> LinkMenu? {
        guard let webView = existingWebView(for: tab) else { return nil }
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.linkMenu, id: signposter.makeSignpostID())
        defer { signposter.endInterval(Signposts.linkMenu, interval) }
        var element = LinkElement(linkURL: linkURL, imageURL: nil)
        if let pressed = await pressedImage(in: webView) {
            // The last finger down may have been somewhere else; keep the image only when it is
            // the link's own image, or, with no link reported, an image outside any link, and
            // only when no iframe was pressed since (that press would be the menu's).
            let pressedInFrameSince = (slot(for: tab)?.lastSubframePress ?? 0) >= pressed.time
            if pressed.link == linkURL, !pressedInFrameSince {
                element.imageURL = pressed.image
            }
        }
        let sections = LinkMenuRules.sections(
            for: element, canOpenInOtherPane: host?.canOpenInOtherPane(from: tab) ?? false,
            canOpenInNewWindow: host?.canOpenInNewWindow(from: tab) ?? false,
            canSaveImages: Self.canSaveToPhotos
        )
        return sections.isEmpty ? nil : LinkMenu(element: element, sections: sections)
    }

    /// The UIKit configuration WebKit shows: the menu, and a live preview for web links.
    func contextMenuConfiguration(for linkURL: URL?, in tab: Tab) async -> UIContextMenuConfiguration? {
        guard let menu = await linkMenu(for: linkURL, in: tab) else { return nil }
        let preview: UIContextMenuContentPreviewProvider?
        // No preview where the menu alone fills the screen (the largest text, a short window):
        // the whole menu matters more than a glimpse of the page.
        if menu.hasPreview, let url = menu.element.linkURL, let size = linkPreviewSize(for: menu, in: tab) {
            preview = { [weak self, weak tab] in
                guard let self, let tab else { return nil }
                let controller = self.makeLinkPreview(url, isPrivate: tab.isPrivate, profile: tab.profileID)
                controller.preferredContentSize = size
                return controller
            }
        } else {
            preview = nil
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: preview) { [weak self, weak tab] _ in
            menu.menu { item in
                guard let self, let tab else { return }
                self.perform(item, on: menu.element, in: tab)
            }
        }
    }

    /// The pressed image, its enclosing link and the press time (ms since 1970, the page's clock).
    private func pressedImage(in webView: WKWebView) async -> (image: URL, link: URL?, time: Double)? {
        let reply: PressedImageReply? = await withWebKitTimeout(
            fallback: nil, timeout: EngineChoices.pressedElementTimeout
        ) { done in
            webView.callAsyncJavaScript(
                UserScripts.pressedImageQuery, arguments: [:], in: nil, in: UserScripts.world
            ) { result in
                let info = (try? result.get()) as? [String: Any]
                done(info.map {
                    PressedImageReply(src: $0["src"] as? String, href: $0["href"] as? String, time: $0["at"] as? Double ?? 0)
                })
            }
        }
        guard let reply, let image = LinkMenuRules.fetchableImageURL(reply.src) else { return nil }
        return (image, reply.href.flatMap(URL.init(string:)), reply.time)
    }

    /// Photos crashes an app that saves without this key, so Save Image hides until it is there.
    static var canSaveToPhotos: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") != nil
    }

    // MARK: - Preview

    /// A preview web view: the shared configuration with its own controller and the content
    /// rules, but no delegates, so it can't open windows, show dialogs or download.
    func makeLinkPreview(_ url: URL, isPrivate: Bool, profile: ProfileID = Profile.defaultID) -> UIViewController {
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.linkPreview, id: signposter.makeSignpostID())
        let (webView, controller) = makePreviewWebView(isPrivate: isPrivate, profile: profile)
        contentRules?.apply(to: controller, forMainFrameURL: url)
        webView.load(URLRequest(url: url))
        signposter.endInterval(Signposts.linkPreview, interval)
        return LinkPreviewController(webView: webView) { [weak self] webView in
            webView.stopLoading()
            self?.contentRules?.release(controller)
        }
    }

    /// The preview's size for `menu` in `tab`'s window (`LinkMenuRules.previewSize`): short
    /// enough that every item shows without scrolling. Nil when there is no room for one, or
    /// before the tab is in a window.
    private func linkPreviewSize(for menu: LinkMenu, in tab: Tab) -> CGSize? {
        guard let window = existingWebView(for: tab)?.window else { return nil }
        let traits = window.traitCollection
        let rowHeight = UIFontMetrics(forTextStyle: .body).scaledValue(for: LinkMenuRules.menuRowHeight, compatibleWith: traits)
        return LinkMenuRules.previewSize(
            window: window.bounds.size, safeTop: window.safeAreaInsets.top, safeBottom: window.safeAreaInsets.bottom,
            rows: menu.items.count, sections: menu.sections.count, rowHeight: rowHeight,
            menuBeside: traits.verticalSizeClass == .compact
        )
    }

    /// The user tapped the preview: the link opens in the tab, as in Safari.
    func commitPreview(of linkURL: URL?, in tab: Tab, animator: any UIContextMenuInteractionCommitAnimating) {
        guard let linkURL, NavigationRules.schemeKind(of: linkURL) == .web else { return }
        animator.preferredCommitStyle = .pop
        animator.addCompletion { [weak tab] in tab?.load(linkURL) }
    }

    // MARK: - Actions

    func perform(_ item: LinkMenuItem, on element: LinkElement, in tab: Tab) {
        Signposts.signposter.emitEvent(Signposts.linkMenuAction, "\(item.rawValue, privacy: .public)")
        let link = element.linkURL
        switch item {
        case .openInNewTab, .openInBackground, .openInOtherPane, .openInNewWindow:
            guard let link else { return }
            let placement: LinkOpenPlacement = switch item {
            case .openInBackground: .backgroundTab
            case .openInOtherPane: .otherPane
            case .openInNewWindow: .newWindow
            default: .newTab
            }
            host?.tab(tab, open: link, placement: placement)
        case .copyLink:
            guard let link else { return }
            pasteboard.url = link
            host?.tab(tab, didComplete: .copyLink, succeeded: true)
        case .share:
            guard let link, let webView = existingWebView(for: tab) else { return }
            let center = CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 1, height: 1)
            host?.tab(tab, share: link, from: webView, sourceRect: center)
        case .downloadLinkedFile:
            guard let link else { return }
            startDownload(link, from: tab)
        case .saveImage, .copyImage:
            guard let image = element.imageURL else { return }
            Task { [weak self, weak tab] in
                guard let self else { return }
                // Photos off for Plain: say so and offer Settings instead of failing silently.
                if item == .saveImage {
                    let photos = await Self.photosAccessOffMain()
                    self.systemAccess.record(.photos, photos)
                    if self.systemAccess.access(.photos).isBlocked {
                        if let tab { self.host?.tab(tab, wasDenied: [.photos], forSite: "") }
                        return
                    }
                }
                let store = tab.map(self.websiteDataStore(for:)) ?? self.dataStore
                let succeeded = await self.handleImage(image, item: item, store: store)
                if let tab { self.host?.tab(tab, didComplete: item, succeeded: succeeded) }
            }
        }
    }

    /// Fetches the image with the page's cookies, off the main thread, then copies it or adds it
    /// to Photos. The bytes are never decoded: the pasteboard and Photos take the file as is, so a
    /// GIF stays animated.
    private func handleImage(_ url: URL, item: LinkMenuItem, store: WKWebsiteDataStore) async -> Bool {
        let cookies = url.scheme?.hasPrefix("http") == true ? await store.httpCookieStore.cookies(for: url) : []
        guard let (data, type) = try? await Self.fetchImage(url, cookies: cookies) else { return false }
        switch item {
        case .copyImage:
            pasteboard.setItems([[type.identifier: data]])
            return true
        case .saveImage:
            return await Self.addToPhotos(data)
        default:
            return false
        }
    }

    @concurrent
    nonisolated static func fetchImage(_ url: URL, cookies: [HTTPCookie]) async throws -> (Data, UTType) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await imageSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let type = response.mimeType.flatMap { UTType(mimeType: $0) } ?? .image
        guard type.conforms(to: .image), !data.isEmpty else { throw URLError(.cannotDecodeContentData) }
        return (data, type)
    }

    /// No cookie jar or cache of its own: the page's cookies are passed per request.
    nonisolated private static let imageSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    /// Whether Plain may add to Photos (Save Image). Reading the answer changes nothing, so an
    /// isolated run reads the simulator's or phone's own.
    nonisolated static func photosAccess() -> SystemAccess {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited: .allowed
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    @concurrent
    nonisolated static func photosAccessOffMain() async -> SystemAccess {
        photosAccess()
    }

    @concurrent
    nonisolated static func addToPhotos(_ data: Data) async -> Bool {
        // An isolated test run never adds to the owner's photo library.
        if TestIsolation.isActive { return true }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            return true
        } catch {
            return false
        }
    }
}
#endif
