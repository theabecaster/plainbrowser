import BrowserCore
import Foundation
import Testing

/// The error page's sentence comes from the error's kind, never the raw text (docs/ui-reference.md).
@Suite struct LoadFailureTests {
    @Test func networkErrorsMapToPlainSentences() {
        func failure(_ code: Int) -> LoadFailure { LoadFailure(domain: NSURLErrorDomain, code: code) }
        #expect(failure(NSURLErrorCannotConnectToHost) == .notAnswering)
        #expect(failure(NSURLErrorCannotConnectToHost).message == "The site isn't answering.")
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
        #expect(LoadFailure(domain: "kCFErrorDomainCFNetwork", code: NSURLErrorCannotConnectToHost) == .notAnswering)
        // WebKit's own domain wrapping a refused connection.
        let wrapped = LoadFailure(
            domain: "WebKitErrorDomain", code: 999, underlying: (domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        )
        #expect(wrapped == .notAnswering)
        #expect(LoadFailure(domain: "WebKitErrorDomain", code: 101) == .other)
        // WebKit refuses restricted ports (9, 25, ...) itself.
        #expect(LoadFailure(domain: "WebKitErrorDomain", code: 103) == .blockedPort)
        #expect(LoadFailure(domain: "WebKitErrorDomain", code: 103).message == "Plain doesn't open pages on this port.")
    }
}
