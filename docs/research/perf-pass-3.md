# Perf pass 3: complexity, the system's floor, and what is left (2026-11-28)

**Bottom line.** Plain's own code is a small share of every over-budget metric; most of each is
UIKit, the system keyboard and the test runner. On the simulator Plain sits 23–31 ms above a bare
UIKit field for the time before the keyboard rises, ~90 ms above it for the field-focused launch,
and holds 69 MB at ten tabs against the bare screen's 33 MB. This pass cuts the cookie banner
engine's per-frame work from O(rules) to the address's few candidates, its memory by 2.6 MB, and New Tab's web view
creation out of the tap, and adds a reference that measures the floor on the Duo. Whether 150 ms
launches and 510 ms focus are reachable on the Duo at all is the device run's answer (section 6).

| Metric (device target) | Device before | Simulator: what this pass changed | Expected on the Duo |
|---|---|---|---|
| Launch, first frame (150) | 235.5 | nothing measurable (start screen shortcuts deferred: no gain) | ~unchanged; the floor decides |
| Launch, field focused (150) | 212.3 | nothing measurable on a quiet host (lean traits: −0.8%, noise) | ~unchanged; the floor decides |
| Launch, last tab (150) | 218 | — | ~unchanged; 117–182 ms over the unfocused floor on the sim |
| Pill tap to keyboard (510) | 533.4 | — (Plain's own frames ~6% of the pre-keyboard time) | ~unchanged |
| New Tab to keyboard (510) | 536.3 | warm web view made again after each take: no `WKWebView.init` in the tap; 517 → 484 ms pooled (15 vs 15, rounds +18 / 0 / −77 under load) | a few ms |
| Keystroke to suggestions (8.3) | 11.7 | — (test runner's accessibility work queued ahead of the rows; Plain 5.96 vs the bare field's 3.99 ms) | ~unchanged |
| Memory, ten tabs (60) | 72.7 | 71.3 → 68.6 MB (cookie rules) | ~−2.6 MB (the lean-field experiment, 2.3, measures the keyboard's share) |
| Link tap to first paint (100) | — | made measurable in pass 2 | the device run says |

The device gate of 2026-11-27 20:30 (`eb5ddec`) left these over target: cold launch to first
frame 235.5 ms (150), to the focused field 212.3 (150), with the last tab 218 (150); pill tap to
keyboard 533.4 (510), New Tab to keyboard 536.3 (510); keystroke to suggestions 11.7 (8.3); memory
with ten tabs 72.7 MB (60); link paint unmeasured. Perf pass 2 (docs/research/perf-pass-2.md)
profiled each one. This pass asks three questions per metric: what does UIKit alone cost for the
same thing on the same machine (the floor), how does each hot path grow with its input (the
complexity), and which honest change closes the gap.

## 1. Method

- Simulator `plain-p3-duo-*` (iPhone Duo, iOS 27.2), Release, through the shared queue. Every
  comparison is an interleaved A/B in one build: a temporary launch argument switches the change
  on (`-P3Lean`, `-P3Eager`), and runs alternate A, B, A, B, so load drifts over both sides.
  The switches were removed before hand-back; the shipped code has only the chosen side.
- Instruments-grade evidence: `xctrace record --template 'Time Profiler' --instrument
  os_signpost` on cold launches and on the keystroke and focus tests, exported to XML and
  reduced to main-thread samples inside the app's own signpost intervals (frames named below).
- Memory: `footprint`, `vmmap --summary`, `heap -s` and `malloc_history -allBySize` on the app at
  ten tabs, with `MallocStackLogging=lite`, during `testMemoryWithTenTabs`.
- Complexity: curves at three sizes or more, from package tests on macOS (`ComplexityCurveTests`
  with `PLAIN_CURVES=1`; `CookieBannerRulesTests`).
- The floor: a new **perf reference** (`-PlainPerfReference`, isolated test runs only): a bare
  UIKit screen with one text field (the address field's input traits) and two buttons, measured
  by the same signposts (`PerfTests.testReferenceLaunch`, `testReferenceFocus`, run with
  `TEST_RUNNER_PLAIN_PERF_REFERENCE=1`). It is what UIKit and the system keyboard alone take on
  that device under the same harness: a budget below it would need UIKit or the keyboard to do
  less than they do for a bare screen, which no app controls.

## 2. Results by metric

### 2.1 Where the time goes, named frames

**Pill tap to keyboard start** (`urlBar.keyboardStart`, `xctrace` attached during
`testAddressBarFocus`, 5 intervals, 534 main-thread samples at 1 kHz, load ~250):

| Frames | Samples | Whose |
|---|---|---|
| `-[UIKeyboardSceneDelegate setInputViews:…]` from `-[UIPeripheralHost queueDelayedTask:…]` (the keyboard's input window: `-[UIInputWindowController moveFromPlacement:toPlacement:…]` 248, `updateInputAssistantView:` 119, `changeToInputViewSet:` 151) | 304 | UIKit |
| `-[_UIKeyboardFocusAssistant performWhenReadyForResponder:…]` (around the two above) | 405 | UIKit |
| The update cycle's layout (`CA::Layer::layout_if_needed`, the keyboard window's Auto Layout) | 216 | UIKit, partly ours |
| `BrowserViewController.pillTapped()` | 147 | ours, of which `-[UITextField becomeFirstResponder]` 131 (UIKit) |
| · `openSearchSheet`, `applyEditingLayout`, `textFieldDidBeginEditing` | ~30 | ours |

So ~6% of the time before the keyboard starts is Plain's own code; the rest is the system
keyboard placing its window and input assistant. The bare reference confirms it (section 2.2).

### 2.2 The floor: Plain against a bare UIKit screen, same build, same load

`PerfTests` with `TEST_RUNNER_PLAIN_PERF_REFERENCE=1`, Plain's tests and the reference's in one
run, twice (macdesk, Release, medians of 5 iterations per run; ms):

| Interaction | Plain run 1 / 2 | Reference run 1 / 2 | Plain over the floor |
|---|---|---|---|
| Pill tap to keyboard at rest (`urlBar.ready` vs `reference.ready`) | 502.8 / 486.8 | 453.1 / 453.0 | +34 to +50 |
| · tap to keyboard start (`urlBar.keyboardStart` vs `reference.keyboardStart`) | 92.2 / 81.2 | 61.2 / 57.7 | +23 to +31 |
| New Tab to keyboard at rest (`tab.newReady`) | 501.6 / 483.9 | 453.1 / 453.0 | +31 to +49 |
| `main` to the focused field (`launch`) | 436.0 / 444.5 | 499.6 / 354.1 | +90 (run 2; run 1's reference was noisy) |
| `main` to the first frame, search first (`launch.firstFrame`) | 833.1 / 882.8 | 1060.6 / 764.5 (keyboard up) | +118 (run 2) |
| `main` to the first frame, last tab (`testLaunchToLastTab`) vs the unfocused reference | 633.5 / 610.1 | 516.4 / 427.7 | +117 to +182 |

Under heavy load (load ~800, job A) the focus gap was within noise (485.2 vs 477.7).

What it says, and its limits:
- The keyboard's own rise is ~0.40 s here; the 0.5 s of the budgets is the Duo's (perf-goals.md).
  On the simulator, a bare UIKit field takes ~453 ms from the tap to the keyboard at rest, and
  ~58–61 ms of that is before the rise starts. Plain adds 23–31 ms there, of which its own
  frames are ~6 ms (2.1); the rest is UIKit doing the same keyboard placement over Plain's much
  larger view tree (the keyboard layout guide's constraints, the window's Auto Layout).
- The device decides: on the Duo the rise alone is ~0.5 s, so `focusMs`'s 510 leaves ~10 ms for
  everything before it; the reference's `reference.keyboardStart` on the Duo says whether UIKit
  alone fits in that.
- The launch floor depends on the keyboard: the focused reference's first frame waits for the
  system keyboard's bring-up, the unfocused one's doesn't (516 vs 1061 ms, run 1). Plain's search
  launch holds its keyboard under the splash (an empty input view), so its first frame lands
  between the two.

**Keystroke to suggestions** (`search.suggestions`, 30 intervals, 128 ms in all, 85 main-thread
samples): between our `editingChanged` and the rows, the main thread runs the test runner's
accessibility broadcasts (`_UIAccessibilityBroadcastNotificationFunction`,
`-[UITextInputControllerAccessibility _sendDelegateChangeNotificationsForText:selection:]`,
`AXUIAutomationHandleKeyComplete`: 17 samples, plus their `os_log` calls, 28) and UIKit's keyboard
task queue (`-[UIKeyboardTaskQueue continueExecutionOnMainThread]`, 20). They are queued on the
main queue before the database read's continuation, so the rows wait for them. Plain's own work in
the interval is under 1 ms (perf pass 2). The accessibility part exists only while XCUITest (or
VoiceOver) drives the app; reordering our continuation ahead of it would end the interval earlier
without the rows reaching the screen sooner (they wait for the same commit), so it is not done.

**Memory at ten tabs** (`footprint` and `malloc_history`, MallocStackLogging on, so the
"Performance Tool Data" region is left out): 68 MB without the tool's own data. Malloc small
37 MB, of which the frames that own it:

| Owner (innermost app frame, or the framework) | Live | Note |
|---|---|---|
| System, no app frame: UIKit 3.4, TextInput 2.0, Core Animation 1.9, SwiftUI 1.0, Auto Layout 0.5 MB | ~10 MB | |
| Accessibility runtime (AXCoreUtilities, libAccessibility, UIAccessibility, AX safe categories) | ~4.8 MB | loaded because XCUITest drives the app; a user without VoiceOver doesn't pay it |
| `AddressField.init` (the first `UITextField` of the process: TextKit 2 and its layout manager) | 2.1 MB | needed |
| `viewIsAppearing` → `becomeFirstResponder` (the keyboard set up for the launch focus) | 1.3 MB small, 8.1 MB with its larger buffers | see `-P3Lean` |
| `WebViewPool.makeWebView`, `attach` (ten tabs' web views, UI side) | ~2 MB | |
| Cookie banner rules (`CookieBannerRules.init`, JSON strings) | 0.6 MB | was ~3.2 MB with every pattern compiled |
| `Surfaces.refresh` through `-[UIViewAccessibility setBackgroundColor:]`, `Tiles.pattern` | ~3 MB | partly the accessibility runtime's |
| Cards' placeholders, button bar, sheet rows | ~1.5 MB | |

Outside malloc: `__DATA` of the linked frameworks 14 MB (system), one 4.2 MB `CG Image` (the
current tab's raw snapshot, `ThumbnailService.capture` → `-[WKWebView takeSnapshot…]` →
`CGBitmapAllocateData`, kept in the thumbnail cache), page tables 2 MB, Core Animation 1.5 MB.
The thumbnails are IOSurfaces (78 MB reclaimable) and do not count. The bare reference holds
33.3 MB under the same harness (`testReferenceMemory`), so Plain with ten tabs adds ~36 MB.

### 2.3 The address field's text traits (an owner decision, not changed)

The non-private field asks for inline predictions, Writing Tools and grammar checking by default
(`.default`); a private tab turns them off. `-P3Lean` turned them off for every tab (plus smart
quotes and dashes), as an interleaved A/B:

| Run (host, load) | Ten-tab memory | Field-focused launch | Keystroke |
|---|---|---|---|
| job A (macdesk, ~800) | — | −13% (2 rounds) | −11% |
| job C (macdesk, ~30) | **67.6 → 56.1 MB** (−11.4 MB, both rounds, peak 80 → 69) | — | — |
| job D (m6desk, ~10, 4 rounds = 20 vs 20 iterations) | 68.8 → 68.8 MB | −0.8% (noise) | +3.9% (noise) |
| job D, each trait alone (m6desk) | 68.5–69.3 MB (base 69.1) | | |
| job F (macdesk, the shipped `-PlainPerfLeanField` switch) | 68.29 → 68.06 MB | | |

So it buys no time on a quiet simulator (job A's gains were the load) and no memory either: job
C's −11 MB did not come back in three later runs on both test Macs, the last on the same Mac
through the shipped switch, so it is not counted. A simulator may not load the on-device
prediction and Writing Tools models a phone does, so the device keeps the question open:
`testMemoryWithTenTabsLeanField` runs the ten-tab memory test with `-PlainPerfLeanField`
(isolated runs only, AddressPill) beside the reference. Only if the Duo shows a real difference
is there anything for the owner to decide (the field already corrects and spell-checks nothing;
Plain's own rows are its predictions).

### 2.4 The keystroke and memory floors

Job F, macdesk, the reference beside Plain in one run:

| | Plain | Reference | Plain over the floor |
|---|---|---|---|
| Keystroke to rows (`search.suggestions` vs `reference.keystroke`, the same off-main hop) | 5.96 ms | 3.99 ms | ~2 ms |
| Footprint (`testMemoryWithTenTabs` vs `testReferenceMemory`, keyboard up) | 68.3 MB | 30.9 MB | ~37 MB for ten tabs, their web views' app side, the shell and its caches |

The 8.3 ms keystroke target leaves ~4 ms over UIKit's and the test runner's own keystroke work
on this simulator; the device's `reference.keystroke` says how much it leaves on the Duo.

## 3. Complexity

Package tests on macdesk (macOS, M4, Release-like `swift test` debug build; times are relative,
the shape is the point). `ComplexityCurveTests` runs with `PLAIN_CURVES=1`.

| Hot path | The n | Complexity | Measured curve | Verdict |
|---|---|---|---|---|
| Keystroke's history query (`addressBarCandidates`: FTS5 `MATCH`, join on `rowid`, `ORDER BY (address LIKE prefix) DESC, frecency DESC LIMIT 2·16`) | k = index rows the `MATCH` yields (grows with history size n and shrinks with each letter) | O(k log L): every match is visited, a bounded sorter keeps the best L (`USE TEMP B-TREE FOR ORDER BY`) | 1k pages: p50 0.32–0.34 ms (k 69–250); 10k: 0.55–0.66 ms (k 691–2,537); 100k: 1 letter 6.8 / p95 10.1 ms (k 6,816), 2–3 letters 8.3 / p95 12.1 ms (k 25,443), a word 7.2 ms | Linear in matches. Under the 16 ms p95 budget at 100k on a Mac, off the main thread; the gate's test has 2 pages, so it doesn't see it. The follow-up below. |
| Site top hit (`siteMatch`) | root pages with the prefix | O(log n + m) on the partial index `historyPlace_sites`, then a sort for `ORDER BY frecency` | plan: `SEARCH … USING INDEX historyPlace_sites (address>? AND address<?)`, `USE TEMP B-TREE` | Fine: m is the few root pages per prefix |
| Adaptive picks (`InputHistory.matches`) | picks for the prefix | O(log n + m), primary-key range | plan: `SEARCH i USING INDEX sqlite_autoindex_inputHistory_1 (input>? AND input<?)`, join by `url` index | Fine |
| Tab session read at launch (`loadTabSession`, off main) | open tabs | O(n) | 10: 0.80 ms, 100: 1.64, 1,000: 10.3 | Linear, off the main thread |
| `TabStore(session:)` on the main thread | open tabs | O(n) | 10: 0.034 ms, 100: 0.158, 1,000: 1.37 | Linear; under the 5 ms budget at 1,000 |
| Closing one tab (`TabStore.close`) | tabs in the window | O(n) per close (list `firstIndex`/`removeAll`, the session snapshot) | with the session snapshot each close builds: 5 closes at 10 tabs 0.07 ms, 50 at 100: 2.0 ms, 500 at 1,000: 162 ms (0.32 ms each) | O(n²) only when closing one by one; Close All and archiving already batch (`closeTabs`) |
| Cookie banner rules per frame | R rules | before O(R) regex matches; now O(labels + C log C) for the C = U + k candidates (U = 35 unindexed, k the host's own rules), flat while C stays fixed | see below | Changed this pass |

**Follow-up for the history query (not changed in this pass).** The slow keystrokes at 100k are the
first two or three letters, where the `MATCH` yields tens of thousands of rows only to keep 32.
A bounded plan exists: walk places in `frecency` order (that index exists), once for addresses
that start with the text and once for any match (the ranking's two tiers), stopping at 32 each,
which visits about 32/selectivity rows when the prefix is common and degrades toward n when it
is rare; running the FTS plan for rare prefixes (an FTS5 `instance` count or the
token's doc count from `fts5vocab`) and the frecency walk for common ones would make every
keystroke O(L / selectivity) with the current plan as the bound. It changes the query planner's
inputs, not the ranking, but needs its own ranking-equivalence tests, so it is left for a pass of
its own.

### Cookie banner rules: O(rules) per frame to O(labels + C log C)

Every main frame and every subframe asks `CookieBannerRules` which site rules match its address
(`page`, `init` and `frame` messages). Before, that was 882 `NSRegularExpression` matches per
frame, all 882 compiled at the first page (`CookieBannerRules.init`): O(R) time per frame and
O(R) ICU programs held for the app's life (pass 2 measured ~1.5 MB of ICU regex memory, and
~3.4 MB for the engine and rules in all).

autoconsent's patterns are regular: 847 of the 882 are `^https?://`, at most one optional
subdomain group (`(www\.)?`, `(\w+\.)?`, `([a-z0-9-]+\.)*`, 17 forms in all), a literal host
(sometimes with literal alternatives, `(fellow|fll)\.pl`), then `/`, `(/|$)` or `$`. For those the
host is provably a dot-suffix of the address's text from `://` to the first `/`: each subdomain
group matches nothing or a run ending in `.` with no `/`, and the host itself holds no `/`. So the
rules are indexed by host (`HostKeys.keys(for:)`), an address looks up each of its suffixes
(`HostKeys.hostSuffixes(of:)`: one per label), and only those candidates plus the 35 patterns the
index can't read run their regular expression, compiled the first time it runs. An address with a
line break (ICU's `$` also matches before a final one) takes the full check.

- Correctness: `hostIndexMatchesTheFullCheck` compares the index with the full check on every
  rule's host, its subdomains, look-alikes (`xdeezer.com`, `deezer.com.evil`), credentials,
  ports, queries and both schemes, for main frames and subframes: 186,972 checks, 10,109 of them
  with rules, all equal. Its first run caught patterns that are alternatives at the top level
  (`^…galaxus\.de/|^…galaxus\.fr/`), now indexed under every branch's host; review caught two
  shapes the bundled rules don't use but the parser accepted (a quantified `/`, inline flags such
  as `(?i)`), now left to the full check (`hostKeysReadOnlyTheProvableShape`).
- Curve: `ruleMatchScalesWithTheAddressNotTheRules`, the bundled rules plus copies of the indexed
  ones on hosts of their own:

  | Rules | Indexed | Full check |
  |---|---|---|
  | 882 | 30.9 µs per frame | 373.4 µs |
  | 3,423 | 27.0 µs | 1,535.5 µs |
  | 13,587 | 34.5 µs | 6,608.9 µs |

## 4. Changes

1. **Cookie banner rules: a host index, patterns compiled on first use**
   (`ContentBlocking/CookieBanners.swift`, section 3). Per frame O(labels + C log C), C = U + k candidates, instead of
   O(R); ten-tab memory 71.3 → 68.6 MB (interleaved, 2 rounds of 5, both rounds; job A).
2. **The warm web view is made again after a tab takes it** (`WebViewPool.scheduleRewarm`,
   `EngineChoices.rewarmDelay`): a New Tab after the first no longer runs `WKWebView.init` and its
   attach inside the tap (15 + 9 + 4 of the 422 pre-keyboard samples in the New Tab trace). It
   runs one second after the take, in the run loop's default mode (not during a scroll or a
   tracked gesture; an animation can still be running), only while the app is active and not after
   a memory warning, the same policy as the gallery's spare. Interleaved A/B (job F, macdesk, load
   ~130, 3 rounds of 5): New Tab to keyboard 517.3 → 484.2 ms pooled, keyboard start 109.7 → 87.4
   ms; the rounds disagree under that load (+18, 0, −77 ms), the mechanism (the trace) does not.
3. **The perf reference** (`Plain/PerfReference.swift`, `PerfTests.testReference*`,
   `testMemoryWithTenTabsLeanField`, the gate's report-only lines; section 1). Test runs only.
4. **The complexity curves** (`StorageTests/ComplexityCurveTests.swift`, `PLAIN_CURVES=1`).
5. Comment fix: `EngineChoices.maxWebViews` said hidden web views cost "the app" 3–5 MB each;
   the app's side of ten is ~2 MB, the rest is WebKit's processes.

## 5. Rejected

- **Start screen shortcuts built after the first frame** (they are invisible while the field is
  focused at launch; `-P3Defer`): interleaved A/B, 2 rounds, no gain (first frame +5.9%, field
  within noise). Pass 2's 15 samples for them are a simulator cost (the Swift conformance scans
  that the device's dyld closure precomputes, WWDC22 [110363](https://developer.apple.com/videos/play/wwdc2022/110363/)).
- **Delivering the keystroke's rows ahead of the queued accessibility work**: the rows would be
  handed over sooner but reach the screen in the same commit, so the interval would end before
  what the user sees changes. A metric game.
- **Fewer kept web views** (`EngineChoices.maxWebViews` 8): the ten tabs' web views hold ~2 MB on
  the app's side (`makeWebView`, `attach`); the 3–5 MB each is WebKit's processes, not counted.
  Fewer would lose instant tab switching for little.
- **Smaller thumbnails or swipe previews**: the one 4.2 MB `CG Image` is the current tab's raw
  snapshot at 3 px/pt (`ThumbnailService.capture`); fewer pixels would look softer on the cards.
- **Binary and dyld work** (static vs dynamic modules, mergeable libraries, order files): Plain is
  already one Mach-O (PlainKit's modules and GRDB link statically; no embedded frameworks), 1,595
  Swift conformance records, 231 Objective-C classes, no `+load` methods and no static initializer sections (`otool`). Pre-`main` time is outside
  every launch interval, and the first-touch page faults an order file saves are small on the warm
  launches the tests measure. Not measured further.
- Anything private: private selectors (`_WKContentRuleListAction` counts, keyboard internals such
  as `UIKeyboardImpl` or preloading the keyboard through private classes), swizzling system
  classes, `dlopen` of private frameworks, reading or patching Apple internals. They could fail
  App Review and are not used.

### The simulator gate on the final code (job G)

`TEST_RUNNER_PLAIN_PERF_REFERENCE=1 scripts/perf-gate.sh`, m6desk, load 60, the branch on
origin/dev `3ca5656` (its row was not committed; the lead logs the device row):

| Metric | This branch | Previous sim row (pass 2, `bed7c69`, another base) | Reference (report only) |
|---|---|---|---|
| Launch, first frame | 666.5 (RSD 11.9%) | 639.4 | focused 1,032.9; unfocused 379.6 |
| Launch, field focused | 386.4 (RSD 21.1%) | 316 | focused 513.9; unfocused 290.3 |
| Launch, last tab | 458.6 | 386.6 | |
| Pill tap to keyboard | 517.4 (keyboard start 113.0) | 484.2 | 437.8 (keyboard start 47.5) |
| New Tab to keyboard | 455.6 (RSD 0.3%; keyboard start 63.9) | 465.7 | 437.8 |
| Keystroke to suggestions | 4.3 | 3.8 | 2.7 |
| Link tap to first paint | 71 (RSD 62.7%) | 55 | |
| Memory, ten tabs | 67.6 MB (lean field 67.3) | 58.5 | 34.9 MB |
| Gallery / swipe / card | 526.9 / 291 / 519.2 | 483 / 294.6 / 518.1 | |

The gate failed its 20% simulator ratchet on the field-focused launch (RSD 21%) and link paint
(RSD 63%). The previous row is pass 2's branch, before about forty commits of origin/dev
(gestures, the page's address in the field, new tab, private mode), so it does not isolate this
branch. This branch's own launch-path change is one argument check, and each change above was
measured against its own A/B. Pill focus now spends 113 ms before the keyboard starts against
the bare field's 47.5, more than in pass 2. Because the rewarm can land during a focus right after
a load, it now also waits out any keyboard rise or fall (`isKeyboardMoving`,
`EngineChoices.rewarmRetry`). Job H, with that, on a quiet host (this Mac's slot, load ~10):

| | Plain | Reference |
|---|---|---|
| Pill tap to keyboard at rest | 467.9 ms (keyboard start 66.5) | 448.6 ms (keyboard start 59.3) |
| New Tab to keyboard at rest | 484.0 ms (keyboard start 77.2) | |
| Memory, ten tabs | 56.2 MB | |

On a quiet machine Plain's focus is within ~19 ms of the bare field (7 ms before the keyboard
starts). The ten-tab footprint differs by host (56 MB here, 68–69 on the test Macs, same build),
so memory is only compared within one run.

## 6. Device run requested

On the Duo, Plain Dev, the phone awake and unlocked:

```sh
TEST_RUNNER_PLAIN_PERF_REFERENCE=1 scripts/perf-gate.sh --device
```

It runs the budgeted tests as always and the five reference tests, and prints the reference
under "report only". What each answers:

| Reference line | Answers |
|---|---|
| `testReferenceFocus reference.ready`, `reference.keyboardStart` | Whether `focusMs`/`newTabMs` 510 is reachable at all: if a bare field takes ≥ 510 ms on the Duo, the budget is below UIKit's floor |
| `testReferenceLaunch launch.firstFrame`, `launch` | The search-first launch's floor (a focused field before the first frame) |
| `testReferenceLaunchUnfocused launch.firstFrame` | The last-tab launch's floor (no keyboard) |
| `testReferenceKeystroke reference.keystroke` | The keystroke's floor under XCUITest (keyboard and accessibility work queued ahead of any app's rows) |
| `testReferenceMemory physical_absolute` | What UIKit, the keyboard and the test runner hold before an app adds anything |
