import XCTest
@testable import Feather

/// Covers Editor/CodeFolding.swift: the region table built from indentation and open brackets (`lineEnds`,
/// `build`, `compute`, the lookups on it) and the `FoldingController` on a text view without a window: folding
/// and unfolding blocks, keeping carets and selections out of hidden text, moving folds along with edits,
/// restoring remembered folds, and adopting a syntax tree's table.
final class FoldRegionsTests: XCTestCase {
    private func regions(_ text: String, tabWidth: Int = 4) -> [String] {
        let table = FoldRegions.compute(Array(text.utf16), tabWidth: tabWidth)
        return (0..<table.count).map { "\(table.region(at: $0).header)-\(table.region(at: $0).end)" }
    }

    func testIndentationMakesNestedRegionsAndSkipsBlankLines() {
        let text = "def a():\n    x = 1\n    if x:\n        y\n\n    z = 2\nb = 3\n"
        XCTAssertEqual(regions(text), ["0-5", "2-3"])
        let table = FoldRegions.compute(Array(text.utf16), tabWidth: 4)
        XCTAssertEqual(table.parents, [-1, 0])
        XCTAssertEqual(FoldRegions.lineEnds(Array(text.utf16), tabWidth: 4), [5, -1, 3, -1, -1, -1, -1, -1])
    }

    func testTrailingBlankLinesAreNotPartOfABlock() {
        XCTAssertEqual(regions("a:\n    b\n\n\n"), ["0-1"])
        XCTAssertEqual(regions("a:\n    b"), ["0-1"])                // no final newline
        XCTAssertEqual(regions(""), [])
        XCTAssertEqual(regions("flat\nlines\n"), [])
    }

    func testTabsAreMeasuredByTheTabWidth() {
        XCTAssertEqual(regions("a\n\tb\n  c\n", tabWidth: 4), ["0-2"])
        XCTAssertEqual(regions("a\n\tb\n  c\n", tabWidth: 1), ["0-2", "1-2"])
        XCTAssertEqual(regions("a\n  \tb\n", tabWidth: 4), ["0-1"])
    }

    func testCRLFCountsLikeLF() {
        XCTAssertEqual(regions("a:\r\n    b\r\n\r\n    c\r\nd\r\n"), regions("a:\n    b\n\n    c\nd\n"))
    }

    func testAnOpenBracketAtTheEndOfALineMakesARegionWhereIndentationSaysNothing() {
        XCTAssertEqual(regions("foo(\n1,\n2\n)\n"), ["0-2"])
        XCTAssertEqual(regions("foo(\n)\n"), [])                       // closed on the very next line: nothing to hide
        XCTAssertEqual(regions("foo( 1,\n2\n)\n"), [])                  // the bracket does not end its line
        XCTAssertEqual(regions("a)\nfoo(\n1\n)\n"), ["1-2"])           // a stray closer is ignored
        XCTAssertEqual(regions("x = [\n    1,\n]\n"), ["0-1"])          // indentation and the bracket agree
        XCTAssertEqual(regions("f(\n\"early )\"\n1\n)\n"), [])           // a closer inside a string counts, so the block closes too early
    }

    func testBuildClampsABlockToTheOneItSitsIn() {
        let table = FoldRegions.build(endOf: [3, 5, -1, -1, -1, -1])
        XCTAssertEqual((0..<table.count).map { "\(table.region(at: $0).header)-\(table.region(at: $0).end)" }, ["0-3", "1-3"])
        XCTAssertEqual(table.parents, [-1, 0])
        XCTAssertTrue(FoldRegions.build(endOf: [-1, 0, 1]).isEmpty)     // an end at or before its header is no block
        XCTAssertTrue(FoldRegions.build(endOf: []).isEmpty)
    }

    func testLookups() {
        let table = FoldRegions.compute(Array("a:\n    b:\n        c\n    d\ne\n".utf16), tabWidth: 4)
        XCTAssertEqual(table.count, 2)
        XCTAssertTrue(table.isHeader(0))
        XCTAssertTrue(table.isHeader(1))
        XCTAssertFalse(table.isHeader(2))
        XCTAssertFalse(table.isHeader(9))
        XCTAssertEqual(table.end(ofHeader: 0), 3)
        XCTAssertEqual(table.end(ofHeader: 1), 2)
        XCTAssertNil(table.end(ofHeader: 3))
        XCTAssertEqual(table.enclosing(2), [0, 1])
        XCTAssertEqual(table.enclosing(1), [0])
        XCTAssertEqual(table.enclosing(3), [0])
        XCTAssertEqual(table.enclosing(0), [])
        XCTAssertEqual(table.enclosing(4), [])
        XCTAssertEqual(FoldRegions().enclosing(3), [])
        XCTAssertEqual(table, FoldRegions.compute(Array("a:\n    b:\n        c\n    d\ne\n".utf16), tabWidth: 4))
    }
}

final class FoldingControllerTests: XCTestCase {
    /// Lines: 0 "class A:" 1 "    def f(self):" 2 "        return 1" 3 "" 4 "    x = 2" 5 "print(A)" 6 "".
    /// The block under line 1 hides characters 25..<42; the one under line 0 hides 8..<53.
    private let sample = "class A:\n    def f(self):\n        return 1\n\n    x = 2\nprint(A)\n"
    private let inner = NSRange(location: 25, length: 17)
    private let outer = NSRange(location: 8, length: 45)

    func testBlockEndsComeFromTheLinesOrAnOpenBracket() {
        let editor = HeadlessEditor(sample)
        XCTAssertEqual(editor.folding.blockEnd(ofHeader: 0), 4)
        XCTAssertEqual(editor.folding.blockEnd(ofHeader: 1), 2)
        XCTAssertNil(editor.folding.blockEnd(ofHeader: 2))
        XCTAssertNil(editor.folding.blockEnd(ofHeader: 3))
        XCTAssertNil(editor.folding.blockEnd(ofHeader: 5))
        let brackets = HeadlessEditor("foo(\n1,\n2\n)\nbar(\n)\n")
        XCTAssertEqual(brackets.folding.blockEnd(ofHeader: 0), 2)
        XCTAssertNil(brackets.folding.blockEnd(ofHeader: 4))
    }

    func testFoldHidesFromTheHeaderTextToTheBlockEnd() {
        let editor = HeadlessEditor(sample)
        editor.select(30)                                   // inside what is about to be hidden
        var changes = 0
        editor.folding.onChange = { changes += 1 }
        XCTAssertTrue(editor.folding.fold(line: 1))
        XCTAssertEqual(editor.folding.folds, [inner])
        XCTAssertTrue(editor.folding.hasFolds)
        XCTAssertTrue(editor.folding.isFolded(line: 1))
        XCTAssertFalse(editor.folding.isFolded(line: 0))
        XCTAssertEqual(editor.selection, NSRange(location: 25, length: 0))    // the caret waits at the doorstep
        XCTAssertEqual(changes, 1)
        XCTAssertFalse(editor.folding.fold(line: 1))       // already folded
        XCTAssertFalse(editor.folding.fold(line: 2))       // opens no block
        XCTAssertTrue(editor.folding.unfold(line: 1))
        XCTAssertFalse(editor.folding.unfold(line: 1))
        XCTAssertEqual(editor.folding.folds, [])
        editor.folding.toggle(line: 1)
        XCTAssertEqual(editor.folding.folds, [inner])
        editor.folding.toggle(line: 1)
        XCTAssertEqual(editor.folding.folds, [])
    }

    func testHiddenRangeLookups() {
        let editor = HeadlessEditor(sample)
        editor.folding.fold(line: 1)
        XCTAssertNil(editor.folding.hiddenRange(containing: 25))               // the doorstep is on the header
        XCTAssertEqual(editor.folding.hiddenRange(containing: 26), inner)
        XCTAssertEqual(editor.folding.hiddenRange(containing: 42), inner)      // the hidden end of a hidden line
        XCTAssertNil(editor.folding.hiddenRange(containing: 43))
        XCTAssertEqual(editor.folding.hiddenRange(startingIn: NSRange(location: 9, length: 17)), inner)
        XCTAssertNil(editor.folding.hiddenRange(startingIn: NSRange(location: 0, length: 9)))
    }

    func testCaretsStepOverAFoldAndSelectionsStretchAroundIt() {
        let editor = HeadlessEditor(sample)
        editor.folding.fold(line: 1)
        XCTAssertEqual(editor.folding.steppingOver(from: 25, to: 26), 43)     // one step right crosses it
        XCTAssertEqual(editor.folding.steppingOver(from: 50, to: 30), 25)     // anything else stops at the doorstep
        XCTAssertEqual(editor.folding.steppingOver(from: 0, to: 5), 5)
        XCTAssertEqual(editor.folding.adjustedSelection(from: NSRange(location: 25, length: 0), to: NSRange(location: 25, length: 10)),
                       NSRange(location: 25, length: 17))
        XCTAssertEqual(editor.folding.adjustedSelection(from: NSRange(location: 25, length: 0), to: NSRange(location: 30, length: 0)),
                       NSRange(location: 43, length: 0))                                          // a caret: the stepping rule
        XCTAssertEqual(editor.folding.adjustedSelection(from: NSRange(location: 60, length: 0), to: NSRange(location: 30, length: 0)),
                       NSRange(location: 25, length: 0))
        // A selection that lands inside from elsewhere (Find) opens the fold instead.
        XCTAssertEqual(editor.folding.adjustedSelection(from: NSRange(location: 0, length: 0), to: NSRange(location: 30, length: 3)),
                       NSRange(location: 30, length: 3))
        XCTAssertEqual(editor.folding.folds, [])
    }

    func testFoldsMoveWithEditsAndOpenWhenReachedInto() {
        let editor = HeadlessEditor(sample)
        editor.folding.fold(line: 1)
        editor.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
        editor.folding.noteEdit(NSRange(location: 0, length: 2), delta: 2)
        XCTAssertEqual(editor.folding.folds, [NSRange(location: 27, length: 17)])
        XCTAssertTrue(editor.gutter.lineTableMatchesFullRebuild)
        editor.storage.replaceCharacters(in: NSRange(location: 60, length: 0), with: "!")   // after the fold
        editor.folding.noteEdit(NSRange(location: 60, length: 1), delta: 1)
        XCTAssertEqual(editor.folding.folds, [NSRange(location: 27, length: 17)])
        editor.storage.replaceCharacters(in: NSRange(location: 30, length: 1), with: "")    // inside it
        editor.folding.noteEdit(NSRange(location: 30, length: 0), delta: -1)
        XCTAssertEqual(editor.folding.folds, [])
    }

    func testReturnAtTheDoorstepOpensTheFoldButTypingThereDoesNot() {
        let typed = HeadlessEditor(sample)
        typed.folding.fold(line: 1)
        typed.storage.replaceCharacters(in: NSRange(location: 25, length: 0), with: ":")
        typed.folding.noteEdit(NSRange(location: 25, length: 1), delta: 1)
        XCTAssertEqual(typed.folding.folds, [NSRange(location: 26, length: 17)])
        let returned = HeadlessEditor(sample)
        returned.folding.fold(line: 1)
        returned.storage.replaceCharacters(in: NSRange(location: 25, length: 0), with: "\n")
        returned.folding.noteEdit(NSRange(location: 25, length: 1), delta: 1)
        XCTAssertEqual(returned.folding.folds, [])
    }

    func testRevealOpensOnlyTheFoldsThatHideTheRange() {
        let editor = HeadlessEditor(sample + "def g():\n    pass\n")
        editor.folding.fold(line: 1)
        editor.folding.fold(line: 6)
        XCTAssertEqual(editor.folding.folds.count, 2)
        editor.folding.reveal(NSRange(location: 0, length: 3))
        XCTAssertEqual(editor.folding.folds.count, 2)
        editor.folding.reveal(NSRange(location: 30, length: 1))
        XCTAssertEqual(editor.folding.folds.count, 1)
        XCTAssertFalse(editor.folding.isFolded(line: 1))
        XCTAssertTrue(editor.folding.isFolded(line: 6))
    }

    func testFoldAllAndUnfoldAll() {
        let editor = HeadlessEditor(sample)
        editor.select(30)
        editor.folding.foldAll()
        XCTAssertEqual(editor.folding.folds, [outer, inner])
        XCTAssertEqual(editor.folding.regions.count, 2)
        XCTAssertEqual(editor.folding.hiddenRange(containing: 30), outer)     // nested folds are one hidden stretch
        XCTAssertEqual(editor.selection, NSRange(location: 8, length: 0))
        XCTAssertEqual(editor.folding.hiddenRange(containing: 53), outer)
        XCTAssertNil(editor.folding.hiddenRange(containing: 54))
        editor.folding.unfoldAll()
        XCTAssertEqual(editor.folding.folds, [])
        XCTAssertFalse(editor.folding.hasFolds)
    }

    func testFoldAtCaretFindsTheInnermostBlockAroundTheLine() {
        let editor = HeadlessEditor(sample)
        editor.select(30)                                   // on line 2, which opens nothing of its own
        editor.folding.foldAtCaret()
        XCTAssertEqual(editor.folding.folds, [inner])
        editor.folding.unfoldAtCaret()                      // the caret is now on line 1, the folded header
        XCTAssertEqual(editor.folding.folds, [])
        editor.select(44)                                   // line 4: inside class A only
        editor.folding.foldAtCaret()
        XCTAssertEqual(editor.folding.folds, [outer])
    }

    func testRestoreBringsBackOnlyFoldsThatStillFitTheText() {
        let editor = HeadlessEditor(sample)
        editor.folding.restore([NSRange(location: 25, length: 10), inner, NSRange(location: 900, length: 5), NSRange(location: 8, length: 0)])
        XCTAssertEqual(editor.folding.folds, [inner])
        let fresh = HeadlessEditor(sample)
        fresh.folding.restore([inner, outer])
        XCTAssertEqual(fresh.folding.folds, [outer, inner])                    // sorted by where they start
        fresh.folding.restore([])
        XCTAssertEqual(fresh.folding.folds, [outer, inner])
    }

    func testATreeTableIsAdoptedAndUsedForFolding() {
        let editor = HeadlessEditor(sample)
        var changes = 0
        editor.folding.onChange = { changes += 1 }
        let table = FoldRegions.build(endOf: [2, -1, -1, -1, -1, -1, -1])
        editor.folding.adopt(table)
        XCTAssertEqual(editor.folding.regions, table)
        XCTAssertEqual(changes, 1)
        editor.folding.adopt(table)                          // the same table again: nothing to tell
        XCTAssertEqual(changes, 1)
        editor.folding.treeRegions = { table }
        XCTAssertEqual(editor.folding.blockEnd(ofHeader: 0), 2)                // the tree's block, not the indentation's
        XCTAssertEqual(editor.folding.blockEnd(ofHeader: 1), 2)                // not in the table: read from the lines
        editor.folding.treeRegions = { nil }
        XCTAssertEqual(editor.folding.blockEnd(ofHeader: 0), 4)
    }

    func testScheduledRegionsArriveOffTheMainThread() {
        let editor = HeadlessEditor(sample)
        var changes = 0
        editor.folding.onChange = { changes += 1 }
        editor.folding.scheduleRegions(after: 0)
        XCTAssertTrue(TestSupport.wait(upTo: 5) { changes == 1 })
        XCTAssertEqual(editor.folding.regions.count, 2)
        editor.folding.usesTreeRegions = true
        editor.folding.scheduleRegions(after: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(changes, 1)                           // with a tree, the table is the tree's business
    }
}
