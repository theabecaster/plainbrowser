# UI reference: simple surface, complete options

Plain follows the interface style of Pteron, the owner's iOS remote for Rex: few settings, every useful option one tap away on the thing it acts on, and nothing on screen without a reason.

## Settings

- About five top-level rows, at most two levels deep, opened as a sheet with a single "Done" button.
- Each row shows its current value, for example "Google", "Left" or "After 1 day".
- Every row is a choice the user understands and would want to make. Plain's rows are: Search Engine, Tab Layout, Archive Tabs, Appearance (System, Light, Dark), App Icon, Clear History and Data, and About.
- Footers are one plain sentence that teaches, for example "Tabs you haven't opened in a day move to the archive."
- Labels are Title Case nouns ("Search Engine", "Clear History and Data").
- A row that doesn't apply on this screen stays, disabled, keeping its value, and its footer says why and what to use instead (Tab Layout on a narrow screen: "This screen is too narrow for a tab list. Swipe up from the address bar to see your tabs.").

**Fixed choices.** Every value Plain decides instead of asking lives in one file of named constants, with a short comment saying why (`BrowserCore/FixedChoices.swift`). Examples: blocking is always on, cookie banners are rejected, translation is on the device, PDFs are Letter or A4 by region, haptics follow iOS, text follows Dynamic Type, the archive default is a week and archived tabs leave after 30 days, Appearance starts on System, and dark pages is on.

## Options live on the object

- **Page sheet** (More, or a long press on the pill; Arc's page sheet in Plain's paper): a bottom sheet sized to its content, a popover under More on wide screens. Top to bottom: the **address row**, a capsule card with Back and Forward (dimmed at a limit), the host (a tap edits the address in the field, with Copy inside it; Return loads in the same tab), Copy Link (a check mark answers in place) and Reload (Stop while loading); **tiles**, at most four captioned cards for the page actions people reach for most: Find, Reader, Summarize (on an article in a language the user reads, where Apple Intelligence runs) or Translate (Translated while it is; the two never apply together), Share always last; a tile whose mode is on (Reader while the reader is open, Translated) shows in the accent and turns it off; then keeping the page, one captioned row: Favorite and Read Later (in the accent once kept: the filled star, "Saved"; a tap removes it) and "Site Settings" (Desktop Site, blocking, cookie banners and Dark Pages, set once per site and remembered); then **rows**: Zoom (− % +, acting in place), Save PDF to Files, Open in Other Pane / Swap Panes / Close Pane (Duo), Downloads while there are any, the tabs' places (New Private Tab, Reopen Closed Tab, Archived Tabs) and the app's places (History, Reading List, Favorites, Settings) as captioned chips. Items appear only when they apply; it fits the Duo's outer screen without scrolling. Print and Save as PDF are in the share sheet, where Safari and Chrome keep them. No blocked-trackers count: WebKit gives no public count of what a rule list blocked (docs/research/address-focus.md).
- **Address bar, two doors (Arc):** a tap on the pill opens an empty field to go somewhere new; what is submitted from a page opens a new tab (Back on its first page returns to the page). On the search engine's results page the pill shows the query, and a tap brings it back selected, to refine in the same tab. Editing the page's own address is the page sheet's host, or the page's row under the field.
- **The search sheet (Arc Search's, in paper):** the pill grows into a paper card over the dimmed page; the field ends at the card's top (18.7% down the screen), rows run top down under it, and the card runs to the bottom edge behind the keyboard. In the empty field: a microphone (dictation on the phone) and Browse for Me; once typed in, the clear button. The way out is always visible: the handle at the sheet's top (swipe down, or tap it) and the dimmed page above (tap it); under a top bar, Cancel beside the field. Spec and frames: docs/research/arc-address-expand.md.
- **Automatic, with a way out:** cookie banners are answered (rejected where the banner allows it) on every site, and a foreign page offers Translate Page in its menu. Each has its switch or item on the page, never in Settings. The one hint Plain gives about a feature is a single toast the first time ever it applies ("This page is in French", Translate); after that the menu is the way.
- **On-device AI:** Browse for Me is a row under the search field while the text would search, and a button in the empty field that arms it for Return; Summarize Page is a tile in the page sheet on articles. Both write on the phone with Apple Intelligence and are left out where it can't run (no hint, no dimmed item). The summary is a paper sheet with its title and Done pinned at the top: the query or page title in New York, an honest progress line, then short headings and bullet points, each ending with small numbered citations in Lagoon that open their source, and the numbered sources at the end.
- **Switched-off features** (camera, microphone, location, Photos, cellular data; research in
  docs/research/permissions-states.md): Plain never asks or explains at launch, and puts no screen
  before iOS's own prompt, which appears when a site first asks. Right after the user says no
  there, nothing more. Later, when something the user or a site wanted is blocked by a switch of
  Plain's in Settings, one line says so where it happened, in Plain's words: a toast ("Camera is
  off for Plain", "Saving to Photos is off for Plain") with Settings, which opens Plain's page in
  the Settings app; on the error page, "Cellular data is off for Plain." with Open Settings. A
  site's request is explained once per site until the switch changes; Save Image, the user's own
  action, every time. Screen Time's limits are explained with no button, since Plain's page can't
  change them. Never an alert, never a dead button, never a repeated nag; silent where nothing
  wanted is blocked (Spotlight, Handoff, Siri, Low Power Mode). Site Settings lists the
  permissions a site asked for with their value, "Off in Settings" included.
- **Context menus on links, tabs and favorites:** Open in New Tab, Open in Other Pane, Copy Link, Share, Close, Pin, Rename favorite.
- **Profiles live in the tab switcher, not Settings:** with a second profile a capsule over the cards names the profile shown, and its menu switches, makes, renames and deletes profiles. While Personal is the only one, New Profile is in the switcher's More menu. Clear History and Data clears every profile.
- **Swipe actions:** quick actions with no confirmation, for example close a tab or delete a history row.
- **Confirmations:** only for destructive actions that affect a lot, for example Clear History and Data or Close All Tabs.
- **Gestures are shortcuts, never the only way.** Every gesture has a menu equivalent, and menus name the gesture where it helps ("Next Tab — or swipe the address bar").

## Chrome

- The page gets the screen. Controls show only while they apply, for example the progress bar while loading or a "Reopen tab" toast after a close.
- No badges, banners or standing overlays.
- **The floating controls read over any page.** Liquid Glass shows the page almost unblurred, so
  each glass control on the page (the pill, the button capsules) has a paper ground under it
  (`ChromeScrim`): the glass's own shape, its edge softened over 2 pt, nothing past it, inside
  the control so it moves and fades with it. Never a band, never a halo: the page shows in the
  gaps between capsules, so they float apart.
- **Compact height (an iPhone on its side) is one bottom row,** as Safari keeps one row there:
  Back and Forward in a capsule at the leading end (both slots kept; Forward hides in place), the
  pill in a fixed place, Tabs, Share and More in a capsule at the trailing end. About 17% of the height at rest, nothing while reading.
- **Wide screens (the Duo's inner screen) follow Safari there:** one top bar under the status bar,
  Back and Forward at its leading end, the address in the middle (at most 560 pt), Tabs, Share and
  More at its trailing end. The system's vertical bar is off, so the page has the full width. Tab
  Layout Above adds a 34 pt strip under the bar from the second tab. Where the status items keep
  to a corner (the inner screen) the bar sits on their row, and nothing of Plain's is behind it:
  no band, backing, blur or header-colored fill at the top in any state, only the floating
  glass. At a page's top a site's fixed header rests under the bar and rides up with the page
  to the top edge; mid-page it stays at the top edge under the bar, and nothing in the page moves
  when the bar collapses or comes back. While
  reading, the address shrinks in place and then lifts away, the buttons and strip fade, and the
  page runs to the top edge under the status items. The page's first line starts under the bar
  and slides under it. To type an address, the pill stays in the bar and the search sheet grows
  down from it, with Cancel beside the field. Chrome at rest: about 11% of the landscape inner screen with one tab,
  17% with the strip; nothing while reading.
- Plus buttons act at once when there is one obvious action, and become a menu only when there is a real choice.

## State rules

- Every control earns its place in the current state. The full matrix, with the reason for every
  cell and the open gaps, is `docs/state-rules.md`.
- A button, its gesture and its menu item follow one condition. The swipe up and Show All Tabs
  open the switcher whenever it has a card: another tab, or the page on screen (with one tab, its
  card alone; New Tab is the "+" under it). The tabs button's tap opens the same switcher, so it is Tabs whenever
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
- In sheets an empty list shows its symbol and the sentence in ink secondary, body text
  (`PaperEmptyState`), as the start screen does; never the system's bold black title. Where the
  sentence points at a button it shows the button's symbol ("Tap (More) on a page, then Favorite.").
- After the last tab closes, Plain goes straight to the search field. There is no empty screen in between.
- **Opening with tabs:** the last tab, exactly as it was, from the first frame (its saved picture until the live page has loaded), the bar resting, no keyboard. After 4 hours away, a fresh search over it instead: keyboard up, the tab behind a paper veil, a swipe down back to it. With no tabs, search with the keyboard up. Rules in docs/state-rules.md, "Launch and return".
- **First run:** the owner chose a short intro, shown once on first launch and never again after it is finished or skipped. It is the Stem mark assembling, one promise, what's inside, an icon picker, a live blocking demo and, where Apple Intelligence can run, a live Browse for Me demo (with Turn On Apple Intelligence only while it is off), then it dissolves into the search field with the keyboard up. Every step has Skip. It asks no permissions and sets nothing up by itself: the one setup it offers (Apple Intelligence, when off) is a button beside Not Now, shown once, never a reminder later; camera, location and notifications are still asked only when a site needs them. Its structure follows Arc Search's intro; its look is Plain's own (docs/research/intro.md): paper, a dawn window at the top with the mark on its sill, New York headlines with a coral fold-cut underline, paper cards and a Lagoon Liquid Glass button. These are the intro's own; the rest of the app keeps the rules below.
- **Default browser:** the intro's "Make Plain your default" step and the empty start screen's card (the mark, one sentence, "Set as Default Browser", dismissible) wait behind `FixedChoices.defaultBrowserPromptsEnabled` until Plain has the default-browser entitlement.

## Visual and motion

- One accent color (Lagoon Blue, from `Brand/identity.md`) and semantic colors from `DesignSystem`. No hard-coded colors in features.
- System text styles with Dynamic Type. Tap targets are at least 44 pt (the tappable area, not only the frame around it).
- Text inside fixed-height chrome (the address pill) stops growing at the largest non-accessibility size, as Safari's field does; everything else grows The page sheet's grids of captioned cells (address row, tiles, chips, zoom) keep the default size, as a tab bar's items do, and show large on a long press.
- Corner radii of 6–10 pt for controls and chips. Grouped paper rows in sheets are exempt: they keep the system's inset-grouped radius (about 26 pt), the iOS look (lead's call, 2026-11-27). Liquid Glass only on floating controls, built with one shared helper.
- **Sheet headers stay.** Every sheet's title and Done (and Back on a pushed screen) sit in a header pinned above the list (`sheetTitle` in `FeatureUI/Style.swift`), never in the system's bar, which hides on scroll at a compact height (the Duo's outer screen). A list's search field is its first row and scrolls away with the rows.
- Motion vocabulary: `.snappy(0.15–0.3)` for most changes, `.spring(0.32–0.42, bounce 0–0.12)` for gesture-driven moves, `.easeInOut(0.2)` crossfade under Reduce Motion. The full table is in the plan.
- One `Haptic` enum: `tap`, `selection`, `threshold`, `success`, and a rate-limited "nothing there" bump.

## Wording

- Short and plain, with Title Case for labels and sentence case for footers and messages.
- Error messages are written by Plain from known error cases, never raw WebKit or server text.
  A page that can't load says why in one sentence, with Try Again (`LoadFailure`): "You're
  offline.", "Plain can't find this site.", "The site isn't answering.", "The site took too
  long to answer.", "This site's connection isn't private.", "This address doesn't work.",
  "This site keeps redirecting.", "The site sent something Plain can't show.", "Plain doesn't
  open pages on this port.", "This site is restricted on this iPhone." (Screen Time), else
  "Plain couldn't open this page."
  They name the real cause: "Cellular data is off for Plain." is not "You're offline."
- The intro promises only what this screen can do: "Made for iPhone Duo" shows only where the
  window can be a foldable's (a vertical bar edge, or both size classes regular), from traits.
- A feature that is off reads "<Feature> is off for Plain"; one Screen Time blocks reads
  "<Feature> is restricted" (Apple's word in Screen Time). The toast's button is "Settings"; a page's button,
  which has room, is "Open Settings".
- An item captioned under its symbol uses the same short caption everywhere it shows (the page menu's rows and the start screen's shortcuts: "Private Tab", "Reopen Tab", "Archive"), with the full name for VoiceOver.
- The same action has the same symbol everywhere: Copy Link is `link`, Share `square.and.arrow.up`, Close Tab `xmark`.

## Outside the app

- Widgets, controls and shortcuts use the app's own words and actions: "Search in Plain", "New Tab", "New Private Tab", "Open Favorite", "Show Tabs", "Open URL". Each ends on the screen a tap in Plain would reach; none adds a mode of its own.
- The search widget is paper and the brand's dawn window, with the field drawn like the resting pill and favorites as the monogram discs from above the keyboard. Tinted and clear Home Screens get the same shapes as outlines in the tint.
- Only favorites appear in Spotlight. Nothing from a private tab leaves the app (no Spotlight, no Handoff).
