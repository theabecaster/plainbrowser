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

- **Engine seam: keep state files for closed and archived tabs.** `WebViewPool.close` deletes the
  tab's state file, but Reopen Closed Tab and archive restore want it (back/forward list, scroll).
  The shell should drop the engine tab without deleting the file after `close` and
  `archiveIdleTabs`; Storage's `TabSessionWriter` deletes state files once no row names the tab.
- **Thumbnail files.** Storage keeps only the file name and revision; the engine should prune
  thumbnail files outside `AppDatabase.referencedTabIDs()` at launch.

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
- **Downloads title.** The "Downloads" title sits beside Show in Files instead of centered. (Lead review.)

## M2b tab gallery (2026-11-26)

- **Decided values outside FixedChoices.** `TabGalleryChoices` (Reopen toast 4 s, 64 MB preview
  cache, 180 pt minimum grid card) and `TabGalleryMetrics.gridAspect` (0.62–1.1) belong in
  `FixedChoices`; the gallery signposts (`TabGallerySignposts.swift`) belong in `PerfSignposts`.
  Kept in TabGalleryUI because this lane could not edit BrowserCore or PerfSignposts.
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
- **Downloads list.** A finished download is an alert with Open; there is no list of downloads
  in progress or past ones yet. M4 can add one in the page menu.
- **Restored tabs beyond the last.** Only the last selected tab comes back after a relaunch; the
  other rows stay in Storage for M2's tab gallery.
