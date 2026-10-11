import Foundation

/// An OpenAPI 3.0/3.1 description as a collection: one request per path and operation, a folder per first
/// tag, `{{baseUrl}}` in front of every path, path parameters as `{{name}}`, query and header parameters
/// filled from their examples, and a JSON body made from the request body's example or its schema. The
/// servers become environments, so switching between staging and production is one pick.
enum OpenAPIImport {
    static func isOpenAPI(_ json: [String: Any]) -> Bool { json["openapi"] != nil || json["swagger"] != nil }

    static func read(_ spec: [String: Any]) throws -> APIImportExport.Imported {
        if spec["openapi"] == nil, let swagger = spec["swagger"] {
            throw APIImportExport.ImportError(message: "This is a Swagger \(swagger) file. Feather reads OpenAPI 3; convert it first (most API tools can export OpenAPI 3).")
        }
        var reader = Reader(spec: spec)
        return reader.read()
    }

    private struct Reader {
        let spec: [String: Any]
        var notes: [String] = []
        var pathVariables: [APIVariable] = []
        var authVariables: [APIVariable] = []
        private let methodOrder: [APIMethod] = [.get, .post, .put, .patch, .delete, .head, .options]

        init(spec: [String: Any]) { self.spec = spec }

        mutating func read() -> APIImportExport.Imported {
            let info = spec["info"] as? [String: Any] ?? [:]
            var collection = APICollection(name: string(info["title"]) ?? "Imported API")
            collection.description = string(info["description"]) ?? ""
            var imported = APIImportExport.Imported()

            // Servers → environments, and the first one as the collection's own baseUrl.
            let servers = (spec["servers"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            var baseUrls: [String] = []
            for server in servers {
                guard var url = string(server["url"]), !url.isEmpty else { continue }
                for (name, definition) in server["variables"] as? [String: Any] ?? [:] {
                    if let fallback = string((definition as? [String: Any])?["default"]) { url = url.replacingOccurrences(of: "{\(name)}", with: fallback) }
                }
                if url.hasSuffix("/") { url.removeLast() }
                baseUrls.append(url)
                var name = url
                if let range = name.range(of: "://") { name = String(name[range.upperBound...]) }
                imported.environments.append(APIEnvironment(name: name, variables: [APIVariable("baseUrl", url)]))
            }
            if let first = baseUrls.first {
                collection.variables.append(APIVariable("baseUrl", first))
                if first.hasPrefix("/") { notes.append("The server address (\(first)) has no host; set baseUrl in the collection's variables.") }
            } else {
                collection.variables.append(APIVariable("baseUrl", "http://localhost"))
                notes.append("The file names no server, so baseUrl is set to http://localhost. Change it in the collection's variables.")
            }

            // Sign-in: the scheme the whole API asks for becomes the collection's auth.
            let schemes = (spec["components"] as? [String: Any])?["securitySchemes"] as? [String: Any] ?? [:]
            if let name = firstScheme(in: spec["security"]) ?? schemes.keys.sorted().first, let scheme = schemes[name] as? [String: Any] {
                collection.auth = auth(for: scheme, named: name)
            }

            // Folders per first tag, in the order the file lists tags, then as they appear.
            var folders: [(name: String, folder: APIFolder)] = []
            for tag in (spec["tags"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
                guard let name = string(tag["name"]) else { continue }
                var folder = APIFolder(name: name)
                folder.description = string(tag["description"]) ?? ""
                folders.append((name, folder))
            }
            var untagged: [APIItem] = []
            let paths = spec["paths"] as? [String: Any] ?? [:]
            for path in paths.keys.sorted() {
                guard let item = resolved(paths[path]) else { continue }
                let shared = (item["parameters"] as? [Any] ?? []).compactMap { resolved($0) }
                for method in methodOrder {
                    guard let operation = resolved(item[method.rawValue.lowercased()]) else { continue }
                    let request = self.request(method: method, path: path, operation: operation, shared: shared, collectionAuth: collection.auth, schemes: schemes)
                    if let tag = (operation["tags"] as? [Any])?.compactMap({ string($0) }).first {
                        if let index = folders.firstIndex(where: { $0.name == tag }) { folders[index].folder.items.append(.request(request)) }
                        else { folders.append((tag, APIFolder(name: tag, items: [.request(request)]))) }
                    } else {
                        untagged.append(.request(request))
                    }
                }
            }
            collection.items = folders.filter { !$0.folder.items.isEmpty }.map { .folder($0.folder) } + untagged
            for variable in pathVariables + authVariables where !collection.variables.contains(where: { $0.name == variable.name }) {
                collection.variables.append(variable)
            }
            if !pathVariables.isEmpty {
                notes.append("Path parameters became collection variables (\(pathVariables.map(\.name).joined(separator: ", "))); fill them in before sending.")
            }
            if collection.allRequests.isEmpty { notes.append("The file describes no operations, so the collection is empty.") }
            imported.collections = [collection]
            var seen: Set<String> = []
            imported.notes = notes.filter { seen.insert($0).inserted }
            return imported
        }

        // MARK: Operations

        private mutating func request(method: APIMethod, path: String, operation: [String: Any], shared: [[String: Any]],
                                      collectionAuth: APIAuth, schemes: [String: Any]) -> APIRequest {
            let name = string(operation["summary"]) ?? string(operation["operationId"]) ?? "\(method.rawValue) \(path)"
            var request = APIRequest(name: name, method: method, url: "{{baseUrl}}" + path.replacingOccurrences(of: #"\{([^{}]+)\}"#, with: "{{$1}}", options: .regularExpression))
            var description = string(operation["description"]) ?? ""
            if operation["deprecated"] as? Bool == true { description = "Deprecated." + (description.isEmpty ? "" : " " + description) }
            request.description = description

            // Parameters: the operation's own override the path's, by name and place.
            var parameters = shared
            for own in (operation["parameters"] as? [Any] ?? []).compactMap({ resolved($0) }) {
                parameters.removeAll { string($0["name"]) == string(own["name"]) && string($0["in"]) == string(own["in"]) }
                parameters.append(own)
            }
            for parameter in parameters {
                guard let parameterName = string(parameter["name"]) else { continue }
                let required = parameter["required"] as? Bool ?? false
                let value = parameterValue(parameter)
                switch string(parameter["in"]) {
                case "query":
                    var param = APIKeyValue(parameterName, value, enabled: required)
                    param.note = string(parameter["description"])
                    request.params.append(param)
                case "header":
                    var header = APIKeyValue(parameterName, value, enabled: required)
                    header.note = string(parameter["description"])
                    request.headers.append(header)
                case "path":
                    if !pathVariables.contains(where: { $0.name == parameterName }) { pathVariables.append(APIVariable(parameterName, value)) }
                default: break
                }
            }

            if let body = resolved(operation["requestBody"]) { fill(&request, body: body, requestName: name) }

            // The first success code the file documents is what the request is checked against.
            if let responses = operation["responses"] as? [String: Any] {
                let successes = responses.keys.compactMap { Int($0) }.filter { (200..<300).contains($0) }.sorted()
                if let code = successes.first { request.checks = [.status(code)] }
            }

            // Sign-in on the operation, when it differs from the collection's.
            if let security = operation["security"] as? [Any] {
                if security.isEmpty {
                    request.auth = .none
                } else if let schemeName = firstScheme(in: security), let scheme = schemes[schemeName] as? [String: Any] {
                    let own = auth(for: scheme, named: schemeName)
                    if own != collectionAuth { request.auth = own }
                }
            }
            return request
        }

        private func parameterValue(_ parameter: [String: Any]) -> String {
            if let example = parameter["example"] { return text(example) }
            if let examples = parameter["examples"] as? [String: Any], let first = examples.keys.sorted().first,
               let value = (examples[first] as? [String: Any])?["value"] { return text(value) }
            guard let schema = resolved(parameter["schema"]) else { return "" }
            if let example = schema["example"] { return text(example) }
            if let fallback = schema["default"] { return text(fallback) }
            if let options = schema["enum"] as? [Any], let first = options.first { return text(first) }
            return ""
        }

        private mutating func fill(_ request: inout APIRequest, body: [String: Any], requestName: String) {
            guard let content = body["content"] as? [String: Any], !content.isEmpty else { return }
            let types = content.keys.sorted()
            let chosen = types.first { $0.contains("json") } ?? types.first { $0.hasPrefix("application/x-www-form-urlencoded") }
                ?? types.first { $0.hasPrefix("multipart/") } ?? types[0]
            let media = content[chosen] as? [String: Any] ?? [:]
            let schema = resolved(media["schema"]) ?? [:]
            if chosen == "application/octet-stream" || string(schema["format"]) == "binary" {
                notes.append("\(requestName) sends a whole file as its body, which Feather does not do yet; the body was left empty.")
                return
            }
            var example: Any? = media["example"]
            if example == nil, let examples = media["examples"] as? [String: Any], let first = examples.keys.sorted().first {
                example = (examples[first] as? [String: Any])?["value"]
            }
            if example == nil, !schema.isEmpty { example = self.example(for: schema, depth: 0) }

            if chosen.hasPrefix("application/x-www-form-urlencoded") || chosen.hasPrefix("multipart/") {
                var apiBody = APIBody(kind: chosen.hasPrefix("multipart/") ? .multipart : .urlencoded)
                let fields = example as? [String: Any] ?? [:]
                let properties = schema["properties"] as? [String: Any] ?? [:]
                for key in Set(fields.keys).union(properties.keys).sorted() {
                    let property = resolved(properties[key]) ?? [:]
                    if apiBody.kind == .multipart, string(property["format"]) == "binary" || string(property["format"]) == "base64" {
                        apiBody.files.append(APIFormFile(name: key, path: ""))
                        notes.append("\(requestName) uploads a file as \"\(key)\"; choose the file in the request.")
                    } else {
                        apiBody.fields.append(APIKeyValue(key, fields[key].map(text) ?? ""))
                    }
                }
                request.body = apiBody
                return
            }
            if chosen.contains("json") || !(example is String) {
                guard let example, JSONSerialization.isValidJSONObject(example) || example is String || example is NSNumber || example is NSNull else {
                    request.body = APIBody(kind: .raw, text: "", contentType: chosen)
                    return
                }
                let data = (try? JSONSerialization.data(withJSONObject: example, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])) ?? Data()
                request.body = APIBody(kind: .raw, text: String(decoding: data, as: UTF8.self), contentType: chosen.contains("json") ? "application/json" : chosen)
            } else {
                request.body = APIBody(kind: .raw, text: example as? String ?? "", contentType: chosen)
            }
        }

        // MARK: Schemas

        /// A value shaped like the schema: examples and defaults where given, else "string", 0, false, and
        /// objects and arrays built from their parts.
        private func example(for schema: [String: Any], depth: Int) -> Any {
            guard depth < 8 else { return NSNull() }
            if let example = schema["example"] { return example }
            if let examples = schema["examples"] as? [Any], let first = examples.first { return first }
            if let fallback = schema["default"] { return fallback }
            if let options = schema["enum"] as? [Any], let first = options.first { return first }
            if let all = schema["allOf"] as? [Any] {
                var merged: [String: Any] = [:]
                for part in all.compactMap({ resolved($0) }) {
                    if let object = example(for: part, depth: depth + 1) as? [String: Any] { merged.merge(object) { _, new in new } }
                }
                return merged
            }
            if let options = (schema["oneOf"] ?? schema["anyOf"]) as? [Any], let first = options.compactMap({ resolved($0) }).first {
                return example(for: first, depth: depth + 1)
            }
            var type = string(schema["type"])
            if type == nil, let types = schema["type"] as? [Any] { type = types.compactMap { string($0) }.first { $0 != "null" } }
            if type == nil { type = schema["properties"] != nil ? "object" : schema["items"] != nil ? "array" : "string" }
            switch type {
            case "object":
                var object: [String: Any] = [:]
                for (key, value) in schema["properties"] as? [String: Any] ?? [:] {
                    guard let property = resolved(value) else { continue }
                    if property["readOnly"] as? Bool == true { continue }
                    object[key] = example(for: property, depth: depth + 1)
                }
                return object
            case "array":
                guard let items = resolved(schema["items"]) else { return [Any]() }
                return [example(for: items, depth: depth + 1)]
            case "integer", "number": return 0
            case "boolean": return false
            case "null": return NSNull()
            default:
                switch string(schema["format"]) {
                case "date": return "2024-01-01"
                case "date-time": return "2024-01-01T00:00:00Z"
                case "email": return "user@example.com"
                case "uuid": return "00000000-0000-0000-0000-000000000000"
                case "uri", "url": return "https://example.com"
                default: return "string"
                }
            }
        }

        /// The object itself, or the one a `$ref` points to inside this file.
        private func resolved(_ value: Any?) -> [String: Any]? {
            guard var object = value as? [String: Any] else { return nil }
            var hops = 0
            while let reference = string(object["$ref"]), hops < 8 {
                hops += 1
                guard reference.hasPrefix("#/") else { return object }
                var current: Any? = spec
                for part in reference.dropFirst(2).split(separator: "/") {
                    let key = part.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                    current = (current as? [String: Any])?[key]
                }
                guard let target = current as? [String: Any] else { return nil }
                object = target
            }
            return object
        }

        // MARK: Sign-in

        private func firstScheme(in security: Any?) -> String? {
            for requirement in (security as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
                if let name = requirement.keys.sorted().first { return name }
            }
            return nil
        }

        private mutating func auth(for scheme: [String: Any], named name: String) -> APIAuth {
            switch string(scheme["type"]) {
            case "http":
                if string(scheme["scheme"])?.lowercased() == "basic" {
                    add(APIVariable("username", ""))
                    add(APIVariable("password", "", secret: true))
                    return APIAuth(kind: .basic, username: "{{username}}", password: "{{password}}")
                }
                add(APIVariable("token", "", secret: true))
                return APIAuth(kind: .bearer, token: "{{token}}")
            case "apiKey":
                add(APIVariable("apiKey", "", secret: true))
                let place = string(scheme["in"])
                if place == "cookie" { notes.append("The API key \"\(name)\" goes in a cookie, which Feather sends as a header; check it works.") }
                return APIAuth(kind: .apiKey, keyName: string(scheme["name"]) ?? "X-API-Key", keyValue: "{{apiKey}}", keyIn: place == "query" ? .query : .header)
            case "oauth2", "openIdConnect":
                add(APIVariable("token", "", secret: true))
                notes.append("The API uses OAuth (\(name)); paste a token into the token variable.")
                return APIAuth(kind: .bearer, token: "{{token}}")
            default:
                return .none
            }
        }

        private mutating func add(_ variable: APIVariable) {
            if !authVariables.contains(where: { $0.name == variable.name }) { authVariables.append(variable) }
        }

        // MARK: Values

        private func string(_ value: Any?) -> String? {
            if let text = value as? String { return text }
            return nil
        }

        /// Any scalar or JSON value as text for a field.
        private func text(_ value: Any) -> String {
            switch value {
            case let text as String: return text
            case let number as NSNumber:
                if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
                return number.stringValue
            case is NSNull: return ""
            default:
                let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])) ?? Data()
                return String(decoding: data, as: UTF8.self)
            }
        }
    }
}
