# Development

Xcode 27.2+, XcodeGen (`brew install xcodegen`) and `jq`. Every script runs from any directory.

## Commands

| Command | What it does |
|---|---|
| `scripts/build.sh` | `xcodegen generate`, then a Debug simulator build of the app and UI tests (no simulator needed). Log: `build/build.log`. |
| `scripts/test.sh` | `swift test` for PlainKit on macOS, then the Smoke test plan on the `plain-duo` (iPhone Duo) and `plain-17` (iPhone 17) simulators. It creates them when missing and deletes them afterwards; `KEEP_SIMS=1` keeps them. |
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

Signing is automatic with team R2PVQ496X7; the scripts pass `-allowProvisioningUpdates
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
| `hitchMsPerS` | `testPageScrollHitches`: scroll hitch ratio on a Wikipedia article (needs network) | target 5, fail ≥ 10 |

- **Simulator (default):** runs on the `plain-perf-duo` simulator (iPhone Duo), created when
  missing and shut down afterwards. Fails on a test failure or on a regression of more than 20%
  (`simRegressionTolerance` in `perf/budgets.json`) against the previous `sim` row for the same
  metric. Simulator numbers are not comparable to the device budgets.
- **Device:** `scripts/perf-gate.sh --device` or `PLAIN_PERF_TARGET=device`. Applies the absolute
  budgets in `perf/budgets.json`. A locked or unreachable phone exits 2 with a message instead of
  hanging.

Exit codes: 0 pass, 1 budget breach, regression or test failure, 2 device not ready.

## Simulators

Create your own, named `plain-*`, and never touch others: other agents share the machine. The
scripts use `plain-duo`, `plain-17` and `plain-perf-duo`. Delete yours when you finish
(`xcrun simctl delete <udid>`).

Duo simulator: device type `iPhone Duo`, runtime `com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4`.
Set the fold state from the Device Hub (Closed / Partially Open / Open); there is no CLI for it.
