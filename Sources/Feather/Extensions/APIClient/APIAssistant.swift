import Foundation

/// What "Ask Assistant About Last Request" hands to the AI assistant: a short plain-text brief with the
/// request as a cURL line, what came back (status, time, the first lines of the body) and the checks that
/// failed. Written for an assistant that has the project open, so it says only what the assistant cannot see.
enum APIAssistant {
    /// Lines of the body shown; the rest is summarised as "… and N more lines".
    static let bodyLineLimit = 40
    /// A line longer than this is cut, so a minified answer does not swallow the brief.
    static let lineLengthLimit = 200

    /// One request and what it produced: what the menu command describes.
    struct Exchange {
        var request: APIRequest
        var resolved: APIResolvedRequest?
        var result: Result<APIResponse, APIRequestSender.Failure>?
        var checks: [APIChecks.Result]
        var date: Date
    }

    static func describe(request: APIRequest, resolved: APIResolvedRequest?, response: APIResponse?, checks: [APIChecks.Result],
                         failure: String? = nil) -> String {
        var lines: [String] = []
        let name = request.name.isEmpty ? "\(request.method.rawValue) \(request.url)" : request.name
        lines.append("Look at this API request and its answer, and tell me what is wrong or what to do next.")
        lines.append("")
        lines.append("Request: \(name)")
        lines.append(resolved?.curl.replacingOccurrences(of: " \\\n  ", with: " ") ?? "\(request.method.rawValue) \(request.url)")
        if !request.description.isEmpty { lines.append("Notes: " + firstLine(request.description)) }
        lines.append("")
        if let response {
            var status = "Answer: \(response.status) \(response.statusText)".trimmingCharacters(in: .whitespaces)
            status += " in \(duration(response.duration))"
            status += ", \(size(response.size))"
            if !response.contentType.isEmpty { status += ", \(response.contentType.split(separator: ";").first ?? "")" }
            lines.append(status)
            let body = bodyExcerpt(response)
            if !body.isEmpty {
                lines.append("Body:")
                lines.append(contentsOf: body)
            }
        } else if let failure {
            lines.append("Answer: none. \(failure)")
        } else {
            lines.append("Answer: not sent yet.")
        }
        let failed = checks.filter { !$0.passed }
        if !checks.isEmpty {
            lines.append("")
            if failed.isEmpty {
                lines.append("Checks: all \(checks.count) passed.")
            } else {
                lines.append("Checks: \(failed.count) of \(checks.count) failed:")
                for check in failed { lines.append("- " + check.message) }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ exchange: Exchange) -> String {
        var response: APIResponse?
        var failure: String?
        switch exchange.result {
        case .success(let got): response = got
        case .failure(let error): failure = error.message
        case nil: break
        }
        return describe(request: exchange.request, resolved: exchange.resolved, response: response, checks: exchange.checks, failure: failure)
    }

    /// The brief as one line, for an assistant that would take a newline as Return.
    static func singleLine(_ brief: String) -> String {
        brief.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ⏎ ")
    }

    private static func bodyExcerpt(_ response: APIResponse) -> [String] {
        guard response.bodyFile == nil else { return ["(the body is too large to include: \(size(response.size)))"] }
        guard !response.body.isEmpty else { return [] }
        var text: String
        if response.isJSON, let json = response.json,
           let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) {
            text = String(decoding: pretty, as: UTF8.self)
        } else if String(data: response.body, encoding: .utf8) != nil {
            text = response.text
        } else {
            return ["(binary body, \(size(response.size)))"]
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lines = all.prefix(bodyLineLimit).map { line -> String in
            line.count > lineLengthLimit ? String(line.prefix(lineLengthLimit)) + "…" : line
        }
        if all.count > bodyLineLimit { lines.append("… and \(all.count - bodyLineLimit) more lines") }
        return lines
    }

    private static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.1f s", seconds)
    }

    static func size(_ bytes: Int) -> String {
        switch bytes {
        case ..<1024: return "\(bytes) B"
        case ..<(1024 * 1024): return String(format: "%.1f KB", Double(bytes) / 1024)
        default: return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
    }
}
