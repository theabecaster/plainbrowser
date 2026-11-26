#if canImport(UIKit)
import WebKit

/// Sign-in in web pages (docs/research/sign-in.md).
///
/// Passwords need nothing here: WebKit offers iOS AutoFill (the Passwords app and the password
/// managers the user turned on) in the keyboard's suggestion bar for login fields on its own, and
/// the engine keeps out of its way (no input accessory, no keyboard overrides, page fields left as
/// the site wrote them).
///
/// Passkeys need Apple's web-browser entitlement (`com.apple.developer.web-browser`), which Plain
/// does not have yet (`FixedChoices.passkeysEnabled`); with it WebKit handles them on its own. Without it WebKit still exposes `PublicKeyCredential`, and
/// `getClientCapabilities()` even claims a platform authenticator, but every request fails. So until
/// the entitlement lands the engine adds `passkeyFallback` to every frame:
/// - Feature checks say "no passkeys": `isUserVerifyingPlatformAuthenticatorAvailable()` and
///   `isConditionalMediationAvailable()` resolve false, and `getClientCapabilities()` reports the
///   passkey capabilities false. Sites then show their password sign-in, as they do in a browser
///   without passkeys, instead of a passkey button or prompt that can only fail.
/// - A passkey request a site makes anyway still fails as WebKit fails it (`NotAllowedError`), and
///   the page reports it so the shell can say why, once per site per launch
///   (`SignInPresenter.tab(_:couldNotUsePasskeysOn:)`). Silent (conditional) requests never report.
///
/// The overrides are `Proxy` objects around WebKit's own functions, so they keep their names and
/// still read as native code to sites that check.
enum SignInScripts {
    /// The engine-world message handler the passkey report arrives on.
    static let passkeyHandlerName = "plainPasskey"
    /// The DOM event the page-world script fires on a failed passkey request; the engine-world
    /// relay turns it into a message, so the page world gets no message handler of Plain's.
    static let passkeyFailedEvent = "plain-passkey-unavailable"

    static let passkeyFallbackSource = """
        (() => {
          const PKC = window.PublicKeyCredential;
          if (!PKC) return;
          const replace = (owner, name, apply) => {
            const original = owner[name];
            if (typeof original !== 'function') return;
            try {
              Object.defineProperty(owner, name, {
                value: new Proxy(original, { apply }), configurable: true, writable: true,
              });
            } catch (e) {}
          };
          const no = () => Promise.resolve(false);
          replace(PKC, 'isUserVerifyingPlatformAuthenticatorAvailable', no);
          replace(PKC, 'isConditionalMediationAvailable', no);
          const off = ['passkeyPlatformAuthenticator', 'userVerifyingPlatformAuthenticator',
            'hybridTransport', 'conditionalGet', 'conditionalCreate', 'conditionalMediation'];
          replace(PKC, 'getClientCapabilities', (target, self, args) =>
            Reflect.apply(target, self, args).then((capabilities) => {
              for (const key of off) if (key in capabilities) capabilities[key] = false;
              return capabilities;
            }));
          const credentials = navigator.credentials;
          if (!credentials) return;
          const report = (target, self, args) => {
            const result = Reflect.apply(target, self, args);
            const options = args[0];
            if (options && options.publicKey && options.mediation !== 'conditional') {
              result.catch((error) => {
                if (error && error.name === 'NotAllowedError') {
                  document.dispatchEvent(new CustomEvent('\(passkeyFailedEvent)'));
                }
              });
            }
            return result;
          };
          replace(credentials, 'get', report);
          replace(credentials, 'create', report);
        })();
        """

    /// In the page's world: it changes what the page's own scripts see. Every frame, at document
    /// start, before any page script runs.
    static let passkeyFallback = WKUserScript(
        source: passkeyFallbackSource, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page
    )

    /// Relays `passkeyFailedEvent` to the engine. At most one message per document: the engine
    /// only needs to know that the site tried.
    static let passkeyRelaySource = """
        (() => {
          document.addEventListener('\(passkeyFailedEvent)', () => {
            try { webkit.messageHandlers.\(passkeyHandlerName).postMessage(1); } catch (e) {}
          }, { once: true });
        })();
        """

    static let passkeyRelay = WKUserScript(
        source: passkeyRelaySource, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: UserScripts.world
    )
}

/// What the shell says about sign-in. Every requirement has a default, so a shell without it keeps
/// compiling.
public protocol SignInPresenter: AnyObject {
    /// A page in `tab` asked for a passkey and WebKit refused it, because Plain can't use passkeys
    /// until Apple grants the web-browser entitlement (`FixedChoices.passkeysEnabled`). Called at
    /// most once per site per launch, for private tabs too. The shell says so in one sentence
    /// when `tab` is on screen. Default: nothing.
    func tab(_ tab: Tab, couldNotUsePasskeysOn site: String)
}

extension SignInPresenter {
    public func tab(_ tab: Tab, couldNotUsePasskeysOn site: String) {}
}
#endif
