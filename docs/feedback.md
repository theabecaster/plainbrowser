# Owner feedback

Feedback from testing the app, newest first. Each item stays here until it ships; then it moves to "Done" with the build that has it.

## Open

- **Sign-in like Safari:** passkeys on sites that support them, and saved passwords from the Passwords app and every password manager on the phone (1Password, Bitwarden and others), as easily as in Safari. Both need Apple's web-browser entitlement; the request is ready for the owner to submit. Until it lands, sites are steered to password sign-in and a failed passkey attempt says why. Done when the entitlement ships and the device checks in `docs/research/sign-in.md` pass. (Sign-in lane.)

- **Swipe up with one tab:** dragging the bar up with a single page opens the switcher with that card and a clear way to add a new tab, as in Arc. (One-tab lane.)

- **Appearance:** Settings choice of System (default), Light or Dark, saved; sites follow it, and pages without a dark mode get darkened like Safari's new auto dark mode, with a per-site off switch. (Appearance lane.)

- **Paper texture:** a subtle, elegant paper texture on the app's own surfaces, never costing frames or quality, never called out in the UI. (Paper lane.)

## Done

- **Suggestions over the start-screen mark:** while a query is typed on the start screen, the mark and its shortcuts recede (fade, shrink, drift up) and the rows sit on the paper; they come back when the query is cleared. (dev, state lane.)

- **Discoverable tab features:** New Private Tab, Reopen Closed Tab and Archived Tabs are in More's top section wherever they apply and on the start screen as shortcuts; a one-time tip teaches the long press on Tabs. (dev, state lane.)

- **State-aware controls:** every control follows `docs/state-rules.md`: the tabs button is Tabs, "+" or hidden; empty tabs never pile up; private closes offer no Reopen. (dev, state lane.)

- **Intro styling:** the intro keeps its steps, words and simplicity in Plain's own look: paper, a dawn window with the mark on its sill, New York headlines with a coral fold underline. (dev, next build.)

- **Tab Layout values:** Above (tab strip), Left and Right (sidebar), on the Duo inner screen. (dev, next build.)

- **First-run intro:** Arc Search's intro look and feel in Plain's identity: Stem splash, icon picker (Dawn, Night, Coral, Paper), live blocking demo. The default-browser step and empty-tab card are built and wait for Apple's entitlement. (dev, next build.)

- **Floating address bar:** no glass band behind the pill; the page runs under it. (dev, after build 2611261658.)
- **Tab switcher:** behaves like the iOS app switcher, Arc Search style. (Build 2611261658.)
- **Empty tab:** a start screen with the Plain mark instead of a blank page. (Build 2611261658.)
- **App icon:** Stem, a paper ring with a hidden P. (Build 2611261448.)
- **Long addresses overflowing the pill on the Duo outer screen.** (Build 2611261056.)
