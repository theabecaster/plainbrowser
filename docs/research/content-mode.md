# Desktop or mobile site across the Duo's fold

Owner (2026-11-27): "On the iPhone Duo, when it's open, have the desktop page requested by
default so it looks nice on the big screen, and when I close it, have it default off. But make
sure the reloads don't mess things up. … It's weird now."

## What Plain did before this change

Desktop or mobile was decided once per navigation, from the pane's shorter side (≥ 600 pt is
desktop: the inner screen yes; the outer screen, a split half, a phone in landscape no), and
never changed on a resize. Measured on the iPhone Duo simulator with Device Hub folding it
(captures: `before/` in the lane's capture folder):

- **The page on screen never followed the fold.** A page opened on the outer screen stayed the
  mobile site after unfolding: its phone layout stretched over the inner screen
  (`before-stills`: "MOBILE · A" on the open Duo). A page opened while unfolded stayed the desktop
  site after folding ("DESKTOP · B" on the outer screen). Only the next navigation picked the mode
  for the new screen, so the same tab changed mode on a link tap rather than on the fold: the
  owner's "it's weird now".
- **No reload on fold or unfold, so nothing was lost**, but nothing was fixed either: scroll,
  typed text and video stayed, in the wrong mode.
- **The Desktop Site checkmark followed the navigation's start, not the page**: a navigation that
  failed or became a download still flipped it.
- **Back and forward** could bring back a page from the back-forward cache in its old mode while
  the tab claimed the other one.
- On an iPhone, WebKit's desktop mode keeps the meta viewport (below), so a responsive page in
  desktop mode on the outer screen still lays out at 382 pt; the weirdness shows on sites that
  serve another page by user agent, which is most big sites.

## What desktop mode changes in WebKit

From WebKit's `WebPageProxyIOS.mm` (`effectiveContentModeAfterAdjustingPolicies`,
`isDesktopClassBrowsingRecommended`, `desktopClassBrowsingSupported`):

- **`.recommended` is always mobile on an iPhone.** `desktopClassBrowsingSupported()` is false on
  a small-screen idiom, so the recommended mode never turns desktop there, at any width. The Duo
  is an iPhone, so `.recommended` would give its inner screen the phone site; that is why Plain
  picks the mode itself from the pane's size.
- On iPad, `.recommended` is desktop except for an iPad mini or a narrow window (a view at most
  375 pt wide with no resizable window): that is Safari's desktop at full size and mobile in a
  narrow Split View. The mode is part of the navigation's website policies, so a page that is on
  screen keeps its mode when the window resizes, until its next navigation.
- **Desktop mode sets:** the user agent (Mac Safari; Plain sets its own, because WebKit's would
  keep the `Mobile/15E148` token Plain adds), `navigator.platform` = `MacIntel`, inline video
  without `playsinline`, and when it emulates desktop hardware, no touch points and a fine pointer.
  **Only where desktop-class browsing is supported (iPad, Mac)** does it also ignore the meta
  viewport (a 980 px layout scaled to fit), enable Media Source, and allow simulated mouse
  events. On an iPhone, the Duo included, the meta viewport is still honored.
- So on the Duo the difference is mostly what the site does with the user agent. A responsive
  page lays out to the pane's width in both modes. A site that serves another page by user agent
  (shops, search, social, `m.` hosts, or pages without a device-width viewport) is what changes:
  its phone page stretched over the inner screen, or its desktop page (often 980 px or wider)
  squeezed onto the outer one.
- `navigator.platform` is per document: a page restored from the back-forward cache reports the
  mode it was loaded in, which Plain uses to tell what mode a page really shows.

## What other browsers do

- **Safari on iPad:** `.recommended`; desktop at full size, mobile in a narrow Split View or
  Slide Over. Resizing the window does not reload the page; the next navigation gets the new
  mode. "Request Mobile/Desktop Website" in the page menu reloads and is remembered per site.
- **Chrome on Android:** desktop by default on large tablets (at least 10 in and 8 GB), with a
  desktop user agent but a viewport that matches the window width instead of a fixed 980 px, so
  responsive pages keep fitting; per-site and global switches in the menu and Site settings.
  Chrome's help page says the default view is picked from screen size and memory. No documented
  behavior on a fold for the page already open.
- **Firefox for Android:** treats screens at least 600 dp wide (tablets, unfolded foldables) as
  large. Bug reports on the Galaxy Fold describe the opposite of what the owner wants: a desktop
  page stays desktop after folding, with tiny text, because the setting applied to new tabs only.
- **Samsung Internet on the Galaxy Fold:** users ask for mobile view on the cover screen and
  desktop on the main one, and report switching by hand; Samsung documents no automatic switch.
  A Vivaldi forum request asks for exactly this ("desktop when unfolded, switch when folded"),
  which says it is not common.

None of them switch the page on screen at a fold. That is the gap the owner describes: today the
page stays in the mode of the screen it was opened on.

## The rule Plain uses

1. **A new navigation takes the mode for its pane now**: shorter side ≥ 600 pt is desktop, else
   mobile. A per-site Desktop Site choice always wins and is remembered.
2. **After a fold, an unfold, a split or the side pane changes a pane's size,** each page on
   screen whose wanted mode differs switches, `contentModeSettleDelay` (0.45 s) after the
   change has settled, so the reload never competes with the fold's animation and a fold then a
   quick unfold does nothing.
3. **It switches only when nothing would be lost:** not on a form result (POST), not while media
   plays, in picture in picture, fullscreen, the camera or microphone is on, a download from the
   tab runs, Find is open or the page is translated; not when a field holds typed text (or a
   changed choice or checkbox), a field or editable area has focus, or the page can't answer.
   A page still loading is checked again when its load ends. Otherwise it keeps its mode and the
   next navigation gets the new one. Never a prompt.
4. **The switch is a reload in place under the page's own picture.** The picture
   (`snapshotView`) covers the web view; the reload runs with the new mode; when it finishes
   Plain resets the zoom WebKit restored from the old layout, scrolls the element that was at the
   top (the first one under the bar that scrolls with the page, so not a sticky or fixed header)
   back to the top (by id, else by its path in the document, else the same scroll fraction),
   waits two frames, then crossfades (0.2 s). The picture never stays longer than 2.5 s. No
   history entry is added.
5. **Hidden tabs switch when they come on screen**, by the same rules. Each pane follows its own
   width: a split half is mobile, a full inner pane desktop.
6. **No skipping for responsive pages.** Detecting a responsive page is cheap (a device-width
   viewport), but detecting that a site does not serve another page to a desktop user agent is
   not: `Vary: User-Agent` is often missing or stripped by caches, and scripts read the user
   agent too. A needless reload costs a second behind the picture; a missed one is the owner's
   complaint (`FixedChoices.contentModeSkipsResponsivePages`).

## Sources

- WebKit, `Source/WebKit/UIProcess/ios/WebPageProxyIOS.mm` (main branch, read 2026-11-27):
  https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/ios/WebPageProxyIOS.mm
- Apple, `WKWebpagePreferences.ContentMode`:
  https://developer.apple.com/documentation/webkit/wkwebpagepreferences/contentmode
- WebKit header comment on `preferredContentMode` (recommended: mobile on iPhone and iPad mini):
  https://opensource.apple.com/source/WebKit2/WebKit2-7608.4.9.1.3/UIProcess/API/Cocoa/WKWebpagePreferences.h.auto.html
- Chrome Developers, "Chrome enables desktop mode by default on premium tablets":
  https://developer.chrome.com/blog/desktop-mode
- Google, "Manage desktop mode settings on mobile": https://support.google.com/chrome/answer/13514529
- Mozilla support thread on a folded Fold defaulting to desktop:
  https://support.mozilla.org/questions/1476391
- Samsung Community, "Mobile and desktop view on Fold using Samsung Internet":
  https://eu.community.samsung.com/t5/galaxy-z-fold-z-flip/mobile-and-desktop-view-on-fold-using-samsung-internet/m-p/4447694
- Vivaldi forum request for fold-aware desktop mode: https://forum.vivaldi.net/post/614006
