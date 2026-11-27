# Gallery open and bar swipe: where the time goes

Device gate, 2026-11-27 (iPhone Duo, Release, isolated store; perf-log row 6c1231f): gallery open
median 680 ms (target 650, fail 800), bar swipe settle median 526 ms (target 450, fail 650). Both
spreads were tiny (gallery 674–693 ms, swipe 523–531 ms over 10 runs): something deterministic,
not stalls. Goal: comfortably under target (about 550 and 400 ms) without the motion feeling
worse.

## 1. Method

- Simulator `plain-speed-*` (iPhone Duo, outer screen), Release build, the perf gate's own tests
  (`PerfTests.testGalleryOpen`, `testBarSwipe`). Temporary step marks (`os_log` with
  `CACurrentMediaTime`) at each stage of `presentGallery`, the transition's first settle-watch
  frame and its end, and the swipe's release, rest and hand-off; removed before hand-back.
- The springs were modelled exactly (SwiftUI `Spring(duration:bounce:)`: stiffness
  (2π/duration)², damping ratio 1 − bounce), sampled at 120 Hz with the app's own rest rule (within
  0.5 pt and moving less than 0.5 pt a frame).
- Machine load during every run: load average 40–950 on 14 cores (other lanes building and
  testing). Absolute simulator numbers are noisy; the shares and the spring times are not.

## 2. Breakdown before

**Gallery open** (`gallery.show`, 6 runs; ms)

| Stage | Where | Time |
|---|---|---|
| Tap → gallery view controller built and added | main thread, before the interval starts (felt, not measured) | 8–66 |
| Snapshot of the page (`snapshotView(afterScreenUpdates: false)`) and the thumbnail capture call | main | 4–16 |
| Transition set-up: gallery layout, cards placed, card frame measured | main, inside the interval | 7–28 |
| `run()` and the chrome fade | main | 4–11 |
| Rest of that turn: Core Animation commit of the new layers (blur, cards) | main | 11–47 |
| **Interval start → first frame of the zoom** | | **38–85** |
| **First frame → page visibly on its card** (spring `0.42 s`, bounce 0) | spring | **514–549** |
| Interval total | | 554–634 (gate median 555) |

The spring is about 90% of the interval. A critically damped spring approaches its target
exponentially: from 300–800 pt away it needs 0.58–0.66 s to come within half a point, and it
spends its last ~0.15 s moving under 2 pt. The Duo's numbers (674–693 ms) match the inner screen
(page 951 pt wide, larger edge travel to the grid card) plus ~50 ms of set-up.

**Bar swipe** (`tab.swipeSettle`, finger lift → page at rest → hand-off; 6 runs; ms)

| Stage | Time |
|---|---|
| Release → page at rest (spring `0.35 s`, bounce 0.12, from the release velocity) | 298–309 |
| Hand-off (the neighbour's web view moves into the page) | 12–23 |
| Total | 311–327 (gate median 312) |

No main-thread work to speak of: the time is the spring. The device's 526 ms is the same spring on
the Duo's 951 pt inner page: bounce 0.12 overshoots 0.3% of the travel, which is 2–3 pt there (or
after a fast flick on any width), more than the half point the rest rule allows, so the page
creeps back for another ~0.2 s at under a point a frame. On the 382 pt outer page with the test's
release the overshoot stays under half a point, hence 300 ms on the simulator.

| Spring (duration, bounce) | 95% of the way | at rest: outer, 230 pt left, 1200 pt/s | outer, flick 2500 pt/s | inner, 750 pt, 1200 pt/s | inner 950 pt from rest (menu) | overshoot, inner |
|---|---|---|---|---|---|---|
| 0.35, 0.12 (before) | 200–217 ms | 283 | 367 | 508 | 525 | 2.2–2.9 pt |
| 0.35, 0 | 250–267 | 450 | 425 | 542 | 558 | 0 |
| 0.30, 0 | 217–233 | 392 | 367 | 467 | 475 | 0 |
| **0.30, 0.08 (now)** | 192–200 | 292 | 208 | 317 | 325 | < 0.5 pt |

Critically damped (what one might reach for first) is slower to rest, not faster: it has no
overshoot but crawls in. A damping of 0.92 arrives as briskly as the old spring and its overshoot
stays under the rest band at any width.

| Gallery spring | 50% | 90% | 99% | at rest (300–800 pt) | overshoot |
|---|---|---|---|---|---|
| 0.42, 0 (before) | 117 ms | 267 | 450 | 583–658 | 0 |
| **0.42, 0.06 (now)** | 117 | 242 | 383 | 467–500 | < 0.2 pt (≤ 0.18 pt after a 2000 pt/s flick) |

## 3. Fixes

1. **Gallery spring damping 1 → 0.94** (`Motion.galleryZoom`, `.spring(0.42, bounce 0.06)`). Same
   pace through the first half (50% at 117 ms either way), lands the last points ~25–70 ms
   sooner, overshoot under a fifth of a point (invisible). Saves ~100–150 ms of the tail.
2. **Bar swipe spring 0.35/0.12 → 0.30/0.08** (`Motion.tabSwitchSpring`). The same pace to 95%
   (a hair quicker), no visible overshoot on any width, at rest in ~0.3 s everywhere. Saves ~200 ms
   on the Duo's inner page and after fast flicks; ~the same on the outer page.
3. **A gallery kept ready.** The gallery view controller is no longer built on every tap and thrown
   away on close: one is built at idle (a second after the tab list changes, in the default run
   loop mode so never during a scroll or gesture) as a hidden child, laid out at the page's size,
   with its cards placed and their pictures decoded off the main thread; closing the gallery hides
   it again. Opening shows it with `prepareToShow()` (a diff of the tab list, no new views), so the
   first frame no longer waits for the view controller, the blur and the cards to be built, and
   neighbouring cards have their pictures from the first frame instead of popping in. Dropped on a
   memory warning.
4. **The settle watch samples at 120 Hz** (`SpringDriver.frameRateRange`) instead of the display
   link's default, so the end is seen within a frame of when it happens.
5. **`gallery.show` now starts at the tap** (the shell begins it in `presentGallery` and hands it
   to the transition), not when the transition is made: getting the gallery ready and the page's
   snapshot are inside it. Stricter than before (the old interval left out the 8–66 ms of
   building the gallery), so keeping the gallery ready cannot hide work outside the metric
   (Codex review, round 1).
6. **The settle definition is unchanged.** Both intervals still end when the moving thing is
   within 0.5 pt of its target and moving less than 0.5 pt a frame (`Signposts.visualSettle`),
   what the eye sees. No metric was redefined; the motion itself now ends sooner.

Not done: the page snapshot is already the cheap path (`snapshotView(afterScreenUpdates: false)`,
4–16 ms with the capture call), and the card's thumbnail is already decoded off the main thread.

## 4. After

Simulator perf gate (`scripts/perf-gate.sh --sim`, `PLAIN_SIM_PREFIX=plain-speed`, Release, iPhone
Duo outer screen). Rows not kept in docs/perf-log.md (the lead logs the gate on merge).

| | Before (432dad1, load 40–166) | After (load 370–1000) |
|---|---|---|
| Gallery open, median (`gallery.show`) | 555.1 ms | 482.7 ms, now including the set-up from the tap |
| Bar swipe settle, median (`tab.swipeSettle`) | 311.5 ms | 293.1 ms |
| Gallery, per run | 587, 554, 571, 555, 554 | 499, 482, 483, 483, 566 |
| Swipe, per run | 308, 311, 311, 312, 312 | 293, 309, 293, 293, 292 |

The launch rows moved with the load (launch 810 → 1081 ms, last tab 642 → 901 ms on a machine at
load 370–1000; the before run already failed the search-field row at load 166). The spare gallery
is built only after the launch has finished, a second after the tab list changes, so it is not in
those intervals. Some gallery runs failed their page-load waits under that load (setup, not the
measured step), as the before run did.

Predicted on the Duo (inner screen, from the spring model and the device's before numbers; the
lead's device gate decides):

| | Before (device) | After (predicted) |
|---|---|---|
| Gallery open | 680 ms | ~520–550 ms (spring ~470–500 ms to rest, plus set-up now counted) |
| Bar swipe settle | 526 ms | ~330–345 ms (spring ~317–325 ms plus the ~15 ms hand-off) |
