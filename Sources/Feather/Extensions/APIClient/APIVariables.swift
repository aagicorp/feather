import Foundation

/// `{{name}}` in URLs, headers, bodies and variable values, resolved from the environment, the collection and
/// what recent answers captured, plus a few built-ins. Unknown names are left as they are, so the person can
/// see what is missing.
struct APIVariables {
    /// Later sources win: a captured value beats the environment, which beats the collection.
    private var values: [String: String] = [:]
    /// Names the person marked secret, so displays can mask them.
    private(set) var secretNames: Set<String> = []

    init(collection: [APIVariable] = [], environment: [APIVariable] = [], captured: [String: String] = [:], secrets: SecretStore? = nil,
         collectionID: String? = nil, environmentID: String? = nil) {
        for variable in collection where variable.enabled {
            values[variable.name] = variable.secret ? (secrets?.read(scope: collectionID ?? "", name: variable.name) ?? variable.value) : variable.value
            if variable.secret { secretNames.insert(variable.name) }
        }
        for variable in environment where variable.enabled {
            values[variable.name] = variable.secret ? (secrets?.read(scope: environmentID ?? "", name: variable.name) ?? variable.value) : variable.value
            if variable.secret { secretNames.insert(variable.name) }
        }
        for (name, value) in captured { values[name] = value }
    }

    var names: [String] { values.keys.sorted() }

    subscript(name: String) -> String? { values[name] }

    /// Every `{{name}}` replaced, built-ins included, up to a few levels deep (a value may itself use variables).
    func resolve(_ text: String) -> String {
        guard text.contains("{{") else { return text }
        var result = text
        for _ in 0..<4 {
            let before = result
            result = replaceOnce(result)
            if result == before || !result.contains("{{") { break }
        }
        return result
    }

    private static let pattern = try! NSRegularExpression(pattern: #"\{\{\s*([A-Za-z0-9_.$-]+)\s*\}\}"#)

    private func replaceOnce(_ text: String) -> String {
        let ns = text as NSString
        var result = ""
        var position = 0
        for match in APIVariables.pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: position, length: match.range.location - position))
            let name = ns.substring(with: match.range(at: 1))
            result += value(of: name) ?? ns.substring(with: match.range)
            position = NSMaxRange(match.range)
        }
        result += ns.substring(from: position)
        return result
    }

    private func value(of name: String) -> String? {
        if let known = values[name] { return known }
        switch name {
        case "$timestamp": return String(Int(Date().timeIntervalSince1970))
        case "$isoTimestamp": return ISO8601DateFormatter().string(from: Date())
        case "$uuid", "$guid": return UUID().uuidString.lowercased()
        case "$randomInt": return String(Int.random(in: 0...1000))
        default: return nil
        }
    }

    /// The names used in `text` that have no value.
    func unresolved(in text: String) -> [String] {
        let ns = text as NSString
        return APIVariables.pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
            .filter { value(of: $0) == nil }
    }
}

/// Where secret variable values live: the macOS Keychain in the app, memory in tests.
protocol SecretStore: AnyObject {
    func read(scope: String, name: String) -> String?
    func write(scope: String, name: String, value: String)
    func delete(scope: String, name: String)
}

final class MemorySecretStore: SecretStore {
    private var values: [String: String] = [:]
    func read(scope: String, name: String) -> String? { values[scope + "/" + name] }
    func write(scope: String, name: String, value: String) { values[scope + "/" + name] = value }
    func delete(scope: String, name: String) { values[scope + "/" + name] = nil }
}

/// One generic-password item per (scope, name) under Feather's own service name. Never prompts: items are
/// created by this app and readable by it alone.
final class KeychainSecretStore: SecretStore {
    private let service = "com.aagicorp.feather.api"

    private func query(_ scope: String, _ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: scope + "/" + name]
    }

    func read(scope: String, name: String) -> String? {
        var query = query(scope, name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(scope: String, name: String, value: String) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(scope, name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(scope, name)
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func delete(scope: String, name: String) {
        SecItemDelete(query(scope, name) as CFDictionary)
    }
}
