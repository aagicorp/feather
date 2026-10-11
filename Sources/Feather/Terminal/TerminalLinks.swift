import Foundation

/// A place in a file that a line of terminal output points at: `src/App.tsx:42:7`, a Java stack frame, a Python
/// traceback line. `line` and `column` are one-based, exactly as they were printed.
struct TerminalLink: Equatable {
    var path: String
    var line: Int?
    var column: Int?
    /// For a Java or Kotlin stack frame: the package as a folder path ("com/acme"), which picks the right
    /// `Foo.java` when a project has several.
    var packagePath: String?
    /// Where in the line the link was found (UTF-16), so a click can be matched to it.
    var range: NSRange
    /// False for a bare word such as `Makefile` or `src`: only worth opening when it turns out to exist.
    var isConfident = true
}

/// Finds file references in one line of terminal output. It only reads text; whether the file exists is for
/// `TerminalLinkResolver` to say, at the moment of the click.
enum TerminalLinkParser {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants, so failing to compile is a programming error caught by the first test run.
        try! NSRegularExpression(pattern: pattern)
    }

    /// Python tracebacks: `File "app/main.py", line 12, in handler`.
    private static let python = regex(#"File "([^"\n]+)", line (\d+)"#)
    /// JVM stack frames: `at com.acme.Foo.bar(Foo.java:123)`, with or without a `java.base/` module prefix.
    private static let javaFrame = regex(#"\bat\s+(?:[\w.$]+/)?((?:[\w$]+\.)+)[\w$<>]+\(([\w$\-]+\.(?:java|kt|kts|scala|groovy)):(\d+)\)"#)
    /// A quoted path, which is how tools print paths with spaces in them.
    private static let quoted = regex(#"(["'])([^"'\n]{2,400})\1"#)
    /// A run of characters that can make up an unquoted path. Colons and parentheses are left out on purpose:
    /// they are what separates the path from its line number.
    private static let token = regex(#"[\w@.+\-~/$\[\]]+"#)
    /// What may follow a path: `:42`, `:42:7`, `(42,7)` (tsc), `:[88,13]` (Maven), `, line 12`, `: line 42, col 7` (ESLint).
    private static let position = regex(#"^(?::(\d+)(?::(\d+))?|\((\d+)[,:](\d+)\)|:\[(\d+),(\d+)\]|[,:]? line (\d+)(?:, col(?:umn)? (\d+))?)"#)
    private static let fileExtension = regex(#"\.[A-Za-z][A-Za-z0-9]{0,7}$"#)

    /// Every reference in the line that looks like a file on its own merits, left to right.
    static func links(in line: String) -> [TerminalLink] {
        allLinks(in: line).filter(\.isConfident)
    }

    /// The reference under a click, if any. This one also answers for bare words (`Makefile`), since the caller
    /// is about to check the disk anyway.
    static func link(in line: String, at utf16Index: Int) -> TerminalLink? {
        allLinks(in: line).first { NSLocationInRange(utf16Index, $0.range) }
    }

    private static func allLinks(in line: String) -> [TerminalLink] {
        let text = line as NSString
        guard text.length > 0, text.length < 4000 else { return [] }       // a minified blob is not a list of paths
        let whole = NSRange(location: 0, length: text.length)
        var found: [TerminalLink] = []
        func overlaps(_ range: NSRange) -> Bool { found.contains { NSIntersectionRange($0.range, range).length > 0 } }
        func number(_ match: NSTextCheckingResult, _ group: Int) -> Int? {
            let range = match.range(at: group)
            return range.location == NSNotFound ? nil : Int(text.substring(with: range))
        }

        for match in python.matches(in: line, range: whole) {
            found.append(TerminalLink(path: text.substring(with: match.range(at: 1)), line: number(match, 2),
                                      column: nil, packagePath: nil, range: match.range))
        }
        for match in javaFrame.matches(in: line, range: whole) where !overlaps(match.range) {
            // "com.acme.Foo$Inner." -> package "com/acme": everything before the class.
            let qualified = text.substring(with: match.range(at: 1)).split(separator: ".")
            let package = qualified.dropLast().joined(separator: "/")
            found.append(TerminalLink(path: text.substring(with: match.range(at: 2)), line: number(match, 3), column: nil,
                                      packagePath: package.isEmpty ? nil : package, range: match.range))
        }
        for match in quoted.matches(in: line, range: whole) where !overlaps(match.range) {
            var path = text.substring(with: match.range(at: 2))
            guard !path.contains("://"), path.contains("/") || hasExtension(path) else { continue }
            var range = match.range
            var place = (line: Int?.none, column: Int?.none)
            // The position is either after the closing quote or inside the quotes with the path.
            if let after = positionSuffix(in: text, at: NSMaxRange(range)) {
                place = (after.line, after.column)
                range.length += after.length
            } else if let colon = path.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) {
                let numbers = path[colon].split(separator: ":").compactMap { Int($0) }
                place = (numbers.first, numbers.count > 1 ? numbers[1] : nil)
                path = String(path[..<colon.lowerBound])
            }
            found.append(TerminalLink(path: path, line: place.line, column: place.column, packagePath: nil, range: range))
        }
        for match in token.matches(in: line, range: whole) where !overlaps(match.range) {
            var range = match.range
            var path = text.substring(with: range)
            // A web address is not a file, wherever in it the click landed. `file://` is the one scheme that is.
            let word = enclosingWord(in: text, around: range)
            var isFileURL = false
            if word.contains("://") {
                guard word.contains("file://"), path.hasPrefix("//") else { continue }
                isFileURL = true
            }
            // "[src/a.ts]" and a sentence's full stop are punctuation around the path, not part of it.
            if path.hasPrefix("["), path.hasSuffix("]"), path.count > 2 {
                path = String(path.dropFirst().dropLast())
                range = NSRange(location: range.location + 1, length: range.length - 2)
            }
            while path.hasSuffix(".") && path != "." && path != ".." {
                path.removeLast()
                range.length -= 1
            }
            guard path.count >= 2, path != "..", path.rangeOfCharacter(from: .letters) != nil else { continue }
            if isFileURL {
                while path.hasPrefix("//") { path.removeFirst() }
                path = path.removingPercentEncoding ?? path
            }
            let suffix = positionSuffix(in: text, at: NSMaxRange(range))
            if let suffix { range.length += suffix.length }
            let confident = path.contains("/") || hasExtension(path)
            found.append(TerminalLink(path: path, line: suffix?.line, column: suffix?.column, packagePath: nil,
                                      range: range, isConfident: confident))
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    private static func hasExtension(_ path: String) -> Bool {
        fileExtension.firstMatch(in: path, range: NSRange(location: 0, length: (path as NSString).length)) != nil
    }

    private static func positionSuffix(in text: NSString, at location: Int) -> (line: Int, column: Int?, length: Int)? {
        guard location < text.length else { return nil }
        let rest = text.substring(with: NSRange(location: location, length: min(40, text.length - location)))
        guard let match = position.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) else { return nil }
        let numbers = (1..<match.numberOfRanges).compactMap { group -> Int? in
            let range = match.range(at: group)
            return range.location == NSNotFound ? nil : Int((rest as NSString).substring(with: range))
        }
        guard let line = numbers.first else { return nil }
        return (line, numbers.count > 1 ? numbers[1] : nil, match.range.length)
    }

    /// The run of non-space characters around `range`, which is where a URL's scheme would be.
    private static func enclosingWord(in text: NSString, around range: NSRange) -> String {
        let spaces = CharacterSet.whitespaces
        func isSpace(_ index: Int) -> Bool { UnicodeScalar(text.character(at: index)).map(spaces.contains) ?? false }
        var start = range.location, end = NSMaxRange(range)
        while start > 0, !isSpace(start - 1) { start -= 1 }
        while end < text.length, !isSpace(end) { end += 1 }
        return text.substring(with: NSRange(location: start, length: end - start))
    }
}

/// Turns a parsed link into a file that exists. Absolute paths and paths under the shell's directory are
/// answered at once; anything else is looked for in the project's file listing, off the main thread.
enum TerminalLinkResolver {
    /// `directories` are tried in order: the shell's working directory first, then the project root.
    static func resolve(_ link: TerminalLink, directories: [URL], projectRoot: URL?, completion: @escaping (URL?) -> Void) {
        if let direct = resolveDirectly(link, directories: directories) { return completion(direct) }
        guard let projectRoot, !link.path.hasPrefix("/"), !link.path.hasPrefix("~") else { return completion(nil) }
        DispatchQueue.global(qos: .userInitiated).async {
            let found = search(for: link, in: ProjectFiles.list(root: projectRoot)).map { projectRoot.appendingPathComponent($0) }
            DispatchQueue.main.async { completion(found) }
        }
    }

    static func resolveDirectly(_ link: TerminalLink, directories: [URL]) -> URL? {
        let path = (link.path as NSString).expandingTildeInPath
        let candidates = path.hasPrefix("/") ? [URL(fileURLWithPath: path)] : directories.map { $0.appendingPathComponent(path) }
        return candidates.first(where: isFile)?.standardizedFileURL
    }

    /// Picks from the project's relative paths: the one that ends with the printed path, and for a stack frame
    /// the one inside the frame's package. Among equals the shortest wins (`src/` before `build/generated/`).
    static func search(for link: TerminalLink, in files: [String]) -> String? {
        var wanted = link.path
        while wanted.hasPrefix("./") { wanted.removeFirst(2) }
        guard !wanted.isEmpty, !wanted.hasPrefix("../") else { return nil }
        let suffix = "/" + wanted
        let matches = files.filter { $0 == wanted || $0.hasSuffix(suffix) }
        guard !matches.isEmpty else { return nil }
        if let package = link.packagePath {
            let inPackage = matches.filter { $0.hasSuffix(package + suffix) }
            if let best = inPackage.min(by: { $0.count < $1.count }) { return best }
        }
        return matches.min { $0.count < $1.count }
    }

    private static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
