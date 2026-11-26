# State rules: which control shows when

Every control in Plain earns its place in the current state. This file says, for every state the
app can be in, which controls show, which hide, which dim, and which behave differently, and why.
The implementation follows these rules; the "Gaps" section lists where the code does not yet.

**Where the rules live in code.** `BrowserCore/ControlRules.swift` is the one place that turns a
state into shown / dimmed / hidden: `ChromeState` and `ControlRules` for the bar, the gestures,
the page menu, the tabs menu and the start screen; `GalleryState` and `GalleryRules` for the
gallery. The view code describes the state and applies the answer. `ControlRulesTests` checks
the matrix in section 8 row by row on macOS.

Owner's brief (2026-11-26): "If there are no tabs open and you have one single tab open, why
should we even show the tab switcher? Why should we even show the new tab button all over the
app? … there are many edge cases like this that need to make sense at all times to the user and
the state of the app."

## 1. Principles

1. **A control shows only when it can do something useful now.** A button that would do nothing,
   or only repeat a button next to it, is not on screen.
2. **No dead ends, no empty screens.** Every action lands somewhere useful. The only empty screens
   are ones the user asked for (an empty private list, a search with no results), and each is one
   sentence and one main button (docs/ui-reference.md).
3. **One predicate per action.** A button, its gesture and its menu item share one condition, so
   they never disagree. The tabs button, the swipe up and Show All Tabs all follow `others ≥ 1`.
4. **The same gesture always means the same thing.** When a gesture has nothing to do, it
   rubber-bands and plays the "nothing there" haptic. It never does something else instead
   (today a swipe up with no tabs opens search; that changes).
5. **Hide or dim: decide by mode.** Plain has five modes: *Start* (an empty tab), *Page*,
   *Editing* (search field open), *Gallery* and *Sheet*. Controls appear and disappear only when
   the mode changes. Inside a mode the bar keeps its shape: a control that is out of reach for a
   moment either dims (Back) or hides **in place**, keeping its slot so nothing moves under the
   thumb (Forward). The Duo's system vertical bar packs its items itself, so there nothing hides
   inside a mode; it dims.
6. **Menus hide what does not apply and dim what is at a limit.** An item that never applies to
   this kind of page (Show Reader on a page with no article, Save PDF on HTML) is left out, as
   Apple asks of context menus. An item that applies but cannot go further right now (Zoom In at
   300 %, Next Tab on the last tab) dims, so the menu keeps its shape. That second half is Plain's
   choice, closer to Apple's rule for regular menus: the page menu opens both from More (a regular
   menu) and from a long press on the pill (a context menu), and it must read the same from both.
7. **Empty tabs are never left behind.** An empty tab exists only while it is on screen. Leaving
   it (switching tabs, opening a page in another tab, the gallery) drops it with no Reopen. New Tab
   on an empty tab reuses it. The gallery therefore never shows a blank card, and the swipe never
   lands on one.
8. **At most one New Tab button on screen, and none on an empty tab.** The new-tab affordances
   are: the tabs slot as "+" when there is one tab, the gallery's "+", the card past the last tab
   (a gesture), and the tabs menu. No two of the buttons show at once. A menu item that repeats
   the button it opened from is fine.

Sources behind these choices are in section 9.

## 2. Terms used in the tables

| Term | Meaning |
|---|---|
| `start` | No tab on screen, or the tab on screen has no address and is not loading. The start screen shows. |
| `page` | The tab on screen has an address: loaded, loading, failed or crashed. |
| `others` | Open tabs besides the one on screen, regular and private together. An empty tab never counts (principle 7). |
| `list` | The tab on screen's own list (regular or private), which the bar swipe moves through. |
| `closed` | The recently closed stack holds a regular batch. |
| `archived` | The archive holds at least one tab. Needs a cheap count from Storage. |
| shown / — / dim | Shown and working / hidden (slot kept in the glass bar) / shown but disabled. |
| ≠ | Shown, but behaves differently in this state; see the note. |

## 3. The bar (Page and Start modes)

### Tabs slot (third button; the system bar's Tabs item on the Duo)

One slot, three faces. The long press always opens the tabs menu (section 5), so the slot's long
press means the same thing whatever it shows.

| State | Face | Tap | Why |
|---|---|---|---|
| `others ≥ 1` | Tabs (`square.on.square`) | Gallery | There is somewhere to switch to. |
| `others = 0`, `page` | New Tab (`plus`) | New tab, search field up | A one-card switcher is a dead end (owner). The one useful tab action is a second tab. Same slot, so no new button. |
| `others = 0`, `start` | — | — | You are already in a new tab, and there is nothing to switch to. The tabs menu's other items (New Private Tab, Reopen Closed Tab, Archived Tabs) stay in More (section 4) and show as shortcuts on the start screen, so none of them is ever out of reach. |
| Side tabs in effect (Left, Right) | Tabs | Shows or hides the sidebar | The sidebar is the tab list, so the slot toggles it rather than opening the gallery (M3 lane); the long press keeps the tabs menu, with Show All Tabs for the gallery. Reopen, Archive and private tabs stay in More. The swipe up is off: the sidebar is the switcher. The sidebar's New Tab follows principle 8 (hidden on an empty tab). |

- **The tabs items are never only behind a long press** (owner, 2026-11-26). New Private Tab,
  Reopen Closed Tab and Archived Tabs are in More's top section in every state where they apply,
  one visible tap away, and the start screen shows them as small shortcuts under the mark. The
  long press on the tabs slot is a shortcut to the same items, as Safari keeps Recently Closed
  behind a long press on its New Tab button. The Reopen toast after every close is the visible
  way back.
- **Teaching the long press: a one-time TipKit tip, no glyph on the button.** Options weighed: a
  menu indicator on the button (`UIButton.Configuration.indicator`) is the pop-up button's
  chevron, which tells the user a tap opens a menu, and here a tap does something else; it also
  breaks the bar's five equal glyphs. Safari's and Mail's toolbar buttons with long-press menus
  carry no indicator either. A one-time tip is Apple's own way to teach a hidden gesture
  (TipKit), it shows once and never again, and it costs nothing on screen afterwards. So: after
  the user has opened the gallery twice with a tap on Tabs, a popover tip over the button says
  "Touch and Hold for More"; opening the tabs menu retires it. Because every item is also in
  More, a user who never sees the tip loses nothing. Tips are off under UI tests and perf runs
  (`-Plain…` launch arguments).
- **No count badge.** docs/ui-reference.md says no badges. VoiceOver reads "3 tabs" as the value.
- **The swipe up from the bar follows the same rule.** With `others ≥ 1` it opens the gallery.
  Otherwise the page lifts a few points, rubber-bands back and plays "nothing there". It never
  opens search: the search field is one tap on the pill, and the swipe must keep one meaning.

### Every bar control

| Control | Start | Page | Hide or dim | Why |
|---|---|---|---|---|
| Back | — | shown; dim when there is nothing to go back to | Dim inside Page | The most used button, leftmost; its place is muscle memory. Safari and Arc both keep Back in reach. On Start there is no page and no history. |
| Forward | — | hidden in place until there is somewhere forward | Hide (slot kept) | Rarely available. Safari 26 shows Forward only after Back is used (MacRumors). The slot is kept, so Tabs, Share and More never move. On the Duo's vertical bar: dim. |
| Back in special pages | | Reader: closes the reader. A child tab's first page: closes the tab and returns to its opener. | | One Back for "go to what I was looking at". |
| Share | — | shown when the tab has an address | Hide on Start | Nothing to share on Start. On a failed page it shares the address that was tried. |
| More (page menu) | shown | shown | Never hidden | History, Settings and Edit Favorites apply everywhere. |
| Tabs slot | see above | see above | | |
| Pill | placeholder "Search or enter address" | host, "Not Secure —" first on http, mixed content or a passed certificate | Never hidden | The one way to search. |
| Pill long press | page menu (app items only) | page menu | | Same menu as More. |
| Progress bar | — | while loading only | Hide | ui-reference: controls show only while they apply. |
| Start screen (mark, sentence, Search button) | shown; Search only while the keyboard is down | — | | The empty state: one sentence, one button. |
| Start screen shortcuts (under the Search button) | Private Tab always (New Tab on an empty private tab); Reopen Closed Tab with `closed`; Archived Tabs with `archived`. Only while the keyboard is down. | — | | Small, quiet, one tap: the tabs items in plain sight when no switcher shows (owner). |
| Pull to refresh | off | on a loaded or loading page; off on failed and crashed pages (their Try Again / Reload owns it) and in the reader | Off | Nothing to reload on Start; a second reload control next to Try Again is noise. |
| Bar swipe sideways | to neighbours in `list` | to neighbours in `list` | Rubber-band with no neighbour | The same gesture as on a page. Leaving an empty tab drops it. |
| New Tab card past the last tab | never | when the tab has an address and is last in `list` | Not offered | Swiping past an empty tab would make a second empty tab. |
| Collapsed pill | n/a | taps only | | It sits in the home-indicator zone. |

## 4. The page menu (More, and a long press on the pill)

Order is fixed (docs/ui-reference.md). Columns are states of the tab on screen.

| Item | Start | Loading | Loaded | Failed / offline | Crashed | Reader open | Notes |
|---|---|---|---|---|---|---|---|
| Reload | — | ≠ Stop, same place | shown | shown | shown | — | Safari puts Reload/Stop in one control. In the reader there is nothing to reload. |
| Find on Page | — | shown | shown | — | — | shown (finds in the article) | Nothing to find on an error. |
| Show / Hide Reader | — | — | when readerable | — | — | Hide Reader | Safari: "Show Reader (if available)". |
| Save PDF to Files | — | — | on a PDF | — | — | — | |
| Share, Copy Link | — | shown | shown | shown (the address tried) | shown | shown (the page's address) | |
| Zoom row (− % +) | — | shown | shown; − / + dim at the ends, % dim at 100 % | — | — | — | Zoom acts on the page, which is hidden under the reader. |
| Desktop Site | — | http(s) | http(s) | http(s) | — | — | A remembered Desktop Site choice can be why a page fails, so the switch back stays (it retries the load). Under the reader it would act out of sight. |
| Turn Off / On Blocking on This Site | — | http(s), regular tabs | http(s), regular tabs | http(s), regular tabs (blocking can cause the failure) | — | — | Private tabs: hidden (the allow-list is saved to disk). |
| Add to / Remove from Favorites | — | — | recordable page | — | — | shown (the page's address) | A page that never loaded is not a favorite. |
| Open in Other Pane | — | Duo split possible | Duo split possible | — | — | — | Only where width and height are both regular (plan, section 6). |
| New Private Tab, Reopen Closed Tab, Archived Tabs (top section) | New Private Tab always (on an empty private tab it reads "New Tab": it turns this empty tab, nothing is added); Reopen Closed Tab with `closed`; Archived Tabs with `archived` | ← same | ← | ← | ← | ← | The tabs menu's other items, one visible tap away in every state (owner). Without them, closed and archived tabs could not be reached with no tab open. |
| Downloads | while any this session | ← same | ← | ← | ← | ← | Subtitle "1 in progress" while one runs. |
| History, Edit Favorites, Settings… | shown | shown | shown | shown | shown | shown | Dim only in the first moments while the database opens. |

## 5. The tabs menu (long press on the tabs slot)

| Item | Rule | Why |
|---|---|---|
| New Tab | Hidden when the tab on screen is an empty regular tab | It would reuse the tab already on screen. |
| New Private Tab | Hidden when the tab on screen is an empty private tab | Same. |
| Previous Tab / Next Tab | Shown when `list` has 2 or more tabs; each dims at its end | A pair, so it keeps its shape. Subtitles name the swipe. |
| Show All Tabs | `others ≥ 1` | Same predicate as the tap and the swipe up. |
| Reopen Closed Tab | `closed` | The way back after a close, outside the gallery too. Today only the gallery and the toast have it. |
| Archived Tabs | `archived` | Today the archive is reachable only from the gallery, so with no open tabs it cannot be reached. |
| Close Tab | `page` | Closing an empty tab does nothing useful; it goes away by itself. |

## 6. Other surfaces

### Search field (Editing mode)

| Control | Rule | Why |
|---|---|---|
| Button bar | Hidden (faded out) | The keyboard and the field take the bottom. |
| Bar gestures | Off | The field owns the touches. |
| Favorites above the keyboard | Field empty, or still showing the page's own address, and at least one favorite | With none, the strip takes no space and says nothing; Edit Favorites is in the page menu. |
| Suggestions | While typing | |
| Start screen behind | Shown on Start while the field is empty (the sheet is clear) | The mark keeps the empty field company. |
| Start screen while typing | With a query, the mark, sentence and shortcuts recede (fade, shrink to 94 %, drift up, with the snappy 0.3 spring; Reduce Motion: a crossfade) and the sheet takes the paper; cleared, or the field closed, they come back | Suggestion rows never draw over the mark (owner, 2026-11-26). The rows sit on the paper token themselves, so they read even mid-transition, in light and dark. |
| Remote suggestions | Off in private tabs | FixedChoices. |
| Tap outside the field | Closes the field. On a fresh launch this shows the start screen, never a blank page. | |

### Tab gallery (Gallery mode, reachable only with `others ≥ 1`)

| Control | Rule | Why |
|---|---|---|
| List shown first | Decided after an empty tab on screen is dropped: the list of the tab on screen if it still has tabs, else the other list. | Never open on an empty list when the other one has tabs (an empty regular tab with private pages open opens the private list, and the reverse). |
| Cards | Every tab in the list; never an empty tab (principle 7) | |
| Swipe a card up | Closes it; Reopen toast for regular tabs | |
| Closing the last card in the shown list | First match: the tab on screen still exists (it is in the other list) → the gallery opens it; the other list has tabs → the gallery switches to it; else → the search field. Never an empty gallery. The Reopen toast shows wherever this lands. | Arc: never an empty switcher. |
| Private toggle | Always | The entrance to private browsing. |
| New Tab "+" | When the shown list has tabs. In an empty list the empty state's button is the one New Tab (principle 8). | |
| Done | When the tab on screen is in the shown list; else hidden | Done returns to that tab. Tapping the background does the same. |
| More (…) | Shown when its menu has at least one item | A menu button with an empty menu is a dead end. |
| More → Reopen Closed Tab | `closed`, regular list | |
| More → Archived Tabs | `archived`, regular list | |
| More → Close All Tabs | The list has 2 or more tabs not pinned; the confirmation counts only those | With one card, its swipe or menu closes it. |
| Empty private list | "Private tabs show up here, and Plain keeps no history of them." + New Private Tab | The user chose this list; it is an intentional empty state. |
| Empty regular list (toggled to it with only private tabs open) | "Your open tabs show up here." + New Tab | Same. |
| Card menu | Open in Other Pane (Duo split possible), Copy Link and Share (card has an address), Close Tab | Context menu: hide what does not apply. |

### Toasts

| Toast | Rule |
|---|---|
| Tab closed — Reopen | After a hand close of a regular tab: the tabs menu's Close Tab, a card swipe or menu, Close All Tabs. Only when the close added a batch to the recently closed stack, and Reopen brings back exactly that batch. Never for private tabs. Never when Back closes a child tab (that is navigation). When the close leaves the gallery (the last card, Close All), the offer moves with it and shows above the search field. |
| Opened in background — Show | After Open in Background. Show is dropped if the tab closed meanwhile. |
| Download finished / failed — Show | Shows on the page or the start screen. While the gallery or a sheet is up, the newest one waits and shows when it closes (a toast over them could not open Downloads). |
| While the gallery is up | The shell's toast hides; the gallery has its own Reopen toast. |

### Sheets (Sheet mode)

| Sheet | Empty state |
|---|---|
| History | "Pages you visit show up here." Clear dims only when history is empty, not when a search finds nothing. While loading: nothing (no spinner for a local read). A failed read: one sentence, no raw error. |
| Archived Tabs | Not reachable while empty (tabs menu and gallery menu need `archived`). If the last one is deleted inside it: "No archived tabs." plus the footer. |
| Downloads | Reachable only while any exist this session. The Show in Files folder button is always there. A finished row is a button (Quick Look) with Open, Share and Show in Files in its menu. A running row shows progress and keeps its Cancel button and menu item; the row itself is not a button. A failed or cancelled row reads as inactive and is not a button. |
| Edit Favorites | "Add favorites from the page menu." |
| Every sheet | Loading a local list shows nothing (no spinner). A failed read or write says so in one sentence with Try Again, never as the empty state. A search with no results shows the system's no-results view, and actions on the whole list (Clear) stay available. Such actions dim only when the list itself is empty. |
| Settings → Clear History and Data | Confirmation first (it is destructive and broad); the row dims while it runs; a failure says so in one sentence. |
| Settings → Tab Layout | Shown only where side tabs can show (width and height both regular) and only once side tabs are built. Elsewhere it would be a choice that changes nothing. |

## 7. When states overlap

Several states can hold at once. The one higher in this list decides a control; the lower ones
apply only to what it leaves open.

1. **A system alert from the page** (a JavaScript dialog, sign-in, a permission): it takes every
   touch until answered. Nothing else changes.
2. **Sheet** (Settings, History, Archive, Downloads, Favorites): the page and its bar wait under it.
3. **Gallery**: its own bar; the page's bar, toast and gestures are off.
4. **Search field open**: the bar hides; bar gestures are off.
5. **Find on Page**: the system find bar replaces the page's bar; bar gestures are off. Pull to
   refresh follows the page underneath (off in the reader).
6. **Reader**: reader items in the page menu (§4); pull to refresh off; Back closes the reader.
7. **What the page shows**, first match wins: crashed → waiting to resend a form → failed → loading
   → loaded. Crashed and resend have one button each (Reload); failed has Try Again.
   **Stop** ends a load without an error page. Stopped before the new page committed: the tab
   stays on the page it was showing, with that page's address and controls; a tab that had no
   page goes back to Start. Stopped after commit: the partly loaded page counts as loaded, with
   its own address.
8. **Typing in a page's form** is not editing the address. The keyboard covers the bar; the bar
   comes back when the keyboard leaves. Bar gestures need the bar on screen, so they wait.

## 8. State matrix

Rows are states, columns are controls. Cells use the terms in section 2. A state not listed
combines its base state with the rows that modify it (for example, private + loading).

| State | Back | Fwd | Tabs slot | Share | More | Swipe up | Bar swipe | New Tab card | Pull to refresh | Progress | Start screen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| First run (no tabs, keyboard up) | — | — | — | — | — | off | off | — | off | — | ✓ (behind the field) |
| First run, field closed | — | — | — | — | ✓ (New Private Tab on top) | ≠ bump | ≠ rubber-band | — | off | — | ✓, Search button, Private Tab shortcut |
| No tabs, some closed or archived | — | — | — | — | ✓ (Reopen Closed Tab, Archived Tabs on top) | ≠ bump | ≠ rubber-band | — | off | — | ✓ + shortcuts |
| One empty tab, others ≥ 1 | — | — | Tabs | — | ✓ | gallery | neighbours | — | off | — | ✓ |
| One page, no others | ✓ / dim | — / ✓ | ≠ "+" | ✓ | ✓ | ≠ bump | ≠ rubber-band | ✓ | ✓ | while loading | — |
| Several tabs | ✓ / dim | — / ✓ | Tabs | ✓ | ✓ | gallery | neighbours | when last | ✓ | while loading | — |
| Private only (one private page) | ✓ / dim | — / ✓ | ≠ "+" (private) | ✓ | ✓ | ≠ bump | ≠ rubber-band | ✓ (private) | ✓ | while loading | — |
| Private + regular | ✓ / dim | — / ✓ | Tabs | ✓ | ✓ | gallery (this list) | within this list | when last in this list | ✓ | while loading | — |
| Page loading | ✓ / dim | — / ✓ | as above | ✓ | ✓, Stop | as above | as above | as above | ✓ | ✓ | — |
| Page failed / offline | ✓ / dim | — / ✓ | as above | ✓ | ✓, reduced (§4) | as above | as above | as above | off (Try Again) | — | — |
| Crashed page | ✓ / dim | — / ✓ | as above | ✓ | ✓, reduced (§4) | as above | as above | as above | off (Reload) | — | — |
| Reader open | ≠ closes reader | dim | as above | ✓ | ✓, reader items (§4) | as above | as above | as above | off | — | — |
| Find open | bar replaced by the find bar | | | | | off | off | — | as the page (off in reader) | ✓ | — |
| Waiting to resend a form | ✓ / dim | — / ✓ | as above | ✓ | ✓, reduced (§4, as crashed) | as above | as above | as above | off (Reload) | — | — |
| Typing in a page form | under the keyboard | | | | | waits | waits | — | — | ✓ | — |
| Editing the address | bar hidden | | | | | off | off | — | — | — | on Start |
| Page menu open | system menu covers | | | | | off | off | — | — | ✓ | — |
| Gallery open | page bar hidden; gallery bar instead | | | | | ≠ (gallery: swipe a card up closes it) | off | — | — | — | — |
| Archive has items / empty | | | | | | | | | | | Archived Tabs shown / hidden (§5, §6) |
| Recently closed empty / not | | | | | | | | | | | Reopen Closed Tab hidden / shown (§5, §6) |
| Downloads none / active / finished | | | | | Downloads hidden / shown "1 in progress" / shown | | | | | | toast on finish |
| Duo outer (system vertical bar) | dim when none | dim when none | per table, dim instead of hide inside Page | ✓ | ✓ | same | same | same | same | same | same |
| Duo inner, single pane | as Duo outer | | | | | | | | | | |
| Duo split | per focused pane | | | | | | | | | | Open in Other Pane shown; Close Tab acts on the focused pane |
| Side tabs, Rail or Expanded | as Page | | Tabs: shows or hides the sidebar; long press for the tabs menu | | | ≠ bump (sidebar is the switcher) | neighbours | when last | | | |
| Book pose | as the pane's state; pills and toasts avoid the fold | | | | | | | | | | |
| Phone landscape (compact height) | as Page; no side tabs | | | | | | | | | | |

Notes:
- More always carries New Private Tab on top, and Reopen Closed Tab and Archived Tabs when they
  apply (§4); the matrix names them only where they are the only way to those items.
- "✓ / dim" for Back: shown, dim when there is nothing to go back to. "— / ✓" for Forward:
  hidden in place, shown once there is somewhere forward.
- "bump": the page lifts slightly, rubber-bands back and plays the "nothing there" haptic.
- A popup or link-opened tab on its first page: Back is enabled and closes the tab, returning to
  its opener. The edge swipe back does the same, so button and gesture agree.

## 9. What Safari and Arc Search do

| Finding | Source | Used for |
|---|---|---|
| Safari's Compact bar is Back, page menu, field, Reload, More, with **no Tabs button**; the tab overview is a swipe. Compact is not offered on iPhone Duo. | [Apple: Browse the web](https://support.apple.com/guide/iphone/browse-the-web-iph1fbef4daa/ios), [Apple: Change the layout](https://support.apple.com/guide/iphone/change-the-layout-ipha9ffea1a3/ios) | A tabs button is not required on screen at all times. Plain shows it only when there are tabs to switch to. |
| Safari 26 Compact: Back only; tapping it splits into Back and Forward. "Before, there was no forward button option." | [MacRumors](https://www.macrumors.com/2025/06/23/ios-26-beta-2-safari-design-change/) (secondhand) | Forward hides until it applies. |
| Safari's page menu lists "Show Reader (if available)" and "Request Desktop Website (if available)"; Summarize "appears only if the website supports it". | [Apple: Customize Safari](https://support.apple.com/guide/iphone/customize-your-safari-settings-iphb3100d149/ios) | Menu items that do not apply are left out. |
| Safari: pull down to refresh; Reload in the bar. | [Apple: Browse the web](https://support.apple.com/guide/iphone/browse-the-web-iph1fbef4daa/ios) | Pull to refresh on pages; Reload/Stop in one place. |
| Safari: swiping past the last tab on the address bar opens a new tab. | [iPhone Life](https://iphonelife.com/content/quickest-way-to-open-new-tab-safari-your-iphone) (secondhand) | Kept, behind a card (plan, section 5), and only from a page. |
| Safari: recently closed tabs from a long press on New Tab in the overview; Close All from a long press on Done; tabs button long press has New Tab, New Private Tab, Close This Tab, Close All. | [Apple: Open and close tabs](https://support.apple.com/guide/iphone/open-and-close-tabs-iph489b9313f/ios), [Gadget Hacks](https://ios.gadgethacks.com/how-to/iphone-safari-gestures-productivity/) (secondhand) | Plain's tabs menu holds the same, plus Reopen and Archive. |
| Arc Search: the switcher button bottom-left, a menu bottom-right with "vestigial back and forward buttons", Favorite, Refresh, Zoom, Desktop Site. Back is mainly the edge swipe; swiping back on a tab's first page archives the tab. | [TidBITS](https://tidbits.com/2024/02/15/arc-gains-instant-links-tab-grouping-and-arc-search-iphone-app/), [MacStories](https://www.macstories.net/reviews/arc-search-for-iphone/) (secondhand), [Arc release notes](https://resources.arc.net/hc/en-us/articles/23528454620311) | Plain keeps a real Back button and never archives on Back (plan, section 5). |
| Arc Search launches into search with the keyboard up; a setting covers "reactivating the app with no open tabs". With no tabs the switcher cannot be reached. | [TechCrunch](https://techcrunch.com/2024/01/28/arcs-new-iphone-browser-wants-to-be-your-search-companion), [Arc release notes](https://resources.arc.net/hc/en-us/articles/23528454620311), docs/research/arc-tab-switcher.md | No tabs means the start screen, never an empty switcher. |
| HIG, context menus: "Hide unavailable menu items, don't dim them." HIG, menus: "Show people when a menu item is unavailable … appears dimmed." | [HIG: Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus), [HIG: Menus](https://developer.apple.com/design/human-interface-guidelines/menus) | Principle 6: hide what does not apply, dim what is at a limit. |
| HIG, tab bars: "Don't disable or hide tab bar buttons … makes your app's interface appear unstable." HIG, toolbars: a toolbar "can't be the only place that presents a command." | [HIG: Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars), [HIG: Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) | Plain's bar is a toolbar, not a tab bar, so it may change by mode. Positions stay fixed (slots kept), and every bar command is also in a menu. |

Not found anywhere: whether Safari shows its tabs button with one tab, what closing Safari's last
tab leaves, or Safari's empty tab overview text. The rules above do not depend on them.

## 10. Gaps in the code (audit of `dev` at 18e28cd)

Ranked by how visible and annoying each is. Format: `file:line — today → rule`. **Fixed** marks
the ones the state lane closed (2026-11-26); line numbers are from the audit, before the fix.

1. **Fixed.** `ShellUI/BrowserViewController.swift:576` — the tabs button is always shown and enabled, with
   0, 1 or many tabs → the tabs slot has three faces (§3): Tabs with `others ≥ 1`, "+" with one
   page tab, hidden on Start with nothing else.
2. **Fixed.** `ShellUI/BrowserViewController+Gallery.swift:48` and `ShellUI/TabSwipe.swift:80` — a tap or a
   swipe up with one tab opens a one-card gallery; with no tabs both open the search field → both
   follow `others ≥ 1`; otherwise the "+" tap (button) or the bump (swipe).
3. **Fixed.** `TabGalleryUI/TabGalleryViewController.swift:610` with `ShellUI/GalleryTabs.swift:81` — closing
   a private card shows the Reopen toast, and its Reopen brings back the last closed *regular*
   batch (or does nothing) → the toast shows only when the close made a batch, and reopens that
   batch.
4. **Fixed.** `ShellUI/BrowserViewController+Gallery.swift:45-50` — on Start with only private tabs open, the
   tabs button opens search, because the gallery looks only at the regular list. The private tabs
   cannot be reached → open the gallery on the list that has tabs (§6).
5. **Fixed.** `ShellUI/BrowserViewController+Tab.swift:173-178` with `BrowserCore/TabStore.swift:568` —
   closing the last private tab from the tabs menu, with regular tabs open, lands on an empty
   search field (the store looks for a replacement only in the private list) → show the regular
   tab that was selected before (the gallery already does this, `+Gallery.swift:255`).
6. **Fixed.** `ShellUI/BrowserViewController+Tabs.swift:85-90`, `ShellUI/BrowserViewController+Gallery.swift:230-237`,
   `ShellUI/EngineTabs.swift:105` — New Tab always makes a tab, even on an empty tab, and an
   empty tab you leave stays in the list, so blank start-screen cards pile up in the gallery →
   New Tab reuses the empty tab on screen; leaving an empty tab drops it (principle 7).
7. **Fixed.** `ShellUI/BrowserViewController.swift:573-579` — on Start, Back, Forward and Share show dimmed
   with nothing to act on → hidden on Start (slots kept).
8. **Fixed.** `TabGalleryUI/TabGalleryViewController.swift:599-604`, `ShellUI/BrowserViewController+Gallery.swift:254-266`,
   `TabGalleryUI/TabGalleryViewController.swift:633-640` — closing the last card, or Close All
   Tabs, goes to the search field with no Reopen offer; the undo is left in a menu → the Reopen
   toast moves with the close and shows above the search field.
9. **Fixed.** `ShellUI/TabSwipe.swift:219-222` — the New Tab card shows past the last tab even when that tab
   is empty → only when the tab on screen has an address.
10. **Fixed.** `ShellUI/BrowserViewController.swift:575` — Forward shows dimmed on every page → hidden in
    place until it applies (dim only on the Duo's system bar). Settles the open item "Back and
    Forward when unavailable" in docs/polish-backlog.md.
11. **Fixed.** `ShellUI/BrowserViewController+Tabs.swift:42-82` — the tabs menu has no Reopen Closed Tab or
    Archived Tabs, shows dimmed Previous/Next and Show All Tabs with one tab, and New Tab on an
    empty tab → §5.
12. **Fixed.** `TabGalleryUI/TabGalleryViewController.swift:653` with `ShellUI/GalleryTabs.swift:50` —
    Archived Tabs shows whenever the database is ready, even with an empty archive (opens "No
    archived tabs."), and with no tab open the archive cannot be reached at all → only when
    `archived`, in the gallery menu, the tabs menu and (on Start with nothing open) the page
    menu; needs a count from Storage.
13. **Fixed.** `ShellUI/BrowserViewController.swift:894` — no Stop: while a page loads, the menu offers
    Reload, and `Tab.stopLoading()` (`WebEngine/Tab.swift:148`) has no caller → Stop in Reload's
    place while loading.
14. **Fixed.** `ShellUI/BrowserViewController.swift:893-930` — on a failed or crashed page the menu offers
    Find, Zoom, Reader and Add to Favorites for a page that is not there → §4 (Desktop Site and
    the blocking toggle stay on a failed page: they can be the cause).
15. **Fixed.** `ShellUI/BrowserViewController.swift:925-928`, `ShellUI/BrowserViewController+Tab.swift:277-283`
    — with the reader open, the Zoom row, Desktop Site and the blocking toggle act on the hidden
    page, and Reload (and pull to refresh) reloads the reader view → hidden in the reader; pull to
    refresh off.
16. **Fixed (M3 lane):** Tab Layout shows only where side tabs can show. `FeatureUI/SettingsView.swift:33` — Tab Layout shows on every screen, and Side Tabs changes
    nothing yet → shown only where side tabs can show, once they are built (plan, section 4b).
17. **Fixed.** `WebEngine/WebViewPool.swift:185` with `ShellUI/BrowserViewController+Tab.swift:43-57` — the
    Back button closes a link-opened tab on its first page and returns to the opener, but the
    edge swipe does nothing there → the edge swipe does the same as the button.
18. **Fixed.** `ShellUI/BrowserViewController+Tabs.swift:15-17` — the bar gestures do not check whether Find
    on Page is open, so a swipe could switch tabs under the find bar (not yet seen on a device) →
    off while Find is open (§7).
19. **Fixed.** `TabGalleryUI/TabGalleryViewController.swift:477-479` — an empty list shows the empty state's
    New Tab button and the bar's "+" together → the bar's "+" hides in an empty list.
20. **Fixed.** `ShellUI/BrowserViewController+PageFeatures.swift:100-110` — a download toast can show while
    the gallery or a sheet is up (the gallery hides the toast only as it opens), where Show cannot
    open Downloads → the newest toast waits until they close.
21. **Fixed.** `TabGalleryUI/TabGalleryViewController.swift:645-668` — the gallery's More button shows even
    when its menu is empty (no closed tabs, empty archive, one card) → hidden when empty; Close
    All needs 2 or more tabs.
22. **Fixed.** `TabGalleryUI/TabGalleryViewController.swift:480` — Done shows dimmed when the shown list
    does not hold the tab on screen → hidden.
23. **Fixed.** `FeatureUI/Downloads.swift:120-121` — running, failed and cancelled rows are buttons that do
    nothing (no file yet) → only a finished row is a button.
24. **Fixed.** `TabGalleryUI/TabGalleryViewController.swift:630-632` — Close All Tabs counts pinned tabs it
    will not close. No pin control exists yet, so no one sees it today → count only the tabs it
    closes.
25. **Fixed.** `ShellUI/BrowserViewController+PageFeatures.swift:95-97` — a download start plays a haptic
    and nothing else until it ends → Downloads item says "1 in progress" while one runs.
