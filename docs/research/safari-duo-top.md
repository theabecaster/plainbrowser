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
| Host in a capsule | Not taken: the band is the glass; a capsule on it would be a third layer of glass. The host is text on the band. |
| Timed collapse and expand | Not taken: Plain's bar follows the finger 1:1 between expanded and collapsed (docs/research/scroll-chrome.md); the snap and the tap use one interruptible spring (`Motion.toolbarSnap`). |
| Status items fade, tint settles after | Not needed: the status items stay; the glass's tint follows the page under it on its own. |
| Address field 360 pt, centered on the row | Kept Plain's: the pill fills the room between the capsules up to 560 pt. |

## Plain: scenarios checked on the inner screen

See the table at the end of this file (filled from the captures in this lane).
