import XCTest
@testable import Feather

/// Activity/AssistantChanges.swift: the edge cases of `ChangedLines.ranges` (the basics are in
/// ChangedLinesTests): empty texts, edits at the very start and end, a missing final newline, repeated
/// lines, a replacement next to an insertion, non-ASCII, and the size cap. The coordinator side needs a window.
final class ChangedLinesEdgeCaseTests: XCTestCase {
    func testFromNothingAndToNothing() {
        XCTAssertEqual(ChangedLines.ranges(from: "", to: "a\nb\n"), [0..<2], "the empty text is one empty line, which stays as the last")
        XCTAssertEqual(ChangedLines.ranges(from: "a\nb\n", to: ""), [0..<0])
        XCTAssertEqual(ChangedLines.ranges(from: "", to: ""), [])
    }

    func testEditsAtTheStartAndTheEnd() {
        XCTAssertEqual(ChangedLines.ranges(from: "a\nb\nc\n", to: "A\nb\nc\n"), [0..<1])
        XCTAssertEqual(ChangedLines.ranges(from: "a\nb\nc\n", to: "new\na\nb\nc\n"), [0..<1])
        XCTAssertEqual(ChangedLines.ranges(from: "a\nb\nc\n", to: "a\nb\nC\n"), [2..<3])
        XCTAssertEqual(ChangedLines.ranges(from: "a\nb\nc\n", to: "a\nb\nc\nd\n"), [3..<4])
        XCTAssertEqual(ChangedLines.ranges(from: "a\nb\nc\n", to: "b\nc\n"), [0..<0])
        XCTAssertEqual(ChangedLines.ranges(from: "a\nb\nc\n", to: "a\nb\n"), [2..<2])
    }

    func testAddingOrRemovingTheFinalNewlineIsTheLastLine() {
        // "c" became "c" plus an empty line after it.
        XCTAssertEqual(ChangedLines.ranges(from: "a\nb\nc", to: "a\nb\nc\n"), [3..<4])
        XCTAssertEqual(ChangedLines.ranges(from: "a\nb\nc\n", to: "a\nb\nc"), [3..<3])
    }

    func testRepeatedLinesAreNotConfused() {
        XCTAssertEqual(ChangedLines.ranges(from: "a\na\na\n", to: "a\na\na\na\n"), [3..<4])
        XCTAssertEqual(ChangedLines.ranges(from: "x\n\n\ny\n", to: "x\n\n\n\ny\n"), [3..<4])
    }

    func testAReplacementNextToAnInsertionIsOneRange() {
        XCTAssertEqual(ChangedLines.ranges(from: "a\nb\nc\n", to: "a\nB\nB2\nc\n"), [1..<3])
        XCTAssertEqual(ChangedLines.ranges(from: "a\nb\nc\nd\n", to: "a\nB\nC\nd\n"), [1..<3])
    }

    func testADeletionNextToAChangeIsSwallowedByIt() {
        // "b" gone and "c" edited: one range at the edited line, no empty range for the deletion.
        XCTAssertEqual(ChangedLines.ranges(from: "a\nb\nc\nd\n", to: "a\nC\nd\n"), [1..<2])
    }

    func testTwoSeparateDeletions() {
        XCTAssertEqual(ChangedLines.ranges(from: "a\nb\nc\nd\ne\n", to: "a\nc\ne\n"), [1..<1, 2..<2])
    }

    func testNonASCIIAndEmoji() {
        XCTAssertEqual(ChangedLines.ranges(from: "héllo\nwörld\n", to: "héllo\n🌍\n"), [1..<2])
        XCTAssertEqual(ChangedLines.ranges(from: "名前\n", to: "名前\n"), [])
    }

    func testAHugeRewriteInTheMiddleIsOneBlock() {
        let old = (0..<ChangedLines.maxDiffedLines + 10).map { "line \($0)" }.joined(separator: "\n")
        let new = (0..<ChangedLines.maxDiffedLines + 10).map { $0 < 5 ? "line \($0)" : "other \($0)" }.joined(separator: "\n")
        XCTAssertEqual(ChangedLines.ranges(from: old, to: new), [5..<(ChangedLines.maxDiffedLines + 10)])
        // Under the cap the same shape is diffed line by line and still comes out as one range.
        let small = (0..<50).map { $0 < 5 ? "line \($0)" : "other \($0)" }.joined(separator: "\n")
        let smallOld = (0..<50).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(ChangedLines.ranges(from: smallOld, to: small), [5..<50])
    }
}

final class ChangedLinesLineEndingTests: XCTestCase {
    func testCRLFFilesAreSplitIntoLines() {
        let old = "a\r\nb\r\nc\r\n", new = "a\r\nB\r\nc\r\n"
        XCTAssertEqual(ChangedLines.ranges(from: old, to: new), [1..<2])
    }
}
