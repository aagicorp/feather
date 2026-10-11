import Foundation

/// The requests written in a `.http` / `.rest` file, the way VS Code's REST Client reads them: blocks separated
/// by `###` lines, each with a request line (`POST {{baseUrl}}/login HTTP/1.1`, the method and the version
/// optional), then headers, a blank line and the body. `@name = value` lines are file variables and are
/// substituted; `# @name login` names the request; the text after `###` names it too.
///
/// This is the reader the editor strip uses; the importer has its own, fuller one. Nothing here throws: a
/// file that is half written still lists the requests that can be made out.
enum HTTPFileBlocks {
    struct Block: Equatable {
        /// From the block's first non-blank line to the end of its last one, in UTF-16, so the block under the
        /// cursor can be found.
        var range: NSRange
        /// Zero-based line of the request line, for showing where the block is.
        var line: Int
        var request: APIRequest

        static func == (lhs: Block, rhs: Block) -> Bool {
            lhs.range == rhs.range && lhs.line == rhs.line && lhs.request.method == rhs.request.method && lhs.request.url == rhs.request.url
                && lhs.request.name == rhs.request.name && lhs.request.headers == rhs.request.headers && lhs.request.body == rhs.request.body
        }
    }

    /// Files above this size are not read: a strip over a log dump would help nobody.
    static let sizeLimit = 200_000
    static let fileExtensions: Set<String> = ["http", "rest"]

    static func isHTTPFile(_ url: URL?) -> Bool { url.map { fileExtensions.contains($0.pathExtension.lowercased()) } ?? false }

    private static let requestLine = try! NSRegularExpression(
        pattern: #"^\s*(?:(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+)?(\S.*?)(?:\s+HTTP/\d(?:\.\d)?)?\s*$"#, options: [.caseInsensitive])
    private static let headerLine = try! NSRegularExpression(pattern: #"^([A-Za-z0-9!#$%&'*+.^_`|~-]+):\s*(.*?)\s*$"#)
    private static let variableLine = try! NSRegularExpression(pattern: #"^@([A-Za-z0-9_.$-]+)\s*=\s*(.*?)\s*$"#)
    private static let nameComment = try! NSRegularExpression(pattern: #"^(?:#|//)\s*@name\s*[= ]?\s*([^\s]+)"#)

    private struct Line {
        var text: String
        var range: NSRange
        var number: Int
    }

    static func parse(_ text: String) -> [Block] {
        let ns = text as NSString
        guard ns.length > 0, ns.length <= sizeLimit else { return [] }
        var lines: [Line] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            lines.append(Line(text: ns.substring(with: range), range: range, number: lines.count))
        }
        // File variables apply to the whole file, wherever they are written.
        var fileVariables: [String: String] = [:]
        for line in lines {
            if let match = variableLine.firstMatch(in: line.text, range: NSRange(location: 0, length: (line.text as NSString).length)) {
                let name = (line.text as NSString).substring(with: match.range(at: 1))
                fileVariables[name] = (line.text as NSString).substring(with: match.range(at: 2))
            }
        }
        let variables = APIVariables(collection: fileVariables.map { APIVariable($0.key, $0.value) })

        var blocks: [Block] = []
        var current: [Line] = []
        var heading: String?
        func flush() {
            if let block = makeBlock(current, heading: heading, variables: variables) { blocks.append(block) }
            current = []
        }
        for line in lines {
            if line.text.hasPrefix("###") {
                flush()
                let title = line.text.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                heading = title.isEmpty ? nil : title
            } else {
                current.append(line)
            }
        }
        flush()
        return blocks
    }

    /// The block the cursor is in: the last one that starts at or before `location` (the blank lines after a
    /// block still count as its), or the first block when the cursor is above them all.
    static func block(at location: Int, in blocks: [Block]) -> Block? {
        blocks.last { $0.range.location <= location } ?? blocks.first
    }

    private static func makeBlock(_ lines: [Line], heading: String?, variables: APIVariables) -> Block? {
        var index = 0
        var name = heading
        // Comments, variables and blank lines before the request line.
        while index < lines.count {
            let text = lines[index].text
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("@") { index += 1; continue }
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
                if let match = nameComment.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) {
                    name = (trimmed as NSString).substring(with: match.range(at: 1))
                }
                index += 1
                continue
            }
            break
        }
        guard index < lines.count else { return nil }
        let first = lines.first { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty } ?? lines[index]
        let requestText = lines[index].text
        guard let match = requestLine.firstMatch(in: requestText, range: NSRange(location: 0, length: (requestText as NSString).length)) else { return nil }
        let methodText = match.range(at: 1).location == NSNotFound ? "GET" : (requestText as NSString).substring(with: match.range(at: 1)).uppercased()
        guard let method = APIMethod(rawValue: methodText) else { return nil }
        var url = (requestText as NSString).substring(with: match.range(at: 2))
        let requestLineNumber = lines[index].number
        index += 1
        // A long query may continue on lines that start with ? or &.
        while index < lines.count {
            let trimmed = lines[index].text.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("?") || trimmed.hasPrefix("&") else { break }
            url += trimmed
            index += 1
        }
        // "TRACE http://h" or a sentence: a request line has one address and nothing else.
        guard !url.isEmpty, url.rangeOfCharacter(from: .whitespaces) == nil else { return nil }

        var request = APIRequest(name: "", method: method, url: variables.resolve(url))
        while index < lines.count {
            let text = lines[index].text
            if text.trimmingCharacters(in: .whitespaces).isEmpty { index += 1; break }
            if let header = headerLine.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                request.headers.append(APIKeyValue((text as NSString).substring(with: header.range(at: 1)),
                                                   variables.resolve((text as NSString).substring(with: header.range(at: 2)))))
                index += 1
            } else if text.hasPrefix("#") || text.hasPrefix("//") {
                index += 1
            } else {
                break           // not a header: the body starts here without a blank line
            }
        }
        var bodyLines = lines[index...].map(\.text)
        while let last = bodyLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { bodyLines.removeLast() }
        if !bodyLines.isEmpty {
            let bodyText = variables.resolve(bodyLines.joined(separator: "\n"))
            let declared = request.headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
            let contentType = declared ?? (looksLikeJSON(bodyText) ? "application/json" : "text/plain")
            if contentType.contains("x-www-form-urlencoded"), bodyLines.count == 1 || bodyText.contains("&") {
                request.body = APIBody(kind: .urlencoded, fields: formFields(bodyText))
            } else {
                request.body = APIBody(kind: .raw, text: bodyText, contentType: contentType)
            }
        }
        request.name = name ?? defaultName(method: method, url: request.url)
        let last = lines.last { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty } ?? lines[index - 1]
        let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        return Block(range: range, line: requestLineNumber, request: request)
    }

    /// "GET /users/42" — the path is what tells requests apart; the host is the same for most of a file.
    static func defaultName(method: APIMethod, url: String) -> String {
        var path = url
        if let scheme = path.range(of: "://") {
            path = String(path[scheme.upperBound...])
            if let slash = path.firstIndex(of: "/") { path = String(path[slash...]) } else { path = "/" }
        }
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        if path.isEmpty { path = url }
        return method.rawValue + " " + path
    }

    static func looksLikeJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
    }

    /// `a=1&b=2` as rows, percent-decoded.
    static func formFields(_ text: String) -> [APIKeyValue] {
        text.replacingOccurrences(of: "\n", with: "&").split(separator: "&").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first, !name.isEmpty else { return nil }
            let value = parts.count > 1 ? String(parts[1]) : ""
            return APIKeyValue(String(name).removingPercentEncoding ?? String(name), value.removingPercentEncoding ?? value)
        }
    }
}
