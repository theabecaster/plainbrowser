#if canImport(UIKit)
import BrowserCore
import DesignSystem
import FeatureUI
import Intelligence
import PerfSignposts
import Reader
import SwiftUI
import UIKit
import WebEngine

/// The summary on screen (or kept behind a source opened from it). One at a time: a new summary
/// replaces it.
final class SummaryUIState {
    var run: SummaryRun?
    var screen: SummaryScreenModel?
    var input: SummaryRun.Input?
    /// Sources open in private tabs when the summary started from one.
    var isPrivate = false
    /// The sheet is closing to show a source: the run keeps going, and Back on that tab's first
    /// page brings the summary back.
    var keepsRun = false
    weak var returnTab: WebEngine.Tab?
}

// MARK: - Browse for Me and Summarize Page

extension BrowserViewController {
    /// Whether `text` would search rather than open an address.
    static func isSearch(_ text: String) -> Bool {
        if case .search = AddressBarInput(text) { return true }
        return false
    }

    /// Browse for Me's row above the field, by the rules: its place while something is typed and
    /// the model can run, the row itself while the text would search. Before typing, the focused
    /// field's own rows (the page, a copied link, recents) sit right on the field with no gap; the
    /// place opens with the first keystroke, when the list changes anyway, and then stays put
    /// whether the text reads as a search or an address, so the suggestions never move while
    /// typing. Cheap (no pass over the tabs): it runs per keystroke.
    func updateBrowseForMe(query: String) {
        var state = ChromeState()
        state.isEditing = true
        state.isAIAvailable = session.summaries.isAvailable
        state.queryIsSearch = Self.isSearch(query)
        let rules = ControlRules(state)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        sheet.setBrowseForMe(reserved: state.isAIAvailable && !trimmed.isEmpty, query: rules.browseForMe ? trimmed : nil)
    }

    /// The model's answer changed (Apple Intelligence turned on, the model ready): the entries
    /// follow at once, the search sheet's row included.
    func summaryAvailabilityChanged() {
        // A summary on its way when the model goes away ends in one line, not a stuck spinner; a
        // finished one stays to be read.
        if !session.summaries.isAvailable, let run = summaryUI.run, run.isRunning {
            Signposts.signposter.emitEvent(Signposts.systemAccessNotice, "summary ended: model unavailable")
            run.end(with: .unavailable)
        }
        updateButtons()
        guard isEditingAddress else { return }
        // As `queryChanged` sees it: the page's own address, untouched, is not a query.
        let text = pill.textField.text ?? ""
        updateBrowseForMe(query: text == pageAddress?.absoluteString ? "" : text)
    }

    /// Summarize Page, in the page menu's row with Find and Reader.
    func summarizeMenuItems(_ rules: ControlRules) -> [UIMenuElement] {
        guard rules.summarizePage else { return [] }
        let action = UIAction(title: "Summarize Page", image: UIImage(systemName: "sparkles")) { [weak self] _ in
            self?.summarizePage()
        }
        action.accessibilityIdentifier = "menu.summarize"
        return [action]
    }

    // MARK: Starting

    func browseForMe(_ query: String) {
        Haptic.tap.play()
        // Browse for Me from a New Tab keeps that tab: its sources open from there.
        tabsUI.newTabReturn = nil
        let isPrivate = currentTab?.isPrivate ?? false
        endAddressEditing()
        let input = SummaryRun.Input.search(query, engine: data.searchEngine)
        guard let screen = presentSummary(
            SummaryProgress(subject: .search(query), stage: .searching(engine: data.searchEngine.name)), isPrivate: isPrivate
        ) else { return }
        summaryUI.input = input
        startRun(input, on: screen)
    }

    func summarizePage() {
        guard let tab = currentTab, let page = session.pool.webView(for: tab), let url = pageAddress else { return }
        let title = tab.title.isEmpty ? BrowseForMe.siteName(url) : tab.title
        guard let screen = presentSummary(
            SummaryProgress(subject: .page(title: title, url: url), stage: .writing), isPrivate: tab.isPrivate
        ) else { return }
        // Weak: a page closed meanwhile has no text to give.
        let input = SummaryRun.Input.page(title: title, url: url) { [weak page] in
            guard let page else { return nil }
            return try await ReaderExtractor.text(in: page, limit: FixedChoices.summaryMaxPageText)
        }
        summaryUI.input = input
        startRun(input, on: screen)
    }

    /// Shows the summary sheet with its first state and wires its actions, or nil when another
    /// sheet is up (nothing then starts out of sight). Replaces a summary kept from before.
    private func presentSummary(_ progress: SummaryProgress, isPrivate: Bool) -> SummaryScreenModel? {
        guard presentedViewController == nil else { return nil }
        cancelSummary()
        let screen = SummaryScreenModel(progress: progress)
        screen.onDone = { [weak self] in self?.closeSheet() }
        screen.onOpenSource = { [weak self] url, background in self?.openSummarySource(url, background: background) }
        screen.onRetry = { [weak self, weak screen] in
            guard let self, let screen, let input = summaryUI.input else { return }
            summaryUI.run?.cancel()
            startRun(input, on: screen)
        }
        // A search from a page opens a new tab (the address bar's second door), so the page stays
        // and Back returns to it; from no page it loads where the search would have.
        screen.onSearchInstead = { [weak self] query in
            guard let self, let url = data.searchEngine.resultsURL(for: query) else { return }
            let opener = currentTab.flatMap { session.tabs.isEmpty($0.id) ? nil : $0 }
            let isPrivate = summaryUI.isPrivate
            closeSheet { [weak self] in
                guard let self else { return }
                guard let opener, opener === currentTab else { return load(url, kind: .typed) }
                let tab = session.tabs.newTab(isPrivate: isPrivate, opener: opener)
                engineUI.typedVisitTabs.insert(tab.id)
                tab.load(url)
                show(tab)
            }
        }
        summaryUI.screen = screen
        summaryUI.isPrivate = isPrivate
        showSummarySheet(screen, signpost: Signposts.summaryShow)
        return screen
    }

    private func showSummarySheet(_ screen: SummaryScreenModel, signpost: StaticString) {
        let host = UIHostingController(rootView: SummaryView(model: screen))
        host.modalPresentationStyle = .pageSheet
        host.view.accessibilityIdentifier = "summarySheet"
        present(host, signpost: signpost) { [weak self] in self?.summarySheetClosed() }
    }

    private func startRun(_ input: SummaryRun.Input, on screen: SummaryScreenModel) {
        let browsing: (any ResultsReading & PageReading)?
        if case .search = input { browsing = session.summaries.makeBrowsing() } else { browsing = nil }
        let run = SummaryRun(input, model: session.summaries.model, results: browsing, pages: browsing) { [weak screen] progress in
            screen?.apply(progress)
        }
        summaryUI.run = run
        run.start()
    }

    // MARK: Closing and sources

    /// Done or a swipe down: everything stops and goes, unless the sheet closed to show a source.
    private func summarySheetClosed() {
        if summaryUI.keepsRun {
            summaryUI.keepsRun = false
            return
        }
        cancelSummary()
    }

    func cancelSummary() {
        summaryUI.run?.cancel()
        summaryUI.run = nil
        summaryUI.screen = nil
        summaryUI.input = nil
        summaryUI.returnTab = nil
    }

    /// A citation or a source row: a new tab, shown (the summary waits behind it, Back returns),
    /// or one behind the page from the row's menu.
    private func openSummarySource(_ url: URL, background: Bool) {
        let isPrivate = summaryUI.isPrivate
        if background {
            Signposts.signposter.emitEvent(Signposts.summaryOpenSource, "background")
            let tab = session.tabs.newTab(isPrivate: isPrivate, inBackground: true)
            tab.load(url)
            Haptic.success.play()
            return
        }
        Signposts.signposter.emitEvent(Signposts.summaryOpenSource, "new tab")
        summaryUI.keepsRun = true
        closeSheet { [weak self] in
            guard let self else { return }
            let tab = session.tabs.newTab(isPrivate: isPrivate)
            tab.load(url)
            show(tab)
            summaryUI.returnTab = tab
        }
    }

    /// Back from a source's first page: the summary as it was, or as far as it has been written.
    func reopenSummary() {
        guard let screen = summaryUI.screen, presentedViewController == nil else { return }
        summaryUI.returnTab = nil
        showSummarySheet(screen, signpost: Signposts.summaryShowAgain)
    }
}
#endif
