# What a browser shows when the address bar is focused (2026-11-27)

What each reference browser shows the moment the address bar takes focus, and two API limits:
the iOS paste alert, and counting what content rule lists blocked.

Tags: **[C]** confirmed by a source, **[I]** inferred. "(2nd)" marks a secondhand source.

## Arc Search (iOS)

From the owner's screen recording on the iPhone Duo, 2026-11-27. **[C]** [Owner recording]

- **Focus:** a tap on the bottom bar raises a dark frosted rounded sheet; the page's top shows above.
- **Field:** top of the sheet, empty, placeholder "Search…", mic and a small icon on the right.
  The current URL is not shown.
- **Rows:** one suggestion row ("A farewell to Arc", a recent page), in the same frame as the
  keyboard. Typing updates rows in place, top down: search rows with a magnifier, site rows with
  globe or favicon, title and domain. Inline completion: "nic" becomes "nicovideo.jp", selected.
- **Submit:** always a new tab; the page under the sheet stays.
- **Editing the current address:** a separate page sheet from the bottom-right control: an address
  capsule (back/forward, host centered and editable in place with inline copy, copy-link, reload);
  four captioned tiles (Find on Page, Reader Mode, Pin, Share); rows (Display Options ›, Site
  Settings); a card "Arc scrubbed 16 trackers — Problems? Tap to restore original page".
- **New tab:** the same search sheet with the keyboard up. **[C]** [TidBITS] No copied-link row,
  favorites grid or recently closed list in the sheet. **[I]**

## Safari (iOS 26/27)

- **Loaded page:** the URL shows in the field, selected; typing replaces it. **[I]**
- **Favorites on focus:** "Access your favorite websites when you search or create a new tab".
  Typing adds search engine and Safari Suggestions (open tabs, bookmarks, recent pages). **[C]** [Apple search]
- **New tab:** the start page with Favorites, Suggestions ("websites you visit most, websites
  shared in other apps"), Privacy Report, Reading List, Recently Closed Tabs and iCloud Tabs, each
  a toggle. **[C]** [Apple settings]
- **Submit:** the current tab. Inline autocompletion of the top hit, selected. **[I]**
- **Clipboard:** no copied-link row; "Paste and Go" is in the field's edit menu. Safari is
  first-party and never shows the paste alert. Placeholder "Search or enter website name". **[I]**
- No iOS 27 change to any of this was found.

## Chrome (iOS)

- **Loaded page:** URL selected; zero-state suggestions below. Submit: same tab. **[I]**
- **Current-page row (Copy, Share, Edit):** that row is Chrome for Android's. **[C]** [9to5Google
  2019] (2nd). Chromium's iOS strings have no such row, so iOS likely lacks it. **[I]**
- **Most visited:** the iOS omnibox popup has a most-visited tile carousel (`kTileNavsuggest`),
  with remove and open-in-new-tab menus. **[C]** [Chromium `omnibox_popup_mediator.mm`]
- **Copied link:** a row labelled "Link you copied" (also "Text you copied", "Image you copied").
  Chrome checks with `detectPatternsForPatterns:` (`ProbableWebURL`), shows a *blank* row, and reads
  the value with `detectValuesForPatterns:` only on use. Its comment: "accessing the clipboard
  contents shows a notification … create blank matches." **[C]** [Chromium `clipboard_provider.cc`],
  [Chromium `clipboard_recent_content_impl_ios.mm`]
- **Copied link age:** only within 10 minutes of the copy, timed from `changeCount` changes.
  **[C]** [Chromium `clipboard_recent_content.cc`]
- **Placeholder:** "Search or type URL", or "Search Google or type URL". **[C]** [Chromium
  `omnibox_strings.grdp`] Inline autocompletion: yes. **[I]**

## Firefox (iOS)

- **Focus on a page:** with recent or trending searches on, the zero-search view (Recent Searches,
  trending); otherwise the embedded homepage (shortcuts/top sites). A private tab never gets the
  zero-search view. **[C]** [firefox-ios `BrowserViewController.swift`]
- **Copied link:** opt-in. On foreground it checks `hasURLs` and `changeCount`, then shows a toast
  whose button is a `UIPasteControl`, with no URL preview. **[C]** [firefox-ios
  `ClipboardBarDisplayHandler.swift`], [firefox-ios PR 20200]
- **Paste & Go, Copy Address:** in the bar's menu. **[C]** (same file) Placeholder "Search or
  enter address"; inline autocompletion yes. **[I]**

## DuckDuckGo (iOS)

- **Focus:** the text is selected (`selectAll`). With an empty field the tray shows Favorites (if
  any); typing switches it to autocomplete. **[C]** [DDG `DefaultOmniBarViewController.swift`],
  [DDG `SuggestionTrayViewController.swift`] No copied-link row found. **[I]**

## Brave (iOS)

- **Focus overlay:** Favorites, then Recent Searches (opt-in prompt first), plus QR scan. Neither
  recent section shows in private browsing. **[C]** [Brave `TopSitesViewController.swift`]
- **Placeholder:** "Search or enter address"; "Paste and Go" in the bar. **[C]** [Brave
  `BraveStrings.swift`] No copied-link row found. **[I]**

## Orion (iOS)

- **Focus:** one tap selects the URL and shows its options; Favorites show while editing.
  **[C]** [Orion notes 1.3.14, 1.4.19]
- **Suggestions:** top hit, bookmarks, history (each can be turned off); inline completion of
  `m.`/`www.` hosts. **[C]** [Orion notes 1.3.9, 1.5.3]
- **Paste alert:** 1.3.9 "Fixed need of `Allow Paste` notification when clicking in location bar".
  New tab: a "Show Keyboard on New Tab" setting. **[C]** [Orion notes]

## API 1: the iOS paste alert

Since iOS 16, reading another app's pasteboard content without user intent shows "Allow Paste".
iOS 16.1 added a per-app "Paste from Other Apps" setting (Ask, Deny, Allow). **[C]** [Apple
UIPasteControl], [MacRumors 16.1] (2nd)

| Call | Alert? |
|---|---|
| `hasStrings`, `hasURLs`, `hasImages`, `hasColors`, `numberOfItems`, `types` | No. **[C]** [Apple UIPasteboard] |
| `detectedPatterns(for:)`, `detectPatterns…` | No: "doesn't allow the app to access the contents". **[C]** [Apple detectedPatterns] |
| `changeCount` | No. Not in Apple's list, but Chrome and Firefox poll it freely. **[I]** |
| `detectedValues(for:)`, `detectValues…` (incl. `.probableWebURL`) | Yes: "the system notifies the user". **[C]** [Apple detectedValues] |
| `string`, `url`, `items`, `data…`, `value…` | Yes, unless the user pasted. **[C]** [Apple UIPasteboard] |

- `detectValues` for `.probableWebURL` reads the value, so it prompts; Chromium's error path says
  "On iOS 16, users can deny access to the clipboard." **[C]** [Chromium `clipboard_recent_content_impl_ios.mm`]
- **`UIPasteControl`** (iOS 16): a system Paste button. A tap is user intent; its `target` gets the
  content with no alert. Nothing can be previewed before the tap, and its look is limited.
  **[C]** [Apple UIPasteControl], [firefox-ios PR 20200]
- A custom "Paste and Go" menu item that reads `UIPasteboard.general` prompts; only system paste
  (edit menu Paste, Cmd-V, `UIPasteControl`) counts as intent. **[I]** from [Apple UIPasteboard]

## API 2: counting blocked trackers

**Verdict: not available cheaply through public API.**

- Public `WKNavigationDelegate` has no content-rule-list callback. **[C]** [Apple WKNavigationDelegate]
- Apple's public rule format lists five action types: `block`, `block-cookies`, `css-display-none`,
  `ignore-previous-rules`, `make-https`. `notify` is not among them. **[C]** [Apple content blocker]
- WebKit supports `notify`, but reports it (and blocks) only through private delegate methods
  `_webView:URL:contentRuleListIdentifiers:notifications:` and
  `_webView:contentRuleListWithIdentifier:performedAction:forURL:`, whose `_WKContentRuleListAction`
  has `blockedLoad`, `notifications` and more. Private on WebKit main; absent from Apple's current
  public docs. **[C]** [WebKit `WKNavigationDelegatePrivate.h`], [WebKit `_WKContentRuleListAction.h`]
- Why: content blockers are built not to observe browsing; a per-load callback was refused and
  aggregate counts never shipped. **[C]** [WebKit bug 152598], [WebKit bug 205720]
- **Public workaround:** a `WKUserScript` that matches resource URLs against the same list and
  posts to a `WKScriptMessageHandler`, as DuckDuckGo does. **[C]** [DDG
  `ContentBlockerRulesUserScriptsTests.swift`] It costs JS on every page and counts loads seen,
  not loads WebKit blocked. **[I]**

## What Plain takes

Built as described in docs/decisions.md, "Address focus and the page sheet".

- **Empty field, not a selected URL** (Arc): a tap on the pill goes somewhere new. On a page,
  what is submitted opens a new tab; Back on its first page returns to the page. Editing the
  page's own address is a second door: the page sheet's host, or the page's row above the field,
  with the address selected and Copy inside the field; it loads in the same tab.
- **Contents, nearest the field first** (Plain's field sits above the keyboard, so Arc's top-down
  list is mirrored): Open Copied Link; the page's own row (title, host, Copy; a tap edits);
  Favorites; up to four recent pages; up to two recently closed tabs. A first run gets one
  sentence. On a new tab the page's row is left out.
- **Copied link without the alert:** `detectPatterns(for: [\.probableWebURL])` when
  `changeCount` changed, offered within 10 minutes (Chrome). The row names the address only when
  Plain copied it; otherwise it carries a `UIPasteControl`. Never `detectedValues` or `.url` before
  the tap.
- **Private tab:** no recent pages, no closed tabs; the page, the copied link and Favorites only.
- **Not taken:** inline completion (desynchronised the keyboard under fast typing; the top hit
  already sits nearest the field) and a trackers count (no cheap public API; not the SPI).

## Sources

- [Owner recording]: Arc Search on the owner's iPhone Duo, screen recording, 2026-11-27
- [TidBITS]: https://tidbits.com/2024/04/29/arc-search-iphone-app-now-syncs-arc-sidebar-tabs/
- [Apple search]: https://support.apple.com/guide/iphone/search-for-websites-iph6297b394b/ios
- [Apple settings]: https://support.apple.com/guide/iphone/customize-your-safari-settings-iphb3100d149/ios
- [9to5Google 2019]: https://9to5google.com/2019/05/13/chrome-android-share-links/
- [Chromium `omnibox_popup_mediator.mm`]: https://chromium.googlesource.com/chromium/src/+/main/ios/chrome/browser/omnibox/coordinator/popup/omnibox_popup_mediator.mm
- [Chromium `clipboard_provider.cc`]: https://chromium.googlesource.com/chromium/src/+/main/components/omnibox/browser/clipboard_provider.cc
- [Chromium `clipboard_recent_content_impl_ios.mm`]: https://chromium.googlesource.com/chromium/src/+/main/components/open_from_clipboard/clipboard_recent_content_impl_ios.mm
- [Chromium `clipboard_recent_content.cc`]: https://chromium.googlesource.com/chromium/src/+/main/components/open_from_clipboard/clipboard_recent_content.cc
- [Chromium `omnibox_strings.grdp`]: https://chromium.googlesource.com/chromium/src/+/main/components/omnibox_strings.grdp
- [firefox-ios `BrowserViewController.swift`]: https://github.com/mozilla-mobile/firefox-ios/blob/main/firefox-ios/Client/Frontend/Browser/BrowserViewController/Views/BrowserViewController.swift
- [firefox-ios `ClipboardBarDisplayHandler.swift`]: https://github.com/mozilla-mobile/firefox-ios/blob/main/firefox-ios/Client/Frontend/Browser/ClipboardBarDisplayHandler.swift
- [firefox-ios PR 20200]: https://github.com/mozilla-mobile/firefox-ios/pull/20200
- [DDG `DefaultOmniBarViewController.swift`]: https://github.com/duckduckgo/apple-browsers/blob/main/iOS/DuckDuckGo/OmniBar/DefaultOmniBarViewController.swift
- [DDG `SuggestionTrayViewController.swift`]: https://github.com/duckduckgo/apple-browsers/blob/main/iOS/DuckDuckGo/Main/SuggestionTrayViewController.swift
- [DDG `ContentBlockerRulesUserScriptsTests.swift`]: https://github.com/duckduckgo/apple-browsers/blob/main/SharedPackages/BrowserServicesKit/Tests/BrowserServicesKitTests/ContentBlocker/ContentBlockerRulesUserScriptsTests.swift
- [Brave `TopSitesViewController.swift`]: https://github.com/brave/brave-core/blob/master/ios/brave-ios/Sources/Brave/Frontend/Browser/TopSites/TopSitesViewController.swift
- [Brave `BraveStrings.swift`]: https://github.com/brave/brave-core/blob/master/ios/brave-ios/Sources/BraveStrings/BraveStrings.swift
- [Orion notes]: https://orionbrowser.com/updates/orion-iOS-release-notes
- [Apple UIPasteboard]: https://developer.apple.com/documentation/uikit/uipasteboard
- [Apple UIPasteControl]: https://developer.apple.com/documentation/uikit/uipastecontrol
- [Apple detectedPatterns]: https://developer.apple.com/documentation/uikit/uipasteboard/detectedpatterns(for:)
- [Apple detectedValues]: https://developer.apple.com/documentation/uikit/uipasteboard/detectedvalues(for:)
- [MacRumors 16.1]: https://macrumors.com/2022/10/17/ios-16-1-paste-from-other-apps-settings
- [Apple WKNavigationDelegate]: https://developer.apple.com/documentation/webkit/wknavigationdelegate
- [Apple content blocker]: https://developer.apple.com/documentation/safariservices/creating-a-content-blocker
- [WebKit `WKNavigationDelegatePrivate.h`]: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKNavigationDelegatePrivate.h
- [WebKit `_WKContentRuleListAction.h`]: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/_WKContentRuleListAction.h
- [WebKit bug 152598]: https://bugs.webkit.org/show_bug.cgi?id=152598
- [WebKit bug 205720]: https://bugs.webkit.org/show_bug.cgi?id=205720
