import Foundation

/// Why a page couldn't load, in the user's terms, and Plain's one sentence for it
/// (docs/ui-reference.md, "Wording": Plain writes error messages from known cases, never WebKit's
/// or the server's text). The error page shows the sentence and one button, Try Again.
public enum LoadFailure: Equatable, Sendable {
    /// No network: Wi-Fi and cellular are off, or the connection dropped.
    case offline
    /// The name doesn't resolve: a typo, or the site is gone.
    case notFound
    /// The host refused the connection or dropped it: nothing is serving there.
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
    /// Anything else.
    case other

    /// Classifies an error by its domain and code. CFNetwork's codes are the same numbers as
    /// `NSURLError`'s; `underlying` is the error's `NSUnderlyingErrorKey`, checked when the outer
    /// one is not a known network error (WebKit wraps some).
    public init(domain: String, code: Int, underlying: (domain: String, code: Int)? = nil) {
        let networkDomains: Set<String> = [NSURLErrorDomain, "kCFErrorDomainCFNetwork"]
        guard networkDomains.contains(domain), let failure = Self.network(code) else {
            if let underlying, networkDomains.contains(underlying.domain), let failure = Self.network(underlying.code) {
                self = failure
            } else {
                self = .other
            }
            return
        }
        self = failure
    }

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
        case .notAnswering: "The site isn't answering."
        case .timedOut: "The site took too long to answer."
        case .notPrivate: "This site's connection isn't private."
        case .badAddress: "This address doesn't work."
        case .redirectLoop: "This site keeps redirecting."
        case .badResponse: "The site sent something Plain can't show."
        case .other: "Plain couldn't open this page."
        }
    }
}
