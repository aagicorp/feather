import Foundation

// The data of the API client: what is saved as JSON (collections, environments, history) and what a sent request
// gives back. Everything saved is `Codable` with stable ids and a format number, so files diff well in git and
// an older Feather can ignore keys it does not know.

/// The number in every saved file. Readers accept anything up to their own.
let apiFileFormat = 1

/// Missing keys take the property's default, so a file written by hand or by another version still loads.
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

enum APIMethod: String, Codable, CaseIterable {
    case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE", head = "HEAD", options = "OPTIONS"

    /// Whether a body is normally sent with it (a request may still carry one).
    var usuallyHasBody: Bool { self == .post || self == .put || self == .patch }
}

/// A name/value row in Params, Headers or a form, which can be switched off without being deleted.
struct APIKeyValue: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var value: String
    var enabled = true
    /// Shown greyed under the row in the editor.
    var note: String? = nil

    init(_ name: String, _ value: String, enabled: Bool = true) {
        self.name = name
        self.value = value
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case value
        case enabled
        case note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: UUID().uuidString)
        name = c.value(.name, or: "")
        value = c.value(.value, or: "")
        enabled = c.value(.enabled, or: true)
        note = c.value(.note, or: nil)
    }

}

struct APIFormFile: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    /// Relative to the project when inside it, else absolute; resolved when sending.
    var path: String
    var enabled = true

    init(name: String, path: String, enabled: Bool = true) {
        self.name = name
        self.path = path
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
        case enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: UUID().uuidString)
        name = c.value(.name, or: "")
        path = c.value(.path, or: "")
        enabled = c.value(.enabled, or: true)
    }

}

struct APIBody: Codable, Equatable {
    enum Kind: String, Codable { case none, raw, form, urlencoded, multipart }
    var kind: Kind = .none
    /// The raw text, for `.raw`.
    var text = ""
    /// The Content-Type sent with a raw body ("application/json" by default).
    var contentType = "application/json"
    /// Fields for form, urlencoded and multipart bodies.
    var fields: [APIKeyValue] = []
    var files: [APIFormFile] = []

    init(kind: Kind = .none, text: String = "", contentType: String = "application/json", fields: [APIKeyValue] = [], files: [APIFormFile] = []) {
        self.kind = kind
        self.text = text
        self.contentType = contentType
        self.fields = fields
        self.files = files
    }

    static let none = APIBody()
    static func json(_ text: String) -> APIBody { APIBody(kind: .raw, text: text, contentType: "application/json") }

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case contentType
        case fields
        case files
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.value(.kind, or: .none)
        text = c.value(.text, or: "")
        contentType = c.value(.contentType, or: "application/json")
        fields = c.value(.fields, or: [])
        files = c.value(.files, or: [])
    }

}

struct APIAuth: Codable, Equatable {
    enum Kind: String, Codable { case inherit, none, bearer, basic, apiKey }
    enum Place: String, Codable { case header, query }
    var kind: Kind = .inherit
    var token = ""
    var username = ""
    var password = ""
    var keyName = ""
    var keyValue = ""
    var keyIn: Place = .header

    init(kind: Kind = .inherit, token: String = "", username: String = "", password: String = "", keyName: String = "", keyValue: String = "", keyIn: Place = .header) {
        self.kind = kind
        self.token = token
        self.username = username
        self.password = password
        self.keyName = keyName
        self.keyValue = keyValue
        self.keyIn = keyIn
    }

    static let inherit = APIAuth()
    static let none = APIAuth(kind: .none)

    private enum CodingKeys: String, CodingKey {
        case kind
        case token
        case username
        case password
        case keyName
        case keyValue
        case keyIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.value(.kind, or: .inherit)
        token = c.value(.token, or: "")
        username = c.value(.username, or: "")
        password = c.value(.password, or: "")
        keyName = c.value(.keyName, or: "")
        keyValue = c.value(.keyValue, or: "")
        keyIn = c.value(.keyIn, or: .header)
    }

}

/// One thing to check about the answer: a form, no scripting.
struct APICheck: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case status, jsonPath, header, bodyContains, time
    }
    enum Operator: String, Codable, CaseIterable {
        case equals, notEquals, contains, notContains, exists, notExists, lessThan, greaterThan, matches
    }
    var id = UUID().uuidString
    var kind: Kind
    /// The header name or JSON path; unused for status, bodyContains and time.
    var target = ""
    var op: Operator
    var expected = ""
    var enabled = true

    init(kind: Kind, target: String = "", op: Operator, expected: String = "") {
        self.kind = kind
        self.target = target
        self.op = op
        self.expected = expected
    }

    static func status(_ code: Int) -> APICheck { APICheck(kind: .status, op: .equals, expected: String(code)) }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case target
        case op
        case expected
        case enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: UUID().uuidString)
        kind = c.value(.kind, or: .status)
        target = c.value(.target, or: "")
        op = c.value(.op, or: .equals)
        expected = c.value(.expected, or: "")
        enabled = c.value(.enabled, or: true)
    }

}

/// A value taken from the answer into a variable ("$.token" → token), which is how a login is followed by
/// authenticated requests without scripts.
struct APICapture: Codable, Equatable, Identifiable {
    enum Scope: String, Codable { case environment, collection }
    enum Source: String, Codable { case jsonPath, header, status }
    var id = UUID().uuidString
    var variable: String
    var source: Source = .jsonPath
    var path: String
    var scope: Scope = .environment
    var enabled = true

    init(variable: String, path: String, source: Source = .jsonPath, scope: Scope = .environment) {
        self.variable = variable
        self.path = path
        self.source = source
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case variable
        case source
        case path
        case scope
        case enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: UUID().uuidString)
        variable = c.value(.variable, or: "")
        source = c.value(.source, or: .jsonPath)
        path = c.value(.path, or: "")
        scope = c.value(.scope, or: .environment)
        enabled = c.value(.enabled, or: true)
    }

}

struct APIRequest: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var method: APIMethod = .get
    var url = ""
    var params: [APIKeyValue] = []
    var headers: [APIKeyValue] = []
    var body: APIBody = .none
    var auth: APIAuth = .inherit
    var checks: [APICheck] = []
    var captures: [APICapture] = []
    var description = ""
    /// Text kept from an import (a Postman script) so nothing is lost; not run.
    var importedScripts: [String: String]? = nil

    init(name: String, method: APIMethod = .get, url: String = "") {
        self.name = name
        self.method = method
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case method
        case url
        case params
        case headers
        case body
        case auth
        case checks
        case captures
        case description
        case importedScripts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: UUID().uuidString)
        name = c.value(.name, or: "Untitled")
        method = c.value(.method, or: .get)
        url = c.value(.url, or: "")
        params = c.value(.params, or: [])
        headers = c.value(.headers, or: [])
        body = c.value(.body, or: .none)
        auth = c.value(.auth, or: .inherit)
        checks = c.value(.checks, or: [])
        captures = c.value(.captures, or: [])
        description = c.value(.description, or: "")
        importedScripts = c.value(.importedScripts, or: nil)
    }

}

struct APIFolder: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var items: [APIItem] = []
    var auth: APIAuth = .inherit
    var description = ""

    init(name: String, items: [APIItem] = []) {
        self.name = name
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case items
        case auth
        case description
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: UUID().uuidString)
        name = c.value(.name, or: "Folder")
        items = c.value(.items, or: [])
        auth = c.value(.auth, or: .inherit)
        description = c.value(.description, or: "")
    }

}

/// A request or a folder, in a collection's tree. Encoded with a "kind" key.
indirect enum APIItem: Codable, Equatable, Identifiable {
    case request(APIRequest)
    case folder(APIFolder)

    var id: String {
        switch self {
        case .request(let request): return request.id
        case .folder(let folder): return folder.id
        }
    }
    var name: String {
        switch self {
        case .request(let request): return request.name
        case .folder(let folder): return folder.name
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, request, folder }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "folder": self = .folder(try container.decode(APIFolder.self, forKey: .folder))
        default: self = .request(try container.decode(APIRequest.self, forKey: .request))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .request(let request):
            try container.encode("request", forKey: .kind)
            try container.encode(request, forKey: .request)
        case .folder(let folder):
            try container.encode("folder", forKey: .kind)
            try container.encode(folder, forKey: .folder)
        }
    }
}

/// A variable of a collection or an environment. A secret's value never reaches a file: it lives in the
/// Keychain under the variable's name, and `value` is written empty.
struct APIVariable: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var value: String
    var secret = false
    var enabled = true

    init(_ name: String, _ value: String, secret: Bool = false) {
        self.name = name
        self.value = value
        self.secret = secret
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case value
        case secret
        case enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: UUID().uuidString)
        name = c.value(.name, or: "")
        value = c.value(.value, or: "")
        secret = c.value(.secret, or: false)
        enabled = c.value(.enabled, or: true)
    }

}

/// Where a collection or environment is kept: in the project (shared through git) or with the person.
enum APIStorageLocation: String, Codable { case project, personal }

struct APICollection: Codable, Equatable, Identifiable {
    var format = apiFileFormat
    var id = UUID().uuidString
    var name: String
    var items: [APIItem] = []
    var variables: [APIVariable] = []
    var auth: APIAuth = .none
    var description = ""

    init(name: String, items: [APIItem] = []) {
        self.name = name
        self.items = items
    }

    /// Every request in the tree, depth first, with the folders above it.
    var allRequests: [(request: APIRequest, path: [APIFolder])] {
        var result: [(APIRequest, [APIFolder])] = []
        func walk(_ items: [APIItem], _ path: [APIFolder]) {
            for item in items {
                switch item {
                case .request(let request): result.append((request, path))
                case .folder(let folder): walk(folder.items, path + [folder])
                }
            }
        }
        walk(items, [])
        return result
    }

    func request(id: String) -> APIRequest? { allRequests.first { $0.request.id == id }?.request }

    /// Replaces the request with the same id wherever it is; false when it is not in this collection.
    @discardableResult
    mutating func update(_ request: APIRequest) -> Bool {
        func replace(in items: inout [APIItem]) -> Bool {
            for index in items.indices {
                switch items[index] {
                case .request(let existing) where existing.id == request.id:
                    items[index] = .request(request)
                    return true
                case .folder(var folder):
                    if replace(in: &folder.items) { items[index] = .folder(folder); return true }
                default: break
                }
            }
            return false
        }
        return replace(in: &items)
    }

    /// Removes the item with that id, wherever it is.
    @discardableResult
    mutating func remove(id: String) -> Bool {
        func remove(from items: inout [APIItem]) -> Bool {
            if let index = items.firstIndex(where: { $0.id == id }) { items.remove(at: index); return true }
            for index in items.indices {
                if case .folder(var folder) = items[index], remove(from: &folder.items) {
                    items[index] = .folder(folder)
                    return true
                }
            }
            return false
        }
        return remove(from: &items)
    }

    /// Adds an item at the end of the folder with `folderID`, or at the top level when nil.
    @discardableResult
    mutating func insert(_ item: APIItem, into folderID: String?) -> Bool {
        guard let folderID else { items.append(item); return true }
        func insert(into items: inout [APIItem]) -> Bool {
            for index in items.indices {
                if case .folder(var folder) = items[index] {
                    if folder.id == folderID { folder.items.append(item); items[index] = .folder(folder); return true }
                    if insert(into: &folder.items) { items[index] = .folder(folder); return true }
                }
            }
            return false
        }
        return insert(into: &items)
    }

    private enum CodingKeys: String, CodingKey {
        case format
        case id
        case name
        case items
        case variables
        case auth
        case description
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = c.value(.format, or: apiFileFormat)
        id = c.value(.id, or: UUID().uuidString)
        name = c.value(.name, or: "Collection")
        items = c.value(.items, or: [])
        variables = c.value(.variables, or: [])
        auth = c.value(.auth, or: .none)
        description = c.value(.description, or: "")
    }

}

struct APIEnvironment: Codable, Equatable, Identifiable {
    var format = apiFileFormat
    var id = UUID().uuidString
    var name: String
    var variables: [APIVariable] = []
    /// Seconds before a request is given up on.
    var timeout: Double = 30
    var followsRedirects = true
    var verifiesCertificates = true

    init(name: String, variables: [APIVariable] = []) {
        self.name = name
        self.variables = variables
    }

    private enum CodingKeys: String, CodingKey {
        case format
        case id
        case name
        case variables
        case timeout
        case followsRedirects
        case verifiesCertificates
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = c.value(.format, or: apiFileFormat)
        id = c.value(.id, or: UUID().uuidString)
        name = c.value(.name, or: "Environment")
        variables = c.value(.variables, or: [])
        timeout = c.value(.timeout, or: 30)
        followsRedirects = c.value(.followsRedirects, or: true)
        verifiesCertificates = c.value(.verifiesCertificates, or: true)
    }

}

/// What came back. Not saved as a whole; the history keeps a summary.
struct APIResponse {
    var status: Int
    var statusText: String
    var headers: [(name: String, value: String)]
    /// The whole body when it fits in memory (up to `APIRequestSender.maxBodyInMemory`), else empty.
    var body: Data
    /// The body on disk when it was too large to keep; the caller removes it when done.
    var bodyFile: URL?
    var duration: TimeInterval
    var size: Int
    var url: URL?
    /// What the server set, kept or not (APICookies.swift).
    var cookies: [APICookie]

    func header(_ name: String) -> String? { headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
    var contentType: String { header("Content-Type") ?? "" }
    var isJSON: Bool { contentType.contains("json") }
    var text: String { String(decoding: body, as: UTF8.self) }
    /// The body parsed as JSON, or nil.
    var json: Any? { body.isEmpty ? nil : try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) }
    var isSuccess: Bool { (200..<300).contains(status) }
}

struct APIHistoryEntry: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var date: Date
    var method: APIMethod
    var url: String
    var status: Int?
    var duration: TimeInterval
    var size: Int
    var requestID: String?
    var collectionID: String?
    var error: String?

    init(date: Date, method: APIMethod, url: String, status: Int?, duration: TimeInterval, size: Int,
         requestID: String? = nil, collectionID: String? = nil, error: String? = nil) {
        self.date = date
        self.method = method
        self.url = url
        self.status = status
        self.duration = duration
        self.size = size
        self.requestID = requestID
        self.collectionID = collectionID
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case date
        case method
        case url
        case status
        case duration
        case size
        case requestID
        case collectionID
        case error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: UUID().uuidString)
        date = c.value(.date, or: Date())
        method = c.value(.method, or: .get)
        url = c.value(.url, or: "")
        status = c.value(.status, or: nil)
        duration = c.value(.duration, or: 0)
        size = c.value(.size, or: 0)
        requestID = c.value(.requestID, or: nil)
        collectionID = c.value(.collectionID, or: nil)
        error = c.value(.error, or: nil)
    }

}

/// A request as it was actually sent, with variables resolved and auth applied; what Copy as cURL shows.
struct APIResolvedRequest: Equatable {
    var method: APIMethod
    var url: URL
    var headers: [(name: String, value: String)]
    var body: Data?
    var bodyDescription: String?

    static func == (lhs: APIResolvedRequest, rhs: APIResolvedRequest) -> Bool {
        lhs.method == rhs.method && lhs.url == rhs.url && lhs.body == rhs.body
            && lhs.headers.map { "\($0.name):\($0.value)" } == rhs.headers.map { "\($0.name):\($0.value)" }
    }

    /// A shell-safe `curl` command line for this request.
    var curl: String {
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var parts = ["curl"]
        if method != .get { parts.append("-X " + method.rawValue) }
        for header in headers { parts.append("-H " + quote("\(header.name): \(header.value)")) }
        if let body, !body.isEmpty {
            if let text = String(data: body, encoding: .utf8) { parts.append("--data-raw " + quote(text)) }
            else { parts.append("--data-binary @body.bin") }
        }
        parts.append(quote(url.absoluteString))
        return parts.joined(separator: " \\\n  ")
    }
}

// MARK: - JSON coding shared by the files

enum APIJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
