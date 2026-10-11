import Foundation

/// A file's outline without a language server: lines that look like declarations. Like `SymbolFinder`, whose
/// patterns these follow, it is a careful guess; a server's answer is always preferred when there is one.
enum SymbolOutline {
    private static let modifiers = #"(?:(?:export|default|declare|async|public|private|protected|internal|fileprivate|open|static|final|abstract|override|sealed|data|inline|suspend|pub(?:\([a-z]+\))?|unsafe|extern|virtual|mutating|required|convenience|readonly|get|set|@\w+)\s+)*"#
    private static let name = #"([A-Za-z_$][\w$]*)"#
    /// Words that look like a method name in `if (x) {` or `return f(x) {` but are not.
    private static let notNames: Set<String> = ["if", "for", "while", "switch", "catch", "return", "new", "else", "function",
                                                "throw", "await", "do", "try", "with", "super"]
    private static let scriptExtensions: Set<String> = ["ts", "tsx", "js", "jsx", "mjs", "cjs", "vue"]
    private static let noBraceMethods: Set<String> = ["py", "pyw", "rb", "md", "markdown", "mdx", "sh", "bash", "yaml", "yml", "json"]

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    // Each pattern captures (1) the indentation, (2) the declaring keyword or nothing, (3) the name.
    private static let declaration = regex(#"^([ \t]*)"# + modifiers
        + #"(function\*?|class|interface|type|enum|def|fun|func|struct|protocol|trait|fn|mixin|extension|record|namespace|module|mod|typealias|actor|object|impl)\s+(?:\([^)\n]*\)\s*)?"# + name)
    private static let arrowFunction = regex(#"^([ \t]*)(?:export\s+)?(?:default\s+)?(const|let|var)\s+"# + name
        + #"\s*(?::[^=\n]+)?=\s*(?:async\s*)?(?:function\b|\([^)\n]*\)\s*(?::\s*[^=\n]+)?=>|[A-Za-z_$][\w$]*\s*=>)"#)
    // The body may follow on the same line: `fetchAll() { return [] }` is a method too.
    private static let scriptMethod = regex(#"^([ \t]+)"# + modifiers + "()" + name + #"\s*(?:<[^>\n]*>)?\([^)\n]*\)\s*(?::\s*[^{\n]+)?\{"#)
    // The type words before the name stay on one line: `\s+` there would let `package x` two lines up count.
    private static let typedMethod = regex(#"^([ \t]*)"# + modifiers + #"()(?:[\w<>\[\],.?*&:]+[ \t]+)+"# + name
        + #"\s*\([^;{}]*\)\s*(?:async\*?\s*|throws\s+[\w., ]+\s*|const\s*)?\{"#)
    private static let heading = regex(#"^()(#{1,6})[ \t]+(.+?)[ \t#]*$"#)

    static func scan(_ text: String, fileExtension: String) -> [LSPSymbol] {
        let ext = fileExtension.lowercased()
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var patterns: [NSRegularExpression?]
        if ["md", "markdown", "mdx"].contains(ext) {
            patterns = [heading]
        } else if scriptExtensions.contains(ext) {
            patterns = [declaration, arrowFunction, scriptMethod]
        } else {
            patterns = noBraceMethods.contains(ext) ? [declaration] : [declaration, typedMethod]
        }

        // (offset of the name, indentation, keyword, name); one entry per line, the first pattern to claim it wins.
        var found: [Int: (name: NSRange, indent: NSRange, keyword: String)] = [:]
        for pattern in patterns.compactMap({ $0 }) {
            for match in pattern.matches(in: text, range: whole) {
                let nameRange = match.range(at: 3)
                let keywordRange = match.range(at: 2)
                let declared = keywordRange.location != NSNotFound && keywordRange.length > 0
                // `new Foo()` is a call, `fn new()` a declaration: the not-a-name list only guards keyword-less matches.
                guard nameRange.location != NSNotFound, found[match.range.location] == nil,
                      declared || !notNames.contains(ns.substring(with: nameRange)) else { continue }
                if pattern === typedMethod, let first = ns.substring(with: match.range).split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
                   notNames.contains(String(first)) { continue }
                let keyword = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
                found[match.range.location] = (nameRange, match.range(at: 1), keyword)
            }
        }

        // One walk down the file turns offsets into line numbers, however many symbols there are.
        var symbols: [LSPSymbol] = []
        var line = 0, counted = 0
        let tabWidth = max(1, Settings.shared.tabWidth)
        for (lineStart, entry) in found.sorted(by: { $0.key < $1.key }) {
            var search = NSRange(location: counted, length: lineStart - counted)
            while search.length > 0 {
                let newline = ns.range(of: "\n", options: .literal, range: search)
                if newline.location == NSNotFound { break }
                line += 1
                search = NSRange(location: NSMaxRange(newline), length: lineStart - NSMaxRange(newline))
            }
            counted = lineStart
            let indent = ns.substring(with: entry.indent).reduce(0) { $0 + ($1 == "\t" ? tabWidth : 1) }
            let isHeading = entry.keyword.hasPrefix("#")
            let depth = isHeading ? entry.keyword.count - 1 : min(6, indent / tabWidth)
            symbols.append(LSPSymbol(name: ns.substring(with: entry.name), kind: kind(of: entry.keyword, nested: depth > 0),
                                     container: nil, line: line, character: entry.name.location - lineStart, depth: depth))
        }
        return symbols
    }

    /// The LSP SymbolKind nearest to a declaring keyword, so both sources are labelled the same way.
    private static func kind(of keyword: String, nested: Bool) -> Int {
        switch keyword {
        case "class", "object", "actor", "mixin", "record", "impl", "extension": return 5
        case "interface", "protocol", "trait": return 11
        case "enum": return 10
        case "struct": return 23
        case "namespace", "module", "mod": return 3
        case "type", "typealias": return 26
        case "const", "let", "var": return 12
        case "": return 6
        case _ where keyword.hasPrefix("#"): return 0           // a Markdown heading; the name says it all
        default: return nested ? 6 : 12
        }
    }

    /// A short word for an LSP SymbolKind, shown beside the name.
    static func kindName(_ kind: Int) -> String {
        let names = [1: "file", 2: "module", 3: "namespace", 4: "package", 5: "class", 6: "method", 7: "property", 8: "field",
                     9: "constructor", 10: "enum", 11: "interface", 12: "function", 13: "variable", 14: "constant",
                     15: "string", 19: "object", 20: "key", 22: "enum case", 23: "struct", 24: "event", 25: "operator", 26: "type"]
        return names[kind] ?? ""
    }
}
