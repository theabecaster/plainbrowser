# Owner feedback

Feedback from testing the app, newest first. Each item stays here until it ships; then it moves to "Done" with the build that has it.

## Open

- **Sign-in like Safari:** passkeys on sites that support them, and saved passwords from the Passwords app and every password manager on the phone (1Password, Bitwarden and others), as easily as in Safari. Both need Apple's web-browser entitlement; the request is ready for the owner to submit. Until it lands, sites are steered to password sign-in and a failed passkey attempt says why. Done when the entitlement ships and the device checks in `docs/research/sign-in.md` pass. (Sign-in lane.)


## Done

- **Tapping the address bar looks empty:** it never is now. A tap on the pill opens an empty field on a paper card over the page, which stays visible behind a veil (Arc's sheet), with, nearest the thumb: "Open Copied Link" when a link was just copied (checked without the paste alert), the page itself (title and address, Copy, a tap to edit), your favorites, the pages you visited last and the tabs you closed last; the first run says in one sentence what will show there. All of it is on screen in the frame the keyboard starts. Arc's two doors: what you type from a page opens a new tab (Back returns to the page); More (or a long press on the pill) opens the new page sheet, whose address row (Back, Forward, the host, Copy Link, Reload) edits the address in place with Copy inside the field, then Find, Reader, Translate, Favorite and Share tiles, then Zoom, Site Settings and the app's places. On a search results page the pill shows what you searched for. Private tabs show no history. (Address focus lane; to check on the device.)

- **Duo inner: header-colored bar under the address row at rest; jumpy collapse:** gone. The bar
  floats over the page and leaves it no inset of its own, so WebKit paints no band of a site
  header's color behind the controls, and collapsing or bringing the bar back moves nothing in
  the page. At the top of a page its fixed header sits under the controls with the page's own
  background above it, and rides up to the top edge as you scroll; a fresh page and Back still
  start with the first line under the controls. Phones and the outer screen: the page now runs
  under the status bar, as in Safari, with no paper strip above it. (Inset fill lane; to check on
  the device.)
- **Duo inner: a bar stays at the top while reading — remove every top band:** gone. While reading, the page runs to the very top edge under the clock and battery, as in Safari's full-screen reading, and a site's fixed header moves up to the top edge with nothing above it. At rest only Plain's floating glass controls sit over the page, and the page's first line starts under them. The band was the page's top inset kept after the controls left (69 pt), which WebKit filled with a site header's color, plus the system's blur at the top edge; both are off. Still there at rest: on sites with a fixed header, WebKit paints the header's color up behind the controls (Safari does the same); removing it would make pages load with their first line under the bar, so it is yours to judge on the device. With Left tabs the tab column runs from the top edge and New Tab sits on the bar's row. The outer screen and phones are unchanged. (Duo no-band lane; to check on the device.)
- **Duo inner: huge band at the top — bar must sit in the status zone and float:** the bar now sits on the status row, beside the clock and battery, and stops short of them; nothing of Plain's is above it, and the page runs to the top edge under the floating glass. The page starts about 73 pt from the top (was 132; Safari 84), about 111 pt with the tab strip (was 170), and about 69 pt while reading. Portrait, split and the rail follow the same rule; where a status bar spans the width (phones) the bar stays under it. Plain finds the status corner from the system's corner-adaptive safe area, or else from the camera the status items wrap. (Duo top row lane; to check on the device.)
- **Dark pages wash out text on mixed light/dark sites like apple.com — make it Safari-quality:** dark pages now works like Safari's Adaptive Dark Mode, color by color instead of inverting the whole page: light backgrounds turn dark and dark text turns light, keeping their hue, while black heroes, dark cards and the white text on them stay exactly as the site made them. Pictures, video, emoji, brand colors and colored logos are never changed; text over a photo keeps the site's color; every text on apple.com, AP News and Hacker News measures at least 4.5:1. (dev, dark pages lane.)
- **Launch with tabs feels empty:** Plain opens to the last tab, exactly as it was: its page is on screen from the very first frame (a picture saved when the app left, swapped for the live page once it has loaded, with no flash), the bar resting, no keyboard. After 4 hours away (Chrome's and Firefox's line) it opens a fresh search instead, keyboard up, with the last tab visible behind a paper veil; swipe down or tap outside to get back to it, and a search from there opens a new tab. Returning within 4 hours changes nothing. With no tabs, search first as before. (dev, launch lane.)

- **URL bar should get out of the way while reading:** keep reading past the pill and the bar sinks away, leaving the whole page; a move up, a tap on the bottom edge or the status bar, the page's end, a new page, Find or a page's keyboard brings it back whole. Never hidden while a page loads, on error pages or with VoiceOver. On the Duo's inner screen the top bar's tucked address rises away the same way. (dev, scroll chrome lane.)

- **Duo inner screen: chrome takes too much space, portrait bottom menu looks broken — follow Safari on iPhone Duo:** done the Safari way. On the inner screen the system's side column is off and one top bar sits under the status bar in both orientations: Back and Forward on the left, the address in the middle, Tabs, Share and More on the right; the page gets the full width under it. There is no bottom menu on the inner screen any more. Tabs (Tab Layout Above, now the default) are a slim strip under the bar from the second tab, with short titles; Left and Right are a thinner 52 pt rail. While reading, the bar shrinks to the address and the strip hides. The page shows 89% of the landscape screen with one tab (was 76%), 83% with the strip, 91% while reading; portrait 88–94% (was 80%). The outer screen is unchanged. (dev, Duo layout lane; to check on the device, see the polish backlog.)

- **Suggestions flicker while typing:** fixed. Each row belongs to one suggestion, so a suggestion that stays never blinks; new rows fade in and old ones fade out in place, and a row that changes place crossfades there (a 0.12 s crossfade; nothing slides). Local pages and cached engine rows arrive as one list, and the previous engine rows hold for up to 120 ms until the new answer replaces them. Also fixed: engine rows that turned invisible after the first keystroke. (dev, suggestions lane.)

- **Tabs button with one tab:** with a single page the tabs button is the normal Tabs button, and a tap opens the switcher the swipe up opens (the page's card and a New Tab card), with the same motion. Its long press is unchanged; the start screen alone still has no tabs button. New Tab stays on the switcher's +, its New Tab card, More and the tabs menu. (dev, one-button lane.)

- **New Tab card content drifts:** fixed; the + and label stay at the card's center. (dev, next build.)

- **Sheets on paper:** Settings, History, Favorites, Archived Tabs and Downloads sit on Plain's textured paper, with rows on lifted paper cards, ink text and New York titles; everything else (swipes, search, edit, menus, Dynamic Type) stays native. A failed read shows Try Again instead of an empty list. (dev, sheets lane.)

- **Paper texture:** faint fibre and grain on the start screen, search, tab cards, sidebar and strip, reader and intro; flat under Increase Contrast. (dev, next build.)

- **Swipe up with one tab:** dragging the bar up (or Show All Tabs) with a single page opens the switcher with the same page-to-card motion: the card rests centered and a paper New Tab card grows in beside it; the tabs button's tap stayed "+" (now Tabs, see "Tabs button with one tab"). On the start screen alone the swipe still bumps. (dev, one-tab lane.)

- **Appearance:** Settings > Appearance (System by default, Light, Dark), saved and applied to every window with a crossfade; sites with a dark design follow it, and while Plain is dark, pages without one are darkened like Safari's Adaptive Dark Mode, with "Turn Off Dark Pages for This Site" in the page menu. (dev, next build.)

- **Suggestions over the start-screen mark:** while a query is typed on the start screen, the mark and its shortcuts recede (fade, shrink, drift up) and the rows sit on the paper; they come back when the query is cleared. (dev, state lane.)

- **Discoverable tab features:** New Private Tab, Reopen Closed Tab and Archived Tabs are in More's top section wherever they apply and on the start screen as shortcuts; a one-time tip teaches the long press on Tabs. (dev, state lane.)

- **State-aware controls:** every control follows `docs/state-rules.md`: the tabs button is Tabs, "+" or hidden; empty tabs never pile up; private closes offer no Reopen. (dev, state lane.)

- **Intro styling:** the intro keeps its steps, words and simplicity in Plain's own look: paper, a dawn window with the mark on its sill, New York headlines with a coral fold underline. (dev, next build.)

- **Tab Layout values:** Above (tab strip), Left and Right (sidebar), on the Duo inner screen. (dev, next build.)

- **First-run intro:** Arc Search's intro look and feel in Plain's identity: Stem splash, icon picker (Dawn, Night, Coral, Paper), live blocking demo. The default-browser step and empty-tab card are built and wait for Apple's entitlement. (dev, next build.)

- **Floating address bar:** no glass band behind the pill; the page runs under it. (dev, after build 2611261658.)
- **Tab switcher:** behaves like the iOS app switcher, Arc Search style. (Build 2611261658.)
- **Empty tab:** a start screen with the Plain mark instead of a blank page. (Build 2611261658.)
- **App icon:** Stem, a paper ring with a hidden P. (Build 2611261448.)
- **Long addresses overflowing the pill on the Duo outer screen.** (Build 2611261056.)
