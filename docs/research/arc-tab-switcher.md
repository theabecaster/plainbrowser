# Arc Search's tab switcher, and the spec Plain builds from it (2026-11-26)

The owner asked for the tab gallery to work like Arc Search's, which is modeled on the iPhone app
switcher. This note records what is known about Arc's switcher, what was measured, the iOS
physics behind it, and the numbers Plain uses. Plain reproduces the interaction model and the feel,
not Arc's assets, colors or exact visuals: cards, bar and background use Plain's own look
(`Brand/identity.md`, `DesignSystem`, Liquid Glass only on the floating bar).

Tags: **[C]** confirmed by a source, **[M]** measured from a screenshot, **[I]** inferred.

## 1. What Arc Search does

**Layout**
- Tabs sit in one horizontal row, oldest on the left and newest on the right. MacStories calls it
  "modeled after the typical multitasking UI" and says it "looks like an iPhone app switcher". It
  shows fewer tabs at once than Safari's grid, and its animations are "fluid and snappy", faster
  than Safari's. **[C]** [MacStories]
- The Android version shows "each shrunken tab window … one at a time" and scrolls sideways.
  **[C]** [Android Authority]
- Measured from the App Store screenshot "No more 100+ tab chaos" (phone screen 808 px wide):
  - A card is about **0.66 of the screen**, in the screen's own proportions, centered. **[M]**
  - Later tabs lie **on top**: the card to the right starts **0.78 card widths** right of the
    centered card's left edge, so it covers the centered card's right 22%. **[M]**
  - The first card to the left peeks **0.21 card width**, the second only **~0.045**, pinned at
    the screen edge. **[M]**
  - Left cards shrink to about **0.95** (scaled about their center); right cards keep full size.
    **[M]**
  - About four cards show at once. **[M]**
  - Each card has a small rounded-square site icon and the title **above** it, left-aligned. A
    title shows only on the card with room for it; covered cards show just the icon. **[M]**
  - A soft shadow separates overlapping cards. **[M]**
  - The background is Arc's theme gradient, not a blur of the page. **[M]**
- Controls in the switcher: an Archive button that opens a searchable list grouped by day, a
  Settings gear, a new-tab button. **[C]** [TidBITS], [Arc hidden features]

**Gestures**
- Open the switcher by tapping the tab button at the bottom, or by swiping up on it. **[C]**
  [TidBITS], [Arc blog]
- Swipe a card up to close (MacStories) or archive (TidBITS) it. **[C]**
- Tap a card to open it. **[C]** The zoom itself, scroll physics, haptics and how neighbors close a
  gap are not described anywhere. Plain takes those from the iOS app switcher.

## 2. The iOS physics it imitates

From WWDC18 "Designing Fluid Interfaces" (session 803) and the reference code that implements it
(nathangitter/fluid-interfaces). **[C]**
- Start with no bounce (damping 1.0). Add a little bounce only when the gesture carries momentum
  (Music: 1.0 to open Now Playing, 0.8 to swipe it away).
- Lock a gesture's axis after about 10 pt of movement (hysteresis).
- Project where a flick ends with the scroll view's deceleration and decide from that:
  `projection = (v / 1000) · d / (1 − d)`, with d = 0.998 (`.normal`) or 0.99 (`.fast`).
- Spring from response and damping ratio: stiffness `(2π / response)²`, damping `4πζ / response`.
- Rubber band: `(1 − 1 / (x · c / d + 1)) · d`, c = 0.55 (UIScrollView, reverse-engineered).
- Every animation must be redirectable mid-flight, starting from what is on screen.

Open-source recreations of the app switcher (StackSwipe, crafterm/swiftui-app-switcher) use the
same shape: a card about 66% of the screen, left cards stacking geometrically (each step about
0.28 of the one before), right cards spreading faster than linear, left scale down to 0.90–0.94.
They agree with the Arc measurements. Apple has not published its own numbers. **[C]**

## 3. Plain's spec

**Compact width (phones, the Duo's outer screen): the cascade**
- Card: the page's shape, `min(0.66 × safe width, height left between the status bar and the
  floating bar)`. On iPhone 17 that is 265 × 576 pt. Title row above it: 20 pt icon, title in
  Subheadline semibold, 8 pt gap. Corner radius `Radius.large` (10 pt, ui-reference).
- Position of a card at `r = index − scroll position` (in cards), in card widths from the focus:
  - left (`r < 0`): `−0.294 · (1 − e^(1.252 r))` → −0.21 at r = −1, −0.27 at r = −2, limit −0.29;
  - right (`r ≥ 0`): `0.368 r + 0.412 r²` → 0.78 at r = 1, off screen by r = 2.
  - Both sides have slope 0.368 at r = 0, so a card never jerks as it passes the middle. Cards to
    the right move faster than the finger, cards to the left slower: the app switcher's parallax.
- Scale: 1 at and right of the focus; left `1 − 0.05 · depth / depth(−1)` → 0.95, then 0.93.
- Z order: later tabs on top. Touches go to the card drawn on top.
- Title shows when 55–70% of the card is uncovered (fades in between), masked to the uncovered
  width; the icon fades out when its strip is narrower than the icon.
- Scroll: one card per 0.78 card widths (207 pt on iPhone 17), so the focused card follows the
  finger on average. Free scroll with `UIScrollView`'s `.normal` deceleration (0.998) and its
  rubber band; on release the system's projected stop is rounded to the nearest card, and a flick
  faster than 0.3 pt/ms always moves at least one card. The selected tab rests in the focus when
  the gallery opens.

**Regular width (the Duo's inner screen): pages of an even grid**
- Arc Search has no large-screen layout. The cascade shows four cards on 951 pt; the iPad app
  switcher, Apple's answer for big screens, is a grid that scrolls sideways. Plain uses that: 4
  columns × 2 rows in landscape (217 pt cards), 2 × 2 in portrait, one page per flick. Columns
  stay even and centered, so the middle gap sits on the fold at rest. Same swipe up to close.

**Close: swipe a card up**
- The axis locks after 6 pt from touch-down: within 60° of straight up lifts the card, flatter
  scrolls (2026-11-27, docs/research/tab-drag-feel.md; was a 45° split decided by a pan).
- Up tracks 1:1 from touch-down, with no smoothing spring; down rubber-bands (c = 0.55 over the
  card's height.
- Closes when the projection (d = 0.99) passes **40% of the card's height**, or the flick is
  faster than **500 pt/s** up (was 800, 2026-11-27: a light flick fell short); a release moving down faster than 300 pt/s keeps the card.
- Otherwise it springs back: `.spring(duration: 0.32, bounce: 0.12)` (momentum earns the bounce).
- A closing card flies up off the screen with `.spring(duration: 0.3, bounce: 0)`, continuing
  the finger's tracking spring, so it keeps the release velocity with no hand-off.
- The cards after it slide into the gap at once: `Spring(duration: 0.35, bounce: 0.1)` (damping
  0.9), frame by frame, so a scroll or a second close joins in without a jump. Closing the last
  card slides the stack right instead. Soft impact haptic on commit; the Reopen Tab toast shows.

**Open: tap a card**
- The page grows from the card with `.spring(duration: 0.42, bounce: 0.06)` (plan motion table), and
  the whole cascade zooms with it about the card, so the neighbors slide out past the screen edges
  exactly as the app switcher does. The reverse plays when the gallery opens; either way can be
  reversed mid-flight. Reduce Motion: 0.2 s crossfade.

**Enter: swipe up from the address bar (the home-indicator swipe)**
- The page becomes a card that follows the finger: its bottom edge stays under the finger and it
  moves sideways with it. It shrinks with the distance travelled and is card-sized after 40% of
  the page's height; past that it rubber-bands (c = 0.55) to at most 15% smaller. The other cards
  zoom in around it, so the neighbors slide in from the sides as it shrinks.
- Release: a flick up faster than 600 pt/s lands in the gallery; a release moving down faster
  than 300 pt/s goes back to the page; otherwise the projection (d = 0.99) must pass 30% of the
  way. (The app switcher sends a fast flick home; a browser has no home, so a flick commits.)
  The spring continues the finger's tracking animation, so the card keeps its velocity.
- The tabs button runs the same animation, driven.

**Leave without choosing**
- A tap or a swipe up (40 pt, or a flick) on the space around the cards opens the tab on screen,
  as a tap or a swipe up in the app switcher goes home.

**Look**
- The cards float over the page they came from, blurred (thin dark material) and dimmed with Deep
  Lagoon at 42%, as the app switcher floats over a blurred Home Screen and Arc's switcher over its
  backdrop. The gallery is always dark, so titles and the glass bar read the same in either
  appearance. Private tabs tint the dim with the private dusk.
- Titles and icons fade out while the cards are zoomed in (an open or the swipe up), so they never
  cross the status bar.

**Empty states (Arc: never an empty switcher)**
- Arc closes the last tab straight into search with the keyboard up, over a pastel screen with its
  logo, which a finger can spin like a fidget spinner. With zero tabs the switcher cannot be
  reached. [C] Arc blog "hidden features" (archived), Android release notes v1.9.0.
- Plain: no tabs → the tabs button and the swipe up open the search field, never an empty gallery.
  An empty tab (no page, or no tab at all) shows the start screen: the Stem mark (paper ring, the
  dawn, the stem, the coral fold), large, in the space above the search field and the favorites
  strip, over paper warming toward Lagoon at the bottom. A finger spins it and it keeps turning
  with the flick (friction: 12% of the speed left after a second). Under it one sentence ("Start
  with a search or an address.") and, while the keyboard is down, one button (Search). The search
  sheet is clear over it, so the mark shows with the keyboard up too. A slot under the sentence
  takes one card above the search field (the coming "Set as Default Browser" offer).
- A new tab's card in the gallery is the start screen in small (the mark on paper), never a blank
  white card. The private gallery's empty state keeps its sentence and button, with the mark above.

**One tab (2026-11-26)**

The owner asked that a swipe up with one tab open the switcher, with a way to add a tab or just
see the one. What the references do:
- **Arc Search** has no one-tab exception. Its bar keeps a tab-stack button (bottom left, a tap or
  a swipe up opens the switcher) next to a separate "+" that starts a search, which a long press
  turns into voice search. The switcher is reachable with any tab open, and the "+" is always the
  quick way to a new page. **[C]** [TidBITS], [MacStories], [Arc blog], [9to5Mac voice search]
  How the switcher lays out a single card is not described anywhere. From its model (oldest left,
  newest right, the selected tab in the focus), one card rests in the focus, centered. **[I]**
- **The iOS app switcher**: swipe up from the bottom and hold opens it with any number of apps;
  each app is a card, tap opens it, swipe up quits it. **[C]** [Apple: Switch apps] With one app
  open, that card rests in the middle, alone; the way out is a tap on the empty space or a swipe
  up (home). It offers no "new app" card. **[I]** (no source names the one-app case).
- **Safari** shows its tab overview with one tab too (the grid with one preview); New Tab is the
  "+" in the overview's bar, and a long press on it lists recently closed tabs. **[C]** [Apple:
  Open and close tabs] Swiping the address bar left past the last tab opens a new tab. **[C]**
  [iPhone Life] Not found: Safari's exact one-tab layout on iOS 26.

What Plain takes from this:
- The swipe up always means the switcher when there is a card, as in Arc and the app switcher;
  only an empty start screen alone bumps (nothing to show). Show All Tabs follows it.
- The page shrinks into its card with the same interactive motion as with many tabs, and the card
  rests centered, as the app switcher's lone card does: no left-aligned cascade.
- Removed 2026-11-27 (owner: "there's already a simple button under all the tabs, so just remove
  the fake tab that says New Tab"): the lone card rests centered and New Tab is the bar's "+".
  Before that, a paper **New Tab card** sat in the slot after the card, where the next tab would go, at the
  cascade's next-card place (0.78 card widths over, on top, peeking in from the right edge), or
  beside it on the fold in the Duo's grid. It looks like the card past the last tab in the bar
  swipe ("+" and "New Tab" toward its leading edge, so it reads while it peeks) on the paper of a
  new tab's own card. It is where Safari's swipe past the last tab and Arc's "+" lead, made
  visible, so the one-card switcher never looks half empty. It grows in after the page lands on
  its card (while the page moves it would cover the page's edge), and scrolls into the focus like
  a card. The bar keeps "+" and Done.
- Superseded 2026-11-27 (owner): with one tab the tabs button is Tabs and opens this switcher,
  like the swipe up. It had stayed "+" (Arc keeps its "+" beside the switcher button because a
  new page is the common next step); New Tab is now the switcher's "+".

**Other**
- Long-press a card: its menu (Open in Other Pane, Copy Link, Share, Close Tab "Or swipe the card
  up"). Move the finger and the card lifts to be dragged to a new place; the cards make room with
  the same springs, and the gallery scrolls at the edges (up to 900 pt/s).
- Floating glass bar: More (Reopen Closed Tab, Archived Tabs, Close All Tabs), Private, New Tab,
  Done.
- Haptics: soft impact when a close commits, selection tick when a dragged card takes a new place.

## Sources

- [MacStories] https://www.macstories.net/reviews/arc-search-for-iphone/
- [Android Authority] https://www.androidauthority.com/arc-search-browser-3488152/
- [TidBITS] https://tidbits.com/2024/02/15/arc-gains-instant-links-tab-grouping-and-arc-search-iphone-app/
- [Arc hidden features] https://arc.net/blog/arc-search-hidden-features
- [App Store] https://apps.apple.com/us/app/arc-search-modern-ai-browser/id6472513080 (screenshot "No more 100+ tab chaos")
- [Arc blog] https://arc.net/blog/arc-search-hidden-features ("press and hold the + icon", "swipe up on the little tab stack")
- [9to5Mac voice search] https://9to5mac.com/2024/05/02/arc-search-adds-widgets-voice-search/
- [Apple: Switch apps] https://support.apple.com/en-us/118408
- [Apple: Open and close tabs] https://support.apple.com/guide/iphone/open-and-close-tabs-iph489b9313f/ios
- [iPhone Life] https://iphonelife.com/content/quickest-way-to-open-new-tab-safari-your-iphone
- [WWDC18 803] https://developer.apple.com/videos/play/wwdc2018/803/
- [fluid-interfaces] https://github.com/nathangitter/fluid-interfaces
- [Rubber band] https://gist.github.com/originell/6961057, https://www.holko.pl/2014/07/06/inertia-bouncing-rubber-banding-uikit-dynamics/
- [StackSwipe] https://github.com/SoxiaLiSA/StackSwipe
- [swiftui-app-switcher] https://github.com/crafterm/swiftui-app-switcher
