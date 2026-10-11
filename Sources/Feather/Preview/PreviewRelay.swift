import Foundation
import Network

/// Why the preview does not visit "localhost" under that name.
///
/// WebKit refuses to keep a cookie marked `Secure` that arrives over plain http, and makes no exception for
/// localhost (Chrome does). Many backends always mark their sign-in cookie `Secure`, so in the preview signing
/// in "worked" and the app still saw nobody signed in. WebKit also never sends localhost traffic through a
/// proxy, so nothing could be corrected on the way.
///
/// So the preview visits the app under a stand-in name, which WebKit does send through `PreviewRelay`. The
/// relay passes everything on to the real server under its real name, and takes `Secure` off the cookies that
/// come back. The address field, the browser hand-off and everything the user sees keep saying "localhost".
enum PreviewAlias {
    /// Every stand-in name ends in this; it is the only traffic the relay is given.
    static let domain = "fthr.localhost"
    static let names = ["localhost": "app." + domain, "127.0.0.1": "ip." + domain]

    static func realHost(for alias: String) -> String? {
        names.first { $0.value == alias.lowercased() }?.key
    }

    /// The address WebKit is given for `url`. Only plain http needs the stand-in; https keeps its cookies.
    static func wire(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased(), let alias = names[host],
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.host = alias
        return parts.url ?? url
    }

    /// The address the user knows for what WebKit calls `url`.
    static func shown(_ url: URL) -> URL {
        guard let host = url.host, let real = realHost(for: host),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.host = real
        return parts.url ?? url
    }

    // MARK: - What the relay rewrites

    /// A request on its way to the server: the server must hear its own name, or it may refuse the request
    /// (dev servers check Host and Origin) or answer for the wrong site.
    static func requestHead(_ head: String) -> (head: String, isUpgrade: Bool) {
        var lines = head.components(separatedBy: "\r\n")
        let isUpgrade = lines.contains { $0.lowercased().hasPrefix("upgrade:") }
        var result = [lines.removeFirst()]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            switch name {
            case "host", "origin", "referer": result.append(toRealNames(line))
            case "proxy-connection", "keep-alive": continue
            case "connection" where !isUpgrade: continue
            default: result.append(line)
            }
        }
        // One request per connection: the relay never has to find where one body ends and the next request starts.
        if !isUpgrade { result.append("Connection: close") }
        return (result.joined(separator: "\r\n"), isUpgrade)
    }

    /// An answer on its way to the page: the page lives under the stand-in name, so whatever names the site
    /// must say the stand-in, and cookies must be ones WebKit will keep.
    static func responseHead(_ head: String) -> String {
        var lines = head.components(separatedBy: "\r\n")
        let status = lines.removeFirst()
        let isSwitching = status.split(separator: " ").dropFirst().first == "101"
        var result = [status]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "set-cookie": result.append("Set-Cookie: " + cookie(value))
            case "location", "access-control-allow-origin", "content-location": result.append(line[...colon] + " " + toAliasNames(value, afterSlashesOnly: true))
            case "content-security-policy", "content-security-policy-report-only": result.append(line[...colon] + " " + toAliasNames(value, afterSlashesOnly: false))
            case "keep-alive": continue
            case "connection" where !isSwitching: continue
            default: result.append(line)
            }
        }
        if !isSwitching { result.append("Connection: close") }
        return result.joined(separator: "\r\n")
    }

    /// The same cookie, as one WebKit keeps over plain http: not `Secure`, tied to the host that set it, and
    /// not `SameSite=None` (which is only allowed together with `Secure`).
    static func cookie(_ value: String) -> String {
        let parts = value.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let pair = parts.first else { return value }
        // These names promise `Secure` by their spelling; without it the cookie is refused either way.
        if pair.hasPrefix("__Secure-") || pair.hasPrefix("__Host-") { return value }
        var kept = [pair]
        for attribute in parts.dropFirst() where !attribute.isEmpty {
            let lower = attribute.lowercased()
            if lower == "secure" || lower == "partitioned" || lower.hasPrefix("domain=") { continue }
            kept.append(lower.replacingOccurrences(of: " ", with: "") == "samesite=none" ? "SameSite=Lax" : attribute)
        }
        return kept.joined(separator: "; ")
    }

    private static func toRealNames(_ text: String) -> String {
        names.reduce(text) { $0.replacingOccurrences(of: $1.value, with: $1.key, options: .caseInsensitive) }
    }

    private static func toAliasNames(_ text: String, afterSlashesOnly: Bool) -> String {
        names.reduce(text) { text, name in
            let host = NSRegularExpression.escapedPattern(for: name.key)
            let pattern = afterSlashesOnly ? "(?<=//)\(host)(?![\\w.-])" : "(?<![\\w.-])\(host)(?![\\w.-])"
            return text.replacingOccurrences(of: pattern, with: name.value, options: [.regularExpression, .caseInsensitive])
        }
    }

    /// Runs in the page before its own scripts. Apps are often built with their API's full address inside
    /// ("http://localhost:8080/api"); those calls must go by the stand-in name too, or they would skip the
    /// relay and their cookies would be dropped as before.
    static let pageScript: String = {
        let table = names.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
        return """
        (function () {
          var names = {\(table)};
          function fix(address) {
            try {
              var url = new URL(address, location.href);
              if ((url.protocol === "http:" || url.protocol === "ws:") && names[url.hostname]) { url.hostname = names[url.hostname]; return url.href; }
            } catch (error) {}
            return address;
          }
          var plainFetch = window.fetch;
          if (plainFetch) window.fetch = function (input, options) {
            if (typeof input === "string" || input instanceof URL) input = fix(String(input));
            else if (input instanceof Request && fix(input.url) !== input.url) input = new Request(fix(input.url), input);
            return plainFetch.call(this, input, options);
          };
          var plainOpen = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function (method, address) {
            var rest = Array.prototype.slice.call(arguments, 2);
            return plainOpen.apply(this, [method, fix(String(address))].concat(rest));
          };
          ["WebSocket", "EventSource"].forEach(function (kind) {
            var Plain = window[kind];
            if (!Plain) return;
            var Wrapped = function (address, more) { return more === undefined ? new Plain(fix(String(address))) : new Plain(fix(String(address)), more); };
            Wrapped.prototype = Plain.prototype;
            ["CONNECTING", "OPEN", "CLOSING", "CLOSED"].forEach(function (key) { if (key in Plain) Wrapped[key] = Plain[key]; });
            window[kind] = Wrapped;
          });
          if (navigator.sendBeacon) {
            var plainBeacon = navigator.sendBeacon;
            navigator.sendBeacon = function (address, data) { return plainBeacon.call(navigator, fix(String(address)), data); };
          }
        })();
        """
    }()
}

/// The proxy WebKit is pointed at for the stand-in names, and nothing else. It listens on this Mac only and
/// connects to this Mac only, so it gives no program a way to reach anything it could not already reach.
final class PreviewRelay {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "feather.preview-relay")
    private var connections: [ObjectIdentifier: RelayConnection] = [:]
    let port: UInt16

    /// nil when no port could be opened; the preview then visits localhost directly, as it always did.
    init?() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
        let settled = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: settled.signal()
            default: break
            }
        }
        var accept: ((NWConnection) -> Void)?
        listener.newConnectionHandler = { accept?($0) }
        listener.start(queue: queue)
        guard settled.wait(timeout: .now() + 2) == .success, let port = listener.port?.rawValue, port != 0 else {
            listener.cancel()
            return nil
        }
        self.port = port
        queue.sync {
            accept = { [weak self] connection in
                guard let self else { return connection.cancel() }
                let relayed = RelayConnection(client: connection, queue: self.queue)
                let key = ObjectIdentifier(relayed)
                self.connections[key] = relayed
                relayed.onEnd = { [weak self] in self?.connections[key] = nil }
                relayed.start()
            }
        }
    }

    deinit { listener.cancel() }
}

/// One request and its answer. Everything happens on the relay's queue.
private final class RelayConnection {
    private let client: NWConnection
    private var server: NWConnection?
    private let queue: DispatchQueue
    private var hasEnded = false
    var onEnd: (() -> Void)?

    private static let headEnd = Data("\r\n\r\n".utf8)
    private static let longestHead = 256 * 1024

    init(client: NWConnection, queue: DispatchQueue) {
        self.client = client
        self.queue = queue
    }

    func start() {
        client.start(queue: queue)
        readHead(from: client, buffered: Data()) { [weak self] head, rest in
            guard let self else { return }
            // "CONNECT app.fthr.localhost:3000 HTTP/1.1"
            let words = head.components(separatedBy: "\r\n")[0].split(separator: " ")
            guard words.count >= 2, words[0] == "CONNECT", let colon = words[1].lastIndex(of: ":"),
                  let host = PreviewAlias.realHost(for: String(words[1][..<colon])),
                  let port = NWEndpoint.Port(String(words[1][words[1].index(after: colon)...])) else {
                return self.refuse("403 Forbidden")
            }
            let server = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            self.server = server
            server.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    server.stateUpdateHandler = nil
                    self.client.send(content: Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                    self.relayRequest(buffered: rest)
                case .failed, .waiting:
                    // Waiting is how "nothing is listening there" is said; the page shows its own message for that.
                    self.refuse("502 Bad Gateway")
                default: break
                }
            }
            server.start(queue: self.queue)
        }
    }

    private func relayRequest(buffered: Data) {
        guard let server else { return }
        readHead(from: client, buffered: buffered) { [weak self] head, rest in
            guard let self else { return }
            let request = PreviewAlias.requestHead(head)
            server.send(content: Data((request.head + "\r\n\r\n").utf8Latin1) + rest, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.end() }
            })
            self.pipe(from: self.client, to: server, endsBoth: false)
            self.relayResponse(buffered: Data())
        }
    }

    private func relayResponse(buffered: Data) {
        guard let server else { return }
        readHead(from: server, buffered: buffered) { [weak self] head, rest in
            guard let self else { return }
            let status = head.components(separatedBy: "\r\n")[0].split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
            let rewritten = Data((PreviewAlias.responseHead(head) + "\r\n\r\n").utf8Latin1)
            // "100 Continue" and its kind are followed by the real answer, which needs the same care.
            if (100..<200).contains(status), status != 101 {
                self.client.send(content: rewritten, completion: .contentProcessed { _ in })
                return self.relayResponse(buffered: rest)
            }
            self.client.send(content: rewritten + rest, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.end() }
            })
            self.pipe(from: server, to: self.client, endsBoth: true)
        }
    }

    /// Collects bytes until a blank line, then hands over the head (without it) and whatever came after.
    private func readHead(from connection: NWConnection, buffered: Data, completion: @escaping (String, Data) -> Void) {
        if let end = buffered.range(of: RelayConnection.headEnd) {
            let head = String(data: buffered[..<end.lowerBound], encoding: .isoLatin1) ?? ""
            return completion(head, Data(buffered[end.upperBound...]))
        }
        guard buffered.count < RelayConnection.longestHead else { return end() }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, !data.isEmpty, error == nil else { return self.end() }
            if isComplete, (buffered + data).range(of: RelayConnection.headEnd) == nil { return self.end() }
            self.readHead(from: connection, buffered: buffered + data, completion: completion)
        }
    }

    private func pipe(from source: NWConnection, to destination: NWConnection, endsBoth: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.hasEnded else { return }
            let isOver = isComplete || error != nil
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if sendError != nil || (isOver && (endsBoth || error != nil)) { return self.end() }
                    if !isOver { self.pipe(from: source, to: destination, endsBoth: endsBoth) }
                })
            } else if isOver {
                // The page finishing what it had to say is not the end: the answer may still be on its way.
                if endsBoth || error != nil { self.end() }
            } else {
                self.pipe(from: source, to: destination, endsBoth: endsBoth)
            }
        }
    }

    private func refuse(_ status: String) {
        client.send(content: Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in
            self?.end()
        })
    }

    private func end() {
        guard !hasEnded else { return }
        hasEnded = true
        client.cancel()
        server?.cancel()
        onEnd?()
        onEnd = nil
    }
}

private extension String {
    /// Heads were read byte for byte as Latin-1, so they are written back the same way.
    var utf8Latin1: Data { data(using: .isoLatin1) ?? Data(utf8) }
}
