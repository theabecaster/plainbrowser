# Scroll chrome: how browsers get the bar out of the way (2026-11-27)

Owner: "Scrolling websites needs work: the URL bar should disappear and let the user browse at
some point. Investigate what other browsers do and implement the most elegant one with our
identity. Ensure it's always performant."

Before this change Plain's bar collapsed to a small pill on scroll (Safari 26's compact bar) and
stayed there. This note says what other iPhone browsers do, and what Plain does now.

**[1st]** means the browser's own source code or Apple's documentation. **[2nd]** means press,
forums or bug threads. Safari, Arc Search and Orion are closed source, so their rows are thin.

## 1. What each browser does

### Safari (iOS 26)

- Scrolling down shrinks the Compact bar to a small pill that shows the site; scrolling up or a tap
  on the pill brings it back. It never leaves the screen. [2nd]
  [9to5Mac](https://9to5mac.com/2025/06/12/iphone-ios-26-safari-new-compact-design/),
  [9to5Mac](https://9to5mac.com/2025/09/15/iphone-ios-26-safari-new-compact-design/)
- Near the page's end Safari keeps the bar out rather than open a gap below the page. [2nd]
  [Mozilla bug 1921339](https://bugzilla.mozilla.org/show_bug.cgi?id=1921339)
- Complaints: fixed and sticky page content is cut off instead of drawn behind the floating bar
  ([Apple forums 800798](https://developer.apple.com/forums/thread/800798),
  [801028](https://developer.apple.com/forums/thread/801028)); swipes at the home indicator
  sometimes catch the bar ([PhoneArena](https://www.phonearena.com/news/Safari-on-iOS-26-is-a-mess-but-you-can-fix-some-of-it_id175463)). [2nd]
- With VoiceOver on, Safari never hid its bar (older report). [2nd]
  [Mozilla bug 1178011](https://bugzilla.mozilla.org/show_bug.cgi?id=1178011)

### Arc Search

- A minimal bottom bar (tabs, search, a menu chevron); the address lives behind the menu. No
  source found for its scroll rules, VoiceOver or Reduce Motion. [2nd]
  [MacStories](https://www.macstories.net/reviews/arc-search-for-iphone/)

### Chrome (Chromium source) [1st]

- 1:1 with the finger over `kEasedTransitionScrollDistance = 140` pt; past 25 % of the way the
  animation finishes the rest (`kEnter/ExitFullscreenProgressThreshold`). A 10 pt dead zone
  (`kScrollThresholdDefault`); a release past 10 pt picks the direction, else the nearer end.
  [fullscreen_constants.h](https://chromium.googlesource.com/chromium/src/+/main/ios/chrome/browser/fullscreen/model/fullscreen_constants.h),
  [fullscreen_model.mm](https://github.com/chromium/chromium/blob/main/ios/chrome/browser/fullscreen/ui_bundled/fullscreen_model.mm)
- Top-bounce ignored; the bottom rubber band is frozen "to prevent this UI jump". Short pages
  (content ≤ view + toolbars) never hide. Every new document shows the bars. The web view's
  viewport insets span a min/max range. VoiceOver turns hiding off
  (`fullscreen_system_notification_observer.mm`).

### Firefox [1st]

- Hides on scroll down, back on scroll up. Since 145 a "minimal toolbar" keeps the domain
  visible. [Mozilla support](https://support.mozilla.org/en-US/kb/toolbar-firefox-ios),
  [145 release notes](https://www.firefox.com/en-US/firefox/ios/145.0/releasenotes/)
- `TabScrollHandler`: live tracking, jitter under 0.5 pt ignored; a release commits only past
  `minimumScrollThreshold = 20` pt. Ignored while loading, at the page bottom and in find.
  Short pages (content < view + 2 toolbars) don't hide. VoiceOver turns hiding off. A status bar
  tap or a tap on the collapsed toolbar shows it.
  [TabScrollHandler.swift](https://github.com/mozilla-mobile/firefox-ios/blob/main/firefox-ios/Client/Frontend/Browser/TabScrollController/TabScrollHandler.swift)
- Legacy controller: a drag counts past 20 pt or 100 pt/s; animation 0.2 s.
  [LegacyTabScrollController.swift](https://github.com/mozilla-mobile/firefox-ios/blob/main/firefox-ios/Client/Frontend/Browser/TabScrollController/LegacyTabScrollController.swift)

### DuckDuckGo [1st]

- Floating chrome hides over 80 pt, 1:1; a release faster than 0.15 pt/ms picks the direction,
  else 0.5. Short pages collapse within half their scroll range "so the collapse is over before
  the page end shows, as in Safari". A drag starting within one bar height of the end does not
  hide; pulling past the end with the bar hidden reveals it; the top reveals it.
  [BarsAnimator.swift](https://github.com/duckduckgo/apple-browsers/blob/main/iOS/DuckDuckGo/Main/BarsAnimator.swift)
- A status bar tap while hidden reveals the bar and does not scroll to the top.
  [BrowserChromeManager.swift](https://github.com/duckduckgo/apple-browsers/blob/main/iOS/DuckDuckGo/Main/BrowserChromeManager.swift)

### Brave [1st]

- 1:1 over the bar's height difference; the release projects the fling and collapses only when
  the projected travel passes that distance and the page is not near its end. An upward fling,
  the top, or a fast pull past the end expands. Spring response 0.25, damping 0.8.
  [ToolbarVisibilityViewModel.swift](https://github.com/brave/brave-core/blob/master/ios/brave-ios/Sources/Brave/Frontend/Browser/ToolbarVisibilityViewModel.swift)
- What stays: a lock and the host in caption text (`CollapsedURLBarView`); a tap on it or the
  top/bottom touch areas expands. A loading tab forces the bar out. A status bar tap while
  collapsed expands instead of scrolling. `setMinimumViewportInset(collapsed, maximum: expanded)`.
  [CollapsedURLBarView.swift](https://github.com/brave/brave-core/blob/master/ios/brave-ios/Sources/Brave/Frontend/Browser/Toolbars/UrlBar/CollapsedURLBarView.swift)

### Orion (Kagi)

- "Hide Toolbar" from the site menu; scrolling up undid it in 1.2.4; a later Focus Mode "shows
  the full toolbar on scroll". [2nd] [Orion feedback 4615](https://orionfeedback.org/d/4615)

### Apple

- `UITabBarController.MinimizeBehavior.onScrollDown`: "minimizes when scrolling down, and
  expands when scrolling back up." [1st]
  [Docs](https://developer.apple.com/documentation/uikit/uitabbarcontroller/minimizebehavior/onscrolldown).
  The HIG's tab bar page says a tap or scrolling to the top exits it
  ([HIG](https://developer.apple.com/design/human-interface-guidelines/tab-bars)); DTS says the
  accessory collapses only when content "significantly exceeds the screen height", no number
  ([forums 809945](https://developer.apple.com/forums/thread/809945)).
- `hidesBarsOnSwipe`: swipe up hides, swipe down shows. [1st]
  [Docs](https://developer.apple.com/documentation/uikit/uinavigationcontroller/hidesbarsonswipe)

## 2. Patterns

| Question | What the browsers agree on |
|---|---|
| When it hides | 1:1 with the finger, then a snap on release by distance or velocity. Dead zone 10–20 pt; velocity 100–200 pt/s; otherwise the nearer end. |
| What stays | Safari: the pill. Brave: lock + host label. Firefox 145: the domain. Chrome, DDG, older Firefox: nothing at the bottom. |
| How it returns | Scroll up (past a dead zone or a fling), the top, a tap on what remains, a status bar tap (DDG, Brave: without scrolling to the top), navigation (Chrome). Near the end: Safari keeps the bar, DDG and Brave reveal on a pull past the end. |
| Short pages | Never hide when the content is about one screen plus the bars. |
| Loading | Firefox and Brave keep the bar out while a page loads. |
| Page layout | Chrome and Brave move the viewport insets over a min/max range, never relayout per frame. |
| VoiceOver | Chrome, Firefox (and Safari) never hide. |
| Reduce Motion | None checked in the files read. |

## 3. What Plain does

Three resting states: **expanded → pill → hidden**.

1. **Expanded to pill**, as before: 1:1 with the finger over 56 pt, then a snap on release.
2. **Pill to hidden**: keep reading and the pill sinks below the bottom edge, 12 pt past it so the spring's tail runs off screen, as its text fades (Liquid Glass ignores alpha, so the glass leaves by moving)
   (`Motion.toolbarHide`, `.smooth(0.35)`, a calmer exit than the snap). It happens once the page
   has travelled 120 pt past the pill since the bar was last out, in one drag, over several or
   while coasting. A flick whose coast will carry the reader that far goes straight from wherever
   the bar is to hidden in one motion (Brave's projection), so a single flick never plays two
   animations.
3. **Nothing remains.** No thin host label: text without glass over an arbitrary page is not
   legible, and a label with glass is the pill again. The pill already gave the reader the host
   on the way down. The bottom edge strip (the home-indicator zone) is the way back by touch.
4. **Back, whole bar** (`.smooth(0.25)`, the snap spring), from any of:
   - an upward drag of 24 pt, or 8 pt at 0.3 pt/ms or faster (not a nudge to reread a line, not
     jitter); an upward flick on release;
   - a tap on the bottom edge strip (the home-indicator zone: taps belong to the app there, swipes
     to the system, so the strip has a tap and nothing else);
   - a status bar tap (the first tap only brings the bar back and keeps the place, as DDG and Brave);
   - the page's end reaching the screen's bottom edge (Safari, DDG): the reader is done and the
     next step is the bar. In the last 56 pt before it the bar does not collapse, so it cannot
     flap. If the bar arrives while the page rests at its very end, the page rises with it, so the
     last line is never left under the bar;
   - the top; a new page, another tab, Find, a page's keyboard, a page's alert, the reader;
   - a page that became too short, or VoiceOver / Switch Control turning on.
5. **Never hidden**: while a page loads (the pill carries the progress, and the page may not have
   painted), on a failed, crashed or resend page, while editing or finding, under VoiceOver or
   Switch Control (Chrome, Firefox and Safari do the same), and on a page shorter than two screens.
   The pill is allowed in all of these, as before.
6. **Page inset** (engine rule 4): `obscuredContentInsets.bottom` follows the resting state, now
   one of three: the expanded chrome (136 pt on iPhone 17), the pill (54 pt), or hidden: only the
   home-indicator strip (34 pt; 16 pt where there is none). The scroll view's own bottom inset
   follows it (WebKit's obscured inset alone leaves the scroll range at the safe area, measured),
   so the page's last line can always clear the bar. It switches once, when a motion ends, never
   per frame, and waits out bounces as before. So a fixed footer sits above the expanded bar,
   above the pill, and just above the home indicator while hidden. The viewport range is now
   hidden to expanded (`setMinimumViewportInset`), so `svh`/`lvh` stay fixed during motion.
7. **Duo**: on the outer screen the system's vertical bar cannot hide and keeps its buttons; only
   the pill sinks away. The inner screen has Safari's top bar (docs/research/safari-duo.md) driven
   by the same three states: expanded is the whole row (and the strip); the pill is the address
   tucked under the status bar with the buttons and strip faded; hidden lifts the tucked address
   off the top edge, so the page starts right under the status bar (top inset 0). The top bar is
   clear of the home-indicator zone, so hiding it fights no system gesture. A status bar tap, the
   bottom edge strip and every other reveal bring the row back. In a split, the focused pane's
   lane holds the edge strip.
8. **Reduce Motion**: the hide and the return are the chrome's 0.2 s crossfade; the 1:1 tracking
   to the pill stays (it is the finger's own motion).
9. **Performance**: the scroll callback adds a few comparisons and, only while hidden and
   dragging, one pan-velocity read. Motion is transform and alpha from `SpringDriver` at 80–120 Hz;
   no layout during motion (the edge strip toggles `isUserInteractionEnabled`, not `isHidden`).

Why this one: it keeps what reads best in Plain today (the pill as a calm first step, which also
shows the host), then does what the owner asked, getting fully out of the way, with the return
paths every other browser converged on, and the end-of-page and status-bar manners of the best of
them. It adds no setting.
