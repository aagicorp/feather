import Foundation

/// Runs a request's checks against its answer and takes the captured values out of it. No scripts: every check
/// is a form the person filled in, so the result can always say what was compared with what.
enum APIChecks {
    struct Result: Equatable {
        let check: APICheck
        let passed: Bool
        /// What the answer actually had, for the results table.
        let actual: String
        /// One line, e.g. "status 404 is not 200".
        let message: String
    }

    static func evaluate(_ checks: [APICheck], response: APIResponse) -> [Result] {
        let json = response.json
        return checks.filter(\.enabled).map { check in
            let actual: String?
            switch check.kind {
            case .status: actual = String(response.status)
            case .time: actual = String(Int(response.duration * 1000))
            case .header: actual = response.header(check.target)
            case .bodyContains: actual = response.bodyFile == nil ? response.text : nil
            case .jsonPath: actual = json.flatMap { JSONPath.firstText(check.target, in: $0) }
            }
            let passed = compare(actual, check.op, check.expected, bodyCheck: check.kind == .bodyContains)
            return Result(check: check, passed: passed, actual: describe(actual, check),
                          message: message(for: check, actual: actual, passed: passed))
        }
    }

    private static func compare(_ actual: String?, _ op: APICheck.Operator, _ expected: String, bodyCheck: Bool) -> Bool {
        switch op {
        case .exists: return actual != nil
        case .notExists: return actual == nil
        default: break
        }
        guard let actual else { return op == .notEquals || op == .notContains }
        switch op {
        case .equals: return numericEqual(actual, expected) ?? (actual == expected)
        case .notEquals: return !(numericEqual(actual, expected) ?? (actual == expected))
        case .contains: return actual.localizedCaseInsensitiveContains(expected) || (!bodyCheck && actual.contains(expected))
        case .notContains: return !actual.localizedCaseInsensitiveContains(expected)
        case .lessThan: return (Double(actual) ?? .infinity) < (Double(expected) ?? -.infinity)
        case .greaterThan: return (Double(actual) ?? -.infinity) > (Double(expected) ?? .infinity)
        case .matches: return actual.range(of: expected, options: .regularExpression) != nil
        case .exists, .notExists: return true
        }
    }

    private static func numericEqual(_ a: String, _ b: String) -> Bool? {
        guard let x = Double(a), let y = Double(b) else { return nil }
        return x == y
    }

    private static func describe(_ actual: String?, _ check: APICheck) -> String {
        guard let actual else { return "not present" }
        if check.kind == .bodyContains { return actual.count > 80 ? String(actual.prefix(80)) + "…" : actual }
        return actual.count > 200 ? String(actual.prefix(200)) + "…" : actual
    }

    private static func message(for check: APICheck, actual: String?, passed: Bool) -> String {
        let subject: String
        switch check.kind {
        case .status: subject = "status"
        case .time: subject = "time (ms)"
        case .header: subject = "header \(check.target)"
        case .bodyContains: subject = "body"
        case .jsonPath: subject = check.target
        }
        let value = actual.map { $0.count > 60 ? String($0.prefix(60)) + "…" : $0 } ?? "nothing"
        let verb: String
        switch check.op {
        case .equals: verb = passed ? "is" : "is not"
        case .notEquals: verb = passed ? "is not" : "is"
        case .contains: verb = passed ? "contains" : "does not contain"
        case .notContains: verb = passed ? "does not contain" : "contains"
        case .exists: return passed ? "\(subject) is present" : "\(subject) is missing"
        case .notExists: return passed ? "\(subject) is absent" : "\(subject) is present"
        case .lessThan: verb = passed ? "is under" : "is not under"
        case .greaterThan: verb = passed ? "is over" : "is not over"
        case .matches: verb = passed ? "matches" : "does not match"
        }
        return "\(subject) \(value) \(verb) \(check.expected)"
    }

    /// The variables to set from this answer: name → value. Captures that find nothing set nothing.
    static func capture(_ captures: [APICapture], response: APIResponse) -> [(capture: APICapture, value: String)] {
        let json = response.json
        return captures.filter(\.enabled).compactMap { capture in
            let value: String?
            switch capture.source {
            case .status: value = String(response.status)
            case .header: value = response.header(capture.path)
            case .jsonPath: value = json.flatMap { JSONPath.firstText(capture.path, in: $0) }
            }
            return value.map { (capture, $0) }
        }
    }
}
