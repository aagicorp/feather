/// Covers Explorer/ProjectSearch.swift: the text search across a project (case, whole word, regular
/// expressions, the per-file cap, unsaved text taking precedence over the disk, what is skipped, columns as
/// UTF-16 offsets, previews trimmed for the sidebar) and the rows made from language-server references.
import XCTest
@testable import Feather

final class ProjectSearchTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = TestSupport.temporaryDirectory("feather-search")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func run(_ query: String, _ options: SearchOptions = SearchOptions(), openTexts: [URL: String] = [:]) -> [SearchFileResult] {
        ProjectFiles.invalidate(root: root)
        return ProjectSearch.run(root: root, query: query, options: options, openTexts: openTexts) { false }
    }

    private func places(_ result: SearchFileResult?) -> [String] {
        result?.matches.map { "\($0.line):\($0.column):\($0.length)" } ?? []
    }

    func testOptionsChangeWhatCounts() throws {
        try TestSupport.write(["a.txt": "Cat cat category\nconcat\n"], under: root)
        XCTAssertEqual(places(run("cat").first), ["1:0:3", "1:4:3", "1:8:3", "2:3:3"])
        XCTAssertEqual(places(run("cat", SearchOptions(caseSensitive: true)).first), ["1:4:3", "1:8:3", "2:3:3"])
        XCTAssertEqual(places(run("cat", SearchOptions(wholeWord: true)).first), ["1:0:3", "1:4:3"])
        XCTAssertEqual(places(run("c.t(egory)?", SearchOptions(isRegex: true)).first), ["1:0:3", "1:4:3", "1:8:8", "2:3:3"])
        XCTAssertEqual(run("(unclosed", SearchOptions(isRegex: true)).count, 0)
        XCTAssertEqual(run("").count, 0)
        XCTAssertEqual(run("dog").count, 0)
    }

    func testCancellationReturnsNothing() throws {
        try TestSupport.write(["a.txt": "needle\n"], under: root)
        XCTAssertEqual(ProjectSearch.run(root: root, query: "needle", options: SearchOptions()) { true }.count, 0)
    }

    func testMatchesPerFileAreCapped() throws {
        try TestSupport.write(["many.txt": String(repeating: "needle\n", count: 250), "one.txt": "needle\n"], under: root)
        let results = run("needle")
        XCTAssertEqual(results.map(\.relativePath), ["many.txt", "one.txt"])
        XCTAssertEqual(results[0].matches.count, ProjectSearch.maxMatchesPerFile)
        XCTAssertEqual(results[0].matches.last?.line, 200)
        XCTAssertEqual(results[1].matches.count, 1)
    }

    func testUnsavedTextIsSearchedInsteadOfTheDisk() throws {
        try TestSupport.write(["a.txt": "alpha on disk\n", "b.txt": "alpha too\n"], under: root)
        let open = [root.appendingPathComponent("a.txt").standardizedFileURL: "beta typed\nbeta again\n"]
        XCTAssertEqual(run("alpha", openTexts: open).map(\.relativePath), ["b.txt"])
        let beta = run("beta", openTexts: open)
        XCTAssertEqual(beta.map(\.relativePath), ["a.txt"])
        XCTAssertEqual(places(beta.first), ["1:0:4", "2:0:4"])
        XCTAssertEqual(beta.first?.url.lastPathComponent, "a.txt")
    }

    func testBinaryHugeAndUndecodableFilesAreSkipped() throws {
        try TestSupport.write(["image.png": "needle in a png", "plain.txt": "needle\n"], under: root)
        try Data([0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65, 0x00, 0x01]).write(to: root.appendingPathComponent("nul.dat"))
        try "caf\u{E9} needle\n".data(using: .isoLatin1)!.write(to: root.appendingPathComponent("latin1.txt"))
        var huge = Data(repeating: UInt8(ascii: "a"), count: ProjectSearch.maxFileSize + 1)
        huge.append(contentsOf: "needle".utf8)
        try huge.write(to: root.appendingPathComponent("huge.txt"))
        XCTAssertEqual(run("needle").map(\.relativePath), ["plain.txt"])
        XCTAssertNil(ProjectSearch.searchableText(at: root.appendingPathComponent("image.png")))
        XCTAssertNil(ProjectSearch.searchableText(at: root.appendingPathComponent("nul.dat")))
        XCTAssertNil(ProjectSearch.searchableText(at: root.appendingPathComponent("huge.txt")))
        XCTAssertNil(ProjectSearch.searchableText(at: root.appendingPathComponent("latin1.txt")))
        XCTAssertEqual(ProjectSearch.searchableText(at: root.appendingPathComponent("plain.txt")), "needle\n")
    }

    func testLineEndingsAndUnicodeColumns() throws {
        try TestSupport.write(["crlf.txt": "one needle\r\ntwo needle\r\nthree", "uni.txt": "😀 needle\nhéllo needle\n"], under: root)
        let crlf = run("needle").first { $0.relativePath == "crlf.txt" }
        XCTAssertEqual(places(crlf), ["1:4:6", "2:4:6"])
        XCTAssertEqual(crlf?.matches.map(\.preview), ["one needle", "two needle"], "no stray carriage return in the preview")
        let uni = run("needle").first { $0.relativePath == "uni.txt" }
        XCTAssertEqual(places(uni), ["1:3:6", "2:6:6"], "columns are UTF-16 offsets, as the editor counts them")
        XCTAssertEqual(uni?.matches.first?.previewHighlight, NSRange(location: 3, length: 6))
    }

    func testPreviewsAreTrimmedForTheSidebar() throws {
        let far = String(repeating: "x", count: 60) + "needle" + String(repeating: "y", count: 300)
        try TestSupport.write(["a.txt": "        needle indented\n\(far)\n"], under: root)
        let matches = try XCTUnwrap(run("needle").first).matches
        XCTAssertEqual(matches[0].preview, "needle indented")
        XCTAssertEqual(matches[0].column, 8, "the column is in the real line")
        XCTAssertEqual(matches[0].previewHighlight, NSRange(location: 0, length: 6))
        XCTAssertTrue(matches[1].preview.hasPrefix("…" + String(repeating: "x", count: 30) + "needle"))
        XCTAssertEqual(matches[1].preview.count, 1 + 220)
        XCTAssertEqual(matches[1].previewHighlight, NSRange(location: 31, length: 6))
        XCTAssertEqual(matches[1].column, 60)
    }

    func testEmptyMatchesAreNotListed() throws {
        try TestSupport.write(["a.txt": "abc\n"], under: root)
        XCTAssertEqual(run("x*", SearchOptions(isRegex: true)).count, 0)
        XCTAssertEqual(places(run("b*", SearchOptions(isRegex: true)).first), ["1:1:1"])
    }

    func testFilesAreListedInFinderOrder() throws {
        try TestSupport.write(["file10.txt": "needle", "file2.txt": "needle", "src/a.txt": "needle", "Alpha.txt": "needle"], under: root)
        XCTAssertEqual(run("needle").map(\.relativePath), ["Alpha.txt", "file2.txt", "file10.txt", "src/a.txt"])
    }

    func testTheOldEntryPointStillTakesACaseFlag() throws {
        try TestSupport.write(["a.txt": "Needle needle\n"], under: root)
        ProjectFiles.invalidate(root: root)
        XCTAssertEqual(places(ProjectSearch.run(root: root, query: "needle", caseSensitive: true) { false }.first), ["1:7:6"])
    }

    func testReferencesBecomeTheSameRowsAsATextSearch() throws {
        let a = root.appendingPathComponent("src/a.ts"), b = root.appendingPathComponent("b.ts")
        let texts = [a: "  let value = 1\nuse(value)\n", b: "value\n"]
        let locations = [
            LSPLocation(url: b, line: 0, character: 0, endLine: 0, endCharacter: 5),
            LSPLocation(url: a, line: 1, character: 4, endLine: 1, endCharacter: 9),
            LSPLocation(url: a, line: 0, character: 6, endLine: 0, endCharacter: 11),
            LSPLocation(url: a, line: 0, character: 6, endLine: 3, endCharacter: 2),     // spans lines: to the end of its line
            LSPLocation(url: a, line: 9, character: 0, endLine: 9, endCharacter: 1),     // beyond the text: dropped
            LSPLocation(url: a, line: 1, character: 50, endLine: 1, endCharacter: 60),   // beyond the line: clamped
        ]
        let results = ProjectSearch.results(for: locations, root: root) { texts[$0] }
        XCTAssertEqual(results.map(\.relativePath), ["b.ts", "src/a.ts"])
        XCTAssertEqual(places(results[1]), ["2:4:5", "1:6:5", "1:6:9", "2:10:0"])
        XCTAssertEqual(results[1].matches[1].preview, "let value = 1")
        XCTAssertEqual(results[1].matches[1].previewHighlight, NSRange(location: 4, length: 5))
        XCTAssertEqual(places(results[0]), ["1:0:5"])
        // Outside the project the whole path is shown; without a root too.
        XCTAssertEqual(ProjectSearch.results(for: [locations[0]], root: URL(fileURLWithPath: "/elsewhere")) { texts[$0] }.first?.relativePath, b.path)
        XCTAssertEqual(ProjectSearch.results(for: [locations[0]], root: nil) { _ in nil }.first?.matches.count, 1)
    }
}
