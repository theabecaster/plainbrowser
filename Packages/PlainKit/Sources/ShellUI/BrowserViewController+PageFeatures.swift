#if canImport(UIKit)
import BrowserCore
import DesignSystem
import FeatureUI
import PerfSignposts
import UIKit
import WebEngine

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

    /// Downloads, in the app section while there are any this session; "1 in progress" while one
    /// runs, so a download that started says so before it ends.
    func downloadsMenuItems() -> [UIMenuElement] {
        let downloads = session.pool.downloads.downloads
        guard !downloads.isEmpty else { return [] }
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
