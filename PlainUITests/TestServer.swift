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
            let (status, body) = self.page(for: path)
            let header = """
            HTTP/1.1 \(status)\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Cache-Control: no-store\r
            Connection: close\r
            \r

            """
            connection.send(content: Data((header + body).utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func page(for path: String) -> (String, String) {
        switch path {
        case "/a":
            return ("200 OK", html("Plain Test A", "<h1>Page A</h1><p><a href=\"/b\">Go to B</a></p>"))
        case "/b":
            return ("200 OK", html("Plain Test B", "<h1>Page B</h1>"))
        case "/count":
            loads += 1
            return ("200 OK", html("Plain Counter", "<h1>Load \(loads)</h1>"))
        case "/long":
            let paragraphs = (1...80).map {
                "<p>Paragraph \($0). A browser shows pages, and Plain promises nothing extra: the page gets the screen, and the chrome steps aside while you read.</p>"
            }
            return ("200 OK", html("Plain Long Read", "<h1>Long Read</h1>" + paragraphs.joined()))
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
