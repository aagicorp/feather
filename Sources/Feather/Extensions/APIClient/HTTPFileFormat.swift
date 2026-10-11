import Foundation

/// `.http` / `.rest` files as VS Code's REST Client writes them: requests separated by `###`, an optional
/// `# @name`, `METHOD URL`, header lines, a blank line, the body. `@name = value` lines are file variables,
/// which become collection variables; `{{name}}` references are left for Feather to resolve.
enum HTTPFileFormat {
    struct Parsed {
        var requests: [APIRequest] = []
        var variables: [APIVariable] = []
        var notes: [String] = []
    }

    private static let methods = Set(APIMethod.allCases.map(\.rawValue))
    private static let requestLine = try! NSRegularExpression(pattern: #"^([A-Z]+)\s+(\S.*?)(?:\s+HTTP/[\d.]+)?\s*$"#)

    /// Whether the text has the shape of a request file (a request line, a `###` separator or a file variable).
    static func looksLikeHTTPFile(_ text: String) -> Bool {
        for line in text.components(separatedBy: .newlines).prefix(200) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("###") { return true }
            if trimmed.hasPrefix("@"), trimmed.contains("=") { return true }
            if let method = trimmed.split(separator: " ").first, methods.contains(String(method)), trimmed.count > method.count + 1 { return true }
        }
        return false
    }

    // MARK: Reading

    static func parse(_ text: String) -> Parsed {
        var parsed = Parsed()
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // Blocks: `###` starts a new one; the text after it is a fallback name.
        var blocks: [(title: String?, lines: [String])] = [(nil, [])]
        for line in lines {
            if line.hasPrefix("###") {
                let title = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                blocks.append((title.isEmpty ? nil : title, []))
            } else {
                blocks[blocks.count - 1].lines.append(line)
            }
        }
        for block in blocks {
            var name: String?
            var comments: [String] = []
            var checks: [APICheck] = []
            var captures: [APICapture] = []
            var lineIndex = 0
            var request: APIRequest?
            // Preamble: variables, comments and directives, until the request line.
            while lineIndex < block.lines.count {
                let line = block.lines[lineIndex]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                lineIndex += 1
                if trimmed.isEmpty { continue }
                if trimmed.hasPrefix("@"), let equals = trimmed.firstIndex(of: "=") {
                    let variableName = String(trimmed[trimmed.index(after: trimmed.startIndex)..<equals]).trimmingCharacters(in: .whitespaces)
                    let value = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                    if let existing = parsed.variables.firstIndex(where: { $0.name == variableName }) { parsed.variables[existing].value = value }
                    else { parsed.variables.append(APIVariable(variableName, value)) }
                    continue
                }
                if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
                    let comment = trimmed.hasPrefix("//") ? String(trimmed.dropFirst(2)) : String(trimmed.dropFirst(1))
                    let content = comment.trimmingCharacters(in: .whitespaces)
                    if content.hasPrefix("@name") {
                        name = String(content.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    } else if content.hasPrefix("@check ") {
                        if let check = APICheckLines.parseCheck(String(content.dropFirst(7))) { checks.append(check) }
                    } else if content.hasPrefix("@set ") {
                        if let capture = APICheckLines.parseCapture(String(content.dropFirst(1))) { captures.append(capture) }
                    } else if content.hasPrefix("@secret ") {
                        let secretName = String(content.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                        if let existing = parsed.variables.firstIndex(where: { $0.name == secretName }) { parsed.variables[existing].secret = true }
                        else { parsed.variables.append(APIVariable(secretName, "", secret: true)) }
                    } else if content.hasPrefix("@") {
                        // Other REST Client directives (@prompt, @no-redirect…) have no counterpart.
                    } else {
                        comments.append(content)
                    }
                    continue
                }
                // The request line.
                var method = APIMethod.get
                var url = trimmed
                if let match = requestLine.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) {
                    let word = (trimmed as NSString).substring(with: match.range(at: 1))
                    if let known = APIMethod(rawValue: word) {
                        method = known
                        url = (trimmed as NSString).substring(with: match.range(at: 2))
                    } else if methods.contains(word) == false, word.allSatisfy(\.isUppercase), word.count >= 3 {
                        parsed.notes.append("\(word) is not a method Feather can send; the request was read as GET.")
                        url = (trimmed as NSString).substring(with: match.range(at: 2))
                    }
                }
                if let space = url.range(of: " HTTP/") { url = String(url[..<space.lowerBound]) }
                // A query spread over indented lines starting with ? or &.
                while lineIndex < block.lines.count {
                    let next = block.lines[lineIndex].trimmingCharacters(in: .whitespaces)
                    guard next.hasPrefix("?") || next.hasPrefix("&") else { break }
                    url += next
                    lineIndex += 1
                }
                request = APIRequest(name: "", method: method, url: url)
                break
            }
            guard var found = request else { continue }
            // Headers until a blank line.
            var headers: [APIKeyValue] = []
            while lineIndex < block.lines.count {
                let line = block.lines[lineIndex]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { lineIndex += 1; break }
                lineIndex += 1
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers.append(APIKeyValue(String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                                           String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            }
            // The body is the rest, without trailing blank lines.
            var bodyLines = Array(block.lines[lineIndex...])
            while let last = bodyLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { bodyLines.removeLast() }
            var bodyText = bodyLines.joined(separator: "\n")
            // Auth written as a header comes back as the auth form.
            if let index = headers.firstIndex(where: { $0.name.caseInsensitiveCompare("Authorization") == .orderedSame }) {
                let value = headers[index].value
                if value.lowercased().hasPrefix("bearer ") {
                    found.auth = APIAuth(kind: .bearer, token: String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces))
                    headers.remove(at: index)
                } else if value.lowercased().hasPrefix("basic ") {
                    let credentials = String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    if let colon = credentials.firstIndex(of: ":") {
                        found.auth = APIAuth(kind: .basic, username: String(credentials[..<colon]), password: String(credentials[credentials.index(after: colon)...]))
                        headers.remove(at: index)
                    } else if credentials.contains(" ") {
                        let parts = credentials.split(separator: " ", maxSplits: 1).map(String.init)
                        found.auth = APIAuth(kind: .basic, username: parts[0], password: parts.count > 1 ? parts[1] : "")
                        headers.remove(at: index)
                    } else if let decoded = Data(base64Encoded: credentials), let pair = String(data: decoded, encoding: .utf8),
                              let colon = pair.firstIndex(of: ":") {
                        found.auth = APIAuth(kind: .basic, username: String(pair[..<colon]), password: String(pair[pair.index(after: colon)...]))
                        headers.remove(at: index)
                    }
                }
            }
            let contentTypeIndex = headers.firstIndex { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }
            let contentType = contentTypeIndex.map { headers[$0].value } ?? "application/json"
            if !bodyText.isEmpty {
                if bodyText.trimmingCharacters(in: .whitespaces).hasPrefix("< ") {
                    parsed.notes.append("\(name ?? block.title ?? found.url) takes its body from a file (\(bodyText.trimmingCharacters(in: .whitespaces).dropFirst(2))), which Feather does not do yet; the line was kept as text.")
                }
                if contentType.lowercased().hasPrefix("application/x-www-form-urlencoded"), let fields = formFields(bodyText) {
                    found.body = APIBody(kind: .urlencoded, fields: fields)
                    if let contentTypeIndex { headers.remove(at: contentTypeIndex) }
                } else {
                    if bodyText.hasSuffix("\n") { bodyText.removeLast() }
                    found.body = APIBody(kind: .raw, text: bodyText, contentType: contentType)
                    if let contentTypeIndex { headers.remove(at: contentTypeIndex) }
                }
            }
            found.headers = headers
            found.checks = checks
            found.captures = captures
            found.description = comments.joined(separator: "\n")
            found.name = name ?? block.title ?? CurlFormat.name(for: found.method, url: found.url)
            parsed.requests.append(found)
        }
        return parsed
    }

    private static func formFields(_ text: String) -> [APIKeyValue]? {
        let pieces = text.replacingOccurrences(of: "\n", with: "").split(separator: "&", omittingEmptySubsequences: true)
        guard !pieces.isEmpty, pieces.allSatisfy({ $0.contains("=") }) else { return nil }
        return pieces.map { piece in
            let parts = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let name = parts[0].replacingOccurrences(of: "+", with: " ")
            let value = (parts.count > 1 ? parts[1] : "").replacingOccurrences(of: "+", with: " ")
            return APIKeyValue(name.removingPercentEncoding ?? name, value.removingPercentEncoding ?? value)
        }
    }

    // MARK: Writing

    /// The whole collection as one file: variables at the top, then every request in tree order with the
    /// folders above it in the `###` line.
    static func serialize(_ collection: APICollection) -> String {
        var out = ""
        if !collection.name.isEmpty { out += "# \(collection.name)\n" }
        for line in collection.description.components(separatedBy: "\n") where !line.isEmpty { out += "# \(line)\n" }
        for variable in collection.variables where variable.enabled {
            out += variable.secret ? "@\(variable.name) = \n" : "@\(variable.name) = \(variable.value)\n"
        }
        // Secret values stay out of the file; the names are marked so they come back as secrets.
        for variable in collection.variables where variable.secret && variable.enabled { out += "# @secret \(variable.name)\n" }
        if !out.isEmpty { out += "\n" }
        for (request, path) in collection.allRequests {
            let inherited = path.reversed().map(\.auth) + [collection.auth]
            out += serialize(request, title: (path.map(\.name) + [request.name]).joined(separator: " / "), inheritedAuth: inherited)
            out += "\n"
        }
        return out
    }

    /// One request block. Auth is written as an Authorization header when the request or its folders set one.
    static func serialize(_ request: APIRequest, title: String? = nil, inheritedAuth: [APIAuth] = []) -> String {
        var out = "### \(title ?? request.name)\n"
        out += "# @name \(request.name)\n"
        for line in request.description.components(separatedBy: "\n") where !line.isEmpty { out += "# \(line)\n" }
        for check in request.checks where check.enabled { out += "# @check \(APICheckLines.describe(check))\n" }
        for capture in request.captures where capture.enabled { out += "# @\(APICheckLines.describe(capture))\n" }
        var url = request.url
        var query = request.params.filter { $0.enabled && !$0.name.isEmpty }.map { $0.value.isEmpty ? $0.name : "\($0.name)=\($0.value)" }
        var headers = request.headers.filter { $0.enabled && !$0.name.isEmpty }.map { ($0.name, $0.value) }
        let auth = ([request.auth] + inheritedAuth).first { $0.kind != .inherit } ?? .none
        switch auth.kind {
        case .bearer: headers.append(("Authorization", "Bearer " + auth.token))
        case .basic: headers.append(("Authorization", "Basic \(auth.username):\(auth.password)"))
        case .apiKey:
            if auth.keyIn == .header { headers.append((auth.keyName, auth.keyValue)) }
            else { query.append("\(auth.keyName)=\(auth.keyValue)") }
        case .none, .inherit: break
        }
        if !query.isEmpty { url += (url.contains("?") ? "&" : "?") + query.joined(separator: "&") }
        out += "\(request.method.rawValue) \(url)\n"
        var body: String?
        switch request.body.kind {
        case .none: break
        case .raw:
            if !headers.contains(where: { $0.0.caseInsensitiveCompare("Content-Type") == .orderedSame }) { headers.append(("Content-Type", request.body.contentType)) }
            body = request.body.text
        case .urlencoded, .form:
            headers.removeAll { $0.0.caseInsensitiveCompare("Content-Type") == .orderedSame }
            headers.append(("Content-Type", "application/x-www-form-urlencoded"))
            body = request.body.fields.filter { $0.enabled && !$0.name.isEmpty }.map { encode($0.name) + "=" + encode($0.value) }.joined(separator: "&")
        case .multipart:
            let boundary = "FeatherBoundary"
            headers.removeAll { $0.0.caseInsensitiveCompare("Content-Type") == .orderedSame }
            headers.append(("Content-Type", "multipart/form-data; boundary=\(boundary)"))
            var parts: [String] = []
            for field in request.body.fields where field.enabled && !field.name.isEmpty {
                parts.append("--\(boundary)\nContent-Disposition: form-data; name=\"\(field.name)\"\n\n\(field.value)")
            }
            for file in request.body.files where file.enabled {
                parts.append("--\(boundary)\nContent-Disposition: form-data; name=\"\(file.name)\"; filename=\"\((file.path as NSString).lastPathComponent)\"\n\n< \(file.path)")
            }
            body = parts.joined(separator: "\n") + "\n--\(boundary)--"
        }
        for header in headers { out += "\(header.0): \(header.1)\n" }
        if let body, !body.isEmpty { out += "\n" + body + "\n" }
        return out
    }

    private static func encode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~{}")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
