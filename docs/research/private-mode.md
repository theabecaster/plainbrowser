# Private mode: seeing it and leaving it (2026-11-27)

Owner, on TestFlight: "It's a bit confusing how to turn off private mode, and it's also hard to
tell when you are in it and when you're not." Also: "To be fair, I think Arc is confusing for
private mode too", and "I don't want to drastically change our design... make it clear, elegant
and premium, always keeping performance a priority."

What Plain had: a light lilac glass tint (barely different from Paper in light mode), one
sentence on the empty private start screen, and an unlabelled hand glyph in the tab switcher's
bar as the only way in and out. Decisions: docs/decisions.md, "Private mode you can't miss".
Sources marked (secondhand) were read through search snippets or reviews, not the page itself.

## What the reference browsers do

**Safari (iOS 17 to 27).**
- In private mode the address bar is "black or dark instead of white or gray" [2].
- iOS 27: tap Tabs, then swipe right on the tab bar at the bottom until Private Browsing opens.
  To leave, tap Tabs and swipe left to a tab group [1]. Private sits to the left of the regular
  tabs. iOS 17 and earlier: the "Private" button to enter, "[number] Tabs" to leave [2].
- In the compact layout, More → New Private Tab enters and New Tab leaves [2].
- iOS 26 kept the swipe between regular, private and tab groups, with + on the left and Done on
  the right of the overview [5] (secondhand); a centre slider shows the tab count [6].
- Close All is a long press on Done [7] (secondhand). No current Apple text covers closing only
  the private tabs.
- Settings → Apps → Safari → "Require Face ID to Unlock Private Browsing" locks private windows
  when Safari leaves the foreground [1][3]; added in iOS 17 [4] (secondhand).
- No source says Safari's keyboard turns dark or stops learning in private mode. A WebKit bug
  says Safari on the Mac still learns typing there, closed "MOVED" because the fix is outside
  WebKit [25].

**Chrome iOS Incognito.** More → New Incognito Tab; the tab grid has an always-visible
Incognito switcher beside the regular tabs and groups, and Incognito tabs carry its icon [8][10].
To end it: Incognito → Edit → Close All Tabs [8]. Incognito tabs can be locked with device
authentication [9][11]. On Android Chrome sets the keyboard's no-learning flag on its URL bar
[27] (secondhand); there is no iOS equivalent.

**Firefox iOS.** The mask button at the top of the tabs tray switches in and out; in private
mode the tabs button shows a purple mask and the bar turns purple [12] (secondhand). Since 127 it
closes private tabs when you leave the app, by default [13] (secondhand).

**Arc Search.** + then the eyes icon; the bar turns dark and the tabs say "Incognito" [14]
(secondhand). The owner finds it confusing too, so Plain does not copy it here.

**DuckDuckGo.** No private mode: a Fire Button wipes data, and Fire Tabs (from a link's long
press) delete their data on close [15].

## What people complain about

- iOS 15 buried private browsing deeper than iOS 14 [16]; Tab Groups made it "a bit confusing"
  on iPhone [17].
- Apple Communities has years of "can't get out of private browsing" and "stuck in private"
  threads, up to iOS 26.1 [18] (secondhand).
- A dark bar alone is not enough: Safari's "Show Color in Tab Bar" can darken the bar outside
  private mode [20] (secondhand), and iOS 26 users report hard-to-read private address text [19]
  (secondhand).

## What NN/g says about modes

- A mode error happens when people don't know which mode is active; make the active mode
  clearly visible, and "we strongly recommend at least two visual indicators" [21].
- Name modes clearly and put text labels on mode-selector icons [21].
- Give a clearly marked, labelled exit (user control and freedom) [22] (secondhand).

## The keyboard

- `UITextInputTraits.keyboardAppearance` takes `.dark` [23]; it is cosmetic.
- UIKit has no "don't learn" flag like Android's `IME_FLAG_NO_PERSONALIZED_LEARNING` [23][24].
  The closest is turning things off: autocorrection and spell checking (Plain's field already
  does), `inlinePredictionType = .no`, `writingToolsBehavior = .none` and, on iOS 27,
  `grammarCheckingType = .no` (checked in the iOS 27.2 SDK headers). None of it is documented to
  stop the keyboard learning, so Plain never claims it.
- `WKWebView` has no public keyboard-appearance control for page fields [26]; whether a dark
  page `color-scheme` darkens it is undocumented. Plain leaves page fields to WebKit.
- Known iOS bugs: a number pad can stay light under `.dark` [28] (secondhand).

## Implications for Plain

1. Two strong cues at least, both on the pill: a dark violet material (not a tint of Paper) and
   the private mark before the host. The violet keeps private distinct from any dark page or the
   dark app, which Safari's black bar is not [20].
2. Label the switch: "Private | Tabs" in the switcher, Private on the leading side as in Safari,
   each side with its count, the shown side filled.
3. The exit is as visible as the entrance: the other word of the switch, one tap; "Leave
   Private" on an empty private tab's start screen; Close All Private Tabs in the switcher's
   menu and the tabs menu.
4. The start screen says "Private" as a title, on the private dusk.
5. Dark keyboard and no predictions in private; no promise about learning.
6. Not now: a Face ID lock and closing private tabs on leaving the app. Both are settings or
   behaviour changes the owner did not ask for; noted in docs/polish-backlog.md.

## Sources

1. https://support.apple.com/guide/iphone/browse-the-web-privately-iphb01fc3c85/ios
2. https://support.apple.com/105030
3. https://support.apple.com/105028
4. https://www.macrumors.com/2023/06/05/ios-17-safari-private-browsing-face-id/
5. https://www.macrumors.com/2025/06/23/ios-26-beta-2-safari-design-change/
6. https://www.macrumors.com/guide/ios-26-safari-features/
7. https://support.apple.com/en-kz/guide/iphone/iph3028ebf68/15.0/ios
8. https://support.google.com/chrome/answer/95464?hl=en&co=GENIE.Platform%3DiOS
9. https://support.google.com/chrome/answer/9845881?hl=en&co=GENIE.Platform%3DiOS
10. https://9to5google.com/2025/09/20/chrome-141-liquid-glass/
11. https://9to5google.com/2021/02/11/chrome-lock-touch-face-id/
12. https://support.mozilla.org/kb/private-browsing-firefox-ios
13. https://support.mozilla.org/en-US/kb/automatically-close-private-tabs-when-leaving-priv
14. https://resources.arc.net/hc/en-us/articles/25483815030679-How-To-Use-Incognito-Mode-in-Arc-Search
15. https://duckduckgo.com/duckduckgo-help-pages/privacy/fire-tabs
16. https://9to5mac.com/2022/04/21/iphone-private-browsing-safari-ios-15/
17. https://tidbits.com/2021/09/23/hot-new-features-in-safari-in-ios-15-and-ipados-15/
18. https://discussions.apple.com/thread/252127077, https://discussions.apple.com/thread/254922223,
    https://discussions.apple.com/thread/256118259, https://discussions.apple.com/thread/256209409
19. https://forums.macrumors.com/threads/does-anyone-else-have-frequent-address-bar-issues-while-using-private-browsing-mode-in-safari-on-ios-26.2478365/
20. https://discussions.apple.com/thread/256228304
21. https://www.nngroup.com/articles/modes/
22. https://www.nngroup.com/articles/ten-usability-heuristics/
23. https://developer.apple.com/documentation/uikit/uitextinputtraits
24. https://developer.android.com/reference/android/view/inputmethod/EditorInfo#IME_FLAG_NO_PERSONALIZED_LEARNING
25. https://bugs.webkit.org/show_bug.cgi?id=236212
26. https://developer.apple.com/forums/thread/120631
27. https://codereview.chromium.org/2901023002
28. https://developer.apple.com/forums/thread/817164

## Wide screens and colour (2026-11-28)

Owner: on the inner screen "it mixes the private and regular tabs ... it should be more like the
outer screen, where it's a clear mode"; and the violet "takes away the premium feel and gives
AI-slop vibes". Decisions: docs/decisions.md, "Private as a clear mode on wide screens, in Night
and Horizon".

**How wide layouts do it.**
- Safari on iPad: private browsing is a tab group in the sidebar; while it is on "the Safari
  background is gray", and leaving is picking another group, after which the private tabs stay
  open and lock [29][30]. One list at a time, never mixed.
- Chrome on iPad and Android: Incognito is its own tab grid beside the regular one, with a toggle
  at the top of the switcher [10][31].

**How they colour it.**
- Safari: a dark bar on iPhone [2], a grey background on iPad [29]. Chrome: a dark grey scheme,
  "to distinguish it from normal mode", which themes may not change [32][33]. Arc Search: a dark
  bar [14].
- Purple: Firefox's private windows and its mask [12], Firefox Focus's whole brand ("a sultry
  purple" logo, the "purple curtain") [34][35], and Brave's private windows. So purple says
  "another browser's private mode", and in 2026 the violet-gradient look reads as generated.
- High-end dark interfaces (Apple's dark materials, camera and watch faces, luxury car and audio
  apps) are neutral or warm graphite with a single warm light, never a saturated hue.

**Implication.** Night (warm graphite) with one warm light from Plain's own mark (Horizon,
`#FFC08E`), carried by the mark and the word "Private" so colour is never the only cue.

29. https://support.apple.com/guide/ipad/browse-the-web-privately-ipad8ea0fc1a/17.0/ipados
30. https://tidbits.com/2021/09/23/hot-new-features-in-safari-in-ios-15-and-ipados-15/
31. https://techradar.com/news/chromes-new-tab-switcher-for-smartphones-is-a-bit-of-a-mess-but-still-useful (secondhand)
32. https://techradar.com/news/chrome-is-getting-a-better-dark-mode-when-you-go-incognito (secondhand)
33. https://chromewebstore.google.com/detail/material-incognito-dark-t/ahifcnpnjgbadkjdhagpfjfkmlapfoel (secondhand)
34. https://www.vice.com/en/article/firefox-focus-browser-app/ (secondhand)
35. https://blog.mozilla.org/en/products/firefox/firefox-focus-or-firefox/
