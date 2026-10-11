import Foundation

/// A small JSON path evaluator for checks and captures: `$.user.id`, `$.items[0].name`, `$.items[*].id`,
/// `$..id` (anywhere below), `$['a key']`, `$.items[?(@.id == 42)]`, `$.items.length`. Enough for reading an
/// answer; not the whole JSONPath language. Values come from `JSONSerialization`.
enum JSONPath {
    enum Step: Equatable {
        case key(String)
        case index(Int)
        case wildcard
        case recursive(String)
        case filter(key: String, op: String, value: String)
        case length
    }

    /// Nil when the path cannot be read.
    static func parse(_ path: String) -> [Step]? {
        var text = Substring(path.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("$") { text = text.dropFirst() }
        // "user.name" means "$.user.name".
        if let first = text.first, first != ".", first != "[" { text = "." + text }
        var steps: [Step] = []
        while !text.isEmpty {
            if text.hasPrefix("..") {
                text = text.dropFirst(2)
                let name = text.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
                guard !name.isEmpty else { return nil }
                text = text.dropFirst(name.count)
                steps.append(.recursive(String(name)))
            } else if text.hasPrefix(".") {
                text = text.dropFirst()
                let name = text.prefix { $0 != "." && $0 != "[" }
                guard !name.isEmpty else { return nil }
                text = text.dropFirst(name.count)
                steps.append(name == "length" ? .length : .key(String(name)))
            } else if text.hasPrefix("[") {
                guard let close = text.firstIndex(of: "]") else { return nil }
                let inside = text[text.index(after: text.startIndex)..<close].trimmingCharacters(in: .whitespaces)
                text = text[text.index(after: close)...]
                if inside == "*" {
                    steps.append(.wildcard)
                } else if let index = Int(inside) {
                    steps.append(.index(index))
                } else if inside.hasPrefix("'") || inside.hasPrefix("\"") {
                    steps.append(.key(String(inside.dropFirst().dropLast())))
                } else if inside.hasPrefix("?(") {
                    guard let filter = parseFilter(String(inside.dropFirst(2).dropLast())) else { return nil }
                    steps.append(filter)
                } else {
                    return nil
                }
            } else {
                return nil
            }
        }
        return steps
    }

    /// `@.id == 42`, `@.name != 'x'`, `@.done`.
    private static func parseFilter(_ text: String) -> Step? {
        var body = Substring(text.trimmingCharacters(in: .whitespaces))
        guard body.hasPrefix("@.") else { return nil }
        body = body.dropFirst(2)
        let key = body.prefix { $0 != " " && $0 != "=" && $0 != "!" && $0 != "<" && $0 != ">" }
        body = body.dropFirst(key.count).drop { $0 == " " }
        guard !key.isEmpty else { return nil }
        if body.isEmpty { return .filter(key: String(key), op: "exists", value: "") }
        let op = body.prefix { "=!<>".contains($0) }
        guard ["==", "!=", "<", ">", "<=", ">="].contains(op) else { return nil }
        body = body.dropFirst(op.count).drop { $0 == " " }
        var value = String(body)
        if (value.hasPrefix("'") && value.hasSuffix("'")) || (value.hasPrefix("\"") && value.hasSuffix("\"")) { value = String(value.dropFirst().dropLast()) }
        return .filter(key: String(key), op: String(op), value: value)
    }

    /// Every value the path reaches (a wildcard or filter can reach several; a plain path at most one).
    static func evaluate(_ path: String, in json: Any) -> [Any] {
        guard let steps = parse(path) else { return [] }
        return evaluate(steps, in: json)
    }

    static func evaluate(_ steps: [Step], in json: Any) -> [Any] {
        var current: [Any] = [json]
        for step in steps {
            var next: [Any] = []
            for value in current {
                switch step {
                case .key(let name):
                    if let object = value as? [String: Any], let found = object[name] { next.append(found) }
                case .index(let index):
                    if let array = value as? [Any] {
                        let real = index < 0 ? array.count + index : index
                        if array.indices.contains(real) { next.append(array[real]) }
                    }
                case .wildcard:
                    if let array = value as? [Any] { next += array }
                    else if let object = value as? [String: Any] { next += object.keys.sorted().compactMap { object[$0] } }
                case .recursive(let name):
                    next += descend(value, name: name)
                case .filter(let key, let op, let expected):
                    guard let array = value as? [Any] else { continue }
                    next += array.filter { element in
                        guard let object = element as? [String: Any] else { return false }
                        guard let field = object[key], !(field is NSNull) else { return op == "!=" }
                        return compare(field, op, expected)
                    }
                case .length:
                    if let array = value as? [Any] { next.append(array.count) }
                    else if let string = value as? String { next.append(string.count) }
                    else if let object = value as? [String: Any] { next.append(object.count) }
                }
            }
            current = next
            if current.isEmpty { break }
        }
        return current
    }

    /// The first value as text, the way a check compares it and a capture stores it.
    static func firstText(_ path: String, in json: Any) -> String? {
        evaluate(path, in: json).first.map(text)
    }

    /// Scalars as they would appear in JSON; containers as compact JSON.
    static func text(_ value: Any) -> String {
        switch value {
        case let string as String: return string
        case let number as NSNumber:
            if number === kCFBooleanTrue { return "true" }
            if number === kCFBooleanFalse { return "false" }
            return number.stringValue
        case is NSNull: return "null"
        default:
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) {
                return String(decoding: data, as: UTF8.self)
            }
            return String(describing: value)
        }
    }

    private static func descend(_ value: Any, name: String) -> [Any] {
        var found: [Any] = []
        if let object = value as? [String: Any] {
            if let direct = object[name] { found.append(direct) }
            for key in object.keys.sorted() { found += descend(object[key] as Any, name: name) }
        } else if let array = value as? [Any] {
            for element in array { found += descend(element, name: name) }
        }
        return found
    }

    private static func compare(_ field: Any, _ op: String, _ expected: String) -> Bool {
        if op == "exists" { return true }
        let actual = text(field)
        if let a = Double(actual), let b = Double(expected) {
            switch op {
            case "==": return a == b
            case "!=": return a != b
            case "<": return a < b
            case ">": return a > b
            case "<=": return a <= b
            case ">=": return a >= b
            default: return false
            }
        }
        switch op {
        case "==": return actual == expected
        case "!=": return actual != expected
        default: return false
        }
    }
}
