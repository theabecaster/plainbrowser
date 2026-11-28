# Perf pass 2: where each millisecond goes (2026-11-27)

The device gate of 2026-11-27 20:30 (`eb5ddec`, iPhone Duo, Release, isolated) left these metrics
over target: cold launch to first frame 235.5 ms (target 150), to the focused field 212.3 (150),
with the last tab 218 (150); pill tap to keyboard at rest 533.4 (510), New Tab to keyboard 536.3
(510); keystroke to local suggestions 11.7 (8.3); memory with ten tabs 72.7 MB (60). Link tap to
first paint had no device number. This page measures each one on the simulator, says what each
part of it is, and records what changed and what it bought.

## 1. Method and its limits

- Simulator `plain-perf2-duo` (iPhone Duo, iOS 27.2), Release build, on the test Macs. Load
  average during the runs was 11–460 on 10–14 cores (other lanes' builds, matrices and UI tests),
  so every wall-clock number here is a trend. Two measures hold up under load and are what the
  conclusions rest on:
  - **Main-thread samples** (Time Profiler, 1 kHz): CPU time the main thread actually spent,
    which load inflates far less than wall time.
  - **Interleaved A/B launches** (`ab`: one build, a runtime switch, launches alternating
    A, B, A, B), so load drifts evenly over both sides.
- Signposts: the app's own (`launch`, `launch.firstFrame`, `urlBar.ready`, `search.suggestions`,
  ...) read from the log stream of that simulator only, plus temporary marks inside the
  suggestion path (removed before hand-back).
- Memory: `footprint`, `vmmap --summary` and `heap` of the app process during
  `testMemoryWithTenTabs`, and one run with `MallocStackLogging=lite` for allocation stacks.
- What the simulator gets wrong, so the device stays the judge: keyboard bring-up, `dlopen` of
  text-input frameworks and Swift protocol-conformance scans are far costlier there than on the
  phone (the phone's dyld shared cache has precomputed conformances). The device itself shows it:
  the launch with the last tab (no keyboard) is only 17 ms faster than the search-first launch
  (keyboard) on the Duo, while on the simulator the keyboard is about a third of the launch.
- Simulator gate before this pass (origin/dev `eea68b6`, load 11–69): launch 732.7, field 398.8,
  gallery 482.9, swipe 292.3, last tab 479.9, focus 517.2, suggest 7.9, link paint 73, gallery
  tab 487.9, new tab 500, memory 71.3 MB.

## 2. Cold launch (`launch.firstFrame`, `launch`)

One cold launch, search first, with the splash (`-PlainTestStore -PlainSplash`), 320 main-thread
samples in a 496 ms window (load 31–52; quieter runs: 274 ms median over 5 launches):

| Part | Main-thread samples | What it is |
|---|---|---|
| `main` → scene connects | ~40 | UIKit's app and scene bring-up, keyboard arbiter, `AppDelegate`. System. |
| `scene(_:willConnectTo:)` | 79 | |
| · `BrowserViewController.init` | 40 | stored views: `AddressPill` 14 (its `UITextField` 10, the first text field of the process), `ButtonBar` 10 (SF Symbols 4, button configurations 3), `SearchSheet` 6, `EngineUIState` 5 (`PageStateView`), `TabsUIState` 2 |
| · `BrowserSession.init` | 13 | `WebViewPool` 8 (`WKWebViewConfiguration` and its `WebPreferences` 4, the website data store 2), `SummaryService` 5 (`SystemLanguageModel` init reads `OSEligibilityState`, ~5 ms) |
| · navigation controller, window, stores | 19 | |
| First Core Animation commit | 150 | |
| · `viewDidLoad` | 24 | `updateButtons` 15, almost all the start screen's Private Tab button: `UIButton.Configuration`'s title transformer makes UIKit build its attribute scope (12 samples of Swift conformance scans, once per process) |
| · layout | 53 | Auto Layout, the keyboard layout guide 8, the Liquid Glass containers' SwiftUI layout 12 |
| · `viewIsAppearing` → field first responder | 58 | field editor and selection 10, our `textFieldDidBeginEditing` 9, the keyboard's input views 39 (input assistant, dictation languages, keyboard images, `dlopen`s) |
| Commit → first display-link callback | ~50 | the keyboard's UI bring-up (`keyboardUIBringup`, `reload`, ~45 ms wall) runs on the main thread before the display link fires |

The keyboard is held under the splash (an empty input view), but the field still becomes first
responder before the first frame (docs/decisions.md, "Launch splash": "Focus itself, and so the
`launch` interval, is unchanged"), so all of its bring-up lands inside both launch metrics.

**Deferring focus to the first display-link callback while the splash holds the keyboard**
(nothing visible changes: the splash covers the screen and the keyboard waits for the dive
anyway), A/B, 10 pairs, load 86–90: `launch.firstFrame` 265.0 → 215.5 ms (−19%), but `launch`
231.4 → 288.0 ms (+25%): the field's focus moves behind the first frame and costs more there. It
trades one budget for the other, so it is not in this pass; it is the lever if the owner decides
the first frame matters more than an invisible focus (then `searchFieldMs` would need a new
meaning or budget).

## 3. Address pill tap to keyboard at rest (`urlBar.ready`)

New signposts split it: `urlBar.keyboardStart` (tap until `keyboardWillShow`: the shell's work, the
frame's commit and the keyboard's set-up) and the rest, the system keyboard's own rise. The same
pair exists for New Tab (`tab.newKeyboardStart`). The perf tests now report both.

| Run (sim, load) | `urlBar.keyboardStart` | `urlBar.ready` |
|---|---|---|
| 160–400 | 67–97 ms (median 84) | 469–501 ms |
| 90–270 | 66–90 ms (median 83) | 468–487 ms |

So on the simulator the keyboard's rise is ~400 ms and the time before it starts ~80 ms. On the
Duo the rise is ~0.5 s (perf-goals.md), so of its 533 ms about 30 ms is before the rise starts.

## 4. Keystroke to local suggestions (`search.suggestions`)

Temporary marks inside one keystroke (40 keystrokes, load 41–90):

| Point | Median, ms from the keystroke |
|---|---|
| `queryChanged` returns | 0.08 |
| Database read starts (inside `queryChanged`, see below) | 0.07 |
| SQL work in the read (GRDB's queue) | 0.20 → 0.65 |
| The main thread resumes with the rows | 3.45 |
| Rows handed to the sheet (interval end) | 3.53 |

The shell's own work is about 0.7 ms. The other ~2.8 ms is the main thread finishing UIKit's
handling of the keystroke before it can take the rows. A read that is done by then is taken
before the run loop sleeps, and the sheet applies its rows in the same commit as the typed
character. Under XCUITest part of UIKit's share is the accessibility notifications it logs for
the automation (a test-only cost). Before this pass the read started only
after that wait, in a task the main queue ran later, and the rows needed a second hop back.

## 5. Memory with ten tabs (`memoryMB`)

`footprint` of the app at ten tabs (sim; the gate's XCTMemoryMetric read 71–80 MB on the same
runs):

| Category | Dirty | Notes |
|---|---|---|
| Malloc (small) | 37–41 MB | 33 MB live in 264k allocations |
| `__DATA` of the linked frameworks | 14 MB | system |
| WebKit malloc | 4 MB | the web views' UI-process side |
| CG Image | 4 MB | one decoded picture |
| Page tables, Core Animation, dyld, stacks | ~6 MB | |
| IOSurface | 0 (24–97 MB reclaimable) | the thumbnails and snapshots: purgeable, not in the footprint |

The thumbnails are not the problem: they are IOSurfaces the system may reclaim and the
footprint leaves out. The live heap is spread thin: strings 5.5 MB (45k `CFString`s), Objective-C
method caches 2.4 MB, Swift metadata 1.4 MB, ICU regular expressions 1.5 MB (the cookie banner
rules' 885 site patterns), SF Symbols' SVG trees 1.3 MB. By the app frame that allocated them:
the cookie banner engine and rules ~3.4 MB, the paper surfaces' refresh 3.2 MB, the address
field's text system 2.2 MB, the paper tiles 1.1 MB. No single owner holds the 13 MB between
72.7 and 60; reaching 60 needs several of these at once (section 7).

## 6. Link tap to first paint on the device

The device row has no value. The cause is not the phone reaching the test server: the UI test
runner runs on the phone, and `testBarSwipe` passed on the Duo with its pages (`/a`, `/long`)
asserted loaded from the same `TestServer` (log of 2026-11-27 11:52). The same test passes on the
simulator in light and dark appearance (57 ms median). The device's failure message was not kept
(the gate printed only "no measurement"). Two parts of the measurement could differ on the phone
and are now made independent of it:

- The tap's time travelled in `sessionStorage`; it now rides in the link's address (and in
  `sessionStorage` as a second way).
- `PageReportedMetric` matched a value to its iteration by `Date`; it now uses the runner's own
  mach clock first.
- The gate now prints the test's first failure lines for any metric with no measurement, so the
  next device run says why.

## 7. Changes and what they bought

| Change | Where it shows | Measured (simulator) |
|---|---|---|
| The web view pool's base configuration and Personal's website data store are made at the warm-up (after the first frame), not in `BrowserSession.init` | `launch.firstFrame`, `launch` | 8 of 320 main-thread samples before the first frame |
| `SystemLanguageModel` is made at its first availability check (after the first frame) | same | 5 samples (`OSEligibilityState.current`, ~5 ms) |
| `PageStateView` is made the first time a page can't show | same | 5 samples |
| A keystroke's database read starts inside the keystroke (`Task.immediate`) | `search.suggestions` | read starts at 0.07 ms instead of after UIKit's turn; A/B under load 200–450: median 7.6 vs 8.0 ms |
| `urlBar.keyboardStart`, `tab.newKeyboardStart` | focus and new tab breakdown | new: the app's and the system's part before the keyboard rises |
| Link paint: tap time in the link's address, iterations matched on the runner's clock, the gate prints why a metric has no value | `linkPaintMs` on the device | measures on the simulator as before (55 ms); the device decides |
| `testSummaryStart` runs one unmeasured summary first and skips when the on-device model writes nothing (it failed every lane's gate on the test Macs at its 60 s wait) | the gate, report-only metric | no budget; warm runs only |

Simulator gate before and after, same test Mac (m6desk), each row's own load:

| Metric | Before (`eea68b6`, load 11–69) | After (`bed7c69`, load 4–63) |
|---|---|---|
| Launch, first frame | 732.7 | 639.4 |
| Launch, field focused | 398.8 | 316 |
| Launch with the last tab | 479.9 | 386.6 |
| Pill tap to keyboard at rest | 517.2 | 484.2 |
| New Tab to keyboard at rest | 500 | 465.7 |
| Keystroke to suggestions | 7.9 | 3.8 |
| Link tap to first paint | 73 | 55 |
| Gallery open / card to page | 482.9 / 487.9 | 483 / 518.1 |
| Bar swipe | 292.3 | 294.6 |
| Memory, ten tabs (MB) | 71.3 | 58.5 |

The "before" row is origin/dev before the clarity merge, the "after" row this branch on top of
it, and the after run had less load, so launch and focus differences larger than the samples
above are mostly the machine. Memory is the steadiest metric (RSD 0.1% both), but its 12.8 MB
drop is not explained by this pass's changes (a page state view and a configuration made later
are well under 1 MB): it may come from the clarity merge between the two rows. The A/B against
the branch's own base could not run (the test Macs' queues); the device row will say.

## 8. What to expect on the device, and what is left

- **Launch** (235.5 / 212.3 / 218): about 15 ms of main-thread work less before the first frame
  (the samples above at the device's rate). Expect ~220 / ~198 / ~205: better, not at 150. The
  rest is UIKit's scene and text-field bring-up, the first commit's layout and Liquid Glass, and
  the field's focus; the one large lever left is the deferred focus of section 2, which needs the
  owner's call because it trades `searchFieldMs`.
- **Focus and New Tab** (533 / 536): the shell's own part of `urlBar.keyboardStart` is about
  5 ms of the ~80 ms on the simulator; the rest is the system keyboard's set-up (its focus
  assistant and input window placement, which also re-solves the window's Auto Layout). Expect a
  few ms at most. The new `keyboardStart` numbers will show the device's split.
- **Suggestions** (11.7): the read now overlaps UIKit's handling of the keystroke; expect the
  device's number to fall by about its database read (1–3 ms), to ~9–10.
- **Memory** (72.7): nothing in this pass should move it by more than ~1 MB. If the simulator's
  drop to 58.5 MB holds on the device, its cause is outside this pass and worth finding.
- **Link paint**: should now measure; if not, the gate prints the test's own failure line.
