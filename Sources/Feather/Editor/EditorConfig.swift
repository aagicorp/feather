import AppKit

/// What the `.editorconfig` files above a file say about it. A nil field means "nothing said": the user's own
/// setting applies.
struct EditorConfigProperties: Equatable {
    enum LineEnding: String { case lf, crlf, cr
        var string: String { self == .lf ? "\n" : self == .crlf ? "\r\n" : "\r" }
    }
    var useSpaces: Bool?
    var tabWidth: Int?
    var lineEnding: LineEnding?
    var insertFinalNewline: Bool?
    var trimTrailingWhitespace: Bool?
    /// Only the encodings a document can be held in; others (`utf-8-bom`, `utf-16be`) are left as the file was.
    var encoding: String.Encoding?

    var isEmpty: Bool { self == EditorConfigProperties() }

    /// From the merged key/value pairs, keys and values already lowercased.
    init(_ values: [String: String] = [:]) {
        switch values["indent_style"] {
        case "space": useSpaces = true
        case "tab": useSpaces = false
        default: break
        }
        let size = values["indent_size"].flatMap(Int.init), tab = values["tab_width"].flatMap(Int.init)
        // Feather has one number for both the indent and the width of a tab. With tabs the tab's width is the
        // one that shows; with spaces (or nothing said) the indent size is. Each stands in for the other.
        let width = useSpaces == false || values["indent_size"] == "tab" ? tab ?? size : size ?? tab
        tabWidth = width.map { max(1, min(16, $0)) }
        lineEnding = values["end_of_line"].flatMap(LineEnding.init(rawValue:))
        insertFinalNewline = values["insert_final_newline"].flatMap(EditorConfigProperties.bool)
        trimTrailingWhitespace = values["trim_trailing_whitespace"].flatMap(EditorConfigProperties.bool)
        switch values["charset"] {
        case "utf-8": encoding = .utf8
        case "latin1": encoding = .isoLatin1
        case "utf-16le": encoding = .utf16          // written with a byte-order mark, which is how Feather reads it back
        default: break
        }
    }

    private static func bool(_ text: String) -> Bool? { text == "true" ? true : text == "false" ? false : nil }
}

/// A section glob, compiled once. The grammar is the EditorConfig one: `*` (not across `/`), `**`, `?`,
/// `[abc]`, `[!abc]`, `{a,b}` (nestable), `{1..3}`, and backslash escapes.
struct EditorConfigGlob {
    private let regex: NSRegularExpression?
    /// One per `{low..high}`, in order; each is a capture group whose number must lie in the range.
    private let ranges: [ClosedRange<Int>]

    init(_ pattern: String) {
        var glob = pattern
        // A pattern without a slash names a file in any folder; one with a slash is relative to the .editorconfig.
        if !glob.contains("/") { glob = "**/" + glob } else if glob.hasPrefix("/") { glob.removeFirst() }
        let (source, ranges) = EditorConfigGlob.translate(Array("/" + glob))
        regex = try? NSRegularExpression(pattern: "^" + source + "$", options: [.dotMatchesLineSeparators])
        self.ranges = ranges
    }

    /// `path` is relative to the folder holding the `.editorconfig`, without a leading slash.
    func matches(_ path: String) -> Bool {
        guard let regex else { return false }
        let subject = "/" + path
        let ns = subject as NSString
        guard let match = regex.firstMatch(in: subject, options: [], range: NSRange(location: 0, length: ns.length)) else { return false }
        for (index, range) in ranges.enumerated() {
            let text = ns.substring(with: match.range(at: index + 1))
            // "007" is a different file name from "7", so numbers with leading zeros are not in any range.
            let digits = text.drop { $0 == "-" || $0 == "+" }
            guard let number = Int(text), digits == "0" || !digits.hasPrefix("0"), range.contains(number) else { return false }
        }
        return true
    }

    private static func translate(_ pattern: [Character]) -> (String, [ClosedRange<Int>]) {
        var output = "", ranges: [ClosedRange<Int>] = []
        var groups: [Bool] = []          // for every open brace: is it an alternation, or a literal "{"?
        let count = pattern.count
        // Unbalanced braces are all literal, as the reference implementation has it.
        let balanced = braceBalance(pattern)
        func escaped(_ character: Character) -> String { NSRegularExpression.escapedPattern(for: String(character)) }
        var index = 0
        while index < count {
            let character = pattern[index]
            index += 1
            switch character {
            case "\\":
                if index < count { output += escaped(pattern[index]); index += 1 } else { output += "\\\\" }
            case "*":
                if index < count, pattern[index] == "*" { output += ".*"; index += 1 } else { output += "[^/]*" }
            case "?":
                output += "[^/]"
            case "/":
                // "a/**/b" also matches "a/b".
                if index + 2 < count, pattern[index] == "*", pattern[index + 1] == "*", pattern[index + 2] == "/" {
                    output += "(?:/|/.*/)"
                    index += 3
                } else {
                    output += "/"
                }
            case "[":
                var end = index
                if end < count, pattern[end] == "!" { end += 1 }
                if end < count, pattern[end] == "]" { end += 1 }
                while end < count, pattern[end] != "]" { end += 1 }
                let inner = end < count ? Array(pattern[index..<end]) : []
                if end >= count || inner.contains("/") || inner.isEmpty {
                    output += "\\["
                } else {
                    let negated = inner.first == "!"
                    let body = (negated ? inner.dropFirst() : inner[...]).map { character -> String in
                        "\\[]^".contains(character) ? "\\" + String(character) : String(character)
                    }.joined()
                    output += "[" + (negated ? "^" : "") + body + "]"
                    index = end + 1
                }
            case "{":
                guard balanced, let close = closingBrace(in: pattern, from: index) else { output += "\\{"; break }
                let inner = String(pattern[index..<close.index])
                if !close.hasComma, let range = numericRange(inner) {
                    output += "([+-]?\\d+)"
                    ranges.append(range)
                    index = close.index + 1
                } else {
                    output += close.hasComma ? "(?:" : "\\{"
                    groups.append(close.hasComma)
                }
            case "}":
                if let isGroup = groups.popLast() { output += isGroup ? ")" : "\\}" } else { output += "\\}" }
            case ",":
                output += groups.last == true ? "|" : ","
            default:
                output += escaped(character)
            }
        }
        return (output, ranges)
    }

    private static func braceBalance(_ pattern: [Character]) -> Bool {
        var depth = 0, index = 0
        while index < pattern.count {
            if pattern[index] == "\\" { index += 2; continue }
            if pattern[index] == "{" { depth += 1 } else if pattern[index] == "}" { depth -= 1; if depth < 0 { return false } }
            index += 1
        }
        return depth == 0
    }

    /// The `}` that closes the brace opened just before `start`, and whether a comma sits directly inside it.
    private static func closingBrace(in pattern: [Character], from start: Int) -> (index: Int, hasComma: Bool)? {
        var depth = 0, index = start, hasComma = false
        while index < pattern.count {
            switch pattern[index] {
            case "\\": index += 1
            case "{": depth += 1
            case "}":
                if depth == 0 { return (index, hasComma) }
                depth -= 1
            case ",": if depth == 0 { hasComma = true }
            default: break
            }
            index += 1
        }
        return nil
    }

    private static func numericRange(_ text: String) -> ClosedRange<Int>? {
        let parts = text.components(separatedBy: "..")
        guard parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]) else { return nil }
        return min(low, high)...max(low, high)
    }
}

/// One parsed `.editorconfig`.
struct EditorConfigFile {
    struct Section {
        let glob: EditorConfigGlob
        let values: [(key: String, value: String)]
    }
    var isRoot = false
    var sections: [Section] = []

    init(text: String) {
        var header: String?
        var values: [(key: String, value: String)] = []
        func close() {
            if let header { sections.append(Section(glob: EditorConfigGlob(header), values: values)) }
            values = []
        }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let first = line.first, first != "#", first != ";" else { continue }
            // A glob may itself hold brackets, so the header runs to the last "]" on the line.
            if first == "[", let end = line.lastIndex(of: "]") {
                close()
                header = String(line[line.index(after: line.startIndex)..<end])
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces).lowercased()
            if header == nil {
                if key == "root" { isRoot = value == "true" }
            } else if !key.isEmpty {
                values.append((key, value))
            }
        }
        close()
    }
}

/// Finds and remembers `.editorconfig` files. A lookup walks up from the file's folder to the first file marked
/// `root = true`; nearer files win over farther ones, later sections over earlier ones. Every folder on the way
/// is remembered (also that it has no `.editorconfig`), and looked at again only if it was last checked more
/// than a couple of seconds ago, so opening a thousand files stats each folder once.
final class EditorConfigStore {
    static let shared = EditorConfigStore()
    /// Posted on the main thread after the cache was emptied; open documents work their properties out again.
    static let didInvalidate = Notification.Name("FeatherEditorConfigDidInvalidate")
    private static let recheckAfter: CFAbsoluteTime = 2

    private struct Entry {
        var file: EditorConfigFile?
        var stamp: String?
        var checkedAt: CFAbsoluteTime
    }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    private init() {
        // Files may have been edited, checked out or deleted by other programs while Feather was in the background.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.invalidate()
        }
    }

    func invalidate() {
        lock.lock()
        let hadAny = entries.values.contains { $0.file != nil }
        entries.removeAll()
        lock.unlock()
        if hadAny { NotificationCenter.default.post(name: EditorConfigStore.didInvalidate, object: self) }
    }

    /// Nil when no `.editorconfig` says anything about this file.
    func properties(for url: URL) -> EditorConfigProperties? {
        let path = url.standardizedFileURL.path
        var directory = (path as NSString).deletingLastPathComponent
        var found: [(directory: String, file: EditorConfigFile)] = []
        while true {
            if let file = file(in: directory) {
                found.append((directory, file))
                if file.isRoot { break }
            }
            if directory == "/" || directory.isEmpty { break }
            directory = (directory as NSString).deletingLastPathComponent
        }
        guard !found.isEmpty else { return nil }
        var merged: [String: String] = [:]
        for (directory, file) in found.reversed() {               // farthest first, so nearer files overwrite
            let relative = String(path.dropFirst(directory == "/" ? 1 : directory.count + 1))
            for section in file.sections where section.glob.matches(relative) {
                for (key, value) in section.values { merged[key] = value == "unset" ? nil : value }
            }
        }
        let properties = EditorConfigProperties(merged)
        return properties.isEmpty ? nil : properties
    }

    private func file(in directory: String) -> EditorConfigFile? {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let known = entries[directory]
        lock.unlock()
        if let known, now - known.checkedAt < EditorConfigStore.recheckAfter { return known.file }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(".editorconfig")
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
        let stamp = values?.isRegularFile == true
            ? "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)" : nil
        var entry = Entry(file: known?.file, stamp: stamp, checkedAt: now)
        if stamp != known?.stamp || known == nil {
            entry.file = stamp == nil ? nil : (try? String(contentsOf: url, encoding: .utf8)).map(EditorConfigFile.init(text:))
        }
        lock.lock()
        entries[directory] = entry
        lock.unlock()
        return entry.file
    }
}

/// How a document is indented: what `.editorconfig` says for it, else the user's settings.
struct Indentation {
    let useSpaces: Bool
    let width: Int
    var unit: String { useSpaces ? String(repeating: " ", count: width) : "\t" }
}

extension TextDocument {
    var indentation: Indentation {
        let settings = Settings.shared
        return Indentation(useSpaces: editorConfig?.useSpaces ?? settings.useSpaces, width: editorConfig?.tabWidth ?? settings.tabWidth)
    }
}

extension CodeTextView {
    /// The indentation of the document this view is editing. Its delegate is the `EditorView` that owns it.
    var indentation: Indentation {
        (delegate as? EditorView)?.document.indentation
            ?? Indentation(useSpaces: Settings.shared.useSpaces, width: Settings.shared.tabWidth)
    }
}
