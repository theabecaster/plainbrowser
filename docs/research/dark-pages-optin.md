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

## 3. Plan

### State model

- **`darkPagesEnabled`**, the global switch: a stored setting (`BrowserSettings.darkPages`,
  Settings › Appearance › Dark Pages). Fresh state: **off** (`FixedChoices.darkPagesDefaultEnabled`).
  The engine needs it at document start, before the database opens, so the dark-pages store keeps
  a launch copy in user defaults (`PlainDarkPages`, like `PlainAppearance`); the database value
  replaces it as soon as it is read.
- **Per-site choice** (`DarkPagesSiteChoice`): `automatic` (follow the switch), `on`, `off`.
  Remembered automatically when the user acts on a site (the indicator or Site Settings).
  Stored as two tables, `darkPagesOff` (kept as is, so upgraders keep the sites they turned off)
  and a new `darkPagesOn`. Private tabs keep theirs in memory, over the regular ones.
  - Applied = `on`, or `automatic` while the switch is on.
  - Flipping the switch (Settings or the toast) clears every `on` site: with the switch on they
    are redundant, and the switch turned off must mean off. `off` sites stay: they are the sites
    the user found broken.
  - A tap on the indicator (or the Site Settings item): applied → `off`; not applied → `automatic`
    when the switch is on, `on` when it is off.
- **Suggestion** (`DarkPagesSuggestion`, user defaults, not a setting): `neverAsked`,
  `ignored(times, site, lastShown)`, `declined`, `accepted`.
  - Shown → `ignored(times + 1, site, now)` at the moment it shows, so a toast that is never
    answered (auto-dismissed, replaced by another toast, the app killed) counts as ignored.
  - Turn On → `accepted`. ✕ → `declined`. Both final.
  - The switch turned on anywhere, or any per-site choice made by hand → `accepted` (the user
    knows the feature; a suggestion would be noise).
  - May show again after `ignored` only on **another site**, **at least
    `FixedChoices.darkPagesSuggestionGap` (30 min) later**, and **at most
    `FixedChoices.darkPagesSuggestionMaxShows` (3) times** in all. The gap is the "next time" the
    owner asked for: without it, a user reading three light sites in a minute would see three
    toasts. The cap: three passes on a toast is an answer (TipKit's display-count rule, below).

### When a page "could use it" (eligible)

All of these hold, checked by the engine and the state rules together:

1. **Plain is dark** (`prefers-color-scheme: dark` in the web view, which follows the window's
   style: Settings › Appearance, or iOS under System). In light colors nothing runs, nothing is
   read and no suggestion shows.
2. **A real page:** http(s), an HTML document (`document.contentType` is `text/html` or XHTML:
   not an image or PDF document, where WebKit draws its own viewer), main frame, loaded, not an
   error page (Plain's own view over the page), not the start screen, not under the reader.
3. **No dark theme of its own:** the same checks as today (meta, readable dark rules, root
   `color-scheme` from the computed style).
4. **Mostly light:** the root's (or body's) own background luminance ≥ 0.5, or none (the white
   canvas).
5. **Private tabs:** dark pages *applies* in private tabs (darkening stores nothing), with choices
   kept for the private session only. The *suggestion* never shows in a private tab: the answer
   is app-wide and remembered, and a private session should not teach Plain anything or ask
   anything; the site it would remember is browsing data.

**Detection is cheap and late when dark pages is not applied.** Today's judgement builds the
twins first (10–50 ms). For a page where dark pages is not applied (switch off, or the site off),
the engine instead runs a light check after the page's `load` event plus
`FixedChoices.darkPagesCheckDelay` (250 ms): the meta, the dark-rule scan (same 20,000 cap), the
root's computed `color-scheme` and background. No guard, no twins, no style sheet of Plain's: a
page with dark pages off renders exactly as the site made it. It reports `available` (eligible,
the switch is off and the site is automatic), `off` (eligible, the user turned it off here), or
`native`. Applied pages keep today's path (guard from document start, judged before first paint).

New page states (`DarkPagesState`): `inactive`, `native`, `darkened`, `off`, **`available`**.

### The indicator

- **Glyph:** `circle.lefthalf.filled`, Apple's own symbol for Dark Mode (Control Center's Dark
  Mode control and Settings › Display & Brightness use it) [S]. Not `moon`: on iOS the moon is
  Focus and Sleep, and it would read as Do Not Disturb.
- **Where:** inside the resting pill at its leading edge (Spacing.xs in), in a 36 × 44 pt tap
  area, the glyph at the subheadline text style, scaled with Dynamic Type up to the pill's cap.
  The host stays centered; it gives way to the right only when it would otherwise run under the
  glyph (its centering is a high, not required, priority).
- **When:**
  - **On** (`darkened`): the glyph in the accent on glass (Lagoon), like Safari's Reader icon when
    Reader is on.
  - **Off** (`off`: the user turned it off on this site and the page could use it): the same glyph
    in the secondary ink, dimmed. It stays so the way back is where the user left it; without it
    the control would vanish with no way back except a menu two levels down. The glyph stays the
    same so it reads as the same control, now off.
  - **Hidden** everywhere else: light colors, a page with its own dark theme, `available` (the
    switch is off and the user never chose for this site: the feature is not being applied),
    loading a new page before it is judged, error pages, the start screen, the reader, while
    editing, and in the collapsed pill (taps only, and too small).
- **Tap:** toggles the site (`DarkPagesSiteChoice` rule above), plays `Haptic.selection` (haptics
  plan §2: a state changed in place), and crossfades the page: a snapshot of the web view goes
  over it, the engine switches, the snapshot fades out over 0.25 s once two frames have rendered.
  No reload. Remembered for the site.
- **VoiceOver:** a button "Dark Pages", value "On" / "Off", hint "Double-tap to turn off for this
  site" / "…turn on for this site". The resting pill stays one button ("Address") beside it; the
  indicator comes first, matching what is seen.
- **The lead word:** the indicator is a glyph, never a word, so it never competes with the pill's
  quiet lead word ("Not Secure —", "Private", "Translated"): the line reads
  `◐  Not Secure — example.com`. Reader never shows with the indicator (hidden under the reader).
- **Space** (narrowest first):
  - iPhone 13 mini (pill ≈ 290 pt beside More): the glyph takes 36 pt at the leading edge; a long
    host truncates at its head as before. Checked at the largest non-accessibility text size.
  - Duo outer screen: as the mini.
  - Duo inner screen top bar (pill up to 560 pt): the same leading slot; plenty of room.
  - Accessibility text sizes: the pill's host stops growing at XXXL (`maximumContentSizeCategory`),
    and so does the glyph.

### The suggestion toast

- **Where:** next to the address bar, on the side away from the screen edge: **above** the pill
  on phones and the Duo's outer screen (bottom bar), **under** the top bar on the Duo's inner
  screen and iPad. The other toasts keep their places; this one points at the field where the
  indicator will appear.
- **Copy:** `Darken light pages?` · **Turn On** · ✕ (VoiceOver "No Thanks").
  - "Darken light pages?" says what Turn On does everywhere, not just here (Turn On is the
    switch, so "this site" would be untrue), in 19 characters, which fits the 13 mini's toast at
    the default text size with both buttons.
  - "Turn On" is iOS's verb for a switch (and Settings shows "Dark Pages" on after it).
  - ✕ is a full-size tap target; it is the decline, and says "No Thanks" to VoiceOver.
  - VoiceOver announcement: "Dark Pages. Darken light pages that have no dark mode of their own?"
- **Timing:**
  - Only after the page has loaded and been checked (`available`), and then
    `FixedChoices.darkPagesSuggestionDelay` (2 s) later, so it never shows during a load.
  - Checked again at that moment: the same tab is on screen with the same address, still
    `available`, the bar is showing (not collapsed or hidden), the keyboard is down, no sheet,
    gallery, menu or reader is up, no other toast is showing (it never replaces one), not
    private, and `DarkPagesSuggestion` allows it. Any miss: it does not show for this page load
    (no queueing for later; the next eligible page gets the next chance).
  - At most once per page load; in practice, at most once per 30 minutes.
  - Stays `FixedChoices.darkPagesSuggestionDuration` (8 s), twice the usual 4 s: it asks a question.
  - Never blocks: the page scrolls and takes taps under and around it; scrolling does not dismiss it.
- **Turn On:** the switch goes on (saved like Settings), `accepted`; the page crossfades to dark
  and the indicator appears (on). Other open tabs follow at once, without a reload.
- **✕ (No Thanks):** `declined`. The page stays as it is. Dark Pages can still be turned on in
  Settings › Appearance › Dark Pages, and per site in the page sheet's Site Settings.
- **Untouched:** it leaves after 8 s and counts as ignored.

### The page sheet

Site Settings gets a **"Dark Pages"** checkmark item (checked = applied here) on pages that are
`darkened`, `off` or `available`. Hidden in light colors, on pages with their own dark design, on
error pages and under the reader. A tap is the indicator's toggle (same rule, haptic, crossfade).
This is the clarity lane's naming for Site Settings (checkmark items), done here for this item.

### Settings

Settings › Appearance gains a **Dark Pages** switch in its own section right after Appearance,
footer: "Darkens websites that have no dark mode of their own, while Plain is dark." When
Appearance is Light, the switch is disabled (keeping its value) and the footer says "Plain is set
to Light. Dark Pages works while Plain is dark." (ui-reference: a row that doesn't apply stays,
disabled, and says why). Turning it on counts as `accepted`. It never changes the app's colors.

### Migration

- **Fresh install:** off, `neverAsked`.
- **Upgraders:** dark pages was on for everyone for a few TestFlight builds (since 2026-11-26),
  never by a choice the user made. They start **off and `neverAsked`**, like everyone, so the
  owner's rule (off by default, offered once) holds for every user, and the suggestion is the way
  back: the first light page in dark mode asks, one tap restores yesterday's behavior. Keeping it
  on would make the toast never appear for exactly the people the change is for, and would keep a
  default the owner removed. Sites they turned off stay off (`darkPagesOff` is kept), so
  turning it on again never re-breaks a site they fixed.
- No database migration of rows; one new table (`v11.darkPagesOn`) and one settings key.

### The app's own theme

Untouched. Settings › Appearance (System / Light / Dark) decides only the app's and the web
views' color scheme, as today. Dark Pages only decides whether light-only pages get darkened
inside that.

### Edge cases

- **Redirects:** the state belongs to the committed page; a redirect commits a new page and the
  indicator hides until it is judged. The toast's check compares the address at show time.
- **Single-page apps:** a same-document URL change keeps the page's state (the engine keeps
  watching sheets as today). The toast's check uses the address seen when the state arrived; a
  pushState change before the delay cancels it.
- **Iframes:** same-origin frames follow the top page (as today); other origins stay as made. A
  frame never reports state; only the main frame decides the indicator and the toast.
- **Partial dark** (a dark hero on a light page): judged by the root background, as today.
- **Fold / unfold, rotate:** the pill keeps its state; the toast is hidden on a layout change (it
  would point at the wrong place).
- **Split panes with two sites:** the pill shows the focused pane's state; the toast is only for
  the focused pane's tab; a tap acts on the focused pane's site (both panes crossfade if both show
  that site).
- **Background tabs:** never suggest; they follow choice changes at once (each live web view
  gets the new choice), and their state is right when they come on screen.
- **Restore after relaunch:** the launch copy gives the engine the switch before the database
  opens; per-site lists arrive after the first frame and are applied without a reload (as today).
- **Profiles:** the switch and the suggestion are app-wide (a preference about how the user reads,
  like Appearance); per-site choices are shared too (a site that breaks breaks in every profile),
  as today's off list is.
- **App light ↔ dark live:** the engine follows `prefers-color-scheme` live as today; the
  indicator follows the new state; a toast up while the app turns light is hidden.

### Performance

- **Launch:** no new work: one more defaults read (`PlainDarkPages`) beside `PlainAppearance`'s,
  the script built once as today.
- **Pages with dark pages not applied** (the new default): no guard, no twins, no restyle; one
  light check after load (bounded rule scan, one computed style read) in the web content process.
  Cheaper than today for every page, since nothing is rewritten.
- **Applied pages:** today's engine, unchanged. The heavy darkened scroll metric must hold.
- **Crossfade:** a snapshot view (`snapshotView(afterScreenUpdates: false)`), no reload, one
  0.25 s alpha animation. The engine's switch runs in the web content process.
- **Signposts:** `page.darkPages` (toggle, with the reason: indicator, menu, toast, settings),
  `page.darkPagesCrossfade` (interval), `page.darkPagesSuggestion` (shown, accepted, declined,
  ignored).
- Perf tests that measure the darkened page turn Dark Pages on in Settings first.

### Cross-lane coordination

- **Clarity lane** (Site Settings as checkmark items): this lane ships "Dark Pages" as a
  checkmark item now; the clarity lane's rename of the other items keeps it.
- **Pill lead words** (Private, Reader, Translated): the indicator is a separate glyph view at the
  leading edge of the glass; the lead word stays in the host label. Whoever lands second rebases;
  nothing shares a line.
- **Duo inner top glass:** the indicator lives inside `AddressPill`, so it rides any change to the
  top bar's glass; the toast's under-the-bar constraint is new and separate.
- **Haptics lane:** `Haptic.selection` on the indicator and the Site Settings item, matching the
  plan's Site Settings row.
