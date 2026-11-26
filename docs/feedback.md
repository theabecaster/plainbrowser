# Owner feedback

Feedback from testing the app, newest first. Each item stays here until it ships; then it moves to "Done" with the build that has it.

## Open

- **Appearance:** Settings choice of System (default), Light or Dark, saved; sites follow it, and pages without a dark mode get darkened like Safari's new auto dark mode, with a per-site off switch. (Appearance lane.)

- **Paper texture:** a subtle, elegant paper texture on the app's own surfaces, never costing frames or quality, never called out in the UI. (Paper lane.)

- **Intro styling:** keep the intro's steps, words and simplicity, but restyle it in Plain's own colors and look (paper, dawn, coral fold) so it no longer reads as Arc's. (Intro restyle lane.)

- **Suggestions over the start-screen mark:** typing in a new tab can draw suggestion rows over the white mark, making them unreadable. Keep the design; the mark should yield smoothly while suggestions show. (State fix lane.)

- **Discoverable tab features:** with one tab the tabs button becomes "+"; New Private Tab, Reopen Closed Tab and Archived Tabs must stay obviously reachable (More menu, start-screen shortcuts), not only behind a long press. (State fix lane.)

- **State-aware controls:** a control appears only when it does something useful in the current state, for example no tab switcher or new-tab button with a single empty tab. Rules in `docs/state-rules.md`. (State audit, then a fix lane.)

## Done

- **Tab Layout values:** Above (tab strip), Left and Right (sidebar), on the Duo inner screen. (dev, next build.)

- **First-run intro:** Arc Search's intro look and feel in Plain's identity: Stem splash, icon picker (Dawn, Night, Coral, Paper), live blocking demo. The default-browser step and empty-tab card are built and wait for Apple's entitlement. (dev, next build.)

- **Floating address bar:** no glass band behind the pill; the page runs under it. (dev, after build 2611261658.)
- **Tab switcher:** behaves like the iOS app switcher, Arc Search style. (Build 2611261658.)
- **Empty tab:** a start screen with the Plain mark instead of a blank page. (Build 2611261658.)
- **App icon:** Stem, a paper ring with a hidden P. (Build 2611261448.)
- **Long addresses overflowing the pill on the Duo outer screen.** (Build 2611261056.)
