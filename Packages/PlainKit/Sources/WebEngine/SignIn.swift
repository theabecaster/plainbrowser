#if canImport(UIKit)
import WebKit

/// Sign-in in web pages (docs/research/sign-in.md).
///
/// Passwords need no code: WebKit hands login fields to iOS AutoFill (the Passwords app and the
/// password managers the user turned on), and the engine keeps out of its way (no input accessory,
/// no keyboard overrides, page fields left as the site wrote them). The system shows AutoFill's
/// Passwords button on web fields only to apps with Apple's web-browser entitlement (measured).
///
/// Passkeys need that entitlement (`com.apple.developer.web-browser`) too, which Plain does not
/// have yet (`FixedChoices.passkeysEnabled`); with it WebKit handles them on its own. Without it
/// WebKit still exposes `PublicKeyCredential`, and `getClientCapabilities()` even claims a platform
/// authenticator, but every request fails, seconds later or only at the request's timeout. So
/// until the entitlement lands the engine adds `passkeyFallback` to every frame:
/// - Feature checks say "no passkeys": `isUserVerifyingPlatformAuthenticatorAvailable()` and
///   `isConditionalMediationAvailable()` resolve false, and `getClientCapabilities()` reports the
///   passkey capabilities false. Sites then show their password sign-in, as they do in a browser
///   without passkeys, instead of a passkey button or prompt that can only fail.
/// - A passkey request a site makes anyway is refused at once with `NotAllowedError`, the error
///   WebKit would give later, so the site's own fallback runs right away, and the page reports it
///   so the shell can say why, once per site per launch
///   (`SignInPresenter.tab(_:couldNotUsePasskeysOn:)`). Silent (conditional) requests go to WebKit
///   untouched and never report.
///
/// The overrides are `Proxy` objects around WebKit's own functions, so they keep their names and
/// still read as native code to sites that check.
struct SignInScripts {
    /// The engine-world message handler the passkey report arrives on.
    static let passkeyHandlerName = "plainPasskey"

    /// In the page's world: it changes what the page's own scripts see. Every frame, at document
    /// start, before any page script runs.
    let passkeyFallback: WKUserScript
    /// Relays the fallback's event to the engine, at most once a second per frame.
    let passkeyRelay: WKUserScript

    /// - Parameter token: makes the DOM event's name unguessable (one per pool), so a page can't
    ///   fire it to show Plain's toast. The fallback keeps its own references to
    ///   `dispatchEvent` and `CustomEvent` from before any page script ran.
    init(token: String = UUID().uuidString) {
        let event = "plain-passkey-\(token)"
        passkeyFallback = WKUserScript(
            source: Self.fallbackSource(event: event), injectionTime: .atDocumentStart, forMainFrameOnly: false,
            in: .page
        )
        passkeyRelay = WKUserScript(
            source: Self.relaySource(event: event), injectionTime: .atDocumentStart, forMainFrameOnly: false,
            in: UserScripts.world
        )
    }

    /// A modal request whose signal is already aborted goes to WebKit, which answers `AbortError`
    /// as the spec asks; only a live request is refused and reported.
    static func fallbackSource(event: String) -> String {
        """
        (() => {
          const PKC = window.PublicKeyCredential;
          if (!PKC) return;
          const dispatch = EventTarget.prototype.dispatchEvent;
          const Custom = CustomEvent;
          const Refusal = DOMException;
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
          const refuse = (target, self, args) => {
            const options = args[0];
            if (!options || !options.publicKey || options.mediation === 'conditional'
              || (options.signal && options.signal.aborted)) {
              return Reflect.apply(target, self, args);
            }
            Reflect.apply(dispatch, document, [new Custom('\(event)')]);
            return Promise.reject(new Refusal('Passkeys are not available in this browser yet.', 'NotAllowedError'));
          };
          replace(credentials, 'get', refuse);
          replace(credentials, 'create', refuse);
        })();
        """
    }

    static func relaySource(event: String) -> String {
        """
        (() => {
          let last = 0;
          document.addEventListener('\(event)', () => {
            const now = Date.now();
            if (now - last < 1000) return;
            last = now;
            try { webkit.messageHandlers.\(passkeyHandlerName).postMessage(1); } catch (e) {}
          });
        })();
        """
    }
}

/// What the shell says about sign-in. Every requirement has a default, so a shell without it keeps
/// compiling.
public protocol SignInPresenter: AnyObject {
    /// A page in `tab` asked for a passkey and was refused, because Plain can't use passkeys
    /// until Apple grants the web-browser entitlement (`FixedChoices.passkeysEnabled`). The shell
    /// says so in one sentence when `tab` is on screen, and returns whether it did: the engine
    /// stops asking for that site, this launch, only once the user was told. Private tabs too.
    /// Default: says nothing, returns false.
    func tab(_ tab: Tab, couldNotUsePasskeysOn site: String) -> Bool
}

extension SignInPresenter {
    public func tab(_ tab: Tab, couldNotUsePasskeysOn site: String) -> Bool { false }
}
#endif
