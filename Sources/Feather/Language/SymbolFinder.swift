import Foundation

/// Go-to-definition without a language server. It is a careful guess rather than real analysis: follow the
/// import that brought the name in, then look for a declaration in this file, then across the project.
/// A language server, when one is running, is always asked first.
enum SymbolFinder {
    private static let queue = DispatchQueue(label: "feather.symbols", qos: .userInitiated)
    private static let maxFileSize = 1_000_000
    private static let maxFiles = 6_000

    /// Languages that can plausibly declare a symbol used from a file with the given extension.
    private static let families: [Set<String>] = [
        ["ts", "tsx", "js", "jsx", "mjs", "cjs", "vue"], ["py", "pyw"], ["java", "kt", "kts"], ["dart"],
        ["swift"], ["go"], ["rs"], ["c", "h", "cpp", "cc", "cxx", "hpp", "hh", "m", "mm"], ["rb"], ["php"],
    ]

    static func find(_ word: String, from file: URL, text: String, clickedLine: Int, root: URL?,
                     isCancelled: @escaping () -> Bool = { false },
                     completion: @escaping (LSPLocation?) -> Void) {
        guard !word.isEmpty, word.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil else {
            return completion(nil)
        }
        queue.async {
            if isCancelled() { return DispatchQueue.main.async { completion(nil) } }
            let result = importedDefinition(of: word, in: text, file: file, root: root)
                ?? declaration(of: word, in: text, url: file, skippingLine: clickedLine)
                ?? projectDeclaration(of: word, from: file, root: root, isCancelled: isCancelled)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Declarations

    /// `function X`, `const X =`, `class X`, `def X`, `interface X`, … and, second, `ReturnType X(…) {` methods.
    private static func patterns(for word: String) -> [NSRegularExpression] {
        let name = NSRegularExpression.escapedPattern(for: word)
        let modifiers = #"(?:(?:export|default|declare|async|public|private|protected|internal|fileprivate|open|static|final|abstract|override|sealed|data|inline|suspend|pub|unsafe|extern|virtual|const|mutating|required|convenience|lazy|weak)\s+)*"#
        let keywords = "function\\*?|class|interface|type|enum|const|let|var|val|def|fun|func|struct|protocol|trait|fn|mixin|extension|record|namespace|module|typedef|typealias|actor|object|impl"
        return [
            "^[ \\t]*" + modifiers + "(?:" + keywords + ")\\s+" + name + "\\b",
            "^[ \\t]*" + modifiers + #"(?:[\w<>\[\],.?*&:]+\s+)+"# + name + #"\s*\([^;{}]*\)\s*(?:async\*?\s*|throws\s+[\w., ]+\s*|const\s*)?\{"#,
            "^[ \\t]*" + name + #"\s*[:=]\s*(?:async\s*)?(?:function\b|\([^)]*\)\s*(?::\s*[\w<>\[\]|, ]+)?\s*=>)"#,
        ].compactMap { try? NSRegularExpression(pattern: $0, options: [.anchorsMatchLines]) }
    }

    private static func declaration(of word: String, in text: String, url: URL, skippingLine: Int? = nil,
                                    patterns compiled: [NSRegularExpression]? = nil) -> LSPLocation? {
        let ns = text as NSString
        for regex in compiled ?? patterns(for: word) {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let nameRange = ns.range(of: word, options: [.backwards], range: match.range)
                guard nameRange.location != NSNotFound else { continue }
                var line = 0
                var search = NSRange(location: 0, length: nameRange.location)
                while search.length > 0 {                       // count newlines without building the prefix string
                    let found = ns.range(of: "\n", options: .literal, range: search)
                    if found.location == NSNotFound { break }
                    line += 1
                    search = NSRange(location: NSMaxRange(found), length: nameRange.location - NSMaxRange(found))
                }
                if line == skippingLine { continue }        // the click was on the declaration itself
                let lineStart = ns.lineRange(for: NSRange(location: nameRange.location, length: 0)).location
                let column = nameRange.location - lineStart
                return LSPLocation(url: url.standardizedFileURL, line: line, character: column,
                                   endLine: line, endCharacter: column + nameRange.length)
            }
        }
        return nil
    }

    // MARK: - Imports

    private static func importedDefinition(of word: String, in text: String, file: URL, root: URL?) -> LSPLocation? {
        let name = NSRegularExpression.escapedPattern(for: word)
        let directory = file.deletingLastPathComponent()

        // JavaScript / TypeScript: import { A, B as C } from "./x"   |   import X from "./x"   |   const { A } = require("./x")
        let scriptImport = #"(?:import\s+(?:type\s+)?(?:[\w$]+\s*,\s*)?(?:\{[^}]*\b"# + name + #"\b[^}]*\}|\*\s+as\s+"# + name + "|" + name
            + #")\s*(?:,\s*\{[^}]*\})?\s+from|(?:const|let|var)\s+(?:\{[^}]*\b"# + name + #"\b[^}]*\}|"# + name + #")\s*=\s*require\s*\()\s*["']([^"']+)["']"#
        if let module = firstCapture(scriptImport, in: text) {
            for candidate in scriptCandidates(module, directory: directory, root: root) {
                if let found = open(candidate, lookingFor: word) { return found }
            }
        }
        // Python: from pkg.mod import A
        if let module = firstCapture(#"from\s+([\w.]+)\s+import\s+(?:\([^)]*\b"# + name + #"\b[^)]*\)|[^\n]*\b"# + name + #"\b)"#, in: text) {
            let relative = module.replacingOccurrences(of: ".", with: "/")
            var base: URL? = directory
            while let current = base {
                for candidate in [current.appendingPathComponent(relative + ".py"), current.appendingPathComponent(relative + "/__init__.py")] {
                    if let found = open(candidate, lookingFor: word) { return found }
                }
                if current.path == root?.path || current.path == "/" { break }
                base = current.deletingLastPathComponent()
            }
        }
        return nil
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
        return (text as NSString).substring(with: match.range(at: 1))
    }

    /// "./routes" can mean routes.tsx, routes/index.ts, and so on; "@/x" and "~/x" are the usual aliases for src/.
    private static func scriptCandidates(_ module: String, directory: URL, root: URL?) -> [URL] {
        var bases: [URL] = []
        if module.hasPrefix(".") {
            bases.append(directory.appendingPathComponent(module).standardizedFileURL)
        } else if module.hasPrefix("@/") || module.hasPrefix("~/") {
            let rest = String(module.dropFirst(2))
            var current: URL? = directory
            while let folder = current {
                if FileManager.default.fileExists(atPath: folder.appendingPathComponent("package.json").path) {
                    bases += [folder.appendingPathComponent("src/" + rest), folder.appendingPathComponent(rest)]
                    break
                }
                if folder.path == root?.path || folder.path == "/" { break }
                current = folder.deletingLastPathComponent()
            }
        } else {
            return []        // a package from node_modules: not something to open as project code
        }
        let extensions = ["", ".tsx", ".ts", ".jsx", ".js", ".mjs", ".vue", "/index.tsx", "/index.ts", "/index.jsx", "/index.js"]
        return bases.flatMap { base in extensions.map { URL(fileURLWithPath: base.path + $0) } }
    }

    /// The declaration inside `url`; if the file exists but declares it some way we do not recognise
    /// (a re-export, a default export), the top of the file is still the right place to land.
    private static func open(_ url: URL, lookingFor word: String) -> LSPLocation? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return declaration(of: word, in: text, url: url)
            ?? LSPLocation(url: url.standardizedFileURL, line: 0, character: 0, endLine: 0, endCharacter: 0)
    }

    // MARK: - Project search

    private static func projectDeclaration(of word: String, from file: URL, root: URL?,
                                           isCancelled: () -> Bool) -> LSPLocation? {
        guard let root else { return nil }
        let ext = file.pathExtension.lowercased()
        let family = families.first { $0.contains(ext) } ?? [ext]
        let candidates = ProjectFiles.list(root: root, limit: maxFiles, isCancelled: isCancelled)
            .filter { family.contains(($0 as NSString).pathExtension.lowercased()) }
        // A file named after the symbol (AppRoutes.tsx, UserService.java) is the likeliest home for it, so those go first.
        let isNamedAfterSymbol: (String) -> Bool = { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension == word }
        let files = candidates.filter(isNamedAfterSymbol) + candidates.filter { !isNamedAfterSymbol($0) }
        let compiled = patterns(for: word)                  // once, not once per file
        let needle = Data(word.utf8)
        for relative in files {
            if isCancelled() { return nil }
            let url = root.appendingPathComponent(relative)
            if url.standardizedFileURL.path == file.standardizedFileURL.path { continue }
            // Most files do not mention the word at all; a byte search rules them out without decoding them.
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= maxFileSize,
                  data.range(of: needle) != nil, let text = String(data: data, encoding: .utf8),
                  let found = declaration(of: word, in: text, url: url, patterns: compiled) else { continue }
            return found
        }
        return nil
    }
}
