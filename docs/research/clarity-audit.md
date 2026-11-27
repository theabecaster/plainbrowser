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

## 2. Findings, ranked by what a first-time user meets

**Fixed** items landed in this lane. The others name the lane that owns the area, with the exact
change to make. Captures: `clarity/<config>/<shot>.jpg` in the session scratchpad (configs:
`i17-light` before the fixes, `i17-fix` after, `small-light`, `duo-outer`, `i17-dark`, `i17-xl`,
`inner-land`, `inner-port`).

### High

1. **Fixed (the sheet). Reader and a translated page look like any other page, and their tiles
   looked the same on and off.** In the reader the pill still reads "Not Secure — localhost" and
   the sheet's tile read "Reader" with the same symbol as before it was opened; a translated page
   showed "Original" under the same symbol. Nothing said which mode the page is in or which
   control leaves it (Back closes the reader, which nothing says). Now a tile whose mode is on
   draws in the accent with an accent rim and the selected trait: "Reader" while the reader is
   open, "Translated" ("Translating…" until the first text lands) on a translated page; a tap
   turns the mode off. Still open for the **shell lane (pill)**: the resting pill should name the
   mode in place of the security word, quiet, as it does "Not Secure —": "Reader — host" and
   "Translated — host". [before: i17-light/sheet-07-reader, sheet-08-reader-sheet,
   sheet-13-translated, sheet-14-translated-sheet; after: i17-fix/sheet-08-reader-sheet,
   sheet-14-translated-sheet]
2. **A page in another profile looks exactly like a page in Personal.** After New Profile "Work",
   a Work page has the same pill, bar and sheet as a Personal one; the profile's name shows only
   in the switcher's capsule and in the start screen's sentence. A sign-in on the wrong profile is
   the cost. **Lead to route (profiles):** with two or more profiles, name the profile where the
   page sheet names the site (under the host, in place of nothing: "Work"), and in the tabs
   button's VoiceOver value ("3 tabs, Work"). No badge on the bar. [i17-light/profiles-08-work-page
   against page-01-loaded]
3. **Fixed. Empty Favorites and Reading List sent the user to "the page menu", a name nothing on
   screen carries, in the system's bold black title.** (The bold title was item 15 of the last
   audit.) Now every sheet's empty state is a quiet symbol and one sentence in the ink's secondary
   step (`EmptyStateView`), and the two that point at a button show it: "Tap (More's symbol) on a
   page, then Favorite." / "…then Read Later." VoiceOver reads "Tap More on a page, then
   Favorite." [before: i17-light/sheets-empty-favorites, -history, -reading-list; after: i17-fix,
   same names]
4. **The private toggle in the switcher is a bare hand.** `hand.raised` with no caption is the
   only entrance to private tabs in the switcher, and in an empty profile's list it is the only
   control at the bottom of the screen. Its on state (filled hand on a light disc, violet
   backdrop) is clear once known. **Priv lane:** caption or name the control (Safari's switcher
   says "Private"); the same symbol is captioned "Private Tab" everywhere else in Plain.
   [i17-light/tabs-05-gallery, profiles-03-empty-profile; i17-fix/tabs-10-private-empty,
   tabs-14-private-gallery]
5. **A private page is told apart only by a lilac tint on the pill and bar.** No word says
   "Private" on a page; over a white page the tint is faint. **Priv lane:** the pill's quiet lead
   word, as for "Not Secure —". [i17-fix/tabs-11-private-page against i17-light/page-01-loaded]

### Medium

6. **Fixed (wording). The page sheet's "Favorites" opens an editor, not the favorites.** A tap on
   a row renames it; nothing opens. The footer now says so: "Tap a favorite to rename it. To open
   one, tap the address bar." **Lead's call:** caption the chip "Edit Favorites" (its VoiceOver
   name) or make a tap open the page. [i17-light/sheets-1-favorites, sheets-2-favorites-swipe]
7. **Stop is an X at the end of the sheet's address row.** While a page loads the row is Back,
   host, Copy Link, X. An X in the top corner of a sheet reads as "close the sheet". Reload's
   place is right (state rules §4). **Lead's call (page sheet):** `xmark` is Safari's Stop in the
   address field, where nothing else can close; here `stop.circle`, or the X inside the circular
   arrow's slot with the progress line under the host, would not be mistaken.
   [i17-light/page-04-loading-sheet]
8. **Browse for Me's row sits on the veiled page's text when there are no suggestions.** With a
   query that has no rows the row's symbol and title are drawn straight over the page's words
   ("read." shows through beside the sparkles). **Arcbar lane:** the row needs the card's paper
   under it whenever it shows. [i17-light/address-03-query-browse-for-me]
9. **"Tab closed · Reopen" covers the recently closed rows above the field.** After the last tab
   closes, the search opens with the closed tabs as rows (a return arrow each) and the toast on
   top of the second row's title. Two offers of the same thing, one over the other. **Arcbar
   lane:** no toast while the closed tab is a row on screen, or the toast above the rows.
   [i17-light/launch-05-all-closed]
10. **"Passkeys will work once Apple approves Plain"** is about Plain's paperwork, not about what
    the user can do. **Sign-in lane:** "Passkeys aren't available in Plain yet. Use your
    password." [i17-light/misc-05-passkey-toast]
11. **After "Don't Allow" nothing says how to change it.** The page says "Location denied" and
    Plain shows nothing; Site Settings has no row for it. **Perm lane.**
    [i17-light/misc-06-location-prompt, misc-07-location-denied]
12. **Known, still there (shell lane): the pill and bar over text** (the collapsed pill worst),
    **the link preview pushing its menu off the screen**, and **"Plain couldn't open this page."
    for a refused connection.** [i17-light/page-06-collapsed-pill, misc-01-link-menu,
    page-13-error-refused]

### Low

13. **Fixed. The summary sheet's Done was ink; every other sheet's is the accent.**
    [before: i17-light/summary-05-done; after: i17-fix/summary-05-done]
14. **"Remove" under the crossed glasses.** Next to "Unfavorite" it does not say what it removes.
    **Lead's call:** "Unsave", or the filled glasses with "Saved" in the accent, as the on tiles
    now do. [i17-light/sheet-03-favorited-saved]
15. **Site Settings' items word the same thing three ways:** "Desktop Site", "Turn Off Blocking
    on This Site", "Turn Off Cookie Banner Blocking", "Turn Off Dark Pages for This Site". Under a
    menu titled Site Settings the tail is noise, and Desktop Site shows no on or off. **Lead's
    call** (UI tests name these labels). [i17-light/sheet-05-site-settings, misc-11-dark-site-settings]
16. **The zoom row has no name:** "− 100% +", the percent dimmed at 100. Read correctly by
    everyone asked to guess, so left. [i17-light/sheet-02-article-sheet]
17. **Downloads' Show in Files is a bare folder** at the title's leading end (named for
    VoiceOver). Left: the row's menu has the words. [i17-light/sheets-03-downloads]
18. **Settings footers wrap at two widths:** Archive Tabs' and Appearance's break early, under
    the picker's value. **Sheets (polish backlog).** [i17-light/settings-01-root]
19. **An empty History still shows its search field and a dim "Clear…".** [i17-fix/sheets-empty-history]
20. **Intro, "Made for iPhone Duo — Unfold for two pages side by side" on a phone that cannot
    unfold** (item 16 of the last audit). **Intro lane.** [i17-light/intro-02, small-light/intro-02]

### Checked and clear

The intro's steps and Skip; the start screen's sentence, Search and captioned shortcuts; the
private start sentence; a profile's start sentence; loading (progress in the pill, Stop in
Reload's place); Find; error pages (one sentence, Try Again, the address tried in the pill); the
share sheet with Print and Save as PDF; the focused field's rows (clock, pencil, Open Copied
Link); the tabs menu's subtitles that name the gesture; the switcher, its menus and the Reopen
toast; Close All's count; the profile capsule, New, Rename and the Delete confirmation, which
names everything that goes; History, its search, swipe and Clear menu; Reading List; the archive;
Settings and every screen under it; Browse for Me from the row to its sources, and Summarize
Page; no trace of either without the model; launch to the last tab, the fresh search after four
hours and the way back; cookie banners; the form bar; the permission questions.
