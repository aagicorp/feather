import Foundation

/// Postman collection v2.1 and environment files, both ways. What Postman has and Feather does not (scripts,
/// saved example responses, exotic auth) is kept as text or reported in the notes rather than dropped silently;
/// what Feather has and Postman does not (checks, captures) travels as plain lines in the description, which
/// Postman shows and Feather reads back.
enum PostmanFormat {
    static let schema = "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
    static let secretsNote = "Secret variables are left blank in this export:"

    static func isCollection(_ json: [String: Any]) -> Bool {
        json["info"] is [String: Any] && json["item"] is [Any]
    }

    static func isEnvironment(_ json: [String: Any]) -> Bool {
        json["values"] is [Any] && (json["name"] != nil || json["_postman_variable_scope"] != nil)
    }

    // MARK: Reading

    struct Reader {
        private(set) var notes: [String] = []
        private var scriptedRequests: [String] = []
        private var unsupportedAuth: [String] = []
        private var pathVariables: [APIVariable] = []

        static func read(_ json: [String: Any]) -> (collection: APICollection, notes: [String]) {
            var reader = Reader()
            let collection = reader.collection(json)
            return (collection, reader.notes)
        }

        private mutating func collection(_ json: [String: Any]) -> APICollection {
            let info = json["info"] as? [String: Any] ?? [:]
            var collection = APICollection(name: text(info["name"]) ?? "Imported collection")
            if let id = text(info["_postman_id"]), !id.isEmpty { collection.id = id }
            // A note Feather's own export adds does not belong in the description once it is back.
            collection.description = APICheckLines.split(text(info["description"]) ?? "").text
                .components(separatedBy: "\n").filter { !$0.hasPrefix(PostmanFormat.secretsNote) }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            collection.items = items(json["item"] as? [Any] ?? [])
            collection.variables = (json["variable"] as? [Any] ?? []).compactMap { variable($0) }
            for extra in pathVariables where !collection.variables.contains(where: { $0.name == extra.name }) {
                collection.variables.append(extra)
            }
            let (auth, unsupported) = PostmanFormat.auth(json["auth"])
            collection.auth = auth.kind == .inherit ? .none : auth
            if let unsupported { unsupportedAuth.append("the collection (\(unsupported))") }
            if !(events(json["event"]) ?? [:]).isEmpty { notes.append("The collection has Postman scripts, which Feather does not run; they were not kept.") }
            if !scriptedRequests.isEmpty {
                let shown = scriptedRequests.count > 5 ? scriptedRequests.prefix(5).joined(separator: ", ") + " and \(scriptedRequests.count - 5) more" : scriptedRequests.joined(separator: ", ")
                notes.append("Postman scripts were kept as text on \(scriptedRequests.count == 1 ? "1 request" : "\(scriptedRequests.count) requests") but do not run: \(shown). Use checks instead.")
            }
            if !unsupportedAuth.isEmpty {
                notes.append("Feather has no form for the sign-in type on \(unsupportedAuth.joined(separator: ", ")); set it again by hand.")
            }
            if !pathVariables.isEmpty {
                notes.append("Path variables (\(pathVariables.map(\.name).joined(separator: ", "))) became {{name}} placeholders and collection variables.")
            }
            return collection
        }

        private mutating func items(_ list: [Any]) -> [APIItem] {
            list.compactMap { $0 as? [String: Any] }.compactMap { item($0) }
        }

        private mutating func item(_ dict: [String: Any]) -> APIItem? {
            let name = text(dict["name"]) ?? "Untitled"
            if let children = dict["item"] as? [Any] {
                var folder = APIFolder(name: name, items: items(children))
                if let id = text(dict["id"]), !id.isEmpty { folder.id = id }
                folder.description = APICheckLines.split(text(dict["description"]) ?? "").text
                let (auth, unsupported) = PostmanFormat.auth(dict["auth"])
                folder.auth = auth
                if let unsupported { unsupportedAuth.append("folder \(name) (\(unsupported))") }
                if !(events(dict["event"]) ?? [:]).isEmpty { notes.append("Folder \(name) has Postman scripts, which were not kept.") }
                return .folder(folder)
            }
            guard let requestValue = dict["request"] else { return nil }
            var request = APIRequest(name: name)
            if let id = text(dict["id"]), !id.isEmpty { request.id = id }
            if let raw = requestValue as? String {
                request.url = raw
            } else if let spec = requestValue as? [String: Any] {
                fill(&request, from: spec)
            }
            if let scripts = events(dict["event"]), !scripts.isEmpty {
                request.importedScripts = scripts
                scriptedRequests.append(name)
            }
            return .request(request)
        }

        private mutating func fill(_ request: inout APIRequest, from spec: [String: Any]) {
            if let method = text(spec["method"])?.uppercased() {
                if let known = APIMethod(rawValue: method) { request.method = known }
                else { notes.append("\(request.name) uses \(method), which Feather cannot send; it was imported as GET.") }
            }
            let (description, checks, captures) = APICheckLines.split(text(spec["description"]) ?? "")
            request.description = description
            request.checks = checks
            request.captures = captures
            readURL(spec["url"], into: &request)
            request.headers = headers(spec["header"])
            let (auth, unsupported) = PostmanFormat.auth(spec["auth"])
            request.auth = auth
            if let unsupported { unsupportedAuth.append("request \(request.name) (\(unsupported))") }
            if let body = spec["body"] as? [String: Any] { request.body = self.body(body, headers: request.headers, requestName: request.name) }
            if request.body.kind == .raw, let type = request.headers.first(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame })?.value, !type.isEmpty {
                request.body.contentType = type
            }
        }

        private mutating func readURL(_ value: Any?, into request: inout APIRequest) {
            var raw: String
            var query: [Any] = []
            var variables: [Any] = []
            if let string = value as? String {
                raw = string
            } else if let dict = value as? [String: Any] {
                query = dict["query"] as? [Any] ?? []
                variables = dict["variable"] as? [Any] ?? []
                if let string = text(dict["raw"]), !string.isEmpty {
                    raw = string
                } else {
                    let hostParts = (dict["host"] as? [Any])?.compactMap { text($0) } ?? [text(dict["host"])].compactMap { $0 }
                    let pathParts = (dict["path"] as? [Any])?.compactMap { part -> String? in
                        if let string = part as? String { return string }
                        return text((part as? [String: Any])?["value"])
                    } ?? [text(dict["path"])].compactMap { $0 }
                    raw = ""
                    if let scheme = text(dict["protocol"]), !scheme.isEmpty { raw = scheme + "://" }
                    raw += hostParts.joined(separator: ".")
                    if let port = text(dict["port"]), !port.isEmpty { raw += ":" + port }
                    if !pathParts.isEmpty { raw += "/" + pathParts.joined(separator: "/") }
                }
            } else {
                return
            }
            var params: [APIKeyValue] = []
            if let questionMark = raw.firstIndex(of: "?") {
                let queryText = String(raw[raw.index(after: questionMark)...])
                raw = String(raw[..<questionMark])
                if query.isEmpty {
                    params = queryText.split(separator: "&").map { piece in
                        let parts = piece.split(separator: "=", maxSplits: 1).map(String.init)
                        return APIKeyValue(parts.first ?? "", parts.count > 1 ? parts[1] : "")
                    }
                }
            }
            for entry in query.compactMap({ $0 as? [String: Any] }) {
                var param = APIKeyValue(text(entry["key"]) ?? "", text(entry["value"]) ?? "")
                param.enabled = !(entry["disabled"] as? Bool ?? false)
                param.note = text(entry["description"])
                params.append(param)
            }
            // Postman's `:id` path variables become {{id}}, with the value as a collection variable.
            for entry in variables.compactMap({ $0 as? [String: Any] }) {
                guard let key = text(entry["key"]), !key.isEmpty else { continue }
                if raw.contains(":" + key) {
                    raw = raw.replacingOccurrences(of: ":" + key, with: "{{\(key)}}")
                    if !pathVariables.contains(where: { $0.name == key }) { pathVariables.append(APIVariable(key, text(entry["value"]) ?? "")) }
                }
            }
            request.url = raw
            request.params = params
        }

        private func headers(_ value: Any?) -> [APIKeyValue] {
            if let string = value as? String {
                return string.split(separator: "\n").compactMap { line in
                    let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard let name = parts.first, !name.isEmpty else { return nil }
                    return APIKeyValue(name, parts.count > 1 ? parts[1] : "")
                }
            }
            return (value as? [Any] ?? []).compactMap { entry in
                guard let dict = entry as? [String: Any], let key = text(dict["key"]) else { return nil }
                var header = APIKeyValue(key, text(dict["value"]) ?? "")
                header.enabled = !(dict["disabled"] as? Bool ?? false)
                header.note = text(dict["description"])
                return header
            }
        }

        private mutating func body(_ dict: [String: Any], headers: [APIKeyValue], requestName: String) -> APIBody {
            let mode = text(dict["mode"]) ?? "raw"
            switch mode {
            case "raw":
                let language = text(((dict["options"] as? [String: Any])?["raw"] as? [String: Any])?["language"]) ?? "text"
                let contentType: String
                switch language {
                case "json": contentType = "application/json"
                case "xml": contentType = "application/xml"
                case "html": contentType = "text/html"
                case "javascript": contentType = "application/javascript"
                default: contentType = "text/plain"
                }
                let raw = text(dict["raw"]) ?? ""
                if raw.isEmpty, language == "text" { return .none }
                return APIBody(kind: .raw, text: raw, contentType: contentType)
            case "urlencoded":
                return APIBody(kind: .urlencoded, fields: fields(dict["urlencoded"]))
            case "formdata":
                var body = APIBody(kind: .multipart)
                for entry in (dict["formdata"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
                    let key = text(entry["key"]) ?? ""
                    let enabled = !(entry["disabled"] as? Bool ?? false)
                    if text(entry["type"]) == "file" {
                        let sources = (entry["src"] as? [Any])?.compactMap { text($0) } ?? [text(entry["src"]) ?? ""]
                        for source in sources { body.files.append(APIFormFile(name: key, path: source, enabled: enabled)) }
                    } else {
                        var field = APIKeyValue(key, text(entry["value"]) ?? "", enabled: enabled)
                        field.note = text(entry["description"])
                        body.fields.append(field)
                    }
                }
                return body
            case "graphql":
                let graphql = dict["graphql"] as? [String: Any] ?? [:]
                var object: [String: Any] = ["query": text(graphql["query"]) ?? ""]
                if let variables = text(graphql["variables"]), !variables.isEmpty,
                   let parsed = try? JSONSerialization.jsonObject(with: Data(variables.utf8)) { object["variables"] = parsed }
                let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
                notes.append("\(requestName) had a GraphQL body; it was imported as JSON.")
                return .json(String(decoding: data, as: UTF8.self))
            case "file":
                notes.append("\(requestName) sends a whole file as its body, which Feather does not do yet; the body was left empty.")
                return .none
            default:
                return .none
            }
        }

        private func fields(_ value: Any?) -> [APIKeyValue] {
            (value as? [Any] ?? []).compactMap { entry in
                guard let dict = entry as? [String: Any], let key = text(dict["key"]) else { return nil }
                var field = APIKeyValue(key, text(dict["value"]) ?? "")
                field.enabled = !(dict["disabled"] as? Bool ?? false)
                field.note = text(dict["description"])
                return field
            }
        }

        private func variable(_ value: Any) -> APIVariable? {
            guard let dict = value as? [String: Any], let key = text(dict["key"]), !key.isEmpty else { return nil }
            var variable = APIVariable(key, text(dict["value"]) ?? "", secret: text(dict["type"]) == "secret")
            variable.enabled = !(dict["disabled"] as? Bool ?? false)
            return variable
        }

        /// The scripts on an item, by event name ("prerequest", "test"), empty ones left out.
        private func events(_ value: Any?) -> [String: String]? {
            guard let list = value as? [Any] else { return nil }
            var scripts: [String: String] = [:]
            for entry in list.compactMap({ $0 as? [String: Any] }) {
                guard let listen = text(entry["listen"]), let script = entry["script"] as? [String: Any] else { continue }
                let code: String
                if let lines = script["exec"] as? [Any] { code = lines.compactMap { text($0) }.joined(separator: "\n") }
                else { code = text(script["exec"]) ?? "" }
                if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                scripts[listen] = code
            }
            return scripts
        }
    }

    /// Postman's auth block as Feather's form; the second value names a type Feather has no form for.
    static func auth(_ value: Any?) -> (APIAuth, unsupported: String?) {
        guard let dict = value as? [String: Any], let type = text(dict["type"])?.lowercased() else { return (.inherit, nil) }
        // v2.1 keeps parameters as [{key, value}]; v2.0 as {key: value}. Both are read.
        func parameters(_ name: String) -> [String: String] {
            if let list = dict[name] as? [Any] {
                var result: [String: String] = [:]
                for entry in list.compactMap({ $0 as? [String: Any] }) {
                    if let key = text(entry["key"]) { result[key] = text(entry["value"]) ?? "" }
                }
                return result
            }
            if let object = dict[name] as? [String: Any] { return object.compactMapValues { text($0) } }
            return [:]
        }
        switch type {
        case "noauth": return (.none, nil)
        case "inherit": return (.inherit, nil)
        case "bearer": return (APIAuth(kind: .bearer, token: parameters("bearer")["token"] ?? ""), nil)
        case "basic":
            let basic = parameters("basic")
            return (APIAuth(kind: .basic, username: basic["username"] ?? "", password: basic["password"] ?? ""), nil)
        case "apikey":
            let apikey = parameters("apikey")
            return (APIAuth(kind: .apiKey, keyName: apikey["key"] ?? "", keyValue: apikey["value"] ?? "", keyIn: apikey["in"] == "query" ? .query : .header), nil)
        default: return (.inherit, type)
        }
    }

    static func readEnvironment(_ json: [String: Any]) -> APIEnvironment {
        var environment = APIEnvironment(name: text(json["name"]) ?? "Imported environment")
        if let id = text(json["id"]), !id.isEmpty { environment.id = id }
        environment.variables = (json["values"] as? [Any] ?? []).compactMap { entry in
            guard let dict = entry as? [String: Any], let key = text(dict["key"]), !key.isEmpty else { return nil }
            var variable = APIVariable(key, text(dict["value"]) ?? "", secret: text(dict["type"]) == "secret")
            variable.enabled = dict["enabled"] as? Bool ?? true
            return variable
        }
        return environment
    }

    /// A string, or a number or boolean shown as one; nil for anything else (Postman writes both).
    static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        case let dict as [String: Any]: return text(dict["content"])       // description: {content, type}
        default: return nil
        }
    }

    // MARK: Writing

    static func writeCollection(_ collection: APICollection) -> [String: Any] {
        var info: [String: Any] = ["name": collection.name, "schema": schema, "_postman_id": collection.id]
        var description = collection.description
        let secrets = collection.variables.filter(\.secret).map(\.name)
        if !secrets.isEmpty {
            description += (description.isEmpty ? "" : "\n\n") + secretsNote + " " + secrets.joined(separator: ", ") + "."
        }
        if !description.isEmpty { info["description"] = description }
        var json: [String: Any] = ["info": info, "item": collection.items.map(writeItem)]
        if !collection.variables.isEmpty {
            json["variable"] = collection.variables.map { variable -> [String: Any] in
                var entry: [String: Any] = ["key": variable.name, "value": variable.secret ? "" : variable.value, "type": variable.secret ? "secret" : "string"]
                if !variable.enabled { entry["disabled"] = true }
                return entry
            }
        }
        if let auth = writeAuth(collection.auth) { json["auth"] = auth }
        return json
    }

    private static func writeItem(_ item: APIItem) -> [String: Any] {
        switch item {
        case .folder(let folder):
            var json: [String: Any] = ["name": folder.name, "id": folder.id, "item": folder.items.map(writeItem)]
            if !folder.description.isEmpty { json["description"] = folder.description }
            if let auth = writeAuth(folder.auth) { json["auth"] = auth }
            return json
        case .request(let request):
            var spec: [String: Any] = ["method": request.method.rawValue, "url": writeURL(request)]
            spec["header"] = request.headers.map { header -> [String: Any] in
                var entry: [String: Any] = ["key": header.name, "value": header.value, "type": "text"]
                if !header.enabled { entry["disabled"] = true }
                if let note = header.note, !note.isEmpty { entry["description"] = note }
                return entry
            }
            if let body = writeBody(request.body) { spec["body"] = body }
            if let auth = writeAuth(request.auth) { spec["auth"] = auth }
            let description = APICheckLines.join(request.description, checks: request.checks, captures: request.captures)
            if !description.isEmpty { spec["description"] = description }
            var json: [String: Any] = ["name": request.name, "id": request.id, "request": spec, "response": [Any]()]
            if let scripts = request.importedScripts, !scripts.isEmpty {
                json["event"] = scripts.keys.sorted().map { listen -> [String: Any] in
                    ["listen": listen, "script": ["type": "text/javascript", "exec": scripts[listen]!.components(separatedBy: "\n")]]
                }
            }
            return json
        }
    }

    private static func writeURL(_ request: APIRequest) -> [String: Any] {
        var raw = request.url
        let enabled = request.params.filter { $0.enabled && !$0.name.isEmpty }
        if !enabled.isEmpty {
            raw += (raw.contains("?") ? "&" : "?") + enabled.map { $0.value.isEmpty ? $0.name : "\($0.name)=\($0.value)" }.joined(separator: "&")
        }
        var json: [String: Any] = ["raw": raw]
        var rest = request.url
        if let range = rest.range(of: "://") {
            json["protocol"] = String(rest[..<range.lowerBound])
            rest = String(rest[range.upperBound...])
        }
        if let questionMark = rest.firstIndex(of: "?") { rest = String(rest[..<questionMark]) }
        let hostAndPath = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if let host = hostAndPath.first, !host.isEmpty {
            // "{{baseUrl}}" is one host part; a real host splits on dots. A port stays with the host.
            if host.hasPrefix("{{") { json["host"] = [host] }
            else {
                let hostOnly = host.split(separator: ":", maxSplits: 1).map(String.init)
                json["host"] = hostOnly[0].split(separator: ".").map(String.init)
                if hostOnly.count > 1 { json["port"] = hostOnly[1] }
            }
        }
        if hostAndPath.count > 1 { json["path"] = hostAndPath[1].split(separator: "/", omittingEmptySubsequences: false).map(String.init) }
        if !request.params.isEmpty {
            json["query"] = request.params.map { param -> [String: Any] in
                var entry: [String: Any] = ["key": param.name, "value": param.value]
                if !param.enabled { entry["disabled"] = true }
                if let note = param.note, !note.isEmpty { entry["description"] = note }
                return entry
            }
        }
        return json
    }

    private static func writeBody(_ body: APIBody) -> [String: Any]? {
        func rows(_ fields: [APIKeyValue]) -> [[String: Any]] {
            fields.map { field in
                var entry: [String: Any] = ["key": field.name, "value": field.value, "type": "text"]
                if !field.enabled { entry["disabled"] = true }
                if let note = field.note, !note.isEmpty { entry["description"] = note }
                return entry
            }
        }
        switch body.kind {
        case .none: return nil
        case .raw:
            let type = body.contentType.lowercased()
            let language = type.contains("json") ? "json" : type.contains("xml") ? "xml" : type.contains("html") ? "html" : type.contains("javascript") ? "javascript" : "text"
            return ["mode": "raw", "raw": body.text, "options": ["raw": ["language": language]]]
        case .urlencoded, .form:
            return ["mode": "urlencoded", "urlencoded": rows(body.fields)]
        case .multipart:
            var entries = rows(body.fields)
            for file in body.files {
                var entry: [String: Any] = ["key": file.name, "type": "file", "src": file.path]
                if !file.enabled { entry["disabled"] = true }
                entries.append(entry)
            }
            return ["mode": "formdata", "formdata": entries]
        }
    }

    private static func writeAuth(_ auth: APIAuth) -> [String: Any]? {
        func row(_ key: String, _ value: String) -> [String: Any] { ["key": key, "value": value, "type": "string"] }
        switch auth.kind {
        case .inherit: return nil
        case .none: return ["type": "noauth"]
        case .bearer: return ["type": "bearer", "bearer": [row("token", auth.token)]]
        case .basic: return ["type": "basic", "basic": [row("username", auth.username), row("password", auth.password)]]
        case .apiKey: return ["type": "apikey", "apikey": [row("key", auth.keyName), row("value", auth.keyValue), row("in", auth.keyIn == .query ? "query" : "header")]]
        }
    }

    static func writeEnvironment(_ environment: APIEnvironment) -> [String: Any] {
        [
            "id": environment.id,
            "name": environment.name,
            "values": environment.variables.map { variable -> [String: Any] in
                ["key": variable.name, "value": variable.secret ? "" : variable.value, "enabled": variable.enabled, "type": variable.secret ? "secret" : "default"]
            },
            "_postman_variable_scope": "environment",
            "_postman_exported_at": ISO8601DateFormatter().string(from: Date()),
            "_postman_exported_using": "Feather",
        ]
    }
}

/// Checks and captures as lines of text, so they survive a trip through a format that has no place for them
/// (a Postman description, a comment in an .http file). "status equals 200", "json $.token exists",
/// "header Content-Type contains json", "set token from json $.token".
enum APICheckLines {
    static let checksHeading = "Feather checks (run by Feather when the request is sent):"
    static let capturesHeading = "Feather sets variables from the answer:"

    static func describe(_ check: APICheck) -> String {
        var words: [String] = []
        switch check.kind {
        case .status: words.append("status")
        case .time: words.append("time")
        case .bodyContains: words.append("body")
        case .header: words += ["header", check.target]
        case .jsonPath: words += ["json", check.target]
        }
        words.append(check.op.rawValue)
        if !check.expected.isEmpty { words.append(check.expected) }
        return words.joined(separator: " ")
    }

    static func describe(_ capture: APICapture) -> String {
        var line = "set \(capture.variable) from "
        switch capture.source {
        case .status: line += "status"
        case .header: line += "header " + capture.path
        case .jsonPath: line += "json " + capture.path
        }
        if capture.scope == .collection { line += " (collection)" }
        return line
    }

    static func parseCheck(_ line: String) -> APICheck? {
        var words = line.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = words.first else { return nil }
        words.removeFirst()
        let kind: APICheck.Kind
        var target = ""
        switch first {
        case "status": kind = .status
        case "time": kind = .time
        case "body": kind = .bodyContains
        case "header", "json":
            kind = first == "header" ? .header : .jsonPath
            guard !words.isEmpty else { return nil }
            target = words.removeFirst()
        default: return nil
        }
        guard !words.isEmpty, let op = APICheck.Operator(rawValue: words.removeFirst()) else { return nil }
        return APICheck(kind: kind, target: target, op: op, expected: words.joined(separator: " "))
    }

    static func parseCapture(_ line: String) -> APICapture? {
        var words = line.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 4, words[0] == "set", words[2] == "from" else { return nil }
        let variable = words[1]
        words.removeFirst(3)
        var scope = APICapture.Scope.environment
        if words.last == "(collection)" { scope = .collection; words.removeLast() }
        guard let source = words.first else { return nil }
        switch source {
        case "status": return APICapture(variable: variable, path: "", source: .status, scope: scope)
        case "header": return words.count > 1 ? APICapture(variable: variable, path: words[1], source: .header, scope: scope) : nil
        case "json": return words.count > 1 ? APICapture(variable: variable, path: words[1], source: .jsonPath, scope: scope) : nil
        default: return nil
        }
    }

    /// The description with the check and capture sections appended.
    static func join(_ description: String, checks: [APICheck], captures: [APICapture]) -> String {
        var parts: [String] = []
        if !description.isEmpty { parts.append(description) }
        if !checks.isEmpty { parts.append(([checksHeading] + checks.map { "- " + describe($0) }).joined(separator: "\n")) }
        if !captures.isEmpty { parts.append(([capturesHeading] + captures.map { "- " + describe($0) }).joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    /// The description without those sections, and what they held.
    static func split(_ description: String) -> (text: String, checks: [APICheck], captures: [APICapture]) {
        guard description.contains(checksHeading) || description.contains(capturesHeading) else { return (description, [], []) }
        var kept: [String] = []
        var checks: [APICheck] = []
        var captures: [APICapture] = []
        var section = 0
        for line in description.components(separatedBy: "\n") {
            if line == checksHeading { section = 1; continue }
            if line == capturesHeading { section = 2; continue }
            if section > 0, line.hasPrefix("- ") {
                let body = String(line.dropFirst(2))
                if section == 1, let check = parseCheck(body) { checks.append(check); continue }
                if section == 2, let capture = parseCapture(body) { captures.append(capture); continue }
            }
            if section > 0, line.trimmingCharacters(in: .whitespaces).isEmpty { section = 0; continue }
            if section == 0 { kept.append(line) }
        }
        return (kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), checks, captures)
    }
}
