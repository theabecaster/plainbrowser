import Foundation

/// Why a page couldn't load, in the user's terms, and Plain's one sentence for it
/// (docs/ui-reference.md, "Wording": Plain writes error messages from known cases, never WebKit's
/// or the server's text). The error page shows the sentence and one button, Try Again.
public enum LoadFailure: Equatable, Sendable {
    /// No network: Wi-Fi and cellular are off, or the connection dropped.
    case offline
    /// The name doesn't resolve: a typo, or the site is gone.
    case notFound
    /// The host refused the connection: it is there, but nothing is serving on that port.
    case refused
    /// The host couldn't be reached at all (no route, or no answer to the connection).
    case notAnswering
    /// The host took too long.
    case timedOut
    /// The secure connection failed: a bad or untrusted certificate, or a TLS failure.
    case notPrivate
    /// The address itself can't be loaded.
    case badAddress
    /// The site sends the page round in circles.
    case redirectLoop
    /// The server answered with something that isn't a page.
    case badResponse
    /// A port the engine never opens (WebKit's restricted ports: 9, 25 and the like), so the
    /// request never leaves the device.
    case blockedPort
    /// Screen Time or a content filter blocked the site (WebKit's FrameLoadBlockedByContentFilter,
    /// 104, and FrameLoadBlockedByRestrictions, 106). Where the filter has a page of its own,
    /// WebKit loads it next, which clears this one.
    case restricted
    /// Anything else.
    case other

    /// Classifies an error by its domain and code. CFNetwork's codes are the same numbers as
    /// `NSURLError`'s; `underlying` is the error's `NSUnderlyingErrorKey`, checked when the outer
    /// one is not a known network error (WebKit wraps some). "Can't connect to host" is a refused
    /// connection, as browsers name it (Chrome's ERR_CONNECTION_REFUSED), unless CFNetwork's
    /// POSIX code under it (`_kCFStreamErrorCodeKey`, `streamCode`) names another cause, such as
    /// no route to the host: then the site isn't answering. WebKit's network process does not
    /// pass that key on (measured: a refused port reached Plain without it), so it is usually nil.
    public init(domain: String, code: Int, underlying: (domain: String, code: Int)? = nil, streamCode: Int? = nil) {
        let networkDomains: Set<String> = [NSURLErrorDomain, "kCFErrorDomainCFNetwork"]
        if domain == Self.webKitDomain, code == Self.webKitRestrictedPort {
            self = .blockedPort
            return
        }
        if domain == Self.webKitDomain, Self.webKitContentFilter.contains(code) {
            self = .restricted
            return
        }
        guard networkDomains.contains(domain), let failure = Self.network(code) else {
            if let underlying, networkDomains.contains(underlying.domain), let failure = Self.network(underlying.code) {
                self = Self.refined(failure, streamCode: streamCode)
            } else {
                self = .other
            }
            return
        }
        self = Self.refined(failure, streamCode: streamCode)
    }

    /// Darwin's `ECONNREFUSED`: the host answered the connection with a reset.
    static let connectionRefused = 61

    private static func refined(_ failure: LoadFailure, streamCode: Int?) -> LoadFailure {
        guard failure == .notAnswering else { return failure }
        return streamCode == nil || streamCode == connectionRefused ? .refused : .notAnswering
    }

    /// WebKit's error domain and its "cannot use restricted port" code
    /// (`WebKitErrorCannotUseRestrictedPort`).
    static let webKitDomain = "WebKitErrorDomain"
    static let webKitRestrictedPort = 103
    /// WebKit's content filter and restrictions codes (Screen Time, parental controls).
    static let webKitContentFilter: Set<Int> = [104, 106]

    private static func network(_ code: Int) -> LoadFailure? {
        switch code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive:
            .offline
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            .notFound
        case NSURLErrorCannotConnectToHost:
            .notAnswering
        case NSURLErrorTimedOut:
            .timedOut
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorSecureConnectionFailed, NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            .notPrivate
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL:
            .badAddress
        case NSURLErrorHTTPTooManyRedirects, NSURLErrorRedirectToNonExistentLocation:
            .redirectLoop
        case NSURLErrorBadServerResponse, NSURLErrorZeroByteResource, NSURLErrorCannotDecodeContentData,
             NSURLErrorCannotDecodeRawData, NSURLErrorCannotParseResponse:
            .badResponse
        default:
            nil
        }
    }

    /// One plain sentence, sentence case, no jargon.
    public var message: String {
        switch self {
        case .offline: "You're offline."
        case .notFound: "Plain can't find this site."
        case .refused: "The site refused the connection."
        case .notAnswering: "The site isn't answering."
        case .timedOut: "The site took too long to answer."
        case .notPrivate: "This site's connection isn't private."
        case .badAddress: "This address doesn't work."
        case .redirectLoop: "This site keeps redirecting."
        case .badResponse: "The site sent something Plain can't show."
        case .blockedPort: "Plain doesn't open pages on this port."
        case .restricted: "This site is restricted on this iPhone."
        case .other: "Plain couldn't open this page."
        }
    }
}
