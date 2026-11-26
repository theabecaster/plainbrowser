# UI reference: simple surface, complete options

Plain follows the interface style of Pteron, the owner's iOS remote for Rex: few settings, every useful option one tap away on the thing it acts on, and nothing on screen without a reason.

## Settings

- About five top-level rows, at most two levels deep, opened as a sheet with a single "Done" button.
- Each row shows its current value, for example "Google", "Side tabs" or "After 1 day".
- Every row is a choice the user understands and would want to make. Plain's rows are: Search Engine, Tab Layout, Archive Tabs, Clear History and Data, and About.
- Footers are one plain sentence that teaches, for example "Tabs you haven't opened in a day move to the archive."
- Labels are Title Case nouns ("Search Engine", "Clear History and Data").

**Fixed choices.** Every value Plain decides instead of asking lives in one file of named constants, with a short comment saying why (`BrowserCore/FixedChoices.swift`). Examples: blocking is always on, haptics follow iOS, text follows Dynamic Type, and the archive default is 1 day.

## Options live on the object

- **Page menu:** one menu from the URL pill. It holds Reload, Find on Page, Share, Copy Link, Desktop Site, Zoom, Turn Off Blocking on This Site, Open in Other Pane (Duo), and Add to Favorites. Items appear only when they apply. Destructive items go in their own last section.
- **Context menus on links, tabs and favorites:** Open in New Tab, Open in Other Pane, Copy Link, Share, Close, Pin, Rename favorite.
- **Swipe actions:** quick actions with no confirmation, for example close a tab or delete a history row.
- **Confirmations:** only for destructive actions that affect a lot, for example Clear History and Data or Close All Tabs.
- **Gestures are shortcuts, never the only way.** Every gesture has a menu equivalent, and menus name the gesture where it helps ("Next Tab — or swipe the address bar").

## Chrome

- The page gets the screen. Controls show only while they apply, for example the progress bar while loading or a "Reopen tab" toast after a close.
- No badges, banners or standing overlays.
- Plus buttons act at once when there is one obvious action, and become a menu only when there is a real choice.

## State rules

- Every control earns its place in the current state. The full matrix, with the reason for every
  cell and the open gaps, is `docs/state-rules.md`.
- A button, its gesture and its menu item follow one condition. The tabs button, the swipe up and
  Show All Tabs show only when there is another tab to switch to; with one tab the slot is New Tab.
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
- First run is the search field with the keyboard up. There is no onboarding, and permissions (camera, location, notifications) are asked only when a site needs them.

## Visual and motion

- One accent color (Lagoon Blue, from `Brand/identity.md`) and semantic colors from `DesignSystem`. No hard-coded colors in features.
- System text styles with Dynamic Type. Tap targets are at least 44 pt.
- Corner radii of 6–10 pt. Liquid Glass only on floating controls, built with one shared helper.
- Motion vocabulary: `.snappy(0.15–0.3)` for most changes, `.spring(0.32–0.42, bounce 0–0.12)` for gesture-driven moves, `.easeInOut(0.2)` crossfade under Reduce Motion. The full table is in the plan.
- One `Haptic` enum: `tap`, `selection`, `threshold`, `success`, and a rate-limited "nothing there" bump.

## Wording

- Short and plain, with Title Case for labels and sentence case for footers and messages.
- Error messages are written by Plain from known error cases, never raw WebKit or server text.
