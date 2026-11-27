# Switched-off features and denied permissions

What Plain depends on that the user, a parent (Screen Time) or iOS can switch off, what happened
in each state before this work (dev at `3c1c30c`), and what happens now. The rules that came out
of it are in `docs/ui-reference.md` ("Switched-off features"); the reasons are in
`docs/decisions.md` ("Switched-off features: one quiet line at the moment of need").

## Sources

- **Apple HIG, Privacy** (https://developer.apple.com/design/human-interface-guidelines/privacy):
  "Ideally, wait to request permission until people actually use an app feature that requires
  access." "Avoid requesting permission at launch unless the data or resource is required for
  your app to function." A screen before the system's alert only "if it's essential", with one
  button and no way to cancel.
- **Apple HIG, Alerts** (https://developer.apple.com/design/human-interface-guidelines/alerts):
  "Avoid using an alert merely to provide information… prefer finding an alternative way to
  communicate it within the relevant context." For a problem like no network, "show cached or
  placeholder data and a nonintrusive label that describes the problem."
- **Apple HIG, Onboarding** (https://developer.apple.com/design/human-interface-guidelines/onboarding):
  ask "when people first access the specific function that relies on private data or resources."
- **Apple, "Write clear purpose strings"** (Tech Talk 110152,
  https://developer.apple.com/videos/play/tech-talks/110152): say specifically how the data is
  used, with an example.
- **Apple, "Detecting available Apple Foundation Models"**
  (https://developer.apple.com/documentation/foundationmodels/detecting-available-apple-foundation-models,
  read 2026-11-27): "In iOS 27, iPadOS 27, macOS 27, and visionOS 27 or later, Apple Intelligence
  is on by default and can no longer be turned off." `appleIntelligenceNotEnabled` "occurs in iOS
  26". `modelNotReady` is most common "while the model is downloading" and resolves by itself.
  For `deviceNotEligible`, "it's best to let a person figure out if any of those scenarios apply
  to them."
- **Apple API docs**: `UIApplication.openSettingsURLString` opens Plain's page in Settings;
  `CTCellularData.restrictedState == .restricted` is "a state that denies access to cellular
  data"; `NWPath.UnsatisfiedReason` has `cellularDenied`, `wifiDenied`, `localNetworkDenied`;
  `ProcessInfo.isLowPowerModeEnabled`: "reduce activity in your app"; `STWebpageController`
  (Screen Time) covers a blocked page itself.
- **WebKit source** (github.com/WebKit/WebKit, main, read 2026-11-27):
  `UserMediaPermissionRequestManagerProxy::requestSystemValidation` checks the app's
  `AVCaptureDevice` authorization *before* the UI delegate: not determined, WebKit asks iOS
  itself; denied or restricted, it denies the request and never calls
  `decideMediaCapturePermissionsFor`. The page gets `NotAllowedError`.
  `CoreLocationGeolocationProvider.mm`: not determined, WebKit calls
  `requestWhenInUseAuthorization`; denied or restricted, every waiting request completes `false`
  and `requestGeolocationPermissionFor` is never called; the page gets `PERMISSION_DENIED`. A
  change to denied while a page watches stops the updates (`resetGeolocation`).
- **NN/g, "Permission Requests"** (https://www.nngroup.com/articles/permission-requests/): ask in
  context when the user picks the feature; after a denial "clearly explain why that functionality
  can't be used, and make it easy for them to grant access", with a link straight to Settings.
- **Firefox for iOS** (open source, mozilla-mobile/firefox-ios): a cellular-off error page when
  `CTCellularData.restrictedState == .restricted` and the load failed as offline ("Cellular data
  is turned off for Firefox."), and an "Open Settings" alert for a later denied request, nothing
  right after the system's own denial.
- Not found or not verified: Safari's exact cellular-off wording; how Chrome and Arc for iOS
  handle a system-denied site request; a Baymard article on this.

## What the sources decide

1. Never ask or explain at launch. iOS's own prompt appears when a site first asks (WebKit shows
   it), with Plain's purpose string; Plain adds no screen before it.
2. Right after the user says no in iOS's prompt, say nothing more: they just chose.
3. Later, when a site asks again and the feature is off for Plain, explain once, in context, in
   one line, with one way to fix it (Settings). Not an alert: the user's own action isn't blocked,
   the site's request is.
4. Once per site until the switch changes: a site that asks on every page must not nag.
5. Where Plain's page in Settings can't help (Screen Time), explain without a button.
6. Connection problems are inline, on the error page, and name the real cause (cellular data off
   for Plain is not "offline").
7. Apple Intelligence: never ask the user to turn it on (it can't be off on iOS 27); leave the
   entries out where the model can't run, and let them appear by themselves when it can.
8. Silent where nothing the user wanted is blocked (Spotlight, Handoff, Siri, Low Power Mode).

## The matrix

"Before" is dev at `3c1c30c`; "Now" is this branch. "Later revoked" means turned off in Settings
while Plain is open: iOS ends an app's process when its camera, microphone or Photos access is
turned off (Plain then reopens on its last tab), and keeps it running for location and cellular.

### Camera and microphone for websites (`getUserMedia`)

| State | Before | Now |
|---|---|---|
| Not determined | WebKit shows iOS's prompt (Plain's usage string), then Plain's alert "Allow site to use your camera?"; the answer is remembered per site | Unchanged |
| Allowed, site never asked | Plain's alert, remembered | Unchanged |
| Denied for Plain | WebKit denies before asking Plain; the page fails, **Plain says nothing** | One toast, once per site: "Camera is off for Plain" (or "Camera and microphone are off for Plain") with **Settings** |
| Restricted (Screen Time, profile) | Silent failure | "Camera isn't allowed on this iPhone", no button |
| Later revoked | iOS ends Plain; it reopens on the last tab | Unchanged; the next request explains as above |
| A site the user said Don't Allow | Remembered forever; **no way to change it** in Plain | Site Settings lists it: "Not Allowed"; a tap allows it |
| Site allowed, camera off for Plain | Nothing showed | Site Settings: "Camera — Off in Settings"; a tap opens Settings |

### Location for websites (Core Location, while in use)

| State | Before | Now |
|---|---|---|
| Not determined | WebKit asks iOS (when in use), then Plain's alert | Unchanged |
| Denied for Plain | Silent: the page gets `PERMISSION_DENIED` | "Location is off for Plain" with Settings, once per site |
| Location Services off for the phone | Silent | "Location Services are off" with Settings |
| Restricted | Silent | "Location isn't allowed on this iPhone", no button |
| Approximate only | Pages get approximate positions | Unchanged (nothing is blocked; nothing to say) |
| Later revoked | WebKit stops the page's updates; silent | The next request explains |
| Site Settings | No row | "Location — Allowed / Not Allowed / Off in Settings" |

### Adding images to Photos (Save Image)

| State | Before | Now |
|---|---|---|
| Not determined | iOS's prompt on the first save | Unchanged; a No then gets the "nothing there" haptic only (the user just chose) |
| Allowed (add only) | Saves, success haptic | Unchanged |
| Denied | **Only a "nothing there" haptic** | "Saving to Photos is off for Plain" with Settings, every time (the user's own action) |
| Restricted | Haptic only | "Saving to Photos isn't allowed on this iPhone" |
| Later revoked | iOS ends Plain | Unchanged |

### Downloads and Files

No permission. Downloads go to Plain's own folder (Files > On My iPhone > Plain > Downloads), Save
PDF to Files uses the system's picker. A failed download already says "…didn't download" with
Show. Nothing changed.

### Apple Intelligence (Browse for Me, Summarize Page)

| State | Before | Now |
|---|---|---|
| Not eligible | Entries left out, no hint | Unchanged |
| Off (`appleIntelligenceNotEnabled`) | Left out | Unchanged. On iOS 27 it can't be off (Apple); the case is iOS 26's |
| Model downloading or preparing | Left out; looked again only on a return to the app | Also looked again every 30 s while on screen (`FixedChoices.aiNotReadyRecheck`), so the entries appear soon after it is ready |
| Language not supported | Left out | Unchanged |
| Becomes unavailable while Plain is away | Entries updated on return; an open summary on its way depended on the model's error | Entries leave on return (no flicker: only a changed answer updates them); a summary on its way ends with one line, "Apple Intelligence isn't available right now."; a finished one stays |
| Held back by the system (rate limited, e.g. in the background) | "Isn't available right now", **no Try Again** | "Apple Intelligence is busy. Try again in a moment." with Try Again |

### Network

| State | Before | Now |
|---|---|---|
| Offline (no Wi-Fi, no cellular) | "You're offline." Try Again; a saved reading-list copy opens over it | Unchanged |
| Cellular data off for Plain, no Wi-Fi | **"You're offline."** | "Cellular data is off for Plain." **Open Settings**, Try Again under it; turning it back on reloads the page by itself |
| Wi-Fi off for Plain (the WLAN switch some regions have) | "You're offline." | "Wi-Fi is off for Plain." Open Settings, Try Again |
| Low Data Mode | Pages load normally | Unchanged (nothing blocked) |
| Local network denied | Not verified: a load of a LAN address may fail as "isn't answering" | Unchanged; open (see below) |

### Everything else

| Feature | What depends on it | Before and now |
|---|---|---|
| Low Power Mode | Nothing of Plain's: no background refresh, no polling; iOS and WebKit lower their own work | Silent, correct |
| Screen Time content limits | WebKit's built-in filter blocks a page (WebKit error 104 or 106) | Before: "Plain couldn't open this page." Now: "This site isn't allowed on this iPhone." Where the filter has its own page, WebKit loads it next and Plain's line clears |
| Screen Time per-website time limits | Needs `STWebpageController` per tab | Not integrated (open, see below) |
| Siri and Shortcuts | App Shortcuts and intents | Work in Shortcuts whatever Siri's state; nothing in the app depends on Siri. Silent, correct |
| Spotlight off for Plain | Favorites indexed | iOS hides them; indexing calls still succeed. Silent, correct |
| Background App Refresh | Not used (downloads use `beginBackgroundTask`, which it doesn't affect) | Nothing to handle |
| Handoff off | Current page offered to other devices | iOS doesn't offer it. Silent, correct |
| Notifications | Not used (no web push) | Nothing to handle |

## How Plain knows

- `SystemAccessMonitor` (WebEngine) reads camera, microphone (`AVCaptureDevice`), location
  (`CLLocationManager`, off the main thread), Photos add (`PHPhotoLibrary`) and cellular
  (`CTCellularData`) after the first frame and on every return to the app, and follows
  `NWPathMonitor` and cellular changes. Only changed answers update anything.
- Because WebKit denies a request for a switched-off feature without asking Plain, a small script
  in the page's own world (`AccessRequestWatch`) hears the `getUserMedia`, `getCurrentPosition` and
  `watchPosition` calls, and only for the features that are off right now. With everything on, no
  page gets a script of Plain's in its world.

## Verified on the simulator, to check on the device

Verified with UI tests (`PlainUITests/SystemAccessTests`) and captures: the location, camera and
Screen Time toasts, once per site; the cellular error page; Site Settings' "Off in Settings";
Save Image with Photos revoked (`simctl privacy revoke photos-add`); a summary ending when the
model goes away. On the device: the real camera prompt order (iOS's, then Plain's), that turning
camera access off in Settings ends Plain and it reopens on its tab, the cellular page with
Settings > Plain > Cellular Data off on cellular, and the Screen Time block page.

## Open

- **Screen Time per-website limits:** `STWebpageController` per tab would let parents' website
  limits apply in Plain and cover a blocked page as Safari does. It sits on the hot path (one per
  tab, over the web view), so it needs its own lane with the perf gate.
- **Local network:** whether a WKWebView load of a LAN address asks iOS's local network
  permission, and what it fails with when denied, is unverified; Plain has no
  `NSLocalNetworkUsageDescription`.
