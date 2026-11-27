# UX audit (2026-11-27)

A first-time user's walk through every flow on `dev` at 432dad1: iPhone 17, the iPhone Duo's
outer screen and its inner screen (simulators, light and dark, Dynamic Type up to Accessibility
XL, landscape). Each step was judged against Safari (and Arc Search where Plain follows it), the
owner's feedback (docs/feedback.md), docs/ui-reference.md and docs/state-rules.md.

Ranked by impact. **Fixed** items landed in this lane; the others name the lane that owns the
area. Captures are named in brackets; they were taken into the session scratchpad
(`ux/<name>.jpg`) and are not committed.

## High

1. **Fixed. Opening Reader once turned JavaScript off for every page after it, until relaunch.**
   The reader's configuration is a copy of the pages' one, and `WKWebViewConfiguration.copy()`
   shares `defaultWebpagePreferences`; `ReaderSchemeHandler.install` set
   `allowsContentJavaScript = false` on that shared object. Seen as Google's "Turn on JavaScript
   to keep searching" page for every search after a reader visit (the default engine), and dead
   buttons on every site. Safari on the same simulator searched fine. The reader now gets its own
   preferences object; a Reader test checks the copied configuration keeps JavaScript.
   [i17-30-reader, i17-60-search-result, i17-safari-google2, v-js-before-reader,
   v-js-after-reader, after-js-after-reader]
2. **Gallery after closing down to one card: the New Tab card covers the remaining tab.** Close
   one of two cards: the New Tab card slides to the centre slot, on top, and the remaining tab
   sits shrunk behind it at the left edge with its title hidden (state rules §6 say the lone card
   rests centred with the New Tab card beside it, as on a fresh open). It stays that way.
   Owner: tab switcher lane (TabGalleryUI). [i17-34-closed-toast, i17-36-after-close-5s; a fresh
   one-card open for comparison: i17-25-gallery-one]
3. **Paper status band over every page (iPhone, Duo outer).** The page starts under the status
   bar and a flat paper (light) or navy (dark) strip fills the status area above it. On a white
   page it reads as a two-tone seam; in dark mode the navy band sits over the grey darkened page.
   Safari runs the page under the status bar with the scroll edge effect. Same family as the
   owner's Duo inner "band at the top" complaint, here on the phone layout. Owner: TopChrome / top
   bar lane (page area and insets). [i17-13-page, i17-15-hidden, d-03-page-dark]
4. **The address pill and button bar are hard to read over text.** The glass shows the page's
   text almost unblurred under "Not Secure — host" and the buttons (busy article pages are the
   worst case). Known in docs/polish-backlog.md ("Hard edge look"); it is the first thing a reader
   sees on every article. Owner: chrome / glass (shell lane; not changed here). [i17-28-fr,
   i17-30-reader-a]
5. **Fixed. The address text overflowed the pill at accessibility text sizes.** At Accessibility
   XL the host filled the 48 pt capsule edge to edge and the head truncation read "…Secure —
   127.0.0.1". The pill's text now stops growing at the largest non-accessibility size, as
   Safari's field does. [t-01-page-ax, after-pill-ax]

## Medium

6. **Fixed. Start screen shortcuts wrapped unevenly.** "Reopen Closed Tab" broke onto two lines
   next to a one-line "Private Tab", so the row's captions and heights did not line up, and the
   page menu calls the same items "Reopen Tab" and "Archive". The start screen now uses the page
   menu's captions in equal columns, with the full names for VoiceOver. [i17-43-start-screen,
   after-start-shortcuts]
7. **Fixed. An empty private tab looked exactly like a regular one.** Only the status band and
   the field were tinted; a first-time user had no sign the tab is private (Safari says so on its
   private start page). The sentence under the mark now reads "A private tab: Plain keeps no
   history of it." No badge (docs/ui-reference.md). [i17-44-private-start, after-private-start]
8. **Fixed. The share sheet's header showed only the host and a blank compass.** Safari heads it
   with the page's title. Plain now hands the sheet the title (and a mail subject) with the
   address. [i17-24-share, after-share-header]
9. **Gallery bar off-centre when More hides.** With one card (or in the regular list while a
   private tab is on screen) More and Done hide in place, so the glass capsule keeps an empty slot
   and the Private, "+" and Done buttons sit off-centre in it. Either collapse the capsule to what
   shows, or centre the visible buttons. Owner: tab switcher lane. [i17-25-gallery-one,
   i17-47-regular-gallery]
10. **The gallery's Private toggle shows no on/off state.** The hand is the same white glyph in
    both lists; only the backdrop colour changes (VoiceOver reads "Private, Off"). Safari
    highlights the selected group. A filled hand (`hand.raised.fill`) or a selected background
    when on would do. Owner: tab switcher lane. [i17-46-private-gallery, i17-47-regular-gallery]
11. **Gallery and its bar at large text.** At Accessibility XL "Done" nearly fills the capsule's
    height, and card titles grow large; the gallery chrome needs the same cap as the pill (or the
    Large Content Viewer). Owner: tab switcher lane. [t-03-gallery-ax]
12. **Landscape iPhone: chrome takes ~40% of the height.** The pill and the button bar stay two
    rows in compact height (known in docs/polish-backlog.md, "Landscape iPhones"), and the page is
    pillarboxed with paper side bars where Safari lets the page's background run to the edges. In
    the landscape gallery the New Tab card is cut off at the safe-area edge, not the screen edge.
    Owner: shell (bar), tab switcher lane (gallery). [r-01-landscape-page, r-03-landscape-gallery]
13. **Fixed. Intro Skip's hit target was 35 x 20 pt.** The 44 pt frame sat outside the button, so
    it only spaced the label. [intro tree before/after: 35x20 → 44x44]
14. **Link preview pushes the menu off screen.** A long press on a link shows a full-height live
    preview, and the menu's last item ("Download Linked File") is cut off at the bottom edge until
    scrolled. Safari keeps its preview smaller so the menu fits. Owner: WebEngine link menu (a
    `previewProvider` with a capped `preferredContentSize`). [lm-01-link-menu]
15. **Empty states in sheets are bold, black and big.** Favorites' "Add favorites from the page
    menu." uses `ContentUnavailableView`'s bold title in system black, where every other sentence
    in Plain is regular ink or ink secondary (the start screen's sentence is body, secondary).
    Known in docs/polish-backlog.md (M4); a small shared `PaperEmptyState` (symbol + one
    sentence in ink secondary) would match. Owner: sheets. [i17-56-favorites-empty]
16. **Intro: "Made for iPhone Duo — Unfold for two pages side by side" shows on every iPhone.** On
    an iPhone 17 it promises something the phone can't do. Plain may not check the device model,
    and size classes can't tell a closed Duo from another phone; reword device-neutral, or keep it
    and accept it (Plain is Duo-first). Owner: lead's call. [i17-04-inside]

## Low

17. **Fixed. History and Archive Copy Link used `doc.on.doc` and no haptic**, where the page menu,
    the gallery and the link menu use `link` and the success haptic.
18. **Fixed. Intro wording: "cookie walls".** Plain answers cookie banners; a cookie wall is a
    pay-or-consent page it doesn't touch. Now "cookie banners".
19. **Fixed. Settings > Tab Layout footer taught a swipe that the wide screen lacks.** It shows
    only where a tab list fits, which has the top bar and no swipe up from the address bar; it now
    points to the Tabs button.
20. **Search result pages show the engine's host in the pill** ("google.com") where Safari shows
    the query. Owner: address bar lane. [i17-60-search-result, i17-safari-google]
21. **Typing an `http://` address waits ~5 s on a blank page** while the HTTPS upgrade times out
    before falling back (`automaticFallbackToHTTP`). Mostly local addresses; worth a shorter
    timeout or a progress cue. Owner: WebEngine. [i17-12-loading]
22. **Connection refused reads "Plain couldn't open this page."** A refused local port (after
    the HTTPS try) lands on the default sentence instead of "The site isn't answering." Check which
    error the upgrade fallback reports. Owner: WebEngine. [i17-63-noanswer]
23. **Back closing a link-opened tab switches with no motion**, where Safari slides back to the
    opener. Owner: shell. [nw-01-back-closing]
24. **Status band in a private tab** is a light lilac over a white page, the same seam as item 3.

## Checked and fine

First launch splash, the four intro steps and their motion, dissolve into search with the keyboard
up; suggestions (rows near the field, local rows nearest, no flicker seen); opening links;
bar collapse, hide, bottom-edge and status-bar reveal, scroll to top; Back/Forward (Forward hidden
in place until it applies); tab swipe left/right on the bar and past the last tab into a new tab;
Reopen toast; private tabs and their gallery; page menu sections, captions and Site Settings;
Find on Page; Reader in and out (Back closes it); Downloads toast, menu row and sheet; Settings,
Search Engine, App Icon, About, Clear History confirmation; History; Favorites strip; page
alerts and form keyboard; error pages (one sentence, Try Again); relaunch to the last tab at its
scroll position; dark mode start screen, page, menu.
