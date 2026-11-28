# The side pane's divider: resizing, snapping and take-over (research, 2026-11-28)

The owner (iPhone Duo inner screen and iPad): "I can pull out the Reader pane, but allow me to
resize the split between that pane and the main app, being smart: when the web view is too skinny
to be useful, just snap the Reader to the full view. … it's like when on the Duo I have split apps
and I want one to take over, or the same on desktop OS environments. It should feel natural and
expected."

This file collects what the systems people already know do, what that means users expect, the
behavior Plain chose, and how its cost was measured. The decision is in `docs/decisions.md`, "The
side pane's divider".

## 1. What the platforms do

### iPadOS Split View and Slide Over (iPadOS 15–18)

- Drag the divider to resize; to the middle gives both apps the same space; drag it over an app to
  close that app, and the other takes the whole screen. (Apple Support, "Use multitasking on your
  iPad", https://support.apple.com/102576; iPad User Guide, "Open two items in Split View",
  https://support.apple.com/en-asia/guide/ipad/open-two-items-in-split-view-ipad08c9970c/14.0/ipados)
- The widths are fixed steps, not free: on the 12.9-inch iPad Pro in landscape 1/3, 1/2 and 2/3;
  in portrait no 1/2. The 1/3 side is compact width. (Apple's size-class table, as quoted at
  https://forums.macrumors.com/threads/split-screen-on-11in-pro.2150842)
- Not published by Apple: the steps in points, the handle's touch area, a velocity rule, haptics.

### iPadOS 26 windows and Stage Manager

- Windows resize from any corner (or the bottom-right grabber); a quick flick sends a window to a
  side and tiles it; two tiled windows share a bar in the middle that resizes both. The window
  controls' menu tiles in halves, thirds and quarters. (Apple Support,
  https://support.apple.com/125309; MacStories' iPadOS 26 review,
  https://www.macstories.net/stories/ios-and-ipados-26-the-macstories-review/10)
- `UISplitViewController` columns, the trailing inspector included, can now be resized by dragging
  their separator, between a system minimum and maximum; an inspector becomes a sheet when the
  layout collapses. (WWDC25 "Make your UIKit app more flexible",
  https://developer.apple.com/videos/play/wwdc2025/282/) Plain's side pane follows the inspector's
  rules by hand (docs/decisions.md, "Duo inner screen: the side pane").
- The HIG asks for layouts that hold at narrow, compact and in-between widths, because iPad windows
  resize freely (https://developer.apple.com/design/human-interface-guidelines/split-views).

### iPhone Duo's own split apps, Android and Samsung foldables

The owner's reference behaves like Android's split screen, whose source is public
(`DividerSnapAlgorithm.java`, `DividerView.java`,
https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/libs/WindowManager/Shell/src/com/android/wm/shell/common/split/):

- Rests at 1/3, 1/2 and 2/3 (or 10:90, 50:50 and 90:10 on phones and foldables that allow an app
  off screen), plus a dismiss target at each edge. No free widths by default.
- Release: past the first or last rest and moving outward faster than 600 dp/s, dismiss; slower
  than 400 dp/s, the nearest rest; otherwise the first or last rest in the fling's direction.
- An app's minimum is 220 dp; dragging the divider to the edge closes the app it covers and the
  other takes the screen (https://developer.android.com/develop/ui/views/layout/support-multi-window-mode).
- The handle is a 40 × 4 dp capsule on a 10 dp bar, with an 80 × 48 dp touch region. A double tap on
  the divider is an action of its own.
- The "magnetic" divider plays one light tick when it attaches to a rest, none when it leaves it,
  none at the edge (AOSP commit,
  https://gitlab.e.foundation/e/os/android_frameworks_base/-/commit/1e4861ab8910ff72fcb94e364f66c549c2f08d59;
  whether it ships on is not verified).
- Samsung's One UI: a draggable divider whose tap opens options (swap, save as a pair); 50/50, 75/25
  and 90:10 splits (https://www.samsung.com/in/support/mobile-devices/how-to-master-multitasking-on-galaxy-foldable-devices/,
  https://www.androidauthority.com/one-ui-8-9010-multitasking-split-3561871/). What a drag to the
  edge does there is not verified.
- Material 3's pane expansion: a capsule drag handle; anchors as a share or an offset; on release
  the pane snaps to an anchor; the handle can collapse or expand a pane fully, and a tap switches
  between sizes (https://m3.material.io/foundations/layout/scaffold/panes,
  https://developer.android.com/reference/kotlin/androidx/compose/material3/adaptive/layout/PaneExpansionState).

### macOS

- `NSSplitViewItem.canCollapse`: dragging (or double clicking) the divider collapses a pane; the
  classic rule collapses it once the divider passes halfway between its minimum and zero, and
  brings it back when dragged back past that point (https://developer.apple.com/documentation/appkit/nssplitviewitem;
  Apple's SplitViews sample, https://developer.apple.com/library/archive/samplecode/SplitViews/Listings/ReadMe_md.html).
- SwiftUI's inspector: 225 pt ideal and 400 pt maximum in Apple's example, a 150 pt minimum "at
  which point it will collapse"; a double click on the divider restores the ideal width
  (https://developer.apple.com/documentation/swiftui/view/inspectorcolumnwidth(min:ideal:max:)).
- The HIG: a 1 pt divider; minimums that keep it visible; more than one way back to a hidden pane
  (https://developer.apple.com/design/human-interface-guidelines/split-views).
- Sequoia tiles windows in halves and quarters by dragging to an edge or with Fn-Control-arrow keys,
  and dragging a window out of a tile restores its size
  (https://support.apple.com/guide/mac-help/tile-app-windows-mchl9674d0b0/mac).

### Windows 11 Snap

- Drag the line between snapped windows and both resize; drag to an edge for a half, a corner for
  a quarter, the top to maximize. The layouts offered depend on the display's size
  (https://support.microsoft.com/en-us/windows/snap-your-windows-885a9b1e-a983-a3b1-16cd-c531795e6241).

### Gesture and feedback principles

- WWDC18 "Designing Fluid Interfaces": pick the target nearest where the release velocity would carry
  the content (the projection), not where the finger is; rubber-band at the ends; every motion can
  be caught; momentum earns a slight overshoot (https://developer.apple.com/videos/play/wwdc2018/803/).
- Touch targets: 44 × 44 pt on iOS (https://developer.apple.com/design/human-interface-guidelines/accessibility).
- Haptics: an impact for "a view snaps into place", the selection feel for values that change
  (https://developer.apple.com/design/human-interface-guidelines/playing-haptics). Plain's own
  rules (docs/ui-reference.md, "Haptics") already map these: a tick at a rest passed, the threshold
  where an outcome arms, a tick where it disarms.

### WebKit and a resizing web view

From WebKit's source (`WKWebViewIOS.mm`,
https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/ios/WKWebViewIOS.mm):

- A frame change on a `WKWebView` sends a viewport update to the web content process, which lays
  the page out again. Safari's own live resize (a window scene changing width, not a web view
  inside an unchanged window) scales the old content by `width / startWidth`, waits ~500 ms
  without a change, then snapshots, lays out for real and drops the snapshot at the first commit
  with new content. A divider inside one window doesn't get that for free; the private
  `_beginAnimatedResize` family is off limits.

## 2. What users expect

- **A few rests, not free widths**, about a third, a half and two thirds of the space; a rest shows
  only where both sides stay readable.
- **Past the last rest the side goes:** the pane closes when dragged thin, and the other side takes
  the screen when the page is dragged thin. The line sits about halfway between a side's minimum
  and nothing (macOS); a fast enough throw past the last rest does it without reaching the line
  (Android, 600 dp/s).
- **Velocity counts:** a flick goes on to the next rest; a slow release lands on the nearest rest
  to where it would coast.
- **A visible handle on a hairline** (a short capsule), with a touch area of at least 44 pt.
- **A way back:** the hidden side returns from more than one place (HIG): the divider itself, a
  control, closing the pane.
- **Feedback at the moments:** a light tick at a rest; a firmer bump where letting go would close
  or take over.
- **A double tap** on the divider restores the default width (macOS).

## 3. What Plain does

### Rests and widths (from the pages' span, never the device)

| Rest | Share of the pages | Shows when |
|---|---|---|
| Narrow (the opening width) | 30%, at least 250 pt | always |
| Half | 50% | it leaves the page 375 pt and is 64 pt past Narrow |
| Two Thirds | 66.7% | it leaves the page 375 pt and is 64 pt past Half |

The span is what the sidebar leaves (a rail on the leading side, or a right sidebar on the
trailing side). On the Duo's inner screen (951 pt landscape): Narrow 285, Half 476. Portrait
(669 pt): Narrow (250) alone. A 13-inch iPad in landscape (1366 pt): 410, 683 and 911. A 640 pt
iPad window with a rail: Narrow alone. 375 pt is the narrowest page beside the pane, a split
pane's minimum (the narrowest current iPhone).

Each window keeps one width for Reader, Find and History (switching never moves the page), and it
survives a rotation: Half asked for in portrait shows Narrow and comes back in landscape.

### Lines and releases

- **Close:** the pane at or under 125 pt (half its 250 pt minimum) closes when the finger lifts.
- **Take over:** the page at or under 187.5 pt (half its 375 pt minimum) hands the pane the whole
  span; the page keeps its frame out of sight, so giving it back relayouts nothing.
- **Release:** armed, it does what it armed; outward faster than 600 pt/s past the last rest, it
  closes or takes over without the line; faster than 500 pt/s, the next rest that way; else the rest
  nearest the release projected 0.18 s ahead (the sidebar's projection beside it).
- **In a split** the pane holds the second pane's place: the divider rests on the split line only
  (the split's width is the user's), and still takes over or closes.
- **Partly folded** (book pose) the fold is the divider: no handle, the pane keeps its half.

### The way back from the whole width

The handle sits 22 pt inside the pane's leading edge (a drag right gives the page back); the
header's Show Page button (Full Width beside the page); the handle's menu; the pane's × and Hide
Side Pane, which give the page its full width; anything in the pane that opens the page (a Reader
link, a History row, a Find match) brings it back beside the pane. Closing the pane forgets the
take-over: the next open is beside the page. A relaunch restores both the width and the take-over.

### Feedback, motion and look

- Haptics: `selection` at each rest passed (4 pt of hysteresis; leaving the rest it started on is
  not passing it), `threshold` where closing or taking over arms, `selection` where it disarms
  (10 pt of hysteresis, `ThresholdLatch`), nothing on a release that armed or lands on a rest, `tap`
  for a throw that closes or takes over without having armed. Nothing per frame, nothing from keys,
  the pointer or VoiceOver.
- Motion: the pane's edge tracks the finger 1:1. On release one spring from where it is to where it
  goes, carrying the release velocity (`Motion.sidePaneSettle`, 0.32 s, bounce 0, or 0.1 after a
  flick), frame by frame (`SpringDriver`), so a finger catches it mid-flight. Taking over is the
  same spring, to the span's leading edge; closing is the same spring to the trailing edge. Under
  Reduce Motion each settle is a 0.2 s crossfade.
- Armed: the pane being closed turns see-through (55%); the page about to be covered dims under
  the gallery's ink veil (`Motion.sidePaneArm`). The top bar holds still while the divider moves
  and glides to its new lane (over the page, or across the pane) once, at the rest.
- Handle: a 5 × 40 pt capsule in secondary ink with a 1 pt paper edge, on the existing hairline,
  vertically centered, inside a 44 × 88 pt target; 6 × 44 pt and secondary ink under the pointer;
  6 × 52 pt while dragged; the accent once a line is armed. No glass: it is part of the seam, not a
  floating control.

## 4. Measured: why the web view never resizes per frame

Approach: while the divider moves nothing lays out except the pane's header. The pane's content
keeps its width (`SidePaneController.freezeContent`), the page keeps its frame (the pane slides
over it, or the page's own background, `underPageBackgroundColor`, shows past its edge), and each
side commits once per settle: the growing side when the settle starts (its new part is under the
other side), the shrinking side when it ends. Signposts: `sidePane.drag`, `sidePane.settle`,
`sidePane.commit` ("page", "pane"), `sidePane.width`.

The Debug build measures a drag with `-PlainMeasureDivider` (frame intervals from a display link and
the main thread's work per frame, logged as `[plain-measure] divider …`) and can instead resize the
page's web view every frame with `-PlainDividerLive`, the naive way, for comparison. Numbers from the
simulator runs are in "Results" below.

### Results

iPhone Duo simulator, inner screen unfolded through Device Hub, the capture test's four drags
(slow to Half, on to the whole width, back, a flick), `[plain-measure]` per drag. "Work" is the
main thread's time in the divider's per-frame code (`apply`), p95 and max; the simulator ran at a
60 Hz nominal on a shared, loaded test Mac, so frame counts matter more than absolute times.

| Build | Work p95 (ms) | Work max (ms) | Long frames (> 1.5x) |
|---|---|---|---|
| Bar lane follows the divider, root layout per frame | 3.3 to 4.4 | 4.8 to 8.3 | 1 of 309 |
| Root Duo pass skipped, pane constants per frame | 1.5 to 2.2 | 1.6 to 3.6 | 0 of 322 |
| **Card slid by a transform (shipped)** | **0.14 to 0.27** | 0.3 to 1.6 (the one card layout as a move starts) | 1 of 320 |
| Live: the page's web view resized every frame (`-PlainDividerLive`) | 0.19 to 0.38 | 2.4 to 3.3 | 2 of 322 |

The live row's UI-thread numbers look small because the cost is elsewhere: each frame sends the
web content process a new viewport and it lays the page out again. The frame strips show it: in
the live recording the page's lines re-wrap on every frame of the drag (the text visibly jitters
under the finger); in the shipped one the page holds still while the pane slides over it, then
reflows once at the rest. So the drag stays frozen. Signposts per drag: one `sidePane.drag`, one
`sidePane.settle`, and at most two `sidePane.commit` (the growing side at the start; the page and
the pane together at the rest), never one per frame.

Captures (the lane's scratch folder, not committed): rotation through Device Hub at Half
(landscape Half, portrait Narrow, landscape Half again), the whole width, frame strips of each
phase, and iPad Pro 13-inch shots at each width.

## 5. Edge cases

| Case | Handling | Checked by |
|---|---|---|
| Rotation mid-drag | `windowWillResize` cancels the move; the window's width rides the transition, mapped to the new span | Device Hub rotation shots; unit tests of `rest(for:)` |
| Rotation at a width that doesn't fit | Half asked for in portrait shows Narrow; the request stays, so landscape brings Half back | `innerPortraitRestsAtNarrowOnly`, rotation shots |
| Fold to the outer screen mid-drag | Same as rotation (a size transition); the pane hides on the outer screen as before | `windowWillResize` path |
| Book pose (partly folded) | No divider: the fold divides; a fold's regions changing mid-drag (no size transition) cancels it in the layout pass | `bookPoseHasNoDivider`; review 1 fix |
| Inner portrait | Narrow only (250 pt), take-over and close still work | unit tests |
| iPad sizes | Rests from the span: 13-inch landscape Narrow, Half, Two Thirds; portrait Narrow, Half | `wideIPadWindowsRestAtAllThree`; iPad UI tests and shots |
| Tiny windows (Split View, Stage Manager) | Under 640 pt the pane can't show (as before); at 640 with a rail, Narrow only | unit test at 52...640 |
| Split tabs plus the pane | One rest on the split line; take-over and close work; the split's width is kept | `aSplitRestsOnTheSplitLine` |
| Keyboard up (Find) while resizing | The field keeps the keyboard; the list keeps its matches | `testFindKeepsItsKeyboardWhileTheDividerMoves` |
| Switching Reader, Find, History at a width | One width per window: the page never moves | `testTheWidthStaysWhenTheSectionChangesAndTheMenuSetsIt` |
| Private windows | Same behavior; the width is layout, not history | by design |
| Sidebar rail, Right sidebar, the strip | The span excludes the sidebar; the card is masked to it; the strip stays under the pane | `takingOverBesideARail`; review 3 fix |
| Reduce Motion | Every settle is a 0.2 s crossfade; haptics still play | `Motion.crossfade` path |
| VoiceOver | Adjustable handle, "Side Pane Width", value "Half, 50 percent"; steps Narrow, rests, Full Width; actions Full Width / Show Page, Hide Side Pane; the page under the whole-width pane is hidden from VoiceOver | `testTheHandleIsAdjustableAndSaysTheWidth`, step unit tests |
| Pointer and trackpad (iPad) | A beam held to the seam, the handle grows; a click-drag drags; no haptics | code; recheck after the iPad lane (pointer input events) |
| Hardware keyboard | Control-Command-S, -], -[ | code |
| Fullscreen video, sheets, gallery, search sheet | The divider can't start (`sidePaneDividerMayAct`) | code |
| The page's own sideways scroll | The divider's pan starts only sideways in its 44 pt strip; pans that start there wait for it to fail | code |
| Double tap | Back to Narrow; at Narrow a bump with "nothing there" | `testTheWidthStaysWhen…` |
| Relaunch | Width and take-over come back with the window | `testTheWidthComesBackAfterARelaunch` |
| A release after holding still | No throw: the nearest rest | `testDragRestsAtHalf…` (failed before the fix) |
| A divider close then a reopen | The close finishes; the pane reopens from the edge | review 1 and 3 fixes |
| Gallery with the whole-width pane | The gallery fades in (no page to zoom from) | code |
