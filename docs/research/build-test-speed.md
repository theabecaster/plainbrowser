# Build and test speed: where the time goes, and what to change

2026-11-28. About 14 feature lanes share the test slots (this Mac: 1; test Mac A and test Mac B: 2
each). Jobs queued for an hour or more. Goal: a much faster loop without checking less. Perf
budgets, `scripts/perf-gate.sh`, release builds and the shipped app are unchanged by everything
below. Each number says which Mac it came from.

## Recommendation

Ranked by slot-minutes saved per lane (a typical lane uses about 220 slot-minutes; see 1.3).

| # | Change | Saves | Status |
|---|---|---|---|
| 1 | Run `swift test`, the build check and the full Smoke plan on GitHub's free hosted runners (`scripts/ci.sh`); rerun on a test Mac only the tests that did not pass there | about 50 slot-min per `test.sh` (65 min on a Mac becomes a rerun of about 10–20 tests, 5–10 min), about 100 per lane. Not faster for one lane: a hosted Smoke takes about 70 min | done; see 2.2 for its limits |
| 2 | Keep two slots per test Mac, and stop work running outside them | two jobs at once: 1.8x the jobs per hour of one at a time (test Mac B, measured) | measured; runner kept at two |
| 3 | Clone simulators from per-Mac templates (`scripts/lib/sim.zsh`) | `matrix.sh --quick` 610.8 s to 418.3 s (-32%, test Mac B); about 3 min per matrix, more under load | done (`test.sh`, `matrix.sh`) |
| 4 | Build one simulator architecture (`scripts/build.sh`: `ARCHS=$(uname -m)`) | clean build 51.9 s to 35.6 s (-31%, test Mac B), 39.9 s to 28.6 s (-28%, this Mac); half the compile work on every edit | done |
| 5 | Fix `timeout` on test Mac A (macOS 26 has none) | `matrix.sh` on test Mac A stopped at its first row's boot; Device Hub never folded | done |
| 6 | Queue fixes in the runner and `remote_run` | stops 1-hour stalls (a job waiting on slot 1 only; priority marks held while running; orphaned waiters) | done |

Rejected after measuring: a shared compilation cache (3 s of 28 s), a shared package checkout
(3 s more), self-hosted GitHub runners (unsafe on a public repository), compile-time module
splits (no hot spots), retries on the hosted runners (would hide real flakes). See "Rejected".

## 1. Where the time goes (before)

Sources: the lanes' own logs and result bundles on test Mac A and test Mac B (`~/plain-lanes/*`:
`Logs/*/LogStoreManifest.plist` start and stop times, `xcresulttool` summaries of 61 result
bundles from 2026-11-27 and 28); one measurement job on this Mac (14 cores, 36 GB, load 3 at the
start); one before/after job on test Mac B (12 cores, 16 GB).

### 1.1 Per step

| Step | Test Macs, from the lanes' logs (loaded) | test Mac B, my job | This Mac (idle) |
|---|---|---|---|
| Clean build for testing, both sim archs (`build.sh` before) | 22–130 s (22–61 test Mac B, 28–129 test Mac A) | 51.9 s (load 29) | 39.9 s |
| Same, arm64 only (`build.sh` now) | — | 35.6 s (load 32); 29–30 s at load 3 | 28.6 s |
| No-change rebuild | 5–14 s | 2.3 s | 2.5 s |
| One-line edit, ShellUI / BrowserCore (bottom layer) | — | — | 4.6 s / 5.5 s |
| Resolve packages | 1–8 s | — | — |
| `swift test` (PlainKit, macOS), clean / no change | 40–153 s (test Mac A, through xcodebuild) | — | 36.4 s / 15.3 s |
| Simulator: create / first boot | — | — | 0.2 s / 22.7 s, then setup keeps running |
| Simulator: second boot / clone / clone's boot | — | — | 2.4 s / 3.9 s / 2.4 s |
| Making a template (boot, settle 60 s, shut down; once per device type per Mac) | — | 84–89 s | — |
| `xcodebuild test-without-building`, fixed cost (one skipped test) | — | — | 12.7–17.3 s |
| One matrix row, one capture test (the test itself) | 48–153 s (36–49 s) | — | — |
| `matrix.sh --quick` (5 rows, one capture test) | — | 610.8 s | — |
| One UI class (TabsTests, 6 tests), new sim / clone | — | 238.1 s / 231.0 s (load 6–7) | — |
| Full Smoke plan, one simulator (74 tests run, 117 skip) | 1950 s (test Mac A) | — | — |
| `scripts/test.sh` (Smoke on Duo and iPhone 17, one after the other) | about 65 min | — | — |
| `perf-gate.sh --sim` (Release build plus 14 tests) | 1054–1237 s (17.5–20.6 min) | — | — |

The tests, not the builds, are the cost. Smoke's 74 tests average 25 s each on a loaded test Mac A
(longest 70 s); the perf tests 40–125 s each (sum 862 s). A build is 1–2 minutes even clean, and
a lane's `build/` persists on the host between its jobs (the sync leaves it), so later builds are
incremental.

### 1.2 Compile profile (this Mac, clean, `-showBuildTimingSummary`)

SwiftCompile 198 s of CPU over 322 tasks, SwiftDriver 26 s, SwiftEmitModule 16 s, the asset
catalogs (four app icons) 12 s, linking 3.5 s. With `-warn-long-function-bodies=150` and
`-warn-long-expression-type-checking=150` only one body is slow: FeatureUI `FavoritesEditor.body`,
280 ms. No hot spot worth a module split.

### 1.3 How often, per lane

From the workflow (`docs/workflow.md`) and the lane rules: each fix round is one batched job
(incremental build, `swift test`, the lane's targeted UI tests and captures; 5–20 min on a
loaded host); each hand-off adds `matrix.sh --quick` once; each verify round adds
`scripts/test.sh` (about 65 min) and the simulator perf gate (about 19 min). A lane with three
fix rounds and two verify rounds uses about 3 × 12 + 2 × (65 + 19 + 8) ≈ 220 slot-minutes, of
which `test.sh` is about 130 (60%).

### 1.4 The machines, during the evening of 2026-11-27

| | test Mac A (M4, 10 cores, 16 GB, macOS 26) | test Mac B (12 cores, 16 GB, macOS 27) |
|---|---|---|
| Load average | 150–470 | 23–118 |
| CPU idle | 0% | 0–17% |
| Swap in use | 1.5 of 2 GB | 8 of 9 GB, 64 M swap-outs |
| Booted simulators | 4: 3 Plain with only 2 slots, 1 of another project | 2 |
| Free disk | 12–15 GB | 99 GB |

The top CPU users on test Mac A were a new simulator's first-boot processes (WeatherPoster,
NewsToday, PhotosReliveWidget, ScreenTimeWidget, PosterBoard, WidgetRenderer); templates remove
those. A third booted Plain simulator with two slots means a lane ran work outside the slots or
left a simulator booted (not touched: another lane's). test Mac A also runs another project's
`xcodebuild` and simulator.

### 1.5 One or two jobs per test Mac (measured)

On test Mac B, otherwise idle (my job held both slots; load 3–10): the same lane-sized job (a clean
arm64 build in its own DerivedData, then 16 UI tests, TabsTests and SearchSheetTests, on its own
iPhone 17 clone), twice in a row, then twice at once.

| | Each job | Both done | Tests |
|---|---|---|---|
| One at a time | 441 s, 450 s (builds 29, 30 s) | 892 s | 32 of 32 passed |
| Two at once | 490 s, 490 s (builds 43, 44 s) | 491 s | 32 of 32 passed; every test within 5 s of its one-at-a-time time |

Two at once does 1.8x the work per hour, each job only 10% slower, with no failures or timeouts.
So keep two slots. What overloaded the Macs was everything else: brand-new simulators' first
boots (now templates), work outside the slots, a third booted simulator, the other project on
test Mac A, and jobs pinned to one Mac while others were idle. Keep `-jobs` at its default, and keep
parallel testing off on the test Macs (each worker is one more booted simulator).
Not measured: two jobs at once on test Mac A (10 cores, the other project's load); if it stays above
about 40 load with two Plain jobs, try one slot there only.

## 2. GitHub Actions

### 2.1 Facts (GitHub's docs and runner images, read 2026-11-28)

- **Cost:** "Use of the standard GitHub-hosted runners is free and unlimited on public
  repositories" ([GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)).
  Billing lists standard hosted runners in public repositories and self-hosted runners as free,
  and "Larger runners are billed for public repositories"
  ([Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)).
  The $0.002-a-minute platform charge for self-hosted runners announced for 2026-03-01 is
  postponed with no new date; "GitHub Actions will remain free for public repositories"
  ([2026 pricing changes](https://github.com/resources/insights/2026-pricing-changes-for-github-actions)).
  So $0, as long as the repository stays public and only standard labels are used.
- **Concurrency (Free plan):** 20 jobs at once, at most 5 macOS
  ([Actions limits](https://docs.github.com/en/actions/reference/limits)); 6 hours per job. The cap
  is per account, shared by every lane and every repository. In practice 3 macOS jobs started at
  once, and up to 5 ran later in the same run.
- **Runner:** macOS arm64 standard: 3 cores (M1), 7 GB, 14 GB disk.
- **Xcode:** `macos-26` has Xcode 26.x only (no iOS 27 SDK) and can't build Plain. The `xcode-27`
  image (macOS 27.0.1, image 20261123, generally available since 2026-11-23,
  [announcement](https://github.com/actions/runner-images/issues/15397)) has Xcode 27.2 (27B52, the
  same build as the test Macs) at `/Applications/Xcode_27.2.app`, the iOS 27.2 SDK and runtime, and
  an iPhone Duo runtime for 27.2
  ([image readme](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)).
  XcodeGen is not installed; the workflow downloads the pinned 2.46.0 release and checks its
  SHA-256 (the digest GitHub publishes for it).
- **Security:** secrets are not passed to workflows triggered from forks
  ([using secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets)).
  Self-hosted runners "should almost never be used for public repositories" because "any user can
  open pull requests against the repository and compromise the environment"
  ([secure use](https://docs.github.com/en/actions/reference/security/secure-use)). The
  repository: Actions on, the default token read-only, first-time fork contributors need approval.

### 2.2 Measured (run 1, the full default: `swift test` plus Smoke, 3 shards on each device)

| Job | Time | Result |
|---|---|---|
| `swift test` | 3.5 min (2.3 min in run 2) | run 1: a StorageTests (XCTest) failure; run 2: passed. An intermittent test, not the runner |
| Build for testing (each Smoke job) | about 3.8 min | ok |
| Smoke 17 1/3 | 37 min (tests 1960 s) | 32 passed, 4 failed |
| Smoke 17 2/3 | 34 min | 41 passed, 2 failed |
| Smoke 17 3/3 | 42 min (2312 s) | 39 passed, 3 failed |
| Smoke duo 1/3 | 10 min | 8 passed, 1 failed, then the test runner crashed (`XCTWaiter handleStalledWait`); the rest never ran |
| Smoke duo 2/3 | 49 min (2742 s) | 39 passed, 5 failed |
| Smoke duo 3/3 | 39 min (2188 s) | 40 passed, 2 failed |
| Whole run, wall clock | about 70 min | (6 Smoke jobs share the account's 5 macOS slots) |

About 54 s per test against 25 s on a loaded test Mac A. Of the 17 failures, 9 hit the 120 s
per-test limit or could not launch the app ("does not have a process ID", "Failed to launch"),
and 1 crashed the runner: the 3-core runner is too slow for those tests' waits. The others are
"did not show" waits (pages, Settings, the reader). Four failed on both devices
(`AddressFocusTests.testCopiedLinkIsOfferedOnAnotherPage`,
`EngineTests.testReaderOpensOnAnArticleAndBackReturnsToThePage`,
`IntroTests.testBrowseForMeTurnOnThenReady`, `LaunchTests.testLongAwayOpensSearchOverTheLastTab`),
so they may be real on `dev`, or deterministic on the slow runner; a test Mac decides. One failed
on test Mac A too (`AppearanceTests.testDarkPagesSwitchShowsOnlyWhileDarkAndIsRememberedForTheSite`,
in a lane's full run on 2026-11-27).

So: a hosted pass is a real pass (nothing is retried and the limits are `test.sh`'s), but a
hosted failure is not yet a verdict. The workflow lists every test that did not pass (failed,
timed out, or never ran after a crash), and `scripts/ci.sh` prints them per device for a rerun on
a test Mac. That rerun is 10–20 tests (5–10 min), not the 65 min `test.sh`.

Run 2 (same code plus the review fixes; every Smoke job first checked "30 enumerated classes, all
in exactly one of 3 shards"): `swift test` passed in 2.3 min; the five Smoke jobs that had
finished when this was written took 40–62 min each and failed 2–7 tests each (20 in all), again
mostly 120 s limits and launches. Run 3 (`--tests PlainUITests/AppearanceTests --devices 17`):
17 min, the same two AppearanceTests failures, and `scripts/ci.sh` printed the rerun list and
deleted its branch and run.

Then the tests that failed on every hosted run, on a test Mac (test Mac B, iPhone 17 clone, load
13–39), with the same limits:

| Test | Hosted (runs 1–3) | Test Mac B |
|---|---|---|
| `AddressFocusTests.testCopiedLinkIsOfferedOnAnotherPage` | failed 3 of 3 | passed, 28 s |
| `AppearanceTests.testAppearanceIsSystemByDefaultAndSurvivesRelaunch` | failed 4 of 4 | passed, 63 s |
| `AppearanceTests.testDarkPagesSwitchShowsOnlyWhileDarkAndIsRememberedForTheSite` | failed 4 of 4 | **failed**, 71 s (also on test Mac A on 2026-11-27) |
| `EngineTests.testReaderOpensOnAnArticleAndBackReturnsToThePage` | failed 3 of 3 | passed, 46 s |
| `FeatureSheetTests.testHistoryShowsVisitsSearchesAndOpens` | failed 2 of 2 (iPhone 17) | passed, 24 s |
| `IntroTests.testBrowseForMeTurnOnThenReady` | failed 2 of 2 | passed, 28 s |
| `LaunchTests.testLongAwayOpensSearchOverTheLastTab` | failed 3 of 3 | passed, 31 s |

So the hosted failures are the runner, except one test that is failing on `dev` itself
(`testDarkPagesSwitch...`, a real failure to fix in its own lane). Hosted Smoke is a filter, not
a verdict: its passes count, and only what did not pass there goes to a test Mac.

### 2.3 What runs where

| Work | Where | Why |
|---|---|---|
| `swift test` (PlainKit), build check, test isolation check | hosted, every verify round | reliable there, and it frees a Mac slot |
| Smoke plan (`test.sh`) on Duo and iPhone 17 | hosted first; then on a test Mac only the tests listed as not passed | the biggest single cost on the Macs; hosted failures are mostly the slow runner (2.2) |
| A lane's targeted UI tests | a test Mac (fast, about 25 s a test) or hosted (`--tests`) when the queue is long | hosted takes about 2x as long per test |
| Matrix rows, flat screens | hosted (`--matrix`, `--rows`) when the Macs queue | each row its own runner |
| Matrix rows, the Duo's real inner screen; Device Hub captures | test Mac B | hosted runners can't drive Device Hub; test Mac A's Device Hub scripting is broken now |
| Perf gate, simulator | a test Mac | compared with earlier rows from the same kind of Mac; a 3-core runner would break the baseline |
| Perf gate, device; installs on the Duo; device screenshots | this Mac | needs the phone |
| Signing, TestFlight | test Mac B (`plain-release.zsh`) | needs the keychain and the App Store Connect key; no secrets go to GitHub |

Capacity: a full hosted Smoke is about 6 jobs × 35–50 min, about 240 runner-minutes; with 5
macOS jobs per account that is about one full Smoke an hour for all lanes together. Use it for
verify rounds, not every fix round.

### 2.4 How a lane uses it

`scripts/ci.sh` (`docs/development.md`, "GitHub Actions"): it pushes one commit with no parents
(HEAD's tree plus `.github/ci-request.json`) by "Plain CI" to `ci/<lane>`, waits with the GitHub
CLI, prints each job, the Smoke results and the tests to rerun on a test Mac per device, brings
matrix rows back and makes the sheets here, then deletes the branch (only if it is still its own
commit) and the run. No history goes up, so no author email; `scripts/local.env`, the signing
config, device ids and machine names are not in the tree (all gitignored). The workflow runs only
on `ci/**` pushes (write access needed), never on pull requests, has `contents: read` and no
secrets, and never pushes. Each Smoke job checks, before testing, that the shards together are
exactly the tests Xcode enumerates for the Smoke plan (`smoke-shards.zsh --verify`).

## 3. What changed

- `scripts/build.sh`: `ARCHS=$(uname -m)`. Only for this Debug simulator build; perf gate, device,
  archive and TestFlight builds are untouched.
- `scripts/lib/sim.zsh` (new): `sim_new` clones `plain-template-v1-<type>-<runtime>`, made once per
  Mac under `/tmp/plain-sim-template.lock`, booted once, settled 60 s, shut down, marked ready.
  Clones are made under the same lock. A missing, half-made, booted or unavailable template is
  remade. Under 25 GB free disk no new template is made (about 1.8 GB each). Used by `test.sh` and
  `matrix.sh`; not by the perf gate, which keeps its own fresh simulator so its numbers stay
  comparable with the earlier rows.
- `scripts/matrix.sh`, `scripts/duo-fold.sh`: `perl -e 'alarm N; exec @ARGV'` instead of `timeout`.
- `scripts/lib/remote.zsh` (`matrix.sh --host`): polls both slots instead of blocking on slot 1,
  waits while another lane's priority mark is on the host, survives `set -e` on a busy slot.
- `~/.claude/scripts/plain-remote.zsh` (shared runner, installed atomically): a priority job's marks
  go as soon as it starts (they used to stay for the whole run, keeping other lanes off the host's
  other slot); a waiting job whose parent has gone exits, checked right before each start (so
  `local` now polls its slot every 20 s instead of blocking on it). Kept: two slots, priority,
  `try_local`. The old runner is not in the repository; the change is in
  `~/.claude/scripts` only.
- `.github/workflows/ci.yml`, `scripts/ci.sh`, `scripts/lib/smoke-shards.zsh` (new): section 2.

Lane rules that would help most and need no code: pin a job to a host only when it needs that
host (Device Hub: test Mac B), else `auto:`; never boot a simulator outside a slot; shut down what you
boot.

## Rejected

- **Shared compilation cache** (`COMPILATION_CACHE_ENABLE_CACHING`, a per-host CAS; this Mac): a
  clean arm64 build with a warm cache took 25.2 s against 28.3 s cold (-11%); with the package
  checkout shared too, 22.0 s. The cache was 757 MB after one build, test Mac A has 12–15 GB free,
  and builds are about 5% of a lane's slot time.
- **Shared package checkout** (`-clonedSourcePackagesDirPath`): 3 s per clean build; packages
  resolve in 1–8 s. A lane's `build/` keeps its checkout between jobs anyway.
- **Seeding a new lane's DerivedData from a dev build:** at most one clean build (under a minute)
  per lane, and another checkout's build folder risks stale paths.
- **Module splits for compile time:** no hot spot (1.2).
- **dSYM / `ONLY_ACTIVE_ARCH` in Debug:** XcodeGen's Debug preset already uses `dwarf`;
  `ONLY_ACTIVE_ARCH` does nothing for a generic destination, hence `ARCHS` in `build.sh`.
- **Moving hosted unit tests to `swift test`:** `swift test` already runs every macOS-capable
  PlainKit test; `PlainTests` (App Intents inside the app) and the WebKit and UIKit package tests
  need a simulator.
- **Parallel testing on the test Macs:** each worker is one more booted simulator on 16 GB Macs.
  On hosted runners the parallelism is across runners.
- **Retrying failed tests on the hosted runners** (`-retry-tests-on-failure`): it would turn a real
  intermittent failure into a pass. Tests that did not pass there are rerun on a test Mac instead.
- **Longer time limits on the hosted runners:** the 120 s and 300 s limits are what `test.sh`
  uses; changing them would make the hosted run a different check.
- **Changing the perf gate** (templates, one architecture): the simulator gate compares with the
  previous `sim` row; a different simulator setup or build would change what it is compared with.
- **Self-hosted GitHub runners on our Macs:** free, but on a public repository a pull request can
  run code on them; the shared runner keeps the Macs.
- **Larger hosted runners, Xcode Cloud beyond the free use:** billed; the owner never pays.
- **One job per test Mac:** measured slower (1.5).
