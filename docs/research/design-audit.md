# Design audit (2026-11-26)

Plain's design compared with firefox-ios, DuckDuckGo apple-browsers (iOS), Brave iOS, WebKit source and Apple's iPhone Duo guidance.
"Change" items are adopted in `docs/plan.md`. "Keep" items were checked and stay as they are.
Plain uses public API only. Fixes that need private WebKit API (`_WKNavigationActionPolicyAllowWithoutTryingAppLink`, `_webView:webContentProcessDidTerminateWithReason:`, `_beginInteractiveObscuredInsetsChange`) were not adopted.

Source short names:
[FF] github.com/mozilla-mobile/firefox-ios · [FF#35962] github.com/mozilla-mobile/firefox-ios/issues/35962 ·
[DDG] github.com/duckduckgo/apple-browsers · [Brave] github.com/brave/brave-core · [WK] github.com/WebKit/WebKit

## Engine (tabs, restore, memory)

### Change
- **No throttle tier.** `configuration.copy()` shares one `WKPreferences`, so a per-tab `inactiveSchedulingPolicy` sets it for every tab and sends preference IPC to every page. Leave WebKit's default (`.suspend`); a detached web view is suspended anyway. [WK] `APIPageConfiguration.cpp`, `WKPreferences.mm`; [FF#35962].
- **Save state continuously.** Save `interactionState` after each load (debounced) and on detach; flush all live tabs on resign active inside a background task. Otherwise a kill loses every non-discarded tab. [DDG] `TabManager.swift`, `TabInteractionStateDiskSource.swift`.
- **Timeouts on async WebKit calls.** `takeSnapshot`, `fetchData(of: .sessionStorage)` and `restoreData` may never call back on a frozen process. Race each against ~300–500 ms; skip the sessionStorage fetch on a memory warning. [DDG] `WebViewPreviewSnapshotCapturer.swift`.
- **Verify restores.** Setting `interactionState` fails silently; if `webView.url` is nil afterwards, load the URL. Store whether the current item was a POST and ask before resubmitting. [DDG] `TabViewController.swift`; [WK] `LegacySessionStateCoding.cpp`; [FF#35962].
- **Background process kill = discard.** iOS kills suspended WebContent processes routinely. For a hidden tab, keep its `interactionState` and mark it Discarded instead of reloading; a visible tab in a backgrounded app reloads on become-active. [DDG] `TabViewController.swift`; [FF#35962].
- **Never discard active tabs.** Skip tabs playing media, in PiP or fullscreen, using camera or mic, or downloading, including on a memory warning. [FF#35962].
- **Keep the visible tab's neighbours live.** A bar swipe then shows a real page, not a stale thumbnail and a reload. Keep a hard ceiling (Firefox crashed at ~50 live web views). [FF#35962]; [DDG] `TabEvictionSettings.swift`.
- **Thumbnails at ~2x.** `snapshotWidth` is in points and WebKit multiplies by screen scale, so 200 pt was a 3x image (~3 MB decoded). [WK] `WKWebView.mm`; [FF#35962].
- **`window.close()` only closes script-opened tabs** (`openerID != nil`). [DDG] `TabViewController.webViewDidClose`.
- **Background downloads** in `BGContinuedProcessingTask` or a background task. [Brave] `DownloadBackgroundTaskScheduler.swift`.

### Keep
- One warm `about:blank` web view after the first frame, handed to the first tab; WebKit prewarms the rest. [WK] `WebProcessPool.cpp`.
- One `WKUserContentController` per web view; compiled rule lists are shared memory.
- One shared data store and configuration values; no `WKProcessPool`.
- Lazy tabs: no web view until a tab is shown.
- One state file per tab.
- Thumbnail pipeline: capture before removal, JPEG off main, `byPreparingForDisplay`, generation guard, NSCache.
- Synchronous navigation decisions through small rule objects.
- Popups from WebKit's configuration as rate-limited child tabs.
- Crash-loop guard, scoped to real crashes.
- HTTPS upgrade with `.automaticFallbackToHTTP`; JIT on; content mode chosen once per navigation.
- Not adopted: dropping our universal-link check needs a private policy value to suppress app links on restores.

## Shell (chrome, gestures, transitions)

### Change
- **Bottom inset follows the bar's resting state.** A fixed collapsed inset hides fixed-bottom page UI and the document's last lines under the expanded bar. Change `obscuredContentInsets` once at the end of each snap; defer it during the top bounce. [DDG] `TabViewController.swift`, `WebViewScrollViewInsetUpdater.swift`; [Brave] `BrowserViewController.swift`.
- **Swipe preview from a live view or a full-screen snapshot.** A 200 pt thumbnail upscaled for a full-width swipe looks blurry. Use the neighbour's live web view, else a 2x full-screen snapshot kept for the two neighbours only. Slide a snapshot of the glass bar, not live glass. [DDG] `SwipeTabsCoordinator.swift`; [FF] `TabSwipeGestureHandler.swift`.
- **Collapsed pill takes taps only.** It sits in the home-indicator zone, where horizontal and upward swipes belong to the system. Swipes attach to the expanded pill. 9to5mac.com/2025/06/12/iphone-ios-26-safari-new-compact-design/.
- **Custom gallery animator, not `.zoom`.** Tabs are re-parented web views, not pushed controllers, and `.zoom` has known glitches with collection-view sources. Animate snapshots; hide the target cell by tab ID. [FF] `TabAnimation.swift`; developer.apple.com/forums/thread/794923.
- **Interruptible, velocity-aware toolbar snap.** Retarget from the on-screen (presentation) position when a drag starts mid-snap, and use release velocity to pick the target. developer.apple.com/videos/play/wwdc2024/10145/.
- **One Liquid Glass container** for pill and buttons, so they tint as one and can merge on collapse; drop the extra layer shadow; add the system scroll edge effect. developer.apple.com/videos/play/wwdc2025/284/.
- **Swipe up from the expanded bar opens the gallery,** driven by the same animator. [FF] `SwipeUpTabPreviewGestureHandler.swift`.
- **120 Hz is not automatic.** No `CAFrameRateRange` exists yet; add one where a display link drives motion and verify on device with the Animation Hitches trace.

### Keep
- UIKit shell; custom bar moved by transform and alpha only.
- `setMinimumViewportInset(collapsed, maximum: expanded)`; same as Brave and DDG.
- Scroll-delegate-driven collapse; no collapse on short pages or programmatic scrolls.
- Tap on a collapsed bar expands it first (Safari 26).
- Address editing in place, focused with no async hop; search-first launch focus in `viewIsAppearing`.
- One spring vocabulary through `UIView.animate(SwiftUI.Animation)`, with velocity handoff.
- Motion values: no bounce by default, haptics only on threshold and commit.
- Duo vertical bar through navigation-controller toolbar items.

## Blocking, Reader, Storage

### Change
- **Keep old rule lists attached while new ones compile.** Otherwise every list update leaves pages unblocked for ~7 s. Attach the last compiled list with the same name, swap when the new one is ready, then delete the old. [DDG] `LastCompiledRulesStore`, `FailedCompilationsStore`.
- **First launch compiles the high-value list first:** EasyPrivacy network blocks plus EasyList third-party domains. Same-identifier compiles stay sequential (bugs.webkit.org/show_bug.cgi?id=296313).
- **All cosmetic rules in one list.** One display:none sheet per frame instead of four; cosmetic churn recompiles one list. Measure on device before dropping generic selectors. webkit.org/blog/3476/content-blockers-first-look/.
- **Reader check uses only `isProbablyReaderable`** (4 KB) as a user script; the 90 KB Readability parse runs only when the check passes and the tab is visible, or on tap. github.com/mozilla/readability.
- **Storage maintenance.** After Clear History: WAL checkpoint (TRUNCATE) then `VACUUM`, so deleted rows do not linger. Daily: prune old visits, cap history and favicon size, FTS `optimize`, `PRAGMA optimize`. Firefox application-services places maintenance.
- **Suggestion privacy.** Never send URL-like or intranet input to the remote engine; no remote suggestions in private tabs. Firefox bug 1628079; `browser.search.suggest.enabled.private`.
- **Suggestion latency.** Preconnect to the suggestion host on focus; small prefix cache to fill the list while a request is in flight. Chromium `SearchEnginePreconnector`; Mozilla bug 735543.
- **Omnibox ranking.** Site-level top hit ("git" suggests `github.com`, not a deep page); typed visits weigh more than link clicks; remember the suggestion picked for each input. firefox-source-docs.mozilla.org/browser/urlbar/ranking.html.

### Keep
- Build-time list conversion; converter never linked; JSON bundled.
- `<name>-<sha16>` identifiers, lookup first, compile only on a miss, never at launch.
- Per-site off by detaching lists from the tab's own controller (cheaper than Firefox's and DDG's recompile).
- 4 lists of ~34k rules.
- GRDB `DatabasePool` in WAL mode, FTS5 schema split into places and visits.
- Frecency: decayed log-sum with a 30-day half-life, as Firefox uses.
- Batched history writer with one owner.
- Ephemeral suggestion session, cancel on keystroke, no debounce, 1 s timeout.
- Reader in a named `WKContentWorld`, output on a JS-off custom scheme with strict CSP.

## iPhone Duo

### Change
- **Keep the system vertical bar in inner landscape.** The HIG keeps controls on the side through an unfold. Confirm what Safari does on the device. developer.apple.com/design/human-interface-guidelines (Designing for iPhone Duo).
- **Sidebar gets a ~64 pt icon-rail state,** forced during a split or a fold. A 260 pt sidebar leaves ~345 pt per split pane, less than the outer screen. Safari 27.3 ships an icon strip.
- **The 640 pt side-tab gate applies to the space left after the sidebar,** not the window.
- **No custom tabletop layout.** The HIG says to adjust, not rearrange. Only floating controls avoid the fold; WebKit's fullscreen player already handles tabletop video, so that feature is dropped.
- **Pills avoid the fold and the inner camera.** In book pose, shift pills and toasts off the fold region (`reservedRegions(kind: .division)`); read `.occlusion` for the camera.
- **Fold resize from the target size.** Set each web view's final frame once from `viewWillTransition(to:with:)`'s size; apply `obscuredContentInsets` in the completion. No snapshot cover for a fold; WebKit scales tiles itself (developer.apple.com/forums/thread/802660).
- **One focused pane in a split.** Shared bar buttons act on the pane touched last.
- **Per-window state now,** so "Open in New Window" can ship later without a rewrite.
- **`.includeInactive` gives the fold's position only.** A flat fold's division has zero width; use it to pick columns and pill side, not to inset content.
- **Deployment target 27.2.** `UIView.LayoutRegion.bar(onEdge:)` without `extent:` is 27.2+ in the SDK headers.
- **More button needs a non-ellipsis symbol** and visibility priorities so Back, Forward and Tabs overflow last.

### Keep
- Size classes and `verticalBarEdge` for layout; no idiom, `UIScreen` or orientation checks.
- `UIArrangementViewController` for split tabs, sidebar as its sibling, never nested.
- Even 2 or 4 grid columns on the inner screen.
- Outer screen: system vertical bar plus a custom bottom pill.
- Inner portrait: horizontal bars, one pane.
- Same web views through a fold; content mode never switched mid-page.
- No `UIHingeInteraction`, no outer-screen peek.
