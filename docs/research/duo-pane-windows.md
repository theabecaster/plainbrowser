# Side pane and windows on the iPhone Duo

Researched 2026-11-27: web sources, the local iOS 27.2 SDK headers, and the iPhone Duo simulator.
No device was used.

Labels: **[S]** Sourced (URL in Sources). **[I]** Inferred (basis given). **[U]** Unverified.
**[M]** Measured on the simulator.

## Bottom line

- The Duo's inner screen takes several windows of one app, the iPad way. Its outer screen takes
  none [S1, S2]. An app opts in with `UIApplicationSupportsMultipleScenes` and the scene life
  cycle [S1].
- The system has no button for a new empty window. Users open one from the app's own menus
  ("Open in New Window") [S4]. Two windows sit side by side 50/50 in Split View, and the app
  can't ask for a size or a place [S1, S2, S5].
- Folding is a size and trait change of the same scene, not a disconnect [S2]. What happens to
  a second window on fold is not published [U].
- Apple's model for a supporting column is the split view's inspector (iOS 26): a trailing
  column at regular width, a sheet at compact width [S6, S2]. Plain's shell is a custom container
  with a `UIArrangementViewController` inside, which must not sit in a split view controller
  [S7], so Plain draws its own column with the same rules [I].

## Windows (UIScene multi-window)

- iPhone Duo is the first iPhone with several windows per app; "if your app supports it on iPad,
  it will on the inner display" [S1, S2].
- "On the outer display of iPhone Duo, new windows cannot be created. That behavior is reserved
  for the inner display." Requests must handle errors; `UIWindowSceneActivationAction` hides by
  itself where new windows aren't available [S1].
- Each window is its own scene. `UserDefaults` and `AppStorage` are app-wide, not per window
  [S2]. So per-window state belongs in `UISceneSession.userInfo` or the app's own store [I].
- APIs (SDK 27.2 headers): `UIApplication.activateSceneSession(for:errorHandler:)` with
  `UISceneSessionActivationRequest(role:)` and a `userActivity` for a new window, or
  `UISceneSessionActivationRequest(session:)` to bring one forward; `openSessions`,
  `requestSceneSessionDestruction`; `application(_:didDiscardSceneSessions:)` [S8].
  `UISceneSessionActivationRequest` is a value type in Swift (`var`) [M].
- Split View: drag up from the bottom, pause, drag to an edge, or long-press an icon and pick
  Open in Split View. A second Safari window comes from tapping Safari's icon again in Split
  View [S5]. Each window is about 385 pt wide there [S3].
- iOS has no "Show All Windows" (iPad's app exposé). The app switcher shows each window as its
  own card [S4] [U: no Duo equivalent found].
- Removing an app's card from the app switcher discards its scene sessions; the app hears it
  in `didDiscardSceneSessions` at the next launch [S8, I].
- Simulator: the iPhone Duo simulator (iOS 27.2) reports `supportsMultipleScenes` and opens a
  second window from "Open in New Window" on the inner screen [M, SidePaneTests].

## Safari

- Duo: two Safari windows side by side in landscape on the inner screen, each 385 CSS px wide;
  tab bar at the top inside, at the bottom outside [S3].
- Duo: no source shows "Open in New Window" in Safari's link menu, a Safari sidebar on the inner
  screen, or Reader in a side pane [U].
- iPad: the sidebar opens from the Sidebar button at the top left, on the left. It holds Private,
  History, Reading List, Tab Groups and Shared with You [S9, S10]. Link menu: "Open in New
  Window" [S11]. Long-press the icon > New Window [S12]. A swipe to open the sidebar, its width,
  Merge All Windows and Move Tab to Window were not verified [U].

## The fold and side columns

- Split views expand on the inner screen and collapse to one pane on the outer one. Partly
  folded, they resize their columns to the fold [S13].
- Keep buttons and controls out of the fold; scrolling content may cross it. Make small
  adjustments, not big rearrangements [S13, S14].
- `UIArrangementViewController` (iOS 27.1): never put it inside a split view or scroll view, and
  never nest a split view inside it [S7].
- No Apple guidance on a ~30% side pane was found [U]. The inspector column is the closest system
  pattern [S6].

## What Plain takes from this

1. **Windows:** turn on multiple scenes, offer "Open in New Window" in the link menu and "New
   Window" in the tabs menu only where both size classes are regular and the app supports
   several scenes, and handle the system's refusal anyway [S1].
2. **Per-window state with app-wide stores:** one tab store for all windows (two scenes must
   never write the tab session over each other), one set of per-site choices; per window only
   the window id, the sidebar and the side pane, in `UISceneSession.userInfo` [S2, I].
3. **Switching:** with no system window list on iPhone, the tabs menu lists the other windows
   and brings one forward [S4, I].
4. **Closing:** a window the user closes for good gives its tabs to Reopen Closed Tab, as
   Safari's do; a whole app swiped away keeps every tab [I].
5. **Side pane:** a trailing column like the inspector, only where the top bar is (regular both
   ways); never across the crease: partly folded, page and pane take one side each [S6, S13].

## Sources

- S1 Apple Tech Talk 111464, multiple windows on iPhone Duo: https://developer.apple.com/videos/play/tech-talks/111464
- S2 Apple Developer Forums, iPhone Duo lab summary: https://developer.apple.com/forums/thread/847644
- S3 WebKit, Safari 27.1: https://webkit.org/blog/18486/webkit-features-for-safari-27-1/
- S4 MacStories, multiple windows on iPhone Duo: https://macstories.net/ios/how-to-easily-create-multiple-windows-for-the-same-app-on-iphone-duo/
- S5 Gadget Hacks, two Safari windows: https://apple.gadgethacks.com/news/how-to-open-two-safari-windows-side-by-side-on-iphone-duo/
- S6 UISplitViewController inspector column: https://developer.apple.com/documentation/uikit/uisplitviewcontroller/column/inspector
- S7 UIArrangementViewController: https://developer.apple.com/documentation/uikit/uiarrangementviewcontroller
- S8 Local SDK headers: `UIApplication.h`, `UISceneSessionActivationRequest.h`, `UIWindowSceneActivationAction.h` (iPhoneOS27.2.sdk)
- S9 iPad User Guide, Safari sidebar: https://support.apple.com/guide/ipad/aside/ipad999d68f9/ipados
- S10 iPad User Guide, Tab Groups: https://support.apple.com/guide/ipad/organize-your-tabs-with-tab-groups-ipadf5a4dd79/16.0/ipados
- S11 MacRumors, Open in New Window on iPad: https://www.macrumors.com/how-to/create-new-window-from-link-safari-ipados/
- S12 Apple Support, multiple windows on iPad: https://support.apple.com/125309
- S13 HIG, Designing for iPhone Duo: https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo
- S14 Apple Tech Talk 111466: https://developer.apple.com/videos/play/tech-talks/111466/
