# UI reference: simple surface, complete options

Plain follows the interface style of Pteron, the owner's iOS remote for Rex: few settings, every useful option one tap away on the thing it acts on, and nothing on screen without a reason.

## Settings

- About five top-level rows, at most two levels deep, opened as a sheet with a single "Done" button.
- Each row shows its current value, for example "Google", "Left" or "After 1 day".
- Every row is a choice the user understands and would want to make. Plain's rows are: Search Engine, Tab Layout, Archive Tabs, Appearance (System, Light, Dark), App Icon (only where the icon can change: not for an iPhone app on a Mac), Clear History and Data, and About.
- Footers are one plain sentence that teaches, for example "Tabs you haven't opened in a day move to the archive."
- Labels are Title Case nouns ("Search Engine", "Clear History and Data").
- A row that doesn't apply on this screen stays, disabled, keeping its value, and its footer says why and what to use instead (Tab Layout on a narrow screen: "This screen is too narrow for a tab list. Swipe up from the address bar to see your tabs.").

**Fixed choices.** Every value Plain decides instead of asking lives in one file of named constants, with a short comment saying why (`BrowserCore/FixedChoices.swift`). Examples: blocking is always on, cookie banners are rejected, translation is on the device, PDFs are Letter or A4 by region, haptics follow iOS (System Haptics, no switch of Plain's), text follows Dynamic Type, the archive default is a week and archived tabs leave after 30 days, Appearance starts on System, and dark pages is on.

## Options live on the object

- **Page sheet** (More, or a long press on the pill; Arc's page sheet in Plain's paper): a bottom sheet sized to its content, a popover under More on wide screens. Top to bottom: the **address row**, a capsule card with Back and Forward (dimmed at a limit), the host (a tap edits the address in the field, with Copy inside it; Return loads in the same tab; with two or more profiles the profile's name under it, quiet: "Work"), Copy Link (a check mark answers in place) and Reload (Stop while loading, `stop.circle` in the same slot: an X at a sheet's corner reads as "close the sheet"; Safari's in-field X belongs where nothing else can close); **tiles**, at most four captioned cards for the page actions people reach for most: Find, Reader, Summarize (on an article in a language the user reads, where Apple Intelligence runs) or Translate (Translated while it is; the two never apply together), Share always last; a tile whose mode is on (Reader while the reader is open, Translated) shows in the accent and turns it off; then keeping the page, one captioned row: Favorite and Read Later (in the accent once kept: the filled star, "Saved"; a tap removes it) and "Site Settings" (Desktop Site, Content Blocking, Cookie Banner Blocking and Dark Pages, each named for what it controls and checked while on, set once per site and remembered; then the permissions the site asked for); then **rows**: Zoom (magnifier minus, the percent in ink, magnifier plus, acting in place; VoiceOver hears "Zoom"), Save PDF to Files, Open in Other Pane / Swap Panes / Close Pane (Duo), Downloads while there are any, the tabs' places (New Private Tab, Reopen Closed Tab, Archived Tabs) and the app's places (History, Reading List, Favorites, Settings) as captioned chips. Items appear only when they apply; it fits the Duo's outer screen without scrolling. Print and Save as PDF are in the share sheet, where Safari and Chrome keep them. No blocked-trackers count: WebKit gives no public count of what a rule list blocked (docs/research/address-focus.md).
- **Address bar, the page's address in the field:** a tap on the pill over a page opens the field with the page's full address, all selected, and Copy (`link`) inside the field at its trailing end. Typing over it (or pasting, dictating, clearing) is a new query and opens a new tab (Back on its first page returns to the page); putting the caret in the address and changing part of it edits this page, in the same tab. Copy shows only while the address is untouched. No row under the field stands for the page. On the search engine's results page the pill shows the query, and a tap brings it back selected, to refine in the same tab. The page sheet's host opens the same field with the caret at the address's end. New tabs and the start screen open the field empty.
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
- **The pill's lead word:** the resting pill says one quiet word before the host, in the
  security word's place and style: Private, then Reader or Translated, then Not Secure
  (`PillLead`; docs/decisions.md). The page sheet's host still says Not Secure under any of them.
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
- **The Duo's outer screen keeps the system's vertical bar** beside the page (status items, then
  Back, Forward, Tabs, New Tab and More in one capsule). Behind it Plain puts one floating panel of
  its glass (paper, navy in dark mode, violet in a private tab), 6 pt in from the page and the
  screen's edges with round corners; the page never runs under it.
- **Compact height (an iPhone on its side) is one bottom row,** as Safari keeps one row there:
  Back and Forward in a capsule at the leading end (both slots kept; Forward hides in place), the
  pill in a fixed place, Tabs, New Tab and More in a capsule at the trailing end. About 17% of the height at rest, nothing while reading.
- **Tab cards carry a ×:** top-trailing in the title row, a 24 pt plate (ink veil; the private violet on private cards) inside a 44 pt target, a bold 10 pt glyph in secondary text. A tap closes the tab with the same lift-and-fade as the flick, and a soft haptic. The target never takes a lift or a sideways scroll: a drag that starts on it still lifts or scrolls. VoiceOver: "Close <title>", right after its card.


- **Private mode shows in the chrome itself, never on the page:** deep violet glass drawn dark on
  the pill and buttons, the private mark (`hand.raised.fill`) before the host and in the field,
  a dark keyboard, the empty private tab's start screen drawn dark and titled "Private", and the
  switcher's "Private | Tabs" switch with the shown side filled. The two sides are always named;
  the way out is the other word ("Tabs"), "Leave Private" on an empty private tab, or Close All
  Private Tabs.
- **Wide screens (the Duo's inner screen) follow Safari there:** one top bar under the status bar,
  Back and Forward at its leading end, the address in the middle (at most 560 pt), Tabs, New Tab
  and More at its trailing end. The system's vertical bar is off, so the page has the full width. Tab
  Layout Above adds a 34 pt strip under the bar from the second tab; Left and Right show a 52 pt
  rail of site icons beside the page instead, in landscape and portrait, which widens to titles
  (a drag, or Show Titles at its foot). With one tab neither shows: the page has the room, and
  the list comes in from its edge with the second tab. The strip is as wide as its tabs, from
  the leading edge, up to the screen's width, and starts 10 pt under the status items. Every tab in a list is its own plate (the
  one on screen a solid card ringed in Lagoon, the others a veil with a hairline). Where the status items keep
  to a corner (the inner screen) the bar sits on their row. Behind the row and the strip is one
  band of Liquid Glass across the pages, from the top edge, as Safari has there; the capsules
  float on it, and it reaches under the strip when there is one. While reading the band rises to the status row's height and shows only the site's
  host in a small glass capsule where the address was ("apple.com"), clear of the status items; a
  tap on it brings the bar back. The page's top boundary is the band's bottom in every state: a
  site's fixed header rests under it and nothing in the page moves when the bar collapses or
  comes back; the strip shows while the page's top is in view, so it never covers a header
  mid-page. Private, the band, the host capsule and the strip are the private violet glass, drawn dark. The page's first line starts under the expanded band and slides under the glass. To
  type an address, the pill stays in the bar and the search sheet grows down from it, with Cancel
  beside the field. Chrome at rest: about 11% of the landscape inner screen with one tab, 17.5% with
  the strip at a page's top; 11% while reading.
- Plus buttons act at once when there is one obvious action, and become a menu only when there is a real choice.
- **The bar's buttons** (every layout): Back, Forward, Tabs, New Tab ("+") and More. New Tab opens a
  tab of the kind on screen with the keyboard up; its long press offers the other kind. Share is
  the page sheet's last tile, not a bar button (Safari 26 and Chrome keep it out of the bar too).
  New Tab hides on the start screen, which is already a new tab. A New Tab whose field the user
  closes untouched goes back to the page it came from (docs/research/new-tab.md).

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
- Empty tabs are never left behind, and there is at most one New Tab button on screen: the bar's
  "+" on a page (the gallery's "+" while the gallery is up), none on an empty tab.

## Empty and first-run states

- Each empty state is one sentence and one main button.
- In sheets an empty list shows its symbol and the sentence in ink secondary, body text
  (`PaperEmptyState`), as the start screen does; never the system's bold black title. Where the
  sentence points at a button it shows the button's symbol ("Tap (More) on a page, then Favorite.").
- After the last tab closes, Plain goes straight to the search field. There is no empty screen in between.
- **Opening with tabs:** the last tab, exactly as it was, from the first frame (its saved picture until the live page has loaded), the bar resting, no keyboard. After 4 hours away, a fresh search over it instead: keyboard up, the tab behind a paper veil, a swipe down back to it. With no tabs, search with the keyboard up. Rules in docs/state-rules.md, "Launch and return".
- **First run:** the owner chose a short intro, shown once on first launch and never again after it is finished or skipped. It is the Stem mark assembling, one promise, what's inside, an icon picker (left out where the icon can't change), a live blocking demo and, where Apple Intelligence can run, a live Browse for Me demo (with Turn On Apple Intelligence only while it is off), then it dissolves into the search field with the keyboard up. Every step has Skip. It asks no permissions and sets nothing up by itself: the one setup it offers (Apple Intelligence, when off) is a button beside Not Now, shown once, never a reminder later; camera, location and notifications are still asked only when a site needs them. Its structure follows Arc Search's intro; its look is Plain's own (docs/research/intro.md): paper, a dawn window at the top with the mark on its sill, New York headlines with a coral fold-cut underline, paper cards and a Lagoon Liquid Glass button. These are the intro's own; the rest of the app keeps the rules below.
- **Default browser:** the intro's "Make Plain your default" step and the empty start screen's card (the mark, one sentence, "Set as Default Browser", dismissible) wait behind `FixedChoices.defaultBrowserPromptsEnabled` until Plain has the default-browser entitlement.

## Visual and motion

- One accent color (Lagoon Blue, from `Brand/identity.md`) and semantic colors from `DesignSystem`. No hard-coded colors in features.
- A tab is shown by its site's icon on a small lifted tile (the sidebar, the strip, the switcher's cards), the same tile for every site; a site without an icon shows its first letter in New York on that tile. The tab on screen is marked in Lagoon.
- System text styles with Dynamic Type. Tap targets are at least 44 pt (the tappable area, not only the frame around it).
- Lists of pages with a time (History, Archived Tabs) put the time under the title from the
  first accessibility size, where beside it the title was cut to a word.
- Text inside fixed-height chrome (the address pill) stops growing at the largest non-accessibility size, as Safari's field does; everything else grows The page sheet's grids of captioned cells (address row, tiles, chips, zoom) keep the default size, as a tab bar's items do, and show large on a long press.
- Corner radii of 6–10 pt for controls and chips. Grouped paper rows in sheets are exempt: they keep the system's inset-grouped radius (about 26 pt), the iOS look (lead's call, 2026-11-27). Liquid Glass only on floating controls, built with one shared helper.
- **Sheet headers stay.** Every sheet's title and Done (and Back on a pushed screen) sit in a header pinned above the list (`sheetTitle` in `FeatureUI/Style.swift`), never in the system's bar, which hides on scroll at a compact height (the Duo's outer screen). A list's search field is its first row and scrolls away with the rows.
- Motion vocabulary: `.snappy(0.15–0.3)` for most changes, `.spring(0.32–0.42, bounce 0–0.12)` for gesture-driven moves, `.easeInOut(0.2)` crossfade under Reduce Motion. The full table is in the plan.
- **Haptics** (docs/research/haptics.md has the research and the full inventory). One `Haptic` enum, eight kinds, each with one meaning:

  | Kind | Feel | Meaning | Examples |
  |---|---|---|---|
  | `selection` (the tick) | selection | a value or state changed in place, or a gesture crossed back over its threshold | zoom step, reorder slot, a toggle, Find wrapping to the first match, un-arming a swipe |
  | `tap` (the commit) | light impact | an action committed whose result is small, off-screen or delayed | background tab, download started, zoom back to 100%, a flick that commits without arming |
  | `threshold` | medium impact, 0.7 | a gesture crossed into a new outcome while the finger is down | bar swipe past half, the New Tab card at 80 pt, swipe up past the commit line, a card past its close line |
  | `drop` | rigid impact, 0.6 | a dragged item landed in a new place | gallery reorder drop |
  | `close` | soft impact | something went away | a tab, a pane, a profile |
  | `success` | notification success | it worked, and the result is invisible or ends a wait | Copy Link, favorite, download finished, Clear History done, the intro finished |
  | `failed` | notification warning | a task the user started and waited for did not work | download or PDF failed |
  | `nothingThere` | soft impact, 0.5, at most once a second | instant refusal, nothing to do | Return in an empty field, a swipe with nowhere to go, Find with no matches |

  Rules:
  1. A haptic marks a moment, not a tap. A button whose result is on screen (Back, Tabs, Reload, Share, Done, a sheet opening) plays nothing.
  2. Outcomes after a wait, or invisible ones, get `success` or `failed`. Instant visible outcomes get nothing.
  3. One haptic per gesture outcome. A threshold announced while the finger was down makes the release silent; a flick that commits without arming plays once, as the spring starts.
  4. Thresholds play both ways: `threshold` crossing in, `selection` crossing back, with 10 pt of hysteresis (`ThresholdLatch`, `FixedChoices.hapticThresholdHysteresis`).
  5. Never during scrolling, momentum, chrome collapse or reveal.
  6. No error pattern, and nothing when a confirmation dialog appears: the haptic comes with the destructive choice.
  7. System controls keep their own haptic (context menus, button menus, pickers, `Toggle`, swipe actions, drag lift), and Plain never adds a second.
  8. Nothing from key commands, the pointer or hover (`Haptic.withoutFeedback`).
  9. Reduce Motion keeps haptics: they play with the crossfade.
  10. Nothing from the background: an outcome plays with its toast when the toast appears. Two haptics inside 60 ms are one event, and the first wins (`FixedChoices.hapticMinimumGap`).
  11. iOS mutes haptics while the microphone or camera records, and Plain keeps it that way.
  12. A new haptic adds a row to the inventory in docs/research/haptics.md, and its check to docs/research/haptics-checklist.md.

## Wording

- Short and plain, with Title Case for labels and sentence case for footers and messages.
- Error messages are written by Plain from known error cases, never raw WebKit or server text.
  A page that can't load says why in one sentence, with Try Again (`LoadFailure`): "You're
  offline.", "Plain can't find this site.", "The site refused the connection.", "The site isn't answering.", "The site took too
  long to answer.", "This site's connection isn't private.", "This address doesn't work.",
  "This site keeps redirecting.", "The site sent something Plain can't show.", "Plain doesn't
  open pages on this port.", "This site is restricted on this iPhone." (Screen Time), else
  "Plain couldn't open this page."
  They name the real cause: "Cellular data is off for Plain." is not "You're offline."
- The intro promises only what this screen can do: "Made for iPhone Duo" shows only on a phone
  that folds: UIKit's `UIHingeInteraction` reports a hinge, or the window is a foldable's (a
  vertical bar edge, or both size classes regular). Never the device model.
- A feature that is off reads "<Feature> is off for Plain"; one Screen Time blocks reads
  "<Feature> is restricted" (Apple's word in Screen Time). The toast's button is "Settings"; a page's button,
  which has room, is "Open Settings".
- An item captioned under its symbol uses the same short caption everywhere it shows (the page menu's rows and the start screen's shortcuts: "Private Tab", "Reopen Tab", "Archive"), with the full name for VoiceOver.
- The same action has the same symbol everywhere: Copy Link is `link`, Share `square.and.arrow.up`, Close Tab `xmark`.

## Outside the app

- Widgets, controls and shortcuts use the app's own words and actions: "Search in Plain", "New Tab", "New Private Tab", "Open Favorite", "Show Tabs", "Open URL". Each ends on the screen a tap in Plain would reach; none adds a mode of its own.
- The search widget is paper and the brand's dawn window, with the field drawn like the resting pill and favorites as the monogram discs from above the keyboard. Tinted and clear Home Screens get the same shapes as outlines in the tint.
- Only favorites appear in Spotlight. Nothing from a private tab leaves the app (no Spotlight, no Handoff).
