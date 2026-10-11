import AppKit
import XCTest
@testable import Feather

/// Covers Editor/EditingCommands.swift: the bracket pair table, typing pairs (closing, stepping over, wrapping,
/// the apostrophe rule), deleting and opening a pair, bracket matching with its scan limit, and the line
/// commands (move, copy, delete, indent, outdent, insert line) on a text view without a window.
final class BracketPairsTests: XCTestCase {
    private func unit(_ character: Character) -> unichar { String(character).utf16.first! }

    func testClosersAndQuotes() {
        XCTAssertEqual(BracketPairs.closer(for: unit("(")), unit(")"))
        XCTAssertEqual(BracketPairs.closer(for: unit("[")), unit("]"))
        XCTAssertEqual(BracketPairs.closer(for: unit("{")), unit("}"))
        XCTAssertEqual(BracketPairs.closer(for: unit("\"")), unit("\""))
        XCTAssertEqual(BracketPairs.closer(for: unit("`")), unit("`"))
        XCTAssertNil(BracketPairs.closer(for: unit(")")))
        XCTAssertNil(BracketPairs.closer(for: unit("<")))
        XCTAssertTrue(BracketPairs.isClosingBracket(unit("}")))
        XCTAssertFalse(BracketPairs.isClosingBracket(unit("{")))
        XCTAssertFalse(BracketPairs.isClosingBracket(unit("'")))
    }

    func testPartnersHaveADirectionAndQuotesHaveNone() {
        XCTAssertEqual(BracketPairs.partner(of: unit("("))?.unit, unit(")"))
        XCTAssertEqual(BracketPairs.partner(of: unit("("))?.isForward, true)
        XCTAssertEqual(BracketPairs.partner(of: unit("]"))?.unit, unit("["))
        XCTAssertEqual(BracketPairs.partner(of: unit("]"))?.isForward, false)
        XCTAssertNil(BracketPairs.partner(of: unit("\"")))
        XCTAssertNil(BracketPairs.partner(of: unit("a")))
    }

    func testWordCharactersAndWhereAClosingMayBeTyped() {
        XCTAssertTrue(BracketPairs.isWord(unit("a")))
        XCTAssertTrue(BracketPairs.isWord(unit("_")))
        XCTAssertTrue(BracketPairs.isWord(unit("$")))
        XCTAssertTrue(BracketPairs.isWord(unit("é")))
        XCTAssertFalse(BracketPairs.isWord(unit(" ")))
        XCTAssertFalse(BracketPairs.isWord(nil))
        XCTAssertTrue(BracketPairs.allowsClosing(before: nil))
        for next in " \t\n\r)]},;:.>" { XCTAssertTrue(BracketPairs.allowsClosing(before: unit(next)), "\(next)") }
        for next in "a1_\"(" { XCTAssertFalse(BracketPairs.allowsClosing(before: unit(next)), "\(next)") }
    }
}

final class AutoClosingPairsTests: XCTestCase {
    private func unit(_ character: Character) -> unichar { String(character).utf16.first! }

    func testTypingAnOpenerTypesBothHalves() {
        let editor = HeadlessEditor("call\n")
        editor.select(4)
        let edit = editor.textView.pairedEdit(typing: unit("("), over: NSRange(location: 4, length: 0))
        XCTAssertEqual(edit?.text, "()")
        XCTAssertEqual(edit?.caret, 1)
        XCTAssertEqual(edit?.selected, 0)
        editor.type("(")
        XCTAssertEqual(editor.text, "call()\n")
        XCTAssertEqual(editor.selection, NSRange(location: 5, length: 0))
    }

    func testNoPairInFrontOfAWordOrAfterABackslash() {
        let editor = HeadlessEditor("word \\\n")
        XCTAssertNil(editor.textView.pairedEdit(typing: unit("("), over: NSRange(location: 0, length: 0)))
        XCTAssertNil(editor.textView.pairedEdit(typing: unit("\""), over: NSRange(location: 6, length: 0)))
        editor.select(0)
        editor.type("(")
        XCTAssertEqual(editor.text, "(word \\\n")
    }

    func testTypingTheCloserThatIsAlreadyThereStepsOverIt() {
        let editor = HeadlessEditor("f()")
        editor.select(2)
        let edit = editor.textView.pairedEdit(typing: unit(")"), over: NSRange(location: 2, length: 0))
        XCTAssertEqual(edit?.text, "")
        XCTAssertEqual(edit?.caret, 1)
        editor.type(")")
        XCTAssertEqual(editor.text, "f()")
        XCTAssertEqual(editor.selection, NSRange(location: 3, length: 0))
        editor.select(2)
        editor.type("\"")                                   // a quote before ")" is allowed to pair
        XCTAssertEqual(editor.text, "f(\"\")")
        editor.type("\"")                                   // and typing it again steps over its partner
        XCTAssertEqual(editor.text, "f(\"\")")
        XCTAssertEqual(editor.selection, NSRange(location: 4, length: 0))
        editor.select(1)
        editor.type("\"")                                   // before "(" a quote is simply typed
        XCTAssertEqual(editor.text, "f\"(\"\")")
    }

    func testASelectionIsWrappedAndStaysSelected() {
        let editor = HeadlessEditor("wrap me\n")
        editor.select(0, 4)
        editor.type("[")
        XCTAssertEqual(editor.text, "[wrap] me\n")
        XCTAssertEqual(editor.selection, NSRange(location: 1, length: 4))
        editor.type("(")                                    // a second bracket wraps it again
        XCTAssertEqual(editor.text, "[(wrap)] me\n")
        XCTAssertEqual(editor.selection, NSRange(location: 2, length: 4))
    }

    func testApostrophesInWordsAndClosingQuotesAreTypedPlainly() {
        let editor = HeadlessEditor("don\n")
        editor.select(3)
        editor.type("'")
        XCTAssertEqual(editor.text, "don'\n")
        let closing = HeadlessEditor("'abc\n")
        closing.select(4)
        closing.type("'")                                   // touching a word: no pair
        XCTAssertEqual(closing.text, "'abc'\n")
        let doubled = HeadlessEditor("'\n")
        doubled.select(1)
        XCTAssertNil(doubled.textView.pairedEdit(typing: unit("'"), over: NSRange(location: 1, length: 0)))
    }

    func testBackspaceBetweenAPairTakesBoth() {
        let editor = HeadlessEditor("f()\n")
        editor.select(2)
        XCTAssertTrue(editor.textView.deleteEmptyPair())
        XCTAssertEqual(editor.text, "f\n")
        editor.select(1)
        XCTAssertFalse(editor.textView.deleteEmptyPair())    // "f" and "\n" are not a pair
        let full = HeadlessEditor("(a)")
        full.select(1)
        XCTAssertFalse(full.textView.deleteEmptyPair())
    }

    func testReturnBetweenBracesOpensThemOntoNewLines() {
        let editor = HeadlessEditor("  if x {}\n")
        editor.select(8)
        XCTAssertTrue(editor.textView.openPairOntoNewLines())
        let unit = editor.textView.indentUnit
        XCTAssertEqual(editor.text, "  if x {\n  \(unit)\n  }\n")
        XCTAssertEqual(editor.selection, NSRange(location: 8 + 1 + 2 + (unit as NSString).length, length: 0))
        let plain = HeadlessEditor("ab")
        plain.select(1)
        XCTAssertFalse(plain.textView.openPairOntoNewLines())
    }

    func testLeadingWhitespace() {
        let editor = HeadlessEditor("\t  x\n  y\nz")
        XCTAssertEqual(editor.textView.leadingWhitespace(ofLineAt: 3), "\t  ")
        XCTAssertEqual(editor.textView.leadingWhitespace(ofLineAt: 6), "  ")
        XCTAssertEqual(editor.textView.leadingWhitespace(ofLineAt: 9), "")
        XCTAssertEqual(editor.textView.leadingWhitespace(ofLineAt: 99), "")
    }
}

final class BracketMatchingTests: XCTestCase {
    func testPartnerCountsNesting() {
        let editor = HeadlessEditor("a(b(c)d)e")
        XCTAssertEqual(editor.textView.partner(ofBracketAt: 1), 7)
        XCTAssertEqual(editor.textView.partner(ofBracketAt: 7), 1)
        XCTAssertEqual(editor.textView.partner(ofBracketAt: 3), 5)
        XCTAssertNil(editor.textView.partner(ofBracketAt: 0))                // not a bracket
        XCTAssertNil(editor.textView.partner(ofBracketAt: 9))                // past the end
        XCTAssertNil(HeadlessEditor("((").textView.partner(ofBracketAt: 0))  // never closed
        XCTAssertEqual(HeadlessEditor("([)]").textView.partner(ofBracketAt: 1), 3)   // other kinds are passed over
    }

    func testPartnerGivesUpBeyondTheScanLimit() {
        let far = "(" + String(repeating: " ", count: CodeTextView.bracketScanLimit + 10) + ")"
        let editor = HeadlessEditor(far)
        XCTAssertNil(editor.textView.partner(ofBracketAt: 0))
        XCTAssertNil(editor.textView.partner(ofBracketAt: (far as NSString).length - 1))
        let near = "(" + String(repeating: " ", count: 3000) + ")"          // more than one 2,048-unit block
        XCTAssertEqual(HeadlessEditor(near).textView.partner(ofBracketAt: 0), 3001)
    }

    func testGoToMatchingBracketLandsOutsideThePairAndComesBack() {
        let editor = HeadlessEditor("f(a, [b]) + g")
        editor.select(2)                                    // just after "("
        editor.textView.goToMatchingBracket(nil)
        XCTAssertEqual(editor.selection, NSRange(location: 9, length: 0))   // after ")"
        editor.textView.goToMatchingBracket(nil)
        XCTAssertEqual(editor.selection, NSRange(location: 1, length: 0))   // before "("
        editor.select(7)                                    // inside "[b]", no bracket beside the caret
        editor.textView.goToMatchingBracket(nil)
        XCTAssertEqual(editor.selection, NSRange(location: 5, length: 0))   // the nearest still-open bracket
    }

    func testBracketHighlightsMoveWithEdits() {
        let editor = HeadlessEditor("(x) y")
        editor.textView.bracketHighlights = [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)]
        editor.textView.bracketsNoteEdit(NSRange(location: 1, length: 3), delta: 2)          // "x" became "xyz"
        XCTAssertEqual(editor.textView.bracketHighlights, [NSRange(location: 0, length: 1), NSRange(location: 4, length: 1)])
        editor.textView.bracketsNoteEdit(NSRange(location: 3, length: 0), delta: -2)         // the closer was deleted
        XCTAssertEqual(editor.textView.bracketHighlights, [NSRange(location: 0, length: 1)])
        XCTAssertEqual(editor.textView.editCount, 2)
    }
}

final class LineCommandsTests: XCTestCase {
    func testSelectedLinesRangeLeavesOutALineTheSelectionOnlyStartsOn() {
        let editor = HeadlessEditor("one\ntwo\nthree\n")
        editor.select(1)
        XCTAssertEqual(editor.textView.selectedLinesRange, NSRange(location: 0, length: 4))
        editor.select(0, 8)                                 // "one\ntwo\n": the caret sits at the start of "three"
        XCTAssertEqual(editor.textView.selectedLinesRange, NSRange(location: 0, length: 8))
        editor.select(2, 7)                                 // reaches into "three"
        XCTAssertEqual(editor.textView.selectedLinesRange, NSRange(location: 0, length: 14))
    }

    func testMoveLinesUpAndDownKeepTheSelectionOnTheText() {
        let editor = HeadlessEditor("one\ntwo\nthree")
        editor.select(5, 2)                                 // "wo"
        editor.textView.moveLinesUp(nil)
        XCTAssertEqual(editor.text, "two\none\nthree")
        XCTAssertEqual(editor.selection, NSRange(location: 1, length: 2))
        editor.textView.moveLinesUp(nil)                    // already at the top
        XCTAssertEqual(editor.text, "two\none\nthree")
        editor.textView.moveLinesDown(nil)
        editor.textView.moveLinesDown(nil)
        XCTAssertEqual(editor.text, "one\nthree\ntwo")      // the last line gets the newline it did not have
        XCTAssertEqual(editor.selection, NSRange(location: 11, length: 2))
        editor.textView.moveLinesDown(nil)                  // nowhere further down
        XCTAssertEqual(editor.text, "one\nthree\ntwo")
        XCTAssertEqual(editor.undo.canUndo, true)
        editor.undo.undo()
        XCTAssertEqual(editor.text, "one\ntwo\nthree")      // one step per move
    }

    func testMovingSeveralLinesAndCRLFEndings() {
        let editor = HeadlessEditor("a\r\nb\r\nc\r\nd\r\n")
        editor.select(0, 5)                                 // "a\r\nb\r" reaches into the second line
        editor.textView.moveLinesDown(nil)
        XCTAssertEqual(editor.text, "c\r\na\r\nb\r\nd\r\n")
        XCTAssertEqual(editor.selection, NSRange(location: 3, length: 5))
    }

    func testCopyLinesUpAndDown() {
        let editor = HeadlessEditor("one\ntwo")
        editor.select(5, 1)
        editor.textView.copyLinesDown(nil)
        XCTAssertEqual(editor.text, "one\ntwo\ntwo")
        XCTAssertEqual(editor.selection, NSRange(location: 9, length: 1))     // on the new copy
        editor.select(1)
        editor.textView.copyLinesUp(nil)
        XCTAssertEqual(editor.text, "one\none\ntwo\ntwo")
        XCTAssertEqual(editor.selection, NSRange(location: 1, length: 0))     // on the copy that stayed put
    }

    func testDeleteLinesKeepsTheColumnAndHandlesTheLastLine() {
        let editor = HeadlessEditor("first\nsecond\nlast")
        editor.select(8)                                    // column 2 of "second"
        editor.textView.deleteLines(nil)
        XCTAssertEqual(editor.text, "first\nlast")
        XCTAssertEqual(editor.selection, NSRange(location: 8, length: 0))
        editor.select(10)                                   // column 4 of "last"
        editor.textView.deleteLines(nil)
        XCTAssertEqual(editor.text, "first")                // the newline before it went too
        XCTAssertEqual(editor.selection, NSRange(location: 4, length: 0))
        editor.textView.deleteLines(nil)
        XCTAssertEqual(editor.text, "")
        editor.textView.deleteLines(nil)                    // nothing left: nothing happens
        XCTAssertEqual(editor.text, "")
    }

    func testIndentAndOutdentKeepTheCaretInTheWords() {
        let unit = Settings.shared.useSpaces ? String(repeating: " ", count: Settings.shared.tabWidth) : "\t"
        let editor = HeadlessEditor("a\n\nb\n")
        editor.select(0, 5)
        editor.textView.indentLines(nil)
        XCTAssertEqual(editor.text, "\(unit)a\n\n\(unit)b\n")          // the blank line is left blank
        XCTAssertEqual(editor.selection, NSRange(location: (unit as NSString).length, length: 5 + (unit as NSString).length))
        editor.textView.outdentLines(nil)
        XCTAssertEqual(editor.text, "a\n\nb\n")
        XCTAssertEqual(editor.selection, NSRange(location: 0, length: 5))
        editor.textView.outdentLines(nil)                   // nothing to take away
        XCTAssertEqual(editor.text, "a\n\nb\n")
    }

    func testOutdentTakesOneTabOrUpToAnIndentOfSpaces() {
        let width = Settings.shared.tabWidth
        let editor = HeadlessEditor("\t\tx\n" + String(repeating: " ", count: width + 1) + "y\n z\n")
        editor.select(0, (editor.text as NSString).length)
        editor.textView.outdentLines(nil)
        XCTAssertEqual(editor.text, "\tx\n" + String(repeating: " ", count: 1) + "y\nz\n")
    }

    func testInsertLineBelowAndAbove() {
        let unit = Settings.shared.useSpaces ? String(repeating: " ", count: Settings.shared.tabWidth) : "\t"
        let editor = HeadlessEditor("  if x {\n  y")
        editor.select(3)
        editor.textView.insertLineBelow(nil)
        XCTAssertEqual(editor.text, "  if x {\n  \(unit)\n  y")     // a block opener: one level deeper
        XCTAssertEqual(editor.selection, NSRange(location: 9 + 2 + (unit as NSString).length, length: 0))
        editor.select((editor.text as NSString).length)
        editor.textView.insertLineAbove(nil)
        XCTAssertEqual(editor.text, "  if x {\n  \(unit)\n  \n  y")
        editor.textView.indentAfterColon = true
        let python = HeadlessEditor("def f():")
        python.textView.indentAfterColon = true
        python.select(0)
        python.textView.insertLineBelow(nil)
        XCTAssertEqual(python.text, "def f():\n\(unit)")
        let plain = HeadlessEditor("x:")
        plain.select(0)
        plain.textView.insertLineBelow(nil)                 // without the language rule a colon means nothing
        XCTAssertEqual(plain.text, "x:\n")
    }

    func testLineKeysAreRecognisedByKeyCodeAndModifiers() throws {
        let editor = HeadlessEditor("one\ntwo\n")
        editor.select(5)
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                           context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        XCTAssertTrue(editor.textView.handleLineKey(try key(126, [.option])))          // ⌥↑
        XCTAssertEqual(editor.text, "two\none\n")
        XCTAssertTrue(editor.textView.handleLineKey(try key(125, [.option, .shift])))  // ⌥⇧↓
        XCTAssertEqual(editor.text, "two\ntwo\none\n")
        XCTAssertFalse(editor.textView.handleLineKey(try key(126, [])))               // a plain arrow is not ours
        XCTAssertFalse(editor.textView.handleLineKey(try key(126, [.option, .command])))
    }
}

final class EditorOnlyKeysTests: XCTestCase {
    override func tearDown() {
        EditorOnlyKeys.forgetAll()
        EditorOnlyKeys.setActive(false)
        super.tearDown()
    }

    func testKeysAreOnlyCarriedWhileAnEditorIsActive() {
        let item = NSMenuItem(title: "Move Line Up", action: nil, keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        let key = item.keyEquivalent
        EditorOnlyKeys.claim([item])
        XCTAssertFalse(EditorOnlyKeys.isActive)
        XCTAssertEqual(item.keyEquivalent, "")
        EditorOnlyKeys.setActive(true)
        XCTAssertEqual(item.keyEquivalent, key)
        EditorOnlyKeys.setActive(false)
        XCTAssertEqual(item.keyEquivalent, "")
        EditorOnlyKeys.forgetAll()
        EditorOnlyKeys.setActive(true)
        XCTAssertEqual(item.keyEquivalent, "")               // forgotten items are left alone
    }
}
