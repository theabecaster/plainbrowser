# First-run intro: Arc Search's motion, and Plain's version

The owner loves Arc Search's first-run intro and asked for one like it: the splash, one promise,
what's inside, an icon grid, the blocking demo with a page mock and a toggle, and the dissolve
into the search field. The first version copied Arc's look too (a full-bleed vivid gradient, heavy
type with one italic word, light cards and white pills). The owner liked it but said it read as
Arc's, so it was restyled: the structure, steps, words and rhythm stayed, and the look became
Plain's own (paper, the dawn, the coral fold and the Stem mark). See "Plain's styling" below. It
uses no Arc text, logo or image assets.

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

1. **One field, never a cut.** (Arc's; Plain keeps it as one dawn window that changes shape.) The gradient runs under every step. Each step moves its colors to a
   new arrangement, and the field drifts slowly even when nothing else moves.
2. **Blur is the transition.** (Arc's; Plain lifts the step away like paper instead.) The old step blurs (about 12 pt), fades and shrinks slightly (about
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

## Plain's styling

Two directions were mocked on iPhone 17 (promise, what's inside, blocking demo) and compared by
Codex against Brand/identity.md and Arc's frames:

- **Window (chosen):** cream paper as the ground; the dawn seen through a window cut in the paper
  at the top, the Stem mark resting on its sill; New York headlines.
- **Horizon:** paper with the dawn as a planet and rising sun at the foot of the screen; SF Pro
  Expanded headlines.

The window won. The ground is paper and the dawn is contained, which says what the mark says: a
paper ring with the web's dawn inside, a window onto the web. The serif and the paper layout are
the furthest from Arc's heavy sans on a wall-to-wall gradient. The horizon's full-width atmosphere
felt closer to Arc, and its sun and dark planet fought the buttons (the Next and Not Now labels
lost contrast over the planet).

| Part | Arc (first version) | Plain |
|---|---|---|
| Ground | Full-bleed blue, violet and pink gradient with drifting blooms | Paper (`Palette.background`: cream by day, Deep Lagoon by night), the launch screen's own color |
| Hero | The gradient itself | A dawn window at the top (the mark's sky, coral sun, deep-blue planet with its mint rim). Tall on the promise and default steps, a 56–76 pt band on the busy steps. The sun climbs a little each step and the sky warms from dawn to morning |
| Signature motion | Blur dissolves everywhere | One moment: after the splash the dawn opens out of the mark's own window into the page's window while the mark settles on its sill. Steps then lift away like a sheet (fade, 10 pt rise, 0.985 scale) with no blur |
| Headline | SF Pro Heavy, one word in italics | New York semibold (the Reader's serif), the word underlined by a coral stroke with its end cut at the fold's 45 degrees (a `TextRenderer`) |
| Cards | Light cards with colored chips | Paper sheets: surface color, hairline edge, soft shadow; one ink symbol in a small ring |
| Progress | None | Small rings, one per step, like the mark's ring; the current one filled |
| Buttons | White capsule on the gradient | Lagoon Liquid Glass (`.glassProminent`), filled a step deeper (`#2366F0`) so the white label holds 4.5:1 |
| Blocking demo | White page on the gradient, ink toggle bar | A paper sheet with a hairline and soft shadow; the toggle floats over it on Liquid Glass with a Lagoon switch; the tracker badge has ink text |
| Mark on paper | n/a | The ring casts a soft shadow from a shadow path, so cream holds its edge on cream |

## Plain's translation (structure)


| Arc | Plain |
|---|---|
| Logo zooms and settles | The Stem mark assembles from the icon's own shapes (Core Animation): the stem and bowl are written like a P, the dawn rises in the window (night sky to dawn, the sun comes up), and the coral fold turns over along its crease in 3D. 1.12 s, skippable by a tap. A light haptic tap when the fold lands. Then the dawn opens out of the mark's window into the page's, and the mark settles on its sill. |
| Blue, magenta and red field | Paper with a dawn window (see "Plain's styling"). Each step has its own window and sun (`IntroLayout.scene`). |
| Promise line | "The web, *plainly*." with "Nothing in the way of the page." |
| "Meet your new favorite browser" | "Built to stay / *out of your way*" (the emphasis on its own line, so it takes one stroke), with four paper sheets: Blocking, Everywhere; Tabs Tidy Themselves; Private Tabs; Made for iPhone Duo. |
| 3 x 3 icon grid | "Pick your *icon*": 2 x 2 grid of the Stem colorways (Dawn, Night, Coral, Paper), a coral check under the picked one. Settings > App Icon changes it later. |
| Seam wipe between two page versions | "The page, minus the *junk*": one page mock whose clutter leaves piece by piece (the cookie wall drops away, the video ad shrinks into its corner, the banner and sponsored box fold shut, the tracker count turns into "9 blocked") while the article reflows up. A reflow shows what blocking does to the page; a wipe only compares two pictures. The caption says Plain blocks these on every site, because blocking is always on. |
| (no Arc step) | "Let Plain *browse* for you", where Apple Intelligence can run: a mock of Plain's search on paper, where a question types itself, Browse for Me is pressed, three source chips are read and three cited points arrive; a tap on its row plays it again. One line for the state, and Turn On Apple Intelligence only while it is off (docs/decisions.md, "Setup steps in the intro"). |
| "Never see another ad" on white | "Make Plain your *default*" under a morning window with the mark on its sill (behind `FixedChoices.defaultBrowserPromptsEnabled` until the entitlement lands). |
| Dissolve into search | The step lifts away, the browser comes up under the intro with its search field focused, and the paper and dawn fade over the rising keyboard. |

Numbers: step exit `.smooth(0.38)` (fade, 10 pt lift, 0.985 scale); parts enter on
`.spring(0.52, bounce 0)`, starting 0.16 s after the exit begins and 0.065 s apart, rising 16 pt;
the dawn window opens and the mark settles on one `.spring(0.85, bounce 0)`, and the window changes shape between steps on a quicker `.spring(0.5, bounce 0)` so it is out of the way before the next headline (UIKit animations of layer
frames, so the render server runs them) and the sky's colors on a matching 0.9 s layer animation;
the demo's reflow `.spring(0.55, bounce 0)` with the clutter leaving 0.07 s apart. Under Reduce
Motion every move is a 0.2 s crossfade, the window cuts to its place inside a crossfade and the
splash is a fade-in of the finished mark. Nothing drifts while a step is still.
