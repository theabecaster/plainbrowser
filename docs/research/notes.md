# Research notes (2026-11-26)

These are the key facts from seven research reports, kept for builders. The plan is in `docs/plan.md`. Items marked (unverified) still need a check on the device.

## WebKit

- **iOS 27 `WKWebView` additions:** `load(_ url:)`, `willSubmitForm`/`WKFormInfo`, `mainFrameNavigation`, `WKJSHandle`, `WKContentWorldConfiguration`, `WKHTTPCookieStore.getCookies(for:)`, `globalPrivacyControlEnabled`.
- **`WKProcessPool` is dead.** Since iOS 15 it has no effect, so don't use it.
- **First web view cost:** 47–100+ ms, and the first load can add 100–150 ms while the network process starts. Later web views cost 2–8 ms. Warm one up after the first frame with `about:blank`.
- **Tab restore:**
  - `interactionState` (iOS 15) saves back/forward history and scroll.
  - `fetchData(of: .sessionStorage)` / `restoreData` (iOS 26) save sessionStorage.
  - Gotcha: restored loads count as app-initiated (WebKit bug 232486).
- **Background tabs:** `inactiveSchedulingPolicy = .suspend` (iOS 17).
- **Thumbnails:** `takeSnapshot(configuration:)` with `snapshotWidth` ~200 and `afterScreenUpdates = false`. A full-size snapshot is 70+ MiB. Calling `drawViewHierarchy` repeatedly breaks WKWebView animations.
- **Content rules:**
  - Each `WKContentRuleList` holds at most 150k rules. Use several lists to go beyond that.
  - Compile once, then `lookUpContentRuleList(forIdentifier:)` with an identifier that includes the content hash.
  - Lists over 45k rules have failed to reload on iOS 18. Test compiles on iOS 27.
- **Toolbar collapse:**
  - The `obscuredContentInsets` setter relayouts the page every time it is set. Set it once, to the collapsed size, and change it only when the bar settles.
  - Animate the bar with transform and alpha only.
  - Call `setMinimumViewportInset(_:maximumViewportInset:)` (iOS 15.5).
  - Never animate the web view's frame, `contentInset` or `additionalSafeAreaInsets`.
  - Drive the bar from a `UIScrollViewDelegate` on `webView.scrollView`, not from KVO.
- **Process termination:** `webViewWebContentProcessDidTerminate` sometimes does not fire. Guard against crash loops.
- **Security mode:** keep `WKWebpagePreferences.securityRestrictionMode = .none`. `.maximizeCompatibility` disables the JIT.
- **Network:** `rel=preconnect` is on and `dns-prefetch` is on (Safari 26+). Speculation rules and `rel=prefetch` are not shipped.
- **Back/forward cache:** on by default.
- **Patching page APIs from a user script:** patch the prototype (`CredentialsContainer.prototype.get`), never the instance (`navigator.credentials.get`). A property set on a DOM wrapper object is lost when JavaScriptCore collects and remakes the wrapper: measured on the simulator, about half of fresh pages had lost it by the time a button was tapped.
- **iOS 27.2:** a device-only `WKWebView` safe-area regression is reported (forum 853762).
- **SwiftUI `WebPage` lacks:** a `createWebViewWith` hook, a `WKDownload` delegate, a media permission callback, `interactionState`, `takeSnapshot` and scroll-view access. This is why we use `WKWebView`.

## Browser edge cases: open-source references

- **firefox-ios (MPL-2.0):**
  - Popups: `BrowserKit/Sources/WebEngine/WKWebview/WKUIHandler.swift`, `PopupThrottler.swift`.
  - Downloads: `Client/Frontend/Browser/DownloadHelper/*`, plus the blob fallback in `DownloadHelper.js`.
  - Auth: `Client/Frontend/Browser/Authenticator.swift`.
  - Session restore: `BrowserKit/Sources/TabDataStore/TabSessionStore.swift`.
  - Reader: `WebEngine/WKWebview/Scripts/ReaderMode/*`.
  - Content blocking: `BrowserKit/Sources/ContentBlockingGenerator/*`.
  - Tab tray: `TabDisplayDiffableDataSource.swift`.
  - Error pages: `Client/Frontend/NativeErrorPage/*`.
  - `SampleBrowser/` is a minimal skeleton.
- **DuckDuckGo `duckduckgo/apple-browsers` (Apache-2.0, easiest license to reuse):**
  - Navigation middleware: `SharedPackages/BrowserServicesKit/Sources/Navigation/` (`DistributedNavigationDelegate`, `WebKitDownload`).
  - Tabs: `iOS/DuckDuckGo/Tabs/UI/TabViewController.swift`.
  - Downloads: `iOS/DuckDuckGo/Downloads/`.
  - Fire button: `iOS/DuckDuckGo/Fire/`.
  - Cookie banners: `iOS/DuckDuckGo/Autoconsent/`.
  - Web extensions: `iOS/DuckDuckGo/WebExtensions/`.
- **GPL-3.0, read only and never copy:** AdGuard SafariConverterLib.
- **Popups:** when `targetFrame == nil`, `createWebViewWith` must return a web view built from the configuration it passes in. Reusing your own configuration breaks `window.opener`. Keep OAuth popups as child tabs that share the same data store. Close them on `webViewDidClose`.
- **Google sign-in:** Google rejects embedded user agents, so set a Safari-like `applicationNameForUserAgent` ("Version/x Mobile/15E148 Safari/604.1").
- **Downloads:** in `decidePolicyFor navigationResponse`, return `.download` when the response has `Content-Disposition: attachment` or `!canShowMIMEType`. `NavigationAction.shouldPerformDownload` covers `<a download>`.
- **Not possible:** a `beforeunload` hook (no public API) and Web Push in `WKWebView`.
- **Search suggestion endpoints** (all returned 200 on 2026-11-26):
  - `suggestqueries.google.com/complete/search?client=firefox&q=`
  - `duckduckgo.com/ac/?q=&type=list`
  - `search.brave.com/api/suggest?q=`
  - `kagi.com/api/autosuggest?q=`
  - `startpage.com/osuggestions?q=`
  - Bing's `osjson` endpoint is dead.
- **Web-browser entitlement** (`com.apple.developer.web-browser`): needed for default browser, passkeys in `WKWebView` (on iOS no other key), AutoFill's Passwords button on web fields (measured) and service workers. Apple grants it manually. Not available yet. Details and sources: `docs/research/sign-in.md`.

## Motion

- **Info.plist:** `CADisableMinimumFrameDurationOnPhone = true` is required for 120 Hz.
- **Frame rate:** request `CAFrameRateRange(80,120,120)` for big motion only.
- **Spring bridge:** `UIView.animate(_ animation: SwiftUI.Animation)` (iOS 18). On gesture `.changed` call `.interactiveSpring`; on `.ended` call `.spring`. The spring then inherits the gesture's velocity.
- **Bounce:** 0 by default. 0.15 is subtle and 0.3 is noticeable. Use bounce only when a flick with momentum drives the motion.
- **Tab open:** `preferredTransition = .zoom` (iOS 18). Its closure must return a stable tab ID, not a view.
- **Liquid Glass:** only on the control layer. Use `GlassEffectContainer`, never glass on glass.
- **Arc complaints to avoid:** flick-up gestures that fight the Home indicator, and swiping right on a tab's first page archiving the tab.

## iPhone Duo (UIKit 27.1, local SDK `iPhoneOS27.2.sdk`)

- **`UIArrangementViewController`:**
  - `setViewController(_:for: .primary/.secondary, animated:)`, `updateArrangement(_:animated:)`, `state(for:)`.
  - `UISplitArrangement.axes(.horizontal)`, with `ViewProperties` `width`/`height` `DimensionRange` (`.fractional`, `.absolute`, `.automatic`, `.intrinsic`).
  - Never put a scroll view, split VC or tab VC inside it, and never put it inside one. A `UINavigationController` around it is fine.
  - It has no delegate. Read `state(for:)` during layout.
- **`reservedRegions(kind: .occlusion | .division, options: .includeInactive)`:** returns `[ReservedRegion]` with `id`, `kind`, `frame`, `margins` and `isActive`. UIKit re-runs `updateConstraints()` when the regions change.
- **Fold behavior:** the fold region is active only when the phone is partially open. Fully open, the inner screen is flat.
- **Vertical bar:**
  - `UITraitCollection.verticalBarEdge` (`.unspecified/.leading/.trailing`).
  - `UIViewController.preferredVerticalBarBehavior` (`.automatic/.disabled`).
  - `UIBarButtonItem.axisBehavior` (`.verticalPreferred`) and `visibilityPriority`.
  - `UIView.LayoutRegion.bar(onEdge:extent:)` with `view.layoutGuide(for:)`.
  - An item with only a custom view never goes vertical.
- **`UIHingeInteraction`:** for hinge-as-input only, never for layout.
- **Size classes:** outer screen is compact/regular. Inner full-width is regular/regular. Inner in Split View is compact width. Pro Max in landscape is regular width with compact height.
- **No device check:** there is no "is Duo" API and no posture value. Never use `UIScreen.main`, idiom or orientation for layout. Use `windowScene.displayLink(target:selector:)` (iOS 27).
- **Fold and unfold:** a trait and bounds change in the same scene. The keyboard, scroll position and video survive.
- **Safari's sizes on the Duo:** outer viewport is 382×580 CSS px, with a ~84 pt system column on the right. Folding fires 2–3 resize events, including a transient 466×498, so ignore transient sizes.
- **Web content can't see the fold:** the Viewport Segments and Device Posture web APIs can't be enabled in `WKWebView`.
- **Simulator:** device type `iPhone Duo` with runtime `iOS-27-2-iPhone19-4`. Set the fold state from the Device Hub buttons (Closed / Partially Open / Open). `simctl` has no command for it; `scripts/duo-fold.sh` presses the buttons through System Events. Never use `screenConfig power`: it crashed SpringBoard in a prior project.
- **Measured on the simulator (M3, 2026-11-26):**
  - Unfolded, the inner screen is 951x669 with the system's vertical bar on the trailing edge (84 pt, status bar inside it): pages get 867 pt. Inner portrait (Device Hub "Rotate Right") is 669x951 with horizontal bars.
  - Fold and unfold call `viewWillTransition(to:with:)` (951x669 to 466x678 and back). Partly opening does not: the size stays, only the reserved regions change.
  - `reservedRegions(kind: .division, options: .includeInactive)` reports the crease as a 40 pt wide region (x 455.5 to 495.5 in the root view) both flat (`isActive` false) and partly open (true), not zero wide.
  - `UIArrangementViewController` is fold-aware: partly open, a split with default sizes puts one view on each side of the division (0-455.5 and 495.5-867). A split with a fixed primary width that crosses the active division hides both views (`state(for:).isHidden`). Alone, the primary view keeps half the width unless its preferred width is `.fractional(1)`, and partly open it is moved to one side of the division (hidden if its width is fixed to the full width): a page that should span the fold must not be in the arrangement.
  - `XCUIApplication.webViews.count` counts several elements per web view; count pages by their content instead.
- **Turning the vertical bar off (2026-11-27):** override `preferredVerticalBarBehavior` to return `.disabled` and call `setNeedsUpdateOfVerticalBarConfiguration()` when it changes; `UINavigationController` forwards the question to its top view controller. Bar content falls back to horizontal bars and the status bar goes horizontal. `traitCollection.verticalBarEdge` still reports the system's edge while the bar is disabled, so "the bar is in use" is `verticalBarEdge != .unspecified && preferredVerticalBarBehavior == .automatic`. The header asks for a stable choice (not per page state); Plain ties it to the size classes only.
- **Top inset on `WKWebView`:** `obscuredContentInsets.top` does not change the scroll view's `contentInset` or `adjustedContentInset` (both stay 0, measured): a page at offset 0 draws its first lines under a top bar. A top bar sets `scrollView.contentInset.top` itself (Plain: the expanded bar's height, fixed while the bar collapses, so the page never jumps), plus the obscured insets for fixed elements.
- **Inner-screen stand-in while Device Hub can't be driven (Mac locked):** `xcrun devicectl device appResize start --device <sim> --preferred-size 951x669` moves the frontmost app into a resizable window on the simulator's "Resizable" display (both size classes regular at 951x669 and 669x951); capture it with `simctl io <sim> screenshot --display=Resizable`. It runs until interrupted. It is not the Duo: no fold, no `verticalBarEdge`, a ~20 pt top safe area in landscape and ~80 pt in portrait, and `reservedRegions(kind: .occlusion)` still reports the outer screen's sensor regions (Debug builds take `-PlainIgnoreOcclusions` for captures). A session sometimes fails to take the app and shows a black frame; start it again.
- **Status zone on the inner screen (2026-11-27):** the device's top safe area is 81 pt in landscape, with the clock and battery ring only in the top-trailing corner (owner's screenshot: x 828–928, y 24–69). The simulator's resizable window reports the inner camera as an occlusion region (`.includeInactive`) at x 884.7–921.7, y 29.3–66.3 in 951x669 (x 602.7 in 669x951), the center of the device's battery ring; its safe area's top is 20 pt in landscape and 82 pt in portrait, and there `edgeInsets(for: .safeArea(cornerAdaptation: .horizontal))` equals the safe area (no corner) and `.margins(cornerAdaptation: .horizontal)` only adds the 20 pt side margins. The window also reports a 200x82 region at x 266 (the outer screen's). The device's values are logged (`duo` category, "status zone").
- **Web view under the status zone:** with a pane at the root view's top, the scroll view's automatic inset adjustment would add the safe area's top to the page's own top inset (not measured; UIKit's documented behavior); a top bar inside the zone sets `contentInsetAdjustmentBehavior = .never` and its own insets, and the portrait window then shows the page at 74 pt under an 82 pt safe area (measured).
- **Simulator screenshots:** `xcrun simctl io booted enumerate`, then `screenshot --display=<id>`.
- **Device screenshots:** `xcrun devicectl device info displays --device <udid>`, then `xcrun devicectl device capture screenshot --device <udid> --destination out.png [--display-unique-id <id>]`.

## Build and performance tooling (verified on Xcode 27.2)

- **Device build:** `xcodebuild -destination id=<UDID> -allowProvisioningUpdates -allowProvisioningDeviceRegistration`.
- **Install and launch:** `xcrun devicectl device install app --device <udid> <app>`, then `devicectl device process launch --terminate-existing --console <bundle id>`.
- **Test results:** `xcrun xcresulttool get test-results summary|tests|metrics --path R.xcresult`.
- **Hitch trace:** `xcrun xctrace record --template 'Animation Hitches' --device <UDID> --time-limit 20s --no-prompt --attach <app> --output t.trace`, then `xctrace export --toc` to find the table schema names.
- **XCTest metrics:** `XCTApplicationLaunchMetric(waitUntilResponsive:)`, `XCTHitchMetric`, `XCTOSSignpostMetric(subsystem:category:name:)`, `XCTOSSignpostMetric.scrollingAndDecelerationMetric`, `XCTMemoryMetric`.
- **MetricKit in iOS 27:** the Swift `MetricManager` replaces `MXMetricManager`. `ScrollHitchTimeMetric` is removed; use `HitchTimeMetric`.
- **Concurrency settings:** `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` for UI modules only. In packages, use tools 6.2 and `.defaultIsolation(MainActor.self)`.
- **Icon Composer CLI:** `/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool <x.icon> --export-image --output-file o.png --platform iOS --rendition Default|Dark|TintedDark --width 1024 --height 1024 --scale 1`.
