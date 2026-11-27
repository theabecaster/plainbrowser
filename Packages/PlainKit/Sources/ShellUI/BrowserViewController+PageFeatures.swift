#if canImport(UIKit)
import BrowserCore
import DesignSystem
import FeatureUI
import PerfSignposts
import UIKit
import WebEngine
import WebKit

// FeatureUI can't import WebEngine; the engine's types already have exactly what its Downloads
// list reads (docs/architecture.md, "Downloads UI").
extension Download: DownloadListItem {}
extension DownloadCoordinator: DownloadListSource {}

/// Where a page menu opens. The zoom row keeps the menu open where the shell can update the open
/// menu (the pill's and the glass bar's); the system's vertical bar can't, so there it closes.
enum PageMenuSource {
    case pill, button, barItem

    var keepsMenuOpen: Bool { self != .barItem }
}

// MARK: - Page features: zoom, PDF, downloads

extension BrowserViewController {
    /// Zoom as one inline row: − (Zoom Out), the percentage (back to 100%), + (Zoom In)
    /// (docs/ui-reference.md, page menu). Remembered per site by the engine.
    func zoomMenu(for tab: Tab, source: PageMenuSource) -> UIMenu {
        let keep: UIMenuElement.Attributes = source.keepsMenuOpen ? .keepsMenuPresented : []
        let zoomOut = UIAction(
            title: "Zoom Out", image: UIImage(systemName: "minus"),
            attributes: tab.canZoomOut ? keep : [.disabled]
        ) { [weak self, weak tab] _ in
            tab?.zoomOut()
            self?.refreshOpenPageMenu(source: source)
        }
        zoomOut.accessibilityIdentifier = "menu.zoomOut"
        let percent = UIAction(
            title: "\(tab.zoomPercent)%", attributes: tab.zoomPercent == 100 ? [.disabled] : keep
        ) { [weak self, weak tab] _ in
            tab?.resetZoom()
            self?.refreshOpenPageMenu(source: source)
        }
        percent.accessibilityIdentifier = "menu.zoomReset"
        percent.accessibilityLabel = "Zoom \(tab.zoomPercent)%, Actual Size"
        let zoomIn = UIAction(
            title: "Zoom In", image: UIImage(systemName: "plus"),
            attributes: tab.canZoomIn ? keep : [.disabled]
        ) { [weak self, weak tab] _ in
            tab?.zoomIn()
            self?.refreshOpenPageMenu(source: source)
        }
        zoomIn.accessibilityIdentifier = "menu.zoomIn"
        let row = UIMenu(title: "", options: .displayInline, children: [zoomOut, percent, zoomIn])
        row.preferredElementSize = .small
        return row
    }

    /// After a zoom step, the open menu shows the new percentage.
    private func refreshOpenPageMenu(source: PageMenuSource) {
        let menu = UIMenu(children: pageMenuElements(isFavorite: lastFavoriteAnswer, source: source))
        switch source {
        case .pill: pill.updateVisibleMenu(menu)
        case .button: buttonBar.button(.more).contextMenuInteraction?.updateVisibleMenu { _ in menu }
        case .barItem: break
        }
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
        guard FixedChoices.translateHintShownOnce, !UserDefaults.standard.bool(forKey: key),
              let tab = currentTab, let language = tab.pageLanguage.flatMap(Self.languageName)
        else { return }
        let page = tab.url
        showToastWhenFree { [weak self, weak tab] in
            guard let self, let tab, tab === self.currentTab, tab.url == page, tab.translationTarget != nil,
                  tab.translation == .original, !UserDefaults.standard.bool(forKey: key)
            else { return }
            UserDefaults.standard.set(true, forKey: key)
            self.tabsUI.toast.show(String(localized: "This page is in \(language)"), button: "Translate") { [weak tab] in
                tab?.translate()
            }
        }
    }

    // MARK: Print and Save as PDF

    /// Print and Save as PDF (state rules §4: on what finished loading, or the reader's article,
    /// which they act on instead of the page under it). They sit in Find on Page's row.
    func exportMenuItems(_ rules: ControlRules) -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if rules.print {
            let print = UIAction(title: "Print…", image: UIImage(systemName: "printer")) { [weak self] _ in
                self?.printPage()
            }
            print.accessibilityIdentifier = "menu.print"
            items.append(print)
        }
        if rules.saveAsPDF {
            let save = UIAction(title: "Save PDF", image: UIImage(systemName: "doc.richtext")) { [weak self] _ in
                self?.saveAsPDF()
            }
            save.accessibilityLabel = "Save as PDF"
            save.accessibilityIdentifier = "menu.saveAsPDF"
            items.append(save)
        }
        return items
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
                Haptic.nothingThere.play()
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

    public func downloadDidStart(_ download: Download) {
        Haptic.tap.play()
    }

    /// A short toast instead of an alert: the file is in Downloads, one tap away. While the
    /// gallery or a sheet is up the newest one waits, since Show could not open Downloads there.
    public func downloadDidEnd(_ download: Download) {
        switch download.state {
        case .finished:
            let message = "\(download.filename) downloaded"
            showToastWhenFree { [weak self] in
                self?.tabsUI.toast.show(message, button: "Show") { [weak self] in self?.showDownloads() }
            }
        case .failed:
            Haptic.nothingThere.play()
            let message = "\(download.filename) didn't download"
            showToastWhenFree { [weak self] in
                self?.tabsUI.toast.show(message, button: "Show") { [weak self] in self?.showDownloads() }
            }
        case .inProgress, .cancelled:
            break
        }
    }
}
#endif
