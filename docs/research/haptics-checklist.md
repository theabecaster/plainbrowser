# Haptics: the owner's Duo checklist

The simulator has no Taptic Engine, so the feel is checked here, on the Duo, by hand. The plan and
the full inventory are in docs/research/haptics.md; the rules are in docs/ui-reference.md,
"Haptics".

**Setup.** Turn System Haptics on (Settings > Sounds & Haptics). Do each item twice: once with
Reduce Motion off and once with it on. With Reduce Motion on, each haptic plays with the crossfade.

**Status.** `[run 1]` landed in the Phases 0–2 run, `[run 2]` in the Phases 3–5 run: check both
now. `[divider]` came with the resizable side pane. `[private]` is left for the private-mode lane:
it plays the way it does today.

**What each one feels like.** A *tick* is the lightest click (selection). A *light tap* is a short
light impact. A *firm tap* is a medium impact. A *drop* is a short rigid knock. A *soft close* is
a soft, round impact. *Success* is the double tap Apple Pay uses. A *warning* is the softer
two-hit pattern. A *bump* is a faint soft impact, at most one a second.

## Bar (outer screen and phones)

- [ ] `[run 1]` Slow sideways swipe on the bar to the next tab: one firm tap at half-way, a tick if you go back under half, and silence when you let go.
- [ ] `[run 1]` Fast flick to the next tab: one tick as it lets go, never a double.
- [ ] `[run 1]` Grab the page while it is still sliding: no extra firm tap on the grab.
- [ ] `[run 1]` Past the last tab: a firm tap when the New Tab card is out (80 pt), a tick if you pull it back, and silence when the new tab opens.
- [ ] `[run 1]` Sideways swipe on the only tab, with nothing beside it: one bump as it springs back. Repeating it fast does not buzz.
- [ ] `[run 1]` Swipe up slowly into the switcher: a firm tap where the page passes the commit size, a tick if you go back down, silence when it opens. A quick flick up that opens it: one light tap.
- [ ] `[run 1]` With Reduce Motion on, the swipe up's firm tap still plays (it is the only cue that nothing moves).
- [ ] `[run 2]` Pull to refresh: a firm tap at the arm, a tick when backing off, no chatter while resting on the line, silence when the reload starts.
- [ ] `[run 2]` Long-press the pill (bar not collapsed): one firm tap as the page sheet rises.

## Page sheet (More)

- [ ] `[run 1]` Zoom + and −: a tick per step, a light tap on the step that lands on 100%, and a light tap on the percentage (back to 100%).
- [ ] `[run 1]` Copy Link: success. Favorite on and off: success each time. Read Later: success. (Unchanged, but now on the window's generator.)
- [ ] `[run 2]` Site Settings > Desktop Site, Content Blocking, Cookie Banner Blocking: a tick, then the reload. Page Appearance: a tick and the crossfade.
- [ ] `[run 1]` Reload, Stop, Find, Reader, Share: no haptic.
- [ ] `[run 2]` The pill's Reload and Stop: no haptic. Its long press: the system menu's own, once. Reload Without Cache: one light tap as the page reloads.
- [ ] `[run 1]` Save as PDF that fails: a warning with the "couldn't be saved" toast.
- [ ] `[run 2]` Translation fails: a warning with its toast (behind a sheet, when the toast shows after it closes). Close Pane (inner screen, split): a soft close.

## Gallery (switcher)

- [ ] `[run 1]` Lift a card past its close line slowly: a firm tap. Back under it: a tick. Let go past it: a soft close as it flies.
- [ ] `[run 1]` Lift a card past the line, then flick it back down: a firm tap, then a tick as it springs home, and the tab stays.
- [ ] `[run 1]` A short drag that never reaches the line: silent.
- [ ] `[run 1]` Fast flick close: one haptic, never two glued together (usually the soft close; a flick that crosses the line in its very last frame plays the firm tap alone).
- [ ] `[run 1]` Long-press and reorder across three slots: the system's lift, three ticks, a drop on letting go. Drop it back where it started: no drop.
- [ ] `[run 1]` Gallery scrolling and snapping: silent.
- [ ] `[run 2]` Close All: the confirmation is silent, then one soft close. Reopen (menu or toast): a light tap as the card comes back.
- [ ] `[private]` Private switch: a tick.
- [ ] `[run 2]` New profile: success only (no tick glued to it). Delete profile: a soft close only.

## Inner screen (unfolded)

- [ ] `[run 1]` Side pane Find: Return past the last match ticks as it wraps to the first; Return with no matches bumps; Return while results are still coming stays silent.
- [ ] `[divider]` Side pane divider: drag from Narrow toward the page: one tick passing Half, a firm tap where the pane would take the whole width, a tick if you pull back; letting go after the firm tap is silent. Drag the pane thin: a firm tap where it would close. A fast throw toward the edge closes it with one light tap. Leaving Narrow by itself is silent. Double tap the handle at Narrow: one soft bump.
- [ ] `[run 2]` Strip and sidebar reorder: a tick per place and one drop. Sidebar resize: a firm tap as the titles come in, a tick as they go, and a flick that carries them in: one light tap.
- [ ] `[run 1]` Fold and unfold, rotation: silent.

## Search

- [ ] `[run 1]` Return in an empty field: a bump; pressing it again at once stays silent.
- [ ] `[run 2]` Microphone: a light tap. Browse for Me arm: a tick. Swipe the search sheet down: silent.

## Outcomes

- [ ] `[run 1]` Download a large file: a light tap just after it starts (150 ms), success with the "downloaded" toast. A small file that is done at once: success only, with its toast. Download it while a sheet is open: the success waits and plays when the toast shows after the sheet closes.
- [ ] `[run 1]` A download that fails: a warning with its toast.
- [ ] `[run 2]` Turn on Airplane Mode, then Try Again on the error page: one warning as the page says so again. The first failure is silent (the page says it). Try Again that loads: silent.
- [ ] `[run 2]` Summarize: success when done; a failure (offline): a warning. Close the sheet to a source before it ends: silent.
- [ ] `[run 2]` Reopen on the bar's toast after Close Tab, Reopen Closed Tab from the tabs menu or the start screen: a light tap. ⌘⇧T: nothing.
- [ ] `[run 2]` A sign-in that asks for a passkey: a bump with its toast. Save Image with Photos refused: a bump with the toast that says why. Open in Background: a light tap with its toast.

## Feature sheets (Settings, History, intro)

- [ ] `[run 1]` Settings > Search Engine: a tick when the checkmark moves (none on the engine already picked).
- [ ] `[run 1]` Settings > custom engine: a tick when Use is accepted, a bump when the address is refused.
- [ ] `[run 1]` Settings > Clear History and Data, after its dialog: success when it finishes; the dialog itself is silent.
- [ ] `[run 1]` History > Clear (Last Hour, Today, All), after its dialog: success as the rows go.
- [ ] `[run 1]` Settings > App Icon: a tick on the tile, then the system's own alert. If iOS refuses, a bump as the check goes back.
- [ ] `[run 1]` Intro (`-PlainShowIntro`): a light tap when the mark lands, a tick on an icon tile, success on Let’s Go. Skip, Not Now and Set as Default: silent.

## Timing (Instruments, Points of Interest)

- [ ] `[run 1]` Record a few slow bar swipes: each `haptic` event sits on the frame where `tabSwipe`'s page crosses half the width, and no `haptic` event appears inside `tabSwipe.settle`.
- [ ] `[run 1]` A card close: the `close` haptic within 16 ms of `galleryCardClose`'s start.

## Silence

- [ ] `[run 1]` Scroll a long page with the chrome collapsing and coming back: nothing.
- [ ] `[run 2]` Hardware keyboard shortcuts (⌘T, ⌘W, ⌘L, ⌘R, ⌘⇧T, Control-Command-S): nothing.
- [ ] `[run 1]` Turn System Haptics off: nothing anywhere.
