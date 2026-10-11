import Foundation
import Network

/// A local HTTP server for the API client tests: it answers every request with JSON describing what it received
/// (method, path, query, headers, body), or with what a route says. Listens on port 0, one connection at a time.
final class MockHTTPServer {
    struct Route {
        var status = 200
        var headers: [(String, String)] = [("Content-Type", "application/json")]
        var body: Data
        var delay: TimeInterval = 0
    }

    /// Path → canned answer. Anything else gets the echo answer.
    var routes: [String: Route] = [:]
    /// Every request seen, oldest first.
    private(set) var received: [(method: String, path: String, headers: [String: String], body: Data)] = []
    private let listener: NWListener
    private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "feather.tests.mock-http")

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = self?.listener.port?.rawValue { self?.port = port; ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()
        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { buffer += data }
                if let request = self.parse(buffer) {
                    self.respond(to: request, on: connection)
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    readMore()
                }
            }
        }
        readMore()
    }

    private struct Request { var method: String; var path: String; var headers: [String: String]; var body: Data }

    private func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }
        return Request(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: data[bodyStart..<(bodyStart + length)])
    }

    private func respond(to request: Request, on connection: NWConnection) {
        received.append((request.method, request.path, request.headers, request.body))
        let pathOnly = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        let route = routes[pathOnly] ?? Route(body: echo(request))
        let statusText = HTTPURLResponse.localizedString(forStatusCode: route.status)
        var head = "HTTP/1.1 \(route.status) \(statusText)\r\n"
        for (name, value) in route.headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(route.body.count)\r\nConnection: close\r\n\r\n"
        let send = {
            connection.send(content: Data(head.utf8) + route.body, completion: .contentProcessed { _ in connection.cancel() })
        }
        if route.delay > 0 { queue.asyncAfter(deadline: .now() + route.delay, execute: send) } else { send() }
    }

    private func echo(_ request: Request) -> Data {
        var query: [String: String] = [:]
        if let components = URLComponents(string: "http://x" + request.path) {
            for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        }
        let payload: [String: Any] = ["method": request.method, "path": String(request.path.split(separator: "?").first ?? ""),
                                      "query": query, "headers": request.headers,
                                      "body": String(decoding: request.body, as: UTF8.self)]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    }
}
