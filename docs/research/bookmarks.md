# Bookmarks, favorites and the reading list

Researched 2026-11-27 for v0.2 (plan §7, "Bookmarks UI, reading list"). Unverified points are
marked.

## Bottom line

Plain keeps two lists and no bookmark tree:

- **Favorites** stay the one list of kept pages: a flat, ordered grid above the keyboard and in
  the address bar. No folders.
- **Reading List** ("Read Later" in the page menu) holds pages saved to read once. Each keeps a
  reader copy of its article for offline reading, is unread until opened from the list, and
  ranks in the address bar right after favorites while unread.
- Everything else is found again through History search and the tab archive, which already
  cover "the page I saw last week".

## What the reference browsers do

| Browser | Favorites | Bookmarks | Reading list |
|---|---|---|---|
| Safari iOS | A bookmark folder shown as a grid on the start page (from memory; Apple's guide no longer says it) | Folders, reorder, "Add Bookmark to…" | Share or a link's long press, "Add to Reading List". Swipe left deletes. Offline copy only with Settings > Apps > Safari > Automatically Save Offline (off by default). iOS 27 groups related items into topics. |
| Arc Search | Favorites, no folders, no rename | None. Arc desktop: "Arc for desktop doesn't have bookmarks – we used Pinned Tabs instead." | None. Tabs archive after 12 h–30 d into a searchable archive. |
| Chrome iOS | Shortcuts on the new tab page | Folders | More > Add to Reading List. Read and unread sections, Mark Read. Saves a **distilled** (reader) copy and shows it when the live page fails or takes over a second. |
| Firefox iOS | Shortcuts | Bookmarks | Swipe to remove or mark read. Firefox 128 (July 2024) stopped showing reading list items on Home, and users report the menu entry gone; formal removal unverified. |
| Orion iOS | Favorites | Bookmarks with import and export | A reading list, synced with bookmarks. All/Unread and Save Offline documented on macOS only. |

Sources: Apple's iPhone guide (bookmarks, Reading List), Arc help "Where are Bookmarks",
MacStories and TidBITS on Arc Search, Google Chrome Help (Reading List, iOS), Chromium's
`ios/chrome/browser/reading_list` (2016–17 snapshots), Firefox iOS 128 release notes, Kagi help.

## What people use

- **Bookmarks are lightly used.** In Mozilla's 2012 survey of 5,000+ Firefox users, 73% knew
  the bookmarks menu but 36% used it; bookmarks started under 12% of page visits in an older
  study Mozilla cites; the DOBBS dataset calls them "rarely used". No published numbers on folder
  use (Mozilla asked, never published).
- **People keep pages in tabs instead:** emailing themselves and leaving tabs open topped
  Mozilla's 2012 diary study; about 30% call themselves tab hoarders (CMU, CHI 2021). Plain's
  archive already serves that habit.
- **Read-later is used, then decays.** For Pocket's 500 most-saved long reads (2015) 43% of
  savers read the piece; about 80% of reads happen within 35 days of saving. The "82% never read"
  figure has no traceable source.
- **Standalone read-later apps are gone:** Omnivore closed in November 2024, Pocket in July 2025.
  The habit now needs a home in the browser.

## Decisions

1. **No bookmark folders.** Nobody showed folders are common, Arc shipped without bookmarks, and
   Plain's History search, archive and favorites already answer "find that page again". A tree
   would add a screen, an editor and a move flow for a minority. (`FixedChoices.bookmarkFolders`)
2. **Favorites unchanged:** flat and ordered, the quick-access grid.
3. **Reading List with a reader copy, not a web archive.** Chrome's approach: the article text
   and its image links, small (a long article is tens of KB, LZFSE-compressed), opened in
   Plain's own paper reader. A web archive is heavy, breaks on script-driven pages and does not
   open in reader mode. A page with no article is saved as its link.
4. **Offline is automatic.** A saved page opens live. When the network fails it (offline, the
   site gone or not answering), its copy opens in the reader over the error, as Chrome does.
   No "Save Offline" switch: Safari's is off by default, so most Safari users have no offline
   copy at all.
5. **Unread and read.** Opening a page from the list marks it read; a swipe marks it read or
   unread. Read pages sit in their own section under the unread ones. Nothing is deleted on its
   own.
6. **Saved pages in the address bar.** Unread saved pages that match rank right after favorites
   with an eyeglasses symbol: the user saved them to come back. Read ones match as ordinary pages.
7. **Clear History and Data keeps the reading list**, as it keeps favorites and open tabs.

## Where it shows

- Page menu: "Read Later" (or "Remove from Reading List") after Add to Favorites, and Reading
  List with the app's places (History, Favorites, Settings). Where they sit is the page menu
  redesign's call (docs/decisions.md).
- Address bar: unread saved pages, with the eyeglasses symbol.
- The Reading List sheet: paper, unread then read, searchable; swipe right to mark read or
  unread, left to delete; long press for Open, Mark as Read, Copy Link, Delete.

## Offline copy technique (verified facts)

- `WKWebView.createWebArchiveData` (iOS 14+) saves the current page with its subresources:
  faithful but heavy, and script-driven pages may not work offline. A webarchive would not open in
  Safari's reader (Apple discussions thread 253720422).
- Readability (already in Plain's Reader module, Apache-2.0) gives the cleaned article as HTML
  with absolute image links. Images load from the network when online; offline the text shows
  and images are skipped.
- What Safari stores offline on iOS is undocumented (webarchives in
  `~/Library/Safari/ReadingListArchives` on macOS, per user reports).
