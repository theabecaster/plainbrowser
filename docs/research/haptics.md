# Plain: haptics plan

Status: plan only. Written 2026-11-27 against `dev` at `3aeff73` plus the nine `agent/*` lanes in
flight (worktrees under `.claude/worktrees/`). The implementer lands Phase 0 first, then the
surfaces in the order of Phase 1 to 5.

**Bottom line.** Plain already has a `Haptic` enum (`DesignSystem/Haptic.swift`) with 6 kinds and
about 70 calls. Most of the calls are well placed. This plan does five things:

1. Rebuilds `Haptic` on view-attached generators, because the view-less initializers are deprecated.
2. Adds three kinds: `drop`, `failed`, and `threshold` becomes a medium impact.
3. Fixes double-fires and the missing cross-back ticks.
4. Fills about 40 gaps where a confirmation or a denial is missing.
5. Writes the rules down so later lanes keep to them.

It needs no Core Haptics.

---

## 1. Research (sources)

| Fact | Source |
|---|---|
| Use the system patterns only for what their names mean. Use haptics the same way everywhere ("a clear, causal relationship between each haptic and the action that causes it"). Pair haptics with the visual, and "match the intensity and sharpness of a haptic with the intensity and sharpness of the animation it accompanies". Avoid overuse: "the best haptic experience is one that people may not be conscious of, but miss when it's turned off". Prefer short haptics for discrete events. Haptics can disturb the camera, gyroscope and microphone. | [HIG: Playing haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics) |
| iOS has three families. Notification is for "the outcome of a task or action" (success, warning, error). Impact is "a physical metaphor … to complement a visual experience" (light, medium, heavy, rigid, soft). Selection is for "while the values of a UI element are changing". Standard toggles, sliders and pickers already play system haptics. | HIG: Playing haptics, "iOS" |
| "Apple Pencil Pro and some trackpads can provide haptic feedback when connected to certain iPad models." | HIG: Playing haptics, intro |
| `UIFeedbackGenerator.init()` and `UIImpactFeedbackGenerator.init(style:)` are **deprecated**. The current initializers are `init(view:)` and `init(style:view:)`, which attach a generator to a view (iOS 17.5). The methods that take a location are `impactOccurred(intensity:at:)`, `selectionChanged(at:)` and `notificationOccurred(_:at:)`. `UICanvasFeedbackGenerator` is for snapping to guides while drawing. | [UIFeedbackGenerator](https://developer.apple.com/documentation/uikit/uifeedbackgenerator), [UIImpactFeedbackGenerator](https://developer.apple.com/documentation/uikit/uiimpactfeedbackgenerator) |
| `prepare()` keeps the Taptic Engine ready "for a short period of time (typically seconds)". It returns to idle after a fire. "Calling prepare() and then immediately triggering feedback … does not improve latency." Repeated `prepare()` calls without a fire may be ignored "until after you trigger feedback at least once". Let unused generators deallocate. | [UIFeedbackGenerator.prepare()](https://developer.apple.com/documentation/uikit/uifeedbackgenerator/prepare()) |
| SwiftUI `.sensoryFeedback(_:trigger:)` (iOS 17) plays when a trigger value changes. | [sensoryFeedback(_:trigger:)](https://developer.apple.com/documentation/swiftui/view/sensoryfeedback(_:trigger:)) |
| Core Haptics: `CHHapticEngine` plays AHAP patterns built from transient and continuous events, with intensity and sharpness. The engine has to be started and has reset and stop handlers. | WWDC19 "Introducing Core Haptics" (520), WWDC19 "Expanding the Sensory Experience with Core Haptics" (223), WWDC21 "Practice audio haptic design" (10278) |
| Fluid gestures: respond from the first touch, keep the gesture redirectable, use velocity-carrying springs, and use rubber-banding instead of hard stops ("a dead stop reads as a frozen phone"). Haptics mark the moment a gesture crosses into a new outcome. | WWDC18 "Designing Fluid Interfaces" (803). Already in docs/research/tab-drag-feel.md |
| System behaviour Plain inherits: context-menu lift and long-press button menus play their own haptic. Drag lift is the context menu's. A full swipe on a list swipe action plays at its threshold. Pickers, `UISwitch`/`Toggle` and segmented controls are system-owned. Audio recording suppresses haptics unless the app sets `AVAudioSession.setAllowHapticsAndSystemSoundsDuringRecording(true)`. Plain never sets it. | HIG "iOS". [AVAudioSession allowHapticsAndSystemSoundsDuringRecording](https://developer.apple.com/documentation/avfaudio/avaudiosession/setallowhapticsandsystemsoundsduringrecording(_:)) |

How other apps use haptics. Observed in public reviews and in docs/research. Items marked [C] are commonly reported and were not measured here.

- **Safari.** No haptic on reload, back or tab taps. Long-press menus use the system haptic. Swiping along the bar to a new tab and pulling to refresh in the tab overview use the system haptic. [C]
- **Arc Search.** A tick at the tab-close threshold, a soft impact on close, a tick when a dragged card takes a new place (docs/research/arc-tab-switcher.md §191). The intro marks its beats with taps (docs/research/intro.md). Browse for Me starts with a tap. [C]
- **Chrome iOS.** Plays a tick at its pull-down action menu as each option is crossed (new tab, reload, close). [C] This is the clearest precedent for "tick on each threshold, both ways".
- **Things 3.** Haptics on drag pickup, on each reorder slot and on drop. Its "Magic Plus" has a detent where it snaps into a list. [C]
- **Apollo.** Haptics on swipe-action thresholds (both crossing and uncrossing), on upvote, and a success after a post is submitted. Famous for being "abundant yet purposeful". [C]
- **Apple's own apps.** The home-indicator swipe into the app switcher plays a tick when the switcher arms. Slider detents (Control Center brightness at max/min, Camera zoom at 1x/2x) play a detent tick. Mail's swipe actions play at the full-swipe threshold. UIRefreshControl plays one tick at trigger. Wallet, Pay and Home use success on completion. [C]

Five lessons shape the rules in §2:

1. One haptic per discrete event.
2. A threshold haptic both ways.
3. A detent at the meaningful value.
4. Silence during continuous motion.
5. Notification patterns only for outcomes.

### What to avoid (from the sources above)
- A haptic on every tap. A tap whose result is on screen needs nothing.
- A haptic with no visible change. Exception: the result is invisible by nature (Copy Link, a background tab, a refusal), or Reduce Motion removed the motion that would have shown it (§2, rule 9).
- Repeated buzzes: rate-limit denials, and coalesce the same event.
- Haptics during scrolling or momentum: no tick per card while the gallery decelerates, none while chrome collapses.
- Firing out of sync: before the visual reaches the event, or after its spring has settled.

### Accessibility and devices
- **System Haptics** (Settings > Sounds & Haptics) silences every generator. Plain has no switch of its own (`FixedChoices` line 41: "Haptics follow the iOS system setting"). This stays.
- **Reduce Motion does not mute haptics.** docs/plan.md line 150 says "Haptics and motion follow the system's Reduce Motion setting". Change it to "Haptics follow System Haptics; under Reduce Motion they play with the crossfade". With motion reduced, the haptic often carries more of the meaning, not less.
- **VoiceOver.** Outcome haptics (success, failed, nothing there) still play when an action comes from a VoiceOver custom action, such as the bar's swipe actions in the gestures lane. Threshold haptics do not, because no finger is crossing anything. VoiceOver's own sounds handle focus.
- **iPad.** No iPad has a Taptic Engine, so generators are silent there. View-attached generators with a location do play on Apple Pencil Pro, and on haptic trackpads where the system supports it. So Plain **does not gate on `CHHapticEngine.capabilitiesForHardware().supportsHaptics`**. It always calls the generator, which costs nothing when there is no hardware. Pointer hover gets none: the system's pointer effects are the feedback (iPad lane, `DesignSystem/Pointer.swift`).
- **Hardware keyboard.** Key commands play nothing (§2, rule 8).
- **Battery and latency.** A prepared engine draws power for a few seconds. Plain calls `prepare()` only at a gesture's `.began`, or once when a pull passes half its threshold, never on every frame. Generators are made on first use, never at launch (decisions.md line 148).

---

## 2. Principles: Plain's haptic language

Eight kinds. The names stay as they are today, so that in-flight lanes keep compiling. Two new
kinds are added, and one changes its feel.

| Kind | Generator | Meaning | Used for |
|---|---|---|---|
| `.selection` (the **tick**) | `UISelectionFeedbackGenerator` | A value or state changed in place, or a gesture crossed *back* over its threshold | zoom step, reorder slot, toggles, segmented switches (private, profile), un-arming a gesture, find wrap-around |
| `.tap` (the **commit**) | light impact, 1.0 | An action committed whose result is small, off-screen or delayed | background tab opened, download started, Browse for Me started, dictation started, Reopen, the intro mark landing, zoom back to 100% |
| `.threshold` | **medium** impact, 0.7 (was rigid 0.7) | A gesture crossed into a new outcome while the finger is still down, or a custom long press opened its menu | pull to refresh arms, bar swipe arms the next tab or the New Tab card, switcher swipe-up arms, a card passes its close line, sidebar resize crosses rail/expanded, pill long press |
| `.drop` (new) | rigid impact, 0.6 | A dragged item landed in a new place | gallery, strip and sidebar reorder; a tab dropped on another pane |
| `.close` | soft impact, 1.0 | Something went away | tab closed (card, strip, sidebar, x, menu, key command excluded), Close All, profile deleted, pane closed |
| `.success` | notification `.success` | It worked, and the result is invisible or ends a wait | Copy Link, favorite added or removed, Read Later, Save Image, summary done, Clear History done, PDF saved, download finished |
| `.failed` (new) | notification **`.warning`** | A task the user started *and waited for* did not work | download failed, PDF failed, translation failed, summary failed, Try Again failed again |
| `.nothingThere` | soft impact, 0.5, at most one per 1 s | Instant refusal: nothing to do | Back with no history, bump gestures, Return in an empty field, reopen with nothing closed, reader not available, a window can't open |

### Rules
1. **A haptic marks a moment, not a tap.** A plain button press whose result is on screen (Back, Tabs, New Tab, Reload, Share, Done, opening a sheet) plays nothing.
2. **Outcomes after a wait, or invisible outcomes, get success or failed.** Instant visible outcomes get nothing.
3. **One haptic per gesture outcome.** If the gesture already announced its threshold while the finger was down, the release that commits is silent. A flick that commits without ever arming plays the commit haptic once, at release.
4. **Thresholds play both ways.** `.threshold` on crossing into the outcome, `.selection` on crossing back out. Use hysteresis (8–12 pt) so a finger resting on the line never chatters.
5. **Never during scrolling or momentum.** No per-card ticks while the gallery, strip or sidebar decelerates. Nothing during chrome collapse, hide or reveal. Nothing during page scroll. Reorder auto-scroll ticks only when the slot actually changes, and the throttle caps it.
6. **No `.error` and no `.warning` before a choice.** The notification error pattern (three hits) reads as an alarm. Plain's failures are recoverable and always carry a sentence and Try Again, so `.failed` uses the softer warning pattern. Confirmation dialogs (Close All, Clear History, Delete Profile) play nothing when they *appear*. iOS plays nothing for alerts. The haptic comes on the destructive choice's commit.
7. **System controls keep the system's haptic, and Plain never adds a second one.** This covers context menus, long-press button menus, UIMenu pickers, the system find bar, share sheet, swipe actions, list reorder in edit mode, `Toggle`, `Picker` and drag lift.
8. **No haptics from key commands, pointer or hover.** A hardware keyboard means the phone is on a desk or stand. Shortcuts are already validated (`canPerformAction`), so a refused one never fires.
9. **Reduce Motion keeps haptics.** They fire with the crossfade's start. Where nothing moves during a drag (the switcher swipe-up under Reduce Motion), the threshold haptic is the only cue, so it stays.
10. **Not from the background.** Outcomes that finish while the app is inactive, or hidden behind a sheet, play with their toast when the toast appears (`showToastWhenFree`), not when the task ends.
11. **Microphone and camera.** iOS mutes haptics while recording, and Plain keeps it that way: no `allowHapticsAndSystemSoundsDuringRecording`.
12. **Every haptic is listed in the inventory below (§4).** A new call site adds a row to the table that this plan moves into docs/ui-reference.md.

---

## 3. Architecture

### 3.1 The type (`Packages/PlainKit/Sources/DesignSystem/Haptic.swift`, rewritten in place)

DesignSystem is the right module. It is a MainActor leaf above BrowserCore, it already holds
`Haptic`, and every UI module imports it. WebEngine, BrowserCore and Storage never call it.
Engine events reach ShellUI through delegates (`DownloadPresenter`, `onTranslationFailed`), and
the shell plays the haptic, as it does today.

```swift
public enum Haptic: String, Sendable, CaseIterable {
    case selection, tap, threshold, drop, close, success, failed, nothingThere

    /// Plays on the window that holds `view` (located at `point` in `view`'s space, for Apple Pencil
    /// Pro and haptic trackpads). nil view: the foreground key window (today's `play()` callers).
    public func play(in view: UIView? = nil, at point: CGPoint? = nil)
    /// Readies this kind's generator for a fire expected within ~1 s (a gesture's `.began`).
    /// Idempotent per gesture: call it once, not per frame.
    public func prepare(in view: UIView? = nil)

    /// Runs `body` with every haptic suppressed (key commands, VoiceOver custom actions' thresholds,
    /// state restoration).
    public static func withoutFeedback(_ body: () -> Void)

    /// Test hook: every play that passed the throttle, in order. nil in normal runs.
    public static var recorder: ((Haptic) -> Void)?
    /// Timing from `FixedChoices` (set once at scene connect; defaults equal the FixedChoices values).
    public static func configure(_ timing: Timing)
    public struct Timing: Sendable { var minimumGap: TimeInterval; var nothingThereGap: TimeInterval }
}
```

Internals:

- **Generators per window, made on first use.** `private final class WindowGenerators` holds up
  to six lazily created generators: selection, light, medium, rigid, soft, notification. Each is
  made with `init(style:view:)` / `init(view:)` and attached to the `UIWindow`. They are kept in
  `NSMapTable<UIWindow, WindowGenerators>.weakToStrongObjects()`, so a closed window releases them.
  One set per window supports iPad multi-window and the Duo's scenes. A location is converted
  from `view` into window space, and `…(at:)` is used only when a point is given.
- **Mapping:** `selection` uses `selectionChanged(at:)`. `tap` uses light at 1.0. `threshold`
  uses medium at 0.7. `drop` uses rigid at 0.6. `close` uses soft at 1.0. `success` uses
  `.success`. `failed` uses `.warning`. `nothingThere` uses soft at 0.5.
- **Throttle (first wins).** A play within `Timing.minimumGap` (60 ms) of the last play is
  dropped. `nothingThere` also keeps its own 1 s gap (today's `nothingThereInterval`). First wins
  because the first haptic is the one synced to the visual. A later one in the same 60 ms is
  always a duplicate of the same event: profile create plays success and then `showList()`'s tick,
  and delete plays close and then the tick. Both are fixed explicitly in §4 as well. The clock is
  `CACurrentMediaTime`, injectable for tests (`static var now`).
- **Gates, all O(1):** inside `withoutFeedback`, nothing plays. When
  `UIApplication.shared.applicationState != .active`, nothing plays (rule 10). Then the recorder
  is called, then the signpost, then the generator.
- **Signpost:** `Signposts.signposter.emitEvent(Signposts.haptic, "\(kind)")`. Add
  `static let haptic: StaticString = "haptic"` in `PerfSignposts/Signposts.swift`. Instruments
  then shows each haptic on the same timeline as the animation intervals (`tabSwipe`,
  `galleryCardClose`, …), which is how timing sync gets verified (§5).
- **Main-thread cost:** one dictionary lookup, one time compare, one signpost emit, and the
  generator call, which is asynchronous to the system. No allocation after the first play per
  window. No disk, no locks.
- **Unsupported hardware:** no gate (see §1). Generators are no-ops without a Taptic Engine. The
  recorder still records, so tests on an iPad simulator assert the same sequence.
- **`prepare()`:** a per-kind flag `isPrepared` is cleared by the next play, or by a 2 s
  timestamp. `prepare` returns early while the flag is set, so callers may call it from `.changed`
  without spamming the engine. Today `trackPull` calls `Haptic.selection.prepare()` on every scroll
  frame past 40 pt, which the docs warn the engine may ignore.
- **Compatibility:** `Haptic.x.play()` with no arguments keeps working. The nine lanes call it,
  and none of them touches `Haptic.swift`. New code passes `in:` (the gesture's view) and `at:`
  (the touch point) where it has them.

### 3.2 Constants (`BrowserCore/FixedChoices.swift`, per AGENTS.md "every value Plain decides")

```swift
// MARK: Haptics (docs/ui-reference.md, "Haptics")
/// Two haptics closer than this are one event: the first, synced to the visual, wins.
public static let hapticMinimumGap: TimeInterval = 0.06
/// A refusal repeated faster than this stays silent, so a held or repeated press never buzzes.
public static let hapticNothingThereGap: TimeInterval = 1
/// Hysteresis on a gesture threshold, so a finger resting on the line never chatters.
public static let hapticThresholdHysteresis: CGFloat = 10
```

DesignSystem cannot import BrowserCore. `Plain/SceneDelegate.swift`, at its first scene connect,
calls `Haptic.configure(.init(minimumGap: FixedChoices.hapticMinimumGap, nothingThereGap: FixedChoices.hapticNothingThereGap))`.
A unit test asserts that the defaults in `Haptic.Timing` equal the FixedChoices values, so the
two never drift.

### 3.3 SwiftUI screens
FeatureUI keeps calling `Haptic.x.play()` from action closures, as `Style.swift`'s `copyLink`
does. **No `.sensoryFeedback`.** It cannot be throttled, recorded or attached to a window, and it
would split the vocabulary in two. The exception is a system control that plays its own haptic,
such as `Picker` and `Toggle`: add nothing there.

### 3.4 Core Haptics: not needed
No surface is clearly better with a custom pattern:

- **Pull to refresh.** One tick at arm is the iOS idiom (UIRefreshControl). A custom
  "charge-up" continuous pattern while pulling would be a long-running haptic during a scroll,
  which rule 5 and the HIG both advise against.
- **Launch splash.** decisions.md line 2351 already settles this: "No haptic, no sound: it plays
  on every cold launch". Agreed.
- **Intro mark landing.** A single `.tap` on landing is enough.

Cost of Core Haptics: `CHHapticEngine` start latency, audio-session interplay with page media
(WKWebView video), reset and stop handling, and AHAP assets. Revisit only if the owner asks for a
signature pattern, for example at the end of the intro.

---

## 4. Inventory

Columns: interaction | haptic | exact moment | strength | where (file, function) | lane.

- In the haptic column: **keep** means the call exists and is correct. **change** means it exists
  and changes. **add** means it is new. **none** gives the reason.
- Paths are relative to `Packages/PlainKit/Sources/`. "BVC" is `ShellUI/BrowserViewController`.
- Lane codes:
  - G: gestures (`agent-ac7e5a8ace90c9956`, uncommitted)
  - C: card close (`agent-ac75458666e452f23`)
  - S: Duo strip and sidebar (`agent-a3525164db74ab84f`)
  - B: Duo inner top band (`agent-a7c409ded60866e65`)
  - P: private mode (`agent-ab1ffe987cc698e73`)
  - A: Arc search sheet (`agent-a86bb2517a3c0ff45`)
  - I: iPad (`agent-a8902763908a3690d`)
  - F: performance (`agent-a2c3f09790372cad3`, uncommitted)
  - K: clarity (`agent-ad1d8f15149545ac9`)

### 4.1 Bottom bar and pill (outer screen and phones)

| Interaction | Haptic | Exact moment | Strength | Where | Lane |
|---|---|---|---|---|---|
| Tap Back / Forward with history | none: the page changes | — | — | `BVC.swift` `goBack`/`goForward` | G edits |
| Back / Forward with nothing there (dimmed button, page sheet, edge swipe) | keep `.nothingThere` | on the tap | soft 0.5, rate-limited | `BVC.swift` `goBack`, `goForward` | G edits these functions (makes them internal). Leave them as they are |
| Back on a link-opened tab's first page (closes to opener) | none: the slide-off is the feedback, and it is navigation, not a close | — | — | `BVC+Tab.swift` `performBack` | — |
| Long-press Back / Forward (history list) | none of ours: system menu | — | system | G `BVC+Gestures.swift` `updateHistoryMenus` | G |
| Tap Tabs with a switcher card | none: the gallery zooms | — | — | `BVC+Tabs.swift` tabs tap | — |
| Tap Tabs when the slot is hidden (empty tab alone) | keep `.nothingThere` | on the tap | soft 0.5 | `BVC+Tabs.swift` `case .hidden` | — |
| Long-press Tabs (tab menu) | none of ours: system button menu | — | system | `BVC+Tabs.swift` | — |
| Tap More (page sheet opens) | none: the sheet rises | — | — | `BVC.swift` `showPageSheet` | — |
| Long-press the pill (page sheet) | **change** `.threshold` (now medium 0.7, was rigid). Pass `in: pill, at: press.location(in: pill)` | `press.state == .began`, the frame the sheet starts rising | medium 0.7 | `ShellUI/AddressPill.swift` `pressed(_:)` | A, S, B, P, K all edit AddressPill. Do it in Phase 4 |
| Tap the pill (search opens) | none: the sheet morphs | — | — | `BVC.swift` `pillTapped` | — |
| Tap the collapsed pill or bottom edge (chrome reveal) | none: the bar springs back (rule 5) | — | — | `BVC.swift` `revealEdgeTapped` | — |
| Chrome collapse / hide / reveal while scrolling | none (rule 5) | — | — | `BVC.swift` scroll handling | — |
| Status-bar tap to top | none: system scroll-to-top | — | — | — | G |
| Bar swipe sideways: finger crosses half the width toward a neighbour | **change** `.threshold` (was `.selection`) | the `.changed` frame where `abs(offset) > width/2` first holds, after the transform is applied | medium 0.7 | `ShellUI/TabSwipe.swift` `track(_:)` (the `if armed, !swipe.isArmed` line) | — |
| …crosses back under half | **add** `.selection` | the first frame where `abs(offset) < width/2 − hysteresis` | tick | `TabSwipe.swift` `track(_:)` | — |
| …release commits to the neighbour | **change**: `.selection` only if `!swipe.isArmed` (a flick that never armed). Otherwise silent (rule 3) | at `finish(at:)`, when the spring starts | tick | `TabSwipe.swift` `finish(at:)` | — |
| Swipe past the last tab: the New Tab card reaches `newTabSwipeThreshold` | **change** `.threshold` (was `.selection`, shared line) | the frame it reaches 80 pt | medium 0.7 | `TabSwipe.swift` `track(_:)` | — |
| …pulled back under the threshold | **add** `.selection` | under 80 − 10 pt | tick | `TabSwipe.swift` `track(_:)` | — |
| …release opens a new tab | **change**: `.tap` only if it never armed. Otherwise silent | at `finish(at:)` | light | `TabSwipe.swift` `finish(at:)` | — |
| Sideways swipe with no neighbour and no New Tab card (edge denial) | keep `.nothingThere` | on release, as the rubber band springs back | soft 0.5 | `TabSwipe.swift` `finish(at:)` else-branch | — |
| Sideways swipe when bar swiping is off (bump) | keep `.nothingThere` (prepare at begin) | on release | soft 0.5 | `TabSwipe.swift` `beginBump`/`releaseBump` | — |
| Swipe up from the bar: progress crosses `SwitcherSwipe.commit` (the gallery will open on release) | **add** `.threshold` | the `.changed` frame where `progress > commit` first holds | medium 0.7 | `TabSwipe.swift` `trackGallery(_:)`, using `transition.track(...)`'s returned progress against a new `public static var TabGalleryTransition.commitProgress` (wraps `SwitcherSwipe.commit`) | — |
| …falls back under commit | **add** `.selection` | `progress < commit − 0.03` | tick | `TabSwipe.swift` `trackGallery(_:)` | — |
| …release opens the gallery | none if armed. `.tap` if a flick opened it without arming | at `releaseGallery` when `opens` | light | `TabSwipe.swift` `releaseGallery(velocity:)` | — |
| Swipe up with nothing to show (bump) | keep `.nothingThere` | on release | soft 0.5 | `TabSwipe.swift` `releaseBump` | — |
| Pull to refresh: arms at 80 pt | **change** `.threshold` (was `.selection`). The G lane's PullIndicator doc already says "a light haptic, from the shell" when it fills with Lagoon, which matches the arm moment | the scroll frame `PullToRefreshTracker.pulled` returns `.armed` | medium 0.7 | `BVC.swift` `trackPull(_:)` | G edits `refresh()`/indicator. Coordinate: G owns the file until it merges |
| …disarms (pulled back) | **add** `.selection`, and add hysteresis in `PullToRefreshTracker.pulled` (disarm under `threshold − FixedChoices.hapticThresholdHysteresis`) | `.disarmed` | tick | `BVC.swift` `trackPull`, `ShellUI/ChromeModel.swift` `PullToRefreshTracker` | G |
| …release while armed (reload starts) | none: already announced (rule 3) | — | — | `BVC.swift` `refresh()` | G |
| …prepare | **change**: prepare `.threshold` once when the pull passes 40 pt (the flag in §3.1 makes the per-frame call cheap) | — | — | `BVC.swift` `trackPull` | G |
| Edge swipe from the leading or trailing edge (back, forward, side pane) | none: WebKit's or the system's interactive pop. The page follows the finger | — | — | G `BVC+Gestures.swift` | G |
| Pinch in to the overview (inner screen) | none: the gallery zoom is the event, and a pinch is continuous | — | — | G `PinchToOverview.pinched` | G |

### 4.2 Page sheet (More)

| Interaction | Haptic | Exact moment | Strength | Where | Lane |
|---|---|---|---|---|---|
| Sheet presents, reaches its detent, swipe-down dismiss | none: system sheets play none | — | — | `ShellUI/PageSheet.swift` | — |
| Copy Link (address row) | keep `.success`. The check-mark swap is small, and the result is invisible | on the tap, with the check-mark swap | success | `ShellUI/BVC+AddressFocus.swift` `copyPageAddress` | — |
| Copy Link with no address | keep `.nothingThere` | on the tap | soft | same | — |
| Reload | none: progress shows, and Safari plays none | — | — | `BVC.swift` reload action → `BVC+Tab.swift` `reloadPage` | — |
| Stop | none: the progress bar stops | — | — | `BVC.swift` stop action | K edits icon |
| Back / Forward in the address row | as §4.1 | — | — | `pageSheet.back/forward` | — |
| Find on Page | none: the find bar or side pane opens | — | — | `BVC+Tab.swift` `findOnPage` | — |
| Show Reader | none: the reader slides in | — | — | `BVC+Tab.swift` `openReader` | — |
| Show Reader, but no article was found | keep `.nothingThere` | when extraction returns nil | soft | `BVC+Tab.swift` `openReader` | — |
| Hide Reader | none | — | — | `BVC+Tab.swift` `readerMenuItems` | — |
| Summarize Page | none: the summary sheet opens. Its outcome is in §4.8 | — | — | `BVC+Summaries.swift` `summarizePage` | — |
| Translate Page | none at start ("Translating…" shows) | — | — | `BVC+PageFeatures.swift` `translateMenuItems` | — |
| Translation finished | none: the whole page visibly changes | — | — | — | — |
| Translation failed | **change** `.failed` (was `.nothingThere`): the user waited | with the toast ("This page couldn't be translated"), inside `showToastWhenFree` | warning | `BVC.swift` `onTranslationFailed` closure (line ~233) | K, G, F, S, B, A edit BVC.swift. Phase 4 |
| Show Original | none: the page reverts visibly | — | — | `BVC+PageFeatures.swift` | — |
| Share | none: share sheet | — | system | `BVC.swift` `share(from:)` | — |
| Add to Favorites / Remove from Favorites | keep `.success` both ways. The sheet's star changes only after the async save, and the sheet is usually gone | when `data.setFavorite` returns true | success | `BVC.swift` `setFavorite` | — |
| Favorite save failed | keep `.nothingThere`. Leave it: storage failure is near-impossible and instant | when it returns false | soft | same | — |
| Read Later saved / removed | keep `.success` / `.nothingThere` | after `data.saveForLater` | success | `ShellUI/BVC+ReadingList.swift` `saveForLater`, `removeFromReadingList` | — |
| Site Settings: Desktop Site, Blocking, Cookie Banner Blocking, Dark Pages toggles | **add** `.selection`. A state flipped, and the menu is gone before the reload shows | in the action handler, before `tab.reload()` | tick | `BVC+Tab.swift` `siteMenuItems` (desktop and blocking closures), `cookieBannerMenuItems`; `ShellUI/BVC+Appearance.swift` dark-pages action | K edits `BVC+Tab.swift` and `+Appearance` (names). Phase 4 |
| Site permission allow/deny (Location, Camera …) | keep `.selection` | on the change | tick | `ShellUI/BVC+SystemAccess.swift` permission menu | K edits. Leave the line |
| Zoom Out / Zoom In step | **add** `.selection` | in the action, after `tab.zoomIn()/zoomOut()`, as the percentage redraws (`PageSheet.perform` → `reload()`) | tick | `BVC+PageFeatures.swift` `zoomActions(for:)` closures | — |
| Zoom step that lands on 100% (the detent) | **add** `.tap` instead of the tick | the step whose result is `PageZoom.actualSize` | light | same. Compare `tab.zoomPercent == 100` after the step | — |
| Tap the percentage (back to 100%) | **add** `.tap` (the same detent) | on the tap | light | same, `percent` action | — |
| Zoom at the limit (50% or 300%) | none: the button is disabled (`canZoomOut`/`canZoomIn`), so no tap arrives. The step that *reaches* a limit ticks like any step | — | — | — | — |
| Save PDF to Files (PDF page) | **add** `.success` when the file lands in Downloads, through the download path (`downloadDidFinish`) | see §4.9 | — | — | — |
| Print / Save as PDF with nothing to export | keep `.nothingThere` | on the tap | soft | `BVC+PageFeatures.swift` `printPage`, `saveAsPDF` | — |
| Save as PDF failed | **change** `.failed` (was `.nothingThere`): it took time | with the toast | warning | `BVC+PageFeatures.swift` `saveAsPDF` | — |
| Save as PDF ready (share sheet opens) | none: the share sheet is the result | — | — | — | — |
| Open in Other Pane / Swap Panes | none: the layout visibly changes | — | — | `BVC+Panes.swift` `openInOtherPane`, `swapPanes` | S (4 lines) |
| Close Pane | **add** `.close`: a pane goes away, which counts as a close | on the tap, as the pane starts leaving | soft | `BVC+Panes.swift` `closeFocusedPane` | S |
| Show / Hide Side Pane | none: big visible change | — | — | `BVC+SidePane.swift` | G edits |
| Show Side Pane when unavailable | keep `.nothingThere` | — | soft | `BVC+SidePane.swift` `openSidePane` | G |
| Downloads, History, Settings, Reading List, Edit Favorites | none: a sheet opens | — | — | — | — |
| New Window | none: the system opens it | — | system | `BVC+Windows.swift` | I |
| New Window refused, "That window is gone" | keep `.nothingThere` | — | soft | `BVC+Windows.swift` `openNewWindow`, other-windows menu | I |

### 4.3 Search sheet and address field

| Interaction | Haptic | Exact moment | Strength | Where | Lane |
|---|---|---|---|---|---|
| Field focus / sheet morph | none (plan.md motion table) | — | — | `BVC.swift` `beginAddressEditing` | A |
| Typing, suggestions changing | none (rule 5, and the keyboard clicks) | — | — | — | — |
| Return with a query (search or load) | none: the page loads | — | — | `BVC.swift` `textFieldShouldReturn` | A |
| Return in an empty or unusable field | keep `.nothingThere` | on Return | soft | `BVC.swift` (line ~687) | A |
| Tap a suggestion, favorite tile, history row | none: it opens | — | — | `BVC.swift` `open(_ pick:)` | A |
| "Copied link" row: paste-and-go with no URL on the pasteboard | keep `.nothingThere` | — | soft | `BVC+AddressFocus.swift` `handleFocusPick` | A |
| The field's Copy glyph (page's own address) | keep `.success` (via `copyPageAddress`) | on the tap, with the glyph's check | success | `AddressPill` `onCopy` | A, K |
| Microphone: start / stop dictation | keep `.tap` (A lane). Starting the microphone is a commit with a small glyph change. iOS then mutes haptics while recording (rule 11), so stop rarely plays. Fine | on the tap | light | A `BVC+SearchSheet.swift` `toggleDictation` | A |
| Browse for Me arm / disarm in the field | keep `.selection` (A lane): a toggle | on the tap | tick | A `toggleBrowseArmed` | A |
| Swipe the search sheet down to close | **change** in A: remove `Haptic.selection.play()` on collapse. Sheets close silently (system parity, rule 1) | — | — | A `BVC+SearchSheet.swift` pan `.ended` | A. Ask A to drop it before merge, or remove in Phase 4 |
| Edit Favorites (menu) | none: sheet | — | — | `ShellUI/SearchSheet.swift` | A |
| Favorite tile long press | none of ours: context menu | — | system | `SearchSheet.swift` | A, S |

### 4.4 Tab gallery (switcher)

| Interaction | Haptic | Exact moment | Strength | Where | Lane |
|---|---|---|---|---|---|
| Gallery opens (button or swipe) | none: the zoom | — | — | `BVC+Gallery.swift` `presentGallery` | — |
| Tap a card (open) / Done / empty space / swipe up on empty space | none: the zoom back | — | — | `TabGalleryUI/TabGalleryViewController.swift` `open`, `done`, `backgroundTapped`, `backgroundSwiped` | P, C edit this file |
| Scroll and snap between cards | none (rule 5) | — | — | `scrollViewWillEndDragging` | — |
| Lift a card (finger down, axis locks) | none: the card moves 1:1 with the finger. Keep `Haptic.close.prepare()` and also prepare `.threshold` | `.began` | — | `TabGalleryUI/CardDrag.swift` `handle(_:)` | — |
| Card lifted past the close line (−40% of its height) | **add** `.threshold` | the `.changed` frame where `offset ≤ −closeFraction·height` first holds | medium 0.7 | `CardDrag.swift` `handle(_:)` `.changed`. Add `private var isArmed` and compare `CardSwipe.closeFraction * closeHeight()` | — |
| …dragged back under the line | **add** `.selection` | above the line by the hysteresis | tick | `CardDrag.swift` | — |
| Release closes the tab (flick or past the line) | keep `.close` in `closeTab` as the commit, played as the card starts flying. Rule 3 exception: a close is the tab *going away*, a different event from "will close". Arc plays both. Keep both, because they are ≥ 150 ms apart in practice. The 60 ms throttle protects a fast flick that arms and releases at once | `closeTab(_:)` start, the frame `depart` begins | soft 1.0 | `TabGalleryViewController.swift` `closeTab(_:)` | C, P edit. The line already exists, no edit needed |
| Release short of the line (card springs back) | none if never armed. `.selection` was already played on un-arming | — | — | `CardDrag.release` | — |
| Drag a card *down* (rubber-band, never closes) | none: no request was made. A rubber band is self-evident | — | — | `CardDrag.offset(for:)` | — |
| Card that cannot close (future: pinned with close locked) | **rule**: rubber-band up as well, with `.nothingThere` on release. No such card exists today | release | soft 0.5 | `CardDrag` + `onClose` guard | — |
| Card close button (x) | `.close` comes for free: C routes the x through `closeTab`. Add nothing | on the tap | soft | C `TabCardView.swift` | C |
| Long-press a card (context menu) | none of ours: system lift | — | system | `contextMenuInteraction` | — |
| Card menu: Copy Link | keep `.success` | — | success | `TabGalleryViewController.swift` `cardMenu(for:)` | P, C |
| Card menu: Share, Open in Other Pane | none | — | — | same | — |
| Drag to reorder: pickup | none of ours: the context menu lift already played the system haptic (rule 7) | — | system | `TabGalleryReorder.swift` `sessionWillBegin` | — |
| …the dragged card takes a new slot | keep `.selection`, now `in: view, at: location`. The throttle caps auto-scroll at 900 pt/s | `moveReorder(toward:)` when `target != current.slot` | tick | `TabGalleryUI/TabGalleryReorder.swift` `moveReorder(toward:)` | — |
| …drop in a new place | **add** `.drop` | `dropInteraction(_:performDrop:)`, after `moveTab`: the cards already stand in their places, so release is the landing | rigid 0.6 | `TabGalleryReorder.swift` `performDrop` | — |
| …drop back where it started, or cancel | none: the preview flies home | — | — | `TabGalleryReorder.swift` `didEndWith` | — |
| "+" New Tab | none: search opens | — | — | `newTab()` | — |
| Private / regular switch | keep `.selection` (a segmented choice). P changes it to `showPrivate(_:)` and keeps the tick, with a guard against same-side taps. Good | on the switch | tick | `TabGalleryViewController.swift` `togglePrivate` / P `showPrivate` | P |
| Profile switch (gallery menu) | keep `.selection` through `showList()`, but **add a parameter** `showList(tick: Bool = true)` so create and delete pass `false` | on the crossfade start | tick | `TabGalleryViewController.swift` `showList()`; `BVC+Profiles.swift` `showProfile`, `deleteProfile` | P, K edit `+Profiles`. Phase 4 |
| Reopen Closed Tab (gallery menu or toast) | **add** `.tap`: the card reappears off to one side, and a toast-button press has no other confirmation | after `reloadTabs`, as `scrollToTab` starts | light | `TabGalleryViewController.swift` `reopenClosedTab(offered:)` | P, C |
| Reopen with nothing to reopen | keep `.nothingThere` | — | soft | `BVC+Gallery.swift` `galleryReopen` | — |
| Close All Tabs: the action sheet appears | none (rule 6) | — | — | `confirmCloseAll` | — |
| Close All Tabs: confirmed | **add** `.close`, once, not per tab | in the destructive action, before `closeAllTabs()` | soft | `TabGalleryViewController.swift` `confirmCloseAll(from:)` | P, C |
| Close All from the bar's tab menu (G) | **add** `.close` once | G `closeAllTabs(private:)` start | soft | G `BVC+Gestures.swift` `closeAllTabs` | G |
| Archived Tabs, New Profile… | none: sheets | — | — | `galleryMenuItems` | — |
| Last tab closed → search | none beyond the close | — | — | `leaveEmpty` | — |

### 4.5 Strip, sidebar and Duo layouts

| Interaction | Haptic | Exact moment | Strength | Where | Lane |
|---|---|---|---|---|---|
| Tap a strip or sidebar tab | none: the page changes | — | — | `TabStripViewController.didSelect…`, `SideTabsViewController.didSelect…` | S |
| Close via the strip or sidebar x | keep `.close` | on the tap | soft | `TabGalleryUI/TabStripViewController.swift` `close(_:)`, `TabGalleryUI/SideTabsViewController.swift` `close(_:)` | S |
| Strip / sidebar reorder: pickup | none of ours: system drag lift | — | system | `collectionView(_:itemsForBeginning…)` | S, I |
| …destination index changes | **add** `.selection` | `collectionView(_:dropSessionDidUpdate:withDestinationIndexPath:)` when the index path differs from the last one | tick | `TabStripViewController.swift`, `SideTabsViewController.swift` drop delegate | S |
| …drop | **add** `.drop` | `didReorder(_:)` (diffable reorder transaction) | rigid 0.6 | `SideTabsViewController.swift` `didReorder`, strip equivalent | S |
| Link or tab dropped on the strip or sidebar (opens a tab) | **add** `.drop` | in the drop handler | rigid 0.6 | I `TabDrag.swift`, strip and sidebar drop | I |
| Sidebar resize drag crosses rail ↔ titles | **add** `.threshold` into expanded, `.selection` back to rail. Key it to the existing `showsTitles` flip | `sidebarResized` `.changed`, when `duo.sidebar?.showsTitles` changes value | medium / tick | `ShellUI/BVC+SideTabs.swift` `sidebarResized` | S |
| Sidebar resize release / flick to a state | none: the spring settles where already announced. A flick that changes state without crossing: `.tap` | `.ended` | light | same | S |
| Sidebar titles toggle button (S) | keep S's `.selection`: a toggle | — | tick | S `onToggleTitles` | S |
| Portrait drawer opens / closes (S) | none: sheet-like | — | — | S | S |
| Strip appears with the 2nd tab / leaves | none: automatic, not user-caused | — | — | S | S |
| Split pane created (Open in Other Pane) | none: the layout change is the feedback | — | — | `BVC+Panes.swift` | — |
| Focus a pane (tap the other pane) | none | — | — | `paneTouched` | — |
| Fold / unfold, rotation, window resize | none (plan.md motion table): not user-caused in-app | — | — | `windowWillResize` | — |
| Top glass band changes state (B) | none: tied to scroll | — | — | B `TopBand.swift` | B |

### 4.6 Side pane (Duo inner screen)

| Interaction | Haptic | Exact moment | Strength | Where | Lane |
|---|---|---|---|---|---|
| Section picker (Reader / Find / History) | none of ours: `UISegmentedControl` | — | system | `ShellUI/SidePane.swift` | — |
| Find: typing, results update | none (rule 5) | — | — | `SidePane.swift` `queryChanged`, `search` | — |
| Find: Return goes to the next match | none per step: the row highlights and the page scrolls | — | — | `textFieldShouldReturn` | — |
| Find: Return wraps from the last match to the first | **add** `.selection` | when `(current ?? -1) + 1 == result.matches.count` | tick | `SidePane.swift` `textFieldShouldReturn(_:)` | — |
| Find: Return with no matches | **add** `.nothingThere` (today it returns silently) | on Return when `result.matches.isEmpty` and the query isn't empty | soft | same | — |
| Find: a match is gone from the page (reveal failed) | keep `.nothingThere` | — | soft | `SidePane.swift` `reveal(_:)` | — |
| Tap a match row | none | — | — | `didSelectRowAt` | — |
| Close the pane (x) or flick it away | none: visible | — | — | `BVC+SidePane.swift` `closeSidePane` | G |
| System find bar (phones, the reader): next, previous, wrap, no matches | none of ours: `UIFindInteraction` is system UI and exposes no wrap event | — | system | `Tab.beginFind` | — |

### 4.7 Toasts, error pages, permissions, content blocking

| Interaction | Haptic | Exact moment | Strength | Where | Lane |
|---|---|---|---|---|---|
| Toast appears (passive: "Tab closed", "Opened in background", "This page is in French", permission notices) | none by itself. A toast carries the haptic of the event that caused it, if that event has one. Add `ShellToast.show(_:button:haptic: Haptic? = nil,action:)`, which plays the haptic on the frame the toast's animation starts. This is how rule 10 works | `ShellToast.show`, just before `Motion.animate` | per event | `ShellUI/ShellToast.swift` `show` | K, P edit ShellToast. Phase 4 |
| Toast button: Reopen | **add** `.tap` (as gallery reopen) | after `reopenClosed` succeeds | light | `BVC+Tabs.swift` `offerReopen` closure | G, P, F edit `+Tabs`. Phase 4 |
| Toast button: Reopen, nothing to reopen | keep `.nothingThere` | — | soft | same | — |
| Toast button: Show (download, background tab), Translate, Settings | none: the result is visible, or the app is left | — | — | — | — |
| Toast swiped away / timed out | none | — | — | — | — |
| Error page shown after a normal load | none: not user-initiated in the moment, and the page says why | — | — | `BVC+Tab.swift` page-state block | K |
| Error page: Try Again → fails again | **add** `.failed` | when the error page re-shows for the same tab after `tryAgain` (set `engineUI.retryingTab = tab.id` in `tryAgain`, check and clear it where `state.show(.init(message:…))` runs) | warning | `BVC+Tab.swift` load-failure block (lines ~372–390) | K, G, F, B edit `+Tab`. Phase 4 |
| Error page: Try Again → loads | none: the page shows | — | — | same. Clear `retryingTab` on success | — |
| Error page: Open Settings, Reload after crash, Resend form | none: leaves the app or reloads visibly | — | — | same | — |
| "Showing your saved copy" (reading list offline) | none | — | — | `BVC+Tab.swift` line ~608 | — |
| Content blocked, cookie banner rejected | none: automatic and constant. A haptic per page would wear (rule 1) | — | — | ContentBlocking | — |
| Site asks for a permission (system prompt) | none of ours: system alert | — | system | — | — |
| Feature off for Plain (permission toast) | none: passive | — | — | `BVC+SystemAccess.swift` | K |
| Save Image while Photos is off | keep `.nothingThere` (state-rules: the user's own action) | with the notice | soft | `BVC+SystemAccess.swift` `tab(_:wasDenied:)` | K |
| Passkey not available toast (K) | **add** `.nothingThere`: the user's own sign-in action was refused | with the toast | soft | K `BVC+SignIn.swift` | K |
| Invalid address typed | Return → it searches instead (AddressBarInput), so nothing is refused. Only an empty field bumps | — | — | — | — |
| "This address doesn't work" / blocked port error pages | as error page | — | — | — | — |

### 4.8 Link menus, Browse for Me, summaries, Apple Intelligence

| Interaction | Haptic | Exact moment | Strength | Where | Lane |
|---|---|---|---|---|---|
| Long-press a link (preview menu) | none of ours: system context menu | — | system | `WebEngine/TabWebViewHandler.swift` | — |
| Link menu: Open in Background | keep `.tap` + toast. The result is invisible | on the action | light | `BVC+Tabs.swift` `.backgroundTab` | — |
| Link menu: Copy Link, Copy Image, Save Image succeeded | keep `.success` | `tab(_:didComplete:succeeded:)` | success | `BVC+Tabs.swift` | — |
| Link menu action failed | keep `.nothingThere`. Save Image to Photos failing is instant | same | soft | same | — |
| Link menu: Open in New Tab, Open in Other Pane, Share, Read Later | new tab or pane or share: none. Read Later goes through `saveForLater`: success | — | — | — | — |
| Browse for Me (Return while armed, or the row) | keep `.tap`: it starts a long AI run, which a plain search Return does not | on Return, before the sheet presents | light | `BVC+Summaries.swift` `browseForMe` | I (3 lines) |
| Summary or Browse for Me done | **add** `.success` | the first `apply(progress)` whose `stage == .done`, when the sources list fades in. Only while the sheet is on screen (`summaryUI.screen != nil`) | success | `BVC+Summaries.swift` `startRun` progress closure (compare the previous stage) | I |
| Summary failed (offline, declined, unsupported language, busy, failed) | **add** `.failed` | the first `stage == .failed` | warning | same | I |
| Summary Try Again / Search Instead | none: visible restart, or a page | — | — | `onRetry`, `onSearchInstead` | — |
| Summary source opened in background | keep `.success` | — | success | `openSummarySource` | — |
| Summary cancelled (sheet swiped down) | none | — | — | `summarySheetClosed` | — |
| Apple Intelligence unavailable | none: Summarize and Browse for Me are hidden (state rules). Nothing can be tapped | — | — | `ControlRules` | — |
| Apple Intelligence goes away mid-run | `.failed` through the failed stage above | — | — | — | — |

### 4.9 Downloads

| Interaction | Haptic | Exact moment | Strength | Where | Lane |
|---|---|---|---|---|---|
| Download starts | keep `.tap`: the result is off-screen ("1 in progress" lives in the menu) | `downloadDidStart` | light | `BVC+PageFeatures.swift` `downloadDidStart` | — |
| Download finished | **add** `.success` through the toast (`haptic: .success`), so it plays when the toast shows, not in the background | toast appears | success | `BVC+PageFeatures.swift` `downloadDidChange` `.finished` | — (ShellToast param from Phase 4. Until then, play inside the `showToastWhenFree` closure) |
| Download failed | **change** `.failed` (was `.nothingThere`), through the toast | toast appears | warning | same `.failed` | — |
| Downloads list: Cancel Download | none: the row changes | — | — | `FeatureUI/Downloads.swift` | — |
| Downloads list: Open, Show in Files | none | — | — | same | — |

### 4.10 Feature sheets (SwiftUI)

| Interaction | Haptic | Exact moment | Strength | Where | Lane |
|---|---|---|---|---|---|
| Any sheet: Done, Back, scrolling, detents | none | — | — | `FeatureUI/Style.swift` `sheetTitle` | — |
| Row Copy Link (History, Archive, Reading List) | keep `.success` | — | success | `FeatureUI/Style.swift` `copyLink(_:)` | — |
| History: swipe to delete | none of ours: system swipe action threshold | — | system | `FeatureUI/HistoryView.swift` | — |
| History: context menu Delete | none: the row animates out | — | — | same | — |
| History: Clear Last Hour / Today / All (after its dialog) | **add** `.success` when `HistoryModel.clear` returns: rows vanish, but "All History" can take a moment | after `await clear(_:)` | success | `FeatureUI/HistoryModel.swift` `clear(_:)` | — |
| Reading List: swipe mark read / unread, delete | none of ours: system swipe actions | — | system | `FeatureUI/ReadingListView.swift` | — |
| Archive: open (restore), delete, swipe | none: the sheet closes or the row leaves | — | — | `FeatureUI/ArchiveModel.swift`, `ArchiveView.swift` | — |
| Favorites editor: reorder (edit mode), delete | none of ours: system list editing | — | system | `FeatureUI/FavoritesEditor.swift` | — |
| Favorites editor: Rename confirmed | none: the title changes | — | — | same | — |
| Settings: Tab Layout, Archive Tabs, Appearance pickers | none of ours: system menu picker | — | system | `FeatureUI/SettingsView.swift` | — |
| Settings: Search Engine row picked | **add** `.selection`: the checkmark moves | in `SettingsModel.selectSearchEngine(_:)`, when it changes | tick | `FeatureUI/SettingsModel.swift` | — |
| Settings: Use Custom Engine, valid | **add** `.selection`: a choice was made | `useCustomTemplate()` returns true | tick | same | — |
| Settings: Use Custom Engine, invalid template | **add** `.nothingThere`: the footer says why | returns false | soft | same | — |
| Settings: Clear History and Data (after its dialog) | **add** `.success` | when `clearHistoryAndData()` finishes without error (`isClearing` goes false) | success | `FeatureUI/SettingsModel.swift` `clearHistoryAndData` | — |
| Settings: clear failed (error alert) | none: the alert is the feedback, and alerts play none | — | — | — | — |
| Settings: App Icon picked | **add** `.selection` on the tile. iOS then shows its own alert | the tap, when the choice changes | tick | `FeatureUI/…AppIconView` pick, sharing `IntroModel.pick` | — |
| App Icon refused by the system (reverts) | **add** `.nothingThere` | when `AppIcons.set` returns false | soft | `FeatureUI/Intro/IntroModel.swift` `pick(_:)` and the Settings equivalent | — |
| Site Settings sheet (K) toggles | system `Toggle`: none of ours | — | system | K | K |
| Profiles: create (named) | keep `.success`, and pass `tick: false` to `showList` | after `addProfile` | success | `ShellUI/BVC+Profiles.swift` create closure | P, K |
| Profiles: name taken (Create disabled) | none: the button dims | — | — | `askForProfileName` | — |
| Profiles: rename | none: the name changes | — | — | `renameProfile` | — |
| Profiles: delete (after its alert) | keep `.close`, and pass `tick: false` to `showList` | `deleteProfile` | soft | same | P, K |

### 4.11 Start screen, intro, default browser, launch

| Interaction | Haptic | Exact moment | Strength | Where | Lane |
|---|---|---|---|---|---|
| Launch splash (Metal dive) | none (decisions.md line 2351) | — | — | `FeatureUI/Splash/LaunchSplash.swift` | — |
| Start screen shortcuts (Private Tab, Reopen Tab, Archive) | Private Tab: none (the violet is the change). Reopen Tab: `.tap` via `reopenLastClosed`, **add**. Archive: none | after reopen succeeds | light | `BVC+Tabs.swift` `reopenLastClosed(source:)` | G, P, F. Phase 4 |
| Spin the start-screen mark | none: a toy in continuous momentum (rule 5) | — | — | `TabGalleryUI/MarkView.swift` | P edits `EmptyTabView` |
| New Private Tab (menu, start screen) | none: the bar turns violet | — | — | `BVC+Tabs.swift` `openNewTab(private:)` | P |
| Leave Private (P) | none: the bar changes back | — | — | P | P |
| Intro: the mark assembles and lands | keep `.tap` at `onLanded` | the fold's landing frame | light | `FeatureUI/Intro/IntroViewController.swift` `playSplash` | — |
| Intro: Next, Skip, Not Now | none: the step changes | — | — | `IntroModel.next/skip/finish` | — |
| Intro: icon tile picked | **add** `.selection` | `IntroModel.pick(_:)` when the choice changes | tick | `FeatureUI/Intro/IntroModel.swift` `pick` | — |
| Intro: blocking demo toggle (by user) | keep `.selection` | — | tick | `FeatureUI/Intro/BlockingDemo.swift` `flip` | — |
| Intro: Browse for Me demo replay | keep `.selection`. It is the same control as the blocking toggle, a choice to see it again | — | tick | `FeatureUI/Intro/BrowseForMeDemo.swift` `replay` | — |
| Intro: Turn On Apple Intelligence, Set as Default Browser | none: the app is left for Settings | — | — | `IntroSteps.swift` | — |
| Intro: "Let's Go" (finish, dissolve to search) | **add** `.success`, once in the app's life. It closes the onboarding with the one success that marks a completion (Arc's intro ends on a beat) | when the dissolve starts, `IntroModel.finish()` | success | `FeatureUI/Intro/IntroModel.swift` `finish` (not `skip`) | — |
| Default-browser card: Set as Default / dismiss | none | — | — | `FeatureUI/Intro/DefaultBrowserCard.swift` | — |

### 4.12 Keyboard, pointer, iPad, windows, VoiceOver

| Interaction | Haptic | Exact moment | Strength | Where | Lane |
|---|---|---|---|---|---|
| Any key command (⌘T, ⌘W, ⌘L, ⌘R, ⌘[ ⌘], ⌘⇧T, Escape) | none (rule 8). Wrap `perform(_ shortcut:)` in `Haptic.withoutFeedback { }`. That also silences G's `undoClose` `.nothingThere` and A's ⌘L or Escape paths when a keyboard drives them | — | — | G `BVC+KeyCommands.swift` `perform(_:)`, `performShortcut(_:)`; I `ShellUI/BrowserCommands.swift` | G, I |
| Shake to undo (system Undo alert) → undo close | none: a system alert | — | — | G `registerUndoClose` | G |
| Pointer hover, pointer effects | none: system | — | — | I `DesignSystem/Pointer.swift` | I |
| Trackpad or Apple Pencil Pro (iPad) | location-aware plays come for free from §3.1 (`in:at:`) | — | — | — | I |
| Tab dragged out to a new window (I) | none: the system's drag and new scene | — | system | I `TabDrag.swift` | I |
| VoiceOver custom actions (bar swipe actions in G) | outcome haptics only. Wrap threshold-producing code paths with `withoutFeedback`, or call the commit path directly (G's actions already call `goBack`, `presentGallery`, …, which have no threshold haptics) | — | — | G `updatePillAccessibilityActions` | G |

### 4.13 Counts

**207 interactions** are listed in §4.1–§4.12. 96 of them get a haptic of ours:

- 43 are kept as they are.
- 11 keep a call but change its kind or condition: the tab-swipe arm and New Tab arm (threshold), their release conditions, the pull arm and pull prepare, the pill strength, translation failed, PDF failed, download failed, and the search sheet's swipe-down (removed).
- 39 are new.
- 3 get one through another path: the card x through `closeTab`, an Apple Intelligence loss through the failed stage, and VoiceOver actions through the outcome haptics.

111 get no haptic of ours. Of these, 22 are covered by a system haptic or system UI (rule 7), and
89 have an explicit reason (visible result, scrolling, passive, or not user-caused).

---

## 5. Timing and motion sync

1. **Fire on the frame the visual reaches the event, in the same pass that applies it.** In a
   gesture's `.changed` handler, compute the new offset, apply the transform (`set`, `apply`,
   `track`), *then* test the threshold and play. Never test against the raw finger translation
   before the rubber band or the take-up is applied. The haptic would lead the picture by a frame.
   Use `TabSwipe.displayed(_:)`, `CardDrag.offset(for:)` and the transition's returned progress.
2. **Departures play at the spring's start, arrivals at its landing.**
   - A close, switch or open plays when the spring starts, with the release velocity: the object
     is leaving.
   - A drop or snap plays when the object reaches its place. For the gallery reorder the cards
     already stand there at `performDrop`, so release is the landing. For a future snap whose
     target is far, play when `SpringDriver`'s value first comes within `Signposts.visualSettle`
     of the target. Add `SpringDriver.onArrive` only if such a case appears. None exists today.
   - Never after `completion`. The visible-at-rest tail of Plain's springs is 50–150 ms late.
3. **Async outcomes play with their visual answer, not when the task ends.** A favorite plays when
   the star or list refreshes. A download plays with the toast. A summary plays on the `done`
   frame. If the answer's view is not on screen (a sheet covers it), the outcome rides the toast
   (rule 10).
4. **No haptics during momentum.** Only `isTracking` scroll frames can arm (the pull tracker does
   this already). Nothing is played from `scrollViewDidScroll` during deceleration, from
   `UIUpdateLink` ticks, or from `SpringDriver` frames except as described in item 2.
5. **Prepare at `.began`, not before every play.** `TabSwipe.beginTabSwipe`,
   `TabSwipe.beginBump`, `CardDrag` `.began`, the drag `sessionWillBegin`, `trackPull` once past
   40 pt, and `sidebarResized(.began)` call `prepare()` for the kinds they may play.
6. **Reduce Motion:** play at the crossfade's start (`Motion.crossfade` call site), the same
   moment as the motion it replaces.
7. **Verify with Instruments.** Record a Points of Interest trace with a few swipes. Each `haptic`
   event must sit on the frame where `tabSwipe`'s transform crosses half (offset logged), and
   within 16 ms of `galleryCardClose`'s begin. Add this check to the device checklist.

---

## 6. Testing

### 6.1 Unit tests: `Packages/PlainKit/Tests/DesignSystemTests/HapticTests.swift` (new)
- `recorder` receives `[.threshold, .selection]` for play, play.
- Throttle: two plays inside 60 ms record one, the first. Two plays 61 ms apart record both. Use the injected `Haptic.now`.
- `nothingThere` twice inside 1 s records one, and again after 1 s.
- `withoutFeedback { Haptic.close.play() }` records nothing. Nesting works.
- `prepare()` twice does not reset the flag, and a play clears it (white-box, internal).
- The `Timing` defaults equal `FixedChoices.hapticMinimumGap` / `hapticNothingThereGap`. Put this
  in ShellUITests, which sees both modules.

Logic tests that exist or can be added without UI:
- `PullToRefreshTracker` with hysteresis: arm at 80, no disarm at 75, disarm at 69. Put it in
  `ShellUITests`, alongside today's tracker tests.
- A pure helper `ThresholdLatch` (`DesignSystem`, about 20 lines): `update(value:) -> Haptic?`
  takes a threshold, a hysteresis and a direction, and returns `.threshold` / `.selection` /
  nil. Use it in `TabSwipe.track`, `CardDrag`, `trackGallery`, `trackPull` and `sidebarResized`,
  so the both-ways and hysteresis rule is written once and tested once. Cover it in
  `HapticTests`.
- `TabGalleryUITests`: reorder `moveReorder` across 3 slots records 3 ticks, and `performDrop`
  records `.drop`. This needs the recorder set in the test.

### 6.2 UI tests: the `-PlainHapticLog` launch argument
- In `Plain/SceneDelegate.swift`, next to the isolation marker (line ~648–680): when
  `TestIsolation.isActive` and the arguments contain `-PlainHapticLog`, set `Haptic.recorder` to
  append to a 32-entry ring. It also updates a second hidden accessibility element,
  `plainHapticLog`, whose `accessibilityValue` is `"<count> <kind>,<kind>,…"` with the last 8
  kinds. The count lets a test detect new events.
- In the `PlainUITests/SmokeTests.swift` `IsolatedApplication` helper, add
  `func haptics() -> (count: Int, recent: [String])` and
  `func expectHaptics(_ kinds: [String], after: () -> Void)`.
- New `PlainUITests/HapticsTests.swift` (Smoke plan, with `-PlainHapticLog`):
  1. Bar swipe slowly to the next tab: `threshold`. Then a flick: `selection`.
  2. Swipe past the last tab to the New Tab card: `threshold`, then nothing on release.
  3. Swipe up from the bar to the gallery: `threshold`.
  4. Gallery: lift a card past the line and release: `threshold, close`.
  5. Page sheet zoom: + + then reset: `selection, selection, tap`.
  6. Copy Link: `success`.
  7. Back with no history twice quickly: one `nothingThere`.
  8. Pull to refresh past 80 and back, then past again and release: `threshold, selection, threshold`.
  9. A key command (⌘T, hardware keyboard via `XCUIElement.typeKey`): no new events.
  10. Downloads: the TestServer file finished: `tap`, then `success` when the toast shows.
- The perf gate never passes `-PlainHapticLog`, so the recorder stays nil and perf numbers are untouched.

### 6.3 Manual checklist on the owner's Duo
Turn System Haptics on. Do each item once with Reduce Motion off and once with it on.

**Bar (outer screen)**
- [ ] Slow sideways swipe: one firm tap at half-way, a tick if you go back, silence on release.
- [ ] Fast flick to the next tab: one tick on release, no double.
- [ ] Past the last tab: a firm tap when the New Tab card is fully out, silence when the new tab opens.
- [ ] Sideways swipe on the only tab: one soft bump on release. Repeating it fast does not buzz.
- [ ] Swipe up slowly into the switcher: a firm tap where the page becomes card-sized.
- [ ] Pull to refresh: a firm tap at the arm, a tick when backing off, and no chatter while resting on the line.
- [ ] Long-press the pill: one firm tap as the page sheet rises.

**Page sheet**
- [ ] Zoom + / −: a tick per step, a light tap at 100%.
- [ ] Copy Link: success. Favorite on and off: success each time. Read Later: success.
- [ ] Desktop Site, Blocking: a tick, then the reload.
- [ ] Reload, Stop, Find, Reader, Share: no haptic.

**Gallery**
- [ ] Lift a card past the close line: a firm tap. Back under it: a tick. Release: a soft close.
- [ ] Fast flick close: a single soft close (no firm tap glued to it).
- [ ] Long-press and reorder across three slots: a system lift, three ticks, a rigid drop.
- [ ] Close All: soft once. Reopen: a light tap. Private switch: a tick.
- [ ] Gallery scrolling and snapping: silent.

**Inner screen (unfolded)**
- [ ] Strip and sidebar reorder: ticks and a drop. Sidebar resize: a firm tap at titles, a tick back to the rail.
- [ ] Side pane Find: Return past the last match ticks, and Return with no matches bumps.
- [ ] Close Pane: soft close. Fold and unfold: silent.

**Search**
- [ ] Return in an empty field: a bump. Microphone: a light tap. Browse for Me arm: a tick.
- [ ] Swipe the search sheet down: silent.

**Outcomes**
- [ ] Download a file: a light tap at start, success with the "downloaded" toast.
- [ ] Turn on Airplane Mode, then Try Again on the error page: a warning.
- [ ] Summarize: success when done. A failure (offline): a warning.
- [ ] Clear History: success after the dialog.
- [ ] Intro (`-PlainShowIntro`): a tap when the mark lands, a tick on an icon tile, success on Let's Go.

**Silence checks**
- [ ] Scroll a long page with the chrome collapsing and revealing: nothing.
- [ ] Hardware keyboard shortcuts: nothing.
- [ ] Turn System Haptics off: nothing anywhere.

---

## 7. Phased implementation

Each phase runs `scripts/perf-gate.sh` and the HapticsTests before it lands on `dev`
(AGENTS.md). The implementer works in its own worktree (`wt switch --create agent/haptics-…`).

**Phase 0: the type (no lane conflicts).**
- `DesignSystem/Haptic.swift`: the rewrite from §3.1 (view-attached generators per window,
  `drop`, `failed`, threshold changed to medium, throttle, `withoutFeedback`, `recorder`,
  `configure`, prepare flag), plus `ThresholdLatch`. `Haptic.x.play()` keeps compiling unchanged.
- `PerfSignposts/Signposts.swift`: add `haptic`. The change is additive. Lanes S, A, F and G also
  add lines there, so expect a trivial merge.
- `BrowserCore/FixedChoices.swift`: the three constants. Lanes S, B, A and G add lines too. Additive.
- `Plain/SceneDelegate.swift`: `Haptic.configure`, and the `-PlainHapticLog` marker. Lanes S, B,
  P and I edit this file. Keep the change to a small block next to the isolation marker.
- `Tests/DesignSystemTests/HapticTests.swift`, the `PlainUITests` helper, and `HapticsTests.swift`
  (tests 1–7 can wait for Phases 1–2).
- Docs:
  - `docs/ui-reference.md` line 106: replace it with the §2 table and rules.
  - `docs/plan.md`: line 150 (Reduce Motion) and the Haptic column of the line 171 table.
  - `docs/decisions.md`: a "Haptics" entry. Record the reasons: no Core Haptics, no
    `.sensoryFeedback`, no error pattern, and threshold changed to medium.
  - `docs/state-rules.md`: no change.

**Phase 1: gestures in files no lane touches.**
- `ShellUI/TabSwipe.swift`: arm and un-arm with the latch, release conditions, gallery swipe-up
  threshold. Needs `TabGalleryTransition.commitProgress` (`TabGalleryUI/TabGalleryTransition.swift`,
  untouched by lanes).
- `TabGalleryUI/CardDrag.swift`: close-line latch.
- `TabGalleryUI/TabGalleryReorder.swift`: `in:at:` on ticks, `.drop` on `performDrop`.
- `ShellUI/SidePane.swift`: find wrap and no-match.
- `ShellUI/BVC+PageFeatures.swift`: zoom ticks and detent, download finished (inside the
  `showToastWhenFree` closure for now), download failed and PDF failed changed to `.failed`.
- `ShellUI/BVC+ReadingList.swift`: no change. It is already right.

**Phase 2: SwiftUI and FeatureUI (no lanes).**
- `FeatureUI/SettingsModel.swift`: search engine tick, custom engine tick and bump, clear success.
- `FeatureUI/HistoryModel.swift`: clear success.
- `FeatureUI/Intro/IntroModel.swift`: icon tick and refusal bump, `finish` success.
- The Settings app-icon view's pick shares `IntroModel.pick`'s logic, or gets its own tick and bump.

**Phase 3: after the gallery lanes (P, C) merge.**
- `TabGalleryUI/TabGalleryViewController.swift`: `showList(tick:)`, reopen tap, Close All close.
- `ShellUI/BVC+Profiles.swift`: `tick: false` on create and delete. K also edits this file, so
  do it after K.

**Phase 4: after the shell lanes (G, F, K, A, B, S) merge.** These all edit
`BrowserViewController.swift` and its `+Tab`, `+Tabs`, `+Gallery` and `AddressPill` files.
- `BVC.swift`: `trackPull` threshold and un-arm, prepare-once, hysteresis in `ChromeModel.swift`.
  Translation failed changed to `.failed` through the toast.
- `ShellUI/ShellToast.swift`: the `haptic:` parameter. Move download, translation, PDF and
  passkey outcomes onto it.
- `BVC+Tab.swift`: site toggles tick, Try Again `.failed` (`engineUI.retryingTab`).
- `BVC+Appearance.swift`: dark pages tick.
- `BVC+Tabs.swift`: Reopen tap (toast and start screen).
- `BVC+Panes.swift`: Close Pane close.
- `AddressPill.swift` `pressed`: `in:at:`.
- A lane: remove the swipe-down tick. Better: ask A to drop it before it merges.
- G lane: `closeAllTabs` close, and `perform(_ shortcut:)` wrapped in `withoutFeedback`. Better:
  hand both to G before it merges, since its files are uncommitted.

**Phase 5: after the strip / sidebar (S) and iPad (I) lanes merge.**
- `TabStripViewController.swift`, `SideTabsViewController.swift`: destination ticks and drop.
- `BVC+SideTabs.swift` `sidebarResized`: the latch on `showsTitles`.
- I: link-drop `.drop`, `BrowserCommands` key paths in `withoutFeedback`.
- `BVC+Summaries.swift`: summary done and failed. I's 3-line edit there is small, so this could
  also be done in Phase 1. Check that it rebases cleanly.

**Hand-offs to send to running lanes now (cheapest, no conflicts later):**
- **G (gestures):**
  - Pull arm uses `Haptic.threshold`. Un-arm uses `Haptic.selection`, with hysteresis.
  - `closeAllTabs` plays `.close` once.
  - `perform(_ shortcut:)` runs inside `Haptic.withoutFeedback` (available after Phase 0; until
    then, leave a `// haptics plan: withoutFeedback` note).
  - Keep `undoClose`'s bump only for non-keyboard paths.
- **A (search sheet):** remove `Haptic.selection.play()` on swipe-down collapse. Keep the tap on
  the microphone and the tick on Browse for Me arming.
- **P (private):** keep the tick in `showPrivate`, and add `tick:` to `showList`.
- **S (strip / sidebar):** keep the tick on the titles toggle. Add destination ticks and drop when
  reorder lands, and the resize latch.
- **C (card close):** nothing to add. The x already goes through `closeTab`'s `.close`.
- **K (clarity):** add the passkey toast bump. The Stop icon change needs no haptic.
- **I (iPad):** nothing to add for pointer or hover. Route key commands through `withoutFeedback`.
- **B (top band), F (perf):** none. F should know that `Haptic.play` adds one signpost emit per haptic.
