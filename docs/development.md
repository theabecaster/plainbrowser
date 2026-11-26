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

WebKit tests (`WebEngineTests`, `ContentBlockingTests`) need an iOS simulator; on macOS only their
pure parts run. Run them on one of your own `plain-*` simulators:

```sh
cd Packages/PlainKit
xcodebuild test -scheme PlainKit-Package -destination id=<udid> -only-testing:WebEngineTests
```

They serve pages from a local HTTP server on 127.0.0.1 and print timings as `[plain-measure]`
lines.

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

`scripts/testflight.sh <notes-file> [--build N] [--skip-upload] [--cloud | --auto] [--dry-run]` ships the current checkout:

1. It archives a Release build on this Mac (or on Xcode Cloud, see below) and uploads it with the App Store Connect API key.
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

Testers outside the team only get builds that passed Beta App Review, and only one build is in review at a time. A newer upload replaces any build still waiting to be submitted, so write each build's notes to cover everything since the last build the external group received, not just since the last upload. Leave out internal work (refactors, tests, scripts, docs). Skip a section that would be empty.

The API can't create the app record, so a person makes it once in App Store Connect. Every other step runs through the API.

## Xcode Cloud

Xcode Cloud builds for TestFlight when this Mac is busy. It uses only the 25 compute hours a month included in the Apple Developer Program. Never subscribe to an Xcode Cloud plan. Without a subscription Apple has nothing to bill: at 25 hours, Xcode Cloud stops running builds until the next month.

- `scripts/testflight.sh <notes> --cloud` builds on Xcode Cloud. `--auto` does so only when this Mac is busy: two or more `xcodebuild` processes, or a 1-minute load above 1.5 × the core count. `--auto` builds locally when the Mac is free, when Xcode Cloud is not set up, when the checkout is not the pushed head of its branch, or when Xcode Cloud can't start (for example, the budget guard says no). Without either flag, nothing changes.
- Xcode Cloud archives and uploads the build itself, for internal testing only. So a cloud build goes to `TESTFLIGHT_INTERNAL_GROUP_ID` (it must be an internal group), never to an external one. The script waits for the run and stops unless Apple reports that it built this `HEAD`. Then it tags `tf/<build>`, sets the notes, and adds the build to the group: Xcode Cloud builds never join a group by themselves, even one set to all builds.
- Xcode Cloud builds the branch head on GitHub, so push first. `ci_scripts/ci_post_clone.sh` generates the project there: it installs XcodeGen, writes `DEVELOPMENT_TEAM = $CI_TEAM_ID`, sets `CURRENT_PROJECT_VERSION`, and copies PlainKit's package pins into the project, because Xcode Cloud does not resolve packages itself.
- **Build numbers.** Xcode Cloud replaces `CFBundleVersion` with its own counter (1, 2, 3...) on every build it uploads, whatever the project says. Local builds use `yyMMddHHmm`, so cloud builds sort below them in TestFlight. App Store Connect accepts this for iOS (each version and build pair only has to be unique). To keep them in order, set Xcode Cloud > Settings > Build Number > Next Build Number in App Store Connect above the latest local build; the API can't set it.
- The workflow `TestFlight` starts only by hand: no branch, pull request, tag or schedule trigger. It has one Archive action (any iOS device, scheme Plain, Release, internal-only TestFlight upload), no tests, and a clean build.

`node scripts/xcode-cloud.mjs` (settings from the environment or `scripts/local.env`):

| Command | What it does |
|---|---|
| `setup [--dry-run]` | Checks the workflow (`XCODE_CLOUD_WORKFLOW_ID`) against the settings above and repairs what differs, after disabling the product's other workflows. Changes nothing when all is right. Creates the workflow only if it is gone. |
| `usage` | Compute hours used across all the team's Xcode Cloud products: this calendar month and the last 31 days. |
| `start [branch] [--dry-run]` | Starts the workflow on the branch (default `dev`) and prints the run id. Exit 3: budget guard refused. Exit 4: not set up. |
| `wait <run-id>` | Polls until the run ends, then prints the commit it built and its App Store Connect build number. Fails unless the run succeeded. |

**Budget guard.** `start` refuses when the hours used in the last 31 days plus 0.25 h for the new run would pass 20 h, leaving 5 h of margin under the 25. The API has no usage endpoint, so the script adds up the time every action of every run spent inside the window. It counts 31 days back because Apple does not say on which day the month resets, and those 31 days contain any monthly cycle. `start` also refuses while another run of the workflow is still going.

**One-time setup by the owner** (done 2026-11-26; repeat only if the Xcode Cloud product is deleted). The API can't create the product:

1. Run `xcodegen generate` and open `Plain.xcodeproj` in Xcode, signed in with the team's Admin or Account Holder Apple Account.
2. Choose Integrate > Create Workflow (or Product > Xcode Cloud > Create Workflow) and select the Plain app.
3. Keep the default workflow and continue. Grant Xcode Cloud access to the GitHub repo `theabecaster/plainbrowser` only, and pick the existing Plain app record in App Store Connect.
4. Stop there. Don't press Start Build, and push nothing until the next step: the default workflow builds on every change to the default branch.

Then right away put the product and workflow ids in `scripts/local.env` and run `node scripts/xcode-cloud.mjs setup`. It disables any other workflow first, then makes this one manual-only. Check with `scripts/testflight.sh <notes> --cloud --dry-run`.
