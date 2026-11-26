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
