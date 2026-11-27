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

    // MARK: Print and Save as PDF

    /// Print and Save as PDF as one row of two (state rules §4: on what finished loading, or the
    /// reader's article, which they act on instead of the page under it).
    func exportMenu(_ rules: ControlRules) -> UIMenu? {
        var items: [UIMenuElement] = []
        if rules.print {
            let print = UIAction(title: "Print…", image: UIImage(systemName: "printer")) { [weak self] _ in
                self?.printPage()
            }
            print.accessibilityIdentifier = "menu.print"
            items.append(print)
        }
        if rules.saveAsPDF {
            let save = UIAction(title: "Save as PDF", image: UIImage(systemName: "doc.richtext")) { [weak self] _ in
                self?.saveAsPDF()
            }
            save.accessibilityIdentifier = "menu.saveAsPDF"
            items.append(save)
        }
        guard !items.isEmpty else { return nil }
        let row = UIMenu(options: .displayInline, children: items)
        row.preferredElementSize = .medium
        return row
    }

    /// What Print and Save as PDF act on: the reader's article while it shows, else the page.
    private func exportTarget() -> (tab: Tab, webView: WKWebView)? {
        guard let tab = currentTab else { return nil }
        guard let webView = engineUI.reader.webView ?? session.pool.webView(for: tab) else { return nil }
        return (tab, webView)
    }

    /// The system print sheet with the page's print formatter: paper, copies, range and printer
    /// are the system's, and the page's `@media print` styles apply.
    func printPage() {
        guard let (tab, webView) = exportTarget() else { return Haptic.nothingThere.play() }
        Task { [weak self] in
            await PageExport.loadLazyImages(in: webView)
            guard let self, self.currentTab === tab, self.presentedViewController == nil else { return }
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
        Task { [weak self] in
            await PageExport.loadLazyImages(in: webView)
            let title = tab.title
            let data = await PageExport.pdf(of: webView, title: title)
            let name = PageExport.fileName(title: title, url: tab.url)
            let file = await Task.detached(priority: .userInitiated) {
                try? PageExport.writeTemporaryFile(data, named: name)
            }.value
            Signposts.signposter.endInterval(Signposts.exportPDF, interval)
            guard let self, self.currentTab === tab, self.presentedViewController == nil else { return }
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
