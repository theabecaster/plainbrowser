# Dark Pages: off by default, one suggestion, an indicator in the field (2026-11-27)

Owner's request (2026-11-27): dark pages becomes something the user turns on. Off by default. The
first time a page that could use it shows, a small toast by the address bar suggests it (Turn On,
or decline). Declining or turning it on ends the suggestion for good; leaving it untouched lets it
come back on another site. While dark pages is applied to a page, a small indicator inside the
address field says so, and a tap turns it off or back on for that site. The app's own theme is
never touched. Earlier work: docs/research/dark-mode.md (the engine).

Marks: [V] read at the source, [S] secondary reporting, [M] measured here.

## 1. How it works today (before this change)

- **Always on while Plain is dark** (`FixedChoices.darkPagesOn = true`). No setting.
- **One user script per page** (`WebEngine/DarkPages.swift`, engine in `DarkPagesEngine.swift`),
  main frame, document start, Plain's content world. The pool bakes in the sites where the user
  turned it off (`OFF_SITES`) and swaps the script when that list changes.
- **When it runs:** only while `prefers-color-scheme: dark` matches (the web view follows the
  window's style, which follows Settings › Appearance). From document start a guard sheet holds the
  root at #181818 while the page is judged. The judgement runs in the first rendering update after
  the head's style sheets load (`ready()`), again at DOMContentLoaded and at load.
- **How it decides** (`judge()`): native when a `<meta name=color-scheme>` says dark or `only`, a
  readable `prefers-color-scheme: dark` rule exists (up to 20,000 rules), or a root
  `color-scheme` rule says dark/only (found while the twins are built). Otherwise it reads the
  root's (or body's) own background with the twins on: luminance ≥ 0.5 (about #BCBCBC), or no
  background at all, means darken.
- **What it reports:** `inactive` (light app, or not judged), `native`, `darkened`, `off` (site off).
  The page sheet offers "Turn Off / Turn On Dark Pages for This Site" in Site Settings
  (`ControlRules.darkPages`).
- **Per site:** `darkPagesOff` table (Storage), loaded after the first frame into
  `StorageSiteDarkPagesStore`; private tabs layer an in-memory copy over it.
- **Cost:** the judgement builds every style sheet's twin first (10–50 ms of script per page on
  real sites); a light app reads nothing.

## 2. Research

### What other browsers do

| Browser | Default | How it is offered | Per site | Notes |
|---|---|---|---|---|
| Safari iOS 26 / 27.2 | — | Nothing: pages without a dark theme stay light. [V] (WebKit blog below: the feature is new in 27.3) | — | Reader has its own themes. |
| Safari 27.3 Adaptive Dark Mode | off | "When enabled by a user, Safari adapts light websites" [V]; a **Try** button on bright pages in dark mode, then Page Menu › Adaptive Dark Mode per site, and Settings › Apps › Safari › Adaptive Dark Mode [S]. | page menu, per site [S] | [WebKit blog](https://webkit.org/blog/18541/introducing-adaptive-dark-mode/), [9to5Mac](https://9to5mac.com/2026/11/03/ios-27-3-and-macos-27-3-add-vertical-tabs-adaptive-dark-mode-and-more-to-safari/), [iOSHacker](https://ioshacker.com/how-to/use-adaptive-dark-mode-in-safari-on-iphone-running-ios-27-3) |
| Safari 27.3 flow, reported | — | After the first Try: "all sites" or "site by site"; previewing shows "Previewing Adaptive Dark Mode" with a check to accept [S] | page menu › Adaptive Dark Mode On/Off (iPhone); Settings › Websites (Mac) [S] | [iDownloadBlog](https://www.idownloadblog.com/?p=1063843), early report "inconsistent" [S] ([Gadget Hacks](https://apple.gadgethacks.com/news/safari-adaptive-dark-mode-how-safari-273-beta-works/)) |
| Noir (Safari extension, iOS/macOS) | follows system dark | extension menu from Safari; Shortcuts actions [S] | "Disable Noir on some websites" [V] | [getnoir.app](https://getnoir.app), [App Store](https://apps.apple.com/us/app/-/id1581140954) |
| Dark Reader (Safari) | on | toolbar popup, "Toggle site" [V] | site list, "Not invert listed" or "Invert listed only" [V] | [Dark Reader help](https://darkreader.org/help/en/) |
| Chrome desktop | off | `chrome://flags/#enable-force-dark` "Auto Dark Mode for Web Contents", experimental, no UI [S] | — | [Tom's Guide](https://www.tomsguide.com/computing/browsers/how-to-enable-auto-dark-mode-in-chrome) |
| Chrome Android | off (behind a flag) | Settings › Theme › "Apply Dark themes to sites, when possible" [V]; results "can vary and occasionally be a bit awkward" [V] | Site settings › "Auto-darken web content"; menu "Enable/Disable Auto-Dark for site" [S] | [Chrome blog](https://developer.chrome.com/blog/auto-dark-theme), [Computerworld](https://www.computerworld.com/article/3712240/android-dark-mode.html), [Winaero](https://winaero.com/chrome-for-android-allows-enabling-dark-theme-per-website) |
| Samsung Internet | on with dark mode [S] | global switch; developers report they cannot override it [S] | none found | [Samsung](https://developer.samsung.com/internet/blog/en/2020/12/15/dark-mode-in-samsung-internet), [forum](https://forum.developer.samsung.com/t/websites-dark-mode-gets-overridden-by-samsung-internets-dark-mode/22937) |
| Arc | off | Boosts › "Invert lightness", per site, hard to find, ignores OS dark [S] | per site (a Boost) | [Arc help](https://resources.arc.net/hc/en-us/articles/19212718608151-Boosts-Customize-Any-Website) |
| Orion | — | none built in; users add Dark Reader (white flash on load) [S] | requested | [Orion feedback](https://orionfeedback.org/d/2084-built-in-dark-mode-for-sites) |
| Opera GX / Android | off [S] | "Force dark pages" switch, all sites or a custom list [V]; Android "Dark web pages" [S] | right-click "Disable Force Dark Pages"; exceptions list [S] | [Opera GX](https://www.opera.com/gx/features/force-dark-pages), [forum](https://forums.opera.com/post/345891), [Technipages](https://www.technipages.com/opera-for-android-how-to-configure-dark-mode/) |

**Reading:** nobody but Safari 27.3 suggests it in context; everyone else hides it in a setting
or a flag, and every one that lets users choose keeps a per-site exception. Safari 27.3's own
shape (off, a Try on bright pages in dark mode, then a per-site switch in the page's menu) is the
owner's request almost exactly, which is a good sign it is the right shape for iOS.

### What breaks when a page is darkened

- **Pictures, logos, QR codes inverted:** Chrome 141's auto-dark inverted images, logos, icons
  and QR codes (a P0, then downgraded as experimental) [S]
  ([PiunikaWeb](https://piunikaweb.com/2025/10/10/chrome-141-breaks-auto-dark-mode-inverts-images/));
  Opera users report inverted images and wrong colors [S] ([forum](https://forums.opera.com/post/270783)).
  Plain never touches pictures except black-and-white logos after a pixel check (dark-mode.md §9).
- **Brand colors:** a filter flips them; Plain keeps hue and leaves dark and saturated brand
  backgrounds as made (dark-mode.md §9).
- **Text over pictures, small icons:** Samsung's forced dark struggles with both, and its image
  classifier adds delay [V] ([Samsung](https://developer.samsung.com/internet/blog/en/2020/12/15/dark-mode-in-samsung-internet)).
- **Canvas, maps, video:** Safari leaves canvas alone and may drop masks and blend effects [V]
  (WebKit blog). Map tiles are pictures or canvas, so they stay light on a dark page: correct,
  but bright. No map- or video-specific reports found.
- **Low contrast:** the owner's apple.com report (white text on a section turned light by the
  old root filter) is the classic case; fixed by role-based darkening and the 4.5:1 pass
  (dark-mode.md §9). Dark Reader's filter mode also loses subpixel text and lags on big pages [V].
- **Why opt-in:** every engine, Safari's included, gets some pages wrong ("inconsistent" in
  27.3 beta [S]). A user who chose it forgives a broken page and knows where the switch is; a
  user who never chose it sees a broken site and blames the browser.

### Suggesting a feature: timing and form

- **NN/g, "Onboarding Tutorials vs. Contextual Help"** (2023): help shown when the user needs
  it beats help pushed out of context; "Make it easy to dismiss (and recall) the help content";
  don't repeat it within a session [V] ([NN/g](https://www.nngroup.com/articles/onboarding-tutorials/)).
- **NN/g, coach marks on mobile:** one hint at a time, at the right moment, short text [S]
  ([NN/g](https://www.nngroup.com/articles/mobile-instructional-overlay/)). Passive
  notifications should be unobtrusive and never carry the only copy of key information [S]
  ([NN/g](https://www.nngroup.com/articles/indicators-validations-notifications/)).
- **Apple HIG, "Offering help":** tie help to what people are doing right now; make it easy to
  dismiss; one or two sentences, never promotional; eligibility rules so people who already used
  the feature don't see it; a display frequency, "for example, once every 24 hours" [V]
  ([HIG](https://developer.apple.com/design/human-interface-guidelines/offering-help)).
- **TipKit:** `DisplayFrequency` (hourly, daily…), `MaxDisplayCount`, and invalidation on
  `actionPerformed` or `tipClosed`, both permanent [V]
  ([MaxDisplayCount](https://developer.apple.com/documentation/tipkit/tips/maxdisplaycount),
  [InvalidationReason](https://developer.apple.com/documentation/tipkit/tips/invalidationreason)).
- **What Plain takes:** at the moment of relevance (a light page, in dark colors, loaded and
  still), never during a load or while typing, non-modal, one tap to decline, final once answered
  (TipKit's `tipClosed` / `actionPerformed`), a frequency gap and a display cap for the unanswered
  case. Plain's own rule already says one quiet toast the first time a feature applies
  (ui-reference: Translate's "This page is in French").

### Showing an "on" state inside a text field

- **Safari:** Reader's icon in the field is highlighted while Reader is on, and a tap on it
  opens its settings [S] ([MacRumors](https://www.macrumors.com/how-to/use-new-reader-mode-ios-safari));
  a Translate icon shows in the field while a page is translated, and "View Original" is behind
  it [S] ([MacRumors](https://www.macrumors.com/how-to/safari-webpage-translation-ios/)). The
  pattern: a small glyph at the field's leading side, tinted while its mode is on, gone when it
  doesn't apply.
- **Apple's dark mode glyph:** `circle.lefthalf.filled` is the Dark Mode control in Control
  Center and the Display settings; Safari 27.3's per-site control is in the page menu.
- **Plain takes:** one glyph, inside the field, at its leading edge; accent while on; dimmed
  while the user has it off on this site (so the way back is in the same place); absent
  otherwise. It is never the only way: Site Settings has the same switch.

## 3. Plan (revised after the Codex plan review, §4)

### State model

Three separate things, each with one owner:

1. **Preference** (what the user chose).
   - **The switch**, `BrowserSettings.darkPages` (Settings › Appearance › Dark Pages). Fresh
     state: **off** (`FixedChoices.darkPagesDefaultEnabled`).
   - **Per-site choice**, `DarkPagesSiteChoice`: `automatic` (follow the switch), `on`, `off`.
     Made only by hand (the indicator, Site Settings), remembered automatically. A site's choice
     beats the switch; the switch is "darken sites automatically", the site choice an exception
     either way. Choices are never cleared by the switch: a site the user turned off stays off
     (they found it broken), a site turned on stays on.
   - **Policy**: applies = `on`, or `automatic` while the switch is on (`DarkPagesChoices.applies`).
   - Owner: `DarkPagesPreferences` (ShellUI, app-wide), which holds the switch and the site
     lists in memory, persists them in order, and keeps a **launch copy of all of it** (switch
     and both site lists) in user defaults, so the engine has the complete policy at document
     start, before the database opens: a restored tab never darkens a site the user excluded.
     The database stays the store of record; its read at launch only reconciles. Private tabs
     layer an in-memory overlay (site choices only) that the private session drops at its end.
   - Every writer (Settings, the toast, the indicator, Site Settings) goes through it; a change
     has a revision number, and a database read older than the newest change is dropped.
2. **Eligibility** (what the page is), from the engine: `unknown` (not checked yet), `native`
   (dark design of its own, or not a page Plain darkens), `eligible` (light, no dark design).
3. **Rendering** (what the page shows), reported by the engine for the current document only:
   - `inactive`: light colors, or not judged yet.
   - `native`: the page's own design.
   - `darkened`: the engine applied it and the page's first darkened frame was written.
   - `off`: eligible, not applied, and the site's choice is `off`.
   - `available`: eligible, not applied, the site is `automatic` and the switch is off.

| Colors | Policy | Eligibility | State | Indicator | Site Settings item | Suggestion |
|---|---|---|---|---|---|---|
| light | any | — (never read) | inactive | — | — | — |
| dark | applies | unknown | inactive (guard on) | — | — | — |
| dark | applies | native | native | — | — | — |
| dark | applies | eligible | darkened | on | Dark Pages ✓ | — |
| dark | not (site off) | eligible | off | off | Dark Pages | — |
| dark | not (switch off, automatic) | eligible | available | — | Dark Pages | may show |
| dark | not | native / unknown | native / inactive | — | — | — |

**The suggestion**, `DarkPagesSuggestion` (BrowserCore, kept in user defaults, not a setting, kept
through Clear History and Data):

- `neverAsked` → shown → `ignored(site, session)` (recorded the moment it shows, so a toast that
  is never answered counts as ignored: auto-dismissed, hidden by a layout change, the app killed).
- Turn On → `accepted`; No Thanks → `declined`. Both final.
- The switch turned on in Settings → `accepted`. A per-site choice made by hand in a regular tab →
  `accepted` (the user found the feature). In a private tab it changes nothing app-wide.
- After `ignored`, it may show again on the **next eligible page of another site, in a later
  session** (the app came back from the background, or relaunched). No time gap and no cap: only
  an answer ends it, as the owner asked. "Next time" is read as the next time the user opens
  Plain: NN/g warns against help repeated within a session, and three light sites in a minute
  would otherwise mean three toasts.

### When a page "could use it"

1. **Plain is dark** (`prefers-color-scheme: dark` in the web view, which follows the window:
   Settings › Appearance, or iOS under System). In light colors nothing is read and nothing shows.
2. **A real page:** http(s), main frame, an HTML document (`document.contentType` is `text/html`
   or XHTML: not an image or PDF, which WebKit shows in its own viewer), loaded, not an error page,
   not the start screen, not under the reader (the shell's rules hide everything there).
3. **No dark design of its own:** a `color-scheme` meta with dark or `only`, the root's computed
   `color-scheme` with dark or `only`, or a readable `prefers-color-scheme: dark` rule.
4. **Mostly light:** the root's (or body's) own background is light (luminance ≥ 0.5, or none),
   **and** a small sample of what shows (5 points: the center and the four quarter points of the
   viewport, each the first opaque background up its ancestors) is mostly light (≥ 3 of 5).
   The sample is in the light check only, so the check is stricter than the darkening's own
   judgement: anything it calls eligible, the darkening darkens.
5. **Private tabs:** dark pages applies in private tabs (darkening stores nothing); their site
   choices last for the private session. The suggestion never shows in a private tab: the answer
   is app-wide and remembered, and a private session should not teach Plain anything.

**The light check** runs only when dark pages does not apply to the page (the default now):
after the `load` event (at once if the document already loaded) plus
`FixedChoices.darkPagesCheckDelay` (250 ms), only while the document is visible (a background
tab waits for `visibilitychange`), in slices of at most `FixedChoices.darkPagesCheckSlice`
(4 ms) with the rule scan resumable, cancelled by any change of choice. No guard, no twins, no
sheet of Plain's: a page dark pages doesn't apply to renders exactly as the site made it. It runs
again on a back-forward-cache restore, when the colors switch to dark, and when the shell asks
after a same-document address change (single-page apps).

### The indicator

- **Glyph:** `circle.lefthalf.filled`, Apple's symbol for Dark Mode (Control Center, Display &
  Brightness). Not `moon`: on iOS the moon is Focus and Sleep.
- **Where:** inside the resting pill at its leading edge, a 44 × 44 pt button, glyph at the
  `subheadline` text style, capped with the host at XXXL. The host stays centered; its centering
  is a high, not required, priority, so a long host gives way rather than running under the glyph.
  The button's own tap wins over the pill's tap (UIKit gives a control's action precedence over
  an ancestor's tap recognizer); a long press on it still opens the page sheet, like the pill.
- **On** (`darkened`): the glyph in the accent on glass (Lagoon), as Safari tints Reader's icon
  while Reader is on.
- **Off** (`off`): the same glyph in the primary ink, like Safari's untinted Reader icon: a working
  control that is off, not a disabled one (Codex: dimmed reads as unavailable). It appears only on
  a site the user turned off by hand, on a page that could use it, so the way back is where the
  user left it.
- **Hidden** everywhere else (table above), while editing, during a bar swipe between tabs, and in
  the collapsed pill.
- **Tap:** the site's choice flips (applied → `off`; not applied → `automatic` when the switch is
  on, `on` when it is off), `Haptic.selection`, and the page crossfades (below). Remembered.
- **VoiceOver:** a button "Dark Pages", value "On" / "Off", hint "Turns Dark Pages off for this
  site." / "…on for this site." The pill stays one "Address" button beside it, through a proxy
  element with the same identifier, label, value, hint and actions; the indicator comes first.
- **Lead word:** the indicator is a glyph, never a word, so it never competes with the quiet lead
  word ("Not Secure —", "Private", "Translated"): `◐  Not Secure — example.com`. Never with
  Reader (hidden under the reader).
- **Space:** iPhone 13 mini and the Duo's outer screen (pill ≈ 290 pt beside More): 44 pt at the
  leading edge, a long host truncates at its head as before; checked at the largest
  non-accessibility text size. Duo inner top bar (pill up to 560 pt): the same slot.

### The crossfade

For any user change on the page on screen (indicator, Site Settings item, toast): a snapshot of
each visible pane showing that site (`snapshotView(afterScreenUpdates: false)`) goes over its web
view; the engine is told; when the engine answers for **that document** (a token per document)
that its first frame is written and two animation frames have passed, the snapshot fades out
over `FixedChoices.darkPagesCrossfade` (0.25 s). A navigation, a tab switch, a second tap or a
layout change removes the snapshot at once; no answer within 0.6 s fades it anyway; no snapshot
(capture failed) means no crossfade. Reduce Motion: the same crossfade (it is a fade).
Background tabs: no snapshot.

### The suggestion

A small card, not the one-line toast: it asks a question with two answers, so it has a title,
one sentence and two worded buttons, like a TipKit tip.

```
◐  Dark Pages
   Darken websites that have no dark mode of their own?
                                    No Thanks    Turn On
```

- **Where:** **above** the pill on phones and the Duo's outer screen (bottom bar); **under** the
  top bar on the Duo's inner screen and iPad. Centered on the pill, as wide as the pill (capped at
  420 pt), glass like the toast, corner radius 22. Text wraps; the card grows with the text size.
- **Copy:** title "Dark Pages" (the name the user will find in Settings), message "Darken websites
  that have no dark mode of their own?", buttons **No Thanks** and **Turn On** (accent). The
  message says what Turn On does everywhere, not just here, because Turn On is the switch.
  VoiceOver announces "Dark Pages. Darken websites that have no dark mode of their own?" and
  focus moves to the card.
- **When:** the page was checked `available`, then `FixedChoices.darkPagesSuggestionDelay` (2 s)
  later, if still: the same tab and document on screen, `available`, the settings read, the bar
  fully showing, keyboard down, no sheet, gallery, menu, reader or other toast up, a regular tab,
  and `DarkPagesSuggestion` allows it. Any miss: not for this page load (no queue).
- **While up** it is hidden (and stays ignored) on a navigation, a tab or pane-focus change, a
  sheet or gallery opening, the keyboard, the reader, the bar collapsing, a layout change (fold,
  rotate), the app leaving the foreground, or another toast. It never blocks: the page scrolls
  and takes taps around it.
- **Stays** `FixedChoices.darkPagesSuggestionDuration` (8 s; twice the 4 s toast: it asks
  something). While VoiceOver is running it stays until answered or the page changes.
- **Turn On:** the switch goes on (`accepted`); the page crossfades dark; the indicator appears.
  Other tabs on screen follow at once; tabs off screen get it when they come on screen.
- **No Thanks:** `declined`. Dark Pages can still be turned on in Settings › Appearance › Dark
  Pages, and per site in Site Settings.
- **Untouched:** leaves after 8 s; ignored.

### The page sheet

Site Settings gets a **"Dark Pages"** checkmark item (checked = applied) on `darkened`, `off` and
`available` pages; hidden elsewhere (light colors, own dark design, error pages, under the
reader). A tap is the indicator's toggle (same rule, haptic, crossfade). This follows the clarity
lane's checkmark naming for Site Settings.

### Settings

Settings › Appearance keeps its picker; a **Dark Pages** switch follows in its own section,
footer "Darkens websites that have no dark mode of their own, while Plain is dark. Choices you
make for a site stay." With Appearance on Light the switch is disabled (keeping its value) and the
footer says "Plain is set to Light. Dark Pages works while Plain is dark." The Appearance footer
no longer promises darkened pages. Turning the switch on counts as `accepted`. Nothing here
changes the app's colors.

### Migration

- **Fresh install:** off, `neverAsked`.
- **Upgraders:** dark pages was on for everyone for two TestFlight days, never by choice. They
  start **off and `neverAsked`**: the owner's default holds for every user, and the suggestion is
  exactly how an upgrader learns that the default changed; one tap restores yesterday. Sites they
  turned off stay off (`darkPagesOff` kept), so turning it on never re-breaks a site they fixed.
  Codex suggested keeping it on for users who had excluded a site; rejected: they never chose
  "on", and the suggestion would never reach the people the change is for.
- Versioned: a settings key `darkPages` absent means "never set" and reads as the default once;
  every later save writes it, so a later upgrade never resets a choice. One new table
  (`v11.darkPagesOn`).

### The app's own theme

Untouched. Appearance (System / Light / Dark) decides the app's and the web views' color scheme,
as today. Dark Pages only decides whether light-only pages are darkened inside it.

### Edge cases

- **Redirects, reloads, back:** each document has its own token; the shell takes state only for
  the current document and drops a report from another. The indicator hides until the new
  document is judged.
- **Single-page apps:** a same-document address change asks the engine to check again (the
  darkened path already watches sheets); a pending suggestion is cancelled.
- **Back-forward cache:** on restore the page reports again and the shell reconciles its choice.
- **Iframes:** same-origin frames follow the top page; they ask for the engine (and hold a dark
  guard) only while it applies to the top page (`framesWanted`); a change of choice reaches them
  through the top page. Other origins stay as made. Only the main frame reports.
- **Partial dark** (a dark hero on a light page): the root and the sample decide; a mostly dark
  sample means native (no suggestion), as the darkening would leave most of it anyway.
- **Fold / unfold, rotate:** the pill keeps its state; the suggestion is hidden (ignored).
- **Split panes with two sites:** the pill shows the focused pane; the suggestion is only for the
  focused pane's tab and is hidden when focus moves; a tap acts on the focused pane's site, and
  both panes crossfade when both show it.
- **Background tabs:** never suggest, never check while hidden; they take a changed choice when
  they come on screen (the pool keeps a policy revision per web view).
- **Relaunch:** the launch copy gives the engine the full policy before the database opens.
- **Profiles:** the switch and the suggestion are app-wide (a preference about reading, like
  Appearance); site choices are shared across profiles, as today's off list is: a site that
  breaks darkened breaks in every profile.
- **Light ↔ dark live:** the engine follows `prefers-color-scheme` as today; the indicator follows;
  a suggestion up when the app turns light is hidden.

### Performance

- **Launch:** one defaults read for the launch copy, beside `PlainAppearance`'s; the script built
  once, as today.
- **Pages dark pages doesn't apply to (the new default):** no guard, no twins, no restyle; one
  sliced check after load, only in dark colors, only while visible. Cheaper than today.
- **Applied pages:** today's engine, unchanged; the heavy darkened scroll metric must hold.
- **A change of choice:** future scripts rebuilt once; visible panes told at once; hidden tabs
  when they come on screen. Rapid changes coalesce to the newest.
- **Crossfade:** a snapshot view and one alpha animation; no reload.
- **Signposts:** `page.darkPages` (toggle, with the source), `page.darkPagesCrossfade`
  (interval), `page.darkPagesSuggestion` (shown, accepted, declined, ignored).
- The perf tests that measure the darkened page turn Dark Pages on in Settings first.

### Cross-lane coordination

- **Clarity lane** (Site Settings as checkmark items): "Dark Pages" ships as a checkmark item
  here; their rename of the other items keeps it.
- **Pill lead words** (Private, Reader, Translated): the indicator is its own view at the glass's
  leading edge; the lead word stays in the host label. Whoever lands second rebases.
- **Duo inner top glass:** the indicator lives inside `AddressPill`; the suggestion's
  under-the-bar placement is its own constraint.
- **Haptics lane:** `Haptic.selection` on the indicator and the Site Settings item, matching the
  plan's Site Settings row.

## 4. Plan review (Codex, round 1)

22 findings, 19 blocking. Taken: no gap or cap (only an answer ends it; once per session
instead, from NN/g); site choices never cleared by the switch; a complete state table; one owner
with revisions for every writer; the full policy in the launch copy; document tokens; continuous
validity for the suggestion; sliced, visible-only checks; the sample for "mostly light"; frames
gated on the policy; private choices kept private; a 44 pt target; the off state in primary ink;
worded buttons in a card; a bounded, cancellable crossfade; lazy reconcile of hidden tabs;
versioned migration; the Appearance footer. Not taken: keeping dark pages on for upgraders who
had excluded a site (see Migration); profile-scoped site choices (kept shared, as today).

## 5. Implementation (2026-11-27)

- **BrowserCore:** `DarkPagesChoices` (switch plus on/off sites, off wins a conflict),
  `DarkPagesSiteChoice`, `DarkPagesSuggestion` with `Moment` and `DarkPagesSuggestionStore`
  (user defaults, with a session counter that survives relaunch); `ControlRules.darkPages`
  (checkmark item) and `ControlRules.darkPagesIndicator`. Tests: `DarkPagesRulesTests`.
- **Storage:** `BrowserSettings.darkPages` (key absent reads as off), table `darkPagesOn`
  (`v11.darkPagesOn`), `darkPagesSiteChoices()` and `setDarkPagesChoice(_:forSite:)` in one
  transaction.
- **WebEngine:** the script carries `ENABLED`, `ON_SITES`, `OFF_SITES`; a page dark pages doesn't
  apply to gets no guard and no twins, only the resumable light check (`lightCheck`: meta, root
  `color-scheme` and background, five samples with one style read per step, then the dark-rule
  scan), in 4 ms slices while visible, cancelled by any change of choice or colors, run again on a
  back-forward restore and on a same-document address change. `setChoice(applies, siteOff)`
  answers after two frames with the document's token. The pool applies a change to the panes on
  screen at once (each in parallel, a later caller waits for the same answers), catches up hidden
  tabs as they attach (a revision per web view), and drops reports from a document that left.
- **ShellUI:** `StorageSiteDarkPagesStore` owns the policy with a property-list launch copy;
  every window's pool observes it. `AddressPill` has the indicator and a VoiceOver stand-in for
  the address button. `DarkPagesSuggestionView` is the card. `BrowserViewController+DarkPages`
  holds the switch, the toggle, the crossfade and the suggestion's moment and validity.
  The suggestion's Turn On goes through `FeatureSheets.setDarkPages`, the Settings model's own
  write queue, which now saves each change over what is stored (field by field), so another
  window's open Settings never writes an old switch back.
- **Codex code review:** round 1, 9 blocking, all fixed; round 2, 4 blocking, all fixed (see
  above). Not changed: same-site stale reports (one process delivers in order; the commit resets
  the state before the new page's first report).
