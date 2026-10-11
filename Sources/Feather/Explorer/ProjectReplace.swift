import Foundation

/// The three switches beside the search field, as VS Code has them.
struct SearchOptions: Equatable {
    var caseSensitive = false
    var wholeWord = false
    var isRegex = false

    /// One regular expression stands for every combination, so the search and the replacement cannot disagree
    /// about what a match is. Nil when the query is not a valid pattern (or is empty).
    func regex(for query: String) -> NSRegularExpression? {
        guard !query.isEmpty else { return nil }
        var pattern = isRegex ? query : NSRegularExpression.escapedPattern(for: query)
        if wholeWord { pattern = "(?<![\\p{L}\\p{N}_])(?:" + pattern + ")(?![\\p{L}\\p{N}_])" }
        var flags: NSRegularExpression.Options = []
        if !caseSensitive { flags.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: pattern, options: flags)
    }
}

/// One line of a file after a replacement, for the preview: what it was and what it becomes.
struct ReplacedLine: Equatable {
    let line: Int              // zero-based
    let old: String
    let new: String
}

/// Everything Replace All would do to one file, worked out before anything is touched.
final class FileReplacement {
    let url: URL
    let relativePath: String
    /// In the text as it was, in order, not overlapping; ready for `TextDocument.apply` or the disk rewrite.
    let edits: [RangeEdit]
    let lines: [ReplacedLine]
    /// The preview's per-file switch. Off means the file is left alone.
    var isKept = true

    init(url: URL, relativePath: String, edits: [RangeEdit], lines: [ReplacedLine]) {
        self.url = url
        self.relativePath = relativePath
        self.edits = edits
        self.lines = lines
    }

    var count: Int { edits.count }
}

/// The replacement half of Search in Project. It works on a whole file's text but only ever changes what lies
/// inside a line, so a file's line endings, encoding and trailing newline come through untouched.
enum ProjectReplace {
    /// The edits that replace the matches in `text`. With `only`, just the matches that start at those places
    /// (one-based line, UTF-16 column in the line), which is how a single result row is replaced.
    static func edits(in text: String, regex: NSRegularExpression, replacement: String, isRegex: Bool,
                      only: Set<MatchPlace>? = nil) -> [RangeEdit] {
        let ns = text as NSString
        var edits: [RangeEdit] = []
        var lineNumber = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            lineNumber += 1
            for match in regex.matches(in: text, options: [], range: lineRange) {
                let range = match.range
                if range.length == 0 { continue }           // an empty match (regex "a*") would only insert text everywhere
                if let only, !only.contains(MatchPlace(line: lineNumber, column: range.location - lineRange.location)) { continue }
                let new = isRegex ? regex.replacementString(for: match, in: text, offset: 0, template: replacement) : replacement
                edits.append(RangeEdit(range: range, text: new))
            }
        }
        return edits
    }

    /// The text with the edits made. The edits are in order and do not overlap, so one pass from the top does it.
    static func apply(_ edits: [RangeEdit], to text: String) -> String {
        guard !edits.isEmpty else { return text }
        let ns = text as NSString
        let result = NSMutableString(capacity: ns.length)
        var position = 0
        for edit in edits {
            result.append(ns.substring(with: NSRange(location: position, length: edit.range.location - position)))
            result.append(edit.text)
            position = NSMaxRange(edit.range)
        }
        result.append(ns.substring(from: position))
        return result as String
    }

    /// The before-and-after of every line the edits touch, for the preview. A replacement that adds a line break
    /// shows as one old line turning into several.
    static func changedLines(in text: String, edits: [RangeEdit]) -> [ReplacedLine] {
        guard !edits.isEmpty else { return [] }
        let ns = text as NSString
        var result: [ReplacedLine] = []
        var lineNumber = -1
        var next = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, lineRange, _, stop in
            lineNumber += 1
            // Every edit lies inside some line's content (matches never take in a line break), and they are in order.
            var inLine: [RangeEdit] = []
            while next < edits.count, edits[next].range.location < NSMaxRange(lineRange) {
                inLine.append(edits[next])
                next += 1
            }
            if !inLine.isEmpty {
                let old = ns.substring(with: lineRange)
                let shifted = inLine.map { RangeEdit(range: NSRange(location: $0.range.location - lineRange.location, length: $0.range.length), text: $0.text) }
                result.append(ReplacedLine(line: lineNumber, old: old, new: apply(shifted, to: old)))
            }
            if next >= edits.count { stop.pointee = true }
        }
        return result
    }

    /// Plans the replacement in one file from its current text (the open document's, or the disk's).
    static func plan(url: URL, relativePath: String, text: String, regex: NSRegularExpression, replacement: String,
                     isRegex: Bool, only: Set<MatchPlace>? = nil) -> FileReplacement? {
        let edits = edits(in: text, regex: regex, replacement: replacement, isRegex: isRegex, only: only)
        guard !edits.isEmpty else { return nil }
        return FileReplacement(url: url, relativePath: relativePath, edits: edits, lines: changedLines(in: text, edits: edits))
    }

    // MARK: - Files on disk

    /// The file as text and the encoding it was read with, the way the editor reads files, so what is written back
    /// is what was there. Nil for a binary file or one too large to search.
    static func read(_ url: URL) -> (text: String, encoding: String.Encoding)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= ProjectSearch.maxFileSize else { return nil }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) {
            return (text, .utf16)
        }
        guard !data.prefix(8192).contains(0) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        if let text = String(data: data, encoding: .isoLatin1) { return (text, .isoLatin1) }
        return nil
    }

    /// Rewrites one file on disk. The edits must have been planned from the text the file holds now; if the file
    /// has changed since, nothing is written and the file is reported.
    static func rewrite(_ replacement: FileReplacement, expecting text: String? = nil) -> Bool {
        guard let (current, encoding) = read(replacement.url) else { return false }
        if let text, text != current { return false }
        for edit in replacement.edits where NSMaxRange(edit.range) > (current as NSString).length { return false }
        let updated = apply(replacement.edits, to: current)
        return (try? updated.write(to: replacement.url, atomically: true, encoding: encoding)) != nil
    }

    /// "12 replacements in 3 files", in the words the buttons and notices use.
    static func summary(count: Int, files: Int) -> String {
        "\(count) replacement\(count == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")"
    }
}

/// Where one match starts: the row's one-based line and its UTF-16 column in that line.
struct MatchPlace: Hashable {
    let line: Int
    let column: Int
}
