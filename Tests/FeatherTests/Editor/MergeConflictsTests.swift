/// Editor/MergeConflicts.swift: finding `<<<<<<< ======= >>>>>>>` blocks (plain and diff3, several in a file,
/// the shapes that are not conflicts), the three resolutions, and the controller on a text view: tints, the
/// Accept buttons after each header, resolving as an undoable edit, resolving all.
import XCTest
@testable import Feather

final class MergeConflictsTests: XCTestCase {
    private let one = "line\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature/x\nend\n"

    func testOneBlockIsFoundWithItsParts() throws {
        let text = one as NSString
        let found = MergeConflict.find(in: text)
        XCTAssertEqual(found.count, 1)
        let conflict = try XCTUnwrap(found.first)
        XCTAssertEqual(text.substring(with: conflict.range), "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature/x\n")
        XCTAssertEqual(text.substring(with: conflict.header), "<<<<<<< HEAD\n")
        XCTAssertEqual(text.substring(with: conflict.current), "ours\n")
        XCTAssertEqual(text.substring(with: conflict.separator), "=======\n")
        XCTAssertEqual(text.substring(with: conflict.incoming), "theirs\n")
        XCTAssertEqual(text.substring(with: conflict.footer), ">>>>>>> feature/x\n")
        XCTAssertEqual(conflict.currentLabel, "HEAD")
        XCTAssertEqual(conflict.incomingLabel, "feature/x")
        XCTAssertNil(conflict.base)
    }

    func testTheThreeResolutions() {
        let text = one as NSString
        let conflict = MergeConflict.find(in: text)[0]
        func resolved(_ choice: MergeConflict.Choice) -> String {
            let edit = conflict.edit(choice, in: text)
            return text.replacingCharacters(in: edit.range, with: edit.text)
        }
        XCTAssertEqual(resolved(.current), "line\nours\nend\n")
        XCTAssertEqual(resolved(.incoming), "line\ntheirs\nend\n")
        XCTAssertEqual(resolved(.both), "line\nours\ntheirs\nend\n")
        XCTAssertEqual(MergeConflict.Choice.both.actionName, "Accept Both Changes")
    }

    func testSeveralBlocksAndMultiLineSides() throws {
        let text = "<<<<<<< HEAD\na1\na2\n=======\nb1\n>>>>>>> other\nmiddle\n<<<<<<< HEAD\n=======\nonly theirs\n>>>>>>> other\n" as NSString
        let found = MergeConflict.find(in: text)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(text.substring(with: found[0].current), "a1\na2\n")
        XCTAssertEqual(text.substring(with: found[1].current), "", "an empty side is allowed")
        XCTAssertEqual(text.substring(with: found[1].incoming), "only theirs\n")
        XCTAssertEqual(found[1].edit(.current, in: text).text, "")
    }

    func testDiff3BlocksKeepTheBaseOutOfBothSides() throws {
        let text = "<<<<<<< HEAD\nours\n||||||| merged common ancestors\nbase\n=======\ntheirs\n>>>>>>> other\n" as NSString
        let conflict = try XCTUnwrap(MergeConflict.find(in: text).first)
        XCTAssertEqual(text.substring(with: conflict.current), "ours\n")
        XCTAssertEqual(text.substring(with: try XCTUnwrap(conflict.base)), "||||||| merged common ancestors\nbase\n")
        XCTAssertEqual(text.substring(with: conflict.incoming), "theirs\n")
        XCTAssertEqual(conflict.edit(.both, in: text).text, "ours\ntheirs\n")
    }

    func testShapesThatAreNotConflicts() {
        XCTAssertTrue(MergeConflict.find(in: "a\n=======\nb\n").isEmpty, "a separator on its own")
        XCTAssertTrue(MergeConflict.find(in: "<<<<<<< HEAD\nours\n=======\ntheirs\n").isEmpty, "no end marker")
        XCTAssertTrue(MergeConflict.find(in: "<<<<<<< HEAD\nours\n>>>>>>> other\n").isEmpty, "no separator")
        XCTAssertTrue(MergeConflict.find(in: "x <<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> other\n").isEmpty, "a marker not at the start of a line")
        XCTAssertTrue(MergeConflict.find(in: "<<<<<<<HEAD\nours\n=======\ntheirs\n>>>>>>> other\n").isEmpty, "no space after the marker")
        XCTAssertTrue(MergeConflict.find(in: "<<<<<<< a\n<<<<<<< b\nours\n=======\ntheirs\n>>>>>>> other\n").count == 1, "a header inside an open block starts over")
        XCTAssertTrue(MergeConflict.find(in: "").isEmpty)
        XCTAssertTrue(MergeConflict.find(in: "plain text with ======= inside a line and >>>>>>> too").isEmpty)
    }

    func testWindowsLineEndingsAndAMissingFinalNewline() throws {
        let crlf = "<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> other\r\nend\r\n" as NSString
        let conflict = try XCTUnwrap(MergeConflict.find(in: crlf).first)
        XCTAssertEqual(crlf.substring(with: conflict.current), "ours\r\n")
        XCTAssertEqual(conflict.edit(.incoming, in: crlf).text, "theirs\r\n")
        let eof = "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> other" as NSString
        let last = try XCTUnwrap(MergeConflict.find(in: eof).first)
        XCTAssertEqual(NSMaxRange(last.range), eof.length)
        XCTAssertEqual(eof.substring(with: last.footer), ">>>>>>> other")
    }

    func testTheControllerTintsOffersButtonsAndResolvesUndoably() throws {
        let editor = HeadlessEditor("top\n" + one + "<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> other\n")
        let controller = MergeConflictController()
        var counts: [Int] = []
        controller.onChange = { counts.append($0) }
        controller.attach(to: editor.textView)
        controller.update()
        XCTAssertEqual(controller.conflicts.count, 2)
        XCTAssertEqual(controller.actionViews.count, 2)
        XCTAssertEqual(counts, [2])
        // Tints: the current side green, the incoming side blue, nothing outside the blocks.
        let text = editor.storage.mutableString
        let current = controller.conflicts[0].current.location
        XCTAssertEqual(editor.layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: current, effectiveRange: nil) as? NSColor, MergeConflictController.currentContent)
        XCTAssertEqual(editor.layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: controller.conflicts[0].incoming.location, effectiveRange: nil) as? NSColor, MergeConflictController.incomingContent)
        XCTAssertEqual(editor.layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: controller.conflicts[0].header.location, effectiveRange: nil) as? NSColor, MergeConflictController.currentHeader)
        XCTAssertNil(editor.layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil))
        // The buttons sit after the header line, the second lower down than the first.
        XCTAssertTrue(controller.actionViews.allSatisfy { $0.superview === editor.textView })
        XCTAssertGreaterThan(controller.actionViews[1].frame.minY, controller.actionViews[0].frame.minY)
        XCTAssertGreaterThan(controller.actionViews[0].frame.minX, 60)
        XCTAssertLessThan(controller.actionViews[0].frame.minX, 300, "right after the short header line, not at the end of an unbounded container")
        XCTAssertLessThan(controller.actionViews[0].frame.minY, 100, "on the second line of the file")

        controller.resolve(0, .incoming)
        XCTAssertEqual(text as String, "top\nline\ntheirs\nend\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> other\n")
        XCTAssertEqual(controller.conflicts.count, 1)
        XCTAssertEqual(controller.actionViews.count, 1)
        XCTAssertEqual(counts, [2, 1])
        XCTAssertNil(editor.layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: 6, effectiveRange: nil), "the tint went with the block")
        XCTAssertEqual(editor.undo.undoActionName, "Accept Incoming Change")
        editor.undo.undo()
        controller.update()
        XCTAssertEqual(controller.conflicts.count, 2)
        XCTAssertTrue((text as String).contains(">>>>>>> feature/x"))

        controller.resolveAll(.current)
        XCTAssertEqual(text as String, "top\nline\nours\nend\nx\n")
        XCTAssertEqual(controller.conflicts.count, 0)
        XCTAssertTrue(controller.actionViews.isEmpty)
        editor.undo.undo()
        controller.update()
        XCTAssertEqual(controller.conflicts.count, 2, "all at once is one undo step")
    }

    func testAFileWithoutMarkersCostsOneSearchAndNothingElse() {
        let editor = HeadlessEditor(String(repeating: "let x = 1\n", count: 20_000))
        let controller = MergeConflictController()
        controller.attach(to: editor.textView)
        let started = CFAbsoluteTimeGetCurrent()
        for _ in 0..<50 { controller.update() }
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        XCTAssertTrue(controller.conflicts.isEmpty)
        XCTAssertLessThan(elapsed, 1.0, "50 scans of 20k lines took \(Int(elapsed * 1000)) ms")
    }

    func testTheEditorViewOwnsAController() {
        let document = TextDocument()
        document.replaceAll(with: one)
        let view = EditorView(document: document)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        view.layoutSubtreeIfNeeded()
        view.conflicts.update()
        XCTAssertEqual(view.conflicts.conflicts.count, 1)
        view.conflicts.resolve(0, .both)
        XCTAssertEqual(document.text, "line\nours\ntheirs\nend\n")
    }
}
