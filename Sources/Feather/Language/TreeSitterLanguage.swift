import Foundation
import TreeSitter
import TreeSitterBash
import TreeSitterCSS
import TreeSitterDart
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterKotlin
import TreeSitterPython
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

/// The grammars Feather ships. The raw value names the folder under Resources/queries.
enum TreeSitterLanguage: String, CaseIterable {
    case javascript, typescript, tsx, python, java, dart, kotlin, swift, json, css, html, yaml, bash, go, rust

    fileprivate var entryPoint: OpaquePointer? {
        switch self {
        case .javascript: return tree_sitter_javascript()
        case .typescript: return tree_sitter_typescript()
        case .tsx: return tree_sitter_tsx()
        case .python: return tree_sitter_python()
        case .java: return tree_sitter_java()
        case .dart: return tree_sitter_dart()
        case .kotlin: return tree_sitter_kotlin()
        case .swift: return tree_sitter_swift()
        case .json: return tree_sitter_json()
        case .css: return tree_sitter_css()
        case .html: return tree_sitter_html()
        case .yaml: return tree_sitter_yaml()
        case .bash: return tree_sitter_bash()
        case .go: return tree_sitter_go()
        case .rust: return tree_sitter_rust()
        }
    }

    /// The language an injection query names ("javascript", "js", "css"…), if it is one Feather has.
    static func named(_ name: String) -> TreeSitterLanguage? {
        switch name.lowercased() {
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts": return .typescript
        case "py": return .python
        case "sh", "shell", "zsh": return .bash
        case "yml": return .yaml
        case "kt": return .kotlin
        case "rs": return .rust
        case "golang": return .go
        default: return TreeSitterLanguage(rawValue: name.lowercased())
        }
    }
}

extension Language {
    /// The same language, coloured and folded from a syntax tree when a file has this extension.
    func tree(_ id: TreeSitterLanguage) -> Language {
        var copy = self
        copy.treeSitterLanguage = id
        return copy
    }
}

/// A grammar with its queries, loaded the first time a file of its language is coloured and kept for the run.
/// Nothing is loaded for a language nobody has opened a file in.
final class TreeSitterGrammar {
    let id: TreeSitterLanguage
    /// The `TSLanguage`.
    let language: OpaquePointer
    let highlights: TreeSitterQuery
    let injections: TreeSitterQuery?
    let foldSymbols: FoldSymbols

    /// Off, every file is coloured by the regular expressions; the typing benchmark compares the two.
    static var isEnabled = true

    private static var cache: [TreeSitterLanguage: TreeSitterGrammar?] = [:]
    private static let lock = NSLock()

    /// Which grammars this process has loaded so far.
    static var loaded: [TreeSitterLanguage] {
        lock.lock(); defer { lock.unlock() }
        return cache.values.compactMap { $0?.id }
    }

    static func grammar(for id: TreeSitterLanguage) -> TreeSitterGrammar? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[id] { return cached }
        let grammar = TreeSitterGrammar(id: id)
        cache[id] = .some(grammar)       // a grammar whose queries are missing is not tried again either
        return grammar
    }

    private init?(id: TreeSitterLanguage) {
        guard let language = id.entryPoint, let directory = TreeSitterGrammar.queriesDirectory?.appendingPathComponent(id.rawValue),
              let source = try? String(contentsOf: directory.appendingPathComponent("highlights.scm"), encoding: .utf8),
              let highlights = TreeSitterQuery(language: language, source: source,
                                               kindOf: { TreeSitterGrammar.kind(ofCapture: $0, in: id) }, dropUnknownCaptures: true) else {
            return nil
        }
        self.id = id
        self.language = language
        self.highlights = highlights
        foldSymbols = FoldSymbols(language: language)
        if let source = try? String(contentsOf: directory.appendingPathComponent("injections.scm"), encoding: .utf8) {
            injections = TreeSitterQuery(language: language, source: source, kindOf: { _ in nil }, dropUnknownCaptures: false)
        } else {
            injections = nil
        }
    }

    /// The node kinds folding looks for, as this grammar numbers them.
    struct FoldSymbols {
        /// Anonymous "{", "(" and "[": a node beginning with one is a block.
        let openers: Set<TSSymbol>
        /// What ends a block on a line of its own: brackets, an end tag.
        let closers: Set<TSSymbol>
        /// Named nodes that are blocks without a bracket to show it.
        let blocks: Set<TSSymbol>
        /// Python's suite, whose header is the line its statement starts on.
        let indentedBlock: TSSymbol

        init(language: OpaquePointer) {
            func symbols(_ names: [String], named: Bool) -> Set<TSSymbol> {
                Set(names.map { ts_language_symbol_for_name(language, $0, UInt32($0.utf8.count), named) }.filter { $0 != 0 })
            }
            openers = symbols(["{", "(", "["], named: false)
            closers = symbols(["}", ")", "]"], named: false).union(symbols(["end_tag", "jsx_closing_element"], named: true))
            blocks = symbols(["block", "element", "script_element", "style_element", "jsx_element", "block_mapping_pair",
                              "block_sequence_item", "if_statement", "for_statement", "while_statement", "case_statement",
                              "comment", "block_comment", "multiline_comment"], named: true)
            indentedBlock = ts_language_symbol_for_name(language, "block", 5, true)
        }
    }

    // MARK: - Where the queries are

    /// The app bundle when installed; the project's Resources folder when run straight from `swift build` or in tests.
    static let queriesDirectory: URL? = {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("queries")) }
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("../../../Resources/queries").standardizedFileURL)
        }
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Resources/queries").standardizedFileURL)
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("javascript/highlights.scm").path) }
    }()

    // MARK: - Capture names to token kinds

    /// The capture names the grammars' queries use, in the tree-sitter naming, against Feather's six colours. A name
    /// is looked up whole and then with its last part dropped ("keyword.return" falls back to "keyword"), so a name
    /// here stands for its whole family unless a longer entry says otherwise.
    private static let kinds: [String: TokenKind] = [
        "comment": .comment,
        "string": .string, "character": .string, "escape": .string,
        "number": .number, "float": .number,
        "keyword": .keyword, "conditional": .keyword, "repeat": .keyword, "include": .keyword, "exception": .keyword,
        "storageclass": .keyword, "boolean": .keyword, "constant.builtin": .keyword, "constant.null": .keyword,
        "constant.macro": .keyword, "variable.builtin": .keyword, "tag": .keyword,
        "type": .type, "constructor": .type, "constant": .type, "attribute": .type,
        "function": .function, "method": .function,
    ]

    /// Where a language means something else by a name: JSON and YAML keys are shown like the regex colouring did.
    private static let languageKinds: [TreeSitterLanguage: [String: TokenKind]] = [
        .json: ["string.special.key": .keyword],
        .yaml: ["property": .keyword],
        .css: ["property": .type, "unit": .number, "string.special": .number],
        .bash: ["property": .type],
    ]

    static func kind(ofCapture name: String, in language: TreeSitterLanguage) -> TokenKind? {
        var parts = name.split(separator: ".")
        while !parts.isEmpty {
            let key = parts.joined(separator: ".")
            if let kind = languageKinds[language]?[key] ?? kinds[key] { return kind }
            parts.removeLast()
        }
        return nil
    }
}

/// A compiled query and what Feather makes of it: a token kind per capture id (the captures it has no colour for
/// are switched off, so a cursor never returns them), the predicates of each pattern, and its `#set!` directives.
final class TreeSitterQuery {
    /// The `TSQuery`.
    let pointer: OpaquePointer
    let captureNames: [String]
    /// By capture id.
    let kinds: [TokenKind?]
    /// By pattern index.
    let predicates: [[TreeSitterPredicate]]
    /// By pattern index: "injection.language" → "css" and the like.
    let settings: [[String: String]]

    init?(language: OpaquePointer, source: String, kindOf: (String) -> TokenKind?, dropUnknownCaptures: Bool) {
        var errorOffset: UInt32 = 0
        var errorType = TSQueryErrorNone
        guard let pointer = source.withCString({ ts_query_new(language, $0, UInt32(source.utf8.count), &errorOffset, &errorType) }) else {
            NSLog("Feather: highlight query rejected at byte \(errorOffset) (error \(errorType.rawValue))")
            return nil
        }
        self.pointer = pointer
        let captureCount = Int(ts_query_capture_count(pointer))
        var names: [String] = []
        for id in 0..<captureCount {
            var length: UInt32 = 0
            names.append(ts_query_capture_name_for_id(pointer, UInt32(id), &length).map { String(cString: $0) } ?? "")
        }
        captureNames = names
        kinds = names.map(kindOf)

        let patternCount = Int(ts_query_pattern_count(pointer))
        var predicates: [[TreeSitterPredicate]] = []
        var settings: [[String: String]] = []
        for pattern in 0..<patternCount {
            let (list, set) = TreeSitterQuery.predicates(of: pattern, in: pointer, captureNames: names)
            predicates.append(list)
            settings.append(set)
        }
        self.predicates = predicates
        self.settings = settings

        if dropUnknownCaptures {
            for (id, kind) in kinds.enumerated() where kind == nil {
                // A capture a predicate reads (`@_name` in `(#eq? @_name "hbs")`) must stay, or the test has no text.
                let needed = predicates.contains { $0.contains { $0.captureID == UInt32(id) } }
                if !needed { ts_query_disable_capture(pointer, names[id], UInt32(names[id].utf8.count)) }
            }
        }
    }

    deinit { ts_query_delete(pointer) }

    /// Reads the `(#eq? …)`, `(#match? …)`, `(#any-of? …)` tests and `(#set! …)` directives of one pattern.
    private static func predicates(of pattern: Int, in query: OpaquePointer, captureNames: [String]) -> ([TreeSitterPredicate], [String: String]) {
        var count: UInt32 = 0
        guard let steps = ts_query_predicates_for_pattern(query, UInt32(pattern), &count), count > 0 else { return ([], [:]) }
        var result: [TreeSitterPredicate] = []
        var settings: [String: String] = [:]
        var index = 0
        while index < Int(count) {
            var name: String?
            var strings: [String] = []
            var captures: [UInt32] = []
            while index < Int(count), steps[index].type != TSQueryPredicateStepTypeDone {
                let step = steps[index]
                if step.type == TSQueryPredicateStepTypeCapture {
                    captures.append(step.value_id)
                } else {
                    var length: UInt32 = 0
                    let value = ts_query_string_value_for_id(query, step.value_id, &length).map { String(cString: $0) } ?? ""
                    if name == nil { name = value } else { strings.append(value) }
                }
                index += 1
            }
            index += 1
            guard let name else { continue }
            switch name {
            case "set!":
                // "(#set! injection.language "css")", or a bare flag such as "(#set! injection.combined)".
                if let key = strings.first { settings[key] = strings.count > 1 ? strings[1] : "" }
            case "eq?", "not-eq?":
                guard let capture = captures.first, captures.count == 1, let value = strings.first else { continue }
                let negate = name.hasPrefix("not")
                result.append(TreeSitterPredicate(captureID: capture) { ($0 == value) != negate })
            case "any-of?", "not-any-of?":
                guard let capture = captures.first else { continue }
                let set = Set(strings), negate = name.hasPrefix("not")
                result.append(TreeSitterPredicate(captureID: capture) { set.contains($0) != negate })
            case "match?", "not-match?":
                guard let capture = captures.first, let pattern = strings.first,
                      let test = TreeSitterPredicate.matcher(for: pattern) else { continue }
                let negate = name.hasPrefix("not")
                result.append(TreeSitterPredicate(captureID: capture) { test($0) != negate })
            default:
                // `#is-not? local` needs a scope analysis Feather does not do; such a pattern is taken as matching.
                continue
            }
        }
        return (result, settings)
    }

    /// Whether the pattern's tests pass for this match. `text` gives the characters of a node's range.
    func allows(_ match: TSQueryMatch, text: (NSRange) -> String) -> Bool {
        let list = predicates[Int(match.pattern_index)]
        if list.isEmpty { return true }
        let captures = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
        for predicate in list {
            // A capture missing from the match (an optional part of the pattern) has nothing to test.
            guard let capture = captures.first(where: { $0.index == predicate.captureID }) else { continue }
            let node = capture.node
            let range = NSRange(location: Int(ts_node_start_byte(node)) / 2, length: Int(ts_node_end_byte(node) - ts_node_start_byte(node)) / 2)
            if !predicate.test(text(range)) { return false }
        }
        return true
    }
}

/// One text test of a query pattern: the capture whose text is tested, and the test.
struct TreeSitterPredicate {
    let captureID: UInt32
    let test: (String) -> Bool

    /// `#match?` is run on every identifier in view, so the shapes the grammars use get straight code; anything else
    /// is a real regular expression, remembered per identifier because identifiers repeat.
    static func matcher(for pattern: String) -> ((String) -> Bool)? {
        if pattern == "^[A-Z]" {
            return { first in first.utf16.first.map { $0 >= 0x41 && $0 <= 0x5A } ?? false }
        }
        if pattern == "^[a-z]" || pattern == "^_?[a-z]" {
            let allowsUnderscore = pattern.contains("_?")
            return { text in
                var units = text.utf16.makeIterator()
                guard var unit = units.next() else { return false }
                if allowsUnderscore, unit == 0x5F, let next = units.next() { unit = next }
                return unit >= 0x61 && unit <= 0x7A
            }
        }
        // "^(open|close|len)$": a plain list of words.
        if pattern.hasPrefix("^("), pattern.hasSuffix(")$") {
            let body = pattern.dropFirst(2).dropLast(2)
            let words = body.split(separator: "|", omittingEmptySubsequences: false)
            if words.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" } }) {
                let set = Set(words.map(String.init))
                return { set.contains($0) }
            }
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let memo = Memo()
        return { text in
            if let known = memo.lookup(text) { return known }
            let matched = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
            memo.remember(text, matched)
            return matched
        }
    }

    private final class Memo {
        private var results: [String: Bool] = [:]
        private let lock = NSLock()

        func lookup(_ text: String) -> Bool? {
            lock.lock(); defer { lock.unlock() }
            return results[text]
        }

        func remember(_ text: String, _ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            if results.count > 4096 { results.removeAll(keepingCapacity: true) }
            results[text] = value
        }
    }
}
