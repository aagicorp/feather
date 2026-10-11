import XCTest
@testable import Feather

/// Covers LanguageServer/DocumentSync.swift: the one edit that turns the text a server has into the text the
/// editor has, kept as small as the unchanged beginning and end allow, with positions in UTF-16 and line
/// endings and surrogate pairs never split.
final class DocumentSyncTests: XCTestCase {
    private func edit(_ old: String, _ new: String) -> DocumentEdit? {
        DocumentSync.edit(from: DocumentSync.utf16(old), to: DocumentSync.utf16(new))
    }

    private func place(_ edit: DocumentEdit?) -> [Int] {
        edit.map { [$0.startLine, $0.startCharacter, $0.endLine, $0.endCharacter] } ?? []
    }

    func testUTF16Units() {
        XCTAssertEqual(DocumentSync.utf16("aé😀"), [0x61, 0xE9, 0xD83D, 0xDE00])
        XCTAssertEqual(DocumentSync.utf16(""), [])
    }

    func testTheSameTextIsNoEdit() {
        XCTAssertNil(edit("", ""))
        XCTAssertNil(edit("abc\n", "abc\n"))
    }

    func testTypingInTheMiddleIsAnInsertion() {
        // The unchanged beginning is as long as it can be, so the new "y" is reported after the old one.
        let typed = edit("let x = 1\nlet y = 2\n", "let x = 1\nlet yy = 2\n")
        XCTAssertEqual(place(typed), [1, 5, 1, 5])
        XCTAssertEqual(typed?.text, "y")
        XCTAssertEqual(typed?.oldRange, NSRange(location: 15, length: 0))
        XCTAssertEqual(typed?.newLength, 1)
    }

    func testDeletingAndReplacing() {
        let deleted = edit("abc\ndef\n", "abc\nef\n")
        XCTAssertEqual(place(deleted), [1, 0, 1, 1])
        XCTAssertEqual(deleted?.text, "")
        let replaced = edit("one two three", "one 2 three")
        XCTAssertEqual(place(replaced), [0, 4, 0, 7])
        XCTAssertEqual(replaced?.text, "2")
    }

    func testAppendingAndPrepending() {
        let appended = edit("a\nb", "a\nb\nc")
        XCTAssertEqual(place(appended), [1, 1, 1, 1])
        XCTAssertEqual(appended?.text, "\nc")
        let prepended = edit("a", "xa")
        XCTAssertEqual(place(prepended), [0, 0, 0, 0])
        XCTAssertEqual(prepended?.text, "x")
        let emptied = edit("a\nb", "")
        XCTAssertEqual(place(emptied), [0, 0, 1, 1])
        XCTAssertEqual(emptied?.text, "")
        let filled = edit("", "x\ny")
        XCTAssertEqual(place(filled), [0, 0, 0, 0])
        XCTAssertEqual(filled?.text, "x\ny")
    }

    func testAWholeRewriteIsOneEdit() {
        let old = "alpha\nbeta\ngamma", new = "changed!"
        let whole = edit(old, new)
        XCTAssertEqual(place(whole), [0, 0, 2, 5])
        XCTAssertEqual(whole?.text, "changed!")
        XCTAssertEqual(whole?.oldRange, NSRange(location: 0, length: old.utf16.count))
    }

    func testLinesAreCountedForEveryKindOfLineEnding() {
        XCTAssertEqual(place(edit("a\nb\nc", "a\nb\nX")), [2, 0, 2, 1])
        XCTAssertEqual(place(edit("a\r\nb\r\nc", "a\r\nb\r\nX")), [2, 0, 2, 1])
        // After a lone "\r" servers disagree about the line, so the edit starts before it (see below).
        XCTAssertEqual(place(edit("a\rb\rc", "a\rb\rX")), [1, 1, 2, 1])
    }

    func testAnEditNeverStartsInsideCRLF() {
        // Turning "\r\n" into "\n": the edit covers the whole line ending, not just the "\r".
        let unix = edit("ab\r\ncd", "ab\ncd")
        XCTAssertEqual(place(unix), [0, 2, 1, 0])
        XCTAssertEqual(unix?.text, "\n")
        // Inserting a "\r" in front of "\r\n" would otherwise start between the two.
        let doubled = edit("a\r\n", "a\r\r\n")
        XCTAssertEqual(place(doubled), [0, 1, 0, 1])
        XCTAssertEqual(doubled?.text, "\r")
        // After a lone "\r" is ambiguous too; the edit backs up to include it.
        let lone = edit("a\rb", "a\rc")
        XCTAssertEqual(place(lone), [0, 1, 1, 1])
        XCTAssertEqual(lone?.text, "\rc")
    }

    func testAnEditNeverSplitsASurrogatePair() {
        let smile = edit("x😀y", "x😁y")            // the pairs differ only in their second half
        XCTAssertEqual(smile?.oldRange, NSRange(location: 1, length: 2))
        XCTAssertEqual(smile?.text, "😁")
        XCTAssertEqual(place(smile), [0, 1, 0, 3])
        let joined = edit("😀😀", "😀")             // deleting one of two identical emoji
        XCTAssertEqual(joined?.oldRange.length, 2)
        XCTAssertEqual(joined?.text, "")
    }

    func testPositionsAreUTF16NotCharacters() {
        let after = edit("😀 a", "😀 b")
        XCTAssertEqual(place(after), [0, 3, 0, 4])
        let accents = edit("café x", "café y")
        XCTAssertEqual(place(accents), [0, 5, 0, 6])
    }

    func testContentChangeHasTheProtocolShape() throws {
        let change = try XCTUnwrap(edit("ab", "aXb")).contentChange
        let range = try XCTUnwrap(change["range"] as? [String: [String: Int]])
        XCTAssertEqual(range["start"], ["line": 0, "character": 1])
        XCTAssertEqual(range["end"], ["line": 0, "character": 1])
        XCTAssertEqual(change["text"] as? String, "X")
    }

    func testALargeDocumentWithOneChangedLineStaysSmall() {
        let lines = (0..<20_000).map { "line \($0) of the file" }
        var changed = lines
        changed[12_345] = "line twelve thousand"
        let big = edit(lines.joined(separator: "\n"), changed.joined(separator: "\n"))
        XCTAssertEqual(big?.startLine, 12_345)
        XCTAssertEqual(big?.endLine, 12_345)
        XCTAssertEqual(big?.startCharacter, 5)
        XCTAssertEqual(big?.text, "twelve thousand")
    }
}
