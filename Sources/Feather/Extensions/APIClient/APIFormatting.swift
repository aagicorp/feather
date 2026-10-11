import AppKit

/// The small pure pieces the API client's views share: colours for methods and statuses, sizes and times as
/// people read them, the URL ↔ Params table split, JSON re-indented without losing the order of its keys, and
/// the path of the value under the caret. Kept apart from the views so they can be tested without a window.
enum APIFormat {
    // MARK: Colours

    private static var badgeCache: [String: NSImage] = [:]

    /// "GET" in its colour on a faint rounded ground, for the request's tab and breadcrumb in place of a file icon.
    static let badgeWidth: CGFloat = 38

    static func methodBadge(_ method: APIMethod, theme: Theme) -> NSImage {
        let key = method.rawValue + "|" + theme.name
        if let cached = badgeCache[key] { return cached }
        let colour = methodColor(method, theme: theme)
        let text = method == .delete ? "DEL" : method == .options ? "OPT" : method.rawValue
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold), .foregroundColor: colour]
        let textSize = (text as NSString).size(withAttributes: attributes)
        // One width for every method, so names line up in the tree and the tabs.
        let size = NSSize(width: max(APIFormat.badgeWidth, ceil(textSize.width) + 8), height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            colour.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 1.5), xRadius: 3, yRadius: 3).fill()
            (text as NSString).draw(at: NSPoint(x: floor((rect.width - textSize.width) / 2), y: (rect.height - textSize.height) / 2), withAttributes: attributes)
            return true
        }
        badgeCache[key] = image
        return image
    }

    /// GET green, POST amber, PUT and PATCH blue, DELETE red, the rest grey: the colours Postman and VS Code's
    /// REST clients use, so the tree reads at a glance.
    static func methodColor(_ method: APIMethod, theme: Theme) -> NSColor {
        switch method {
        case .get: return theme.isDark ? NSColor(hex: 0x4CC38A) : NSColor(hex: 0x1F8A4C)
        case .post: return theme.isDark ? NSColor(hex: 0xE0B04A) : NSColor(hex: 0xB7791F)
        case .put, .patch: return theme.isDark ? NSColor(hex: 0x6FA8F0) : NSColor(hex: 0x2B6CB0)
        case .delete: return theme.isDark ? NSColor(hex: 0xF07575) : NSColor(hex: 0xC53030)
        case .head, .options: return theme.lineNumber
        }
    }

    /// 2xx green, 3xx blue, 4xx amber, 5xx and no answer red.
    static func statusColor(_ status: Int?, theme: Theme) -> NSColor {
        switch status ?? 0 {
        case 200..<300: return methodColor(.get, theme: theme)
        case 300..<400: return methodColor(.put, theme: theme)
        case 400..<500: return methodColor(.post, theme: theme)
        default: return methodColor(.delete, theme: theme)
        }
    }

    /// "POST" and the rest at four letters, so names line up in the tree.
    static func methodLabel(_ method: APIMethod) -> String {
        switch method {
        case .delete: return "DEL"
        case .options: return "OPT"
        case .patch: return "PTCH"
        default: return method.rawValue
        }
    }

    // MARK: Numbers

    static func size(_ bytes: Int) -> String {
        switch bytes {
        case ..<1024: return "\(bytes) B"
        case ..<(1024 * 1024): return String(format: "%.1f KB", Double(bytes) / 1024)
        default: return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.2f s", seconds)
    }

    // MARK: URL and params

    /// The address split at its "?": what is before it, and the query as name/value pairs. Values are kept as
    /// typed (no percent-decoding), so a `{{variable}}` in the query stays what it was.
    static func splitQuery(_ url: String) -> (base: String, query: [(name: String, value: String)]) {
        guard let mark = url.firstIndex(of: "?") else { return (url, []) }
        let base = String(url[..<mark])
        let rest = url[url.index(after: mark)...]
        let query = rest.split(separator: "&", omittingEmptySubsequences: true).map { pair -> (String, String) in
            if let equals = pair.firstIndex(of: "=") {
                return (String(pair[..<equals]), String(pair[pair.index(after: equals)...]))
            }
            return (String(pair), "")
        }
        return (base, query)
    }

    /// The address with the enabled params back on it as a query, the way the URL field shows a request.
    static func joinQuery(base: String, params: [APIKeyValue]) -> String {
        let enabled = params.filter { $0.enabled && !$0.name.isEmpty }
        guard !enabled.isEmpty else { return base }
        let query = enabled.map { $0.value.isEmpty ? $0.name : $0.name + "=" + $0.value }.joined(separator: "&")
        return base + (base.contains("?") ? "&" : "?") + query
    }

    /// The Params rows after the URL was edited: its query becomes the enabled rows (keeping the ids of rows whose
    /// name is unchanged, so the table does not jump), and rows that were switched off stay as they were.
    static func params(afterEditingURL url: String, previous: [APIKeyValue]) -> (base: String, params: [APIKeyValue]) {
        let (base, query) = splitQuery(url)
        var unused = previous.filter(\.enabled)
        var rows: [APIKeyValue] = query.map { pair in
            if let index = unused.firstIndex(where: { $0.name == pair.name }) {
                var row = unused.remove(at: index)
                row.value = pair.value
                return row
            }
            return APIKeyValue(pair.name, pair.value)
        }
        rows += previous.filter { !$0.enabled }
        return (base, rows)
    }

    /// The `{{name}}` places in a piece of text, for colouring.
    static func variableRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        return variablePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
    }

    private static let variablePattern = try! NSRegularExpression(pattern: #"\{\{[^{}\n]*\}\}"#)

    // MARK: JSON

    /// JSON re-indented with two spaces, keys in the order the server sent them (`JSONSerialization` would sort
    /// or shuffle them). Works on the text alone, so anything that is not JSON comes back unchanged.
    static func prettyJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else { return text }
        var out = ""
        out.reserveCapacity(text.utf8.count + text.utf8.count / 4)
        var depth = 0
        var inString = false
        var escaped = false
        let scalars = Array(text.unicodeScalars)
        var index = 0
        func newline() {
            out.append("\n")
            out.append(String(repeating: "  ", count: depth))
        }
        func nextNonSpace(after position: Int) -> Unicode.Scalar? {
            var cursor = position + 1
            while cursor < scalars.count {
                if !scalars[cursor].properties.isWhitespace { return scalars[cursor] }
                cursor += 1
            }
            return nil
        }
        while index < scalars.count {
            let scalar = scalars[index]
            if inString {
                out.unicodeScalars.append(scalar)
                if escaped { escaped = false }
                else if scalar == "\\" { escaped = true }
                else if scalar == "\"" { inString = false }
                index += 1
                continue
            }
            switch scalar {
            case "\"":
                inString = true
                out.unicodeScalars.append(scalar)
            case "{", "[":
                let close: Unicode.Scalar = scalar == "{" ? "}" : "]"
                if nextNonSpace(after: index) == close {
                    // An empty object or list stays on one line.
                    out.unicodeScalars.append(scalar)
                    out.unicodeScalars.append(close)
                    index = scalars[(index + 1)...].firstIndex(of: close) ?? index
                } else {
                    out.unicodeScalars.append(scalar)
                    depth += 1
                    newline()
                }
            case "}", "]":
                depth = max(0, depth - 1)
                newline()
                out.unicodeScalars.append(scalar)
            case ",":
                out.append(",")
                newline()
            case ":":
                out.append(": ")
            default:
                if !scalar.properties.isWhitespace { out.unicodeScalars.append(scalar) }
            }
            index += 1
        }
        return out
    }

    /// The path (`$.items[2].name`) of the value the caret is in, worked out by reading the JSON up to that point.
    /// Nil when the text up to there is not JSON.
    static func jsonPath(at offset: Int, in text: String) -> String? {
        struct Frame { var isArray: Bool; var index = 0; var key: String? = nil; var expectingKey: Bool }
        var stack: [Frame] = []
        var inString = false
        var escaped = false
        var string = ""
        let ns = text as NSString
        let end = min(max(0, offset), ns.length)
        guard let first = text.first(where: { !$0.isWhitespace }), first == "{" || first == "[" else { return nil }
        var position = 0
        var sawValue = false
        func path() -> String {
            var result = "$"
            for frame in stack {
                if frame.isArray { result += "[\(frame.index)]" }
                else if let key = frame.key {
                    let plain = key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
                    result += plain ? ".\(key)" : "['\(key)']"
                }
            }
            return result
        }
        while position < end {
            let unit = ns.character(at: position)
            position += 1
            guard let scalar = Unicode.Scalar(unit) else { continue }
            if inString {
                if escaped { escaped = false; string.unicodeScalars.append(scalar) }
                else if scalar == "\\" { escaped = true }
                else if scalar == "\"" {
                    inString = false
                    if let top = stack.indices.last, stack[top].expectingKey, !stack[top].isArray {
                        stack[top].key = string
                        stack[top].expectingKey = false
                    }
                } else { string.unicodeScalars.append(scalar) }
                continue
            }
            switch scalar {
            case "\"":
                inString = true
                string = ""
                sawValue = true
            case "{":
                stack.append(Frame(isArray: false, expectingKey: true))
                sawValue = true
            case "[":
                stack.append(Frame(isArray: true, expectingKey: false))
                sawValue = true
            case "}", "]":
                if stack.isEmpty { return nil }
                stack.removeLast()
            case ",":
                if let top = stack.indices.last {
                    if stack[top].isArray { stack[top].index += 1 } else { stack[top].expectingKey = true; stack[top].key = nil }
                }
            default:
                if !scalar.properties.isWhitespace { sawValue = true }
            }
        }
        guard sawValue else { return nil }
        // A caret on a key that has no value yet ("expectingKey" still set) points at the object itself.
        if let top = stack.indices.last, !stack[top].isArray, stack[top].expectingKey, !inString { stack[top].key = nil }
        return path()
    }
}
