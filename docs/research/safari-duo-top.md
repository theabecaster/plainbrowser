# Safari's top bar on the Duo's inner screen, frame by frame

Measured 2026-11-27 from the owner's screen recording of Safari 27 on the iPhone Duo's inner
screen (landscape, 2854x2008 px at 3x: 951x669 pt; the file is stored portrait with a -90°
rotation; 10.8 s, variable frame rate, about 47 fps on average). Frames were cut at 3, 30 and
120 fps around each transition. Points are pixels / 3. Page: apple.com, whose global nav is
sticky. Three tabs open.

Owner, on Plain's build with the page under floating controls: "I don't want to copy Safari
exactly — I like our style, those floating controls — but now the top of pages goes under the
text field … I like that Safari leaves the URL text field there in a smaller version, with just
the shrunken base URL, and that sets a boundary there. And I like that they use glass for the
background bar."

## Expanded (at rest, and after a reveal)

| What | Measured |
|---|---|
| Band | Full width, 0 to 132 pt. One glass surface: the page under it shows blurred (the confetti and headings read as soft shapes), tinted a neutral mid-grey that leans toward the page's color under it. No hairline at its bottom; the page's own edge is the boundary. |
| Row | 24 to 71 pt: Back and Sidebar (two 47 pt round glass buttons), the address field 281 to 641 pt (360 pt wide, centered on the row, not on the screen), New Tab and Tabs in one capsule. |
| Status items | On the row, at its trailing end (x 780 to 928): mute, time, Wi-Fi, battery ring, the camera. The row's controls stop before them. |
| Strip | 85 to 119 pt (34 pt), three tabs sharing the width, the focused one a lifted capsule with its close button. |
| Page | Starts at the band's bottom (132 pt): the sticky nav sits right under it, never under a control. |

## Collapsed (reading)

| What | Measured |
|---|---|
| Band | Full width, 0 to 45 pt, the same glass. The page scrolls under it and shows blurred; its tint takes on the page's color (navy over the navy hero, near black over the dark nav) within about 0.2 s of arriving. |
| Host | "apple.com" only (no path, no "www."), in its own small glass capsule 75x23 pt at x 438 to 513, y 15 to 38: centered on the screen (475.5), text about 12 to 13 pt, semibold, white over the dark band. |
| Status items | Hidden: they fade out over about 0.2 s after the band has collapsed, and back in on expand. Safari takes the status row for the slim band. |
| Page | Its sticky nav sits at 45 pt, right under the band: the page's top boundary is the band's bottom edge in both states. |

## Transitions

- **Collapse:** starts as the page scrolls down. Captured at 120 fps (duplicates mark frames the
  screen did not change): the controls shrink toward the row's center (about 0.9) and fade to
  about 60% in one step, then the next drawn frame is the collapsed band with the host. The band's
  height, the controls and the page's sticky nav move together: Safari moves the page's top inset
  with the band (the nav goes from 132 to 45 pt in the same frames). About 0.1 s for the bar; the
  status items then fade out over about 0.2 s, and the band's tint settles on the page's color
  over the next 0.15 s.
- **Expand:** on a scroll up (it waits for about 0.2 s of upward travel: small moves up leave it
  collapsed) or a fling up. The host's capsule widens (one frame), the controls appear at about
  0.9 scale and 30% opacity, then whole (three frames, about 0.1 s), the band grows to 132 pt and
  the page's nav moves down with it. The status items fade in over the next 0.15 s, and the band's
  tint returns to its neutral grey over about 0.2 s.
- No transition is tied to the finger: each is a short animation once a threshold is passed.
- **Tap target:** the recording has no tap on the band. Safari on iPhone and iPad brings the bar
  back from a tap on the collapsed address [I].

## What Plain takes, and what it keeps

| Safari | Plain (docs/decisions.md, "Duo inner screen: a glass band with the host while reading") |
|---|---|
| A glass band behind the whole bar | Taken: one band of Liquid Glass (`TopBand`), the pages' width, behind the floating capsules, which stay Plain's (owner: "I like our style, those floating controls"). |
| Slim band with the host while reading | Taken: the band's bottom rises to the status row's (73 to 74 pt), the pill's text shrinks into the host ("apple.com": the host without "www.", never cut to a guessed registrable domain) on the status row. |
| The page's top boundary is the band's bottom | Taken, without moving the page: the obscured top is the collapsed band's bottom in every state, so a header rests under the band mid-page and never moves. Safari moves the page's inset with its band; WebKit relayouts fixed elements on every inset change, so Plain keeps one. |
| Status items hidden while collapsed (45 pt band) | Not taken: the owner asked for the host "aligned with the status row, clear of the status items", and hiding the status bar is a system-level change. The slim band is the status row's height (73 pt on the device), not 45. |
| Host in a capsule | Taken (design review, round 1): bare text on the band read as an empty status bar. A small glass capsule holds the host, 12 x 5 pt around the text. |
| Strip shown whenever the bar is expanded | Not taken: Safari moves the page's inset with its strip; Plain keeps one inset, so the strip shows only while the page's top is in view and the bar comes back mid-page without it (a fixed header rests at the slim band's bottom, which the strip would cover). |
| Timed collapse and expand | Not taken: Plain's bar follows the finger 1:1 between expanded and collapsed (docs/research/scroll-chrome.md); the snap and the tap use one interruptible spring (`Motion.toolbarSnap`). |
| Status items fade, tint settles after | Not needed: the status items stay; the glass's tint follows the page under it on its own. |
| Address field 360 pt, centered on the row | Kept Plain's: the pill fills the room between the capsules up to 560 pt. |

## Plain: scenarios checked on the inner screen

Device Hub's iPhone Duo simulator, unfolded (the real inner screen, 2853x2007 px), iOS 27.2,
2026-11-27/28. Each walk is the Debug driver `-PlainTopWalk` (rest, mid-page, the collapse spring,
reading on, a tap on the band, the reveal spring, back to the top) recorded with `simctl io
recordVideo` on the inner display; stills at the end of each step and 60 fps strips of the top
160 pt around each transition. Local fixtures (fixed header, sticky header, dark page with a
black or red header, long text, a short page, colored stripes, a web app with its own top and
bottom bars, a readable article) plus apple.com, wikipedia.org and a code-hosting site. Round 1
captures are before the design review's fixes (strip over headers, bare host), round 2 after.

| Scenario | Result |
|---|---|
| Fixed header, one tab, light | Pass. The header rests at the band's bottom (73 pt) at rest, mid-page, collapsed and on reveal; the band's height does not change; nothing moves in the page. |
| Fixed and sticky headers, three tabs | Round 1: fail, the strip (73 to 111 pt) covered the header mid-page and controls faded over its text. Fixed: the strip follows the page's top (`stripReveal`); round 2 pass in landscape and portrait. |
| Dark appearance on a dark page with a red header | Pass. The band takes the header's color under the glass, as Safari's does; the host capsule is navy with light text. |
| Pages with their own top and bottom bars | Pass. The web app's bar sits right under the band; its bottom bar rests above the home indicator. |
| Real sites (apple.com, wikipedia.org, a code-hosting site) | Pass. A black site header sits right under the band at the top; the band blurs the page under it mid-page. |
| Busy page (colored stripes, white and black) | Pass. The glass refracts the stripes; the host and the pill stay legible, light and dark. |
| Very short page | Pass. First line under the band; the bar never collapses (the page is too short). |
| Find on Page | Pass. Find opens in the side pane (keyboard up); the band spans the page only. |
| Reader | Pass. The reader starts under the band and collapses to the slim band like a page. (The reader's own crossfade shows both texts for a frame: not this lane.) |
| Back and forward restoring the scroll position | Pass. Back restores mid-page with the bar expanded; the band blurs the text under it. |
| Private (dark) | Pass. Violet band and capsule. |
| Split panes | Pass, with one gap: the band spans both panes; the strip shows only while both panes' tops are in view. A pane resting at its very top while the bar is collapsed shows its page start 38 pt under the band. |
| Side pane (History) | Pass. The band stops at the side pane; the status items sit over the pane's header. |
| Left rail | Pass. The band starts beside the rail; the rail's New Tab stays on the row. |
| One tab against many | Pass. One tab: the band is 73 pt in both states. Many: 111 pt at a page's top, 73 pt mid-page and collapsed. |
| Keyboard up from a page's form | Not captured as its own walk (Find's keyboard was). The keyboard brings the bar back, as before (`keyboardWillShow`). |
| Status bar tap while collapsed | Changed after the captures: the bar now comes back as the page scrolls to its top. Round 2 stills show the old path for one frame (the slim band over a page top). |
| Pull to refresh at the top | Not captured (needs a finger). The indicator still sits under the expanded band (`pullIndicatorTop`). |
| Link from another app | Not verified: `simctl openurl` raises the simulator's "Open in Plain?" prompt, which the walk did not answer. A new page brings the bar back (`expandForNewPage`). |
| Fold and unfold while collapsed | Not verified: Device Hub reported Closed and Open, but the inner display's recording showed no change behind the prompt above. A hidden rest from the outer screen now rests at the slim band on unfold (`settleHiddenChromeForTopBar`). |
| Rotation while collapsed | Not verified: the recording was already portrait when the walk started (DuoTests left the simulator rotated). Portrait walks themselves pass. |
| Landscape and portrait | Pass in both (portrait: 669 pt wide, the same 73 / 111 pt band). |
| DuoTests (UI tests, unfolded) | 4 tests, 0 failures. |

### Glass cost (simulator)

Real Duo inner screen in the simulator, the stripes page with a frame counter (TestServer's
`/light-site` proxy: frames the page drew while scrolling, frames over 25 ms, the worst), three
scrolls of 4,000 pt in 2 s each, driven frame by frame with the bar expanded (the band at its
largest over a moving page). Band on: 405 frames, 1 over 25 ms, worst 86 ms. Band off
(`-PlainNoTopBand`): 406 frames, 1 over 25 ms, worst 82 ms. The same within noise; the one long
frame in each run is the first of a scroll. The simulator renders on the Mac's GPU, so this is
no hitch measurement: the device gate's `testPageScrollHitches` is the check for 120 Hz.
