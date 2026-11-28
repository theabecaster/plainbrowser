# Device matrix

Plain is designed for the iPhone Duo first and must work on every iPhone that runs it. Every UI
change runs `scripts/matrix.sh --quick` for the screens it touches, and the lead reads the contact
sheets before the change lands. The full matrix runs before each TestFlight release when the
machine allows. See "Device matrix" in `docs/workflow.md`.

## What Plain supports

The deployment target is iOS 27.2. Apple's list of iPhones that run it (support.apple.com, "iPhone
models compatible with iOS 27", read 2026-11-27): iPhone 11, 11 Pro, 11 Pro Max; 12 mini, 12, 12
Pro, 12 Pro Max; 13 mini, 13, 13 Pro, 13 Pro Max; 14, 14 Plus, 14 Pro, 14 Pro Max; 15, 15 Plus, 15
Pro, 15 Pro Max; 16, 16 Plus, 16 Pro, 16 Pro Max, 16e; 17, 17 Pro, 17 Pro Max, 17e; iPhone Air;
18 Pro, 18 Pro Max; iPhone Duo; iPhone SE (2nd and 3rd generation).

This Mac's iOS 27.2 runtimes have a simulator for every one of them (`xcrun simctl list runtimes
-j`, `supportedDeviceTypes`). The Duo has its own runtime, `iOS-27-2-iPhone19-4`.

These phones fall into a few screen classes, in points: 375x667 with a Home button (SE); 375x812
with a notch (12 mini, 13 mini, 11 Pro); 390 to 402 wide (12 to 17e, 15 to 18 Pro, with a notch or
the Dynamic Island); 414 to 420 wide (11, 11 Pro Max, Air); 428 to 440 wide (Plus and Pro Max);
and the Duo's two screens. The matrix has one row per class, and one per setting that changes
layout.

## Rows

| Row | Simulator | Screen | Setting | Run | Why |
|---|---|---|---|---|---|
| `se` | iPhone SE (3rd generation) | 375x667 portrait | default | quick | The narrowest and shortest screen, with no safe area at the bottom (Home button). Bars, sheets and menus must fit here. |
| `17` | iPhone 17 | 402x874 portrait | default | quick | The standard phone: most supported iPhones are 390 to 402 wide. |
| `max` | iPhone 18 Pro Max | 440x956 portrait | default | quick | The largest iPhone: nothing should look stretched or lost. |
| `duo-outer` | iPhone Duo, closed | 466x678 outer | default | quick | The Duo as most people hold it: Plain's primary phone layout. |
| `duo-inner` | iPhone Duo, open | 950x668 inner, landscape | default | quick | The inner screen: regular width and height, the vertical system bar, split panes and tab layouts. |
| `mini` | iPhone 13 mini | 375x812 portrait | default | full | The narrowest screen with a notch and a Home indicator (12 mini, 13 mini, 11 Pro). |
| `air` | iPhone Air | 420x912 portrait | default | full | The 414 to 420 class (iPhone 11, 11 Pro Max, Air), between the standard and the largest. |
| `17-land` | iPhone 17 | landscape | default | full | iPhone landscape with compact width and height. |
| `max-land` | iPhone 18 Pro Max | landscape | default | full | Landscape with regular width and compact height: the only iPhone with that size class pair. |
| `duo-inner-portrait` | iPhone Duo, open, rotated | 668x950 inner, portrait | default | full | The inner screen held upright: horizontal system bars. |
| `17-xxxl` | iPhone 17 | portrait | text `extra-extra-extra-large` | full | The largest standard Dynamic Type size (above XL), which many people use. |
| `se-ax3` | iPhone SE (3rd generation) | portrait | text `accessibility-extra-large` | full | An accessibility size on the smallest screen: the worst case for text that wraps or clips. |
| `17-dark` | iPhone 17 | portrait | Dark appearance | full | The dark theme on the standard phone. |
| `duo-inner-dark` | iPhone Duo, open | inner, landscape | Dark appearance | full | The dark theme on the Duo's inner screen, where most chrome differs. |
| `17-motion` | iPhone 17 | portrait | Reduce Motion | full | Plain's transitions crossfade instead (`Motion.prefersCrossfade`); the captures still reach every state. |

The default setting is light appearance, text size `large` (the iOS default) and Reduce Motion
off. The script sets text size and appearance with `simctl ui`, Reduce Motion with
`ReduceMotionEnabled` in the simulator's `com.apple.Accessibility` defaults, orientation through
`XCUIDevice` in the UI tests (`PLAIN_MATRIX_ORIENTATION`), and the Duo's fold and rotation with
`scripts/duo-fold.sh`.

Left out on purpose: the 390 to 393 wide phones (between `mini` and `17`, nothing in Plain's
layout changes there), the Plus and Pro Max models other than the 18 Pro Max (the same 428 to 440
class), the Duo partly open (the fold only moves split panes, which `DuoTests` checks), and
Increase Contrast (Plain's colors come from its design system, checked in `AppearanceTests`).

## Running it

```sh
scripts/matrix.sh --quick --out build/matrix                    # the five quick rows
scripts/matrix.sh --rows se,duo-inner -only-testing:PlainUITests/CaptureTests/testCaptureSheets
scripts/matrix.sh --full                                        # every row, before a release
```

- `--quick` (default) runs `FocusCaptureTests/testCaptureAddressFocus`; `--full` runs
  `CaptureTests` and `FocusCaptureTests`. `-only-testing:` picks other tests; without a capture
  test among them, the default capture test runs too.
- Output: `<out>/<row>/<screen>.png`, a contact sheet per screen in `<out>/sheets/` (that screen
  on every row, side by side, labeled with the row and pixel size), the logs and result bundles,
  and `<out>/summary.txt` (pass or fail per row, and how the Duo's fold was set).
- One simulator at a time, named `plain-matrix-<row>` (`PLAIN_SIM_PREFIX` must start with
  `plain-matrix`): created for its row, shut down and deleted after it; the exit trap deletes any
  left. Every launch is isolated (`scripts/lib/check-isolation.zsh` runs first).
- When Device Hub can't be driven (the Mac is locked, or the terminal has no Accessibility
  access), the Duo's inner rows run in the resizable window at the inner screen's size instead
  (`devicectl device appResize`, with `-PlainIgnoreOcclusions`), and `summary.txt` says so. That
  window is not the Duo: no fold and no vertical bar. `--resizable` forces it. There the largest
  screen is the whole Resizable display (2560x1440 pt) with the window in its top left corner;
  the sheets step cuts the shots to the window. Known gaps (2026-11-27): a session sometimes never
  takes the app (the shots are then the outer screen, and `summary.txt` says so), and when it
  does, `FocusCaptureTests` stops at step 5: a tap on the pill opens no search in that window.
- With `PLAIN_TEST_HOST` set (or `--host <name>`) the matrix runs on that test Mac and the results
  come back to `--out`; see "Test Macs" in `docs/development.md`.
- `XCUIScreen.screens` can list both of the Duo's screens, and the one that is off is
  black. `CaptureTests` and `FocusCaptureTests` attach every one; the sheets step keeps
  the largest screen that shows something. `scripts/matrix.sh --sheets-only --out <dir>` remakes
  the sheets of an earlier run.
- Timing (2026-11-27, a loaded Mac, the quick capture test): about a minute and a half for each
  iPhone row and the Duo's outer screen. The inner screen is slower: XCUITest waits 60 s for the
  app to go idle before each step there ("App animations complete notification not received").
  The full run, with every capture test, takes more than an hour.
