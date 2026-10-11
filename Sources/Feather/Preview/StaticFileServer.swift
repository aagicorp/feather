import Foundation
import Network
import UniformTypeIdentifiers

/// A very small web server for "Preview This Page": it hands out the files of one folder so that a plain HTML
/// page can find its CSS, scripts and pictures by relative address, as it would on a real site.
///
/// It is deliberately narrow. It listens on 127.0.0.1 only, on a port the system picks, answers GET and nothing
/// else, never leaves its folder (not through "..", not through a symbolic link), does not show hidden files such
/// as `.env` or `.git`, and only answers requests addressed to this Mac by name, so a web page elsewhere cannot
/// trick a browser into reading the project through it. It lives exactly as long as the preview that owns it.
final class StaticFileServer {
    /// What goes back for one request. Kept apart from the network code so the rules can be read in one place.
    struct Response {
        var status: Int
        var headers: [(String, String)] = []
        var body = Data()

        static func plain(_ status: Int, _ text: String, headers: [(String, String)] = []) -> Response {
            Response(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")] + headers, body: Data((text + "\n").utf8))
        }
    }

    let root: URL
    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "feather.static-server")
    /// A request line and headers longer than this are not from a browser asking for a page.
    private static let maxHeaderBytes = 16 * 1024

    init(root: URL) {
        self.root = root.resolvingSymlinksInPath()
    }

    deinit { stop() }

    /// The address of a file below the root, once the server is up.
    func address(of file: URL) -> URL? {
        let rootPath = root.path, filePath = file.resolvingSymlinksInPath().path
        guard port != 0, filePath.hasPrefix(rootPath + "/") else { return nil }
        let relative = filePath.dropFirst(rootPath.count + 1).split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        return URL(string: "http://127.0.0.1:\(port)/\(relative)")
    }

    /// Starts listening; `completion` hears the port on the main thread, or nil when no port could be had.
    func start(completion: @escaping (UInt16?) -> Void) {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { return completion(nil) }
        self.listener = listener
        var answered = false
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                let port = listener?.port?.rawValue ?? 0
                self?.port = port           // written once, here, before anyone is told the server is up
                DispatchQueue.main.async {
                    guard !answered else { return }
                    answered = true
                    completion(port == 0 ? nil : port)
                }
            case .failed, .cancelled:
                DispatchQueue.main.async {
                    guard !answered else { return }
                    answered = true
                    completion(nil)
                }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            connection.start(queue: self.queue)
            self.receive(on: connection, collected: Data())
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - One connection

    private func receive(on connection: NWConnection, collected: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var collected = collected
            if let data { collected.append(data) }
            if let end = collected.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: collected[..<end.lowerBound], as: UTF8.self)
                return self.send(StaticFileServer.response(toHead: head, root: self.root, port: self.port), on: connection)
            }
            if collected.count > StaticFileServer.maxHeaderBytes { return self.send(.plain(431, "Request too large"), on: connection) }
            if isComplete || error != nil { return connection.cancel() }
            self.receive(on: connection, collected: collected)
        }
    }

    private func send(_ response: Response, on connection: NWConnection) {
        let reasons = [200: "OK", 301: "Moved Permanently", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                       405: "Method Not Allowed", 431: "Request Header Fields Too Large"]
        var head = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Error")\r\n"
        // Never cached: the whole point of the preview is to show the file as it is now.
        let fixed = [("Content-Length", String(response.body.count)), ("Connection", "close"), ("Cache-Control", "no-store"),
                     ("X-Content-Type-Options", "nosniff")]
        for (name, value) in response.headers + fixed { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - The rules

    /// Decides the answer to a request from its first line and headers. No state: the same request always gets
    /// the same answer, which is what makes the awkward cases testable.
    static func response(toHead head: String, root: URL, port: UInt16) -> Response {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .plain(400, "Bad request") }
        guard parts[0] == "GET" else { return .plain(405, "Only GET is answered here", headers: [("Allow", "GET")]) }
        // A page on some other site can point a browser at 127.0.0.1 under a name of its own choosing and read
        // the answer. Answering only to our own names closes that door.
        let host = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }
            .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased() }
        guard let host, ["127.0.0.1:\(port)", "localhost:\(port)"].contains(host) else { return .plain(403, "Forbidden") }

        switch resolve(target: parts[1], root: root) {
        case .failure(let refusal): return refusal
        case .success(let found):
            if found.needsSlash {
                return Response(status: 301, headers: [("Location", found.redirect)])
            }
            guard let body = try? Data(contentsOf: found.file, options: .mappedIfSafe) else { return .plain(404, "Not found") }
            return Response(status: 200, headers: [("Content-Type", mimeType(of: found.file))], body: body)
        }
    }

    struct Found {
        let file: URL
        /// A folder asked for without its closing "/": the browser is sent to the address with it, or the
        /// page's relative links would point one level too high.
        var needsSlash = false
        var redirect = ""
    }

    /// From the address in a request to a file that is certainly inside `root` (which must already have its
    /// symbolic links resolved), or the refusal to send instead.
    static func resolve(target: String, root: URL) -> Result<Found, RefusalResponse> {
        // Only "/path" is an address of ours. "http://…" (a request meant for a proxy) and "*" are not.
        guard target.hasPrefix("/") else { return .failure(.plain(400, "Bad request")) }
        let rawPath = String(target.prefix { $0 != "?" && $0 != "#" })
        guard let decoded = rawPath.removingPercentEncoding, !decoded.contains("\0") else { return .failure(.plain(400, "Bad request")) }
        var components: [String] = []
        for component in decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if component == "." { continue }
            // ".." is refused outright rather than worked out: no honest page needs to climb above its site. It
            // is checked after decoding, so "%2e%2e" is caught too; a backslash is how Windows spells "/".
            if component == ".." || component.contains("\\") { return .failure(.plain(403, "Forbidden")) }
            // Hidden files hold secrets (.env) and history (.git); they are not part of a site.
            if component.hasPrefix(".") { return .failure(.plain(404, "Not found")) }
            components.append(component)
        }
        var file = components.reduce(root) { $0.appendingPathComponent($1) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else { return .failure(.plain(404, "Not found")) }
        if isDirectory.boolValue {
            if !rawPath.hasSuffix("/") { return .success(Found(file: file, needsSlash: true, redirect: rawPath + "/")) }
            file.appendPathComponent("index.html")
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return .failure(.plain(404, "Not found"))
            }
        }
        // The last word: wherever the path really leads once every symbolic link in it is followed, it must
        // still be inside the folder being served.
        let real = file.resolvingSymlinksInPath().path
        guard real == root.path || real.hasPrefix(root.path == "/" ? "/" : root.path + "/") else { return .failure(.plain(403, "Forbidden")) }
        return .success(Found(file: URL(fileURLWithPath: real)))
    }

    static func mimeType(of file: URL) -> String {
        let ext = file.pathExtension.lowercased()
        // The handful a web page cannot do without are spelled out, so they never depend on what is installed.
        let known = ["html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8", "css": "text/css; charset=utf-8",
                     "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
                     "json": "application/json; charset=utf-8", "map": "application/json; charset=utf-8",
                     "svg": "image/svg+xml", "wasm": "application/wasm", "txt": "text/plain; charset=utf-8",
                     "xml": "application/xml; charset=utf-8", "webmanifest": "application/manifest+json", "ico": "image/x-icon"]
        if let type = known[ext] { return type }
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}

/// A `Response` that says no, as an Error so it can travel in a Result.
typealias RefusalResponse = StaticFileServer.Response
extension StaticFileServer.Response: Error {}
