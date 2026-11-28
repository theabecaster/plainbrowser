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
   they never disagree. The swipe up and Show All Tabs both open the switcher whenever it has a
   card to show (`others ≥ 1`, or a page on screen), and so does the tabs button's tap: with one
   page tab all three open the switcher with its card alone, New Tab on the "+" under it (§3).
4. **The same gesture always means the same thing.** When a gesture has nothing to do, it
   rubber-bands and plays the "nothing there" haptic. It never does something else instead
   (today a swipe up with no tabs opens search; that changes).
5. **Hide or dim: decide by mode.** Plain has five modes: *Start* (an empty tab), *Page*,
   *Editing* (search field open), *Gallery* and *Sheet*. Controls appear and disappear only when
   the mode changes. Inside a mode the bar keeps its shape: a control that is out of reach for a
   moment either dims (Back) or hides **in place**, keeping its slot so nothing moves under the
   thumb (Forward). The Duo's system vertical bar packs its items itself, so there nothing hides
   inside a mode; it dims. The gallery's bar is the exception (lead, 2026-11-27, UX audit item
   10): a control it leaves out (More, Done, "+") is taken out of the row and the rest re-centre,
   since an empty slot left the row visibly off-centre. The change waits until no finger is on
   the gallery: the leaving control fades, then the others glide with a short spring.
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
8. **At most one New Tab button on screen, and none on an empty tab.** On a page the bar's "+"
   is the one (owner, 2026-11-27: "a quick way to open a new tab instead of having to open the
   tab switcher"; docs/research/new-tab.md); while the gallery is up, the gallery's "+". The
   other ways are shortcuts, not buttons: the card past the last tab (a gesture), the "+"'s long
   press (the other kind), New Tab in the tabs menu, New Private Tab in More and ⌘T. The strip
   on the inner screen has no "+" of its own, and the sidebar's New Tab shows only while the bar
   has none. The card past the last tab is a place, where the next tab would sit. A menu item
   that repeats the button it opened from is fine.

Sources behind these choices are in section 9.

## 2. Terms used in the tables

| Term | Meaning |
|---|---|
| `start` | No tab on screen, or the tab on screen has no address and is not loading. The start screen shows. |
| `page` | The tab on screen has an address: loaded, loading, failed or crashed. |
| `others` | Open tabs besides the one on screen, regular and private together, of every profile (the switcher is the way to another profile's). An empty tab never counts (principle 7). |
| `profile` | The window's profile: the profile of the regular tab last shown in the focused pane. New tabs, the bar swipe, Close All Tabs, Reopen Closed Tab, the archive and the start screen use its tabs. |
| `list` | The tab on screen's own list (regular or private), which the bar swipe moves through. |
| `closed` | The recently closed stack holds a regular batch. |
| `archived` | The archive holds at least one tab. Needs a cheap count from Storage. |
| shown / — / dim | Shown and working / hidden (slot kept in the glass bar) / shown but disabled. |
| ≠ | Shown, but behaves differently in this state; see the note. |

## 3. The bar (Page and Start modes)

### Tabs slot (third button; the system bar's Tabs item on the Duo)

One slot, two faces: Tabs, or hidden. The long press always opens the tabs menu (section 5). The
tap follows the swipe up's predicate (principle 3), so the button and the gesture never disagree.

| State | Face | Tap | Why |
|---|---|---|---|
| `others ≥ 1` | Tabs (`square.on.square`) | Gallery | There is somewhere to switch to. |
| `others = 0`, `page` | Tabs (`square.on.square`) | Gallery: this tab's card alone, centered, with the same page-to-card motion as the swipe up | Owner, 2026-11-27: "Not having a tabs button when there's only one tab is weird too — match the behavior to what dragging the URL bar up does now." Was "+" (New Tab) until then. New Tab is the bar's "+" beside it (2026-11-27, new-tab lane), with the tabs menu's New Tab and More's New Private Tab as before. |
| `others = 0`, `start` | — | — | You are already in a new tab, and there is nothing to switch to. The tabs menu's other items (New Private Tab, Reopen Closed Tab, Archived Tabs) stay in More (section 4) and show as shortcuts on the start screen, so none of them is ever out of reach. |
| Side tabs in effect (Left, Right) | Tabs | Shows or hides the sidebar | The sidebar is the tab list, so the slot toggles it rather than opening the gallery (M3 lane); the long press keeps the tabs menu, with Show All Tabs for the gallery. Reopen, Archive and private tabs stay in More. The swipe up is off: the sidebar is the switcher. The sidebar's New Tab shows only while the bar has no "+". |

- **The tabs items are never only behind a long press** (owner, 2026-11-26). New Private Tab,
  Reopen Closed Tab and Archived Tabs are in More's top section in every state where they apply,
  one visible tap away, and the start screen shows them as small shortcuts under the mark. The
  long press on the tabs slot is a shortcut to the same items, as Safari keeps Recently Closed
  behind a long press on its New Tab button. The Reopen toast after every close is the visible
  way back.
- **Teaching the long press: a one-time TipKit tip, no glyph on the button.** Kept after the
  one-tab change (2026-11-27): the long press still holds the same menu, and the button now shows
  as Tabs in more states, so the tip has more chances to be seen, not fewer. Options weighed: a
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
- **The swipe up from the bar always means the switcher.** It opens the gallery whenever the
  gallery has a card: another tab, or the page on screen (owner, 2026-11-26: "Allow users to drag
  the URL bar up when there's only one tab"). With one page tab the page shrinks into its card,
  centered as in the app switcher, with New Tab on the "+" under it (§6). Only on an
  empty tab with nothing else open (or no tab) does the page lift a few points, rubber-band back
  and play "nothing there". It never opens search: the search field is one tap on the pill, and
  the swipe must keep one meaning.

### Every bar control

| Control | Start | Page | Hide or dim | Why |
|---|---|---|---|---|
| Back | — | shown; dim when there is nothing to go back to | Dim inside Page | The most used button, leftmost; its place is muscle memory. Safari and Arc both keep Back in reach. On Start there is no page and no history. |
| Forward | — | hidden in place until there is somewhere forward | Hide (slot kept) | Rarely available. Safari 26 shows Forward only after Back is used (MacRumors). The slot is kept, so Tabs, New Tab and More never move. On the Duo's vertical bar: dim. In the inner screen's top bar Back and Forward have their own capsule, which holds only what shows and grows away from Back, so nothing else moves. |
| Back in special pages | | Reader: closes the reader. A child tab's first page: closes the tab and returns to its opener. | | One Back for "go to what I was looking at". |
| New Tab ("+", Share's slot until 2026-11-27) | — | shown on every page (loading, failed, crashed, the reader, private) | Hide on Start | On Start the tab is already a new tab. A tap opens the kind on screen with the keyboard up; a long press, the other kind. A New Tab opened from a page goes back to it when the user closes its field (a swipe down, a tap on the page, the grabber, Cancel, Escape) with nothing typed or opened (`dismissSearchSheet`, `returnFromUntouchedNewTab`), not from the gallery, and only in the same pane. Share is the page sheet's last tile (§4). |
| More (page menu) | shown | shown | Never hidden | History, Settings and Favorites apply everywhere. |
| Tabs slot | see above | see above | | VoiceOver value: the tab count, and the window's profile with two or more ("3 tabs, Work"). No badge. |
| Bar shape | beside the pill: the bar shrinks to a round glass button (More), or a capsule (Tabs and More), at the pill's trailing end, and the pill takes the rest of the row at the bottom (`ControlRules.barBesidePill`) | under the pill, full width | Changes between modes only | A full-width bar holding one button read as unfinished. Start is its own mode, so the bar may change shape (principle 5); the Duo's vertical bar packs its items itself. On a wide screen (the Duo's inner screen) the bar is the top bar in every mode: Back and Forward at the row's leading end, Tabs, New Tab and More at its trailing end, the pill between; a capsule with nothing to show (Back and Forward on Start) leaves no empty glass. |
| Pill | placeholder "Search or enter address" | host, after one quiet lead word (`PillLead`): "Reader —" while the reader is open, "Translated —" on a translated page, else "Not Secure —" on http, mixed content or a passed certificate (a private page shows the private mark and "Private" before it); on a failed page the address that was tried | Never hidden by a mode; while reading it may sink away (below) | The one way to search. |
| Pill long press | page menu (app items only) | page menu | | Same menu as More. |
| Progress bar | — | while loading only | Hide | ui-reference: controls show only while they apply. |
| Start screen (mark, sentence, Search button) | shown; Search only while the keyboard is down | — | | The empty state: one sentence, one button. With two or more profiles the sentence names the window's profile ("Start with a search or an address in Work."), so a search never starts in the wrong one unnoticed. |
| Start screen shortcuts (under the Search button) | Private Tab always ("Leave Private" on an empty private tab: it turns this tab regular); Reopen Closed Tab with `closed`; Archived Tabs with `archived`. Only while the keyboard is down. | — | | Small, quiet, one tap: the tabs items in plain sight when no switcher shows (owner). |
| Pull to refresh | off | on a loaded or loading page; off on failed and crashed pages (their Try Again / Reload owns it) and in the reader | Off | Nothing to reload on Start; a second reload control next to Try Again is noise. |
| Bar swipe sideways | to neighbours in `list` | to neighbours in `list` | Rubber-band with no neighbour | The same gesture as on a page. Leaving an empty tab drops it. |
| New Tab card past the last tab | never | when the tab has an address and is last in `list` | Not offered | Swiping past an empty tab would make a second empty tab. It commits only while armed (80 pt, `threshold` haptic; a tick if pulled back under 70 pt) and only when the finger lets go: a touch the system cancels springs back. |
| Collapsed pill | n/a | taps only | | It sits in the home-indicator zone. |

### Chrome while reading: expanded, pill, hidden

Scrolling a page moves the bar through three resting states (owner, 2026-11-27: "the URL bar
should disappear and let the user browse at some point"; research and numbers in
docs/research/scroll-chrome.md). `ChromeCollapse` and `ControlRules.chromeMayHide` hold the rules.

| State | On screen | Page inset (`obscuredContentInsets.bottom`) | Gets there | Leaves |
|---|---|---|---|---|
| Expanded | pill + button bar (Duo: pill; the system's vertical bar keeps its buttons) | the expanded chrome | the top, a reveal (below) | scrolling down: 1:1 into the pill over 56 pt |
| Pill | the small pill in the home-indicator zone, taps only | the pill | scrolling down 56 pt; a release snaps to the nearer state, or follows a clear flick | a tap or scrolling up: 1:1 back out; reading on: hidden |
| Hidden | nothing; the home-indicator strip under the focused pane takes taps | the strip only (the home indicator, at least 16 pt) | 120 pt more reading past the pill (one drag, several, or a coast), or a flick whose coast will carry that far, in one motion | any reveal |

**Reveal** (back to Expanded, whole): an upward drag of 24 pt (or 8 pt at 0.3 pt/ms), an upward
flick; a tap on the bottom edge strip; a status bar tap (it reveals and keeps the place; the next
tap scrolls to the top); the page's end reaching the screen's bottom edge (the bar does not
collapse in the last 56 pt before it, and the page rises with the bar if it rests at the very
end); the top; a new page, another tab, Find, a page's keyboard or alert, the reader; the page
becoming too short; VoiceOver or Switch Control turning on.

**Never Hidden** (the pill is still allowed, as before): Start; a page loading (the pill carries
the progress and the page may not have painted); a failed, crashed or resend page; Editing; Find;
VoiceOver or Switch Control running (the bar stays in reach, as in Chrome, Firefox and Safari); a
page shorter than two screens (the end, where the bar comes back, is already near).

The inset changes once per motion, never per frame (docs/plan.md, engine rule 4): when the bar
comes back (to the pill or expanded from further down) it changes as the motion starts, so a fixed
footer moves up in the frame the bar starts rising and the bar slides in under it; when the bar
goes away it changes as the motion ends, so the footer never sits under a bar still on screen.
The top bar on the Duo's inner screen changes no inset at all (below). Under Reduce Motion, hiding
and revealing are a crossfade.

**Compact height (an iPhone on its side).** Expanded is one bottom row: Back and Forward in a
capsule at the leading end, the pill, then Tabs, New Tab and More in a capsule at the trailing end
(the top bar's two capsules, at the bottom). The leading capsule keeps both slots and the pill a
fixed place, so Forward coming and going hides in place and moves nothing. Pill and Hidden are as above: the capsules drop and fade, the pill shrinks
into the home-indicator zone, then sinks away. The start screen keeps its own row (More beside the
pill); editing lifts the pill above the keyboard, full width, as everywhere.

**Duo inner screen (top bar).** Two of the three states drive the top bar: under it the chrome
never hides, because the slim band is the page's top boundary while reading (owner, 2026-11-27:
"I like that Safari leaves the URL text field there in a smaller version, with just the shrunken
base URL, and that sets a boundary there"; docs/research/safari-duo-top.md).

| State | On screen | Page's top |
|---|---|---|
| Expanded | a glass band across the pages from the top edge to under the row (and the strip, from the second tab), with the floating capsules on it: Back/Forward, the pill, Tabs/New Tab/More | a fresh page's first line starts under the band (`contentInset.top`, the expanded band's bottom); it scrolls under the glass |
| Pill (reading) | the band's bottom rises to the status row's (73 pt on the device); the pill's text shrinks into the site's host ("apple.com", no "www.") on the status row, clear of the status items; the capsules and the strip rise and fade | the band's bottom |

- The page's obscured top (`obscuredContentInsets.top`) is the collapsed band's bottom in both
  states: a fixed or sticky header rests under the band mid-page and never moves when the bar
  collapses or comes back. Whatever WebKit paints above such a header is behind the glass.
- Gets to Pill and back as on every screen: 1:1 with the finger over 56 pt, a release snaps to the
  nearer state or follows a clear flick; any reveal brings Expanded back with one interruptible
  spring. A tap anywhere on the collapsed band is a reveal; a status bar tap brings the bar back
  as the page scrolls to its top (no slim band over a page top); VoiceOver reads the collapsed band as
  the address (a double tap shows the toolbar).
- Hidden is never reached under a top bar. A bar the outer screen left hidden rests at Pill when
  the Duo unfolds.
- With two or more tabs (Tab Layout Above) the strip starts 10 pt under the status items and the
  band reaches under it (117 pt on the device); with one tab there is no strip and the band is
  the row's (73 pt). The strip (and the band under it) shows while the page's top is in view
  and goes as the page scrolls the strip's height; mid-page the bar comes back without it, so it
  never covers a fixed header resting at the band's bottom.
- Find and the gallery fade the band with the capsules: an empty band never stays at the top.
  Editing keeps it (the field widens in its row on the band).
- Under a full-width status bar (iPad-size windows) the band runs from the top edge to under the
  row; while reading it is the status bar plus a 30 pt host row.

## 4. The page sheet (More, and a long press on the pill)

Order is fixed (docs/ui-reference.md, "Page sheet"). Columns are states of the tab on screen.
Layout: the address row first (Back and Forward, dimmed at a limit; the host, a tap edits the
address, with the window's profile under it once there are two or more ("Work", and "Not
Secure" after it on an http page); Copy Link; Reload, or Stop (`stop.circle`, never an X, which
reads as closing the sheet) while loading); then at most four captioned tiles: Find on Page, Show Reader,
Translate Page (or Show Original, captioned "Translated"), and Share last; a tile whose mode is on (Hide Reader, Show Original) shows in the accent; then keeping the page as one captioned row:
Add to Favorites, Read Later (Remove from Reading List once saved) and Site Settings (a menu when
two or more of Desktop Site, blocking, cookie banners and Dark Pages apply; a choice there closes
the sheet); then Zoom (− % +), Save PDF to Files, the pane items, Downloads; then the tabs items
(New Private Tab, Reopen Closed Tab, Archived Tabs) as captioned chips when two or more apply,
and History, Reading List, Favorites and Settings as a row of four. Print and
Save as PDF are in the share sheet (Share), as in Safari and Chrome. The whole sheet fits the
Duo's outer screen. Without a page (the start screen) it holds the rows from the pane items on.

| Item | Start | Loading | Loaded | Failed / offline | Crashed | Reader open | Notes |
|---|---|---|---|---|---|---|---|
| Reload | — | ≠ Stop, same place | shown | shown | shown | — | Safari puts Reload/Stop in one control. In the reader there is nothing to reload. |
| Find on Page | — | shown | shown | — | — | shown (finds in the article) | Nothing to find on an error. Where the side pane can show (the inner screen), it opens the pane's Find (a list of matches beside the page); with the reader open, the find bar. |
| Show / Hide Reader | — | — | when readerable | — | — | Hide Reader | Safari: "Show Reader (if available)". |
| Summarize Page | — | — | when readerable, in a language the user reads, and the on-device model can run | — | — | shown (summarizes the article), same language rule | A tile with Find and Reader ("Summarize"), before Share; Translate takes that place on a foreign page. Not on a foreign page: the summary would be in the page's language, Translate Page is what helps, and a fourth item in the row would push the menu off the Duo's outer screen. Left out, never dimmed, where the model can't run (ineligible phone, Apple Intelligence off, model not ready, language not supported): it appears by itself once the model is ready. A page Reader can't read has no article to summarize. Private tabs: shown; nothing is saved. Opens the summary sheet (§6, Sheets). |
| Save PDF to Files | — | — | on a PDF | — | — | — | |
| Translate Page / Show Original | — | Show Original while translated | Translate Page when the page's language is one the user doesn't read and the device can translate it; Show Original while translated | — | — | — | Subtitled with the pair ("French to English"), "Translating…" while the first text is on its way. The tab keeps translating its next pages in that language until Show Original. Under the reader it would act out of sight. One toast the first time ever a foreign page shows, then only the menu. |
| Print, Save as PDF (share sheet) | — | — | shown (http(s) or a PDF; Save as PDF not on a PDF, which has Save PDF to Files) | — | — | shown (prints the article) | In the share sheet as Plain's own actions, wherever Share opens it (page menu, the inner screen's Share button). Nothing finished to print while loading; an error page is Plain's message, not the site's. |
| Share, Copy Link | — | shown | shown | shown (the address tried) | shown | shown (the page's address) | |
| Zoom row (magnifier −, %, magnifier +) | — | shown | shown; − / + dim at the ends; the % always in ink, a tap resets it, no tap at 100 % | — | — | — | Zoom acts on the page, which is hidden under the reader. VoiceOver hears the row as "Zoom". |
| Desktop Site (checked while on) | — | http(s) | http(s) | http(s) | — | — | A remembered Desktop Site choice can be why a page fails, so the switch back stays (it retries the load). Under the reader it would act out of sight. Site Settings' items are named for the thing they control and checked while it is on; a tap switches it (clarity audit 20). |
| Content Blocking (checked while on) | — | http(s), regular tabs | http(s), regular tabs | http(s), regular tabs (blocking can cause the failure) | — | — | Private tabs: hidden (the allow-list is saved to disk). |
| Cookie Banner Blocking (checked while on) | — | http(s) | http(s) | — | — | — | In Site Settings. Applies by reloading. Private tabs: shown, kept for the private session only. Off for a site stops answering its banner; the cookie list's hiding follows the blocking switch. |
| Dark Pages (checked while on) | — | as Loaded | Only while Plain is dark: checked while Plain darkens the page, unchecked while the user has it off for this site | — | — | — | Hidden in a light app (it would change nothing), on pages with their own dark design (nothing to turn off), on error pages and under the reader. Applies at once, no reload. Private tabs: shown, kept for the private session only. |
| Site permissions (Camera, Microphone, Location, Motion) | — | as Loaded | In Site Settings, only the permissions this site asked for, each with its value: Allowed (checked), Not Allowed, Off in Settings (iOS has it off for Plain: a tap opens Settings), Restricted (Screen Time: dimmed) | — | — | — | Read when the page commits, so the menu lists them at once. Allowed and Not Allowed switch with a tap; taking one back reloads the page. A site that asked while the feature was off for Plain (WebKit refused it, nobody was asked) still gets its row, Off in Settings, for the session. A site that never asked has no row. Private tabs: their own answers, for the private session only. |
| Add to / Remove from Favorites | — | — | recordable page | — | — | shown (the page's address) | A page that never loaded is not a favorite. |
| Read Later / Remove from Reading List | — | — | recordable page | — (≠ its saved copy opens instead, below) | — | shown (the page's address; on a saved copy: Remove) | Same predicate as Add to Favorites (`ControlRules.readLater`). Saves the article as a reader copy when the readerable check said yes, else the link. Follows Add to Favorites. |
| Saved copy (reader over the error) | — | — | — | when the failed page is in the reading list with a copy and the failure is the network's (offline, host not found, not answering, timed out; not a certificate error) | — | it is the reader | Automatic, no switch (`ControlRules.opensSavedCopy`). Back or Hide Reader shows the error and Try Again. |
| Open in Other Pane | — | Duo split possible | Duo split possible | — | — | — | Only where width and height are both regular (plan, section 6). Not while the side pane is open (it holds the second pane's place). |
| Swap Panes, Close Pane | while a split shows | ← same | ← | ← | ← | ← | Not while the side pane covers the second pane. |
| Show / Hide Side Pane | where the side pane can show | ← same | ← | ← | ← | ← | The top bar's screens only (the Duo's inner screen, both size classes regular). Hide while it is open. Start screen too: History is useful there. |
| New Private Tab, Reopen Closed Tab, Archived Tabs (top section) | New Private Tab always (on an empty private tab it reads "Leave Private": it turns this empty tab regular, nothing is added); Reopen Closed Tab with `closed`; Archived Tabs with `archived` | ← same | ← | ← | ← | ← | The tabs menu's other items, one visible tap away in every state (owner). Without them, closed and archived tabs could not be reached with no tab open. |
| Downloads | while any this session | ← same | ← | ← | ← | ← | Subtitle "1 in progress" while one runs. |
| Reading List | shown | shown | shown | shown | shown | shown | Above the History row. Always there, like History: its empty state says how to fill it. Dims while the database opens. |
| History, Favorites, Settings | shown | shown | shown | shown | shown | shown | Dim only in the first moments while the database opens. History opens in the side pane where the pane can show, a sheet elsewhere. |

## 5. The tabs menu (long press on the tabs slot)

| Item | Rule | Why |
|---|---|---|
| New Tab | Hidden when the tab on screen is an empty regular tab | It would reuse the tab already on screen. |
| New Private Tab | Hidden when the tab on screen is an empty private tab | Same. |
| Previous Tab / Next Tab | Shown when `list` has 2 or more tabs; each dims at its end | A pair, so it keeps its shape. Subtitles name the swipe. |
| Show All Tabs | `others ≥ 1`, or a page on screen (with the sidebar on screen: `others ≥ 1`, which it always is there) | Same predicate as the swipe up. |
| Reopen Closed Tab | `closed` in the window's profile | The way back after a close, outside the gallery too. Another profile's close never comes back here. |
| Archived Tabs | `archived` | Today the archive is reachable only from the gallery, so with no open tabs it cannot be reached. |
| New Window | where a new window can open (both size classes regular and the app may have several scenes: the Duo's inner screen) | The system has no New Window button on iPhone; the outer screen takes no new windows. |
| The other windows (one item each: the page it shows, its tab count) | another window exists (connected or in the app switcher) | iPhone has no window list (iPad's Show All Windows); a tap brings that window forward. |
| Close Tab | `page` | Closing an empty tab does nothing useful; it goes away by itself. |
| Close All Private Tabs | A private tab on screen and 2 or more private pages in `list` | Ends private browsing in one step, where Safari and Chrome keep Close All. With one, Close Tab does it. The screen goes to the regular tab seen last, else the search field. |

## 6. Other surfaces

### Side pane (the inner screen)

| Control | Rule | Why |
|---|---|---|
| The pane | Only where the top bar is (both size classes regular, page ≥ 640 pt). Folding to the outer screen hides it; unfolding brings it back. | Beside a phone-width page it would leave no page. |
| Reader / Find / History picker | Always, in the pane's header. The selected segment carries its word beside its symbol; the others are symbols, each named for VoiceOver | The pane's three places, one tap apart; the word says where you are without a guess. |
| Close (×) | Always | The pane closes from itself too, not only from More. |
| Reader | The focused page's article; "This page has no article to read." when the page's check says no; "Open a page to read it here." on Start | One sentence, no dead end. |
| Find | Field, count ("12 matches"), list; "Type to find on this page." before typing; "No matches" | Return goes to the next match. Marks come off when the pane closes or the section changes. |
| History | The History screen without Done | The pane has its own close. |
| Edge swipe from the trailing edge | Opens it where it can show and it is closed | Takes the edge from WebKit's swipe forward there; Forward stays in the top bar. |
| Swipe toward the edge on the pane | Closes it | Same direction as it came in. |


### Search field (Editing mode)

| Control | Rule | Why |
|---|---|---|
| Button bar | Hidden (faded out) | The keyboard and the field take the bottom. |
| Bar gestures | Off | The field owns the touches. |
| Favorites under the field | Field empty, or still showing the page's own address, and at least one favorite | With none, the strip takes no space and says nothing; Favorites is in the page sheet. |
| Rows before typing (top down under the field, nearest first) | Open Copied Link (a web address on the pasteboard, offered once, within 10 minutes, never the page on screen); the page's own row (search over a page: title and host, Copy, a tap edits the address); up to 4 recently visited pages (regular tabs; never the page on screen, a favorite or a closed tab's page); up to 2 recently closed tabs (regular tabs); unread Reading List pages (up to 2); one sentence, "Pages you visit and your favorites show up here.", while nothing is kept yet (no recent, closed or unread pages, no favorites, no copied link; not on the start screen, which has its own) | Never an empty field (owner, 2026-11-27: "it just looks empty"). Everything is already in memory, so it shows in the frame the keyboard starts. Private tabs show no history: only the page, a copied link, favorites and a sentence that says Plain keeps none. |
| The sheet | The pill grows into a paper card over the dimmed page: its top at 18.7% of the height (right under the safe area on a screen under 560 pt tall), the field 16 pt under its top, the rows top down under the field, the card to the bottom edge behind the keyboard. Under a top bar the field stays in the bar and the card grows down from it. | Arc Search's sheet, measured (docs/research/arc-address-expand.md); the page stays sharp above it as the place to go back to (owner, 2026-11-27: the field at the top when expanded). |
| The field's options (trailing end of the field) | Empty field: the microphone (dictation on the phone; only where on-device speech recognition runs) and Browse for Me (binoculars; only where the model runs). Typed in: the system's clear button. The page's own address, untouched: Copy. Dictating: the microphone, filled, until it stops. | Arc Search's field: options while empty, × once typed. Each shows only where it can act. |
| Browse for Me armed | A tap on the field's binoculars arms it: the button turns Lagoon and stays while typing, the placeholder reads "Ask Browse for Me", and Return browses for a text that would search (an address still opens). A second tap, or closing the field, takes it back. | In an empty field there is nothing to browse for yet; armed, Return does it. What Return will do is always in sight. |
| The way out | The handle at the sheet's top (a tap closes; it marks the swipe), a swipe down on the sheet or the field (follows the finger; collapses past 28% or on a flick, else springs back), a tap on the dimmed page. Under a top bar: Cancel beside the field, and a tap on the dimmed page. | Arc shows none and the owner could not find Plain's (2026-11-27). One visible, quiet affordance per layout, plus the gestures it names. |
| Suggestions | While typing; a recent row that is also a suggestion keeps its row | |
| Start screen behind | Shown on Start, dimmed, above the sheet | The same sheet everywhere; the start screen is the place a tap outside goes back to. |
| Start screen while typing | With a query, or rows of the field's own, the mark, sentence and shortcuts recede (fade, shrink to 94 %, drift up, with the snappy 0.3 spring; Reduce Motion: a crossfade); cleared, or the field closed, they come back | Suggestion rows never draw over the mark (owner, 2026-11-26). The rows sit on the paper token themselves, so they read even mid-transition, in light and dark. |
| Search over a page (a tap on the pill) | The field opens empty over the veiled page; a submitted search or address opens a new tab whose opener is the page (Back on its first page closes it and shows the page); dismissing creates nothing. On the start screen it loads in place. | Arc's "go somewhere new": the page being read is never replaced by a stray search (owner, 2026-11-27). |
| Edit the page's address (the page sheet's host, or the page's row) | The field shows the address, selected, with Copy inside it while untouched; Return loads in the same tab | The second door, for changing this page. |
| On the search engine's results page | The pill shows the query; a tap brings it back selected and a new query replaces the results in the same tab | Safari: refining a search is not going somewhere new. |
| Remote suggestions | Off in private tabs | FixedChoices. |
| Browse for Me (the row right under the field) | Its place opens with the first keystroke where the on-device model can run, and stays while there is text; the row shows in it while the text would search (`AddressBarInput.search`) and fades out in place while it is an address. Before typing there is no place: the focused field's own rows (the page, a copied link, reading list, recents) sit right on the field | Arc Search's button beside Go. The place opens when the focused rows give way to suggestions anyway, then holds, so the suggestions never move while typing (principle 5). Without the model the place is not there and nothing says why (§4, Summarize Page). Private tabs: shown; it leaves nothing behind. |
| The handle, a tap on the dimmed page, or a swipe down on the sheet | Closes the field. On a fresh launch with no tab this shows the start screen, never a blank page; over a last tab it shows the tab. | Arc Search's swipe down back to the tab. |
| Fresh search over a page | The page shows sharp and dimmed above the sheet; the field starts empty with favorites; a submitted search opens a new tab, so the page stays as it was. Lasts until the field closes. | The tab is visibly still there, one swipe away (owner, 2026-11-27). |

### Launch and return

What Plain opens to (`BrowserCore/LaunchRules.swift`; research in docs/research/launch.md). "Away"
is the time since the app last left the foreground; "long" is `FixedChoices.freshSearchAfter`
(4 hours, Chrome's and Firefox's line).

| Situation | Opens to | Why |
|---|---|---|
| Cold launch, no tab (first run, all closed) | Search, keyboard up, start screen behind | Nothing to go back to. |
| Cold launch, a last tab, away < 4 h | **The last tab**: its saved picture at full size on the first frame, the bar resting with the tab's address and buttons, no keyboard. The live page restores under the picture, which fades once the page has loaded (at most 3 s); a drag uncovers it at once. | Safari, Chrome and Firefox reopen the page being read; the first frame never looks empty. |
| Cold launch, a last tab, away ≥ 4 h | **Fresh search over the last tab**: keyboard up, empty field, the tab's picture behind a paper veil. Swipe down or tap outside: the tab, as it was. | Arc Search's sheet over the tab; Chrome's new tab after 4 hours. |
| Cold launch, a link from another app | The link's page | A link always wins. |
| Cold launch, the last screen was private, a split, the reader or the start screen | Search, keyboard up; the restored tab, if any, shows through the frost behind it | No picture is kept of private pages; a split or the reader restores differently from its picture. |
| After private browsing, any launch | Out of private: private tabs are never kept, so the regular tab (or the start screen) comes back with the regular chrome | The private look never outlives the private tabs. |
| Return from the background, away < 4 h | Exactly where the user left off | |
| Return, away ≥ 4 h, a page on screen | Fresh search over the page | As cold launch. |
| Return, away ≥ 4 h, the start screen | Search, keyboard up | |
| Return, away ≥ 4 h, but the gallery, a sheet or the field is open, or the page plays media, is fullscreen or downloads | Exactly where the user left off | The user is in the middle of something (Chrome leaves its tab grid alone too). |

While the picture stands in (before the saved session is read), the bar follows the saved tab:
its address, Back and Forward, the tabs slot; nothing in the bar moves when the live page arrives.

### Launch splash

A cold launch opens with the chosen app icon's world (its field, the mark in its colors) and a
dive through the P's counter into the app (`FeatureUI/Splash`, `SplashGate`; docs/decisions.md,
"Launch splash: through the P"). The app is whole underneath from its own first frame: the table
above still says what it shows, and the splash only covers it.

| Situation | Splash | Why |
|---|---|---|
| Cold launch from the Home Screen or the app switcher (the app was not running) | Plays: the icon's world from the first frame, then the dive (0.66 s); on a search-first launch the keyboard rises as the dive lands | The owner: "for the startup." |
| First run | Plays; the dive opens onto the intro | The intro comes after the splash. |
| Cold launch by a link from another app, a widget, a shortcut, a Spotlight result or Handoff | None | A link always wins: the page comes first. |
| Return from the background (the app still running), however long away | None | Not a startup; the user is where they left off. |
| A second window (Open in New Window), or a scene the system makes later | None | Once per launch. |
| A touch anywhere, typing, a link arriving, the screen rotating or folding | Ends at once (a 0.12 s fade); the touch that ended it does nothing else, the next goes to the app | A tap on what cannot be seen must not act on it. |
| The app leaves the foreground while it plays, or was launched in the background and never came forward | Gone at once, nothing drawn in the background; no splash when it comes forward later | That is a return, not a startup. |
| Reduce Motion | The icon's world, then a 0.2 s crossfade to the app; no dive | The motion table's rule. |
| An isolated test run | None, unless `-PlainSplash` is given | Hundreds of UI tests launch the app; the perf launch tests and the splash's own tests pass it. |

The splash follows the Home Screen icon as it is (`AppIcons.current`) and the system's light or
dark, like the icon and the launch screen under it, not the app's own Appearance setting. Dawn
has dark art; Night, Coral and Paper look the same in both.

### Tab gallery (Gallery mode, reachable with a card to show: `others ≥ 1`, or a page on screen)

| Control | Rule | Why |
|---|---|---|
| List shown first | Decided after an empty tab on screen is dropped: the list of the tab on screen if it still has tabs, else the other list. With neither, the list of the profile used last. | Never open on an empty list when the other one has tabs (an empty regular tab with private pages open opens the private list, and the reverse). |
| Profile switcher (a capsule over the cards: the shown profile's name and a chevron) | Two or more profiles, a regular list. Its room stays reserved over the private list, so the cards never move. | Profiles, no tab groups (docs/decisions.md). With Personal alone there is nothing to switch to. |
| Switcher menu | The profiles, the shown one checked; New Profile (until six); Rename Profile; Delete Profile (never for Personal) | Options on the object. Picking a profile lists its tabs; the window's profile changes only when one of them (or New Tab there) opens. |
| More → New Profile | Personal is the only profile, regular list | From the second profile on it is in the switcher's menu. |
| Delete Profile | One confirmation that counts the open tabs and names what goes (archived tabs, history, favorites, logins and site data) and says it can't be undone | Destructive and broad (docs/ui-reference.md, Confirmations). Its tabs close without a Reopen: their data is gone. |
| Empty profile list | "Tabs in Work show up here, with Work's own logins and history." + New Tab | A new profile's list says whose it is and what is separate. |
| Cards | Every tab in the list; never an empty tab (principle 7) | |
| Lone card | When the shown list has exactly one card: it rests centered (cascade and grid); New Tab is the "+" in the bar under it. No New Tab card (removed 2026-11-27, owner: "there's already a simple button under all the tabs, so just remove the fake tab that says New Tab"). | The app switcher with one app shows one centered card; the "+" is always in the bar. |
| Swipe a card up | Closes it; Reopen toast for regular tabs | |
| Close button (×) on a card | Every card with at least half of it uncovered (grid, Duo inner columns, the front card of the cascade and the focused one with the next card over its trailing edge; the × then sits at the edge of the part that shows); hidden on a card the next one covers more than that. Private cards wear the private plate. | Owner, 2026-11-27: "tabs should have a close button besides the close gesture too." Same close as the swipe and the menu: same motion, same Reopen toast. The gesture stays the fast way; the button is the discoverable one. |
| Closing the last card in the shown list | First match: the tab on screen still exists (it is in the other list) → the gallery opens it; the other list has tabs → the gallery switches to it; else → the search field. Never an empty gallery. The Reopen toast shows wherever this lands. | Arc: never an empty switcher. |
| Private \| Tabs switch | Always: two named sides, Private leading, each with its count (none at zero); the shown side filled (violet for Private, light for Tabs). The counts drop before the bar outgrows the screen, never the words. | The entrance and the exit of private browsing, one tap each, named (NN/g: label the modes, show the active one). Tapping the shown side does nothing. |
| New Tab "+" | When the shown list has tabs. In an empty list the empty state's button is the one New Tab (principle 8). | |
| Done | When the tab on screen is in the shown list; else hidden | Done returns to that tab. Tapping the background does the same. |
| More (…) | Shown when its menu has at least one item | A menu button with an empty menu is a dead end. |
| More → Reopen Closed Tab | `closed`, regular list | |
| More → Archived Tabs | `archived`, regular list | |
| More → Close All Tabs | The regular list has 2 or more tabs not pinned; the confirmation counts only those. In the private list it reads "Close All Private Tabs" and shows with any card | With one regular card, its swipe or menu closes it. Only the shown profile's tabs. Private: where people expect to end private browsing; nothing comes back. |
| Empty private list | "Private tabs show up here, and Plain keeps no history of them." + New Private Tab | The user chose this list; it is an intentional empty state. |
| Empty regular list (toggled to it with only private tabs open) | "Your open tabs show up here." + New Tab | Same. |
| Card menu | Open in Other Pane (Duo split possible), Copy Link and Share (card has an address), Close Tab | Context menu: hide what does not apply. |

### Toasts

| Toast | Rule |
|---|---|
| Tab closed — Reopen | After a hand close of a regular tab: the tabs menu's Close Tab, a card swipe or menu, Close All Tabs. Only when the close added a batch to the recently closed stack, and Reopen brings back exactly that batch. Never for private tabs. Never when Back closes a child tab (that is navigation). When the close leaves the gallery (the last card, Close All), the offer moves with it and shows above the search field. |
| Showing your saved copy. — Try Again | When a saved page's copy opens in the reader after a network failure. Try Again closes the reader and loads the page. Once per failure. |
| Opened in background — Show | After Open in Background. Show is dropped if the tab closed meanwhile. |
| Download finished / failed — Show | Shows on the page or the start screen. While the gallery or a sheet is up, the newest one waits and shows when it closes (a toast over them could not open Downloads). |
| While the gallery is up | The shell's toast hides; the gallery has its own Reopen toast. |
| Camera / Microphone / Location is off for Plain — Settings | The page on screen asked for a feature iOS has off for Plain (WebKit denied it without asking). Once per site until the switch changes, in memory only; never right after the user said no in iOS's own prompt (that page was already loaded without the watch). "Location Services are off" when they are off for the phone. Screen Time: "… is restricted", no button. Never for background tabs. |
| Saving to Photos is off for Plain — Settings | Save Image while Photos is off for Plain: every time (the user's own action), with the "nothing there" haptic. Screen Time: no button. |
| Passkeys aren't available in Plain yet. Use your password. | A page on screen asked for a passkey and Plain refused it (no web-browser entitlement yet, so WebKit would too). Once per site per launch; never for silent (conditional) requests or background tabs. Gone once `FixedChoices.passkeysEnabled` is on. |

### Sheets (Sheet mode)

| Sheet | Empty state |
|---|---|
| History | "Pages you visit show up here." and nothing else: an empty History has no search field and no Clear (nothing to search or clear). A search that finds nothing keeps both. While loading: nothing (no spinner for a local read). A failed read: one sentence, no raw error. |
| Archived Tabs | Not reachable while empty (tabs menu and gallery menu need `archived`). If the last one is deleted inside it: "No archived tabs." plus the footer. |
| Downloads | Reachable only while any exist this session. "Show in Files" is a labelled row under the files (the folder symbol and its words, in the accent). A finished row is a button (Quick Look) with Open, Share and Show in Files in its menu. A running row shows progress and keeps its Cancel button and menu item; the row itself is not a button. A failed or cancelled row reads as inactive and is not a button. |
| Favorites | "Tap (More's symbol) on a page, then Favorite." A tap on a row opens the favorite in the tab, as History's rows do. Swipe right Rename, swipe left Delete; the row's menu has Open, Rename, Copy Link and Delete; Edit (in the header, while there are favorites) shows the reorder handles, and its Done ends the editing. Edit Favorites on the favorites above the keyboard opens it editing. The footer: "Swipe right to rename, left to delete. Tap Edit to reorder." |
| Reading List | "Tap (More's symbol) on a page, then Read Later." Unread rows first, then a "Read" section; each section shows only with rows. Tap opens the page (marks it read); swipe right Mark Read / Mark Unread, swipe left Delete, no confirmation. Search with no results: the system's no-results view. |
| Summary (Browse for Me, Summarize Page) | Never empty: it opens on what it is doing ("Searching Google…", the sites being read with each one's state, "Writing from 4 pages…"), then the summary streams in. One Done; a swipe down or Done stops everything at once. A failure is one sentence of Plain's (no results, none readable in time, offline, declined, language, busy) with Try Again where a second try can help, or Search Instead for Browse for Me. The model going away while a summary is on its way (read on each return to the app) ends it with "Apple Intelligence isn't available right now."; a finished summary stays. A source opens in a new tab with the summary kept behind it: Back on that tab's first page closes it and brings the summary back. Its menu opens a source in the background. |
| Every sheet | An empty list shows its symbol and one sentence in the ink's secondary step, body text (`PaperEmptyState`), never the system's bold black title. Loading a local list shows nothing (no spinner). A failed read or write says so in one sentence with Try Again, never as the empty state. A search with no results shows the system's no-results view, and actions on the whole list (Clear) stay available. An empty list shows its empty state alone: no search field, no Clear. |
| Settings → Clear History and Data | Confirmation first (it is destructive and broad); the row dims while it runs; a failure says so in one sentence. |
| Settings → Appearance | Always shown and enabled: it applies on every screen. Its footer is one sentence for the current choice. |
| Settings → Tab Layout | Shown only where side tabs can show (width and height both regular) and only once side tabs are built. Elsewhere it would be a choice that changes nothing. |
| Settings → App Icon, and the intro's icon step | Shown only where the icon can change (`AppIconSupport`: `supportsAlternateIcons`, and not an iPhone app on a Mac, whose Dock icon can't change). Elsewhere the row is not in Settings and the intro goes from What's inside straight to the blocking demo, its step rings one fewer. Decided from the capability, never the device model. |

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
   → loaded. Crashed and resend have one button each (Reload); failed has Try Again. Failed for
   want of the network while cellular data (or Wi-Fi) is off for Plain: "Cellular data is off for
   Plain." with Open Settings, and Try Again under it; turning it back on reloads the page.
   **Stop** ends a load without an error page. Stopped before the new page committed: the tab
   stays on the page it was showing, with that page's address and controls; a tab that had no
   page goes back to Start. Stopped after commit: the partly loaded page counts as loaded, with
   its own address.
8. **Typing in a page's form** is not editing the address. The keyboard brings the whole bar
   back (from the pill or hidden), then covers it; the bar
   comes back when the keyboard leaves. Bar gestures need the bar on screen, so they wait.

## 8. State matrix

Rows are states, columns are controls. Cells use the terms in section 2. A state not listed
combines its base state with the rows that modify it (for example, private + loading).

| State | Back | Fwd | Tabs slot | New Tab | More | Swipe up | Bar swipe | New Tab card | Pull to refresh | Progress | Start screen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| First run (no tabs, keyboard up) | — | — | — | — | — | off | off | — | off | — | ✓ (behind the field) |
| Launch with a last tab, picture standing in | as the saved tab | as the saved tab | as the saved tab | ✓ | ✓ | waits for the tab | waits for the tab | — | off | — | — |
| First run, field closed | — | — | — | — | ✓ (New Private Tab on top) | ≠ bump | ≠ rubber-band | — | off | — | ✓, Search button, Private Tab shortcut |
| No tabs, some closed or archived | — | — | — | — | ✓ (Reopen Closed Tab, Archived Tabs on top) | ≠ bump | ≠ rubber-band | — | off | — | ✓ + shortcuts |
| One empty tab, others ≥ 1 | — | — | Tabs | — | ✓ | gallery | neighbours | — | off | — | ✓ |
| One page, no others | ✓ / dim | — / ✓ | Tabs (gallery: its card) | ✓ | ✓ | gallery (its card) | ≠ rubber-band | ✓ | ✓ | while loading | — |
| Several tabs | ✓ / dim | — / ✓ | Tabs | ✓ | ✓ | gallery | neighbours | when last | ✓ | while loading | — |
| Private only (one private page) | ✓ / dim | — / ✓ | Tabs (private gallery: its card) | ✓ | ✓ | gallery (its card) | ≠ rubber-band | ✓ (private) | ✓ | while loading | — |
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
| Duo inner (top bar), single pane | as Duo outer | | | | | off (no swipe up from a top bar; Tabs and the strip are at hand) | pill, sideways | | | | |
| Tab Layout Above, two or more tabs | | | | | | | | | | | the strip shows under the top bar; one tab: no strip (nothing to switch to). It comes in with the second tab and leaves with the last but one, in one spring |
| Duo split | per focused pane | | | | | | | | | | Open in Other Pane shown; Close Tab acts on the focused pane |
| Side tabs, Rail or Expanded | as Page | | Tabs: shows or hides the sidebar; long press for the tabs menu | | | ≠ bump (sidebar is the switcher) | neighbours | when last | | | the sidebar shows in landscape and portrait from the second tab; with one tab the row is "Duo inner, single pane" (Tabs opens the switcher); see "The sidebar" below |
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

### The sidebar (Tab Layout Left or Right)

Where it shows: wherever Tab Layout applies and the rail leaves a page of at least 600 pt
(`DuoLayout`): the Duo's inner screen in landscape and in portrait. A narrower window shows the
strip and keeps the setting.

| Control | Shows when | Why |
|---|---|---|
| The rail (site icons) | Left or Right in effect and two or more tabs, unless the Tabs button hid it | The tab list. One tab has nothing to switch to, so the page has the whole width (owner, 2026-11-27: "if I have one tab, the whole bar shows, and this looks weird"); the same rule as the strip. It comes in from its edge with the second tab and leaves with the last but one. New Tab is then the bar's "+", as on every page; the Tabs button opens the switcher, as on any page with one tab. |
| A tab's plate | every tab, in the strip and in the titled rows | Each tab is its own shape: the one on screen a solid card ringed in Lagoon, the others a veil with a hairline, glass between them (owner: "non-selected tabs [...] are just part of the whole bar"). In the rail the tile is the shape. |
| New Tab (first row) | only while the bar has no "+" (principle 8); on an empty tab neither shows | One New Tab on screen: the bar's "+" is it on a page. A long press offers New Private Tab. |
| Show Titles / Hide Titles (last row) | the rail may widen: not during a split, a book pose or with the side pane open | Where Expanded can't rest, a control that does nothing would be noise. A drag on the sidebar does the same. |
| Titles and close buttons | Expanded | The rail has room for the tile only; there Close Tab is in the tab's menu (and VoiceOver's actions). |
| Private section (hand, then "Private") | at least one private tab | Private tabs are listed after the regular ones on the dusk tint, never mixed in. |
| The mark on a tab | the focused pane shows it (Lagoon tint and ring); a split's other pane shows it (outline) | One strong mark: the tab the bar acts on. |
| Expanded as a drawer | portrait: over the page and the bar's leading end; a tab picked, a touch on the page or the address field closes it | No page or bar fits beside 260 pt there. Landscape docks it beside the page. |

A site icon replaces the tab's letter once the site has one; a site without an icon keeps the
letter (docs/decisions.md, "Site icons"). Private tabs' icons are never stored.

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
| Arc Search launches into search with the keyboard up, over the last tab, which a swipe down on the sheet reveals; a setting covers "reactivating the app with no open tabs". With no tabs the switcher cannot be reached. Safari reopens the last tab; Chrome and Firefox open a start page after 4 hours away (docs/research/launch.md). | [TechCrunch](https://techcrunch.com/2024/01/28/arcs-new-iphone-browser-wants-to-be-your-search-companion), [Arc release notes](https://resources.arc.net/hc/en-us/articles/23528454620311), docs/research/arc-tab-switcher.md, docs/research/launch.md | No tabs means the start screen, never an empty switcher. With tabs: the last tab, or after 4 hours a fresh search over it (§6, "Launch and return"). |
| HIG, context menus: "Hide unavailable menu items, don't dim them." HIG, menus: "Show people when a menu item is unavailable … appears dimmed." | [HIG: Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus), [HIG: Menus](https://developer.apple.com/design/human-interface-guidelines/menus) | Principle 6: hide what does not apply, dim what is at a limit. |
| HIG, tab bars: "Don't disable or hide tab bar buttons … makes your app's interface appear unstable." HIG, toolbars: a toolbar "can't be the only place that presents a command." | [HIG: Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars), [HIG: Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) | Plain's bar is a toolbar, not a tab bar, so it may change by mode. Positions stay fixed (slots kept), and every bar command is also in a menu. |

Not found anywhere: whether Safari shows its tabs button with one tab, what closing Safari's last
tab leaves, or Safari's empty tab overview text. The rules above do not depend on them.

## 10. Gaps in the code (audit of `dev` at 18e28cd)

Ranked by how visible and annoying each is. Format: `file:line — today → rule`. **Fixed** marks
the ones the state lane closed (2026-11-26); line numbers are from the audit, before the fix.

1. **Fixed.** `ShellUI/BrowserViewController.swift:576` — the tabs button is always shown and enabled, with
   0, 1 or many tabs → the tabs slot has three faces (§3): Tabs with `others ≥ 1`, "+" with one
   page tab, hidden on Start with nothing else. Revised 2026-11-27 (owner): "+" is gone; with one
   page tab the slot is Tabs and opens the switcher.
2. **Fixed.** `ShellUI/BrowserViewController+Gallery.swift:48` and `ShellUI/TabSwipe.swift:80` — a tap or a
   swipe up with one tab opens a one-card gallery; with no tabs both open the search field → both
   follow `others ≥ 1`; otherwise the "+" tap (button) or the bump (swipe). Revised 2026-11-26
   (owner): with one page tab the swipe up and Show All Tabs open the gallery with the card and a
   New Tab card (§3, §6; the gallery's New Tab card was removed 2026-11-27); the tap stays "+", and the bump is left for an empty tab alone.
   Revised again 2026-11-27 (owner): the tap opens the same gallery.
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
26. **Fixed (one-tab lane).** `ShellUI/BrowserViewController+Panes.swift:231` — a touch on an empty pane
    opened the search field at touch-down, even on the start screen's own controls, so with no tab
    open (first run, iPhone) the search sheet took the tap from Private Tab, Reopen Closed Tab and
    Archived Tabs, and private tabs could not be reached from the start screen → a touch on a
    control (or the spinnable mark) is the control's; only the start screen's paper opens search.
