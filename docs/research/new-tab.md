# A quick way to open a new tab

Owner, 2026-11-27: "I think there should be a quick way to open a new tab instead of having to
open the tab switcher. But I don't want to overload the interface. … Maybe Settings can go
somewhere else: not a must, just a suggestion."

**Bottom line.** The bar's Share slot becomes New Tab ("+"). Share was the one bar button that
repeats an item of the page sheet (its last tile), and Safari 26 and Chrome both keep Share out of
the bar while Chrome, Firefox and Brave put New Tab in it. The bar keeps five slots, so nothing is
added. A long press on "+" opens the other kind (New Private Tab from a regular page). A "+" that
is closed untouched goes back to the page it came from, so a stray tap costs nothing. The strip's
own "+" on the Duo's inner screen goes (the bar's "+" sits right above it). The swipe past the last
tab stays, with the haptics plan's `threshold`. Settings stays where it is: it is in the page
sheet, not the bar, so moving it frees no slot.

## 1. Today (dev at 3aeff73)

The bar is Back, Forward, Tabs, Share, More (`PageButton`). Forward hides in place until there is
somewhere forward. On the Duo's outer screen the same five are the system's vertical bar; on the
inner screen they are the top bar's two capsules (Back, Forward | pill | Tabs, Share, More), with
the tab strip under it from the second tab (Tab Layout Above).

### Every path to a new tab, and what it costs

| Path | Phone, Duo outer | Duo inner (top bar) | Start screen | Notes |
|---|---|---|---|---|
| Tabs, then the switcher's "+" | 2 taps, with the 0.4 s zoom in between | 2 taps | Tabs is hidden on an empty tab alone | The only visible path on a phone. |
| Long press on Tabs, then New Tab | press 0.5 s + 1 tap | same | hidden on an empty regular tab | Taught once by a TipKit tip. |
| Swipe past the last tab on the pill | 1 drag, only on the list's last tab | same, on the pill | never (would make a second empty tab) | Hidden; a card with "+" and "New Tab" rubber-bands in, commits at 80 pt. |
| The strip's "+" | — | 1 tap, only with 2 or more tabs and Tab Layout Above | — | With one tab there is no strip, so no "+". |
| The sidebar's New Tab | — | 1 tap with Tab Layout Left/Right | hidden on an empty tab | |
| A tap on the pill, then a search | 1 tap + typing; the tab is made only when something is opened, as a child of the page (Back on its first page closes it) | same | loads in place | Arc's "go somewhere new". It is a search, not a New Tab: nothing to open empty. |
| More, then New Private Tab | 2 taps (private only; "New Tab" only on an empty private tab) | same | same | |
| ⌘T | hardware keyboard (gestures lane) | same | | |

Start screen: the tab on screen is already a new tab. Nothing is needed there.

**Settings** is reached the same way everywhere: More, then Settings in the page sheet's last row
(History, Reading List, Favorites, Settings), 2 taps. It has no bar slot on any layout.

## 2. Research

Tags: [V] read on the official or primary page; [S] a secondhand article; [U] not confirmed (search
snippet or memory).

### Browsers

| Finding | Source |
|---|---|
| Safari 26 has three layouts: Compact (the tab bar compressed below the page), Bottom and Top. | [V] [Apple: Change the layout](https://support.apple.com/en-om/guide/iphone/ipha9ffea1a3/26/ios/26) |
| Compact hides Share, Bookmarks and Tabs behind "•••": no visible "+" on a page. Bottom and Top keep the iOS 18 bar (Back, Forward, Share, Bookmarks, Tabs). | [S] [MacRumors: iOS 26 Safari](https://www.macrumors.com/guide/ios-26-safari-features/) |
| Safari's New Tab button is in the tab overview, bottom left; a long press on it lists recently closed tabs; a long press on Done offers Close All. | [V] [Apple: Open and close tabs](https://support.apple.com/en-om/guide/iphone/iph489b9313f/26/ios/26) |
| In the iOS 26 beta Apple moved the overview's "+" to the top, then back to the bottom in beta 2 after mis-taps. | [S] [MacRumors](https://www.macrumors.com/2025/06/23/ios-26-beta-2-safari-design-change/) |
| Swiping the bottom address bar past the last tab opens a new tab. | [S] [iPhone Life](https://iphonelife.com/content/quickest-way-to-open-new-tab-safari-your-iphone) |
| Safari's tabs button long press holds New Tab, New Private Tab, Close This Tab, Close All Tabs. | [U] |
| Safari's settings live in the system Settings app (Apps > Safari); no in-app Settings entry. | [V] Apple: Change the layout |
| Arc Search: three bottom buttons (tabs, search, page menu), no "+"; search results open in a new tab. Tabs archive when inactive (12 h to 30 d; 1 d default). Settings: a gear in the tab switcher. | [S] [MacStories](https://www.macstories.net/reviews/arc-search-for-iphone/), [S] [TechCrunch](https://techcrunch.com/2024/01/28/arcs-new-iphone-browser-wants-to-be-your-search-companion); gear [U] |
| Chrome iOS: a bottom "+" New Tab and a tab counter; their long press: Close Tab, New Tab, New Incognito Tab (order changed June 2026). Settings: More (•••), then Settings. | [S] [PiunikaWeb](https://piunikaweb.com/2026/06/08/google-chrome-for-ios-long-press-menu-order-new-tabs/), [V] [Chrome Help](https://support.google.com/chrome/answer/2391819?co=GENIE.Platform%3DiOS); order Back, Forward, +, Tabs, ••• [U] |
| Firefox iOS 144: "customize your toolbar by choosing a New Tab button or a Home button"; New Tab the default from 143. Settings in the ☰ menu. | [V] [Firefox 144 notes](https://www.firefox.com/en-US/firefox/ios/144.0/releasenotes/); default and menu [U] |
| Brave iOS: "+" bottom center on the page; moving it in the switcher drew complaints about muscle memory. Settings: main menu, All Settings. | [S] [Brave community](https://community.brave.app/t/bring-the-button-back-to-the-middle/658981); settings [U] |
| DuckDuckGo iOS (Aug 2026): one customizable slot left of the tab switcher, New Tab one of its options; the rest in the menu bottom right. | [S] [PiunikaWeb](https://piunikaweb.com/2026/08/19/duckduckgo-ios-update-shortcut-options-toolbar/) |
| Orion iOS: "Recently Closed Tabs" on a long press of "+". | [U] Orion release notes |

### Guidelines

| Finding | Source |
|---|---|
| HIG, toolbars: "Choose items deliberately to avoid overcrowding." On iOS, "Prioritize only the most important items for inclusion in the main toolbar area… Create a More menu to include additional items." "Provide actions that support the main tasks people perform." No item count is given. | [V] [HIG: Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) |
| HIG, gestures: a custom gesture should be "Discoverable… Not the only way to perform an important action". "Use shortcut gestures to supplement standard gestures, not replace them." | [V] [HIG: Gestures](https://developer.apple.com/design/human-interface-guidelines/gestures) |
| NN/g: "Most users won't discover these actions" (contextual swipe, no signifier); "The actions available through the gesture should also be present in the visible UI." | [V] [NN/g: Contextual swipe](https://www.nngroup.com/articles/contextual-swipe/), [V] [NN/g: Contextual menus](https://www.nngroup.com/articles/contextual-menus/) |
| NN/g: hidden navigation cut discoverability by more than 20%; with 4 or fewer top items, show them. | [V] [NN/g: Hamburger menus](https://www.nngroup.com/articles/hamburger-menus/) |
| Hoober: 49% of people touching a phone use one hand; "People touch the center of the screen"; accuracy 7 mm at the center to 12 mm at the corners; "more than four items on an iOS menu bar—or five on the largest phones—is just asking for trouble." | [V] [UXmatters 2013](https://www.uxmatters.com/mt/archives/2013/02/how-do-users-really-hold-mobile-devices.php), [V] [UXmatters 2017](https://www.uxmatters.com/mt/archives/2017/07/design-for-fingers-touch-and-people-part-3.php) |
| Fitts's law: time to hit a target grows with distance over size. A bottom-bar slot next to the center is near the thumb's rest; a top-corner target is the worst on a large phone. | Fitts (1954); Hoober above |

What the research says for Plain: a gesture alone (the swipe past the last tab) is not enough,
because most people never find it and it only works from the last tab. A visible button is the
fix. Hoober's five-item ceiling means it must replace something, not add a sixth.

## 3. Options weighed

| Option | Verdict | Why |
|---|---|---|
| (a) A visible "+" in the bar, replacing a slot | **Chosen**, in Share's slot | Settings has no bar slot. Share does: it is the page sheet's last tile too, so it is the bar's only duplicate. Safari 26 Compact and Chrome keep Share out of the bar; Chrome, Firefox, Brave put "+" in. The bar stays at five, with Tabs still in the center. Share goes from 1 tap to 2 (More, Share), the same as Safari's default layout. |
| (b) Swipe past the last tab | **Kept**, retuned | It exists (`TabSwipe`, the New Tab card at 80 pt). Its haptics move to the plan's vocabulary: `threshold` as it arms, a tick as it disarms (10 pt hysteresis), a silent commit. It stays a shortcut, never the only way (HIG). |
| (c) Long press on Tabs, New Tab | **Kept** | Exists. Safari and Chrome have it. |
| (d) Swipe up or double tap on Tabs | Rejected | A swipe up anywhere on the bar already opens the switcher; on one button it would mean something else (principle 4). A double tap makes every single tap on Tabs wait out the double-tap window (about 0.3 s), on the hottest button, and is undiscoverable. |
| (e) Start screen | Nothing | The tab on screen is already a new tab; the "+" hides there (principle 8). |
| (f) Duo inner: the strip's "+" | Replaced by the bar's | The strip shows only from the second tab, so with one tab the inner screen had no "+". The bar's "+" is there with one tab or ten, right above where the strip's sat. Two "+" a few points apart would break principle 8, so the strip's goes, as Safari's tab bar on iPad has none (its "+" is in the toolbar). The sidebar's New Tab hides while the bar has "+", for the same reason. |
| (g) Move Settings | Not moved | It has no bar slot, so moving it frees nothing. The page sheet's last row (History, Reading List, Favorites, Settings) is where Chrome and Firefox keep Settings (their main menu), and More is one tap away on every screen. Moving it into the switcher's More (Arc) would hide it behind the switcher and, with one tab, a menu that is otherwise empty. |

Also considered: a "+" inside the pill (Arc's search button): the pill tap already opens the
field; two targets inside one capsule are small and fight the sideways swipe. Rejected.

## Plan

### Per layout

| Layout | New Tab | Share | Settings |
|---|---|---|---|
| Phone bottom bar (every iPhone, portrait) | "+" in the fourth slot: Back, Forward, Tabs, **New Tab**, More. The bar keeps its shape: same five equal slots, glass capsule, 44 pt targets, `plus` at 19 pt medium like its neighbours. | the page sheet's last tile (More, Share), and the pill's long press (same sheet) | More, Settings (unchanged) |
| Phone landscape (compact height, one row) | the trailing capsule: Tabs, **New Tab**, More | same | same |
| Duo outer (system vertical bar) | the bar item after Tabs, `.verticalPreferred`, visibility priority high (Share's was low) | same | same |
| Duo inner (top bar) | the trailing capsule: Tabs, **New Tab**, More. The strip has no "+"; the sidebar's New Tab hides while the bar's shows | same; More opens the sheet as a popover | same |
| iPad (coming, trait-driven) | the top bar's trailing capsule, as Safari's toolbar "+" on iPad | same | same |
| Start screen | hidden: the bar sits beside the pill (More, or Tabs and More) | hidden | More, Settings |

### Behavior

- **Tap:** a new tab of the kind on screen (private stays private), as the swipe past the last
  tab does. The search field takes the keyboard at once (`openNewTab`, the same path as the menu,
  the gallery's "+", the swipe and ⌘T).
- **Long press:** a one-item menu with the other kind: New Private Tab on a regular page, New Tab
  on a private one. The tabs menu still has both. "Plus buttons act at once when there is one
  obvious action" (ui-reference): the tap is that action, the menu is the shortcut.
- **A stray "+" costs nothing.** A New Tab opened over a page goes back to that page when the user
  closes its field (a swipe down, a tap on the page, the grabber, Cancel, Escape) with nothing typed and nothing opened; the
  empty tab is dropped (principle 7). Arc's search over a page works the same way. Anything else
  keeps the new tab: typed text, any load (Return, a suggestion, a favorite, Open Copied Link),
  Browse for Me, and the field ending for any other reason (backgrounding, a sheet, the gallery,
  a pane change). The way back is bound to the pane it was opened in and is not offered when the
  page has moved to the other pane. New Tab from the gallery has no way back (the page under the
  gallery is not where the user was). A private "+" cancelled from a regular page goes back to
  that regular page: the user never started browsing privately. Applies to every New Tab from a
  page (button, tabs menu, swipe, ⌘T), so they all behave alike.
- **Swipe past the last tab:** unchanged motion (the page slides out, the card with `plus.circle`
  and "New Tab" follows 1:1, rubber-banded). Commits only while armed and only when the finger
  lets go: a touch the system cancels (a call, Control Center) springs back.
- **Gestures around the "+".** The bar's pan recognizers cancel the touches in its buttons, so a
  swipe up that starts on "+" opens the switcher and never taps "+". Sideways swipes belong to the
  pill only, so a sideways drag on the button bar does nothing. The top bar has no swipe up. The
  long press and the tap share one button, as Tabs': holding never also fires the tap.

### Visuals

The "+" is one more glass-bar glyph: SF Symbol `plus`, 19 pt, medium weight, the ink tint of its
neighbours (not the accent: the bar has no colored button), centered in a 44 pt slot of the
existing capsule. No badge, no label, no new surface. In the top bar it sits between Tabs and More
in the 132 pt trailing capsule, which keeps its width.

### Motion

- The tap starts the existing New Tab motion: the start screen takes the page's place under the
  search sheet, and the pill grows from the bar into the field above the rising keyboard
  (`.snappy(0.3)` on `keyboardLayoutGuide`). One motion, from where the thumb is; the keyboard is
  asked for in the same frame, so nothing waits on an animation (budget: New Tab to keyboard,
  510 ms target, 600 fail).
- The untouched return: the sheet and keyboard go down as for any closed field, and the page is
  back under them; no slide.
- Transform and alpha only; no layout beyond the keyboard geometry the field already follows.
  Reduce Motion: the existing crossfade.

### Haptics (haptics plan vocabulary)

| Moment | Haptic |
|---|---|
| Tap "+" | none: the result is on screen (rule 1) |
| Long press "+" | the system's menu haptic |
| Swipe past the last tab: the card reaches 80 pt | `threshold` |
| …pulled back under 70 pt | `selection` |
| …released armed | none (rule 3: the threshold already played) |
| Swipe sideways with no neighbour and no card | `nothingThere` (unchanged) |

### VoiceOver

The button reads "New Tab", identifier `newTab`. Its long-press menu is offered by VoiceOver as
the button's menu action, as Tabs' is. The strip loses its "New Tab" element; the bar's is the one
on screen. The start screen has no "New Tab" element (already a new tab).

### Key commands

⌘T and ⇧⌘N belong to the gestures lane; they call the same `openNewTab`, so they get the
untouched return too. Nothing new here.

### State rules

`ControlRules.newTab` replaces `ControlRules.share` with the same predicate: shown in Page mode
(loading, loaded, failed, crashed, resend, the reader, private or not), hidden on Start. On the
system vertical bar the item hides on Start as Share's did. It never changes inside a mode, so
nothing moves under the thumb. Principle 8 now reads: one New Tab button on screen, the bar's
"+" on a page and none on an empty tab; the gallery's "+" replaces it while the gallery is up.

### Performance

No launch work: the button is built with the other four. No new per-frame work. The tap runs the
existing `openNewTab` and its `tab.newReady` interval, so `newTabMs` measures it; the perf test
now taps "+" instead of the tabs menu, which starts the interval at the same call.

## Review of this plan (Codex)

Round 1 (`codex exec`, the plan, the code and captures of today's bar on the iPhone 17 and the
Duo's two screens). Verdict: "Keep the Share-to-`+` swap and Settings placement; block shipping
until cancellation, privacy, gesture arbitration, accessibility and end-to-end timing are
specified and verified."

| Finding | Taken? | What changed |
|---|---|---|
| "Untouched" undefined; backgrounding and other field ends must not return | Yes | Returns only on the user's own close (a swipe down, a tap on the page, the grabber, Cancel, Escape) with an empty field; every other end settles the new tab. |
| Favorites and paste-and-go race the dismissal | Already safe | `load` clears the way back before it ends editing, synchronously. |
| Split panes: bind the return to its pane | Yes | Pane recorded; no return if focus moved or the page is in the other pane. |
| Gallery "+": the way back is ambiguous | Yes | No way back from the gallery. |
| Cancelled swipe can commit an armed card | Yes (it predates this lane) | Only `.ended` commits the card. |
| Gesture arbitration around "+" | Specified | Section above; UIKit's pan cancels the button's touch. |
| Browse for Me must keep its tab | Yes | Its tab is kept (it ends editing itself). |
| Private "+" cancelled must not leave private browsing | No | Cancelling goes back to where the user was; nothing private had started. |
| VoiceOver: label, menu, focus, hidden items leave the tree | Kept as is | "New Tab" label; the long-press menu is the button's menu, as Tabs'; `setVisibility` takes hidden buttons out of the tree. |
| Measure end to end, input to editable field | No | `newTabMs` keeps its definition (call to keyboard at rest), so before and after compare; the tap dispatch it leaves out is the same for every path. |
| Strip "+" vs sidebars and split | Yes | The sidebar's New Tab shows only while the bar has none; in a split the one bar spans both panes. |
| Docs drift (state rules, ui-reference still say Share) | Yes | Updated with the implementation. |
| Polish: no badge or tip; accept Share's extra tap explicitly | Yes | No tip or badge; Share's 1 to 2 taps is stated above. |

## Results

### Tap counts, before and after (from a page)

| Path | Before | After |
|---|---|---|
| New Tab, phone and Duo outer | 2 taps (Tabs, then the switcher's "+"), or a long press + 1 tap, or the swipe on the last tab only | **1 tap** ("+"); the others stay |
| New Tab, Duo inner, one tab | 2 taps (no strip, so no strip "+") | **1 tap** |
| New Tab, Duo inner, two or more tabs | 1 tap (the strip's "+") | 1 tap (the bar's "+", above where the strip's was) |
| New Private Tab | 2 taps (More, New Private Tab) or a long press on Tabs + 1 tap | the same, plus a long press on "+" + 1 tap |
| Undo a stray New Tab | close the field, then find the page again (Tabs, its card): 3+ taps | close the field: back on the page |
| Share | 1 tap | 2 taps (More, Share) |
| Settings | 2 taps (More, Settings) | 2 taps, unchanged |

### Verification

- `swift test`: 206 tests pass (new: `newTabButtonShowsOnEveryPageAndNeverOnStart`,
  `newTabButtonAndTheSwipePastTheLastTabAgreeOnPages`). `check-isolation.zsh`: ok.
- UI tests (`NewTabTests`: the tap, the long press, the swipe past the last tab, the untouched
  return, no "+" on Start; plus the touched `StateRulesTests`, `DuoTests` and `TabsTests`) pass on
  iPhone 17, iPhone 13 mini and the Duo's outer screen. On the inner screen the first run's tests
  closed the sheet with a tap that dev's new top-bar field no longer takes; the close now uses the
  sheet's grabber or Cancel.
- `scripts/matrix.sh --quick`: all five rows pass.
- Perf gate (simulator, the same test Mac, one after the other): New Tab to keyboard 549.8 ms
  before, 484.4 ms after (target 510, fail 600); the after run passed every metric. Part of the
  gain is the test's own path: before it opened the tabs menu first, whose closing overlapped the
  interval.

### Implementation review (Codex)

- Code round 1: blocking, two stale UI tests (fixed); polish, the hysteresis into
  `FixedChoices` (done).
- Code round 2 (after the rebase onto the new search sheet): no blocking finding. Polish: return
  before the sheet collapses so it lands on the page's pill (done); a sturdier close in the tests
  (done).
- Design round 1: "Visually approve." Polish: the long-press menu's lifted backing looks muddy over
  text; it is the system's button-menu lift, as on Tabs, so it goes to the polish backlog.
