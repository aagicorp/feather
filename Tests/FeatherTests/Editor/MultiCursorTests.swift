import AppKit
import XCTest
@testable import Feather

/// Covers Editor/MultiCursor.swift: the cursor and edit values, keeping the set (sorting, clamping, merging,
/// the primary), adding cursors by occurrence and by line, editing and moving at every cursor as one change,
/// and the way outside changes drop back to a single cursor. All on a text view without a window.
final class TextCursorTests: XCTestCase {
    func testRangesAndEdits() {
        XCTAssertEqual(TextCursor(anchor: 5, head: 2).range, NSRange(location: 2, length: 3))
        XCTAssertEqual(TextCursor(anchor: 2, head: 5).range, NSRange(location: 2, length: 3))
        XCTAssertEqual(TextCursor(NSRange(location: 4, length: 2)), TextCursor(anchor: 4, head: 6))
        XCTAssertNil(TextCursor(NSRange(location: 1, length: 0)).goalX)
        let edit = CursorEdit.replacing(NSRange(location: 3, length: 2), with: "ab")
        XCTAssertEqual(edit.caret, 2)
        XCTAssertTrue(edit.changesText)
        XCTAssertFalse(CursorEdit(range: NSRange(location: 3, length: 0), text: "", caret: 1).changesText)
        XCTAssertTrue(CursorEdit(range: NSRange(location: 3, length: 1), text: "", caret: 0).changesText)
    }
}

final class MultiCursorTests: XCTestCase {
    private func cursors(_ editor: HeadlessEditor) -> [NSRange] { editor.textView.cursorRanges }

    private func caret(_ location: Int) -> TextCursor { TextCursor(anchor: location, head: location) }

    // MARK: - Keeping the set

    func testSetCursorsSortsClampsMergesAndKeepsThePrimary() {
        let editor = HeadlessEditor("aaaa bbbb")
        editor.textView.setCursors([caret(7), caret(2), caret(50)], primary: 1)
        XCTAssertTrue(editor.textView.isMultiCursor)
        XCTAssertEqual(cursors(editor), [NSRange(location: 2, length: 0), NSRange(location: 7, length: 0), NSRange(location: 9, length: 0)])
        XCTAssertEqual(editor.textView.multiCursor.primary, 0)
        XCTAssertEqual(editor.selection, NSRange(location: 2, length: 0))              // the text view holds the primary
        // Overlapping selections become one; a caret on the edge of a selection is swallowed by it.
        editor.textView.setCursors([TextCursor(NSRange(location: 0, length: 2)), TextCursor(NSRange(location: 1, length: 2)), caret(3), caret(6)], primary: 3)
        XCTAssertEqual(cursors(editor), [NSRange(location: 0, length: 3), NSRange(location: 6, length: 0)])
        XCTAssertEqual(editor.textView.multiCursor.primary, 1)
        // Two selections that only touch stay apart.
        editor.textView.setCursors([TextCursor(NSRange(location: 0, length: 2)), TextCursor(NSRange(location: 2, length: 2))], primary: 0)
        XCTAssertEqual(cursors(editor), [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
        // One cursor left means ordinary editing again.
        editor.textView.setCursors([caret(4)], primary: 0)
        XCTAssertFalse(editor.textView.isMultiCursor)
        XCTAssertEqual(cursors(editor), [NSRange(location: 4, length: 0)])
    }

    func testMergingKeepsTheDirectionOfTheLaterSelection() {
        let editor = HeadlessEditor("abcdefghij")
        editor.textView.setCursors([TextCursor(anchor: 0, head: 3), TextCursor(anchor: 5, head: 2), caret(8)], primary: 0)
        XCTAssertEqual(editor.textView.allCursors, [TextCursor(anchor: 5, head: 0), caret(8)])
    }

    func testOutsideChangesDropBackToOneCursor() {
        let editor = HeadlessEditor("one two three")
        editor.textView.setCursors([caret(0), caret(4), caret(8)], primary: 2)
        XCTAssertEqual(editor.selection, NSRange(location: 8, length: 0))
        editor.select(1)                                    // a click, Find, a jump…
        XCTAssertFalse(editor.textView.isMultiCursor)
        XCTAssertEqual(cursors(editor), [NSRange(location: 1, length: 0)])
        editor.textView.setCursors([caret(0), caret(4)], primary: 0)
        editor.textView.textChangedFromOutside()
        XCTAssertFalse(editor.textView.isMultiCursor)
        editor.textView.setCursors([caret(0), caret(4)], primary: 1)
        editor.textView.collapseToPrimaryCursor()
        XCTAssertEqual(cursors(editor), [NSRange(location: 4, length: 0)])
    }

    func testToggleCursorAddsAndRemoves() {
        let editor = HeadlessEditor("one two three")
        editor.select(0)
        editor.textView.toggleCursor(at: 4)
        editor.textView.toggleCursor(at: 8)
        XCTAssertEqual(cursors(editor), [NSRange(location: 0, length: 0), NSRange(location: 4, length: 0), NSRange(location: 8, length: 0)])
        editor.textView.toggleCursor(at: 4)
        XCTAssertEqual(cursors(editor), [NSRange(location: 0, length: 0), NSRange(location: 8, length: 0)])
        editor.textView.toggleCursor(at: 8)
        XCTAssertFalse(editor.textView.isMultiCursor)
        XCTAssertEqual(cursors(editor), [NSRange(location: 0, length: 0)])
    }

    // MARK: - Finding occurrences

    func testAddSelectionToNextFindMatchSelectsTheWordFirstThenWholeWordsOnlyAndWrapsAround() {
        let editor = HeadlessEditor("item items item\nitem")
        editor.select(17)                                   // inside the last "item"
        editor.textView.addSelectionToNextFindMatch(nil)
        XCTAssertEqual(cursors(editor), [NSRange(location: 16, length: 4)])
        editor.textView.addSelectionToNextFindMatch(nil)    // round from the top: "items" is not a whole word
        XCTAssertEqual(cursors(editor), [NSRange(location: 0, length: 4), NSRange(location: 16, length: 4)])
        XCTAssertEqual(editor.selection, NSRange(location: 0, length: 4))   // the newest is the primary
        editor.textView.addSelectionToNextFindMatch(nil)
        XCTAssertEqual(cursors(editor), [NSRange(location: 0, length: 4), NSRange(location: 11, length: 4), NSRange(location: 16, length: 4)])
        let count = cursors(editor).count
        editor.textView.addSelectionToNextFindMatch(nil)    // nothing left to add
        XCTAssertEqual(cursors(editor).count, count)
    }

    func testASelectionIsMatchedAsIsNotAsAWord() {
        let editor = HeadlessEditor("ab abc ab")
        editor.select(0, 2)
        editor.textView.addSelectionToNextFindMatch(nil)
        XCTAssertEqual(cursors(editor), [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
    }

    func testSelectAllOccurrencesKeepsThePrimaryWhereItWas() {
        let editor = HeadlessEditor("a aa a\na")
        editor.select(5)
        editor.textView.selectAllOccurrences(nil)
        XCTAssertEqual(cursors(editor), [NSRange(location: 0, length: 1), NSRange(location: 5, length: 1), NSRange(location: 7, length: 1)])
        XCTAssertEqual(editor.selection, NSRange(location: 5, length: 1))
        let selected = HeadlessEditor("aaaa")
        selected.select(0, 2)
        selected.textView.selectAllOccurrences(nil)
        XCTAssertEqual(cursors(selected), [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
    }

    // MARK: - Cursors by line

    func testAddCursorBelowKeepsTheWidestColumnAndStopsAtTheEnd() {
        let editor = HeadlessEditor("abcdef\nab\nabcdef\n")
        editor.select(4)
        editor.textView.addCursorBelow(nil)
        XCTAssertEqual(cursors(editor), [NSRange(location: 4, length: 0), NSRange(location: 9, length: 0)])   // pulled in by "ab"
        editor.textView.addCursorBelow(nil)
        XCTAssertEqual(cursors(editor).last, NSRange(location: 14, length: 0))                              // back in column 4
        editor.textView.addCursorBelow(nil)
        XCTAssertEqual(cursors(editor).last, NSRange(location: 17, length: 0))                              // the empty last line
        let count = cursors(editor).count
        editor.textView.addCursorBelow(nil)                 // nothing below
        XCTAssertEqual(cursors(editor).count, count)
    }

    func testAddCursorAbove() {
        let editor = HeadlessEditor("ab\nabcdef")
        editor.select(8)
        editor.textView.addCursorAbove(nil)
        XCTAssertEqual(cursors(editor), [NSRange(location: 2, length: 0), NSRange(location: 8, length: 0)])
        XCTAssertEqual(editor.selection, NSRange(location: 2, length: 0))
        editor.textView.addCursorAbove(nil)                 // nothing above
        XCTAssertEqual(cursors(editor).count, 2)
    }

    func testAddCursorBelowPassesOverFoldedLines() {
        let editor = HeadlessEditor("a:\n    b\n    c\nd\n")
        editor.folding.fold(line: 0)
        editor.select(0)
        editor.textView.addCursorBelow(nil)
        XCTAssertEqual(cursors(editor), [NSRange(location: 0, length: 0), NSRange(location: 15, length: 0)])
    }

    // MARK: - Editing at every cursor

    func testTypingAtEveryCursorIsOneChangeAndOneUndoStep() {
        let editor = HeadlessEditor("x\nx\nx")
        editor.textView.setCursors([caret(1), caret(3), caret(5)], primary: 2)
        editor.type("(")
        XCTAssertEqual(editor.text, "x()\nx()\nx()")
        XCTAssertEqual(cursors(editor), [NSRange(location: 2, length: 0), NSRange(location: 6, length: 0), NSRange(location: 10, length: 0)])
        editor.type("y")
        XCTAssertEqual(editor.text, "x(y)\nx(y)\nx(y)")
        editor.type(")")                                    // steps over the closer at each cursor
        XCTAssertEqual(editor.text, "x(y)\nx(y)\nx(y)")
        XCTAssertEqual(cursors(editor), [NSRange(location: 4, length: 0), NSRange(location: 9, length: 0), NSRange(location: 14, length: 0)])
        editor.undo.undo()
        XCTAssertEqual(editor.text, "x\nx\nx")                       // typing at three places was one step
    }

    func testDeletingAtEveryCursorTakesPairsAndRunsEditsTogether() {
        let editor = HeadlessEditor("f() g() ab")
        editor.textView.setCursors([caret(2), caret(6), caret(9), caret(10)], primary: 0)
        editor.command("deleteBackward:")
        XCTAssertEqual(editor.text, "f g ")                         // two pairs and both letters, as one change
        XCTAssertEqual(cursors(editor), [NSRange(location: 1, length: 0), NSRange(location: 3, length: 0), NSRange(location: 4, length: 0)])
        editor.command("deleteForward:")
        XCTAssertEqual(editor.text, "fg")
    }

    func testReplacingSelectionsAndInsertingNewlinesAndTabs() {
        let editor = HeadlessEditor("one two\n  three")
        editor.textView.setCursors([TextCursor(NSRange(location: 0, length: 3)), TextCursor(NSRange(location: 4, length: 3))], primary: 0)
        editor.type("X")
        XCTAssertEqual(editor.text, "X X\n  three")
        editor.textView.setCursors([caret(1), caret(9)], primary: 0)
        editor.command("insertNewline:")
        XCTAssertEqual(editor.text, "X\n X\n  thr\n  ee")             // each new line keeps its own indentation
        XCTAssertEqual(cursors(editor), [NSRange(location: 2, length: 0), NSRange(location: 13, length: 0)])
        let tabs = HeadlessEditor("a\nb")
        tabs.textView.setCursors([caret(1), caret(3)], primary: 0)
        tabs.command("insertTab:")
        let unit = Settings.shared.useSpaces ? String(repeating: " ", count: Settings.shared.tabWidth - 1) : "\t"
        XCTAssertEqual(tabs.text, "a\(unit)\nb\(unit)")               // spaces fill up to the next tab stop
    }

    func testApplyCursorEditsMergesEditsThatRunIntoEachOther() {
        let editor = HeadlessEditor("abcdef")
        editor.textView.setCursors([caret(0), caret(3)], primary: 0)
        editor.textView.applyCursorEdits([CursorEdit.replacing(NSRange(location: 0, length: 4), with: "X"),
                                          CursorEdit.replacing(NSRange(location: 3, length: 2), with: "Y")])
        XCTAssertEqual(editor.text, "XYf")
        XCTAssertEqual(cursors(editor), [NSRange(location: 2, length: 0)])
        XCTAssertFalse(editor.textView.isMultiCursor)
    }

    // MARK: - Moving every cursor

    func testMotionsMoveEveryCursorAndShiftExtendsThem() {
        let editor = HeadlessEditor("  one two\n  three four")
        editor.textView.setCursors([caret(4), caret(15)], primary: 0)
        editor.command("moveRight:")
        XCTAssertEqual(cursors(editor), [NSRange(location: 5, length: 0), NSRange(location: 16, length: 0)])
        editor.command("moveWordRight:")
        XCTAssertEqual(cursors(editor), [NSRange(location: 9, length: 0), NSRange(location: 17, length: 0)])
        editor.command("moveWordLeft:")
        XCTAssertEqual(cursors(editor), [NSRange(location: 6, length: 0), NSRange(location: 12, length: 0)])
        editor.command("moveToBeginningOfLine:")                    // first to the code, then to the line
        XCTAssertEqual(cursors(editor), [NSRange(location: 2, length: 0), NSRange(location: 10, length: 0)])   // the second was already at its code
        editor.command("moveToBeginningOfLine:")
        XCTAssertEqual(cursors(editor), [NSRange(location: 0, length: 0), NSRange(location: 12, length: 0)])
        editor.command("moveToEndOfLineAndModifySelection:")
        XCTAssertEqual(cursors(editor), [NSRange(location: 0, length: 9), NSRange(location: 12, length: 10)])
        XCTAssertEqual(editor.textView.allCursors.map(\.head), [9, 22])
        editor.command("moveLeft:")                                 // lets go of the selection at its left end
        XCTAssertEqual(cursors(editor), [NSRange(location: 0, length: 0), NSRange(location: 12, length: 0)])
        editor.command("moveToEndOfDocument:")
        XCTAssertFalse(editor.textView.isMultiCursor)                // both landed on the same place: one cursor
        XCTAssertEqual(editor.selection, NSRange(location: 22, length: 0))
    }

    func testLeftAndRightStepOverComposedCharacters() {
        let editor = HeadlessEditor("😀a\n😀b")
        editor.textView.setCursors([caret(0), caret(4)], primary: 0)
        editor.command("moveRight:")
        XCTAssertEqual(cursors(editor), [NSRange(location: 2, length: 0), NSRange(location: 6, length: 0)])
        editor.command("moveLeft:")
        XCTAssertEqual(cursors(editor), [NSRange(location: 0, length: 0), NSRange(location: 4, length: 0)])
    }

    func testEscapeCollapsesAndUnknownCommandsAreNotOurs() {
        let editor = HeadlessEditor("ab")
        editor.textView.setCursors([caret(0), caret(2)], primary: 1)
        XCTAssertFalse(editor.textView.performAtCursors(NSSelectorFromString("uppercaseWord:")))
        XCTAssertTrue(editor.textView.performAtCursors(NSSelectorFromString("cancelOperation:")))
        XCTAssertFalse(editor.textView.isMultiCursor)
        XCTAssertEqual(editor.selection, NSRange(location: 2, length: 0))
    }
}
