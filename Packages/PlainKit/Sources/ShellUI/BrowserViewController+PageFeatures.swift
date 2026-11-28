#if canImport(UIKit)
import BrowserCore
import DesignSystem
import FeatureUI
import LinkPresentation
import PerfSignposts
import UIKit
import WebEngine
import WebKit

// FeatureUI can't import WebEngine; the engine's types already have exactly what its Downloads
// list reads (docs/architecture.md, "Downloads UI").
extension Download: DownloadListItem {}
extension DownloadCoordinator: DownloadListSource {}

// MARK: - Page features: zoom, PDF, downloads

extension BrowserViewController {
    /// Zoom as one row of the page sheet: − (Zoom Out), the percentage (back to 100%), + (Zoom
    /// In) (docs/ui-reference.md, page menu). Remembered per site by the engine. The sheet stays
    /// up and shows the new percentage after each step: a tick per step, a light tap at 100% (the
    /// detent, as a slider's), in the action that redraws it.
    func zoomActions(for tab: Tab) -> [UIAction] {
        let zoomOut = UIAction(
            title: "Zoom Out", image: UIImage(systemName: "minus"), attributes: tab.canZoomOut ? [] : [.disabled]
        ) { [weak tab] _ in
            tab?.zoomOut()
            Self.playZoomStep(tab)
        }
        zoomOut.accessibilityIdentifier = "menu.zoomOut"
        let percent = UIAction(
            title: "\(tab.zoomPercent)%", attributes: tab.zoomPercent == 100 ? [.disabled] : []
        ) { [weak tab] _ in
            tab?.resetZoom()
            Self.playZoomStep(tab)
        }
        percent.accessibilityIdentifier = "menu.zoomReset"
        percent.accessibilityLabel = "Zoom \(tab.zoomPercent)%, Actual Size"
        let zoomIn = UIAction(
            title: "Zoom In", image: UIImage(systemName: "plus"), attributes: tab.canZoomIn ? [] : [.disabled]
        ) { [weak tab] _ in
            tab?.zoomIn()
            Self.playZoomStep(tab)
        }
        zoomIn.accessibilityIdentifier = "menu.zoomIn"
        return [zoomOut, percent, zoomIn]
    }

    private static func playZoomStep(_ tab: Tab?) {
        guard let tab else { return }
        (tab.zoomPercent == 100 ? Haptic.tap : Haptic.selection).play()
    }

    /// Save PDF to Files, only on a PDF page.
    func pdfMenuItems(for tab: Tab) -> [UIMenuElement] {
        guard tab.isPDF else { return [] }
        let save = UIAction(title: "Save PDF to Files", image: UIImage(systemName: "arrow.down.doc")) { [weak tab] _ in
            tab?.saveToDownloads()
        }
        save.accessibilityIdentifier = "menu.savePDF"
        return [save]
    }

    // MARK: Translate Page

    /// Translate Page on a page in a language the user doesn't read, subtitled with the pair
    /// ("French to English"); Show Original while it is translated (state rules §4).
    func translateMenuItems(for tab: Tab, item: TranslateItem) -> [UIMenuElement] {
        switch item {
        case .hidden:
            return []
        case .showOriginal:
            let subtitle = tab.translation == .translating ? String(localized: "Translating…") : nil
            let show = UIAction(title: "Show Original", subtitle: subtitle, image: UIImage(systemName: "translate")) { [weak tab] _ in
                tab?.showOriginal()
            }
            show.accessibilityIdentifier = "menu.translate"
            // On: the sheet's tile shows in the accent while the page is translated.
            show.state = .on
            return [show]
        case .translate:
            let translate = UIAction(
                title: "Translate Page", subtitle: Self.languagePair(tab), image: UIImage(systemName: "translate")
            ) { [weak tab] _ in
                tab?.translate()
            }
            translate.accessibilityIdentifier = "menu.translate"
            return [translate]
        }
    }

    /// "French to English", in the user's language; nil when either name is unknown.
    static func languagePair(_ tab: Tab) -> String? {
        guard let source = tab.pageLanguage.flatMap(languageName), let target = tab.translationTarget.flatMap(languageName)
        else { return nil }
        return String(localized: "\(source) to \(target)")
    }

    static func languageName(_ language: Locale.Language) -> String? {
        guard let code = language.languageCode?.identifier else { return nil }
        return Locale.current.localizedString(forLanguageCode: code)?.capitalized(with: .current)
    }

    /// The one quiet hint (`FixedChoices.translateHintShownOnce`): the first time ever a page in a
    /// language the user doesn't read shows, a toast names the language with a Translate button.
    /// After that, Translate Page waits in the page menu. No banner, no badge (ui-reference).
    func offerTranslationOnce() {
        let key = "PlainTranslateHintShown"
        // TestIsolation.defaults: a test run's own suite, never the owner's flag.
        let defaults = TestIsolation.defaults
        guard FixedChoices.translateHintShownOnce, !defaults.bool(forKey: key),
              let tab = currentTab, let language = tab.pageLanguage.flatMap(Self.languageName)
        else { return }
        let page = tab.url
        showToastWhenFree { [weak self, weak tab] in
            guard let self, let tab, tab === self.currentTab, tab.url == page, tab.translationTarget != nil,
                  tab.translation == .original, !defaults.bool(forKey: key)
            else { return }
            defaults.set(true, forKey: key)
            self.tabsUI.toast.show(String(localized: "This page is in \(language)"), button: "Translate") { [weak tab] in
                tab?.translate()
            }
        }
    }

    // MARK: Print and Save as PDF

    /// Print and Save as PDF in the share sheet (state rules §4: on what finished loading, or the
    /// reader's article, which they act on instead of the page under it). Safari and Chrome keep
    /// them there, and the page menu stays short enough for the Duo's outer screen.
    func exportActivities(_ rules: ControlRules) -> [UIActivity] {
        var activities: [UIActivity] = []
        if rules.print { activities.append(PageActivity.print) }
        if rules.saveAsPDF { activities.append(PageActivity.saveAsPDF) }
        return activities
    }

    /// The share sheet closed on one of Plain's export activities: run it once the sheet is gone,
    /// since the print sheet and the PDF's share sheet present from the browser.
    func runExportActivity(_ type: UIActivity.ActivityType, after sheet: UIViewController) {
        let action: () -> Void
        switch type {
        case PageActivity.printType: action = { [weak self] in self?.printPage() }
        case PageActivity.saveAsPDFType: action = { [weak self] in self?.saveAsPDF() }
        default: return
        }
        if let coordinator = sheet.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in action() }
        } else {
            action()
        }
    }

    /// What Print and Save as PDF act on: the reader's article while it shows, else the page.
    private func exportTarget() -> (tab: Tab, webView: WKWebView)? {
        guard let tab = currentTab else { return nil }
        guard let webView = engineUI.reader.webView ?? session.pool.webView(for: tab) else { return nil }
        return (tab, webView)
    }

    /// The export still acts on what the user chose: the same tab, web view and document.
    private func isStillExporting(_ tab: Tab, _ webView: WKWebView, document: URL?) -> Bool {
        guard currentTab === tab, presentedViewController == nil, webView.url == document, !webView.isLoading,
              let current = exportTarget()
        else { return false }
        return current.webView === webView
    }

    /// The system print sheet with the page's print formatter: paper, copies, range and printer
    /// are the system's, and the page's `@media print` styles apply.
    func printPage() {
        guard let (tab, webView) = exportTarget() else { return Haptic.nothingThere.play() }
        let document = webView.url
        Task { [weak self] in
            let token = await PageExport.markDocument(in: webView)
            await PageExport.loadLazyImages(in: webView)
            guard await PageExport.isSameDocument(webView, token: token), let self,
                  self.isStillExporting(tab, webView, document: document)
            else { return }
            Signposts.signposter.emitEvent(Signposts.printPage)
            let info = UIPrintInfo(dictionary: nil)
            info.outputType = .general
            info.jobName = tab.title.isEmpty ? PageExport.fileName(title: nil, url: tab.url) : tab.title
            let controller = UIPrintInteractionController.shared
            controller.printInfo = info
            controller.printFormatter = webView.viewPrintFormatter()
            controller.present(animated: true)
        }
    }

    /// A paginated PDF of the page in the share sheet (Save to Files, AirDrop, Mail). The file
    /// lives in a temporary folder until the sheet closes.
    func saveAsPDF() {
        guard let (tab, webView) = exportTarget() else { return Haptic.nothingThere.play() }
        let interval = Signposts.signposter.beginInterval(Signposts.exportPDF)
        let document = webView.url
        Task { [weak self] in
            let token = await PageExport.markDocument(in: webView)
            await PageExport.loadLazyImages(in: webView)
            guard await PageExport.isSameDocument(webView, token: token), let self,
                  self.isStillExporting(tab, webView, document: document)
            else {
                return Signposts.signposter.endInterval(Signposts.exportPDF, interval, "cancelled")
            }
            let title = tab.title
            let data = await PageExport.pdf(of: webView, title: title) { [weak self] in
                self?.tabsUI.toast.show(String(localized: "Saving as PDF…"))
            }
            let name = PageExport.fileName(title: title, url: tab.url)
            let file = await Task.detached(priority: .userInitiated) {
                try? PageExport.writeTemporaryFile(data, named: name)
            }.value
            Signposts.signposter.endInterval(Signposts.exportPDF, interval)
            let same = await PageExport.isSameDocument(webView, token: token)
            guard same, self.isStillExporting(tab, webView, document: document) else {
                if let file { Task.detached { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
                return
            }
            guard let file, !data.isEmpty else {
                // The user waited for it: the warning, with the sentence that says so.
                Haptic.failed.play()
                return self.tabsUI.toast.show("This page couldn't be saved as a PDF")
            }
            let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            sheet.completionWithItemsHandler = { _, _, _, _ in
                Task.detached { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            }
            sheet.popoverPresentationController?.sourceItem = self.pill
            self.present(sheet, animated: true)
        }
    }

    /// Downloads, in the app section while there are any this session; "1 in progress" while one
    /// runs, so a download that started says so before it ends.
    func downloadsMenuItems() -> [UIMenuElement] {
        let downloads = session.pool.downloads.downloads
        guard currentRules().downloads else { return [] }
        let running = downloads.count { $0.state == .inProgress }
        let subtitle = running == 0 ? nil : String(localized: "\(running) in progress")
        let item = UIAction(title: "Downloads", subtitle: subtitle, image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in
            self?.showDownloads()
        }
        item.accessibilityIdentifier = "menu.downloads"
        return [item]
    }

    func showDownloads() {
        let sheet = sheets.downloads(source: session.pool.downloads) { [weak self] in self?.closeSheet() }
        present(sheet, signpost: Signposts.downloadsShow)
    }

    // MARK: DownloadPresenter

    /// The start's tap waits a moment: a small file finishes first, and its success with the
    /// toast is then the one haptic (a tap glued to a success would read as one muddled event).
    public func downloadDidStart(_ download: Download) {
        Task { [weak download] in
            try? await Task.sleep(for: FixedChoices.hapticDownloadStartDelay)
            if download?.state == .inProgress { Haptic.tap.play() }
        }
    }

    /// A short toast instead of an alert: the file is in Downloads, one tap away. While the
    /// gallery or a sheet is up the newest one waits, since Show could not open Downloads there.
    public func downloadDidEnd(_ download: Download) {
        switch download.state {
        case .finished:
            let message = "\(download.filename) downloaded"
            // The outcome plays with its toast, not when the file lands: behind a sheet or the
            // gallery the toast waits, and so does the haptic (docs/ui-reference.md, "Haptics").
            showToastWhenFree { [weak self] in
                Haptic.success.play()
                self?.tabsUI.toast.show(message, button: "Show") { [weak self] in self?.showDownloads() }
            }
        case .failed:
            let message = "\(download.filename) didn't download"
            showToastWhenFree { [weak self] in
                Haptic.failed.play()
                self?.tabsUI.toast.show(message, button: "Show") { [weak self] in self?.showDownloads() }
            }
        case .inProgress, .cancelled:
            break
        }
    }
}

/// The page's address for the share sheet, with its title for the sheet's header and a mail's
/// subject. A bare URL shows only the host and a blank icon there.
nonisolated final class PageShareItem: NSObject, UIActivityItemSource {
    let url: URL
    let title: String?

    init(url: URL, title: String?) {
        self.url = url
        self.title = title
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { url }

    func activityViewController(_ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? {
        url
    }

    func activityViewController(_ controller: UIActivityViewController, subjectForActivityType type: UIActivity.ActivityType?) -> String {
        title ?? ""
    }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        metadata.title = title
        return metadata
    }
}

/// One of Plain's actions in the share sheet (Print, Save as PDF). The sheet reports the choice
/// through its completion handler, and the browser runs it after the sheet is gone.
nonisolated final class PageActivity: UIActivity {
    static let printType = UIActivity.ActivityType("dev.abrahamgonzalez.plainbrowser.print")
    static let saveAsPDFType = UIActivity.ActivityType("dev.abrahamgonzalez.plainbrowser.saveAsPDF")

    static var print: PageActivity { PageActivity(type: printType, title: String(localized: "Print"), symbol: "printer") }
    static var saveAsPDF: PageActivity {
        PageActivity(type: saveAsPDFType, title: String(localized: "Save as PDF"), symbol: "doc.richtext")
    }

    private let type: UIActivity.ActivityType
    private let title: String
    private let symbol: String

    private init(type: UIActivity.ActivityType, title: String, symbol: String) {
        self.type = type
        self.title = title
        self.symbol = symbol
        super.init()
    }

    override class var activityCategory: UIActivity.Category { .action }
    override var activityType: UIActivity.ActivityType? { type }
    override var activityTitle: String? { title }
    override var activityImage: UIImage? { UIImage(systemName: symbol) }
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool { true }
    override func perform() { activityDidFinish(true) }
}
#endif
