# Clarity audit (2026-11-27)

Owner: "run through the whole app, every single state of every single page, and make sure things
are clear to the user — what things are. Keep our elegant premium feel and, most importantly, the
performance at all times."

A first-time user's walk through every page and state on `dev` at e8598ab. Each state was judged
for: is it obvious what every element is and does, is the mode visible (private, profile, reader,
translated, dark), is it clear what is tappable, where you are and how to get out, and is the copy
short, plain and the same everywhere. The previous walk is docs/research/ux-audit.md; what it
fixed was not judged again.

The walk is `PlainUITests/ClarityCaptureTests` (isolated, tolerant: a state it cannot reach is
skipped, never a failure). Run it with `TEST_RUNNER_PLAIN_CLARITY=1`; with
`TEST_RUNNER_PLAIN_CLARITY_DIR` each shot is taken by `simctl` on the Mac, which is how the Duo's
inner screen is captured. Captures went to the session scratchpad (`clarity/<config>/<shot>.jpg`)
and are not committed; names in brackets below are `<shot>` names.

## 1. Pages and states

`[x]` walked and read, `[c]` judged from the code only (the state can't be reached in a simulator
or by a test), `[ ]` not covered. Shot prefixes are in brackets.

### Intro [intro-]
- [x] Splash (the mark assembling)
- [x] Each step in order, with Skip, to the dissolve into search
- [c] Browse for Me step per availability (available, off, not ready): intro lane's captures
- [c] Default browser step (behind `FixedChoices.defaultBrowserPromptsEnabled`)

### Start screen [start-]
- [x] First run: field focused over the mark, the one-sentence hint
- [x] Empty, field closed: mark, sentence, Search, shortcuts
- [x] With favorites, history and an archive: focused rows; closed, with shortcuts
- [x] Private empty tab: focused and closed
- [x] Page sheet without a page
- [x] Default browser card (preview argument)

### A page [page-]
- [x] Loaded (http: "Not Secure —")
- [x] Loading, and its sheet (Stop)
- [x] Bar collapsed to the pill; chrome hidden; revealed
- [x] Find on Page open, typed, matches
- [x] Zoomed, and the sheet's zoom row
- [x] Failed: not answering, host not found, site gone under a page; the failed page's sheet
- [c] Offline, timed out, certificate error ("Visit Anyway"), crashed, resend form: wording read in `PageStateView`
- [c] PDF (Save PDF to Files): no local PDF in the test server
- [x] Dark pages on and off for a site; the app's Appearance set to Dark [misc-08…12]

### Page sheet [sheet-]
- [x] Article: address row, tiles (Find, Reader, Summarize, Share), keep row, rows, chips
- [x] After Favorite and Read Later (Unfavorite, Remove)
- [x] Copy Link answered in place
- [x] Site Settings menu
- [x] Editing the address from the host
- [x] Reader, and the sheet over the reader
- [x] Share sheet, with Print and Save as PDF
- [x] Foreign page: the one-time hint, Translate tile, translated, Original
- [x] Private tab's sheet [tabs-12]; failed page's sheet [page-14]; loading [page-04]; start [start-03]
- [x] Without Apple Intelligence [summary-11]

### Address bar [address-]
- [x] Resting on a page; focused on a page (the page's row, favorites, recent pages)
- [x] Typing: suggestions; a query with Browse for Me; an address (the row leaves)
- [x] The page's own address in the field, Copy, Copied
- [x] Open Copied Link offered on another page
- [x] Private tab focused [tabs-13]

### Tabs [tabs-]
- [x] Switcher with one tab, with several, its More menu, a card's menu
- [x] A card closed: Reopen toast
- [x] Close All Tabs confirmation
- [x] Tabs menu (long press) with one tab and with several
- [x] After a bar swipe
- [x] Private: empty list, a private page, its sheet, its switcher, the regular list from it
- [c] Bar swipe mid-gesture, New Tab card past the last tab, card drag: stills can't hold a gesture; the motion lanes' recordings cover them

### Profiles [profiles-]
- [x] New Profile in the switcher's More menu; the name alert
- [x] An empty profile's list; the switcher capsule and its menu; Rename
- [x] A profile's start screen, page and switcher; Delete confirmation

### Sheets [sheets-, settings-]
- [x] History, Reading List, Favorites: empty
- [x] History, Reading List, Favorites, Archived Tabs: with rows; swipe actions; History search with no results; Clear
- [x] Downloads: toast, sheet row in the page sheet, the sheet, a row's menu
- [x] Settings: root, Search Engine, Tab Layout, Archive Tabs, Appearance, App Icon, About, Clear confirmation

### Summaries [summary-]
- [x] Browse for Me: the row, searching, reading, writing, done, sources, a source's menu
- [x] Summarize Page: start and done
- [x] Without the model: no row, no tile
- [c] Failures (no results, none readable, offline, declined, language): wording read in `SummaryView`

### Launch [launch-]
- [x] Cold with a last tab: first screen, settled
- [x] After 4 hours: fresh search over the tab; back on the tab
- [x] No tabs

### Links, prompts, forms [misc-]
- [x] Link menu and its preview; Opened in background toast
- [x] Cookie banner answered; a form's keyboard; passkey toast
- [x] Location prompt and denied; camera prompt (preview argument)

### Duo inner screen [inner-]
- [x] Top bar with one tab; the strip with three; page sheet (popover)
- [x] Side pane: Reader, Find, History
- [x] Split, and its sheet (Swap Panes, Close Pane); tabs menu (New Window)
- [x] Tab Layout Left and Right
- [c] A second window: one scene at a time shows in the stand-in window
