import BrowserCore
import Foundation
import Testing

/// The error page's sentence comes from the error's kind, never the raw text (docs/ui-reference.md).
@Suite struct LoadFailureTests {
    @Test func networkErrorsMapToPlainSentences() {
        func failure(_ code: Int) -> LoadFailure { LoadFailure(domain: NSURLErrorDomain, code: code) }
        #expect(failure(NSURLErrorCannotConnectToHost) == .refused)
        #expect(failure(NSURLErrorCannotConnectToHost).message == "The site refused the connection.")
        // CFNetwork's POSIX code under it tells a refused connection from a host that never answered.
        let refused = LoadFailure(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, streamCode: 61)
        #expect(refused == .refused)
        #expect(refused.message == "The site refused the connection.")
        #expect(LoadFailure(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, streamCode: 65) == .notAnswering)
        #expect(LoadFailure.notAnswering.message == "The site isn't answering.")
        #expect(LoadFailure(
            domain: "WebKitErrorDomain", code: 999, underlying: (domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost), streamCode: 61
        ) == .refused)
        #expect(failure(NSURLErrorNotConnectedToInternet).message == "You're offline.")
        #expect(failure(NSURLErrorCannotFindHost).message == "Plain can't find this site.")
        #expect(failure(NSURLErrorDNSLookupFailed) == .notFound)
        #expect(failure(NSURLErrorTimedOut) == .timedOut)
        #expect(failure(NSURLErrorSecureConnectionFailed).message == "This site's connection isn't private.")
        #expect(failure(NSURLErrorHTTPTooManyRedirects) == .redirectLoop)
        #expect(failure(NSURLErrorUnsupportedURL) == .badAddress)
        #expect(failure(NSURLErrorBadServerResponse) == .badResponse)
        #expect(failure(NSURLErrorUnknown).message == "Plain couldn't open this page.")
    }

    @Test func cfNetworkAndWrappedErrorsToo() {
        #expect(LoadFailure(domain: "kCFErrorDomainCFNetwork", code: NSURLErrorCannotConnectToHost) == .refused)
        // WebKit's own domain wrapping a refused connection.
        let wrapped = LoadFailure(
            domain: "WebKitErrorDomain", code: 999, underlying: (domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        )
        #expect(wrapped == .refused)
        #expect(LoadFailure(domain: "WebKitErrorDomain", code: 101) == .other)
        // WebKit refuses restricted ports (9, 25, ...) itself.
        #expect(LoadFailure(domain: "WebKitErrorDomain", code: 103) == .blockedPort)
        #expect(LoadFailure(domain: "WebKitErrorDomain", code: 103).message == "Plain doesn't open pages on this port.")
        // Screen Time's and content filters' blocks.
        #expect(LoadFailure(domain: "WebKitErrorDomain", code: 104) == .restricted)
        #expect(LoadFailure(domain: "WebKitErrorDomain", code: 106) == .restricted)
        #expect(LoadFailure.restricted.message == "This site is restricted on this iPhone.")
    }
}
