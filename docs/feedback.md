# Owner feedback

Feedback from testing the app, newest first. Each item stays here until it ships; then it moves to "Done" with the build that has it.

## Open

- **Launch with tabs feels empty:** open to the last tab (or a search with the last tab behind it), like Arc but smoother. (Launch lane.)


- **Sign-in like Safari:** passkeys on sites that support them, and saved passwords from the Passwords app and every password manager on the phone (1Password, Bitwarden and others), as easily as in Safari. Both need Apple's web-browser entitlement; the request is ready for the owner to submit. Until it lands, sites are steered to password sign-in and a failed passkey attempt says why. Done when the entitlement ships and the device checks in `docs/research/sign-in.md` pass. (Sign-in lane.)


## Done

- **Suggestions flicker while typing:** fixed. Each row belongs to one suggestion, so a suggestion that stays never blinks; new rows fade in and old ones fade out in place (0.18 s, no bounce), a row that moves one place slides and a longer jump crossfades. Local pages and cached engine rows arrive as one list, and the previous engine rows hold for up to 120 ms until the new answer replaces them. Also fixed: engine rows that turned invisible after the first keystroke. (dev, suggestions lane.)

- **Tabs button with one tab:** with a single page the tabs button is the normal Tabs button, and a tap opens the switcher the swipe up opens (the page's card and a New Tab card), with the same motion. Its long press is unchanged; the start screen alone still has no tabs button. New Tab stays on the switcher's +, its New Tab card, More and the tabs menu. (dev, one-button lane.)

- **New Tab card content drifts:** fixed; the + and label stay at the card's center. (dev, next build.)

- **Sheets on paper:** Settings, History, Favorites, Archived Tabs and Downloads sit on Plain's textured paper, with rows on lifted paper cards, ink text and New York titles; everything else (swipes, search, edit, menus, Dynamic Type) stays native. A failed read shows Try Again instead of an empty list. (dev, sheets lane.)

- **Paper texture:** faint fibre and grain on the start screen, search, tab cards, sidebar and strip, reader and intro; flat under Increase Contrast. (dev, next build.)

- **Swipe up with one tab:** dragging the bar up (or Show All Tabs) with a single page opens the switcher with the same page-to-card motion: the card rests centered and a paper New Tab card grows in beside it; the tabs button's tap stayed "+" (now Tabs, see "Tabs button with one tab"). On the start screen alone the swipe still bumps. (dev, one-tab lane.)

- **Appearance:** Settings > Appearance (System by default, Light, Dark), saved and applied to every window with a crossfade; sites with a dark design follow it, and while Plain is dark, pages without one are darkened like Safari's Adaptive Dark Mode, with "Turn Off Dark Pages for This Site" in the page menu. (dev, next build.)

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
