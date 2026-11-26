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
- **Desktop Site.** Remembered per host for the session only, through a desktop user agent. Move it
  to `preferredContentMode` in WebEngine's navigation delegate and persist it per site in Storage.
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

- Shell wiring: the reader web view's navigation delegate must allow only `ReaderRenderer.isReaderURL`
  loads and open every other link in the tab (the reader page itself has JavaScript off and a
  no-script CSP).
- Opening blocks some sites put before the article (Ars' "Biz & IT —" kicker and bold deck) read
  as two extra headings. Could normalize them into `.eyebrow`/`.dek` during extraction.
- No controlled test where an older `ReaderSchemeHandler.show` finishes after a newer one; the
  latest-show guard is covered by a cancellation test only.
- Screenshots so far come from simulator Safari loading the rendered page (an SPM test bundle has
  no window server). Recheck in the app once reader mode is wired, including accessibility text
  sizes and the Duo outer screen.
