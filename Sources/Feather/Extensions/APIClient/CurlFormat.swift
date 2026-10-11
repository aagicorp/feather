import Foundation

/// A `curl` command line read into a request, and a request written back as one. People paste what an API's
/// documentation, a browser's "Copy as cURL" or a chat answer gives them, so the reader takes the shell forms
/// those produce: single and double quotes, `$'…'`, backslash-newline continuations, bunched short options
/// (`-sS`), values attached to the option (`-XPOST`) and `--option=value`.
enum CurlFormat {
    /// Whether the text starts like a curl command (a prompt or `sudo` in front is fine).
    static func looksLikeCurl(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
        for word in words.prefix(3) {
            if isCurlWord(word) { return true }
            if word != "$" && word != "sudo" && !word.hasPrefix("%") { return false }
        }
        return false
    }

    private static func isCurlWord(_ word: String) -> Bool {
        word == "curl" || word == "curl.exe" || word.hasSuffix("/curl")
    }

    /// The request a command line describes, or nil when the text is not a curl command.
    static func parse(_ text: String) -> APIRequest? {
        var words = shellWords(text)
        while let first = words.first, first == "$" || first == "sudo" || first.hasPrefix("%") { words.removeFirst() }
        guard let first = words.first, isCurlWord(first) else { return nil }
        words.removeFirst()

        var method: String?
        var headers: [APIKeyValue] = []
        var dataPieces: [String] = []
        var urlencodedFields: [APIKeyValue] = []
        var formFields: [APIKeyValue] = []
        var formFiles: [APIFormFile] = []
        var url: String?
        var basic: (user: String, password: String)?
        var bearer: String?
        var sendsJSON = false
        var dataAsQuery = false
        var headOnly = false

        func addHeader(_ text: String) {
            // "Name: value"; "Name;" sends an empty header; "Name:" removes a default one (kept, empty).
            if let colon = text.firstIndex(of: ":") {
                headers.append(APIKeyValue(String(text[..<colon]).trimmingCharacters(in: .whitespaces),
                                           String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            } else if text.hasSuffix(";") {
                headers.append(APIKeyValue(String(text.dropLast()).trimmingCharacters(in: .whitespaces), ""))
            } else if !text.isEmpty {
                headers.append(APIKeyValue(text.trimmingCharacters(in: .whitespaces), ""))
            }
        }
        func addForm(_ text: String, literal: Bool) {
            guard let equals = text.firstIndex(of: "=") else { formFields.append(APIKeyValue(text, "")); return }
            let name = String(text[..<equals])
            var value = String(text[text.index(after: equals)...])
            if !literal, value.hasPrefix("@") || value.hasPrefix("<") {
                let isFile = value.hasPrefix("@")
                value.removeFirst()
                // "@path;type=image/png;filename=x" — the path comes first.
                let path = value.split(separator: ";", maxSplits: 1).first.map(String.init) ?? value
                if isFile { formFiles.append(APIFormFile(name: name, path: path)) }
                else { formFields.append(APIKeyValue(name, "<" + path)) }
            } else {
                formFields.append(APIKeyValue(name, value))
            }
        }
        func apply(option: String, value: String?) {
            switch option {
            case "X", "request": method = value?.uppercased()
            case "H", "header": if let value { addHeader(value) }
            case "d", "data", "data-raw", "data-binary", "data-ascii": if let value { dataPieces.append(value) }
            case "data-urlencode":
                guard let value else { return }
                // name=value, =value, name@file, @file, or just content.
                if let equals = value.firstIndex(of: "=") {
                    urlencodedFields.append(APIKeyValue(String(value[..<equals]), String(value[value.index(after: equals)...])))
                } else {
                    dataPieces.append(value)
                }
            case "F", "form": if let value { addForm(value, literal: false) }
            case "form-string": if let value { addForm(value, literal: true) }
            case "u", "user":
                guard let value else { return }
                if let colon = value.firstIndex(of: ":") {
                    basic = (String(value[..<colon]), String(value[value.index(after: colon)...]))
                } else {
                    basic = (value, "")
                }
            case "oauth2-bearer": bearer = value
            case "url": if let value, url == nil { url = value }
            case "A", "user-agent": if let value { headers.append(APIKeyValue("User-Agent", value)) }
            case "e", "referer": if let value { headers.append(APIKeyValue("Referer", value)) }
            case "b", "cookie": if let value, !value.contains("/") || value.contains("=") { headers.append(APIKeyValue("Cookie", value)) }
            case "json":
                if let value { dataPieces.append(value) }
                sendsJSON = true
            case "G", "get": dataAsQuery = true
            case "I", "head": headOnly = true
            default: break
            }
        }

        // Options whose value is the next word (or attached, as in -XPOST and --data=…).
        let shortWithValue: Set<Character> = ["X", "H", "d", "F", "u", "A", "e", "b", "o", "w", "m", "c", "K", "T", "E", "U", "x", "r", "y", "Y", "z", "C", "D", "P", "Q", "t"]
        let longWithValue: Set<String> = ["request", "header", "data", "data-raw", "data-binary", "data-ascii", "data-urlencode", "form",
                                          "form-string", "user", "url", "user-agent", "referer", "cookie", "cookie-jar", "output", "max-time",
                                          "connect-timeout", "proxy", "json", "cert", "key", "cacert", "capath", "retry", "retry-delay",
                                          "retry-max-time", "write-out", "range", "resolve", "upload-file", "unix-socket", "oauth2-bearer",
                                          "interface", "dump-header", "config", "limit-rate", "max-redirs", "proxy-user", "trace",
                                          "trace-ascii", "stderr", "engine", "ciphers", "tls-max", "keepalive-time", "pinnedpubkey",
                                          "proto", "expect100-timeout", "happy-eyeballs-timeout-ms", "abstract-unix-socket", "aws-sigv4",
                                          "create-file-mode", "dns-servers", "doh-url", "etag-save", "etag-compare", "ftp-port", "hostpubmd5",
                                          "local-port", "login-options", "mail-from", "mail-rcpt", "netrc-file", "noproxy", "pass",
                                          "proxy-header", "pubkey", "referer", "request-target", "service-name", "socks5", "speed-limit",
                                          "speed-time", "tlsuser", "tlspassword", "tlsauthtype", "url-query", "variable"]
        var index = 0
        while index < words.count {
            let word = words[index]
            index += 1
            if word == "--" { if index < words.count, url == nil { url = words[index] }; break }
            if word.hasPrefix("--"), word.count > 2 {
                var name = String(word.dropFirst(2))
                var attached: String?
                if let equals = name.firstIndex(of: "=") {
                    attached = String(name[name.index(after: equals)...])
                    name = String(name[..<equals])
                }
                if longWithValue.contains(name) {
                    let value: String?
                    if let attached { value = attached }
                    else if index < words.count { value = words[index]; index += 1 }
                    else { value = nil }
                    apply(option: name, value: value)
                } else {
                    apply(option: name, value: nil)
                }
            } else if word.hasPrefix("-"), word.count > 1 {
                var letters = Substring(word.dropFirst())
                while let letter = letters.first {
                    letters = letters.dropFirst()
                    if shortWithValue.contains(letter) {
                        let value: String?
                        if !letters.isEmpty { value = String(letters) }
                        else if index < words.count { value = words[index]; index += 1 }
                        else { value = nil }
                        apply(option: String(letter), value: value)
                        break
                    }
                    apply(option: String(letter), value: nil)
                }
            } else if url == nil {
                url = word
            }
        }

        guard var address = url?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else { return nil }
        if address.hasPrefix("'") || address.hasPrefix("\"") { address = String(address.dropFirst().dropLast()) }

        // Headers that are really auth become the auth form, so they are not sent twice.
        var auth = APIAuth.inherit
        if let position = headers.firstIndex(where: { $0.name.caseInsensitiveCompare("Authorization") == .orderedSame }) {
            let value = headers[position].value
            if value.lowercased().hasPrefix("bearer ") {
                auth = APIAuth(kind: .bearer, token: String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces))
                headers.remove(at: position)
            } else if value.lowercased().hasPrefix("basic "),
                      let decoded = Data(base64Encoded: String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces)),
                      let pair = String(data: decoded, encoding: .utf8), let colon = pair.firstIndex(of: ":") {
                auth = APIAuth(kind: .basic, username: String(pair[..<colon]), password: String(pair[pair.index(after: colon)...]))
                headers.remove(at: position)
            }
        }
        if let basic { auth = APIAuth(kind: .basic, username: basic.user, password: basic.password) }
        if let bearer { auth = APIAuth(kind: .bearer, token: bearer) }

        let contentTypeIndex = headers.firstIndex { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }
        let contentType = contentTypeIndex.map { headers[$0].value }
        var body = APIBody.none
        var params: [APIKeyValue] = []
        let joinedData = (dataPieces + urlencodedFields.map { encodeForm($0.name) + "=" + encodeForm($0.value) }).joined(separator: "&")
        if !formFields.isEmpty || !formFiles.isEmpty {
            body = APIBody(kind: .multipart, fields: formFields, files: formFiles)
            if let contentTypeIndex, contentType?.lowercased().hasPrefix("multipart") == true { headers.remove(at: contentTypeIndex) }
        } else if !joinedData.isEmpty {
            if dataAsQuery {
                params = formPairs(joinedData) ?? [APIKeyValue(joinedData, "")]
            } else if sendsJSON || contentType?.lowercased().contains("json") == true {
                body = APIBody(kind: .raw, text: joinedData, contentType: contentType ?? "application/json")
            } else if let contentType {
                if contentType.lowercased().hasPrefix("application/x-www-form-urlencoded"), let pairs = formPairs(joinedData) {
                    body = APIBody(kind: .urlencoded, fields: pairs)
                    if let contentTypeIndex { headers.remove(at: contentTypeIndex) }
                } else {
                    body = APIBody(kind: .raw, text: joinedData, contentType: contentType)
                }
            } else if !urlencodedFields.isEmpty || looksLikeForm(joinedData), let pairs = formPairs(joinedData) {
                body = APIBody(kind: .urlencoded, fields: pairs)
            } else if looksLikeJSON(joinedData) {
                // curl would send this as a form, but nobody means that when they paste JSON.
                body = .json(joinedData)
            } else {
                body = APIBody(kind: .raw, text: joinedData, contentType: "application/x-www-form-urlencoded")
            }
        }
        if sendsJSON {
            if contentType == nil { headers.append(APIKeyValue("Content-Type", "application/json")) }
            if !headers.contains(where: { $0.name.caseInsensitiveCompare("Accept") == .orderedSame }) { headers.append(APIKeyValue("Accept", "application/json")) }
        }

        let chosen: APIMethod
        if headOnly { chosen = .head }
        else if let method, let known = APIMethod(rawValue: method) { chosen = known }
        else { chosen = body.kind == .none ? .get : .post }

        var request = APIRequest(name: name(for: chosen, url: address), method: chosen, url: address)
        request.headers = headers
        request.params = params
        request.body = body
        request.auth = auth
        return request
    }

    /// "POST /v1/users" — the method and path, which is how people refer to an endpoint.
    static func name(for method: APIMethod, url: String) -> String {
        var rest = url
        if let range = rest.range(of: "://") { rest = String(rest[range.upperBound...]) }
        if let query = rest.firstIndex(of: "?") { rest = String(rest[..<query]) }
        let path = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? ""
        let shown = (path.isEmpty || path == "/") ? rest : path
        return "\(method.rawValue) \(shown.isEmpty ? url : shown)"
    }

    // MARK: Body shapes

    private static func looksLikeJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
    }

    private static func looksLikeForm(_ text: String) -> Bool {
        !text.contains("\n") && !text.hasPrefix("{") && !text.hasPrefix("[") && !text.hasPrefix("<")
            && text.split(separator: "&").allSatisfy { $0.contains("=") }
    }

    /// "a=1&b=2" as fields, percent-decoded; nil when a piece has no "=".
    private static func formPairs(_ text: String) -> [APIKeyValue]? {
        let pieces = text.split(separator: "&", omittingEmptySubsequences: true)
        guard !pieces.isEmpty, pieces.allSatisfy({ $0.contains("=") }) else { return nil }
        return pieces.map { piece in
            let equals = piece.firstIndex(of: "=")!
            let name = String(piece[..<equals]).replacingOccurrences(of: "+", with: " ")
            let value = String(piece[piece.index(after: equals)...]).replacingOccurrences(of: "+", with: " ")
            return APIKeyValue(name.removingPercentEncoding ?? name, value.removingPercentEncoding ?? value)
        }
    }

    private static func encodeForm(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    // MARK: Shell words

    /// The words of a command line as a POSIX shell would split them: quotes removed, escapes applied,
    /// backslash-newline joined. Stops at an unquoted `|`, `;` or `&&`, so a trailing `| jq` does no harm.
    static func shellWords(_ text: String) -> [String] {
        let chars = Array(text)
        var words: [String] = []
        var current = ""
        var inWord = false
        var index = 0
        func finish() {
            if inWord { words.append(current) }
            current = ""
            inWord = false
        }
        scan: while index < chars.count {
            let char = chars[index]
            switch char {
            case "\\":
                guard index + 1 < chars.count else { index += 1; continue }
                let next = chars[index + 1]
                if next == "\n" { index += 2; continue }
                if next == "\r" { index += (index + 2 < chars.count && chars[index + 2] == "\n") ? 3 : 2; continue }
                current.append(next)
                inWord = true
                index += 2
            case "'":
                inWord = true
                index += 1
                while index < chars.count, chars[index] != "'" { current.append(chars[index]); index += 1 }
                index += 1
            case "\"":
                inWord = true
                index += 1
                while index < chars.count, chars[index] != "\"" {
                    if chars[index] == "\\", index + 1 < chars.count, ["\"", "\\", "$", "`", "\n"].contains(chars[index + 1]) {
                        if chars[index + 1] != "\n" { current.append(chars[index + 1]) }
                        index += 2
                    } else {
                        current.append(chars[index])
                        index += 1
                    }
                }
                index += 1
            case "$" where index + 1 < chars.count && chars[index + 1] == "'":
                inWord = true
                index += 2
                while index < chars.count, chars[index] != "'" {
                    if chars[index] == "\\", index + 1 < chars.count {
                        switch chars[index + 1] {
                        case "n": current.append("\n")
                        case "t": current.append("\t")
                        case "r": current.append("\r")
                        default: current.append(chars[index + 1])
                        }
                        index += 2
                    } else {
                        current.append(chars[index])
                        index += 1
                    }
                }
                index += 1
            case " ", "\t", "\n", "\r":
                finish()
                index += 1
            case "|", ";":
                break scan
            case "&" where index + 1 < chars.count && chars[index + 1] == "&":
                break scan
            case "#" where !inWord:
                // A comment runs to the end of the line.
                while index < chars.count, chars[index] != "\n" { index += 1 }
            default:
                current.append(char)
                inWord = true
                index += 1
            }
        }
        finish()
        return words
    }

    // MARK: Writing

    /// The command line that sends `request` as Feather would, variables resolved and auth applied. A request
    /// whose address cannot be resolved still gets a best-effort line, so Copy as cURL always copies something.
    static func command(for request: APIRequest, variables: APIVariables, inheritedAuth: [APIAuth] = [], projectRoot: URL? = nil) -> String {
        let context = APIRequestSender.Context(variables: variables, inheritedAuth: inheritedAuth, environment: nil, projectRoot: projectRoot)
        if request.body.kind == .multipart {
            return multipartCommand(for: request, variables: variables, context: context)
        }
        if let resolved = try? APIRequestSender.resolve(request, context: context) { return resolved.curl }
        var parts = ["curl"]
        if request.method != .get { parts.append("-X " + request.method.rawValue) }
        for header in request.headers where header.enabled && !header.name.isEmpty {
            parts.append("-H " + quote("\(variables.resolve(header.name)): \(variables.resolve(header.value))"))
        }
        if request.body.kind == .raw, !request.body.text.isEmpty { parts.append("--data-raw " + quote(variables.resolve(request.body.text))) }
        parts.append(quote(variables.resolve(request.url)))
        return parts.joined(separator: " \\\n  ")
    }

    /// Multipart bodies are written as `-F` parts rather than a boundary-laden blob, as a person would write them.
    private static func multipartCommand(for request: APIRequest, variables: APIVariables, context: APIRequestSender.Context) -> String {
        var plain = request
        plain.body = .none
        let resolved = try? APIRequestSender.resolve(plain, context: context)
        var parts = ["curl"]
        if request.method != .get { parts.append("-X " + request.method.rawValue) }
        for header in resolved?.headers ?? [] { parts.append("-H " + quote("\(header.name): \(header.value)")) }
        for field in request.body.fields where field.enabled && !field.name.isEmpty {
            parts.append("-F " + quote("\(variables.resolve(field.name))=\(variables.resolve(field.value))"))
        }
        for file in request.body.files where file.enabled {
            parts.append("-F " + quote("\(file.name)=@\(file.path)"))
        }
        parts.append(quote(resolved?.url.absoluteString ?? variables.resolve(request.url)))
        return parts.joined(separator: " \\\n  ")
    }

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
