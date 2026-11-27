# Polish backlog

Findings left after a feature's review rounds (docs/workflow.md), and known gaps to pick up later.
Newest feature last.

## M1 shell (Lane A, 2026-11-26)

- **Favorites strip edge.** The last visible favorite is cut by the strip's trailing edge. The strip
  scrolls sideways, but an edge fade or a spacing that ends on a half tile would say so more
  clearly. (Design review, round 1.)
- **Edge swipe in UI tests.** `allowsBackForwardNavigationGestures` is on and the swipe tracks
  under XCUITest, but a synthesized release never commits it, so the UI test checks Back and
  Forward through the buttons only. Check the swipe by hand on the Duo.
- **Landscape iPhones.** The pill and the button bar take two rows (102 pt) in compact height.
  Fold them into one row there.
- **Duo inner screen.** The plan turns the vertical bar off in inner landscape (Safari's
  precedent); the shell follows `verticalBarEdge` everywhere for now (M3).
- **Shell constants.** The pull-to-refresh threshold, collapse distance and compact pill scale live
  in `ShellUI/ChromeModel.swift`. Move any that count as product decisions to `FixedChoices`.
- **Sheet close.** While the sheet fades out, the favorites briefly overlap the page coming back.
  Fade the favorites out first. (Design review, round 3.)

## Integration 1: sheets and history wiring (2026-11-26)

- **Favorites strip edge on the Duo.** The last tile is cut where the strip meets the vertical bar
  (same item as Lane A's strip-edge note). (Design review, round 1.)
- **Tab Layout footer.** Two choices joined by a semicolon; one teaching sentence would read
  better ("Side Tabs shows tabs in a sidebar when the window is wide."). FeatureUI wording.
- **Grouped-list radii and the focus rim.** System grouped lists in the sheets use larger radii
  than the 6–10 pt rule, and the field's mint-to-blue rim reads as a second accent. Either adjust
  or record them as exceptions in docs/ui-reference.md.
- **Visits on commit, pushState and reloads.** History records at load end per back-forward item.
  Same-document navigations and reloads are not new visits until WebEngine's navigation delegate
  reports commits (Lane C).

## Reader (lane F)

- Opening blocks some sites put before the article (Ars' "Biz & IT —" kicker and bold deck) read
  as two extra headings. Could normalize them into `.eyebrow`/`.dek` during extraction.
- No controlled test where an older `ReaderSchemeHandler.show` finishes after a newer one; the
  latest-show guard is covered by a cancellation test only.
- Screenshots so far come from simulator Safari loading the rendered page (an SPM test bundle has
  no window server). Recheck in the app once reader mode is wired, including accessibility text
  sizes and the Duo outer screen.

## Shell audit (lane H, 2026-11-26)

- **Fixed values.** The snap's clear-velocity (0.2 pt/ms) and speed cap (8 progress/s) and the glass
  merge spacing (4 pt) live in `ShellUI/ChromeModel.swift` with the other shell constants; move
  any that count as product decisions to `FixedChoices` (BrowserCore, outside the shell lane).
  (Code review, round 1.)
- **Duo inner screen.** Not captured: the fold state is set only from the Device Hub and the Mac
  was locked. Check the bar, the edge effect and the footer inset on the inner screen.
- **Device checks.** On the Duo: 120 Hz during the snap (Animation Hitches trace), how the hard
  edge looks while the bar moves, and the merge of pill and bar glass mid-collapse.
- **Other springs.** Only the snap asks for 80–120 Hz. The URL-focus and sheet springs run through
  `UIView.animate(Animation)`, which takes no frame-rate range; move them to `SpringDriver` if the
  device trace shows them below 120 Hz.
- **Hard edge look.** With the hard edge, page text still shows blurred below and beside the
  resting pill, and the edge's full-width hairline reads as a shelf behind the floating pill,
  mostly when collapsed. Try the soft style again on the device (it left text refracting through
  the pill on the simulator), or a stronger glass tint. (Design review, round 3.)

## Tab model (lane M2a, 2026-11-26)

- Both items (state files kept on close and archive, thumbnail pruning) are done in the M2 shell
  wiring.

## M4 completeness (lane M4, 2026-11-26)

- **Downloads sheet styling.** The list card's large radius, the gap under the toolbar and the bold
  empty-state sentence come from the system `List` and `ContentUnavailableView`, shared with
  History. Revisit both sheets together. (Design review, round 1.)
- **Share in Downloads** uses `ShareLink`, which has no signpost hook. (Code review, round 1.)
- **Iframe images in the link menu.** The pressed-image lookup reads the main frame only, so an
  image inside an iframe gets the link items but not Save Image / Copy Image. A press in an iframe
  does hide an older main-frame image. (Code review, round 1-2.)
- **Synthetic presses.** The press listeners accept untrusted `pointerdown` events (tests depend
  on them), so a page can hide its own image items. Iframe press messages are throttled to one per
  100 ms. (Code review, round 3.)
- **Check on the Duo:** long-press menus and the live preview on real links and images (WebKit's
  element info for an unlinked image), the find bar above the keyboard with the bottom pill, PiP
  and fullscreen flags with a real video, `<input type=file>` and `capture` pickers.

## M2b tab gallery (2026-11-26)

- **Decided values outside FixedChoices.** `TabGalleryChoices` (Reopen toast 4 s, 64 MB preview
  cache, 180 pt minimum grid card) and `TabGalleryMetrics.gridAspect` (0.62–1.1) belong in
  `FixedChoices`. (The gallery signposts moved to `PerfSignposts` with the M2 shell wiring.)
- **Blurry previews on big cards.** `ThumbnailService` captures 200 pt wide; a compact card is
  about 370 pt wide, so its preview is upscaled. Capture visible and neighbour tabs at card width.
- **Bar over a dense grid.** In the inner-landscape grid, titles and close buttons still show
  through the floating bar; the scroll edge effect could suppress more there. (Design review,
  round 2.)
- **XCUITest after a card's long press.** With drag-to-reorder on, XCUITest reports "App
  animations complete notification not received" after the context menu (60 s waits; the app's
  CPU stays at 0). Without the drag interaction it does not happen. Check on the Duo that no drag
  lift animation stays open.
- **Not captured yet.** Duo inner screen on the device (simulated with a 951x669 / 669x951
  container on an iPad simulator; Device Hub has no CLI), Reduce Motion crossfade, accessibility
  text sizes, a tap that reverses a moving page (unit-tested only: XCUITest waits for idle), and
  the 120 Hz hitch numbers on the device.
- **Context menu on a partly hidden card** lifts its preview over the next card. System
  behavior; scrolling the card into view first would avoid it.

## Integration 2: shell on the engine (2026-11-26)

- **Reader web view ownership.** The pool makes the reader's web view (`makeAuxiliaryWebView`) but
  `ReaderPresenter` holds it while it shows. Move holding and release into the pool (an
  auxiliary slot per pane) if a second auxiliary view appears. (Code review, round 1.)
- **Back and Forward when unavailable.** They stay visible and disabled (system style, stable
  layout); the design review asked to hide them. Decide with the shell lane.
- **Page menu on the Duo outer screen.** The last section (Edit Favorites, Settings) scrolls below
  the fold of the menu with no cue. (Design review, round 2.)
- **Geolocation and motion prompts on the simulator.** WebKit never asked the UI delegate for
  `http://localhost` test pages (not a secure context), so the captured prompt is the camera one,
  shown through a debug launch argument. Check location and camera prompts on the device.
- **Duo inner screen captures.** The simulator's fold state is set only in Device Hub, so this
  round has iPhone 17 and Duo outer screenshots only.

## M2 shell wiring: tabs, gallery, bar swipe, private (2026-11-26)

- **Blurry card previews.** Still the M2b item above: thumbnails are 200 pt at 2x (400 px) and a
  phone card is about 370 pt at 3x. A sharper capture needs a bigger file per tab or a top-only
  crop at card width; decide with the memory budget on the Duo. (Design review, round 1.)
- **Page menu length.** The Zoom row adds a row to a menu that already scrolls on the Duo outer
  screen and on iPhone 17 (the last section is cut with no cue). Move History / Edit Favorites /
  Settings to their own submenu or the tabs button, or drop a section. (Design review, round 1.)
- **Zoom from the Duo's vertical bar.** UIKit gives no way to update an open `UIBarButtonItem`
  menu, so there each zoom step closes the menu (the pill's and the glass bar's menus stay open
  and update).
- **Blocking per site in private tabs.** Hidden: the allow-list is persistent. A memory-only
  private allow-list in `ContentBlocker` would bring the toggle back. (Code review, round 1.)
- **gallery.show measures the spring's settle, not what the eye sees.** `TabGalleryTransition`
  completes when Core Animation settles the 0.42 s spring, a steady ~1.48 s (perf gate, sim), so the
  budget is set to it and the metric catches stalls on top. End the interval (and drop the snapshot)
  at the perceptual duration instead, then tighten the budget.
- **Gallery selection ring weight.** The blue ring reads strong in the calm gallery; try a thinner
  ring or the on-glass blue. (Design review, round 1.) Now 2 pt (app-switcher gallery, below).
- **Inner screen and device checks.** No Duo inner screen captures (fold not settable from the
  CLI). Check on the device: the bar swipe at 120 Hz with a live neighbour, a swipe started on a
  page still loading, the swipe-up gallery with the system's vertical bar, private tint in dark
  mode.

## Tab gallery as the app switcher, start screen (2026-11-26)

- **Tune on the Duo.** The swipe-up numbers (card-sized at 40% of the height, commit at 30% or
  600 pt/s), the cascade curve and the close thresholds come from the research and the simulator.
  Feel them on the device; 120 Hz and hitches need the device perf gate (simulator p95 is 1.4–1.6 ms
  of main-thread work per scroll frame with 100 tabs).
- **Duo outer screen.** The status bar's camera bubble overlaps the top corner of the card to the
  right of the focus. Safe area does not include it; `reservedRegions(kind: .occlusion)` could.
- **Grid pages give no hint of the next page.** The inner screen's grid pages fill the width
  exactly (columns even, the fold in the middle gap), so nothing peeks. Consider a page indicator
  in the bar, or a narrow peek on both sides.
- **Corner radius.** Cards keep `Radius.large` (10 pt, ui-reference). The app switcher's cards
  follow the display corners (about 24 pt at card size); revisit with the reference rule.
- **Spin the mark with the keyboard up.** The clear search sheet takes touches over the mark, so a
  tap there closes search (as in Arc: tap the background, then spin). Route touches on the mark to
  it if spinning with the keyboard up is wanted. (Code review, round 2.)
- **Signposts.** Drag lift and cancel in a reorder, and VoiceOver page scrolls, have none. (Code
  review, round 1.)
- **A new tab's zoom.** Opening a new tab's card grows the shell's card picture (`cardPicture`:
  the thumbnail or plain surface), then the start screen appears. Grow the mark instead.
- **Unused motion values.** `Motion.throwClose` and `Motion.throwCloseTiming` no longer have a
  user; drop them once no lane needs them.
- **XCUITest after a long press** still waits for idle up to a minute (M2b item above).
- **A new tab's card after an appearance change.** Its paper resolves from the window scene's
  appearance when shown; switching the system appearance while the always-dark gallery is open
  leaves it stale until the card is configured again. (Code review, round 3.)
- **Dark band at the bottom of page previews.** The shell's thumbnails include the area under the
  resting bar, which shows as a solid dark footer on the cards. Crop it in `ThumbnailService`.
  (Design review, round 3.)

## First-run intro (2026-11-26)

- **Splash-skip UI test proves little.** `testTapSkipsTheSplash` can pass even without the tap
  handler when launch synchronization outlasts the 1.12 s splash. A Debug launch argument that
  holds the splash until tapped would make it a real test. (Code review, rounds 1–2.)
- **Icon step on tall screens.** The 2 x 2 grid leaves a large empty middle above Next on an
  iPhone 17; lower or enlarge the grid on tall layouts, keep the Duo's tighter arrangement.
  (Design review, round 3.)
- **Default-browser prompts back to back.** With the prompts on, "Not Now" on the intro's default
  step is followed by the empty-tab card on the start screen. When the start screen hosts the card,
  skip it for the first session after the intro. (Design review, round 3.)
- **Duo cluttered demo.** The cookie wall still covers most of the photo on the Duo's outer
  screen. Fine as a picture of clutter; a shorter wall or a smaller masthead would show more.
  (Design review, round 3.)
- **Hosting the empty-tab card.** `DefaultBrowserCard` lives in FeatureUI. ShellUI installs the
  start screen (TabGalleryUI's `EmptyTabView`) and already imports FeatureUI, so it can add the
  card there behind `DefaultBrowserPrompts.showsEmptyTabCard()`. The card shows its own mark, so
  hosted on the start screen it should replace that screen's mark and sentence, not stack on them.
- **Two Stem mark views.** The intro's `StemMarkView` (FeatureUI, animated assembly) and the start
  screen's `MarkView` (TabGalleryUI, spinnable) were built in parallel lanes. Move one shared mark
  (geometry from `Brand/tools/gen_icon.py`) to DesignSystem and have both use it.
- **Device numbers.** Splash frame rate and hitches are measured on the simulator only (60 Hz);
  check 120 Hz and the `intro.splash` animation interval on the Duo.
## M3 Duo layouts (2026-11-26)

- **Top pills on the inner screen.** The plan's table gives each pane its own top pill in inner
  landscape; M3 kept the one bottom pill and moved it over the focused pane (the brief: keep the
  existing chrome). Decide on the device whether the inner screen wants top pills. (Design
  review, round 1.)
- **Open in New Window** needs one app-wide `TabStore` shared by scenes, and a fresh window for a
  scene whose saved window is gone (today it takes the first window; one scene only). (Code
  review, round 1.)
- **Drop a tab on the other pane to split** (plan, side tabs) and drag a tab between panes are not
  built; Open in Other Pane covers it from the menus.
- **Site icons in the rail.** Rows show a letter tile until Storage's favicons reach the shell.
- **Inner portrait split.** Off by design (two 334 pt panes); a stacked second pane is not built.
- **A tab moving between panes** (Open in Other Pane on the page itself, Swap Panes) re-parents its
  web view with no snapshot cover; check on the device for a blank frame.
- **Expanded sidebar floating** casts a light shadow; check its edge on the device and in dark mode.
- **Pill margin in book pose.** Shifted off the crease, the pill keeps the 12 pt side margin of a
  phone-width lane, which reads tight next to the centered 640 pt pill when flat. (Design review,
  round 1.)
- **Tab strip reloads twice per action.** A tap, close or reorder reloads the strip at once (for
  instant feedback) and again on the store's change notification; fold them into the one
  notification if profiling shows it. (Code review, round 3.)
- **Above and Right on the device.** Both were built after the Mac locked: unit-tested
  (`DuoLayoutTests`) and UI-tested only as far as the simulator allowed; check the strip's look
  and the Right sidebar's drag on the inner screen.
## State rules (state lane, 2026-11-26)

- **Find on Page and the bar.** Bar gestures stop while the find bar is open, but the page's bar
  is not replaced by it (§7, §8 "Find open"); the keyboard covers it today. Hide the bar while
  Find is open. (Code review, round 1.)
- **Book pose.** Pills and toasts avoiding the fold (§8 "Book pose") are the M3 layout's, not
  `ControlRules`'; check them on the device with the state rules in mind.
- **Sheet failure states.** History, Archive and Favorites show OK on a failed read, not Try
  Again, and History's Clear is enabled with an empty history while a search is typed (§6,
  Sheets; pre-existing, not in the gaps list). (Code review, round 1.)
- **The pill on a failed page** shows the last committed address, not the one that was tried;
  Share and Copy already use the tried address. (Code review, round 1.)
- **Fixed choices.** The tabs tip's trigger (2 gallery opens) and display count, the bump's
  travel and the edge swipe's commit distance live in their files; move them to `FixedChoices`
  when that file is free of other lanes' edits. (Code review, round 1.)
- **The bar on the start screen.** With nothing open, the full-width glass bar holds only More at
  its right end. Start is its own mode, so the bar may change shape: a compact More capsule, as the
  Duo's vertical bar shows it, would read better. (Design review, round 1.)
- **Long page menu.** With every item that applies, More on a page runs past the screen and
  History is cut at the bottom edge; the system menu scrolls, but nothing says so. Consider moving
  the app section (Downloads, History, Edit Favorites, Settings) into a submenu. (Design review,
  round 1.)
- **Start screen recede values.** The 94 % scale and the drift live in `EmptyTabView.setReceded`;
  move them to `Motion` with the other motion values. (Code review, round 3.)
- **Signposts.** New Tab reusing an empty tab emits no `tab.open`; the tip's display and
  retirement emit none. (Code review, round 1.)

## Appearance and dark pages (2026-11-26)

- **Device hitch numbers for dark pages.** The simulator has no hitch metric; its in-page frame
  proxy showed no difference (docs/research/dark-mode.md, section 8). Run
  `AppearanceTests/testScrollHitchesDarkened` and `testScrollHitchesDarkPagesOff` on the Duo
  (`TEST_RUNNER_PLAIN_DARK_PERF=1`). If darkened is worse by a measurable margin, switch the
  darkening to Dark Reader's dynamic mode (MIT; research, section 4) behind the same judgement.
- **Filter fidelity.** Darkening flips emoji and CSS-drawn artwork with the text, and pictures
  given the filter twice lose a little saturation in very light or very dark saturated colors
  (CSS filters clamp between steps): a pale yellow comes back cream. Colored text headers flip
  in lightness (a blue bar with white text becomes light blue with black text). Inherent to the
  filter; a style rewrite or Safari's in-engine darkening (private API on iOS 27) avoids it.
  (Design review, round 1, blocking; accepted as the technique's trade, see decisions.)
- **Link previews.** The link menu's preview web view has no dark pages script, so a light-only
  page previews white in a dark app.
- **Frames.** Iframes are kept as made (an embed in a darkened page stays light), by design; a
  same-site iframe of an article could be darkened with the page.
- **Crossfade duration** (0.3 s) lives in `AppAppearance`; move it to `Motion` when the
  DesignSystem lane is free. (Code review, polish.)
- **Settings polish seen in captures, not this lane's:** the dark sheet's Done capsule reads low
  contrast; rows are full capsules where ui-reference says 6–10 pt corners; the Archive Tabs
  footer says "used" where ui-reference says "opened". (Design review, polish.)

## One-tab switcher (2026-11-26)

- **Card footer band.** A page's card shows a dark band under the page picture: the thumbnail is
  shorter than the card (the card takes the whole screen's shape), so the card's surface shows.
  Every gallery card has it, not only the lone one. Capture the thumbnail at the card's aspect or
  fill the card with the page's background. (Design review, round 1; flagged blocking, left here
  because it predates this lane and touches the thumbnail pipeline.)
- **Heading under the status bar mid-swipe.** Held part way up, the shrinking page's top passes
  under the clock and the Dynamic Island, as in the app switcher. Consider keeping the page's top
  inset while it shrinks. (Design review, round 1.)
- **Gallery bar contrast and backdrop blur.** The bar's pale blue glyphs on the dark glass read a
  little inactive, and the blurred backdrop reads mostly as flat slate. (Design review, round 1.)
- **Duo outer: the next card under the status column.** The New Tab card (like any next card in the
  cascade) runs under the system's vertical bar, where the status icons draw over it. Clip the
  cascade to the safe area there.
- **New Tab card entrance.** It grows in after the page has landed on its card, which reads as a
  second animation. Starting it as the zoom settles would feel like one motion, but while the page
  still moves above the gallery the card's overlap would pop at the end; solve both together.
  (Design review, round 2.)
- **New Tab card fade reversal.** Back to one card within the 0.15 s fade-out (a reopen then a
  close), the card restarts its grow-in from nothing instead of from where the fade had it.
  (Code review, round 2.)
