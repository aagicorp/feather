import XCTest
@testable import Feather

/// Covers the TODO scanner and the rows of LanguageServer/Problems.swift: which comments count (TODO, FIXME,
/// HACK, XXX, NOTE after a comment marker, never an identifier), where they are, how their text is trimmed
/// and capped, and how files are ordered. The store itself is covered in ProjectCheckerTests.
final class TodoScannerTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/p/a.swift")

    private func items(_ text: String) -> [ProblemItem] { TodoScanner.items(in: text, url: url) }

    func testTagsAfterEveryKindOfCommentMarker() {
        let text = """
        // TODO: one
        # FIXME - two
        /* HACK three */
        <!-- NOTE four -->
        -- XXX five
        % TODO six
        ; NOTE seven
         * TODO eight
        """
        XCTAssertEqual(items(text).map { "\($0.tag ?? ""):\($0.message)" },
                       ["TODO:one", "FIXME:two", "HACK:three", "NOTE:four", "XXX:five", "TODO:six", "NOTE:seven", "TODO:eight"])
    }

    func testIdentifiersAndStringsAreNotComments() {
        XCTAssertEqual(items("let TODO_LIST = 1\nlet s = \"NOTE\"\nfunc hackIt() {}\nTODO: no marker").count, 0)
        XCTAssertEqual(items("// TODOS are not TODO\n").count, 0, "the tag must end at a word boundary")
        XCTAssertEqual(items("").count, 0)
    }

    func testAuthorsAndDecorationsAreStripped() {
        XCTAssertEqual(items("// TODO(alice): call her").first?.message, "call her")
        XCTAssertEqual(items("// @TODO fix me").first?.message, "fix me")
        XCTAssertEqual(items("//TODO:no space").first?.message, "no space")
        XCTAssertEqual(items("// FIXME").first?.message, "")
        XCTAssertEqual(items("// FIXME").first?.fullMessage, "FIXME")
        XCTAssertEqual(items("/* TODO trailing   */").first?.message, "trailing")
        XCTAssertEqual(items("// NOTE: keep this: the colon stays").first?.message, "keep this: the colon stays")
    }

    func testPositionsAreZeroBasedLinesAndUTF16Columns() {
        let text = "first\nsecond // TODO here\n\nlet s = \"😀\" // FIXME after an emoji\n"
        let found = items(text)
        XCTAssertEqual(found.map(\.line), [1, 3])
        XCTAssertEqual(found.map(\.character), [10, 16])
        XCTAssertEqual(found.last?.endCharacter, 16 + 5)
        XCTAssertEqual(found.last?.endLine, 3)
        // Only whitespace may sit between the comment marker and the tag.
        XCTAssertEqual(items("// 😀 FIXME not a tag").count, 0)
        XCTAssertEqual(found.map(\.severity), [0, 0])
        XCTAssertEqual(found.map(\.detail), ["", ""])
    }

    func testCRLFFilesKeepTheirLineNumbers() {
        let found = items("a\r\nb\r\n// TODO x\r\n")
        XCTAssertEqual(found.first?.line, 2)
        XCTAssertEqual(found.first?.message, "x")
    }

    func testALongCommentIsCut() {
        let long = String(repeating: "x", count: 400)
        let message = items("// TODO " + long).first?.message ?? ""
        XCTAssertEqual(message.count, 301)
        XCTAssertTrue(message.hasSuffix("…"))
        XCTAssertEqual(items("// TODO " + String(repeating: "y", count: 300)).first?.message.count, 300)
    }

    func testAtMostFiveHundredPerFile() {
        let text = (0..<600).map { "// TODO item \($0)" }.joined(separator: "\n")
        let found = items(text)
        XCTAssertEqual(found.count, TodoScanner.maxPerFile)
        XCTAssertEqual(found.last?.line, TodoScanner.maxPerFile - 1)
    }

    func testTwoTagsOnOneLineAreBothFound() {
        let found = items("x = 1  // TODO a // FIXME b")
        XCTAssertEqual(found.map(\.tag), ["TODO"])           // the rest of the line belongs to the first comment
        XCTAssertEqual(found.first?.message, "a // FIXME b")
    }

    func testScanningFilesOnDisk() throws {
        let root = TestSupport.temporaryDirectory("feather-todo")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.write(["src/b.swift": "// TODO b\n", "src/a.swift": "no comment\n", "src/über.py": "# FIXME ü\n"], under: root)
        try Data([0x00, 0x01, 0x02, 0xFF]).write(to: root.appendingPathComponent("blob.bin"))
        XCTAssertNil(TodoScanner.scan(file: root.appendingPathComponent("src/a.swift"), relativePath: "src/a.swift"))
        XCTAssertNil(TodoScanner.scan(file: root.appendingPathComponent("missing.swift"), relativePath: "missing.swift"))
        XCTAssertNil(TodoScanner.scan(file: root.appendingPathComponent("blob.bin"), relativePath: "blob.bin"))
        let group = try XCTUnwrap(TodoScanner.scan(file: root.appendingPathComponent("src/über.py"), relativePath: "src/über.py"))
        XCTAssertEqual(group.relativePath, "src/über.py")
        XCTAssertEqual(group.items.map(\.message), ["ü"])
        XCTAssertEqual(group.total, 1)
        XCTAssertEqual(group.hiddenCount, 0)
        let groups = TodoScanner.scan(root: root) { false }
        XCTAssertEqual(groups.map(\.relativePath), ["src/b.swift", "src/über.py"])
        XCTAssertTrue(TodoScanner.scan(root: root) { true }.isEmpty, "cancelled before it started")
    }

    func testFilesAreSortedTheWayTheFinderSortsThem() {
        let groups = ["src/file10.ts", "src/file2.ts", "README.md", "src/File1.ts"].map {
            ProblemGroup(url: url, relativePath: $0, items: [], total: 0)
        }
        XCTAssertEqual(TodoScanner.sorted(groups).map(\.relativePath), ["README.md", "src/File1.ts", "src/file2.ts", "src/file10.ts"])
    }
}

final class ProblemItemTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/p/a.ts")

    func testADiagnosticRowShowsItsFirstLineAndSource() {
        let item = ProblemItem(url: url, diagnostic: LSPDiagnostic(startLine: 3, startCharacter: 1, endLine: 4, endCharacter: 2, severity: 2,
                                                                     message: "first line\nsecond line", source: "ts", code: "2322"))
        XCTAssertEqual(item.message, "first line")
        XCTAssertEqual(item.fullMessage, "first line\nsecond line")
        XCTAssertEqual(item.detail, "ts(2322)")
        XCTAssertEqual([item.line, item.character, item.endLine, item.endCharacter], [3, 1, 4, 2])
        XCTAssertEqual(item.severity, 2)
        XCTAssertNil(item.tag)
    }

    func testDetailWithoutASourceOrCode() {
        func detail(source: String?, code: String?) -> String {
            ProblemItem(url: url, diagnostic: LSPDiagnostic(startLine: 0, startCharacter: 0, endLine: 0, endCharacter: 0, severity: 1,
                                                            message: "m", source: source, code: code)).detail
        }
        XCTAssertEqual(detail(source: nil, code: nil), "")
        XCTAssertEqual(detail(source: "pyright", code: nil), "pyright")
        XCTAssertEqual(detail(source: nil, code: "E1"), "(E1)")
    }

    func testAnEmptyMessageAndLeadingNewlines() {
        let item = ProblemItem(url: url, diagnostic: LSPDiagnostic(startLine: 0, startCharacter: 0, endLine: 0, endCharacter: 0, severity: 1,
                                                                     message: "\n\nlate", source: nil, code: nil))
        XCTAssertEqual(item.message, "late")
        XCTAssertEqual(ProblemItem(url: url, diagnostic: LSPDiagnostic(startLine: 0, startCharacter: 0, endLine: 0, endCharacter: 0,
                                                                        severity: 1, message: "", source: nil, code: nil)).message, "")
    }

    func testACommentRowSpansItsTag() {
        let item = ProblemItem(url: url, tag: "FIXME", text: "soon", line: 9, character: 4)
        XCTAssertEqual(item.fullMessage, "FIXME: soon")
        XCTAssertEqual(item.endCharacter, 9)
        XCTAssertEqual(item.severity, 0)
        XCTAssertEqual(item.detail, "")
    }
}
