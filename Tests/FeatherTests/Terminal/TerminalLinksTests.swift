import XCTest
@testable import Feather

/// Covers Terminal/TerminalLinks.swift: finding file references in a line of terminal output (paths with line
/// and column in every format the common tools print, quoted paths, Python and JVM stack frames, punctuation
/// around a path, web addresses left alone) and resolving them to files that exist.
final class TerminalLinkParserTests: XCTestCase {
    private func first(_ line: String) -> TerminalLink? { TerminalLinkParser.links(in: line).first }

    func testRelativePathWithLineAndColumn() {
        let link = first("src/App.tsx:42:7 - error TS2322")
        XCTAssertEqual(link?.path, "src/App.tsx")
        XCTAssertEqual(link?.line, 42)
        XCTAssertEqual(link?.column, 7)
        XCTAssertEqual(link?.range, NSRange(location: 0, length: 16))
        XCTAssertTrue(link?.isConfident == true)
    }

    func testAbsolutePathAndLineOnly() {
        let link = first("  /Users/me/proj/Sources/main.swift:3: warning: x")
        XCTAssertEqual(link?.path, "/Users/me/proj/Sources/main.swift")
        XCTAssertEqual(link?.line, 3)
        XCTAssertNil(link?.column)
    }

    func testTildePath() {
        let link = first("saved to ~/notes/today.md")
        XCTAssertEqual(link?.path, "~/notes/today.md")
        XCTAssertNil(link?.line)
    }

    func testTscAndMavenAndESLintPositions() {
        XCTAssertEqual(first("src/app.ts(12,5): error TS2322").map { [$0.line, $0.column] }, [12, 5])
        XCTAssertEqual(first("[ERROR] /p/App.java:[88,13] cannot find symbol").map { [$0.path, "\($0.line ?? 0)", "\($0.column ?? 0)"] },
                       ["/p/App.java", "88", "13"])
        XCTAssertEqual(first("src/a.js: line 42, col 7, Error - x").map { [$0.line, $0.column] }, [42, 7])
        XCTAssertEqual(first("src/a.js: line 42, column 7").map { [$0.line, $0.column] }, [42, 7])
    }

    func testPythonTraceback() {
        let links = TerminalLinkParser.links(in: #"  File "app/main.py", line 12, in handler"#)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].path, "app/main.py")
        XCTAssertEqual(links[0].line, 12)
        XCTAssertNil(links[0].column)
    }

    func testJavaStackFrameCarriesThePackage() {
        let plain = first("\tat com.acme.Foo$Inner.bar(Foo.java:123)")
        XCTAssertEqual(plain?.path, "Foo.java")
        XCTAssertEqual(plain?.line, 123)
        XCTAssertEqual(plain?.packagePath, "com/acme")
        let modular = first("\tat java.base/java.util.ArrayList.get(ArrayList.java:427)")
        XCTAssertEqual(modular?.path, "ArrayList.java")
        XCTAssertEqual(modular?.packagePath, "java/util")
        let kotlin = first("\tat MainKt.main(Main.kt:4)")
        XCTAssertEqual(kotlin?.path, "Main.kt")
        XCTAssertNil(kotlin?.packagePath)
    }

    func testQuotedPathsMayHoldSpacesAndAPosition() {
        XCTAssertEqual(first("open 'my docs/read me.txt' first")?.path, "my docs/read me.txt")
        let inside = first(#"error in "src/a.ts:12:3""#)
        XCTAssertEqual(inside?.path, "src/a.ts")
        XCTAssertEqual(inside?.line, 12)
        XCTAssertEqual(inside?.column, 3)
        let after = first(#""src/a.ts":12 is wrong"#)
        XCTAssertEqual(after?.path, "src/a.ts")
        XCTAssertEqual(after?.line, 12)
        XCTAssertNil(after?.column)
        // A quoted word that is not a path is not a link.
        XCTAssertNil(first(#"expected "foo" here"#))
    }

    func testTrailingPunctuationAndBracketsAreNotPartOfThePath() {
        XCTAssertEqual(first("see src/a.ts.")?.path, "src/a.ts")
        XCTAssertEqual(first("changed [src/a.ts]")?.path, "src/a.ts")
        XCTAssertEqual(first("changed [src/a.ts]")?.range, NSRange(location: 9, length: 8))
        XCTAssertEqual(first("wrote src/a.ts, then src/b.ts")?.path, "src/a.ts")
        XCTAssertEqual(TerminalLinkParser.links(in: "wrote src/a.ts, then src/b.ts").map(\.path), ["src/a.ts", "src/b.ts"])
    }

    func testWebAddressesAreNotFiles() {
        XCTAssertEqual(TerminalLinkParser.links(in: "Local: http://localhost:5173/src/main.tsx"), [])
        XCTAssertEqual(TerminalLinkParser.links(in: "see https://example.com/docs/guide.html for more"), [])
        // file:// is the one scheme that is a file.
        let link = first("file:///tmp/some-dir/a.txt")
        XCTAssertEqual(link?.path, "/tmp/some-dir/a.txt")
    }

    func testBareWordsOnlyAnswerAClick() {
        XCTAssertEqual(TerminalLinkParser.links(in: "run make in src"), [])
        let clicked = TerminalLinkParser.link(in: "edit Makefile now", at: 6)
        XCTAssertEqual(clicked?.path, "Makefile")
        XCTAssertEqual(clicked?.isConfident, false)
        XCTAssertEqual(TerminalLinkParser.link(in: "edit Makefile now", at: 15)?.path, "now")     // any word, once clicked
        XCTAssertNil(TerminalLinkParser.link(in: "edit Makefile now", at: 4))                   // the space between
        XCTAssertNil(TerminalLinkParser.link(in: "edit Makefile now", at: 13))
    }

    func testClickIsMatchedToTheWholeLinkIncludingItsPosition() {
        let line = "at src/App.tsx:42:7 and more"
        XCTAssertEqual(TerminalLinkParser.link(in: line, at: 16)?.path, "src/App.tsx")     // inside ":42:7"
        XCTAssertEqual(TerminalLinkParser.link(in: line, at: 4)?.path, "src/App.tsx")
    }

    func testNumbersAndDotsAloneAreNotPaths() {
        XCTAssertEqual(TerminalLinkParser.links(in: "12:30 ... 3.14 .. ."), [])
        XCTAssertEqual(TerminalLinkParser.links(in: ""), [])
    }

    func testAMinifiedBlobIsIgnored() {
        let blob = String(repeating: "src/a.ts:1:1 ", count: 400)
        XCTAssertEqual(TerminalLinkParser.links(in: blob), [])
    }

    func testNonASCIIPaths() {
        let link = first("wrote docs/über/résumé.md:2")
        XCTAssertEqual(link?.path, "docs/über/résumé.md")
        XCTAssertEqual(link?.line, 2)
        XCTAssertEqual(link?.range, NSRange(location: 6, length: 21))
    }
}

final class TerminalLinkResolverTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = TestSupport.temporaryDirectory("feather-links")
        try TestSupport.write([
            "src/main/java/com/acme/App.java": "class App {}\n",
            "build/generated/com/other/App.java": "class App {}\n",
            "src/a.ts": "",
            "docs/über.md": "# ü\n",
            "sub/note.txt": "n\n",
        ], under: root)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func link(_ path: String, package: String? = nil) -> TerminalLink {
        TerminalLink(path: path, line: nil, column: nil, packagePath: package, range: NSRange(location: 0, length: 1))
    }

    func testAbsoluteAndRelativePathsAreAnsweredAtOnce() {
        XCTAssertEqual(TerminalLinkResolver.resolveDirectly(link(root.appendingPathComponent("src/a.ts").path), directories: [])?.path,
                       root.appendingPathComponent("src/a.ts").path)
        XCTAssertEqual(TerminalLinkResolver.resolveDirectly(link("note.txt"), directories: [root.appendingPathComponent("sub"), root])?.path,
                       root.appendingPathComponent("sub/note.txt").path)
        XCTAssertEqual(TerminalLinkResolver.resolveDirectly(link("docs/über.md"), directories: [root])?.path, root.appendingPathComponent("docs/über.md").path)
        XCTAssertNil(TerminalLinkResolver.resolveDirectly(link("missing.ts"), directories: [root]))
        // A folder is not a file to open.
        XCTAssertNil(TerminalLinkResolver.resolveDirectly(link("src"), directories: [root]))
    }

    func testTheAnswerIsStandardised() throws {
        // /private/tmp and /tmp are the same place; the answer is spelled the way the rest of Feather spells it
        // (standardised), whichever way the shell printed it.
        let tmp = URL(fileURLWithPath: "/private/tmp/feather-links-\(UUID().uuidString)", isDirectory: true)
        try TestSupport.write(["src/a.ts": ""], under: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let expected = tmp.appendingPathComponent("src/a.ts").standardizedFileURL.path
        XCTAssertEqual(TerminalLinkResolver.resolveDirectly(link("src/a.ts"), directories: [tmp])?.path, expected)
        XCTAssertEqual(TerminalLinkResolver.resolveDirectly(link("/tmp/\(tmp.lastPathComponent)/src/a.ts"), directories: [])?.path, expected)
        XCTAssertTrue(expected.hasPrefix("/tmp/"))
    }

    func testSearchPicksTheShortestMatchAndHonoursThePackage() {
        let files = ["build/generated/com/other/App.java", "src/main/java/com/acme/App.java", "src/App.tsx", "other/src/App.tsx"]
        XCTAssertEqual(TerminalLinkResolver.search(for: link("App.tsx"), in: files), "src/App.tsx")
        XCTAssertEqual(TerminalLinkResolver.search(for: link("./src/App.tsx"), in: files), "src/App.tsx")
        XCTAssertEqual(TerminalLinkResolver.search(for: link("App.java", package: "com/acme"), in: files), "src/main/java/com/acme/App.java")
        XCTAssertEqual(TerminalLinkResolver.search(for: link("App.java", package: "com/other"), in: files), "build/generated/com/other/App.java")
        // An unknown package still finds something rather than nothing.
        XCTAssertEqual(TerminalLinkResolver.search(for: link("App.java", package: "org/x"), in: files), "src/main/java/com/acme/App.java")
        XCTAssertNil(TerminalLinkResolver.search(for: link("../App.tsx"), in: files))
        XCTAssertNil(TerminalLinkResolver.search(for: link("pp.tsx"), in: files))       // a suffix must start at a "/"
        XCTAssertNil(TerminalLinkResolver.search(for: link(""), in: files))
    }

    func testResolveFallsBackToTheProjectListing() {
        var answer: URL??
        TerminalLinkResolver.resolve(link("App.java", package: "com/acme"), directories: [root.appendingPathComponent("sub")], projectRoot: root) { answer = .some($0) }
        XCTAssertTrue(TestSupport.wait { answer != nil })
        XCTAssertEqual(answer??.path, root.appendingPathComponent("src/main/java/com/acme/App.java").path)
    }

    func testResolveGivesUpOnAbsoluteAndMissingPaths() {
        var answers: [URL?] = []
        TerminalLinkResolver.resolve(link("/nowhere/at/all.ts"), directories: [root], projectRoot: root) { answers.append($0) }
        TerminalLinkResolver.resolve(link("nothing-like-this.ts"), directories: [root], projectRoot: root) { answers.append($0) }
        TerminalLinkResolver.resolve(link("a.ts"), directories: [root], projectRoot: nil) { answers.append($0) }
        XCTAssertTrue(TestSupport.wait { answers.count == 3 })
        XCTAssertEqual(answers.compactMap { $0 }, [])
    }
}
