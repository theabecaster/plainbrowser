# UI reference: simple surface, complete options

Plain follows the interface style of Pteron, the owner's iOS remote for Rex: few settings, every useful option one tap away on the thing it acts on, and nothing on screen without a reason.

## Settings

- About five top-level rows, at most two levels deep, opened as a sheet with a single "Done" button.
- Each row shows its current value, for example "Google", "Left" or "After 1 day".
- Every row is a choice the user understands and would want to make. Plain's rows are: Search Engine, Tab Layout, Archive Tabs, Appearance (System, Light, Dark), App Icon, Clear History and Data, and About.
- Footers are one plain sentence that teaches, for example "Tabs you haven't opened in a day move to the archive."
- Labels are Title Case nouns ("Search Engine", "Clear History and Data").
- A row that doesn't apply on this screen stays, disabled, keeping its value, and its footer says why and what to use instead (Tab Layout on a narrow screen: "This screen is too narrow for a tab list. Swipe up from the address bar to see your tabs.").

**Fixed choices.** Every value Plain decides instead of asking lives in one file of named constants, with a short comment saying why (`BrowserCore/FixedChoices.swift`). Examples: blocking is always on, cookie banners are rejected, translation is on the device, PDFs are Letter or A4 by region, haptics follow iOS, text follows Dynamic Type, the archive default is 1 day, Appearance starts on System, and dark pages is on.

## Options live on the object

- **Page menu:** one menu from the URL pill. It holds Reload, Find on Page, Print…, Save as PDF, Translate Page (Show Original while translated), Share, Copy Link, Desktop Site, Zoom, Turn Off Blocking on This Site, Turn Off Cookie Banner Blocking, Turn Off Dark Pages for This Site (while Plain is dark and darkens the page), Open in Other Pane (Duo; Swap Panes and Close Pane while a split shows), and Add to Favorites. Items appear only when they apply. Destructive items go in their own last section. It fits the Duo's outer screen without scrolling: Reload (Stop while loading), Share and Copy Link are one row of three at the top of the page items; Find on Page, Print… and Save as PDF are the next row of three while the page can be printed (captions "Find", "Print…", "Save PDF"; full names for VoiceOver); Desktop Site, the blocking toggle, cookie banners and Dark Pages, set once per site and then remembered, are one "Site Settings" submenu (subtitled with the site) when two or more apply; History, Edit Favorites ("Favorites" in the row) and Settings are one row of three at the end, under Downloads while there are any.
- **Automatic, with a way out:** cookie banners are answered (rejected where the banner allows it) on every site, and a foreign page offers Translate Page in its menu. Each has its switch or item on the page, never in Settings. The one hint Plain gives about a feature is a single toast the first time ever it applies ("This page is in French", Translate); after that the menu is the way.
- **Context menus on links, tabs and favorites:** Open in New Tab, Open in Other Pane, Copy Link, Share, Close, Pin, Rename favorite.
- **Swipe actions:** quick actions with no confirmation, for example close a tab or delete a history row.
- **Confirmations:** only for destructive actions that affect a lot, for example Clear History and Data or Close All Tabs.
- **Gestures are shortcuts, never the only way.** Every gesture has a menu equivalent, and menus name the gesture where it helps ("Next Tab — or swipe the address bar").

## Chrome

- The page gets the screen. Controls show only while they apply, for example the progress bar while loading or a "Reopen tab" toast after a close.
- No badges, banners or standing overlays.
- **Wide screens (the Duo's inner screen) follow Safari there:** one top bar under the status bar,
  Back and Forward at its leading end, the address in the middle (at most 560 pt), Tabs, Share and
  More at its trailing end. The system's vertical bar is off, so the page has the full width. Tab
  Layout Above adds a 34 pt strip under the bar from the second tab. While reading, the bar shrinks
  to the address under the status bar and the buttons and strip fade. The page starts under the
  bar and slides under it. To type an address, the pill still rises above the keyboard with the
  search sheet, as on every screen. Chrome at rest: about 11% of the landscape inner screen with
  one tab, 17% with the strip; about 9% while reading.
- Plus buttons act at once when there is one obvious action, and become a menu only when there is a real choice.

## State rules

- Every control earns its place in the current state. The full matrix, with the reason for every
  cell and the open gaps, is `docs/state-rules.md`.
- A button, its gesture and its menu item follow one condition. The swipe up and Show All Tabs
  open the switcher whenever it has a card: another tab, or the page on screen (with one tab, its
  card and a New Tab card). The tabs button's tap opens the same switcher, so it is Tabs whenever
  the switcher has a card. An empty tab alone has nothing to show: no tabs button, and the swipe
  bumps.
- A long press is never the only way to an item: New Private Tab, Reopen Closed Tab and Archived
  Tabs are also in More, and on the start screen.
- A gesture with nothing to do rubber-bands with the "nothing there" haptic. It never does
  something else instead.
- The bar changes shape only between modes (start screen, page, search, gallery). Inside a mode a
  control dims or hides in place, so nothing moves under the thumb. Menus leave out items that do
  not apply and dim items at a limit.
- Empty tabs are never left behind, and there is at most one New Tab button on screen, none on an
  empty tab.

## Empty and first-run states

- Each empty state is one sentence and one main button.
- After the last tab closes, Plain goes straight to the search field. There is no empty screen in between.
- **First run:** the owner chose a short intro, shown once on first launch and never again after it is finished or skipped. It is the Stem mark assembling, one promise, what's inside, an icon picker and a live blocking demo, then it dissolves into the search field with the keyboard up. Every step has Skip. It asks no permissions: camera, location and notifications are still asked only when a site needs them. Its structure follows Arc Search's intro; its look is Plain's own (docs/research/intro.md): paper, a dawn window at the top with the mark on its sill, New York headlines with a coral fold-cut underline, paper cards and a Lagoon Liquid Glass button. These are the intro's own; the rest of the app keeps the rules below.
- **Default browser:** the intro's "Make Plain your default" step and the empty start screen's card (the mark, one sentence, "Set as Default Browser", dismissible) wait behind `FixedChoices.defaultBrowserPromptsEnabled` until Plain has the default-browser entitlement.

## Visual and motion

- One accent color (Lagoon Blue, from `Brand/identity.md`) and semantic colors from `DesignSystem`. No hard-coded colors in features.
- System text styles with Dynamic Type. Tap targets are at least 44 pt.
- Corner radii of 6–10 pt. Liquid Glass only on floating controls, built with one shared helper.
- Motion vocabulary: `.snappy(0.15–0.3)` for most changes, `.spring(0.32–0.42, bounce 0–0.12)` for gesture-driven moves, `.easeInOut(0.2)` crossfade under Reduce Motion. The full table is in the plan.
- One `Haptic` enum: `tap`, `selection`, `threshold`, `success`, and a rate-limited "nothing there" bump.

## Wording

- Short and plain, with Title Case for labels and sentence case for footers and messages.
- Error messages are written by Plain from known error cases, never raw WebKit or server text.
