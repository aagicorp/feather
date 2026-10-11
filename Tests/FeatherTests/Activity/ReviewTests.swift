import XCTest
@testable import Feather

/// Undoing one block of a file without git (Activity/HunkPatch.swift), against blocks cut by `FileDiff.parse`
/// from hand-written `git diff -U0` output and, further down, against blocks a real checkpoint store produced.
final class HunkPatchTests: XCTestCase {
    private func hunks(_ diff: String) -> [DiffHunk] { FileDiff.parse(Data(diff.utf8)).hunks }

    private func undo(_ hunk: DiffHunk, _ text: String) -> String? {
        HunkPatch.undo(hunk, in: Data(text.utf8)).map { String(decoding: $0.data, as: UTF8.self) }
    }

    func testUndoingTheMiddleOfThreeBlocksLeavesTheOthers() {
        let before = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"
        var lines = (1...12).map { "line \($0)" }
        lines[1] = "LINE 2 changed"          // block 0: one line changed
        lines.insert("an extra line", at: 6) // block 1: one line added after line 6
        lines.remove(at: 11)                 // block 2: line 11 taken away
        let after = lines.joined(separator: "\n") + "\n"
        let diff = """
        diff --git a/f.txt b/f.txt
        --- a/f.txt
        +++ b/f.txt
        @@ -2 +2 @@
        -line 2
        +LINE 2 changed
        @@ -6,0 +7 @@
        +an extra line
        @@ -11 +11,0 @@
        -line 11

        """
        let blocks = hunks(diff)
        XCTAssertEqual(blocks.count, 3)
        // Undo the middle block only: the extra line goes, the other two changes stay.
        var expected = lines
        expected.remove(at: 6)
        XCTAssertEqual(undo(blocks[1], after), expected.joined(separator: "\n") + "\n")
        // The first block alone, and the last block alone.
        var first = lines
        first[1] = "line 2"
        XCTAssertEqual(undo(blocks[0], after), first.joined(separator: "\n") + "\n")
        var last = lines
        last.insert("line 11", at: 11)
        XCTAssertEqual(undo(blocks[2], after), last.joined(separator: "\n") + "\n")
        // All three, one after another (line numbers of the later blocks still hold because each earlier block
        // is undone at its own place): back to the start.
        var text = after
        for block in blocks.reversed() { text = undo(block, text) ?? "" }
        XCTAssertEqual(text, before)
    }

    func testABlockThatNoLongerMatchesIsRefused() {
        let blocks = hunks("@@ -2 +2 @@\n-line 2\n+LINE 2\n")
        XCTAssertNil(undo(blocks[0], "line 1\nsomething else\nline 3\n"))
        XCTAssertNil(undo(blocks[0], "line 1\n"))        // too short
    }

    func testWindowsLineEndingsComeThrough() {
        let after = "one\r\ntwo changed\r\nthree\r\n"
        let blocks = hunks("@@ -2 +2 @@\n-two\r\n+two changed\r\n")
        XCTAssertEqual(undo(blocks[0], after), "one\r\ntwo\r\nthree\r\n")
    }

    func testAMissingFinalNewlineComesThrough() {
        // The last line changed; neither version ends in a newline.
        let blocks = hunks("@@ -3 +3 @@\n-three\n\\ No newline at end of file\n+THREE\n\\ No newline at end of file\n")
        XCTAssertEqual(undo(blocks[0], "one\ntwo\nTHREE"), "one\ntwo\nthree")
        // The change added the final newline; undoing takes it away again.
        let added = hunks("@@ -3 +3 @@\n-three\n\\ No newline at end of file\n+three\n")
        XCTAssertEqual(undo(added[0], "one\ntwo\nthree\n"), "one\ntwo\nthree")
        // A block before the end leaves the file's missing newline alone.
        let early = hunks("@@ -1 +1 @@\n-one\n+ONE\n")
        XCTAssertEqual(undo(early[0], "ONE\ntwo\nthree"), "one\ntwo\nthree")
    }

    func testLinesAddedAtTheVeryEnd() {
        let blocks = hunks("@@ -2,0 +3,2 @@\n+three\n+four\n")
        XCTAssertEqual(undo(blocks[0], "one\ntwo\nthree\nfour\n"), "one\ntwo\n")
    }

    func testTheSameUndoAsAnEditorEdit() {
        let after = "one\ntwo changed\nthree\n"
        let blocks = hunks("@@ -2 +2 @@\n-two\n+two changed\n")
        let edit = HunkPatch.edit(for: blocks[0], in: after, encoding: .utf8)
        XCTAssertEqual(edit, RangeEdit(range: NSRange(location: 4, length: 12), text: "two\n"))
        XCTAssertNil(HunkPatch.edit(for: blocks[0], in: "one\ntwo edited\nthree\n", encoding: .utf8))
        XCTAssertNil(HunkPatch.edit(for: blocks[0], in: after, encoding: .utf16))
    }

    func testTheSidesOfABlock() {
        let sides = HunkPatch.sides(of: Data("@@ -1,2 +1,1 @@\n-a\n-b\n+c\n\\ No newline at end of file\n".utf8))
        XCTAssertEqual(sides?.old.map { String(decoding: $0, as: UTF8.self) }, ["a\n", "b\n"])
        XCTAssertEqual(sides?.new.map { String(decoding: $0, as: UTF8.self) }, ["c"])
        // A patch cut short without its final newline still yields whole lines.
        XCTAssertEqual(HunkPatch.sides(of: Data("@@ -1 +1 @@\n-a\n+b".utf8))?.new.map { String(decoding: $0, as: UTF8.self) }, ["b\n"])
        XCTAssertNil(HunkPatch.sides(of: Data("not a block\n-a\n".utf8)))
        XCTAssertNil(HunkPatch.sides(of: Data("@@ -1 +1 @@\n a context line\n".utf8)))
        XCTAssertNil(HunkPatch.sides(of: Data("@@ -1 +1 @@\n\\ No newline at end of file\n".utf8)), "a note before any line belongs to nothing")
        XCTAssertEqual(HunkPatch.sides(of: Data())?.old.count, 0, "no lines at all is still a (useless) block")
    }

    func testABlockWhoseCountsDoNotMatchItsLinesIsRefused() {
        let wrong = DiffHunk(oldStart: 0, oldCount: 1, newStart: 0, newCount: 2, patch: Data("@@ -1 +1,2 @@\n-a\n+b\n".utf8))
        XCTAssertNil(HunkPatch.undo(wrong, in: Data("b\n".utf8)))
        let empty = DiffHunk(oldStart: 0, oldCount: 0, newStart: 0, newCount: 1, patch: Data())
        XCTAssertNil(HunkPatch.undo(empty, in: Data("b\n".utf8)), "a block without a patch (a new file) cannot be undone line by line")
    }

    func testUndoingAtTheVeryStartAndPastTheEnd() {
        let first = hunks("@@ -1 +1 @@\n-a\n+A\n")
        XCTAssertEqual(undo(first[0], "A\nb\n"), "a\nb\n")
        XCTAssertNil(undo(first[0], "A"), "the block's line has a newline and the file's does not: a different line")
        let beyond = hunks("@@ -5 +5 @@\n-e\n+E\n")
        XCTAssertNil(undo(beyond[0], "a\nb\n"), "the block points past the end of the file")
        let appended = hunks("@@ -2,0 +3 @@\n+c\n")
        XCTAssertEqual(undo(appended[0], "a\nb\nc\n"), "a\nb\n")
        XCTAssertNil(undo(appended[0], "a\nb\n"))
    }

    // MARK: - Against a real checkpoint

    private func makeStore() throws -> (root: URL, store: CheckpointStore, base: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("feather-review-\(UUID().uuidString)")
        let root = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CheckpointStore.baseDirectory = base.appendingPathComponent("checkpoints")
        return (root, CheckpointStore.store(for: root), base)
    }

    private func checkpoint(_ store: CheckpointStore) -> Checkpoint? {
        let done = expectation(description: "checkpoint")
        var result: Checkpoint?
        store.newCheckpoint(name: "Test", kind: .manual) { result = try? $0.get(); done.fulfill() }
        wait(for: [done], timeout: 20)
        return result
    }

    private func diff(_ store: CheckpointStore, _ path: String, _ checkpoint: Checkpoint) -> FileDiff? {
        let done = expectation(description: "diff")
        var result: FileDiff?
        store.perform({ store.loadDiff(path: path, since: checkpoint) }) { result = try? $0.get(); done.fulfill() }
        wait(for: [done], timeout: 20)
        return result
    }

    func testUndoingOneBlockOfARealCheckpointDiff() throws {
        let (root, store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = root.appendingPathComponent("a.txt")
        let original = (1...15).map { "row \($0)" }.joined(separator: "\r\n")          // CRLF, no final newline
        try original.write(to: file, atomically: true, encoding: .utf8)
        guard let checkpoint = checkpoint(store) else { return XCTFail("no checkpoint") }
        var rows = (1...15).map { "row \($0)" }
        rows[2] = "row 3 edited"
        rows[7] = "row 8 edited"
        rows[14] = "row 15 edited"
        try rows.joined(separator: "\r\n").write(to: file, atomically: true, encoding: .utf8)
        guard let diff = diff(store, "a.txt", checkpoint) else { return XCTFail("no diff") }
        XCTAssertEqual(diff.hunks.count, 3)
        XCTAssertTrue(diff.canPatchBlocks)
        let data = try Data(contentsOf: file)
        guard let middle = HunkPatch.undo(diff.hunks[1], in: data) else { return XCTFail("the middle block did not apply") }
        rows[7] = "row 8"
        XCTAssertEqual(String(decoding: middle.data, as: UTF8.self), rows.joined(separator: "\r\n"))
        // And the last block, whose line has no newline after it.
        guard let last = HunkPatch.undo(diff.hunks[2], in: data) else { return XCTFail("the last block did not apply") }
        rows[7] = "row 8 edited"
        rows[14] = "row 15"
        XCTAssertEqual(String(decoding: last.data, as: UTF8.self), rows.joined(separator: "\r\n"))
        XCTAssertFalse(last.data.last == 0x0A)
    }

    func testReviewSessionCountsKeptAndUndoneBlocks() {
        let session = ReviewSession()
        let checkpoint = Checkpoint(id: "1", commit: "c", name: "One", date: Date(), kind: .manual)
        session.prepare(for: checkpoint)
        let blocks = hunks("@@ -2 +2 @@\n-a\n+b\n@@ -5 +5 @@\n-c\n+d\n@@ -9 +9 @@\n-a\n+b\n")
        session.note("f.txt", hunks: blocks)
        session.note("new.txt", hunks: [DiffHunk(oldStart: 0, oldCount: 0, newStart: 0, newCount: 3, patch: Data())])
        XCTAssertEqual(session.total, 4)
        XCTAssertEqual(session.reviewed, 0)
        let keys = ReviewSession.keys(for: "f.txt", hunks: blocks)
        XCTAssertNotEqual(keys[0], keys[2], "two blocks with the same lines are still two blocks")
        session.keep(keys[0])
        session.noteUndone(keys[1])
        XCTAssertEqual(session.reviewed, 2)
        XCTAssertEqual(session.total, 4)
        // The file is read again after the undo, with the two blocks that are left; the kept mark survives.
        session.note("f.txt", hunks: [blocks[0], blocks[2]])
        XCTAssertTrue(session.isKept(keys[0]))
        XCTAssertEqual(session.total, 4)
        session.keepAll()
        XCTAssertEqual(session.reviewed, 4)
        // A new checkpoint starts the review over.
        session.prepare(for: Checkpoint(id: "2", commit: "d", name: "Two", date: Date(), kind: .manual))
        XCTAssertEqual(session.total, 0)
        XCTAssertEqual(session.reviewed, 0)
    }
}
