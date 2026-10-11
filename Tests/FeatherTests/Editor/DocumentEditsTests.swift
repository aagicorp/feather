import XCTest
@testable import Feather

/// Covers `DocumentEdits` (Editor/DocumentEdits.swift): normalising a formatter's edits down to what really
/// changes, mapping a caret through them, the inverse batch that undoes them, and the tidying done on save.
final class DocumentEditsTests: XCTestCase {
    private func normalised(_ edits: [(NSRange, String)], in text: String) -> [RangeEdit]? {
        DocumentEdits.normalised(edits, in: text as NSString)
    }

    private func apply(_ edits: [RangeEdit], to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in edits.reversed() { result.replaceCharacters(in: edit.range, with: edit.text) }
        return result as String
    }

    // MARK: - normalised

    func testEditsAreOrderedAndNoOpsDropped() {
        let text = "abc def"
        let edits = normalised([(NSRange(location: 4, length: 3), "xyz"), (NSRange(location: 0, length: 3), "abc"),
                                (NSRange(location: 3, length: 1), " ")], in: text)
        XCTAssertEqual(edits, [RangeEdit(range: NSRange(location: 4, length: 3), text: "xyz")])
    }

    func testWholeFileReplacementIsCutDownToTheDifference() {
        let text = "line one\nline two\nline three\n"
        let edits = normalised([(NSRange(location: 0, length: (text as NSString).length), "line one\nline 2\nline three\n")], in: text)
        XCTAssertEqual(edits, [RangeEdit(range: NSRange(location: 14, length: 3), text: "2")])
        XCTAssertEqual(apply(edits ?? [], to: text), "line one\nline 2\nline three\n")
    }

    func testCommonPrefixAndSuffixDoNotOverlap() {
        // "aa" -> "aaa": the prefix takes both characters, so the suffix must not count them again.
        let edits = normalised([(NSRange(location: 0, length: 2), "aaa")], in: "aa")
        XCTAssertEqual(edits, [RangeEdit(range: NSRange(location: 2, length: 0), text: "a")])
        let shrink = normalised([(NSRange(location: 0, length: 3), "aa")], in: "aaa")
        XCTAssertEqual(shrink, [RangeEdit(range: NSRange(location: 2, length: 1), text: "")])
    }

    func testInsertionsAtOnePlaceBecomeOne() {
        let edits = normalised([(NSRange(location: 2, length: 0), "x"), (NSRange(location: 2, length: 0), "y")], in: "abcd")
        XCTAssertEqual(edits, [RangeEdit(range: NSRange(location: 2, length: 0), text: "xy")])
    }

    func testOverlappingOrOutOfRangeEditsAreRejected() {
        XCTAssertNil(normalised([(NSRange(location: 0, length: 3), "x"), (NSRange(location: 2, length: 2), "y")], in: "abcdef"))
        XCTAssertNil(normalised([(NSRange(location: 4, length: 3), "x")], in: "abcdef"))
        XCTAssertEqual(normalised([], in: ""), [])
        XCTAssertEqual(normalised([(NSRange(location: 0, length: 0), "")], in: ""), [])
    }

    func testNormalisedWorksInUTF16Units() {
        let text = "😀 café"
        let edits = normalised([(NSRange(location: 0, length: 7), "😀 cafés")], in: text)
        XCTAssertEqual(edits, [RangeEdit(range: NSRange(location: 7, length: 0), text: "s")])
    }

    // MARK: - map

    func testMapShiftsACaretPastEarlierEdits() {
        let edits = [RangeEdit(range: NSRange(location: 2, length: 2), text: "12345"),       // +3
                     RangeEdit(range: NSRange(location: 10, length: 4), text: "")]           // -4
        XCTAssertEqual(DocumentEdits.map(1, through: edits).location, 1)
        XCTAssertEqual(DocumentEdits.map(2, through: edits).location, 2)         // at the edit's start: before it
        XCTAssertEqual(DocumentEdits.map(6, through: edits).location, 9)
        XCTAssertEqual(DocumentEdits.map(20, through: edits).location, 19)
        XCTAssertFalse(DocumentEdits.map(20, through: edits).rewritten)
        XCTAssertEqual(DocumentEdits.map(5, through: []).location, 5)
    }

    func testCaretInsideAReplacementStaysInsideAndSaysSoForMultiLineText() {
        let single = [RangeEdit(range: NSRange(location: 2, length: 4), text: "ab")]
        let inside = DocumentEdits.map(5, through: single)
        XCTAssertEqual(inside.location, 4)                   // clamped to the end of the shorter replacement
        XCTAssertFalse(inside.rewritten)
        let multi = [RangeEdit(range: NSRange(location: 2, length: 4), text: "a\nb\nc")]
        let rewritten = DocumentEdits.map(3, through: multi)
        XCTAssertEqual(rewritten.location, 3)
        XCTAssertTrue(rewritten.rewritten)
    }

    // MARK: - inverse

    func testInverseGivesBackTheOriginal() {
        let text = "one two three four"
        let edits = [RangeEdit(range: NSRange(location: 0, length: 3), text: "1"),
                     RangeEdit(range: NSRange(location: 8, length: 0), text: "inserted "),
                     RangeEdit(range: NSRange(location: 14, length: 4), text: "")]
        let edited = apply(edits, to: text)
        XCTAssertEqual(edited, "1 two inserted three ")
        let inverse = DocumentEdits.inverse(of: edits, in: text as NSString)
        XCTAssertEqual(inverse, [RangeEdit(range: NSRange(location: 0, length: 1), text: "one"),
                                 RangeEdit(range: NSRange(location: 6, length: 9), text: ""),
                                 RangeEdit(range: NSRange(location: 21, length: 0), text: "four")])
        XCTAssertEqual(apply(inverse, to: edited), text)
        XCTAssertEqual(DocumentEdits.inverse(of: [], in: ""), [])
    }

    // MARK: - tidyingForSave

    private func tidy(_ text: String, trim: Bool = true, newline: Bool = true) -> String {
        apply(DocumentEdits.tidyingForSave(text as NSString, trimTrailingWhitespace: trim, insertFinalNewline: newline), to: text)
    }

    func testTrailingWhitespaceGoesAndAFinalNewlineComes() {
        XCTAssertEqual(tidy("a  \nb\t\n  c "), "a\nb\n  c\n")
        XCTAssertEqual(tidy("a  \nb", trim: false), "a  \nb\n")
        XCTAssertEqual(tidy("a  \nb", newline: false), "a\nb")
        XCTAssertEqual(tidy("a\n"), "a\n")
        XCTAssertEqual(DocumentEdits.tidyingForSave("a\n", trimTrailingWhitespace: true, insertFinalNewline: true), [])
    }

    func testTidyingHandlesEmptyTextBlankLinesAndCRLF() {
        XCTAssertEqual(DocumentEdits.tidyingForSave("", trimTrailingWhitespace: true, insertFinalNewline: true), [])
        XCTAssertEqual(tidy("   \n\t\n"), "\n\n")
        XCTAssertEqual(tidy("a \r\nb \r\n"), "a\r\nb\r\n")            // the CR belongs to the line ending, not the content
        XCTAssertEqual(tidy("a \r\nb"), "a\r\nb\n")
        XCTAssertEqual(tidy("日本 \n"), "日本\n")
    }

    func testTidyingEditsAreInDocumentOrderAndDoNotTouchOtherLines() {
        let edits = DocumentEdits.tidyingForSave("x \ny\nz  " as NSString, trimTrailingWhitespace: true, insertFinalNewline: true)
        XCTAssertEqual(edits, [RangeEdit(range: NSRange(location: 1, length: 1), text: ""),
                               RangeEdit(range: NSRange(location: 6, length: 2), text: ""),
                               RangeEdit(range: NSRange(location: 8, length: 0), text: "\n")])
    }
}
