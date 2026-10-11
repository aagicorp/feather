import XCTest
@testable import Feather

/// Git/GitDiff.swift: cutting `git diff -U0` output into blocks, splitting file bytes into lines (CRLF, no
/// newline at the end), the side-by-side rows with their folds, word-level change spans, making one block into
/// a patch of its own (forwards and turned around), and loading and applying blocks against a real repository.
final class GitDiffParsingTests: XCTestCase {
    private func parse(_ text: String) -> (header: String, hunks: [DiffHunk]) {
        let (header, hunks) = FileDiff.parse(Data(text.utf8))
        return (String(decoding: header, as: UTF8.self), hunks)
    }

    func testHeaderAndBlocksAreCutApart() {
        let diff = """
        diff --git a/f.txt b/f.txt
        index 1111111..2222222 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -2 +2 @@
        -two
        +TWO
        @@ -5,0 +6,2 @@ func name()
        +six
        +seven

        """
        let (header, hunks) = parse(diff)
        XCTAssertEqual(header, "diff --git a/f.txt b/f.txt\nindex 1111111..2222222 100644\n--- a/f.txt\n+++ b/f.txt\n")
        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks[0].oldStart, 1)
        XCTAssertEqual(hunks[0].oldCount, 1)
        XCTAssertEqual(hunks[0].newStart, 1)
        XCTAssertEqual(hunks[0].newCount, 1)
        XCTAssertEqual(String(decoding: hunks[0].patch, as: UTF8.self), "@@ -2 +2 @@\n-two\n+TWO\n")
        // A block of only new lines names the line it goes after ("-5,0"), so its old start is that line itself.
        XCTAssertEqual(hunks[1].oldStart, 5)
        XCTAssertEqual(hunks[1].oldCount, 0)
        XCTAssertEqual(hunks[1].newStart, 5)
        XCTAssertEqual(hunks[1].newCount, 2)
        XCTAssertTrue(String(decoding: hunks[1].patch, as: UTF8.self).hasPrefix("@@ -5,0 +6,2 @@ func name()\n"))
    }

    func testABlockThatOnlyRemovesLines() {
        let (_, hunks) = parse("@@ -3,2 +2,0 @@\n-c\n-d\n")
        XCTAssertEqual(hunks[0].oldStart, 2)
        XCTAssertEqual(hunks[0].oldCount, 2)
        XCTAssertEqual(hunks[0].newStart, 2)
        XCTAssertEqual(hunks[0].newCount, 0)
    }

    func testNoBlocksMeansEverythingIsHeader() {
        let (header, hunks) = parse("diff --git a/f b/f\nBinary files differ\n")
        XCTAssertEqual(header, "diff --git a/f b/f\nBinary files differ\n")
        XCTAssertTrue(hunks.isEmpty)
        XCTAssertTrue(FileDiff.parse(Data()).hunks.isEmpty)
    }

    func testAMalformedBlockHeaderIsSkipped() {
        let (_, hunks) = parse("@@ -x +1 @@\n+a\n@@ -1 +1 @@\n-a\n+b\n")
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].oldStart, 0)
    }

    func testABlockWhoseLinesAreNotUTF8StaysBytes() {
        var data = Data("@@ -1 +1 @@\n-".utf8)
        data.append(contentsOf: [0xFF, 0xFE, 0x0A])
        data.append(contentsOf: "+ok\n".utf8)
        let (_, hunks) = FileDiff.parse(data)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].patch, data)
    }

    // MARK: - Lines

    func testLinesSplitOnNewlineAndDropTheCarriageReturn() {
        XCTAssertEqual(FileDiff.lines(of: Data()), [])
        XCTAssertEqual(FileDiff.lines(of: Data("a\nb\n".utf8)), ["a", "b"])
        XCTAssertEqual(FileDiff.lines(of: Data("a\nb".utf8)), ["a", "b"])
        XCTAssertEqual(FileDiff.lines(of: Data("a\r\nb\r\n".utf8)), ["a", "b"])
        XCTAssertEqual(FileDiff.lines(of: Data("\n\n".utf8)), ["", ""])
        XCTAssertEqual(FileDiff.lines(of: Data("\n".utf8)), [""])
        XCTAssertEqual(FileDiff.lines(of: Data("héllo\u{1F600}\n".utf8)), ["héllo\u{1F600}"])
    }

    // MARK: - Rows

    private func diff(old: Int, new: Int, hunks: [DiffHunk]) -> FileDiff {
        var diff = FileDiff()
        diff.oldLines = (0..<old).map { "old \($0)" }
        diff.newLines = (0..<new).map { "new \($0)" }
        diff.hunks = hunks
        return diff
    }

    func testRowsShowContextAroundABlockAndFoldTheRest() {
        // 20 lines, line 10 changed: 3 context lines each side, folds for the rest.
        let hunk = DiffHunk(oldStart: 10, oldCount: 1, newStart: 10, newCount: 1, patch: Data())
        let rows = diff(old: 20, new: 20, hunks: [hunk]).rows()
        XCTAssertEqual(rows.map(\.kind), [.fold, .context, .context, .context, .changed, .context, .context, .context, .fold])
        XCTAssertEqual(rows[0].count, 7)
        XCTAssertEqual(rows[0].old, 0)
        XCTAssertEqual(rows[4].hunk, 0)
        XCTAssertEqual(rows[4].old, 10)
        XCTAssertEqual(rows[4].new, 10)
        XCTAssertEqual(rows[8].count, 6)
        XCTAssertEqual(rows[8].old, 14)
        XCTAssertEqual(FileDiff.expanded(rows[0]).map(\.old), Array(0..<7))
    }

    func testAShortGapIsNotFolded() {
        // Between the two blocks there are 8 unchanged lines: 3 + 3 context and only 2 more, so they are all shown.
        let hunks = [DiffHunk(oldStart: 0, oldCount: 1, newStart: 0, newCount: 1, patch: Data()),
                     DiffHunk(oldStart: 9, oldCount: 1, newStart: 9, newCount: 1, patch: Data())]
        let rows = diff(old: 10, new: 10, hunks: hunks).rows()
        XCTAssertFalse(rows.contains { $0.kind == .fold })
        XCTAssertEqual(rows.count, 10)
    }

    func testUnevenBlocksHaveBlankSides() {
        let hunk = DiffHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 3, patch: Data())
        let rows = diff(old: 3, new: 5, hunks: [hunk]).rows()
        XCTAssertEqual(rows.map(\.kind), [.context, .changed, .added, .added, .context])
        XCTAssertEqual(rows[2].old, -1)
        XCTAssertEqual(rows[2].new, 2)
        XCTAssertEqual(rows[4].old, 2)
        XCTAssertEqual(rows[4].new, 4)
        let removal = DiffHunk(oldStart: 1, oldCount: 2, newStart: 1, newCount: 0, patch: Data())
        XCTAssertEqual(diff(old: 3, new: 1, hunks: [removal]).rows().map(\.kind), [.context, .removed, .removed])
    }

    func testAFileWithNoBlocksIsAllContext() {
        let rows = diff(old: 4, new: 4, hunks: []).rows()
        XCTAssertEqual(rows.map(\.kind), [.context, .context, .context, .context])
        XCTAssertTrue(diff(old: 0, new: 0, hunks: []).rows().isEmpty)
    }

    // MARK: - Changed spans

    func testChangedSpansAreWholeWords() {
        let spans = FileDiff.changedSpans("let value = compute(a, b)", "let result = compute(a, c)")
        XCTAssertEqual(spans.old, [NSRange(location: 4, length: 5), NSRange(location: 23, length: 1)])
        XCTAssertEqual(spans.new, [NSRange(location: 4, length: 6), NSRange(location: 24, length: 1)])
    }

    func testChangedSpansMergeNeighbouringTokens() {
        let spans = FileDiff.changedSpans("a b", "a b c d")
        XCTAssertEqual(spans.old, [])
        XCTAssertEqual(spans.new, [NSRange(location: 3, length: 4)])
        XCTAssertEqual(FileDiff.changedSpans("same", "same").old, [])
    }

    func testChangedSpansCountUTF16Units() {
        let spans = FileDiff.changedSpans("é 😀 x", "é 😀 y")
        XCTAssertEqual(spans.old, [NSRange(location: 5, length: 1)])
        XCTAssertEqual(spans.new, [NSRange(location: 5, length: 1)])
    }

    func testVeryLongLinesFallBackToTheDifferingMiddle() {
        let old = String(repeating: "a ", count: 300) + "X" + String(repeating: " b", count: 300)
        let new = String(repeating: "a ", count: 300) + "YY" + String(repeating: " b", count: 300)
        let spans = FileDiff.changedSpans(old, new)
        XCTAssertEqual(spans.old, [NSRange(location: 600, length: 1)])
        XCTAssertEqual(spans.new, [NSRange(location: 600, length: 2)])
    }

    // MARK: - Standalone blocks

    private func standalone(_ patch: String, reversed: Bool) -> String? {
        FileDiff.standalone(Data(patch.utf8), reversed: reversed).map { String(decoding: $0, as: UTF8.self) }
    }

    func testAForwardBlockKeepsItsOldSideAndRecountsTheNew() {
        // As `git diff` wrote it, the new-side number counts an earlier block's two added lines.
        XCTAssertEqual(standalone("@@ -7 +9 @@\n-old\n+new\n", reversed: false), "@@ -7,1 +7,1 @@\n-old\n+new\n")
        XCTAssertEqual(standalone("@@ -7,0 +10,2 @@\n+a\n+b\n", reversed: false), "@@ -7,0 +8,2 @@\n+a\n+b\n")
        XCTAssertEqual(standalone("@@ -7,2 +8,0 @@\n-a\n-b\n", reversed: false), "@@ -7,2 +6,0 @@\n-a\n-b\n")
    }

    func testAReversedBlockSwapsTheSides() {
        XCTAssertEqual(standalone("@@ -7 +9 @@\n-old\n+new\n", reversed: true), "@@ -9,1 +9,1 @@\n-new\n+old\n")
        // Lines that were added are taken away: the block now names them on its "-" side.
        XCTAssertEqual(standalone("@@ -7,0 +10,2 @@\n+a\n+b\n", reversed: true), "@@ -10,2 +9,0 @@\n-a\n-b\n")
        XCTAssertEqual(standalone("@@ -7,2 +8,0 @@\n-a\n-b\n", reversed: true), "@@ -8,0 +9,2 @@\n+a\n+b\n")
    }

    func testTheNoNewlineNoteTravelsWithItsLine() {
        let patch = "@@ -3 +3 @@\n-three\n\\ No newline at end of file\n+THREE\n\\ No newline at end of file\n"
        XCTAssertEqual(standalone(patch, reversed: true),
                       "@@ -3,1 +3,1 @@\n-THREE\n\\ No newline at end of file\n+three\n\\ No newline at end of file\n")
        let addedNewline = "@@ -3 +3 @@\n-three\n\\ No newline at end of file\n+three\n"
        XCTAssertEqual(standalone(addedNewline, reversed: true), "@@ -3,1 +3,1 @@\n-three\n+three\n\\ No newline at end of file\n")
    }

    func testABlockWithContextOrABadHeaderIsRefused() {
        XCTAssertNil(standalone("@@ -1,2 +1,2 @@\n a\n-b\n+c\n", reversed: false))
        XCTAssertNil(standalone("not a block\n", reversed: false))
        XCTAssertNil(standalone("", reversed: false))
    }

    func testBlockActionsUseTheIndexOrTheWorkingTree() {
        XCTAssertTrue(FileDiff.BlockAction.stage.arguments.contains("--cached"))
        XCTAssertTrue(FileDiff.BlockAction.unstage.arguments.contains("--cached"))
        XCTAssertFalse(FileDiff.BlockAction.revert.arguments.contains("--cached"))
        XCTAssertEqual(DiffSide.workingTree.label, "Working Tree")
        XCTAssertEqual(DiffSide.index.label, "Index")
    }

    func testProblemMessagesAreForPeople() {
        XCTAssertTrue(FileDiff.Problem.binary.message.contains("binary"))
        XCTAssertTrue(FileDiff.Problem.tooLarge.message.contains("too large"))
        XCTAssertTrue(FileDiff.Problem.restricted.message.contains("Restricted Mode"))
        XCTAssertEqual(FileDiff.Problem.failed("boom").message, "boom")
    }
}

/// `FileDiff.load` and `apply` against a throwaway repository, off the main thread as in the app.
final class GitDiffRepositoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try TestSupport.makeRepository(["f.txt": (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func load(_ path: String = "f.txt", originalPath: String? = nil, side: DiffSide = .workingTree) -> Result<FileDiff, FileDiff.Problem>? {
        var result: Result<FileDiff, FileDiff.Problem>?
        let done = expectation(description: "load")
        DispatchQueue.global().async {
            result = FileDiff.load(root: self.root, path: path, originalPath: originalPath, side: side)
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        return result
    }

    private func problem(_ result: Result<FileDiff, FileDiff.Problem>?) -> FileDiff.Problem? {
        if case .failure(let problem)? = result { return problem }
        return nil
    }

    private func write(_ lines: [String], to name: String = "f.txt", terminator: String = "\n") throws {
        try (lines.joined(separator: terminator) + terminator).write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func fileText(_ name: String = "f.txt") throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    func testAnUnchangedFileHasNoBlocks() throws {
        guard case .success(let diff) = try XCTUnwrap(load()) else { return XCTFail("load failed") }
        XCTAssertTrue(diff.hunks.isEmpty)
        XCTAssertEqual(diff.oldLines.count, 12)
        XCTAssertEqual(diff.insertions + diff.deletions, 0)
        XCTAssertFalse(diff.canPatchBlocks)
    }

    func testThreeSeparateEditsAreThreeBlocks() throws {
        var lines = (1...12).map { "line \($0)" }
        lines[1] = "LINE 2"
        lines.insert("extra", at: 6)
        lines.remove(at: 11)
        try write(lines)
        guard case .success(let diff) = try XCTUnwrap(load()) else { return XCTFail("load failed") }
        XCTAssertEqual(diff.hunks.count, 3)
        XCTAssertTrue(diff.canPatchBlocks)
        XCTAssertEqual(diff.insertions, 2)
        XCTAssertEqual(diff.deletions, 2)
        XCTAssertEqual(diff.hunks.map(\.newStart), [1, 6, 11])
        XCTAssertEqual(diff.newLines, lines)
        XCTAssertTrue(String(decoding: diff.header, as: UTF8.self).hasPrefix("diff --git"))
    }

    func testStagingOneBlockLeavesTheOthersUnstaged() throws {
        var lines = (1...12).map { "line \($0)" }
        lines[1] = "LINE 2"
        lines.insert("extra", at: 6)
        lines.remove(at: 11)
        try write(lines)
        guard case .success(let diff) = try XCTUnwrap(load()) else { return XCTFail("load failed") }
        let staged = diff.apply(.stage, hunk: 1, root: root)
        XCTAssertTrue(staged.ok, staged.message)
        let index = Git.runSync(["show", ":f.txt"], in: root).output
        var expected = (1...12).map { "line \($0)" }
        expected.insert("extra", at: 6)
        XCTAssertEqual(index, expected.joined(separator: "\n") + "\n")
        // The working tree is untouched; the diff against the index now has two blocks.
        XCTAssertEqual(try fileText(), lines.joined(separator: "\n") + "\n")
        guard case .success(let remaining) = try XCTUnwrap(load()) else { return XCTFail("load failed") }
        XCTAssertEqual(remaining.hunks.count, 2)
        // And the index side shows the one staged block, which can be unstaged again.
        guard case .success(let indexSide) = try XCTUnwrap(load(side: .index)) else { return XCTFail("load failed") }
        XCTAssertEqual(indexSide.hunks.count, 1)
        XCTAssertTrue(indexSide.apply(.unstage, hunk: 0, root: root).ok)
        XCTAssertEqual(Git.runSync(["show", ":f.txt"], in: root).output, (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n")
    }

    func testRevertingOneBlockPutsTheOldLinesBack() throws {
        var lines = (1...12).map { "line \($0)" }
        lines[1] = "LINE 2"
        lines[9] = "LINE 10"
        try write(lines)
        guard case .success(let diff) = try XCTUnwrap(load()) else { return XCTFail("load failed") }
        let reverted = diff.apply(.revert, hunk: 1, root: root)
        XCTAssertTrue(reverted.ok, reverted.message)
        lines[9] = "line 10"
        XCTAssertEqual(try fileText(), lines.joined(separator: "\n") + "\n")
        // Reverting the same block again does not apply: the file has moved on.
        XCTAssertFalse(diff.apply(.revert, hunk: 1, root: root).ok)
        XCTAssertFalse(diff.apply(.revert, hunk: 5, root: root).ok, "an index outside the blocks is refused")
    }

    func testWindowsLineEndingsSurviveARevert() throws {
        try write(["one", "two", "three"], to: "crlf.txt", terminator: "\r\n")
        TestSupport.git(["add", "crlf.txt"], in: root)
        TestSupport.git(["commit", "-qm", "crlf"], in: root)
        try write(["one", "TWO", "three"], to: "crlf.txt", terminator: "\r\n")
        guard case .success(let diff) = try XCTUnwrap(load("crlf.txt")) else { return XCTFail("load failed") }
        XCTAssertEqual(diff.oldLines, ["one", "two", "three"])
        XCTAssertEqual(diff.newLines, ["one", "TWO", "three"])
        XCTAssertEqual(diff.hunks.count, 1)
        XCTAssertTrue(diff.apply(.revert, hunk: 0, root: root).ok)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("crlf.txt")), Data("one\r\ntwo\r\nthree\r\n".utf8))
    }

    func testAMissingFinalNewlineIsKept() throws {
        try "a\nb".write(to: root.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        TestSupport.git(["commit", "-qam", "no newline"], in: root)
        try "a\nB".write(to: root.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        guard case .success(let diff) = try XCTUnwrap(load()) else { return XCTFail("load failed") }
        XCTAssertEqual(diff.newLines, ["a", "B"])
        XCTAssertTrue(String(decoding: diff.hunks[0].patch, as: UTF8.self).contains("\\ No newline at end of file"))
        XCTAssertTrue(diff.apply(.stage, hunk: 0, root: root).ok)
        XCTAssertEqual(Git.runSync(["show", ":f.txt"], in: root).output, "a\nB")
    }

    func testAnUntrackedFileIsOneBlockThatCannotBePatched() throws {
        try write(["new", "file"], to: "new.txt")
        guard case .success(let diff) = try XCTUnwrap(load("new.txt")) else { return XCTFail("load failed") }
        XCTAssertEqual(diff.hunks.count, 1)
        XCTAssertEqual(diff.hunks[0].newCount, 2)
        XCTAssertEqual(diff.hunks[0].oldCount, 0)
        XCTAssertFalse(diff.canPatchBlocks)
        XCTAssertEqual(diff.insertions, 2)
        XCTAssertFalse(diff.apply(.stage, hunk: 0, root: root).ok)
    }

    func testANewlyAddedFileCannotBePatchedBlockByBlock() throws {
        try write(["new", "file"], to: "added.txt")
        TestSupport.git(["add", "added.txt"], in: root)
        guard case .success(let diff) = try XCTUnwrap(load("added.txt", side: .index)) else { return XCTFail("load failed") }
        XCTAssertEqual(diff.hunks.count, 1)
        XCTAssertFalse(diff.canPatchBlocks, "git wrote 'new file mode', so the block is not applied alone")
    }

    func testARenamedFileComparesAgainstItsOldName() throws {
        TestSupport.git(["mv", "f.txt", "g.txt"], in: root)
        var lines = (1...12).map { "line \($0)" }
        lines[0] = "LINE 1"
        try write(lines, to: "g.txt")
        TestSupport.git(["add", "g.txt"], in: root)
        guard case .success(let diff) = try XCTUnwrap(load("g.txt", originalPath: "f.txt", side: .index)) else { return XCTFail("load failed") }
        XCTAssertEqual(diff.oldLines.count, 12)
        XCTAssertEqual(diff.hunks.count, 1)
        XCTAssertFalse(diff.canPatchBlocks)
    }

    func testBinaryAndHugeFilesAreRefused() throws {
        var bytes = Data(count: 100)
        bytes[10] = 0
        try bytes.write(to: root.appendingPathComponent("blob.bin"))
        TestSupport.git(["add", "blob.bin"], in: root)
        TestSupport.git(["commit", "-qm", "binary"], in: root)
        bytes[20] = 7
        try bytes.write(to: root.appendingPathComponent("blob.bin"))
        XCTAssertEqual(problem(load("blob.bin")), .binary)
        let huge = Data(repeating: UInt8(ascii: "x"), count: FileDiff.maxBytes + 1)
        try huge.write(to: root.appendingPathComponent("huge.txt"))
        XCTAssertEqual(problem(load("huge.txt")), .tooLarge)
    }

    func testLoadOutsideARepositoryFails() throws {
        let plain = TestSupport.temporaryDirectory("feather-plain")
        defer { try? FileManager.default.removeItem(at: plain) }
        try "x\n".write(to: plain.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        var result: Result<FileDiff, FileDiff.Problem>?
        let done = expectation(description: "load")
        DispatchQueue.global().async {
            result = FileDiff.load(root: plain, path: "f.txt", originalPath: nil, side: .workingTree)
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        guard case .failure(.failed(let message)) = result else { return XCTFail("expected a failure, got \(String(describing: result))") }
        XCTAssertFalse(message.isEmpty)
    }
}
