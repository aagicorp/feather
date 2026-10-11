import Foundation

/// A cookie as the server sent it, whether or not it is kept. Feather keeps its own jar rather than the
/// system's: macOS refuses a `Secure` cookie over plain `http://localhost`, which is exactly how a local
/// back end hands out its sign-in cookie, and Postman and every browser treat localhost as secure.
struct APICookie: Equatable, Codable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Date?
    var secure = false
    var httpOnly = false
    var sameSite: String?
    /// Set without a `Domain` attribute: it belongs to that one host, not its subdomains.
    var hostOnly = true
    /// Why the jar did not keep it, when it did not (shown in the Cookies tab).
    var notStored: String?

    var isExpired: Bool { expires.map { $0 < Date() } ?? false }
    /// True for a cookie the server set for this session only.
    var isSessionCookie: Bool { expires == nil }
}

enum APICookieParser {
    /// Foundation joins several `Set-Cookie` headers into one with ", "; this takes them apart again without
    /// cutting the comma inside an `Expires=Sun, 27 Sep 2026 …` date.
    static func split(joined header: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var index = header.startIndex
        while index < header.endIndex {
            let character = header[index]
            if character == "," {
                // A new cookie starts after a comma only when `name=` follows.
                let rest = header[header.index(after: index)...].drop(while: { $0 == " " })
                if let equals = rest.firstIndex(of: "="), !rest[..<equals].contains(where: { $0 == ";" || $0 == "," || $0 == " " }), equals > rest.startIndex {
                    parts.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    index = rest.startIndex
                    continue
                }
            }
            current.append(character)
            index = header.index(after: index)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current.trimmingCharacters(in: .whitespaces)) }
        return parts
    }

    private static let dateFormats: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = format
        return formatter
    }

    /// One `Set-Cookie` line → a cookie for `url` (its host and path fill in what the line leaves out).
    static func parse(_ line: String, for url: URL) -> APICookie? {
        let pieces = line.split(separator: ";", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = pieces.first, let equals = first.firstIndex(of: "=") else { return nil }
        let name = String(first[..<equals]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        var cookie = APICookie(name: name, value: String(first[first.index(after: equals)...]),
                               domain: url.host?.lowercased() ?? "", path: defaultPath(for: url))
        var maxAge: TimeInterval?
        for attribute in pieces.dropFirst() {
            let key: String, value: String
            if let equals = attribute.firstIndex(of: "=") {
                key = attribute[..<equals].lowercased()
                value = String(attribute[attribute.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            } else {
                key = attribute.lowercased()
                value = ""
            }
            switch key {
            case "domain":
                cookie.domain = value.lowercased().hasPrefix(".") ? String(value.lowercased().dropFirst()) : value.lowercased()
                cookie.hostOnly = false
            case "path": cookie.path = value.isEmpty ? "/" : value
            case "expires": cookie.expires = dateFormats.lazy.compactMap { $0.date(from: value) }.first
            case "max-age": maxAge = TimeInterval(value)
            case "secure": cookie.secure = true
            case "httponly": cookie.httpOnly = true
            case "samesite": cookie.sameSite = value
            default: break
            }
        }
        if let maxAge { cookie.expires = Date().addingTimeInterval(maxAge) }      // Max-Age wins over Expires
        return cookie
    }

    /// Every cookie in a response's headers (`Set-Cookie`, joined or not).
    static func cookies(in headers: [(name: String, value: String)], for url: URL) -> [APICookie] {
        headers.filter { $0.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame }
            .flatMap { split(joined: $0.value) }
            .compactMap { parse($0, for: url) }
    }

    /// RFC 6265's default path: the request path up to its last slash.
    static func defaultPath(for url: URL) -> String {
        let path = url.path
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    /// Hosts that count as secure without https, as browsers treat them.
    static func isLocalHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasSuffix(".localhost")
    }
}

/// The cookies the API client holds for one project: filled from answers, sent back with later requests that
/// match, kept in the personal folder (never in the project, since a sign-in cookie is a secret of sorts).
final class APICookieJar {
    private(set) var cookies: [APICookie] = []
    private let file: URL?
    static let didChange = Notification.Name("FeatherAPICookiesDidChange")

    init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = try? APIJSON.decoder.decode([APICookie].self, from: data) {
            cookies = saved.filter { !$0.isExpired }
        }
    }

    /// Keeps the cookies an answer set, replacing older ones with the same name, domain and path. A cookie
    /// whose domain does not cover the host is refused, as a browser would; returns the cookies with
    /// `notStored` filled in where that happened.
    @discardableResult
    func store(_ received: [APICookie], from url: URL) -> [APICookie] {
        let host = url.host?.lowercased() ?? ""
        var result: [APICookie] = []
        for var cookie in received {
            if !(host == cookie.domain || host.hasSuffix("." + cookie.domain)) {
                cookie.notStored = "Not kept: the server set it for \(cookie.domain), not \(host)."
            } else {
                cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
                if cookie.isExpired { cookie.notStored = "Removed: the server set it to expire in the past." }
                else { cookies.append(cookie) }
            }
            result.append(cookie)
        }
        save()
        return result
    }

    /// The `Cookie` header value for a request, or nil when nothing applies.
    func header(for url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        let secure = url.scheme?.lowercased() == "https" || APICookieParser.isLocalHost(host)
        let matching = cookies.filter { cookie in
            !cookie.isExpired
                && (host == cookie.domain || (!cookie.hostOnly && host.hasSuffix("." + cookie.domain)))
                && (path == cookie.path || path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/"))
                && (!cookie.secure || secure)
        }
        guard !matching.isEmpty else { return nil }
        return matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    func remove(name: String, domain: String) {
        cookies.removeAll { $0.name == name && $0.domain == domain }
        save()
    }

    func clear() {
        cookies = []
        save()
    }

    private func save() {
        NotificationCenter.default.post(name: APICookieJar.didChange, object: self)
        guard let file else { return }
        let kept = cookies.filter { !$0.isSessionCookie && !$0.isExpired }       // session cookies end with the app
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if kept.isEmpty { try? FileManager.default.removeItem(at: file); return }
        try? APIJSON.encoder.encode(kept).write(to: file, options: .atomic)
    }
}
