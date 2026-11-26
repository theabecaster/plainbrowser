# Development

Xcode 27.2+, XcodeGen (`brew install xcodegen`) and `jq`. Every script runs from any directory.

## Commands

| Command | What it does |
|---|---|
| `scripts/build.sh` | `xcodegen generate`, then a Debug simulator build of the app and UI tests (no simulator needed). Log: `build/build.log`. |
| `scripts/test.sh` | `swift test` for PlainKit on macOS, then the Smoke test plan on the `plain-duo` (iPhone Duo) and `plain-17` (iPhone 17) simulators. It creates them when missing and deletes them afterwards; `KEEP_SIMS=1` keeps them. `PLAIN_SIM_PREFIX=plain-x` renames them (`plain-x-duo`, `plain-x-17`) so parallel runs don't share simulators. |
| `scripts/perf-gate.sh` | The perf tests (Perf test plan, Release). Simulator by default; `--device` for the phone. Appends a row to `docs/perf-log.md`. See below. |
| `scripts/install-duo.sh [--no-launch] [build]` | Release build for the device, install, then launch. Best effort: an install that fails (phone locked or unreachable) prints a note and exits 0; launch is skipped on a locked phone. `--no-launch` installs only. |
| `scripts/shot.sh <name>` | Screenshots every active display of the device into `build/shots/<name>-<display>.png`. |

Package tests alone: `cd Packages/PlainKit && swift test`.

## Device setup

The device scripts read the phone's UDID from `PLAIN_DEVICE`, or from `scripts/local.env`
(gitignored):

```sh
cp scripts/local.env.example scripts/local.env   # then set PLAIN_DEVICE
```

Signing is automatic. The team ID is personal, so it lives in the gitignored
`Config/Signing.local.xcconfig`:

```sh
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig   # then set DEVELOPMENT_TEAM
```

Simulator builds work without it. The device scripts pass `-allowProvisioningUpdates
-allowProvisioningDeviceRegistration`. For perf runs keep the phone awake and unlocked
(Settings > Display & Brightness > Auto-Lock > Never).

## Perf gate

`scripts/perf-gate.sh` runs `PlainUITests/PerfTests` through `Perf.xctestplan` in a Release build,
reads the metrics with `xcrun xcresulttool get test-results metrics`, and appends one row to
`docs/perf-log.md` with the date, the git SHA and the target.

| Metric | Test | Budget (device) |
|---|---|---|
| `launchMs` | `testLaunch`: `XCTApplicationLaunchMetric(waitUntilResponsive: true)` | target 300, fail ≥ 400 |
| `searchFieldMs` | `testLaunchToSearchFieldReady`: the `launch` signpost interval | target 300, fail ≥ 400 |
| `hitchMsPerS` | `testPageScrollHitches`: `XCTHitchMetric` while scrolling a Wikipedia article (needs network). Device only: the simulator reports no hitch data. | target 5, fail ≥ 10 |

- **Simulator (default):** runs on the `plain-perf-duo` simulator (iPhone Duo; `PLAIN_SIM_PREFIX`
  renames it), shut down afterwards and deleted when the run created it. Fails on a test failure or on a regression of more than 20%
  (`simRegressionTolerance` in `perf/budgets.json`) against the previous `sim` row for the same
  metric. Simulator numbers are not comparable to the device budgets.
- **Device:** `scripts/perf-gate.sh --device` or `PLAIN_PERF_TARGET=device`. Applies the absolute
  budgets in `perf/budgets.json`. A locked or unreachable phone exits 2 with a message instead of
  hanging.

Exit codes: 0 pass, 1 budget breach, regression or test failure, 2 device not ready.

## Simulators

Create your own, named `plain-*`, and never touch others: other agents share the machine. The
scripts use `plain-duo`, `plain-17` and `plain-perf-duo`; set `PLAIN_SIM_PREFIX` (e.g. `plain-r`) to
get your own set. Delete yours when you finish
(`xcrun simctl delete <udid>`).

Duo simulator: device type `iPhone Duo`, runtime `com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4`.
Set the fold state from the Device Hub (Closed / Partially Open / Open); there is no CLI for it.

## TestFlight

`scripts/testflight.sh <notes-file> [--build N] [--skip-upload] [--dry-run]` ships the current checkout:

1. It archives a Release build on this Mac and uploads it with the App Store Connect API key.
2. It waits until App Store Connect marks the build `VALID` (up to 45 minutes).
3. It sets "What to Test" from the notes file.
4. For an external group, it submits the build to Beta App Review and waits for approval (up to 2 hours).
5. It adds the build to the group.

It reads `ASC_KEY_ID`, `ASC_ISS`, `ASC_KEY`, `TESTFLIGHT_APP_ID` and `TESTFLIGHT_GROUP_ID` from the environment or `scripts/local.env` (see `scripts/local.env.example`). `--dry-run` checks the key, app and group with read-only calls. `scripts/asc.mjs METHOD PATH [BODY]` makes one App Store Connect API call for anything else.

**Notes for testers.** Every build gets notes written for the people testing it, not for developers. List what changed since the last build: `git log --first-parent $(git describe --tags --match 'tf/*' --abbrev=0)..HEAD` (the script tags each upload `tf/<build>`). Use these sections, each a list of short lines in plain words:

- **NEW:** what testers can now do, and where to find it.
- **IMPROVED:** what feels or works better.
- **FIXED:** bugs testers could have hit.
- **NOT IN YET:** big things still missing, so nobody reports them.
- **WHAT TO TEST:** two or three things to try in this build.

Leave out internal work (refactors, tests, scripts, docs). Skip a section that would be empty.

The API can't create the app record, so a person makes it once in App Store Connect. Every other step runs through the API.
