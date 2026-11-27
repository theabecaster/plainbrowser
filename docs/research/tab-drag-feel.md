# Tab card drag: why it felt hard, and how the reference apps do it

Owner feedback (2026-11-27): "In the tab switcher the feel isn't quite right yet. It feels hard to
drag a tab; it's not like Arc or the iPhone app switcher at all. Tabs that can't be dismissed, like
the New Tab one, should let me drag them up a bit and get stuck, letting me know it's not
dismissable that way, with no text."

Sources are marked **[V]** (verified: read the source or measured here) or **[C]** (consensus of
secondary sources, not verified).

## 1. How the reference apps behave

**iOS app switcher** (WWDC18 "Designing Fluid Interfaces", session 803) **[V]**
- "One-to-one tracking is extremely important. When swiping or dragging, the contents should stay
  attached to the gesture", and "the moment the touch and content stop tracking one-to-one, we
  immediately notice it."
- "Be vigilant and mindful of all the latencies or timers": everything responds at once; no
  delay that waits to see what the finger means.
- Release decisions use projected momentum, not position: velocity with
  `UIScrollView.DecelerationRate`, so a light flick goes as far as a long drag.
- Springs: start from 100% damping; reward a gesture's momentum with a little overshoot.
- Every motion is redirectable: the finger can catch anything mid-flight, from where it is.
- Two axes in one gesture: sideways moves between apps, up closes. A card lifted up moves
  vertically only, under the finger. **[C]** (observed behavior; Apple publishes no numbers)

**Arc Search** (docs/research/arc-tab-switcher.md) **[C]**
- Cards close with a swipe up, the app switcher's gesture; sideways scrolls the row.

**Safari, Chrome and Firefox for iOS** **[C]** / **[V]** for Firefox
- Safari's and Chrome's tab grids close a tab with a sideways swipe on its thumbnail; the grid
  scrolls vertically, so the close axis is the free one, as in Plain's row (scroll sideways,
  close up).
- Firefox (`SwipeAnimator.swift`, read 2026-11-27) **[V]**: the cell follows the pan 1:1
  (`translation.x`), fades to alpha 0 and scales to 0.9 and rotates up to 10° with distance; it
  closes past 80 pt; a release speed is clamped to at least 800 pt/s for the exit; it recenters in
  0.15 s otherwise; it begins only when the move is more horizontal than vertical.

**Things that cannot be dismissed** **[C]**
- A scroll view at its edge: the content keeps following the finger with growing resistance,
  `x' = (1 − 1 / (x · c / d + 1)) · d`, c ≈ 0.55, d the limit (reverse-engineered, Arc doc §2),
  then springs back on release. It never stops dead: a dead stop reads as a frozen phone (WWDC18).
- A sheet with `isModalInPresentation`: dragged down it stretches a little with heavy
  resistance and snaps back; nothing explains why.
- Plain's own "nothing there" rule (docs/state-rules.md, principle 4): a gesture with nothing to do
  moves a little, rubber-banded, and springs back with the soft "nothing there" haptic.

## 2. What Plain did before (measured)

Simulator (iPhone Duo, outer screen, Debug), a scripted drag: touch down, hold 50 ms, then up
90 pt at 400 pt/s, hold 0.4 s, lift; and a flick up 70 pt at 2500 pt/s. A temporary probe logged
the finger and the card's on-screen position every frame from touch-down. **[V]**

| | Before | After |
|---|---|---|
| Finger travel before the card moved | 70.7 pt (238 ms after touch-down) | 11.7 pt locks it; it moves from the next frame (134 ms after touch-down, of which 50 ms is the scripted hold and ~30 ms the first touch events) |
| Card at rest under a 90 pt drag | 49 pt (ratio 0.54) | 90 pt (ratio 1.00, one frame behind) |
| Short quick flick (70 pt, 2500 pt/s) | the card never moved; the tab stayed | closes |

Why it felt hard:
1. **A `UIPanGestureRecognizer` begins late and counts from there.** It begins only after its
   hysteresis (10–25 pt here, and later still while the card's drag-and-drop and context-menu
   interactions are deciding), and its translation starts near the point where it began, so the
   card stayed 10–40 pt behind the finger for the whole drag. A flick shorter than the hysteresis
   never began at all.
2. **A smoothing spring between finger and card.** Each pan update animated the card with
   `interactiveSpring(0.12)`, so the card trailed the finger further while it moved.
3. **A 45° split between lifting and scrolling.** A thumb swipes up in an arc; anything flatter
   than 45° went to the gallery's scroll instead of the card.
4. **800 pt/s to close by flick.** A light flick fell short; the app switcher takes it.
5. **Nothing for the New Tab card.** A drag on it did nothing at all. The owner then asked for the
   card to go (2026-11-27): New Tab is the "+" under the cards, so no card in the gallery is left
   that cannot close (gallery items are never pinned; nothing pins a tab), and the planned
   rubber band for undismissable cards was dropped with it. The rule stays: should a card that
   cannot close come back, it resists with the scroll view's formula and springs back, no text.

## 3. What Plain does now

- `LiftGestureRecognizer` measures the finger from touch-down and decides the axis after 6 pt
  (under the scroll view's own threshold, so a lift wins the race): within 60° of straight up it
  lifts the card, otherwise it fails at once and the gallery scrolls. Down stays at 45°.
- The card's offset is the finger's travel, applied directly each touch event (no smoothing
  spring). The 6–12 pt of travel before the lock is paid back over the next 12 pt, so there is
  no jump on the first frame and the card is exactly under the finger after it.
- Release: closes on a flick faster than 500 pt/s up, or when the projection (d = 0.99) passes
  40% of the card's height; otherwise it springs back with the release velocity
  (`Spring(0.32, bounce 0.12)`, frame by frame, `SpringDriver`), and a finger can catch it
  mid-flight from where it is. A closing card flies on with the same velocity
  (`Spring(0.3, bounce 0)`).
- Horizontal swipes still scroll the cards; a tap still opens; a long press still brings the menu
  and the drag to reorder.
