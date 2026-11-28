# Gestures and keys a Safari user expects (2026-11-27)

Owner, 2026-11-27: "Like Safari, we should support all expected web browser gestures — for example
to change tabs, or whatever else." This is the inventory: what Safari on iOS 26/27 (iPhone, iPad
and the iPhone Duo's inner screen, which Plain treats like an iPad window) and Chrome or Arc do,
what Plain did before this lane, and what it does now. Rules for each live in
`docs/state-rules.md`; the table users see is in `docs/ui-reference.md`, "Gestures and keys".

## Sources

- Apple, iPhone User Guide, "Browse the web using Safari on iPhone" and "Open and close tabs":
  swipe the address bar for the next or previous tab, swipe up on it for all tabs, the tabs
  button's long press (New Tab, New Private Tab, Close This Tab, Close All Tabs), Recently Closed
  from a long press on New Tab in the overview. https://support.apple.com/guide/iphone/browse-the-web-iph1fbef4daa/ios
- MacRumors, "Safari Changes on iOS 26 Go Beyond the Address Bar" (2025-06-18) and 9to5Mac, "iOS
  26 Safari new compact design" (2025-06-12): the Compact bar is the default; sideways on the bar
  switches tabs, up opens all tabs, past the last tab opens a new one.
  https://www.macrumors.com/2025/06/18/safari-changes-on-ios-26/ ·
  https://9to5mac.com/2025/06/12/iphone-ios-26-safari-new-compact-design/
- Apple, "Learn iPad keyboard shortcuts" (support.apple.com/102393) and the iPad User Guide: hold
  ⌘ for the app's shortcuts. Safari's list (⌘T, ⌘⇧N, ⌘W, ⌘⇧T, ⌘L, ⌘R, ⌘., ⌘[, ⌘], ⌘F, ⌘G, ⌘⇧G,
  ⌘D, ⌘⇧D, ⌘⇧R, ⌘⇧\, ⌃Tab, ⌃⇧Tab, ⌘⇧[ ⌘⇧], ⌘1 to ⌘9, ⌘+ ⌘− ⌘0, ⌘Y) is Safari for Mac's and
  iPad's; OSXDaily, "28 Safari Keyboard Shortcuts for iPad", lists the same core.
  https://support.apple.com/102393
- iGeeksBlog and MacRumors how-tos on reopening tabs: shake the iPhone for "Undo Close Tab"
  (Settings > Accessibility > Touch > Shake to Undo); the three-finger swipe left is the system's
  undo gesture since iOS 13. https://www.macrumors.com/how-to/open-recently-closed-safari-tabs-on-ios/
- WebKit: `allowsBackForwardNavigationGestures` (edge swipes), `allowsLinkPreview` (link
  previews and their menus), page pinch and double-tap zoom, Space / ⇧Space / arrows / ⌘↑ ⌘↓
  keyboard scrolling while the web view holds the keys (WKWebView, iOS 13.4+).
- Safari on iPad: a pinch in on a page at its smallest zoom opens the tab overview (not on
  iPhone). Chrome and Arc on iPhone: no pinch to the overview; Arc's Back on a link's first page
  returns to the opener, as Plain's does.

## Inventory

Status before (dev at eea68b6) and after this lane.

| Interaction | Safari / standard | Plain before | Plain now |
|---|---|---|---|
| Swipe the address bar sideways: previous / next tab, past the last a new tab | iPhone Safari | Yes (`TabSwipe`, New Tab card) | Unchanged |
| Swipe up on the bar: all tabs | iPhone Safari | Yes (interactive, `TabGalleryTransition`) | Unchanged; none from the inner screen's top bar (decided, decisions.md) |
| Edge swipe back / forward on the page | All | Back: WebKit, then the opener swipe without history. Forward: WebKit, **except the Duo's inner screen, where the side pane took the trailing edge always** | Forward edge goes forward whenever the page has somewhere forward; the side pane opens from that edge only where forward has nothing to do |
| Pull to refresh | All | Yes (arms at 80 pt, selection haptic) | Arrow runs through the brand's colors, faster near the threshold; spins in Lagoon until the load ends |
| Pinch zoom, double-tap zoom | WebKit | Yes (viewport limits ignored) | Unchanged |
| Tap the status bar: top of the page | All | Yes; with the bar hidden the first tap brings it back, the next scrolls | Unchanged (decided, DuckDuckGo and Brave do the same) |
| Tap the bottom edge with the bar hidden | Safari | Yes (`revealEdge`) | Unchanged |
| Long press Back / Forward: the history list | All | **No** | Yes, nearest page first, at most 15; only where the page has history that way |
| Long press Tabs: New Tab, New Private Tab, Close Tab, Close All | Safari | New Tab, New Private Tab, Previous/Next, Show All, Reopen, Archive, windows, Close Tab. **No Close All** | Close All N Tabs under Close Tab, confirmed first |
| Long press a link or image: preview, Open in New Tab / Background / Other Pane / New Window, Copy, Share, Save | All | Yes (`LinkMenu`) | Unchanged |
| Drag a link to another app or window | iPad Safari; iPhone apps since iOS 15 | No (WebKit keeps drag off on iPhone-class devices) | Not changed: turning it on needs WebKit SPI or reaching into WKContentView's interactions; the strip and rail as drop targets are the strip lane's. Open in New Window and Open in Other Pane cover the Duo |
| Pinch in on a page: the tab overview | iPad Safari | **No** | Yes on the inner screen (the top bar's screens), page at its smallest zoom, fingers closed to 70% |
| Swipe down to dismiss sheets | System | Yes (system sheets, the search field's swipe down) | Unchanged |
| Swipe a card to close in the switcher | Safari (sideways), Arc (up) | Yes (up, Arc) | Unchanged |
| Shake / three-finger swipe: Undo Close Tab | Safari | **No** | Yes, and ⌘Z: the last hand close, the same batch as the Reopen toast |
| Hardware keyboard shortcuts, listed when ⌘ is held | Safari (iPad, iPhone with a keyboard) | **None** | Every key in the list above; each acts only where its control would |
| Find Next / Previous (⌘G, ⌘⇧G) | Safari | No | Yes, while the find bar is open |
| Space, ⇧Space, arrows, ⌘↑, ⌘↓ | WebKit | Only after a tap put the page in charge of the keys | The page takes the keys whenever a hardware keyboard is attached and nothing else has them |
| Escape | Safari | No | Closes the search field or the overview; otherwise the page's (fullscreen video, a web app's dialog) |
| VoiceOver: the bar's gestures | — | Buttons and menus only | Pill actions: Previous Tab, Next Tab, New Tab, Show All Tabs; the two-finger scrub closes the field or the overview |

## Conflicts and how they were resolved

- **The Duo's trailing edge: WebKit's swipe forward or the side pane.** Before, the pane's edge
  swipe always won where the pane could open, so a Safari user's forward swipe never worked on
  the inner screen. Now the edge is the page's while it has a page forward, and the pane's only
  where forward would do nothing (`FixedChoices.forwardSwipeBeforeSidePane`). Back's edge already
  works this way (WebKit's back first; the opener swipe only without history), so both edges read
  the same: the page's own history first, Plain's extra only where history has nothing. The pane
  also opens from More (Show Side Pane), History and Find on Page, so it is never only behind the
  gesture. A two-stage edge (a short swipe forward, a long one the pane) was rejected: the
  difference is invisible and the wrong one fires under a hurried thumb.
- **Pinch to the overview and WebKit's zoom.** The recognizer only watches (it cancels no
  touches and recognizes with every other gesture) and starts only with the page at its smallest
  zoom, so any zoom in and the zoom back out stay WebKit's. It acts when the fingers lift having
  closed to 70%: WebKit's own rubber band below the smallest zoom is a smaller squeeze. Only on the
  top bar's screens (the Duo's inner screen), as Safari keeps it to the iPad.
- **System gestures.** Nothing new sits on the screen's edges except the existing edge swipes:
  the home indicator, Control Center and the notification shade are untouched; the bottom-edge tap
  takes touches only while the bar is hidden, as before.
- **Keys and the page.** Browser keys win over a page's own ⌘L or ⌘F, as in Safari
  (`wantsPriorityOverSystemBehavior`). Escape acts only while the field or the overview is open;
  anywhere else its validation says no and the key goes on to the page. Space and the arrows are
  never claimed: WebKit scrolls with them.
- **Undo and typing.** The browser's undo is the responder chain's last resort: in the field or a
  page's form, ⌘Z and a shake undo typing, as everywhere in iOS.

## Pull to refresh's colors (owner, 2026-11-27)

"For the spinner that shows on pull-down, can it cycle through colors as it gets closer to the
trigger point, and the closer it gets the quicker it changes? Use our gradient and palette
colors."

- The loop is dawn teal (Shallows Mint), Lagoon, the icon's violet bloom and Curl Coral
  (`Palette.pullCycle`); a private tab runs the dusk violets and the sky's blue
  (`Palette.privatePullCycle`).
- Colors blend in OKLab (Björn Ottosson, 2020), so Lagoon to coral passes through an even violet
  instead of the grey an sRGB blend gives. Each color is held in a lightness band so it reads on
  the indicator's ground: OKLab L ≤ 0.62 on white by day, ≥ 0.74 on the dark surface by night.
- The position in the loop is `turns × fraction²` (`ColorCycle.phase`, two turns): its speed
  grows with the pull, so a pull just begun barely changes and the last stretch races.
- Armed: the indicator fills with Lagoon (violet in a private tab), the arrow white, with the
  selection haptic. Released armed: it rises to its resting spot and spins in that one color until
  the load ends, at most 1.5 s. Reduce Motion: one color, no cycle, no spin.
- Cost: the loops are four tables of 96 `CGColor`s built once; a scroll callback indexes the
  table and sets one layer color only when the entry changes. The arrow is a symbol used as a
  mask, so a color change never draws the symbol again. No display link: the pull's own scroll
  callbacks drive it.
