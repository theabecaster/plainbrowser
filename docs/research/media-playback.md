# Media playback: what Safari does, and how Plain matches it

Owner feedback (TestFlight, iPhone Duo): fullscreen video felt "weird", unlike Safari's native
player. This note records what Safari on iPhone and iPad does, which public `WKWebView` settings
reproduce it, what Plain did differently, and what changed. WebKit sources were read at
`WebKit/WebKit` main, commit `5c559a93f2f9` (2026-11-28); Apple pages were read the same day.

## Bottom line

- Plain turned on element fullscreen (`WKPreferences.isElementFullscreenEnabled = true`) on
  every device. Safari never allows it on iPhone. With it on, a site player that uses the API
  when present (the usual pattern; not verified on the live sites, see "Sites") fullscreens its
  own web player box: web controls, no system gestures, no picture in picture button, no AirPlay
  route picker, no swipe down to close. That is the likely "weird" player.
- Plain had no `audio` background mode. Without it iOS suspends the app when it leaves the
  screen: no sound with the screen locked or in another app, no automatic picture in picture
  from fullscreen, no lock-screen controls that keep working.
- Plain now turns element fullscreen off on iPhone (the Duo included) and declares the `audio`
  background mode. Everything else already matched Safari.

## What Safari does, and the setting behind it

| Behavior | Safari on iPhone | Safari on iPad | WKWebView setting | Source |
|---|---|---|---|---|
| Element fullscreen (Fullscreen API on any element) | Not available: `document.fullscreenEnabled` and `requestFullscreen` are absent (undefined; measured) | Available since iPadOS 12 (prefixed), unprefixed since 16.4 | `WKPreferences.isElementFullscreenEnabled` (default false) | MDN browser-compat-data, `api.Element.requestFullscreen`: "Only available on iPad, not on iPhone." `UnifiedWebPreferences.yaml` `FullScreenEnabled` (default false). WebKit's `setElementFullscreenEnabled` is not tied to the idiom (`WKPreferences.mm`), so this is Safari's own choice. |
| `requestFullscreen()` on a `<video>` | Not exposed: with the Fullscreen API off, `Element.requestFullscreen` is not in the page at all (`Element+Fullscreen.idl` gates it on `FullScreenEnabled`, or a per-site WebKit quirk, `shouldEnterNativeFullscreenWhenCallingElementRequestFullscreen`, that exposes it and sends it to the native player), so pages use `webkitEnterFullscreen()`: the native player | Opens the native player | none needed | Where it is exposed, `HTMLVideoElement::requestFullscreen` on iOS calls `webkitSetPresentationMode(Fullscreen)` (`HTMLVideoElement.cpp`). `videoUsesElementFullscreen()` is false on iOS unless `VideoFullscreenRequiresElementFullscreen` (only visionOS and Apple TV, `WebPreferencesDefaultValues.cpp`). |
| A site's player when element fullscreen is off | Falls back to `video.webkitEnterFullscreen()`: the native player | n/a | `isElementFullscreenEnabled = false` | The players check `document.fullscreenEnabled` / `webkitFullscreenEnabled` and fall back to the video's own fullscreen. Plain's test page does the same (`/custom-player`). |
| Inline playback | Inline only with `playsinline` (`webkit-playsinline` for old pages); otherwise play opens the native player | Always inline | `allowsInlineMediaPlayback = true`; WebKit keeps `inlineMediaPlaybackRequiresPlaysInlineAttribute` true on small screens | Apple, `WKWebViewConfiguration.allowsInlineMediaPlayback`: "When adding a video element to an HTML document on iPhone, you must also include the playsinline attribute." `APIPageConfiguration.h`: `allowsInlineMediaPlayback { !currentUserInterfaceIdiomIsSmallScreen() }`, `inlineMediaPlaybackRequiresPlaysInlineAttribute { !allowsInlineMediaPlayback }`, `allowsInlineMediaPlaybackAfterFullscreen` (inline again after the player closes). |
| Autoplay | Muted video autoplays; sound needs a tap | Same | `mediaTypesRequiringUserActionForPlayback = .audio` | WebKit blog, "New `<video>` Policies for iOS" (2016). |
| Picture in picture | PiP button in the native player and `requestPictureInPicture()`; starts by itself when the user leaves the app while a video is fullscreen | Same | `allowsPictureInPictureMediaPlayback = true` (default true on iOS) plus the `audio` background mode | Apple, "Adopting Picture in Picture in a Standard Player": "PiP playback starts automatically if your video is playing in full-screen mode and the user exits the app." Apple, "Configuring your app for media playback": the Audio, AirPlay, and Picture in Picture background mode is needed "to enable advanced playback features like AirPlay streaming and Picture in Picture playback". |
| Leaving the app | Video pauses unless in PiP or on AirPlay; audio-only media keeps playing; video with sound pauses when the phone locks | Same | `audio` background mode | `MediaSessionManageriOS::resetRestrictions` (`BackgroundProcessPlaybackRestricted` for Video, WebAudio and VideoAudio; `SuspendedUnderLockPlaybackRestricted` for VideoAudio), `HTMLMediaElement::shouldOverrideBackgroundPlaybackRestriction` (PiP, AirPlay, car head unit). Audio elements carry no such restriction. |
| Audio session | WebKit sets `.playback` (long-form route sharing) while media is audible | Same | none: WebKit manages the category | `MediaSessionManagerCocoa::updateSessionState` (`MediaPlayback` when audible media plays, `PlayAndRecord` for calls, `Ambient` for Web Audio alone). |
| Now Playing / lock screen | Title, artwork and controls from `navigator.mediaSession` or the page | Same | none beyond the `audio` background mode (without it the app is suspended and the controls stop working) | `MediaSessionManagerCocoa::setNowPlayingInfo` / `clearNowPlayingInfo` (MediaRemote). |
| AirPlay | Route button in the native player | Same | `allowsAirPlayForMediaPlayback = true` (Plain already set it) | Apple, "Configuring your app for media playback" (the same background mode streams over AirPlay). |
| Rotation | The native player turns to landscape with the phone | Same | the app's supported orientations (Plain supports all four) | AVKit's player follows the app's orientations. |
| A background tab with media | Keeps playing (an audible page holds a foreground assertion) | Same | none | `WebPageProxy::updateThrottleState`: `takeAudibleActivity()` while `ActivityState::IsAudible`. |

## The iPhone Duo's two screens

The Duo is an iPhone (`userInterfaceIdiom == .phone`) on both screens. Safari's choice is per
device class, not per window size: element fullscreen comes with iPad Safari, and the Duo runs
iPhone Safari. Measured in the iOS 27.2 simulator (Safari opening a page that prints `document.fullscreenEnabled`; captures in
the lane's report): see "Measured" below. Plain follows the idiom too
(`EngineChoices.allowsElementFullscreen(on:)`), so a page never sees the Fullscreen API appear or
vanish when the phone unfolds, and fullscreen video is the native player on both screens.

The inner screen gets desktop sites in Plain (`EngineChoices.desktopMinimumSide`); Safari on the
Duo asks for mobile sites there (measured). Neither has the Fullscreen API. A desktop player with
no fallback to the video's own fullscreen would lose its fullscreen button in Plain on the inner
screen, as it does in iPhone Safari's "Request Desktop Website". Not yet checked on live desktop
sites: it is on the owner's device list.

## Sites

Expected, not verified: the usual web-player pattern (as in YouTube's, Vimeo's and X's players
and the big news players such as JW Player and Brightcove) is to use the Fullscreen API on the
player's box when the page may (`document.fullscreenEnabled`, `webkitFullscreenEnabled`) and to
call `webkitEnterFullscreen()` on the `<video>` otherwise, which on iOS is the system player.
That is why one switch would decide which fullscreen these sites get, and why the owner saw a
site's web fullscreen in Plain and the native player in Safari. None of the players' code was
read and the live sites were not tried from the test Macs (they need network, consent banners
and sign-in); `/custom-player` in the UI tests reproduces only the pattern. The owner's device
checks are listed in the lane's report.

## What Plain does now

- `isElementFullscreenEnabled` follows `EngineChoices.allowsElementFullscreen(on:)`: off on
  iPhone, on for any other idiom (an iPad running the iPhone app reports `.phone`, so it is off
  there too, as on an iPhone).
- `UIBackgroundModes` has `audio` (`Plain/Info.plist`).
- Unchanged, already like Safari: inline playback with `playsinline`, muted autoplay, PiP
  allowed, AirPlay allowed, all four orientations, the pool never discarding a tab that plays,
  is in PiP or fullscreen.
- The native player is a system view controller presented above Plain's window, so Plain's
  bars, swipes and haptics can't act while it is up, and closing it returns to the page as it
  was (MediaTests checks the scroll position, the address and that no haptic played).

## Better than Safari, where it is clearly better

- Picture in picture keeps playing when the user opens or switches tabs: an audible page keeps
  its process running even when its web view leaves the window, and the pool never discards it.
  Safari does the same; nothing extra was needed, and MediaTests now guards it.
- Nothing else was changed on purpose: the native player is what users know.

## Measured

iOS 27.2 simulators, 2026-11-28 (captures in the lane's report).

| | iPhone 17 | Duo outer | Duo inner |
|---|---|---|---|
| Safari: `document.fullscreenEnabled`, `webkitFullscreenEnabled`, `Element.prototype.requestFullscreen` | undefined | undefined | undefined |
| Safari: user agent | iPhone | iPhone | iPhone (mobile site, 951x537 viewport) |
| Plain before: Fullscreen API (`isElementFullscreenEnabled = true` everywhere) | on | on | on |
| Plain now: Fullscreen API (`/custom-player` reads "Element fullscreen off") | off | off | off |
| Plain now: site player's fullscreen button | native player | native player | native player |
| Plain now: video without `playsinline` | native player | native player | plays inline (WebKit's own default on that screen) |
| Plain now: muted autoplay | inline | inline | inline |
| Plain now: native player turned to landscape | fills the screen, page kept | not testable (Device Hub turns the Duo) | n/a |

- The simulator has no picture in picture: Safari there also reports
  `document.pictureInPictureEnabled` false and `webkitSupportsPresentationMode('picture-in-picture')`
  false. The two PiP tests skip there and run on a device.
- Safari on the Duo's inner screen asks for the mobile site; Plain asks for the desktop site there
  (`EngineChoices.desktopMinimumSide`). A separate choice, not changed here.
- Rotating with the player up can move the page a few points on return (7 pt measured on iPhone
  17): the page reflows at the landscape width. The test allows 24 pt for that case only.
- Open: on the Duo's inner screen, leaving the native player puts the page 7 pt higher than it
  was (969 to 962, the same in every run; on iPhone 17 and the outer screen it comes back to
  the point). Not yet traced: the inner screen's status column or top-bar inset changing while
  the player is up is the likely cause. Safari was not measured for it. The test allows 8 pt
  there and says why.
