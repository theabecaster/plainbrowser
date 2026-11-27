# Perf goals: realistic, best-in-class numbers

Researched 2026-11-27 for the perf program. The budgets live in `perf/budgets.json` (a `why` per
metric). This page records where each number comes from.

Rule of thumb: a metric's **target** is the best realistic number, what a perfect native app
reaches, set near the perception threshold or the best competitor and never looser than today's
device number. Its **fail** is an absolute regression guard. Between the two, the gate's ratchet
holds every metric near its best recent device value (see "The ratchet" below).

## What people perceive

| Threshold | What it means | Source |
|---|---|---|
| 100 ms | A response feels instant; no feedback needed | Nielsen, [Response times: the 3 important limits](https://www.nngroup.com/articles/response-times-3-important-limits/) (after Miller 1968, Card et al. 1991) |
| 1 s | The user's train of thought stays unbroken | same |
| 100 ms response, input handled in ≤ 50 ms | RAIL: finish a tap's visible response within 100 ms; keep handlers to 50 ms so other work fits | web.dev, [RAIL](https://web.dev/articles/rail) |
| 100 ms | Apple's line for a noticeable delay after a tap (a hang) | Apple, [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness) |
| 8.3 ms per frame at 120 Hz (16.7 at 60) | ProMotion frame budget; under ~5 ms of main-thread work per frame is usually on time | same; [Optimizing ProMotion refresh rates](https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays) |
| 25–33 ms | Finger-to-pixel latency at 120 Hz, by rendering mode | Apple, [Understanding hitches in your app](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app) |
| ~1 vs 6 ms | Users tell 1 ms from 6 ms drag latency on a touch screen (Ng et al., UIST 2012) | cited in [Jota et al. / Annett et al., GI 2014](https://sites.ualberta.ca/~wfb/publications/C-2014-GI-Latency.pdf) |
| ~64 ms | Below this, users can't tell a tap's latency from 1 ms (Jota et al., CHI 2013) | same |

Consequences for Plain:

- A tap's first visible response must land within 100 ms, and well inside it: the 25–33 ms
  finger-to-pixel path is already spent before the app does anything.
- Motion that follows the finger (bar swipe, gallery swipe) must hold every 8.3 ms frame.
- Page content in `WKWebView` is held near 60 fps by WebKit; no public API lifts it
  ([WebKit bug 294338](https://bugs.webkit.org/show_bug.cgi?id=294338), open 2026-11). The
  native chrome still runs at 120 Hz, so the hitch metrics hold the chrome to 120 Hz and the page
  to its 60 Hz cadence.

## Apple's guidance

| Number | What | Source |
|---|---|---|
| 400 ms | Icon tap to first frame; about 100 ms is the system's, leaving ~300 ms for the app | WWDC19 [Optimizing App Launch](https://developer.apple.com/videos/play/wwdc2019/423/) |
| no number | Current launch doc defines the metric (tap to first frame, Organizer's p50/p90) but sets no target | [Reducing your app's launch time](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time) |
| < 5 ms/s good, 5–10 noticeable, ≥ 10 critical | Hitch time ratio tiers (2020) | WWDC20 [Eliminate animation hitches with XCTest](https://developer.apple.com/videos/play/wwdc2020/10077/); Tech Talk [Explore UI animation hitches and the render loop](https://developer.apple.com/videos/play/tech-talks/10855/) |
| ≤ 10 good, ≤ 25 warning, ≤ 50 critical | Hitch tiers in the current docs (looser) | [Understanding hitches in your app](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app) |
| `CAFrameRateRange(80, 120, 120)` | Apple's suggestion for high-impact animations | [Optimizing ProMotion refresh rates](https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays) |
| delta | `XCTMemoryMetric`'s Memory Physical is the change over the measured block, not the footprint | [XCTMemoryMetric](https://developer.apple.com/documentation/xctest/xctmemorymetric) |

Plain uses the stricter 2020 hitch tiers: 5 ms/s is the fail line, 0 the target.

## Motion: the system's own timings

| Number | What | Source |
|---|---|---|
| 0.5 s, bounce 0 | `UIView.animate(springDuration:bounce:)` and SwiftUI `Spring` defaults; `.smooth` and `.snappy` default to 0.5 s | [UIView spring](https://developer.apple.com/documentation/uikit/uiview/animate(springduration:bounce:initialspringvelocity:delay:options:animations:completion:)), [SwiftUI smooth](https://developer.apple.com/documentation/swiftui/animation/smooth(duration:extrabounce:)) |
| bounce 0 when unsure, ≤ ~0.4 for UI | Springs set by perceived duration and bounce | WWDC23 [Animate with springs](https://developer.apple.com/videos/play/wwdc2023/10158/) |
| 100% damping, 80% for a flick with momentum | Fluid interfaces: no overshoot unless momentum drives it; rubber-band at edges | WWDC18 [Designing Fluid Interfaces](https://developer.apple.com/videos/play/wwdc2018/803/) |
| ~0.25 s, curve 7 | What the keyboard notifications usually report for the keyboard's rise; the curve is private and other durations appear | [Developer forums](https://developer.apple.com/forums/thread/48088), [keyboardAnimationDurationUserInfoKey](https://developer.apple.com/documentation/uikit/uiresponder/keyboardanimationdurationuserinfokey) |

A spring's visible end is not its nominal duration. A critically damped spring with response
`d` covers `D` points as `D·(1+ωt)·e^(−ωt)`, `ω = 2π/d`; it is within 0.5 pt of a 400 pt move
after `ωt ≈ 9`, so a 0.42 s spring (the gallery) visibly rests at ~0.60 s. That is the floor for
any interval that ends at the visual settle; the target adds one 120 Hz frame.

## Other browsers

No credible published numbers exist for any iOS browser's cold launch, tab switcher, address bar
focus or memory per tab (Safari, Chrome, Firefox, Arc Search, Brave, DuckDuckGo). What exists:

| Number | What | Source |
|---|---|---|
| LCP ≤ 2.5 s, INP ≤ 200 ms, CLS ≤ 0.1 (p75) | Core Web Vitals "good" | web.dev, [Web Vitals](https://web.dev/articles/vitals) |
| FCP ≤ 1.8 s good, > 3.0 s poor | First contentful paint over the network | web.dev, [FCP](https://web.dev/articles/fcp) |
| Speedometer 3.0, iPhone 15 Pro Max: Safari 27.6, Firefox 26.4, Chrome 24.5, Arc 23.6, Brave 23.0 | Web app speed (all WebKit on iOS); not launch | [Applesfera, 2024](https://www.applesfera.com/aplicaciones-ios/hemos-medido-cual-navegador-rapido-dentro-iphone-hay-diferencia-que-esperaba) |
| `Startup.ColdStartFromMain` | Chrome iOS measures launch from `main`, like Plain's `launch.firstFrame`; no published values | [Chromium source](https://chromium.googlesource.com/chromium/src/+/e6fa44fa873b2b51bb363bfa6cd168caa0aa11f7) |
| ~979–1,160 ms | Firefox Android cold launch to first frame, median, lab device (2024) | [Bugzilla 1909258](https://bugzilla.mozilla.org/show_bug.cgi?id=1909258) |

Since competitors publish nothing comparable, the targets come from perception and physics: the
100 ms threshold, the 8.3 ms frame, Apple's launch budget, and the springs' own settle times. The
open item is to measure Safari on the Duo with the same scripted interactions (a screen recording
at 120 fps, frame-counted) and add it as the competitor column.

## Plain's goals

Today is the device row of 2026-11-27 12:00 (`6c1231f`). New metrics have no device row yet; the
lead's first device run fills them in. Simulator numbers are trends only.

| Metric | Today (device) | Sim, 2026-11-27 | Target | Fail | Why | Source |
|---|---|---|---|---|---|---|
| `launchMs`: `main` to first frame | 225 | 804 | 150 | 300 | Apple's 400 ms tap-to-first-frame leaves ~300 for the app; pre-`main` is outside this interval, so a lean app needs about half | WWDC19 423 |
| `searchFieldMs`: `main` to field focused | 198 | 425 | 150 | 300 | The field focuses before the first frame: same budget as launch | WWDC19 423 |
| `lastTabMs`: launch with the last tab's picture | 214 | 618 | 150 | 300 | Same budget; the picture decodes off the main thread | WWDC19 423 |
| `hitchMsPerS`: scroll an ordinary page | 0 | n/a | 0 | 5 | Plain already drops nothing; fail at Apple's 2020 "good" ceiling (stricter than today's doc) | WWDC20 10077, Tech Talk 10855 |
| `heavyHitchMsPerS`: scroll a 6,300-element page darkened | — | n/a | 0 | 10 | Scrolling is composited off the main thread; dark pages must add no hitch. Fail at Apple's current "good" ceiling until device rows exist | Understanding hitches; dark-mode.md |
| `galleryMs`: tabs button to gallery at rest | 680 | 554 | 610 | 750 | The 0.42 s critically damped spring is within 0.5 pt at ~0.60 s; +1 frame | Spring math above; plan motion table |
| `galleryTabMs`: card tap to page at rest | — | GALLERY_TAB_SIM | 610 | 750 | The same spring in reverse | same |
| `swipeMs`: finger lift to page at rest | 526 | 310 | 320 | 600 | The 0.35 s spring rests in ~0.30 s from the test's release, + the hand-off (~10 ms) | budgets.json; plan motion table |
| `focusMs`: pill tap to keyboard at rest | — | 507 | 510 | 600 | Ends at `keyboardDidShow`, so the system's 0.5 s keyboard rise is inside; best = rise starting on the tap's frame (+1 frame); fail = rise + the 100 ms delay threshold | Nielsen; Apple responsiveness |
| `newTabMs`: New Tab to keyboard at rest | — | 534 | 510 | 600 | Same as focus | same |
| `suggestionsMs`: keystroke to local rows | — | 8.1 | 8.3 | 50 | Next 120 Hz frame; RAIL keeps input handling under 50 ms | RAIL; ProMotion |
| `linkPaintMs`: link tap to next page's first paint (local) | — | 108 | 100 | 200 | 100 ms reads as instant; 200 ms is Core Web Vitals' "good" INP (input to next paint) | Nielsen; web.dev Vitals |
| `memoryMB`: app footprint, 10 tabs | — | 72 | 60 | 150 | A lean UIKit shell ~40 MB + ten 2x thumbnails ~1.3 MB each; fail at twice the sim reading until device rows exist | XCTMemoryMetric docs |

Simulator numbers came from a machine at load average 200–900 (other lanes' builds and
simulators): trends only. The keyboard's 0.5 s rise shows as the simulator's floor (its fastest
focus runs end 1 ms after it).

## The ratchet

Device mode fails when a metric reaches its `fail`, or when it is worse than its best value in the
last 5 passing device rows by more than 10% or its `slack` (one 120 Hz frame for times, 1 ms/s for
hitches, 2 MB for memory), whichever is larger. Each value is the median of 5 iterations; the gate
prints each metric's relative standard deviation (RSD), and a metric over 10% RSD reruns its test
once, whose numbers then count. Simulator mode is unchanged: a 20% regression against the previous
sim row.

An improvement tightens the gate automatically: the next device rows compare against it. A real
regression (a feature that must cost time) needs the owner's call and a note in the perf log.
