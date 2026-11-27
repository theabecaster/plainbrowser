# Polish backlog

Findings left after a feature's review rounds (docs/workflow.md), and known gaps to pick up later.
Newest feature last.

## M1 shell (Lane A, 2026-11-26)

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

- **The focus rim.** The field's mint-to-blue rim reads as a second accent. Either adjust or
  record it as an exception in docs/ui-reference.md. (The sheets' grouped-list radius is now a
  recorded exception: "Sheets on paper" in docs/decisions.md.)
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

- **Downloads sheet styling.** The gap under the toolbar and the bold empty-state sentence come
  from the system `List` and `ContentUnavailableView`, shared with History. The card's radius is
  now a recorded exception ("Sheets on paper" in docs/decisions.md). (Design review, round 1.)
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
- **Geolocation and motion prompts on the simulator.** WebKit never asked the UI delegate for
  `http://localhost` test pages (not a secure context), so the captured prompt is the camera one,
  shown through a debug launch argument. Check location and camera prompts on the device.
- **Duo inner screen captures.** The simulator's fold state is set only in Device Hub, so this
  round has iPhone 17 and Duo outer screenshots only.

## M2 shell wiring: tabs, gallery, bar swipe, private (2026-11-26)

- **Zoom from the Duo's vertical bar.** UIKit gives no way to update an open `UIBarButtonItem`
  menu, so there each zoom step closes the menu (the pill's and the glass bar's menus stay open
  and update).
- **Blocking per site in private tabs.** Hidden: the allow-list is persistent. A memory-only
  private allow-list in `ContentBlocker` would bring the toggle back. (Code review, round 1.)
- **Drop the gallery snapshot at the visual settle.** `gallery.show` now ends when the page is
  within 0.5 pt of its card (budget 650/800 ms), but the snapshot and the transition still run to
  Core Animation's settle of the spring's tail.
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

- **Book pose.** Pills and toasts avoiding the fold (§8 "Book pose") are the M3 layout's, not
  `ControlRules`'; check them on the device with the state rules in mind.
- **Fixed choices.** The tabs tip's trigger (2 gallery opens) and display count, the bump's
  travel and the edge swipe's commit distance live in their files; move them to `FixedChoices`
  when that file is free of other lanes' edits. (Code review, round 1.)
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
- **Filter fidelity.** Fixed 2026-11-27: the root filter was replaced by per-role darkening
  (emoji, pictures and colored headers now keep their colors; see decisions).
- **Device numbers for per-role darkening.** Script cost and first-frame time were measured in
  the simulator (docs/research/dark-mode.md, section 9). Take `DarkPagesTests/largePageCost` and
  the scroll hitch tests on the Duo; if the first frame on `/apple-big` passes ~33 ms there,
  move the sheet rewrite of sheets below the fold behind the first paint.
- **Dark cards on light sections lose their edge.** A #1d1d1f card on a #f5f5f7 section stays
  #1d1d1f while the section becomes #202022, so the card reads only by its shadow. Safari's
  stated rules do the same (dark backgrounds unchanged). A later pass could lift a dark box
  whose parent was darkened by a few lightness steps.
- **Black-and-white pictures.** Safari inverts simple black-and-white logos in `<img>` after a
  histogram check; Plain leaves every `<img>` as made, so a black wordmark image on a light page
  shows black on dark. Needs a same-origin canvas read; other-origin pictures can't be read.
- **Shadow DOM and frames.** Open shadow roots (web components) and same-site iframes are not
  darkened; their light boxes stay light.
- **Engine limits accepted in review (code review, rounds 1–2):** rules in an anonymous `@layer`
  get a twin in a new anonymous layer, after the page's named layers (unlayered rules still win
  as before); a rule's declarations edited in place through the CSSOM, with no change in rule
  count or first/last rule size, keep the old twin; one very large sheet arriving late is
  rewritten in one go; a border shorthand set from one variable keeps its light color (repeating
  the shorthand would reset widths); a multicolored SVG logo whose outline comes from a grey
  CSS `fill` gets a light outline; a theme class on a large subtree (over 300 elements) keeps its
  old element fixes until each is replaced. Page scripts can read the darkened computed colors
  and the `data-plain-dark` attribute (Safari hides its changes; an app cannot).
- **Link previews.** The link menu's preview web view has no dark pages script, so a light-only
  page previews white in a dark app.
- **Frames.** Iframes are kept as made (an embed in a darkened page stays light), by design; a
  same-site iframe of an article could be darkened with the page.
- **Crossfade duration** (0.3 s) lives in `AppAppearance`; move it to `Motion` when the
  DesignSystem lane is free. (Code review, polish.)
- **Settings polish seen in captures, not this lane's:** the dark sheet's Done capsule reads low
  contrast. (Design review, polish.) Rows' radius: a recorded exception ("Sheets on paper" in
  docs/decisions.md).

## One-tab switcher (2026-11-26)

- **New Tab card entrance.** It grows in after the page has landed on its card, which reads as a
  second animation. Starting it as the zoom settles would feel like one motion, but while the page
  still moves above the gallery the card's overlap would pop at the end; solve both together.
  (Design review, round 2.)
- **New Tab card fade reversal.** Back to one card within the 0.15 s fade-out (a reopen then a
  close), the card restarts its grow-in from nothing instead of from where the fade had it.
  (Code review, round 2.)

## Paper texture (2026-11-26)

- **Reader and Reduce Transparency.** The app's Paper surfaces go flat under Reduce Transparency,
  but WebKit has no `prefers-reduced-transparency`, so the reader page keeps its texture. Bridge the
  setting into the reader (a class on the root, or a flat stylesheet), including changes while it
  is open. (Code review, round 1.)
- **Duo start screen wash.** The start screen's bottom wash (`EmptyTabView`'s glow) ends at the
  start screen's edge, so on the Duo it stops in a hard vertical line at the vertical bar's lane.
  Pre-existing; extend the wash under the lane or fade it out before the edge. (Design review,
  round 1.)
- **Render-pass check on the device.** The simulator test checks the layer gets a pattern color
  with no contents, mask, shadow or rasterizing. Confirm no offscreen pass with Instruments' Core
  Animation instrument on the Duo during the device perf gate.

## Polish lane (2026-11-26)

- **Fixed values outside FixedChoices.** The find bar's close check (every 0.25 s,
  `BrowserViewController+Tab.swift`), the favorites strip's edge fade (28 pt, `SearchSheet.swift`)
  and the held page's top overshoot (12 pt, `TabGalleryTransition.swift`) live in their files;
  move them to `FixedChoices` or `Motion` when those files are free of other lanes' edits. (Code
  review, round 1.)
- **Thumbnail memory on the device.** Thumbnails are now 3x at card width (about 5 MB decoded
  each, 40 MB cache). Check memory with many tabs on the Duo and lower the cache if it pushes the
  app toward a memory warning.

## Sheets on paper (2026-11-26)

- **Supporting text in dark.** Raised to 76 % paper (90 % with Increase Contrast) and readable,
  but the reviewer still finds footers, addresses and times subdued at night. Check on the Duo
  before going higher, which flattens the hierarchy. (Design review, round 2.)

## v0.2 page features: translate, print and PDF, cookie banners (2026-11-27)

- **Translate: sentence context across links.** Each text node is translated alone, so a sentence
  split by a link or bold run loses context. Try `TranslationSession.translate(_: AttributedString)`
  (iOS 26.4) with one run per text node, and map the runs back.
- **Translate: frames and shadow roots.** Only the main frame's document is translated; open
  shadow roots and same-origin frames could follow (Firefox translates each frame on its own).
- **Translate: attributes.** `placeholder`, `title`, `alt`, `aria-label` and button values stay in
  the original language (VoiceOver reads `aria-label`).
- **Translate: the reader.** Translate Page is hidden under the reader; translating the article
  view itself would be the better answer for a foreign article.
- **Translate on the device.** The framework doesn't run in the simulator: the real download sheet,
  `.lowLatency` quality and timings need a check on the Duo.
- **Save as PDF on very long pages.** The first page waits for the page's process to lay out the
  whole document (about 0.4 s for 121 pages on the simulator). Show a small progress cue past
  ~150 ms, or build the pages from `createPDF` off the main thread.
- **Cookie list in its own compiled list.** "Turn Off Cookie Banner Blocking" stops the answering
  but the EasyList Cookie List's hiding stays with the blocking switch. Split the cookie list out
  in tools/blocklists so one switch shows a site's banner as the site made it.
- **Cookie banners: rules updates.** autoconsent ships rule fixes almost daily; bump
  `tools/autoconsent` each release (no remote config).
- **Cookie switch wording.** Design review suggests "Cookie Banner Blocking" with a checkmark
  instead of "Turn Off / On …"; it follows the blocking switch's wording today. Change both
  together if at all.
- **Zoom row's 100%.** Design review: the current value reads as disabled; use secondary text.

## Duo inner screen top bar (2026-11-27)

- **Check on the device.** Built while the Mac was locked: captured in the simulator's resizable
  window, which has no fold and no vertical bar. On the Duo: the vertical bar really goes away on
  unfold and comes back on fold; the status bar's height; where the inner camera's occlusion sits
  against the row; book pose with the bar on the focused pane's side; the unfold motion (pill from
  the bottom to the top).
- **Edit in place at the top?** The pill still rises above the keyboard to edit, a long move from
  the top bar. Safari on iPad edits in place with suggestions under the field.
- **Strip in the row.** With the strip the chrome is 17% of the landscape screen at rest. A Safari
  compact-style row (tabs beside the address) would bring it near 11%, at the cost of short titles.
- **Split divider** runs up behind the top bar; it could stop under the bar.
- **Split focus ring** reads as a strong box around the page (design review, round 2); a lighter
  ring or a tint on the bar's address could mark focus more quietly.
- **Strip overflow cue.** With many tabs the fade at the strip's edge is the only sign of more
  tabs; a count or a scroll position hint may help (design review, round 2).
- **Existing installs keep Left.** Above is the new default, but a stored Tab Layout is kept;
  the owner's Duo may need Settings > Tab Layout > Above once.

## Follow-ups: reveal inset, page menu, cookie probe, History search (2026-11-27)

- **Page menu with a download this session.** On the Duo's outer screen the menu fits a
  readerable foreign page with a closed tab to reopen, but a Downloads row on top of that (only
  after a download this launch) puts the History/Favorites/Settings row about 45 pt past the
  menu's edge, so it scrolls. Options: Downloads in the tabs row, or zoom into Site Settings.
- **Translate Page in the captioned row** loses its visible "French to English" subtitle (VoiceOver
  reads it); "Translating…" no longer shows in the row either.
- **Top bar reveal on the inner screen.** Same `PageInsetState` path as the bottom bar, unit-tested,
  but not frame-checked: the fold can't be set from the command line and XCUITest can't drive the
  simulator's resizable window. Check a fixed page header against the top bar on the Duo.
- **Cookie banners: prehide for known consent managers.** A consent manager found by the probe
  (not by a site rule) gets the engine after DOMContentLoaded, so its banner can show for a moment
  before it is rejected. If it shows on real sites, inject only the prehide CSS of the generic rules
  for the hosts the probe saw, before the engine.
- **Sheet bar hides on the Duo's outer screen.** Scrolled far down, History's title, Clear and Done
  leave the screen there (iOS 27; the same with the old bottom search field, before this change).
  `.toolbarVisibility(.visible, for: .navigationBar)` doesn't keep it. Swipe down still closes the
  sheet and scrolling back up brings the bar. Design review called it blocking; check on the device
  whether the vertical bar is meant to take the items there.
- **Footer step at a reveal.** A fixed page footer now moves up in the frame the bar starts back
  (one motion with the bar, not after it), but in one step: WebKit doesn't animate an inset change,
  and changing it per frame would relayout the page during the spring (engine rule 4).

## System integration (v0.2b, 2026-11-27)

- **Small widget hierarchy.** The dawn window still outweighs the Search field; try a shorter
  window (about 55% of the height) once seen on the device and in StandBy. (Design review, round 2.)
- **Tinted, clear and StandBy.** The `.accented` outline drawing and StandBy (background removed)
  are built but not captured; check them on the device. Lock Screen accessories were rendered
  without the system's accessory background; check spacing there. (Design review, round 2.)
- **Shortcuts app capture.** iOS 27's new-shortcut screen opens on "describe a shortcut", which
  the capture test can't drive, so Plain's actions in the Shortcuts editor are unverified by
  screenshot (the App Intents metadata lists all seven intents and six App Shortcuts, and
  PlainTests performs each). Check once by hand.
- **Spotlight App Shortcut tiles.** Spotlight on the simulator showed the favorite but not Plain's
  App Shortcut tiles; check on the device after a day of use.
- **Cold-launch command sequences.** Show Tabs then another command during restore is handled
  (the later one cancels the wait) but has no UI test; add one if it ever regresses.
- **Site icons in the widget.** Favorites are monograms in the widget and above the keyboard; if
  favorites ever get site icons, do both together. (Design review, round 1.)
- **Isolation check limits** (landing review, round 2). The guard check ignores `//` lines but not
  `/* … */` comments, and an App Shortcuts update counts as inside `SystemSync.live`'s closure by
  being within three lines of it, not by parsing. Both are safe today; tighten if the files grow.
- **Widget captures on a device.** The widget extension is started by the system without the
  app's isolation arguments, so it reads the installed app's real App Group. That is why
  `SystemCaptureTests` runs on simulators only; a device capture would need a throwaway install.
## Duo inner: no band at the top (2026-11-27)

- **Header fill at rest.** On a site with a fixed or sticky header, WebKit paints the header's
  color into the page's top inset behind the floating controls at rest (Safari does the same).
  An inset of 0 at rest makes WebKit load pages with the first line under the row, so it stays;
  the owner judges it on the device (docs/decisions.md, "No band at the top").
- **Portrait strip, three tabs.** The selected tab ends tight against the strip's "+" and its
  close button looks clipped where the strip stops beside the status corner (design review,
  round 1). Not changed by this lane.
- **Integration coverage.** Unit tests cover the inset values only; add UI checks for the hidden
  edge effects and the split's other pane insets (code review, round 1).
