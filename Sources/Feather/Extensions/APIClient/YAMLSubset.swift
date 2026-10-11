import Foundation

/// A reader for the YAML that OpenAPI files are written in: block maps and lists, plain and quoted scalars,
/// `|` and `>` block text, inline `[a, b]` and `{a: b}`, comments. It is not the whole language (anchors are
/// ignored, aliases read as null, tags are skipped, only the first document is read), but a real-world spec
/// loads, and anything stranger is refused with a line number rather than misread. Feather has no YAML
/// dependency and a full parser would be a large one for this single use.
enum YAMLSubset {
    struct ParseError: LocalizedError {
        let line: Int
        let message: String
        var errorDescription: String? { "Line \(line): \(message)" }
    }

    /// The document as the same shapes `JSONSerialization` gives: dictionaries, arrays, strings, numbers, Bools, NSNull.
    static func parse(_ text: String) throws -> Any {
        var raw = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // Directives and the first document marker are skipped; a second document ends the read.
        var start = 0
        while start < raw.count, raw[start].hasPrefix("%") || raw[start].trimmingCharacters(in: .whitespaces).isEmpty { start += 1 }
        if start < raw.count, raw[start].hasPrefix("---") { raw[start] = String(raw[start].dropFirst(3)); if raw[start].trimmingCharacters(in: .whitespaces).isEmpty { start += 1 } }
        if let end = raw[start...].firstIndex(where: { $0.hasPrefix("---") || $0 == "..." }) { raw = Array(raw[..<end]) }
        if let tabbed = raw.indices.first(where: { raw[$0].prefix { $0 == " " || $0 == "\t" }.contains("\t") }) {
            throw ParseError(line: tabbed + 1, message: "indented with a tab; YAML needs spaces")
        }
        var parser = Parser(lines: raw, position: start)
        let value = try parser.node()
        parser.skipBlank()
        if parser.position < raw.count { throw ParseError(line: parser.position + 1, message: "unexpected text: \(parser.content(parser.position))") }
        return value ?? NSNull()
    }

    private struct Parser {
        var lines: [String]
        var position: Int

        // MARK: Lines

        func indent(_ index: Int) -> Int { lines[index].prefix { $0 == " " }.count }

        /// The line without its indent, comment and trailing spaces.
        func content(_ index: Int) -> String { YAMLSubset.stripComment(lines[index]).trimmingCharacters(in: .whitespaces) }

        func isBlank(_ index: Int) -> Bool { content(index).isEmpty }

        mutating func skipBlank() { while position < lines.count, isBlank(position) { position += 1 } }

        func error(_ message: String) -> ParseError { ParseError(line: min(position, lines.count - 1) + 1, message: message) }

        // MARK: Nodes

        mutating func node() throws -> Any? {
            skipBlank()
            guard position < lines.count else { return nil }
            let text = content(position)
            if isSequenceItem(text) { return try sequence(indent(position)) }
            if splitKey(text) != nil { return try mapping(indent(position)) }
            position += 1
            return try value(rest: text, parentIndent: indent(position - 1) - 1)
        }

        private func isSequenceItem(_ text: String) -> Bool { text == "-" || text.hasPrefix("- ") }

        mutating func mapping(_ indent: Int) throws -> [String: Any] {
            var result: [String: Any] = [:]
            while true {
                skipBlank()
                guard position < lines.count, self.indent(position) == indent else {
                    if position < lines.count, self.indent(position) > indent { throw error("unexpected indentation") }
                    break
                }
                let text = content(position)
                if isSequenceItem(text) { break }
                guard let (key, rest) = splitKey(text) else { throw error("expected \"name: value\", found: \(text)") }
                position += 1
                result[key] = try value(rest: rest, parentIndent: indent) ?? NSNull()
            }
            return result
        }

        mutating func sequence(_ indent: Int) throws -> [Any] {
            var result: [Any] = []
            while true {
                skipBlank()
                guard position < lines.count, self.indent(position) == indent else {
                    if position < lines.count, self.indent(position) > indent { throw error("unexpected indentation") }
                    break
                }
                let text = content(position)
                guard isSequenceItem(text) else { break }
                let rest = text == "-" ? "" : String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    position += 1
                    result.append(try value(rest: "", parentIndent: indent) ?? NSNull())
                } else if splitKey(rest) != nil || isSequenceItem(rest) {
                    // "- name: pet" starts a map (or a nested list) whose other lines sit under "name"; the
                    // line is rewritten as that first line so the usual reader takes it.
                    let childIndent = indent + (text.count - rest.count)
                    lines[position] = String(repeating: " ", count: childIndent) + rest
                    result.append(try node() ?? NSNull())
                } else {
                    position += 1
                    result.append(try value(rest: rest, parentIndent: indent) ?? NSNull())
                }
            }
            return result
        }

        /// The value after "key:" (or "- "), which may sit on the same line or on the lines below.
        mutating func value(rest: String, parentIndent: Int) throws -> Any? {
            var rest = rest
            while rest.hasPrefix("&") || rest.hasPrefix("!") {          // anchors and tags carry no data
                rest = rest.split(separator: " ", maxSplits: 1).dropFirst().first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            }
            if rest.hasPrefix("*") { return NSNull() }
            if rest.isEmpty {
                skipBlank()
                guard position < lines.count else { return nil }
                if indent(position) > parentIndent { return try node() }
                if indent(position) == parentIndent, isSequenceItem(content(position)) { return try sequence(parentIndent) }
                return nil
            }
            if rest.hasPrefix("|") || rest.hasPrefix(">") { return try blockScalar(header: rest, parentIndent: parentIndent) }
            if rest.hasPrefix("[") || rest.hasPrefix("{") {
                var text = rest
                while !YAMLSubset.isBalanced(text), position < lines.count {
                    text += " " + content(position)
                    position += 1
                }
                var index = text.startIndex
                let parsed = try YAMLSubset.flowValue(text, &index, line: position)
                return parsed
            }
            var scalar = rest
            if scalar.hasPrefix("\"") || scalar.hasPrefix("'") {
                let quote = scalar.first!
                while !YAMLSubset.closesQuote(scalar, quote), position < lines.count {
                    scalar += " " + content(position)
                    position += 1
                }
            } else {
                // A plain scalar may continue on deeper lines that are not keys or list items.
                while position < lines.count, !isBlank(position), indent(position) > parentIndent {
                    let next = content(position)
                    if splitKey(next) != nil || isSequenceItem(next) { break }
                    scalar += " " + next
                    position += 1
                }
            }
            return YAMLSubset.scalar(scalar)
        }

        mutating func blockScalar(header: String, parentIndent: Int) throws -> String {
            let folded = header.hasPrefix(">")
            let chomp: Character? = header.dropFirst().first { $0 == "-" || $0 == "+" }
            var collected: [String] = []
            var blockIndent: Int?
            while position < lines.count {
                let line = lines[position]
                let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
                if !blank {
                    let lineIndent = line.prefix { $0 == " " }.count
                    if blockIndent == nil {
                        guard lineIndent > parentIndent else { break }
                        blockIndent = lineIndent
                    }
                    if lineIndent < blockIndent! { break }
                }
                collected.append(blank ? "" : String(line.dropFirst(blockIndent ?? 0)))
                position += 1
            }
            var trailing = 0
            while let last = collected.last, last.isEmpty { collected.removeLast(); trailing += 1 }
            var text: String
            if folded {
                text = ""
                var previousBlank = true
                for line in collected {
                    if line.isEmpty { text += "\n"; previousBlank = true; continue }
                    if !previousBlank { text += line.hasPrefix(" ") ? "\n" : " " }
                    text += line
                    previousBlank = false
                }
            } else {
                text = collected.joined(separator: "\n")
            }
            switch chomp {
            case "-": break
            case "+": text += String(repeating: "\n", count: trailing + 1)
            default: if !collected.isEmpty { text += "\n" }
            }
            return text
        }

        /// "key: rest" → (key, rest); nil when the line is not a map entry.
        func splitKey(_ text: String) -> (String, String)? {
            guard !text.isEmpty else { return nil }
            var index = text.startIndex
            if text.first == "\"" || text.first == "'" {
                let quote = text.first!
                index = text.index(after: index)
                while index < text.endIndex {
                    if text[index] == "\\", quote == "\"" { index = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex; continue }
                    if text[index] == quote {
                        if quote == "'", text.index(after: index) < text.endIndex, text[text.index(after: index)] == "'" { index = text.index(index, offsetBy: 2); continue }
                        break
                    }
                    index = text.index(after: index)
                }
                guard index < text.endIndex else { return nil }
                let close = text.index(after: index)
                let afterQuote = text[close...].drop { $0 == " " }
                guard afterQuote.first == ":", afterQuote.count == 1 || afterQuote.dropFirst().first == " " else { return nil }
                let key = YAMLSubset.scalar(String(text[...index])).map { "\($0)" } ?? ""
                return (key, String(afterQuote.dropFirst()).trimmingCharacters(in: .whitespaces))
            }
            if text.first == "[" || text.first == "{" || text.first == "#" { return nil }
            // The first ": " (or a ":" at the end) outside any quotes ends the key.
            var inQuote: Character?
            while index < text.endIndex {
                let char = text[index]
                if let quote = inQuote { if char == quote { inQuote = nil } }
                else if char == "\"" || char == "'" { inQuote = char }
                else if char == ":" {
                    let next = text.index(after: index)
                    if next == text.endIndex || text[next] == " " || text[next] == "\t" {
                        let key = text[..<index].trimmingCharacters(in: .whitespaces)
                        guard !key.isEmpty, !key.hasPrefix("- ") else { return nil }
                        return (key, String(text[next...]).trimmingCharacters(in: .whitespaces))
                    }
                }
                index = text.index(after: index)
            }
            return nil
        }
    }

    // MARK: Scalars

    /// A plain, single-quoted or double-quoted scalar as a value: null, Bool, Int, Double or String.
    static func scalar(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\"") {
            var result = ""
            var index = trimmed.index(after: trimmed.startIndex)
            while index < trimmed.endIndex, trimmed[index] != "\"" {
                if trimmed[index] == "\\", trimmed.index(after: index) < trimmed.endIndex {
                    index = trimmed.index(after: index)
                    switch trimmed[index] {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "r": result.append("\r")
                    case "0": result.append("\0")
                    case "u":
                        let hex = trimmed[trimmed.index(after: index)...].prefix(4)
                        if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                            result.unicodeScalars.append(scalar)
                            index = trimmed.index(index, offsetBy: 4)
                        }
                    default: result.append(trimmed[index])
                    }
                } else {
                    result.append(trimmed[index])
                }
                index = trimmed.index(after: index)
            }
            return result
        }
        if trimmed.hasPrefix("'") {
            var body = String(trimmed.dropFirst())
            if body.hasSuffix("'") { body.removeLast() }
            return body.replacingOccurrences(of: "''", with: "'")
        }
        switch trimmed {
        case "", "~", "null", "Null", "NULL": return nil
        case "true", "True", "TRUE": return true
        case "false", "False", "FALSE": return false
        default: break
        }
        if let int = Int(trimmed), !(trimmed.hasPrefix("0") && trimmed.count > 1), !(trimmed.hasPrefix("-0") && trimmed.count > 2), !trimmed.hasPrefix("+") { return int }
        if trimmed.range(of: #"^-?(\d+\.\d*|\.\d+|\d+)([eE][-+]?\d+)?$"#, options: .regularExpression) != nil, trimmed.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }),
           let double = Double(trimmed) { return double }
        return trimmed
    }

    private static func stripComment(_ line: String) -> String {
        var inQuote: Character?
        var previous: Character = " "
        for (offset, char) in line.enumerated() {
            if let quote = inQuote { if char == quote { inQuote = nil } }
            else if char == "\"" || char == "'" {
                // A quote opens a string only at a value boundary, not inside a word (don't, it's).
                if previous == " " || previous == ":" || previous == "[" || previous == "{" || previous == "," || offset == 0 || previous == "-" { inQuote = char }
            }
            else if char == "#", previous == " " || previous == "\t" || offset == 0 { return String(line.prefix(offset)) }
            previous = char
        }
        return line
    }

    private static func closesQuote(_ text: String, _ quote: Character) -> Bool {
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            if text[index] == "\\", quote == "\"" { index = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex; continue }
            if text[index] == quote {
                let next = text.index(after: index)
                if quote == "'", next < text.endIndex, text[next] == "'" { index = text.index(after: next); continue }
                return true
            }
            index = text.index(after: index)
        }
        return false
    }

    private static func isBalanced(_ text: String) -> Bool {
        var depth = 0
        var inQuote: Character?
        for char in text {
            if let quote = inQuote { if char == quote { inQuote = nil }; continue }
            switch char {
            case "\"", "'": inQuote = char
            case "[", "{": depth += 1
            case "]", "}": depth -= 1
            default: break
            }
        }
        return depth <= 0
    }

    // MARK: Flow collections

    private static func flowValue(_ text: String, _ index: inout String.Index, line: Int) throws -> Any {
        func skipSpaces() { while index < text.endIndex, text[index] == " " || text[index] == "\t" { index = text.index(after: index) } }
        skipSpaces()
        guard index < text.endIndex else { return NSNull() }
        if text[index] == "[" {
            index = text.index(after: index)
            var items: [Any] = []
            while true {
                skipSpaces()
                guard index < text.endIndex else { throw ParseError(line: line, message: "unclosed [") }
                if text[index] == "]" { index = text.index(after: index); return items }
                items.append(try flowValue(text, &index, line: line))
                skipSpaces()
                if index < text.endIndex, text[index] == "," { index = text.index(after: index) }
            }
        }
        if text[index] == "{" {
            index = text.index(after: index)
            var map: [String: Any] = [:]
            while true {
                skipSpaces()
                guard index < text.endIndex else { throw ParseError(line: line, message: "unclosed {") }
                if text[index] == "}" { index = text.index(after: index); return map }
                let keyText = flowScalarText(text, &index, stopAt: [":", ",", "}"])
                let key = scalar(keyText).map { "\($0)" } ?? ""
                skipSpaces()
                if index < text.endIndex, text[index] == ":" {
                    index = text.index(after: index)
                    map[key] = try flowValue(text, &index, line: line)
                } else {
                    map[key] = NSNull()
                }
                skipSpaces()
                if index < text.endIndex, text[index] == "," { index = text.index(after: index) }
            }
        }
        let scalarText = flowScalarText(text, &index, stopAt: [",", "]", "}"])
        return scalar(scalarText) ?? NSNull()
    }

    private static func flowScalarText(_ text: String, _ index: inout String.Index, stopAt: Set<Character>) -> String {
        var result = ""
        var inQuote: Character?
        while index < text.endIndex {
            let char = text[index]
            if let quote = inQuote {
                result.append(char)
                if char == "\\", quote == "\"", text.index(after: index) < text.endIndex {
                    index = text.index(after: index)
                    result.append(text[index])
                } else if char == quote {
                    inQuote = nil
                }
            } else if char == "\"" || char == "'", result.trimmingCharacters(in: .whitespaces).isEmpty {
                inQuote = char
                result.append(char)
            } else if stopAt.contains(char) {
                break
            } else {
                result.append(char)
            }
            index = text.index(after: index)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
