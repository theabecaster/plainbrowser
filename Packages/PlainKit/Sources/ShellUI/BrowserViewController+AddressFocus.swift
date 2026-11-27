#if canImport(UIKit)
import BrowserCore
import DesignSystem
import PerfSignposts
import UIKit
import WebEngine

/// What the focused address bar offers before typing, and which of Arc's two intents the field
/// serves (docs/decisions.md, "Address focus and the page sheet").
final class AddressFocusState {
    /// Favorites and recent pages, read off the main thread ahead of the next focus, so the
    /// field's first frame has them.
    var content = FocusContent.empty
    var loadTask: Task<Void, Never>?
    let copiedLink = CopiedLinkWatcher()
    /// The field edits the page's own address: Return loads in the same tab, and the field has a
    /// Copy button while it still shows that address. Otherwise a search over a page opens a new
    /// tab (`LaunchUIState.isFreshSearch`).
    var isEditingPage = false
}

// MARK: - The focused field's content

extension BrowserViewController {
    /// The rows above the empty (or untouched) field, nearest first. Built from memory only: the
    /// focus snapshot, the closed stack and the pasteboard check already made.
    func focusItems() -> [SheetItem] {
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.focusContent)
        defer { signposter.endInterval(Signposts.focusContent, interval) }
        let tab = currentTab
        let isPrivate = tab?.isPrivate == true
        let page = tab.flatMap { session.tabs.isEmpty($0.id) ? nil : pageAddress }
        var items: [SheetItem] = []
        if let offer = focusUI.copiedLink.offer(excluding: page) {
            items.append(.copiedLink(offer.url))
        }
        if let page, !focusUI.isEditingPage {
            items.append(.currentPage(url: page, title: tab?.title))
        }
        guard !isPrivate else {
            if items.isEmpty, focusUI.content.favorites.isEmpty {
                items.append(.hint(String(localized: "Private tab: Plain keeps no history of the pages you visit here.")))
            }
            return items
        }
        let pageKey = page.map(AddressBarSuggestions.addressKey)
        let recent = focusUI.content.recent
            .filter { AddressBarSuggestions.addressKey($0.url) != pageKey }
            .prefix(FixedChoices.focusRecentPages)
        items += recent.map { SheetItem.recent(url: $0.url, title: $0.title) }
        for batch in session.tabs.store.recentlyClosed.suffix(FixedChoices.focusClosedTabs).reversed() {
            guard let first = batch.tabs.first else { continue }
            items.append(.closed(batch: batch.id, url: first.entry.url, title: first.entry.title, count: batch.tabs.count))
        }
        // The start screen's own sentence keeps an empty start company; elsewhere one sentence.
        let showsStart = tab.map { session.tabs.isEmpty($0.id) } ?? true
        if items.isEmpty, focusUI.content.favorites.isEmpty, !showsStart {
            items.append(.hint(String(localized: "Search, or enter an address. Pages you visit and your favorites show up here.")))
        }
        return items
    }

    /// Reads favorites and recent pages off the main thread for the next focus; an open field
    /// takes them in as they land.
    func refreshFocusContent() {
        focusUI.loadTask?.cancel()
        focusUI.loadTask = Task { [weak self, data] in
            let signposter = Signposts.signposter
            let interval = signposter.beginInterval(Signposts.focusContentLoad)
            let content = await data.focusContent()
            signposter.endInterval(Signposts.focusContentLoad, interval)
            guard let self, !Task.isCancelled, content != self.focusUI.content else { return }
            self.focusUI.content = content
            self.sheet.setFavorites(content.favorites)
            if self.isEditingAddress { self.queryChanged() }
        }
    }

    /// A page was recorded in history (regular tabs only): it leads the recent pages at once,
    /// while the history writer batches it to disk. A title arriving later names it.
    func noteVisit(url: URL, title: String?) {
        guard LiveAddressBarData.isRecordable(url) else { return }
        let key = AddressBarSuggestions.addressKey(url)
        var content = focusUI.content
        guard !content.favorites.contains(where: { AddressBarSuggestions.addressKey($0.url) == key }) else { return }
        let known = content.recent.first { AddressBarSuggestions.addressKey($0.url) == key }
        content.recent.removeAll { AddressBarSuggestions.addressKey($0.url) == key }
        let name = title.flatMap { $0.isEmpty ? nil : $0 } ?? known?.title
        content.recent.insert(FavoritePage(url: url, title: name), at: 0)
        content.recent = Array(content.recent.prefix(FixedChoices.focusRecentPages + 1))
        focusUI.content = content
    }

    /// The pasteboard may hold a new link: check it (no paste alert) and update an open field.
    func refreshCopiedLink() {
        focusUI.copiedLink.onChange = { [weak self] in
            guard let self, self.isEditingAddress else { return }
            self.queryChanged()
        }
        focusUI.copiedLink.refresh()
    }

    // MARK: Picks

    /// A pick from the focused field's own rows. Returns false for picks that open an address.
    func handleFocusPick(_ pick: SearchPick) -> Bool {
        let signposter = Signposts.signposter
        switch pick {
        case .editAddress:
            signposter.emitEvent(Signposts.focusAction, "edit")
            beginEditingPageAddress()
        case .copyAddress:
            signposter.emitEvent(Signposts.focusAction, "copy")
            copyPageAddress()
            sheet.confirmCopied()
        case .copiedLink(let known):
            signposter.emitEvent(Signposts.focusAction, "copied")
            let url = known ?? UIPasteboard.plain.url ?? UIPasteboard.plain.string.flatMap {
                AddressBarInput($0)?.destination(searchingWith: data.searchEngine)
            }
            guard let url else {
                Haptic.nothingThere.play()
                return true
            }
            focusUI.copiedLink.markUsed()
            load(url, kind: .typed)
        case .reopen(let batch):
            signposter.emitEvent(Signposts.focusAction, "closed")
            endAddressEditing()
            _ = galleryReopen(batch: batch)
        case .page, .search:
            return false
        }
        return true
    }

    /// Copies the page's address (the field's Copy button, the page's row, the page sheet).
    func copyPageAddress() {
        guard let url = pageAddress else { return Haptic.nothingThere.play() }
        Signposts.signposter.emitEvent(Signposts.copyLink)
        UIPasteboard.plain.url = url
        focusUI.copiedLink.noteCopied(url)
        Haptic.success.play()
    }

    // MARK: Editing the page's address

    /// The page's address in the field, selected, with Copy inside it: Return loads in the same
    /// tab. From an open search (the page's row) the field stays where it is; from the page sheet
    /// it opens.
    func beginEditingPageAddress() {
        guard let url = pageAddress else { return }
        Signposts.signposter.emitEvent(Signposts.editAddress)
        focusUI.isEditingPage = true
        launchUI.isFreshSearch = false
        pill.textField.text = url.absoluteString
        pill.setCopyShown(true)
        if isEditingAddress {
            pill.textField.selectAll(nil)
            queryChanged()
            return
        }
        applyEditingLayout(true, animated: true)
        if !pill.beginEditing() { applyEditingLayout(false, animated: false) }
    }
}

// MARK: - Copied link

/// Watches the pasteboard for a web address to offer as "Open Copied Link", without reading it:
/// `detectPatterns` answers whether there is one and shows no paste alert (docs/research/
/// address-focus.md). The address itself is known only when Plain copied it; another app's link
/// is read on the tap (the system Paste button, or the alert).
@MainActor
final class CopiedLinkWatcher {
    struct Offer: Equatable {
        var changeCount: Int
        /// Known only when Plain copied it.
        var url: URL?
    }

    var onChange: () -> Void = {}
    private var offerNow: Offer?
    private var checkedCount = Int.min
    private var firstSeen = Date.distantPast
    private var usedCount = Int.min
    private var plainCopy: Offer?

    /// The offer for the focused field, unless it was used, is stale, or is the page on screen.
    func offer(excluding page: URL?) -> Offer? {
        guard let offer = offerNow, offer.changeCount != usedCount,
              Date.now.timeIntervalSince(firstSeen) < FixedChoices.copiedLinkFreshness
        else { return nil }
        if let url = offer.url, let page, AddressBarSuggestions.addressKey(url) == AddressBarSuggestions.addressKey(page) {
            return nil
        }
        return offer
    }

    /// Checks the pasteboard if it changed since the last check. Cheap: a change count, then the
    /// pattern check off the main thread.
    func refresh() {
        let board = UIPasteboard.plain
        let count = board.changeCount
        guard count != checkedCount else { return }
        checkedCount = count
        firstSeen = .now
        offerNow = nil
        if let plainCopy, plainCopy.changeCount == count {
            offerNow = plainCopy
            onChange()
            return
        }
        guard board.hasURLs || board.hasStrings else { return onChange() }
        board.detectPatterns(for: [\UIPasteboard.DetectedValues.probableWebURL]) { [weak self] result in
            let found = (try? result.get())?.contains(\UIPasteboard.DetectedValues.probableWebURL) == true
            Task { @MainActor in
                guard let self, self.checkedCount == count else { return }
                self.offerNow = found ? Offer(changeCount: count, url: nil) : nil
                self.onChange()
            }
        }
    }

    /// Plain just copied `url`: it knows the address, so the row can show it.
    func noteCopied(_ url: URL) {
        plainCopy = Offer(changeCount: UIPasteboard.plain.changeCount, url: url)
        refresh()
    }

    /// The offer was opened: it is not offered again until something new is copied.
    func markUsed() {
        usedCount = offerNow?.changeCount ?? checkedCount
    }
}
#endif
