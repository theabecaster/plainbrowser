# Perf log

One row per perf-gate run (`scripts/perf-gate.sh`), appended by the script. Values are the
median of each test's iterations. SHA ends in `-dirty` when the tree had uncommitted changes.

- `sim` rows come from the `plain-perf-duo` simulator. They track trends only: they are not
  comparable to the device budgets, and XCUITest automation inflates launch times there
  (main → focused field is ~0.2–0.4 s outside the test harness, ~2 s inside it).
- `device` rows come from the phone and are held to `perf/budgets.json`.

Columns: launch = cold launch until responsive (ms), field = `main` to search field focused (ms),
hitch = page scroll hitch ratio (ms/s), gallery = tabs button to gallery settled (`gallery.show`, ms),
swipe = bar swipe to page settled (`tab.swipe`, ms), last tab = cold launch with a last tab until its
picture and resting bar are on screen (`launch.firstFrame`, ms). Rows before the M2 shell wiring have
neither gallery nor swipe; rows before 2026-11-27 have no last tab. Since 2026-11-27 launch and field
start from an empty test store (no tab), as a last tab now opens without the search field.

Since the perf program (2026-11-27): focus = tap on the address pill until the keyboard rests
under the focused field (`urlBar.ready`, ms), suggest = one keystroke until its local suggestions
show (`search.suggestions`, ms), link paint = a link tap until the next local page's first
contentful paint, measured by the pages (ms), gallery tab = a gallery card tapped until its page
rests (`gallery.openTab`, ms), new tab = New Tab until the keyboard rests under its field
(`tab.newReady`, ms), memory = the app's footprint with ten tabs, after the gallery showed them
(MB; WebKit's processes not counted), heavy hitch = hitch ratio scrolling a large page darkened by
dark pages (ms/s, device only). Older rows have the result where these columns begin. The gate
reads columns by header name, and its ratchet compares device rows against the best of the last 5
passing device rows (perf/budgets.json, docs/research/perf-goals.md).

Note, M2 shell wiring rows (2026-11-26 15:12–15:23): machine load average 70–130 on 14 cores (other
lanes building), so these are noise. Launch reported no measurement in two of three runs; the bar
swipe (`tab.swipe`) recorded no XCTOSSignpostMetric value in any run (the swipe UI tests pass), to
investigate before relying on it. Gallery ends at the spring settle (see perf/budgets.json).

Note, launch lane rows (2026-11-27 02:28 before, 10:30 after): load average 12 rising to 300 during
the first run and 7 to 60 during the second (other lanes' simulators), so launch moves within noise.
Simulator signposts in the after build: the last tab's picture finished decoding 25–33 ms after the
scene connected, hundreds of ms before the first frame, so the first frame never waited for it.

Note, perf program row (2026-11-27 14:11): the first with every new column, at load average
800–970 (other lanes), so launch and last tab "regressed" within noise. The one failing test,
`testNewTabToSearchField`, timed out waiting 10 s for its page under that load (the wait is 20 s
since, and it passes alone). Gallery tab reads ~1.5 s against ~0.6 s for the gallery's open:
`gallery.openTab` seems to end at Core Animation's completion rather than the visual settle.

| Date | SHA | Target | Launch ms | Field ms | Hitch ms/s | Gallery ms | Swipe ms | Last tab ms | Focus ms | Suggest ms | Link paint ms | Gallery tab ms | New tab ms | Memory MB | Heavy hitch ms/s | Result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-11-26 05:23 | 9b9ba4e | sim | 3353.9 | 2064.4 | n/a | pass |
| 2026-11-26 06:16 | 6ba5947 | sim | 3578.5 | 2035.5 | n/a | pass |
| 2026-11-26 06:33 | 2c966cc | sim | 3529.1 | 1851.1 | n/a | pass |
| 2026-11-26 07:13 | 34cc71f | sim | 3461.8 | 1880.7 | n/a | pass |
| 2026-11-26 12:10 | f556baf | sim | 3578.0 | 2045.0 | n/a | pass |
| 2026-11-26 12:26 | 77d08f4 | sim | 3570.7 | 507.9 | n/a | pass |
| 2026-11-26 13:01 | 2d4189d | sim | 3257.5 | 491.5 | n/a | pass |
| 2026-11-26 15:12 | 448bd31 | sim | — | 436.3 | n/a | 1481.8 | — | FAIL |
| 2026-11-26 15:17 | 2ced874 | sim | 3271.3 | 441 | n/a | 1480.7 | — | FAIL |
| 2026-11-26 15:23 | ebab6bf | sim | — | 447.6 | n/a | 1482.9 | — | FAIL |
| 2026-11-26 23:26 | 32eecbe | device | — | 219.4 | 0 | 984.1 | — | FAIL |
| 2026-11-27 00:46 | 503cd9a | device | 246.6 | 224.8 | 0 | 559.6 | 1090.5 | FAIL |
| 2026-11-27 02:28 | 9560a3b | sim | 751.9 | 492.9 | n/a | 556.1 | 307.4 | pass |
| 2026-11-27 10:30 | ad4b8f6 | sim | 803.8 | 424.7 | n/a | 553.8 | 309.7 | 618.1 | pass |
| 2026-11-27 11:21 | d9da72b | device | — | — | — | — | — | — | FAIL |
| 2026-11-27 11:25 | d9da72b | device | — | — | 0 | 690.5 | 528.7 | 223.9 | FAIL |
| 2026-11-27 11:52 | 5788977 | device | 225.4 | 198.1 | 0 | — | — | 214.3 | FAIL |
| 2026-11-27 12:00 | 6c1231f | device | 225.4 | 198.1 | 0 | 680 | 526 | 214.3 | pass (gallery/swipe rerun alone after a notification interrupted them) |
| 2026-11-27 14:11 | 5094071 | sim | 968.3 | 507.2 | n/a | 583.7 | 329.3 | 889.3 | 468.3 | 9.3 | 56 | 1489.9 | 531.3 | 72 | n/a | FAIL |
