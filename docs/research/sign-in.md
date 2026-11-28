# Sign-in: passkeys, passwords and password managers (2026-11-26)

What a `WKWebView` browser on iOS 27.2 can do for sign-in, and what Plain does. Facts marked
**measured** were checked on the iPhone 17 simulator (iOS 27.2) in this repo. **SDK** means the
iOS 27.2 SDK headers. Everything else cites its source.

## Bottom line

- **Passkeys** in web pages need Apple's `com.apple.developer.web-browser` entitlement. With it,
  `WKWebView` handles WebAuthn for every site by itself, with no extra code. Without it, every
  passkey request for another site fails.
- **Passwords from AutoFill** (the Passwords app, 1Password, Bitwarden and other managers) also
  wait for the entitlement in practice. On iOS 27.2 the keyboard's "Passwords" button shows for
  a web login field in Safari, but not in Plain or in a bare `WKWebView` in the same app. A
  native username field in that same app does get the button (**measured**).
- **Saving a new password** after sign-in ("Save password?") is not possible for any
  third-party browser. Only Safari gets it, through private API.

Plain's part: ask Apple for the entitlement (the owner submits it), stay out of AutoFill's way,
and until the grant, steer sites to password sign-in instead of a passkey prompt that can only
fail.

## Works now (no entitlement)

| What | Notes |
|---|---|
| Typing or pasting a password, or copying one from a password manager app | Always works. |
| The page's form bar (Previous, Next, Done) on login fields | **Measured.** Plain adds no input accessory and changes no keyboard settings, so WebKit's own bar shows. |
| Login fields keep the site's `autocomplete` hints (`username`, `current-password`, `new-password`, `one-time-code`) | **Measured** (`SignInTests`). WebKit maps them to `UITextContentType` and sends the system an AutoFill context with the page URL (`_WebViewURL`) and `_acceptsLoginCredentials` (WebKit source, `WKContentViewInteraction.mm` `_autofillContext`). |
| `PublicKeyCredential` exists in pages | **Measured.** `isUserVerifyingPlatformAuthenticatorAvailable()` and `isConditionalMediationAvailable()` resolve false. But `getClientCapabilities()` reports `passkeyPlatformAuthenticator`, `hybridTransport`, `conditionalGet` and more as true, so a site that checks it offers passkeys that then fail. Plain corrects this (below). |
| Passkeys and AutoFill for the app's own domains (`webcredentials:` associated domains) | Apple, [Supporting passkeys](https://developer.apple.com/documentation/authenticationservices/supporting-passkeys). Useless for a browser: it covers only domains whose `apple-app-site-association` lists the app. |

## Needs the web-browser entitlement

| What | Source |
|---|---|
| Passkeys for every site in `WKWebView`, including passkey AutoFill (conditional UI), hybrid sign-in with a phone, and security keys | Apple staff, July 2026: "For an iOS web browser to use passkeys, all you need is the `com.apple.developer.web-browser` entitlement. The WKWebView itself then provides the full support." ([forum 837755](https://developer.apple.com/forums/thread/837755)). Apple, [Passkey use in web browsers](https://developer.apple.com/documentation/authenticationservices/passkey-use-in-web-browsers): with `WKWebView`, "WebKit automatically handles WebAuthentication challenges". |
| AutoFill's "Passwords" button and site-matched suggestions on web login fields | **Measured** gate: Safari shows it, a bare `WKWebView` in a plain app does not, a native field in the same app does. Entitled browsers (Firefox, Chrome, Brave) show site-matched suggestions ([forum 719636](https://developer.apple.com/forums/thread/719636), a developer's observation, not Apple documentation). The decision is in the system's closed AutoFill code, not WebKit, so confirm on the device after the grant. |
| Being chosen as the default browser | [`com.apple.developer.web-browser`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser). |
| Service workers in `WKWebView`, full script access on all domains, Add to Home Screen | Apple, [Preparing your app to be the default web browser](https://developer.apple.com/documentation/xcode/preparing-your-app-to-be-the-default-browser). |

On iOS no second key is needed. `com.apple.developer.web-browser.public-key-credential` and its
[request form](https://developer.apple.com/contact/request/macos-browsers-passkeys/) are for macOS
and Mac Catalyst only ([entitlement page](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential)).
Firefox, DuckDuckGo and Brave ship `web-browser` and no public-key-credential key (their
entitlements files on GitHub: `firefox-ios/Client/Entitlements/FirefoxApplication.entitlements`,
`duckduckgo/apple-browsers` `iOS/DuckDuckGo/DuckDuckGo.entitlements`, `brave/brave-core`
`ios/brave-ios/App/iOS/Entitlements/Release (AppStore).entitlements`).

Browsers that ship their own engine call `ASAuthorizationPlatformPublicKeyCredentialProvider`'s
`clientData` requests and `ASAuthorizationWebBrowserPublicKeyCredentialManager` (iOS 17.4+,
**SDK**; `isDeviceConfiguredForPasskeys` is iOS 26.2+). A `WKWebView` browser needs neither.

## Not possible for a third-party browser

| What | Why |
|---|---|
| The system "Save password?" prompt after a web sign-in, and strong-password suggestions on sign-up forms | Not from `WKWebView` in other apps ([forum 654338](https://developer.apple.com/forums/thread/654338), [705522](https://developer.apple.com/forums/thread/705522)). Safari uses private SPI (`_webView:focusRequiresStrongPasswordAssistance:`); App Review Guideline 2.5.1 forbids it. |
| Writing a password into the Passwords app or another manager for any site | `SecAddSharedWebCredential` needs an associated domain. `ASSavePasswordRequest` (iOS 26.2, **SDK**) is the provider side: the system sends it to a password manager's extension; apps can't send one. `ASCredentialUpdater` (iOS 26) only reports changes for the app's own domains. |
| Separate username and password pages filling in one go | Reported broken in plain `WKWebView` ([forum 772213](https://developer.apple.com/forums/thread/772213)). Recheck after the grant. |

Browsers that offer "save password" (Firefox, DuckDuckGo, Brave, Chrome) keep their own password
store and register it as a system AutoFill provider
(`com.apple.developer.authentication-services.autofill-credential-provider`). Plain keeps no
password store of its own (`FixedChoices.passwordsFromSystemAutoFill`): the system already holds
the user's passwords and passkeys, and a second store is one more to keep in sync.

New in iOS 27.2 (**SDK**), for browsers with their own password manager only:
`WKNavigationDelegate.webView(_:willSubmitForm:submissionHandler:)` with `WKFormInfo` (the
submitted values), and `WKContentWorld.Configuration.autofillScriptingEnabled`. Plain doesn't use
them.

## What Plain does

- **Passwords:** nothing to turn on. The engine adds no input accessory, no keyboard overrides and
  no script that touches form fields, keeps the app active state alone (no privacy blur on
  resign, which Apple says breaks a Face ID fill), and leaves AutoFill to the system.
  `SignInTests` (engine) checks the hints survive and fields focus.
- **Passkeys, until the grant** (`FixedChoices.passkeysEnabled = false`, `WebEngine/SignIn.swift`):
  - In every frame, before page scripts run, `isUserVerifyingPlatformAuthenticatorAvailable()`
    and `isConditionalMediationAvailable()` resolve false and `getClientCapabilities()` reports
    the passkey capabilities false. Sites then show password sign-in, as in a browser without
    passkeys. The overrides are `Proxy` objects, so they still read as native code.
  - A passkey request a site makes anyway is refused at once with `NotAllowedError`, the error
    WebKit gives. WebKit itself answers only seconds later (**measured** on the simulator: about
    3 s for a request with a 5 s timeout), and a site's timeout is often a minute or more. The
    site's own fallback then runs right away, and Plain shows one toast: "Passkeys aren't available in Plain yet. Use your password." (the
    clarity audit: it says what the user can do, not why). Once per site per launch, only for the page on screen, never for silent
    (conditional) requests. Signpost `signIn.passkeyUnavailable`.
- **Default browser, ready for the grant:** `CFBundleURLTypes` declares http and https, the scene
  delegate opens web links other apps hand over (at launch, while running, and while the first-run
  intro is up, which then waits for the next launch), and `Plain/Plain-WebBrowser.entitlements` holds the key.

## Apple's default-browser requirements, checked

From [Preparing your app to be the default web browser](https://developer.apple.com/documentation/xcode/preparing-your-app-to-be-the-default-browser):

| Requirement | Plain |
|---|---|
| Info.plist declares the HTTP and HTTPS schemes | Yes, `CFBundleURLTypes` (added with this work). |
| On launch, show a text field for a URL, search, or bookmarks | Yes: the search sheet with the field focused, and favorites above the keyboard. |
| Open any URL it is given and show the expected content, with no unexpected redirects or hard-coded destinations | Yes: links open in a new tab (`BrowserViewController.open(externalURL:)`). Only Safe Browsing (`isFraudulentWebsiteWarningEnabled`) can interrupt. |
| No `UIWebView` | Yes: `WKWebView` only. |
| Info.plist keys browsers may not have (`NSPhotoLibraryUsageDescription`, `NSLocationAlways*`, `NSHomeKitUsageDescription`, `NSBluetoothAlwaysUsageDescription`, `NSHealth*`) | None. Plain has `NSPhotoLibraryAddUsageDescription` (add-only) and `NSLocationWhenInUseUsageDescription`, which are different keys. |
| Universal links for specific domains are ignored once entitled | Plain claims none. |

## When Apple grants it

1. Copy the `com.apple.developer.web-browser` key from `Plain/Plain-WebBrowser.entitlements`
   into `Plain/Plain.entitlements` (the app's entitlements since v0.2, which hold the App Group),
   then `xcodegen generate`. Automatic signing picks the entitlement up from the App ID once
   Apple has added it.
2. Set `FixedChoices.passkeysEnabled` and `FixedChoices.defaultBrowserPromptsEnabled` to true.
3. In `PlainUITests/SignInTests.testLoginFieldBringsUpTheKeyboard`, turn the skip into a failure.
4. Run the device checks below, then move the `docs/feedback.md` entry to Done.

## Device checks (the Duo, with 1Password and iCloud Keychain)

Before the grant (this build):

1. Settings > General > AutoFill & Passwords: turn on Passwords and 1Password.
2. In Plain, open a login page (github.com/login, accounts.google.com). Tap the username field.
   Note whether the suggestion bar shows "Passwords" or a key. Expected: no (the simulator shows
   none). If it does show, tap it: Face ID, pick an account, check that both fields fill. Repeat
   with 1Password as the provider.
3. github.com/login: no passkey prompt opens by itself. Tap "Sign in with a passkey": the page
   shows its own error, and Plain shows the toast once. Tap it again: no second toast.
4. A Google account whose sign-in prefers a passkey: Google should go to the password step
   instead of a passkey prompt.
5. webauthn.io: Register fails with the toast. Nothing hangs, and no system sheet opens.
6. Sign in on a site that has a password saved in 1Password using 1Password's share sheet or copy
   and paste, to confirm nothing blocks pasting into the field.

After the grant (signed with the entitlement):

1. Settings > Apps > Default Browser App lists Plain. Choose it. Tap a link in Messages and in
   Mail: it opens in Plain in a new tab, with the app running and from a cold launch.
2. Login fields show "Passwords" with the site's own accounts first. Fill from iCloud Keychain,
   then from 1Password.
3. webauthn.io: register a passkey into iCloud Keychain, then into 1Password, then sign in with
   each. Try "Sign in with a passkey" on github.com and google.com, passkey AutoFill (tap the
   username field: the passkey appears in the suggestion bar), and a phone's QR code (hybrid).
4. No toast appears for any of these.
5. Run `scripts/perf-gate.sh --device`: the fallback script is gone, so nothing should change.
