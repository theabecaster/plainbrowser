import Foundation
import Network

/// A tiny HTTP server on localhost for the UI tests, so they never depend on the network.
/// The simulator shares the Mac's loopback, so the app reaches it at `localhost:<port>`.
///
/// Pages:
/// - `/a`: "Page A", with a link to `/b`.
/// - `/b`: "Page B".
/// - `/count`: "Load N", where N counts this page's loads (pull to refresh reloads it).
/// - `/long`: a long article, for scrolling and the toolbar collapse.
/// - `/footer`: a long page with a `position: fixed` footer, for the page's bottom inset.
/// - `/ua`: "Desktop UA" or "Mobile UA", from the request's user agent (Desktop Site).
/// - `/blocking`: "Ad blocked" or "Ad loaded", whether `/jquery.overlayad.js` (an EasyList rule
///   that matches any site) was blocked.
/// - `/article`: a readerable article (Reader), with a link to `/b`.
/// - `/location`: asks for the location (a permission prompt).
/// - `/motion`: a button that asks for motion sensors (a permission prompt after a tap).
/// - `/login`: a sign-in form with the `autocomplete` hints AutoFill reads.
/// - `/passkey`: "Sign In with a Passkey", which asks for a passkey; the heading says how it ended.
final class TestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "TestServer")
    private var loads = 0
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    /// Starts listening and returns once the port is known.
    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, port != 0 else {
            throw URLError(.cannotConnectToHost)
        }
    }

    func stop() {
        listener.cancel()
    }

    /// The address as typed into the address bar.
    func address(_ path: String) -> String {
        "localhost:\(port)\(path)"
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let agent = request.split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("user-agent:") }.map(String.init) ?? ""
            let (status, body) = self.page(for: path, userAgent: agent)
            let isFile = path.hasPrefix("/file.txt")
            let type = path.hasSuffix(".js") ? "application/javascript" : (isFile ? "text/plain" : "text/html; charset=utf-8")
            // A download: the browser saves it instead of showing it.
            let disposition = isFile ? "Content-Disposition: attachment; filename=\"plain-notes.txt\"\r\n" : ""
            let header = """
            HTTP/1.1 \(status)\r
            Content-Type: \(type)\r
            \(disposition)\
            Content-Length: \(body.utf8.count)\r
            Cache-Control: no-store\r
            Connection: close\r
            \r

            """
            // `/slow` answers after a few seconds: a page that stays loading (Stop, the progress bar).
            let delay: Double = path.hasPrefix("/slow") ? 8 : 0
            self.queue.asyncAfter(deadline: .now() + delay) {
                connection.send(content: Data((header + body).utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func page(for path: String, userAgent: String) -> (String, String) {
        // Query strings don't change the page (tests use long tracking addresses).
        let path = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        switch path {
        case "/a":
            return ("200 OK", html("Plain Test A", "<h1>Page A</h1><p><a href=\"/b\">Go to B</a></p>"))
        case "/b":
            return ("200 OK", html("Plain Test B", "<h1>Page B</h1>"))
        case "/c":
            return ("200 OK", html("Plain Test C", "<h1>Page C</h1><p>A third page, for tab switching.</p>"))
        case "/files":
            return ("200 OK", html("Plain Files", "<h1>Files</h1><p><a href=\"/file.txt\">Download notes</a></p>"))
        case "/file.txt":
            return ("200 OK", "Notes from the Plain test server.\n")
        case "/count":
            loads += 1
            return ("200 OK", html("Plain Counter", "<h1>Load \(loads)</h1>"))
        case "/long":
            let paragraphs = (1...80).map {
                "<p>Paragraph \($0). A browser shows pages, and Plain promises nothing extra: the page gets the screen, and the chrome steps aside while you read.</p>"
            }
            return ("200 OK", html("Plain Long Read", "<h1>Long Read</h1>" + paragraphs.joined()))
        case "/footer":
            // A long page with a fixed footer, like a cookie bar or an app's tab bar: the resting
            // toolbar must never cover it.
            let paragraphs = (1...60).map {
                "<p>Line \($0). Fixed page footers sit on the page's bottom edge, which the toolbar covers unless the page knows about it.</p>"
            }
            let footer = "<div style=\"position:fixed;left:0;right:0;bottom:0;padding:14px 20px;"
                + "background:#2973FF;color:#fff;font-weight:600\">Fixed Footer</div>"
            return ("200 OK", html("Plain Footer", "<h1>Footer Page</h1>" + paragraphs.joined() + "<p>End of page.</p>" + footer))
        case "/ua":
            let desktop = !userAgent.contains("Mobile")
            return ("200 OK", html("Plain UA", "<h1>\(desktop ? "Desktop" : "Mobile") UA</h1>"))
        case "/blocking":
            return ("200 OK", html("Plain Blocking", """
                <h1 id="state">Checking</h1>
                <script>function done(text) { document.getElementById('state').textContent = text; }</script>
                <script src="/jquery.overlayad.js" onload="done('Ad loaded')" onerror="done('Ad blocked')"></script>
                """))
        case "/jquery.overlayad.js":
            return ("200 OK", "window.plainAd = true;")
        case "/article":
            let paragraphs = (1...12).map {
                "<p>Paragraph \($0) of the article. Reading on a phone should feel calm: the text sets the pace, the "
                    + "margins give it room, and nothing moves unless you ask it to. A reader view keeps the words and "
                    + "drops everything around them, so a long piece reads like a page in a good book.</p>"
            }
            let body = "<header><nav><a href=\"/a\">Home</a> · <a href=\"/b\">Archive</a></nav></header>"
                + "<article><h1>The Quiet Page</h1><p class=\"byline\">By Plain Tester</p>"
                + paragraphs.joined() + "<p>Next, <a href=\"/b\">read page B</a>.</p></article>"
                + "<footer><p>Footer links and other chrome.</p></footer>"
            return ("200 OK", html("The Quiet Page", body))
        case "/slow":
            return ("200 OK", html("Plain Slow", "<h1>Slow Page</h1>"))
        case "/motion":
            return ("200 OK", html("Plain Motion", """
                <h1 id="state">Motion</h1>
                <p><button id="ask" style="font-size:22px;padding:12px 20px" onclick="
                  DeviceMotionEvent.requestPermission()
                    .then(r => { document.getElementById('state').textContent = 'Motion ' + r; })
                    .catch(e => { document.getElementById('state').textContent = 'Motion error'; });
                ">Use Motion</button></p>
                """))
        case "/location":
            return ("200 OK", html("Plain Location", """
                <h1 id="state">Asking</h1>
                <script>
                navigator.geolocation.getCurrentPosition(
                  () => { document.getElementById('state').textContent = 'Location allowed'; },
                  () => { document.getElementById('state').textContent = 'Location denied'; });
                </script>
                """))
        case "/login":
            return ("200 OK", html("Plain Login", """
                <h1>Sign In</h1>
                <form method="post" action="/a">
                  <p><input id="user" name="username" type="email" autocomplete="username" placeholder="Email"
                    style="font-size:20px;width:90%"></p>
                  <p><input id="pass" name="password" type="password" autocomplete="current-password"
                    placeholder="Password" style="font-size:20px;width:90%"></p>
                  <p><button style="font-size:20px">Sign In</button></p>
                </form>
                """))
        case "/passkey":
            return ("200 OK", html("Plain Passkey", """
                <h1 id="state">Passkey</h1>
                <p><button id="go" style="font-size:22px;padding:12px 20px" onclick="
                  navigator.credentials.get({ publicKey: { challenge: new Uint8Array(32), timeout: 5000 } })
                    .then(() => { document.getElementById('state').textContent = 'Signed in'; })
                    .catch(e => { document.getElementById('state').textContent = 'Passkey ' + e.name; });
                ">Sign In with a Passkey</button></p>
                """))
        default:
            return ("404 Not Found", html("Not Found", "<h1>Not Found</h1>"))
        }
    }

    private func html(_ title: String, _ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width, initial-scale=1">\
        <title>\(title)</title>\
        <style>body{font:17px -apple-system;margin:20px;line-height:1.5}a{font-size:20px}</style>\
        </head><body>\(body)</body></html>
        """
    }
}
