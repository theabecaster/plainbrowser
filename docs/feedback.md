# Owner feedback

Feedback from testing the app, newest first. Each item stays here until it ships; then it moves to "Done" with the build that has it.

## Open

- **Tab Layout values:** "Above", "Left" and "Right" instead of "Regular Tabs" and "Side Tabs". The name "Tab Layout" stays. (M3 lane.)
- **State-aware controls:** a control appears only when it does something useful in the current state, for example no tab switcher or new-tab button with a single empty tab. Rules in `docs/state-rules.md`. (State audit, then a fix lane.)
- **First-run intro:** Arc Search's intro look and feel in Plain's identity, including the blocking toggle demo and the default-browser card on the empty tab (gated until Apple grants the entitlement). (Intro lane.)

## Done

- **Floating address bar:** no glass band behind the pill; the page runs under it. (dev, after build 2611261658.)
- **Tab switcher:** behaves like the iOS app switcher, Arc Search style. (Build 2611261658.)
- **Empty tab:** a start screen with the Plain mark instead of a blank page. (Build 2611261658.)
- **App icon:** Stem, a paper ring with a hidden P. (Build 2611261448.)
- **Long addresses overflowing the pill on the Duo outer screen.** (Build 2611261056.)
