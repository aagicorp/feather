import Foundation

/// Reads a `curl` command line into a request: the address, `-X`, `-H`, `-d`, `-F`, `-u` and the other
/// options people actually paste. Options curl would take but the API client has no use for (`-s`, `-o`,
/// `--max-time`…) are skipped, with their argument when they have one. Nothing here runs anything.
///
/// This is the small reader the terminal link uses; the importer's cURL reader is the fuller one.
enum CurlParser {
    /// Short options that take an argument, so `-o out.json` is not read as an address.
    private static let shortWithArgument: Set<Character> = ["X", "H", "d", "F", "u", "A", "e", "b", "o", "w", "m", "x", "c", "T", "D", "r", "y", "Y", "K", "E", "U", "C", "z", "Q"]
    /// Long options that take an argument and are ignored.
    private static let ignoredLongWithArgument: Set<String> = [
        "output", "write-out", "max-time", "connect-timeout", "cacert", "cert", "key", "proxy", "cookie-jar", "upload-file",
        "dump-header", "resolve", "retry", "retry-delay", "range", "speed-time", "speed-limit", "interface", "unix-socket",
        "abstract-unix-socket", "max-redirs", "limit-rate", "config", "ciphers", "proto", "proxy-user", "continue-at",
        "time-cond", "stderr", "trace", "trace-ascii", "expect100-timeout", "keepalive-time", "happy-eyeballs-timeout-ms",
        "dns-servers", "local-port", "pinnedpubkey", "tls-max", "pass", "engine", "krb", "delegation", "capath", "crlfile",
        "egd-file", "random-file", "netrc-file", "output-dir", "create-file-mode", "aws-sigv4", "alt-svc", "hsts", "etag-save",
        "etag-compare", "url-query",
    ]

    /// Splits a command line the way a shell would: single quotes keep everything, double quotes keep
    /// everything but `\"`, `\\` and `\$`, a backslash escapes the next character, and a backslash before a
    /// newline joins the lines. An unfinished quote runs to the end.
    static func words(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var hasWord = false
        var quote: Character?
        var iterator = command.makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        while let ch = next() {
            if let open = quote {
                if ch == open { quote = nil; continue }
                if open == "\"", ch == "\\", let escaped = next() {
                    if escaped == "\"" || escaped == "\\" || escaped == "$" || escaped == "`" { current.append(escaped) }
                    else if escaped == "\n" { continue }
                    else { current.append("\\"); current.append(escaped) }
                    continue
                }
                current.append(ch)
                continue
            }
            switch ch {
            case "'", "\"":
                quote = ch
                hasWord = true
            case "\\":
                guard let escaped = next() else { continue }
                if escaped == "\n" || escaped == "\r" { continue }
                current.append(escaped)
                hasWord = true
            case " ", "\t", "\n", "\r":
                if hasWord { words.append(current); current = ""; hasWord = false }
            default:
                current.append(ch)
                hasWord = true
            }
        }
        if hasWord { words.append(current) }
        return words
    }

    /// The request the command describes, or nil when it is not a curl command with an address.
    static func parse(_ command: String) -> APIRequest? {
        var words = words(command)
        guard let start = words.firstIndex(where: { ($0 as NSString).lastPathComponent == "curl" }) else { return nil }
        words = Array(words[(start + 1)...])
        var method: APIMethod?
        var url: String?
        var headers: [APIKeyValue] = []
        var data: [String] = []
        var urlencoded: [APIKeyValue] = []
        var formFields: [APIKeyValue] = []
        var formFiles: [APIFormFile] = []
        var auth: APIAuth = .inherit
        var json: String?
        var asGet = false
        var head = false
        var index = 0
        func argument() -> String? {
            guard index + 1 < words.count else { return nil }
            index += 1
            return words[index]
        }
        func apply(_ option: String, _ value: String?) {
            switch option {
            case "X", "request": method = value.flatMap { APIMethod(rawValue: $0.uppercased()) }
            case "H", "header":
                guard let value, !value.hasPrefix("@"), let colon = value.firstIndex(of: ":") else { return }
                let name = value[..<colon].trimmingCharacters(in: .whitespaces)
                let text = value[value.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if name.caseInsensitiveCompare("Authorization") == .orderedSame, text.lowercased().hasPrefix("bearer ") {
                    auth = APIAuth(kind: .bearer, token: String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces))
                } else if !name.isEmpty {
                    headers.append(APIKeyValue(name, text))
                }
            case "d", "data", "data-raw", "data-binary", "data-ascii": if let value { data.append(value) }
            case "data-urlencode":
                guard let value else { return }
                let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 { urlencoded.append(APIKeyValue(String(parts[0]), String(parts[1]))) } else { data.append(value) }
            case "json":
                json = (json.map { $0 + "\n" } ?? "") + (value ?? "")
            case "F", "form", "form-string":
                guard let value else { return }
                let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts.first ?? "")
                let content = parts.count > 1 ? String(parts[1]) : ""
                if option != "form-string", content.hasPrefix("@") {
                    formFiles.append(APIFormFile(name: name, path: String(content.dropFirst().split(separator: ";").first ?? "")))
                } else {
                    formFields.append(APIKeyValue(name, content))
                }
            case "u", "user":
                guard let value else { return }
                let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                auth = APIAuth(kind: .basic, username: String(parts[0]), password: parts.count > 1 ? String(parts[1]) : "")
            case "oauth2-bearer": if let value { auth = APIAuth(kind: .bearer, token: value) }
            case "A", "user-agent": if let value { headers.append(APIKeyValue("User-Agent", value)) }
            case "e", "referer": if let value { headers.append(APIKeyValue("Referer", value)) }
            case "b", "cookie": if let value, value.contains("=") { headers.append(APIKeyValue("Cookie", value)) }
            case "url": url = url ?? value
            case "G", "get": asGet = true
            case "I", "head": head = true
            default: break
            }
        }
        while index < words.count {
            let word = words[index]
            if word.hasPrefix("--") {
                let body = String(word.dropFirst(2))
                if let equals = body.firstIndex(of: "=") {
                    apply(String(body[..<equals]), String(body[body.index(after: equals)...]))
                } else if takesArgument(long: body) {
                    apply(body, argument())
                } else {
                    apply(body, nil)
                }
            } else if word.hasPrefix("-"), word.count > 1 {
                // Bundled short options: -sS, -XPOST, -H'…'. The first one that takes an argument gets the rest.
                let letters = Array(word.dropFirst())
                var position = 0
                while position < letters.count {
                    let letter = letters[position]
                    if shortWithArgument.contains(letter) {
                        let rest = String(letters[(position + 1)...])
                        apply(String(letter), rest.isEmpty ? argument() : rest)
                        break
                    }
                    apply(String(letter), nil)
                    position += 1
                }
            } else if url == nil {
                url = word
            }
            index += 1
        }
        guard var address = url?.trimmingCharacters(in: .whitespaces), !address.isEmpty else { return nil }
        if !address.contains("://") { address = "http://" + address }
        guard let components = URLComponents(string: address), components.host?.isEmpty == false else { return nil }

        var request = APIRequest(name: "", method: .get, url: address)
        if let json {
            data = [json]
            if !headers.contains(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
                headers.append(APIKeyValue("Content-Type", "application/json"))
            }
        }
        if asGet, !data.isEmpty || !urlencoded.isEmpty {
            // `-G -d a=1` sends the data in the query, not the body.
            request.params = urlencoded + data.flatMap { HTTPFileBlocks.formFields($0) }
        } else if !formFields.isEmpty || !formFiles.isEmpty {
            request.body = APIBody(kind: .multipart, fields: formFields, files: formFiles)
        } else if !urlencoded.isEmpty {
            request.body = APIBody(kind: .urlencoded, fields: urlencoded + data.flatMap { HTTPFileBlocks.formFields($0) })
        } else if !data.isEmpty {
            let text = data.joined(separator: "&")
            let declared = headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
            let contentType = declared ?? (HTTPFileBlocks.looksLikeJSON(text) ? "application/json" : "application/x-www-form-urlencoded")
            if contentType.contains("x-www-form-urlencoded") {
                request.body = APIBody(kind: .urlencoded, fields: HTTPFileBlocks.formFields(text))
            } else {
                request.body = APIBody(kind: .raw, text: text, contentType: contentType)
            }
        }
        request.method = method ?? (head ? .head : (request.body.kind == .none || asGet ? .get : .post))
        request.headers = headers
        request.auth = auth
        request.name = HTTPFileBlocks.defaultName(method: request.method, url: address)
        return request
    }

    private static func takesArgument(long option: String) -> Bool {
        switch option {
        case "request", "header", "data", "data-raw", "data-binary", "data-ascii", "data-urlencode", "json", "form", "form-string",
             "user", "oauth2-bearer", "user-agent", "referer", "cookie", "url":
            return true
        default:
            return ignoredLongWithArgument.contains(option)
        }
    }
}

/// Finds a `curl` command in a line of terminal output, whatever printed it: a shell prompt (`$ curl …`,
/// `❯ curl …`), an assistant's tool line (`Bash(curl -s …)`) or plain text.
enum CurlDetection {
    private static let curlWord = try! NSRegularExpression(pattern: #"(?:^|[\s(\[;|&`$"'])curl(?=\s)"#)

    /// The command from `curl` to the end of the line, or nil when the line has none worth adding.
    static func command(in line: String) -> String? {
        let ns = line as NSString
        guard ns.length > 5, ns.length < 20_000 else { return nil }
        for match in curlWord.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let start = ns.range(of: "curl", options: [], range: match.range).location
            var text = ns.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
            // `Bash(curl …)` and `[curl …]`: the closing bracket belongs to the wrapper, not the address.
            let before = start > 0 ? ns.substring(with: NSRange(location: start - 1, length: 1)) : ""
            if before == "(", text.hasSuffix(")") { text.removeLast() }
            if before == "[", text.hasSuffix("]") { text.removeLast() }
            if before == "`", text.hasSuffix("`") { text.removeLast() }
            if before == "'" || before == "\"", text.hasSuffix(before) { text.removeLast() }
            // A shell shows "> " at the start of each continued line; that is its prompt, not the command.
            text = text.replacingOccurrences(of: #"\n\s*>\s?"#, with: "\n", options: .regularExpression)
            if CurlParser.parse(text) != nil { return text }
        }
        return nil
    }
}
