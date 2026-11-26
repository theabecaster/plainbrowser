# Plain

Plain is an iOS web browser built for speed and feel. It has a UIKit shell, uses `WKWebView`, and is designed for iPhone Duo first while working on every iPhone. Swift 6, iOS 27.1+.

## Layout

- `project.yml`: XcodeGen spec. The `.xcodeproj` is generated and not committed, so run `xcodegen generate` after pulling.
- `Packages/PlainKit`: all code, split into modules. The app target is a thin wrapper.
- `Brand/`: app icon (Icon Composer `.icon`) and color identity.
- `scripts/`: build, test, install, screenshot and perf gate. See `docs/development.md`.
- `docs/`: `architecture.md` (modules and data flow), `decisions.md` (what was chosen and why), `development.md` (commands and device setup), `perf-log.md` (perf numbers per merge), `research/notes.md` (verified API facts).

## Rules

- **Opinionated and simple.** Plain makes the decisions in its internal logic. Users get the fewest possible settings and options. Add a setting only when no single default can be right for most people, and prefer a smart automatic behavior over a toggle. Per-site choices are remembered automatically, not configured.
- **Performance is a requirement.** Every change runs `scripts/perf-gate.sh` on the device before it lands on `dev`. A budget breach blocks the change, the same as a failing test. Budgets live in `perf/budgets.json`.
- **Layers point one way:** UI → WebEngine/ContentBlocking/Reader → Storage → BrowserCore. `BrowserCore` and `Storage` never import UIKit or WebKit.
- **One owner per piece of state.** `TabStore` owns tabs. Each `Tab` owns its own state. The web view pool owns every `WKWebView`; UI code never creates one.
- **The main thread is for UI only.** No disk, network, database or decoding work on it.
- **Every user-visible interaction gets a signpost** in `PerfSignposts`.
- **No frameworks for architecture.** No TCA, DI, coordinator or reactive libraries. Use plain types, initializer injection, `@Observable` and async/await. Every dependency needs a reason in `docs/decisions.md`.
- **UIKit for the hot paths:** shell, web views, tab gallery, gestures, transitions. SwiftUI is for low-frequency screens only.
- **Layout comes from size classes and view bounds.** Never use `UIScreen.main`, device model or orientation.
- **Simulators:** create your own, named `plain-*`, and never touch other simulators.
- **Clean up when you finish.** Shut down and delete the simulators you created. Remove build output, test results, traces and screenshots you made. Remove your worktrees and merged branches. Leave the repo, its folders and the machine clean and ready for the next person.

## Git

- `main` is the latest release. `dev` is where work happens. Commit to `dev`, and merge into `main` only for a release.
- Commit small and often, then push.
- Never commit secrets, device IDs or machine names. Local values go in the gitignored `scripts/local.env`.
- License: AGPL-3.0-only. Code from other projects must use a compatible license, recorded in `docs/decisions.md`.
