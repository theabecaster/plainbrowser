#if canImport(UIKit)
import BrowserCore
import DesignSystem
import PerfSignposts
import Reader
import Storage
import UIKit
import WebEngine

// MARK: - Reading list (docs/research/bookmarks.md)

extension BrowserViewController {
    /// Read Later, or Remove from Reading List once saved (`ControlRules.readLater`), for the
    /// page menu. `url` is the address the menu acts on (`pageAddress`).
    func readLaterMenuItem(for tab: Tab, url: URL, isSaved: Bool) -> UIAction {
        let item = UIAction(
            title: isSaved ? "Remove from Reading List" : "Read Later",
            image: UIImage(systemName: "eyeglasses")
        ) { [weak self, weak tab] _ in
            guard let self, let tab else { return }
            if isSaved { self.removeFromReadingList(url) } else { self.saveForLater(tab, url: url) }
        }
        item.accessibilityIdentifier = "menu.readLater"
        // On: the sheet shows "Saved" in the accent; a tap removes it.
        if isSaved { item.state = .on }
        return item
    }

    /// Reading List, one of the app's places in the page menu: always there, like History.
    func readingListMenuItem() -> UIAction {
        let item = UIAction(title: "Reading List", image: UIImage(systemName: "eyeglasses")) { [weak self] _ in
            self?.showReadingList()
        }
        item.accessibilityIdentifier = "menu.readingList"
        return item
    }

    /// Read Later: saves the page with its article as a reader copy when it has one (the reader's
    /// own extraction, already done when the reader is open), else as a link. The extraction runs
    /// in the page's web content process and the encoding off the main thread.
    func saveForLater(_ tab: Tab, url: URL) {
        let signposter = Signposts.signposter
        let state = signposter.beginInterval(Signposts.readingListSave)
        // Only a page whose readerable check said yes is parsed: no 90 KB Readability run on a page
        // with no article.
        let page = currentRules().reader != .hidden ? session.pool.webView(for: tab) : nil
        let title = tab.title
        Haptic.success.prepare()
        Task { [weak self, session, data] in
            // The article must be this address's: the page under a saved copy can be another one,
            // and the page may navigate before or while the extraction runs.
            var article: ReaderArticle?
            if let page, page.url == url {
                article = try? await session.reader.article(in: page)
                if page.url != url || article?.url.map({ AddressBarSuggestions.addressKey($0) != AddressBarSuggestions.addressKey(url) }) == true {
                    article = nil
                }
            }
            let saved = await Self.savedPage(url: url, title: title, article: article)
            let ok = await data.saveForLater(saved)
            if saved.copy == nil {
                signposter.endInterval(Signposts.readingListSave, state, "link")
            } else {
                signposter.endInterval(Signposts.readingListSave, state, "copy")
            }
            if ok { Haptic.success.play() } else { Haptic.nothingThere.play() }
            if ok, self?.pageAddress == url { self?.lastPageMarks?.isSaved = true }
            if ok { self?.refreshFocusContent() }
        }
    }

    /// The page to save, with `article` encoded as its reader copy. Encoding a long article takes
    /// a few milliseconds, so it runs off the main thread.
    @concurrent
    nonisolated private static func savedPage(url: URL, title: String, article: ReaderArticle?) async -> SavedPage {
        guard let article, let copy = try? JSONEncoder().encode(article) else {
            return SavedPage(url: url, title: title.isEmpty ? nil : title)
        }
        return SavedPage(
            url: url, title: title.isEmpty ? article.title : title, siteName: article.siteName,
            excerpt: article.excerpt, copy: copy, copyLength: article.textLength
        )
    }

    func removeFromReadingList(_ url: URL) {
        Signposts.signposter.emitEvent(Signposts.readingListRemove)
        Task { [weak self, data] in
            if await data.removeFromReadingList(url: url) {
                Haptic.success.play()
                if self?.pageAddress == url { self?.lastPageMarks?.isSaved = false }
                self?.refreshFocusContent()
            } else {
                Haptic.nothingThere.play()
            }
        }
    }

    func showReadingList() {
        let list = sheets.readingList(
            onOpen: { [weak self] url in
                self?.closeSheet { self?.load(url) }
            },
            onDone: { [weak self] in self?.closeSheet() }
        )
        present(list, signpost: Signposts.readingListShow)
    }

}
#endif
