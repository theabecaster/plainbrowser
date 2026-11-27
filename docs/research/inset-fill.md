# WebKit's fill in the obscured top inset (iOS 26/27)

Why a band of a site header's color showed behind the Duo inner screen's floating controls at
rest, why the collapse jumped, and what public API can change it. Read in the iPhoneOS 27.2 SDK
headers and in WebKit's source (`Source/WebKit/UIProcess/API/ios/WKWebViewIOS.mm`,
`Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm`, `Source/WebCore/page/LocalFrameView.cpp`,
`main`, 2026-11-27), then measured on the iPhone Duo simulator (iOS 27.2).

## What paints the band

- **The fixed color extension.** With `ENABLE(CONTENT_INSET_BACKGROUND_FILL)` and the
  `contentInsetBackgroundFillEnabled` preference (on in apps, not public), WebKit adds a
  `WKColorExtensionView` ("Fixed color extension fill (Top)") to the web view's scroll view,
  above the content, for each side whose obscured inset is above 0 *and* that has a fixed or
  sticky element on that edge (`_fixedContainerEdges.hasFixedEdge`). It is the element's
  predominant color (`predominantColor`), or the under-page color, and it fills the inset above
  the element. `WKWebView.h` says only that WebKit "adjusts how fixed and sticky elements are
  rendered near edges with non-zero obscured insets". Safari paints the same fill.
- **A fixed element sits at the obscured inset**, not at the web view's edge: the layout viewport
  is the unobscured rect. So with `obscuredContentInsets.top` at the controls' bottom (72.5 pt),
  a fixed header rests under the controls and the 72.5 pt above it is the fill: the band.
- **The jump.** Plain changed the obscured top from 72.5 to 0 when the bar came to rest collapsed
  (`PageInsetState`, once per rest, never per frame). WebKit then moved the header from 72.5 to 0
  and dropped the fill in one frame, after the controls had already gone.
- **Not the scroll edge effect.** The iOS 26 top edge effect (`UIScrollEdgeEffect`, the "pocket")
  is a separate blur; WebKit tints it with the same sampled header color
  (`_setInternalTopPocketColor`). Plain hides it (`hideChromeEdgeEffects`).

## Public knobs

| API | What it does here |
|---|---|
| `obscuredContentInsets` (iOS 26) | The only input to the fill: a side with 0 gets none. Also where fixed elements sit, the page's own scroll origin, and the initial scroll position. Setting it relayouts the page's fixed layout. |
| `setMinimumViewportInset(_:maximumViewportInset:)` (iOS 15.5) | CSS `svh`/`lvh` only. It does not move fixed elements and does not touch the fill. |
| `scrollView.contentInset` | The scroll range. WebKit ignores it for fixed elements and the fill once `obscuredContentInsets` has been set. |
| `contentInsetAdjustmentBehavior`, `additionalSafeAreaInsets` | The safe area feeds WebKit's obscured inset only while `obscuredContentInsets` was never set (`_haveSetObscuredInsets`); Plain sets it (the bottom inset), so no effect. `additionalSafeAreaInsets` also feeds CSS `env(safe-area-inset-*)`. |
| `underPageBackgroundColor` | The overscroll area's color and the fill's fallback color; it does not turn the fill off. |
| Turning the fill off | No public API. `_shouldSuppressTopColorExtensionView`, `_resetObscuredInsets` and `_obscuredInsetEdgesAffectedBySafeArea` are SPI. |

So the only public way to have no band is an obscured top of 0 wherever a header could sit
under the controls.

## The catch with an obscured top of 0, and the fix

- WebKit's page top is the obscured inset. A load's first commit (`_resetContentOffset`), a
  history restore (`_restoreScrollAndZoomStateForTransaction`) and a page's `scrollTo(0, 0)` set
  the scroll view's offset to minus the obscured inset (`_initialContentOffsetForScrollView`
  returns `-_computedContentInset`, which is the obscured inset once one was set). With 0, a page
  loads at offset 0: its first line under the controls. That is why the first try (2026-11-27)
  was reverted.
- Plain keeps the scroll range's start under the expanded bar (`contentInset.top` 72.5) and moves
  a page that WebKit put at exactly its top on to the range's start in the same
  `scrollViewDidScroll` pass (`UIScrollView.keepPageTopUnderBar`), before the frame is drawn.
  Only moves no finger made: tracking, a fling's coast, a bounce and zooming are left alone.

## Measured (simulator, iPhone Duo inner screen, forced status corner)

See docs/decisions.md, "The page's top inset never follows the bar", for the captures.
