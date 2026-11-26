# First-run intro: Arc Search's motion, and Plain's version

The owner loves Arc Search's first-run intro and asked for one in the same visual language: the
full-bleed vivid gradient, big bold display type with one word in italics, rounded light feature
cards, the icon grid, the blocking demo with a page mock and a toggle, big capsule buttons, and the
dissolve into the search field. Plain's version keeps that language and makes it Plain's with
Plain's palette (mint, Lagoon Blue and violet dawn, cream paper, coral), the Stem mark, and Plain's
own words. It uses no Arc text, logo or image assets.

## Sources

- **The owner's screen recording** of Arc Search's intro (iOS, 38 s; frames every 0.25 s). It is
  the main source; every timing below comes from it.
- **Arc's desktop onboarding hand-off**, written up by the engineer who built it
  (merowing.info, "content-reveal"). The last screen "melts" into the browser: a mask of about 20
  uneven blobs shrinks over a 3 s ease-in-out, a 10 pt blur softens the blob edges, and the logo
  animates blur and opacity. It is SwiftUI with no shaders, and the post says the timings took
  "lots of tweaking". This covers the desktop app, not Arc Search, but it is the same team's
  hand-off idea.
- **The splash plays haptic taps** in time with its animation (a third-party guide and a Product
  Hunt comment).
- **The team's bar for motion.** Arc Search's mobile design lead wanted "delightful animations,
  interactions, and haptics" (Inverse). MacStories called the transitions "fluid and snappy".
- **Not public:** no Browser Company post, talk or credited designer gives the intro's springs,
  durations, gradient technique or tools. The principles below are read from the recording.

## What the recording shows

| Step | What happens | Motion |
|---|---|---|
| Splash | The logo enlarges into a deep blue field, then settles small and rises to the top third | Zoom and settle about 1 s; the field turns from flat blue to a blue, magenta and red gradient as it settles |
| Promise | One bold line, with one word in italics | Text arrives out of a blur; Next arrives a beat later |
| Features | Title and four light cards (icon chip, bold title, one-line subtitle) | The old step blurs out; title, then cards, then button arrive staggered, each out of a blur |
| Icon | 3 x 3 grid of alternate icons, a radio under each, the current one ringed | Same blur dissolve; picking shows the system's "icon changed" alert |
| Blocking | A phone-sized page mock (white, rounded) with a dark "Block Ads and Trackers" bar overlapping its bottom | The demo flips by itself; a vertical seam sweeps across the page, swapping the clean and ad-filled versions |
| Default | The field turns light (white and pastel), the icon is large, "Set as Default Browser" and Skip | The field's colors move rather than cut |
| Finish | Content blurs away, the gradient stays, the search field and keyboard come up | About 1 s of the bare field, then the field fades as the keyboard rises |

## Principles

1. **One field, never a cut.** The gradient runs under every step. Each step moves its colors to a
   new arrangement, and the field drifts slowly even when nothing else moves.
2. **Blur is the transition.** The old step blurs (about 12 pt), fades and shrinks slightly (about
   0.96). The next step arrives the reverse way. The two overlap by about half, so the field is
   never empty for long.
3. **Stagger by importance.** The headline comes first, then the subtitle, then the cards or the
   demo about 60–70 ms apart, and the button last. Each part rises about 16–18 pt out of the blur.
4. **Soft springs with no bounce.** Everything settles; nothing overshoots. Only the splash is
   longer (about 1–1.2 s), and its haptics mark its beats.
5. **Show, don't list.** The blocking step is a live page, not a claim. The toggle drives it, and
   it plays once by itself.
6. **Hand off to the product.** The last step does not close; it dissolves into the real search
   field with the keyboard up.

## Plain's translation

| Arc | Plain |
|---|---|
| Logo zooms and settles | The Stem mark assembles from the icon's own shapes (Core Animation): the stem and bowl are written like a P, the dawn rises in the window (night sky to dawn, the sun comes up), and the coral fold turns over along its crease in 3D. 1.12 s, skippable by a tap. A light haptic tap when the fold lands. Then the mark rises into the promise step's header. |
| Blue, magenta and red field | A dawn field: night lagoon, dawn violet and Lagoon Blue, with mint, violet, coral and peach blooms. Each step has its own arrangement (`IntroBackdrop.Mood`); the blooms travel there and drift underneath. |
| Promise line | "The web, *plainly*." with "Nothing in the way of the page." |
| "Meet your new favorite browser" | "Built to stay *out of your way*", with four cream-paper cards: Blocking, Everywhere; Tabs Tidy Themselves; Private Tabs; Made for iPhone Duo. |
| 3 x 3 icon grid | "Pick your *icon*": 2 x 2 grid of the Stem colorways (Dawn, Night, Coral, Paper), a coral check under the picked one. Settings > App Icon changes it later. |
| Seam wipe between two page versions | "The page, *minus the junk*": one page mock whose clutter leaves piece by piece (the cookie wall drops away, the video ad shrinks into its corner, the banner and sponsored box fold shut, the tracker count turns into "9 blocked") while the article reflows up. A reflow shows what blocking does to the page; a wipe only compares two pictures. The caption says Plain blocks these on every site, because blocking is always on. |
| "Never see another ad" on white | "Make Plain your *default*" on cream paper with the mark (behind `FixedChoices.defaultBrowserPromptsEnabled` until the entitlement lands). |
| Dissolve into search | The step blurs away, the browser comes up under the intro with its search field focused, and the field fades over the rising keyboard. |

Numbers: step exit `.smooth(0.38)`; parts enter on `.spring(0.62, bounce 0)`, starting 0.16 s
after the exit begins and 0.065 s apart, rising 18 pt out of a 12 pt blur; field moves 0.9 s
ease-in-out; the demo's reflow `.spring(0.55, bounce 0)` with the clutter leaving 0.07 s apart.
Under Reduce Motion every move is a 0.2 s crossfade, the field does not drift and the splash is a
fade-in of the finished mark.
