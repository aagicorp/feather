import XCTest
@testable import Feather

final class ProjectReplaceTests: XCTestCase {
    private func replaced(_ text: String, _ query: String, with replacement: String, _ options: SearchOptions = SearchOptions(),
                          only: Set<MatchPlace>? = nil) -> (text: String, count: Int) {
        guard let regex = options.regex(for: query) else { return (text, -1) }
        let edits = ProjectReplace.edits(in: text, regex: regex, replacement: replacement, isRegex: options.isRegex, only: only)
        return (ProjectReplace.apply(edits, to: text), edits.count)
    }

    func testPlainReplacementIgnoresCaseAndCoversEveryLine() {
        let result = replaced("Foo bar\nfoo FOO\nnothing\n", "foo", with: "baz")
        XCTAssertEqual(result.text, "baz bar\nbaz baz\nnothing\n")
        XCTAssertEqual(result.count, 3)
    }

    func testMatchCase() {
        let result = replaced("Foo foo FOO", "foo", with: "x", SearchOptions(caseSensitive: true))
        XCTAssertEqual(result.text, "Foo x FOO")
        XCTAssertEqual(result.count, 1)
    }

    func testWholeWord() {
        let result = replaced("cat category concat cat_x (cat)", "cat", with: "dog", SearchOptions(wholeWord: true))
        XCTAssertEqual(result.text, "dog category concat cat_x (dog)")
        XCTAssertEqual(result.count, 2)
    }

    func testRegexGroups() {
        let result = replaced("mail: ann@example, bob@test\n", #"(\w+)@(\w+)"#, with: "$2 at $1", SearchOptions(isRegex: true))
        XCTAssertEqual(result.text, "mail: example at ann, test at bob\n")
        XCTAssertEqual(result.count, 2)
    }

    func testLiteralReplacementIsNotATemplate() {
        // Without regex mode, "$1" is just text.
        let result = replaced("price", "price", with: "$1.00")
        XCTAssertEqual(result.text, "$1.00")
    }

    func testRegexSpecialCharactersAreLiteralUnlessRegexIsOn() {
        XCTAssertEqual(replaced("a.b axb", "a.b", with: "-").text, "- axb")
        XCTAssertEqual(replaced("a.b axb", "a.b", with: "-", SearchOptions(isRegex: true)).text, "- -")
    }

    func testEmptyMatchesAreSkipped() {
        // "x*" matches the empty string everywhere; only real matches are replaced.
        let result = replaced("axxb", "x*", with: "-", SearchOptions(isRegex: true))
        XCTAssertEqual(result.text, "a-b")
        XCTAssertEqual(result.count, 1)
    }

    func testInvalidRegexIsRejected() {
        XCTAssertNil(SearchOptions(isRegex: true).regex(for: "(unclosed"))
        XCTAssertNil(SearchOptions().regex(for: ""))
    }

    func testCRLFAndFinalNewlineArePreserved() {
        let result = replaced("one foo\r\ntwo foo\r\nfoo", "foo", with: "bar")
        XCTAssertEqual(result.text, "one bar\r\ntwo bar\r\nbar")
        XCTAssertEqual(result.count, 3)
        // A match cannot span a line break, so a regex ending in "." never eats the "\r".
        let dotted = replaced("ab\r\nab\r\n", "b.", with: "X", SearchOptions(isRegex: true))
        XCTAssertEqual(dotted.text, "ab\r\nab\r\n")
        XCTAssertEqual(dotted.count, 0)
    }

    func testOnlyTheChosenMatch() {
        let text = "foo foo\nfoo\n"
        // Line 1, second match (column 4) only.
        let result = replaced(text, "foo", with: "bar", only: [MatchPlace(line: 1, column: 4)])
        XCTAssertEqual(result.text, "foo bar\nfoo\n")
        XCTAssertEqual(result.count, 1)
    }

    func testChangedLinesForThePreview() throws {
        let text = "keep\nfoo here\nkeep\nfoo and foo\n"
        let regex = try XCTUnwrap(SearchOptions().regex(for: "foo"))
        let edits = ProjectReplace.edits(in: text, regex: regex, replacement: "bar", isRegex: false)
        let lines = ProjectReplace.changedLines(in: text, edits: edits)
        XCTAssertEqual(lines, [ReplacedLine(line: 1, old: "foo here", new: "bar here"),
                               ReplacedLine(line: 3, old: "foo and foo", new: "bar and bar")])
    }

    func testRewriteOnDiskKeepsLineEndingsAndEncoding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feather-replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let crlf = root.appendingPathComponent("crlf.txt")
        try Data("alpha foo\r\nbeta foo\r\n".utf8).write(to: crlf)
        let latin = root.appendingPathComponent("latin.txt")
        try "café foo\n".data(using: .isoLatin1)!.write(to: latin)

        let regex = try XCTUnwrap(SearchOptions().regex(for: "foo"))
        for url in [crlf, latin] {
            let (text, _) = try XCTUnwrap(ProjectReplace.read(url))
            let plan = try XCTUnwrap(ProjectReplace.plan(url: url, relativePath: url.lastPathComponent, text: text, regex: regex, replacement: "bar", isRegex: false))
            XCTAssertTrue(ProjectReplace.rewrite(plan, expecting: text))
        }
        XCTAssertEqual(try Data(contentsOf: crlf), Data("alpha bar\r\nbeta bar\r\n".utf8))
        XCTAssertEqual(try Data(contentsOf: latin), "café bar\n".data(using: .isoLatin1))

        // A file that changed since the plan was made is left alone.
        try Data("changed\r\n".utf8).write(to: crlf)
        let stale = FileReplacement(url: crlf, relativePath: "crlf.txt", edits: [RangeEdit(range: NSRange(location: 6, length: 3), text: "x")], lines: [])
        XCTAssertFalse(ProjectReplace.rewrite(stale, expecting: "alpha bar\r\nbeta bar\r\n"))
        XCTAssertEqual(try String(contentsOf: crlf, encoding: .utf8), "changed\r\n")
    }

    func testSearchListsEveryMatchOnALineAndHonoursOptions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feather-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "let cat = category + cat;\nCAT\n".write(to: root.appendingPathComponent("src/a.ts"), atomically: true, encoding: .utf8)
        try "no animals here\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let plain = ProjectSearch.run(root: root, query: "cat", options: SearchOptions()) { false }
        XCTAssertEqual(plain.map(\.relativePath), ["src/a.ts"])
        XCTAssertEqual(plain.first?.matches.map { "\($0.line):\($0.column)" }, ["1:4", "1:10", "1:21", "2:0"])

        let word = ProjectSearch.run(root: root, query: "cat", options: SearchOptions(caseSensitive: true, wholeWord: true)) { false }
        XCTAssertEqual(word.first?.matches.map { "\($0.line):\($0.column)" }, ["1:4", "1:21"])

        let regex = ProjectSearch.run(root: root, query: "cat(egory)?", options: SearchOptions(caseSensitive: true, isRegex: true)) { false }
        XCTAssertEqual(regex.first?.matches.map { "\($0.line):\($0.column):\($0.length)" }, ["1:4:3", "1:10:8", "1:21:3"])
    }
}
