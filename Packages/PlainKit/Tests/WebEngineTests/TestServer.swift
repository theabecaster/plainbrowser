#if canImport(UIKit)
import Foundation
import Network

/// A tiny HTTP/1.1 server on 127.0.0.1 for engine tests: one response per connection, no bodies
/// read. Real HTTP (not a `WKURLSchemeHandler`) so auth challenges, downloads and
/// `Content-Disposition` go through the same WebKit paths as on the web.
final class TestServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
    }

    struct Response: Sendable {
        var status = 200
        var reason = "OK"
        var headers: [String: String] = ["Content-Type": "text/html; charset=utf-8"]
        var body = Data()

        static func html(_ html: String, headers: [String: String] = [:]) -> Response {
            var response = Response(body: Data(html.utf8))
            response.headers.merge(headers) { $1 }
            return response
        }

        static func data(_ data: Data, type: String, headers: [String: String] = [:]) -> Response {
            var response = Response(headers: ["Content-Type": type], body: data)
            response.headers.merge(headers) { $1 }
            return response
        }

        static let notFound = Response(status: 404, reason: "Not Found", body: Data("not found".utf8))
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "plain.test-server")
    private let route: @Sendable (Request) -> Response
    private let lock = NSLock()
    private var _requests: [Request] = []

    var requests: [Request] { lock.withLock { _requests } }

    private(set) var port: UInt16 = 0

    init(route: @escaping @Sendable (Request) -> Response) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.route = route
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        port = try await withCheckedThrowingContinuation { continuation in
            let resumed = NSLock()
            nonisolated(unsafe) var done = false
            listener.stateUpdateHandler = { [listener] state in
                resumed.withLock {
                    guard !done else { return }
                    switch state {
                    case .ready:
                        done = true
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    case .failed(let error):
                        done = true
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.start(queue: queue)
        }
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.respond(to: head, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ").map(String.init) ?? []
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let request = Request(method: parts.first ?? "GET", path: parts.count > 1 ? parts[1] : "/", headers: headers)
        lock.withLock { _requests.append(request) }
        let response = route(request)
        var text = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        var allHeaders = response.headers
        allHeaders["Content-Length"] = String(response.body.count)
        allHeaders["Connection"] = "close"
        allHeaders["Cache-Control"] = "no-store"
        for (name, value) in allHeaders { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif
