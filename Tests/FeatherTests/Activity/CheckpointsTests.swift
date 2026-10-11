import XCTest
@testable import Feather

/// Activity/Checkpoints.swift: the private checkpoint store, pointed at a scratch base directory. Taking and
/// listing checkpoints, what changed since one (created, changed, deleted, binary, line counts), putting one
/// file or everything back, the safety checkpoint that makes an undo undoable, the built-in excludes and the
/// project's own `.gitignore`, oversized files, unicode names, CRLF, a project with no git of its own and one
/// whose `.git` must stay untouched, pruning, and the age labels. Nothing here touches Application Support.
final class CheckpointsTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var store: CheckpointStore!
    /// Files an undo moved to the Trash, removed again afterwards so nothing of the test lingers there.
    private var trashed: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = TestSupport.temporaryDirectory("feather-checkpoints")
        root = base.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CheckpointStore.baseDirectory = base.appendingPathComponent("store", isDirectory: true)
        store = CheckpointStore.store(for: root)
    }

    override func tearDown() {
        trashed.forEach { try? FileManager.default.removeItem(at: $0) }
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    // MARK: - Helpers

    private func write(_ text: String, to path: String) throws {
        try TestSupport.write([path: text], under: root)
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }

    private func take(_ name: String? = "Test", kind: Checkpoint.Kind = .manual) throws -> Checkpoint {
        var result: Result<Checkpoint, CheckpointStore.CheckpointError>?
        store.newCheckpoint(name: name, kind: kind) { result = $0 }
        XCTAssertTrue(TestSupport.wait(upTo: 30) { result != nil }, "the checkpoint was not taken")
        return try XCTUnwrap(result).get()
    }

    private func checkpoints() -> [Checkpoint] {
        var list: [Checkpoint]?
        store.loadCheckpoints { list = $0 }
        XCTAssertTrue(TestSupport.wait(upTo: 30) { list != nil })
        return list ?? []
    }

    private func changes(since checkpoint: Checkpoint) -> ActivitySnapshot? {
        var snapshot: ActivitySnapshot?
        store.changes(since: checkpoint) { snapshot = $0 }
        XCTAssertTrue(TestSupport.wait(upTo: 30) { snapshot != nil })
        return snapshot
    }

    private func changeOf(_ path: String, since checkpoint: Checkpoint) -> ActivityChange? {
        changes(since: checkpoint)?.changes.first { $0.path == path }
    }

    private func restore(to checkpoint: Checkpoint, only: Set<String>? = nil, skipping: Set<String> = []) -> RestoreOutcome? {
        var outcome: RestoreOutcome?
        store.restore(to: checkpoint, only: only, skipping: skipping) { outcome = $0 }
        XCTAssertTrue(TestSupport.wait(upTo: 30) { outcome != nil })
        trashed += outcome?.trashedURLs ?? []
        return outcome
    }

    // MARK: - Ages

    func testAgeLabels() {
        let now = Date()
        XCTAssertEqual(Checkpoint.age(of: now.addingTimeInterval(-3), now: now), "just now")
        XCTAssertEqual(Checkpoint.age(of: now.addingTimeInterval(-45), now: now), "45 sec ago")
        XCTAssertEqual(Checkpoint.age(of: now.addingTimeInterval(-125), now: now), "2 min ago")
        XCTAssertEqual(Checkpoint.age(of: now.addingTimeInterval(-7200), now: now), "2 hr ago")
        XCTAssertEqual(Checkpoint.age(of: now.addingTimeInterval(-200_000), now: now), "2 d ago")
        XCTAssertEqual(Checkpoint.age(of: now.addingTimeInterval(60), now: now), "just now", "a clock that went backwards is not the future")
        XCTAssertEqual(Checkpoint.shortAge(of: now.addingTimeInterval(-30), now: now), "now")
        XCTAssertEqual(Checkpoint.shortAge(of: now.addingTimeInterval(-600), now: now), "10m")
        XCTAssertEqual(Checkpoint.shortAge(of: now.addingTimeInterval(-7200), now: now), "2h")
        XCTAssertEqual(Checkpoint.shortAge(of: now.addingTimeInterval(-90_000), now: now), "1d")
    }

    func testCountingLines() throws {
        try write("a\nb\n", to: "two.txt")
        try write("a\nb", to: "two-no-newline.txt")
        try write("", to: "empty.txt")
        var binary = Data("text".utf8)
        binary.append(0)
        try binary.write(to: root.appendingPathComponent("blob.bin"))
        XCTAssertEqual(CheckpointStore.countLines(root.appendingPathComponent("two.txt")).lines, 2)
        XCTAssertEqual(CheckpointStore.countLines(root.appendingPathComponent("two-no-newline.txt")).lines, 2)
        XCTAssertEqual(CheckpointStore.countLines(root.appendingPathComponent("empty.txt")).lines, 0)
        let blob = CheckpointStore.countLines(root.appendingPathComponent("blob.bin"))
        XCTAssertNil(blob.lines)
        XCTAssertTrue(blob.isBinary)
        XCTAssertNil(CheckpointStore.countLines(root.appendingPathComponent("missing.txt")).lines)
    }

    // MARK: - Taking checkpoints

    func testStoresAreSharedPerFolderAndBaseDirectory() {
        XCTAssertTrue(CheckpointStore.store(for: root) === store)
        XCTAssertTrue(CheckpointStore.store(for: URL(fileURLWithPath: root.path + "/")) === store, "spelling does not matter")
        XCTAssertFalse(CheckpointStore.store(for: base) === store)
        XCTAssertTrue(store.directory.path.hasPrefix(CheckpointStore.baseDirectory.path))
    }

    func testANewProjectHasNoCheckpoints() {
        XCTAssertTrue(checkpoints().isEmpty)
        XCTAssertTrue(store.checkpoints.isEmpty)
    }

    func testTakingACheckpointListsItNewestFirst() throws {
        try write("one\n", to: "a.txt")
        let first = try take("First")
        XCTAssertEqual(first.name, "First")
        XCTAssertEqual(first.kind, .manual)
        XCTAssertEqual(first.commit.count, 40)
        XCTAssertLessThan(abs(first.date.timeIntervalSinceNow), 5)
        let second = try take("Second", kind: .automatic)
        XCTAssertGreaterThan(second.id, first.id, "ids order by age even when taken within the same millisecond")
        XCTAssertEqual(checkpoints().map(\.id), [second.id, first.id])
        XCTAssertEqual(checkpoints().map(\.name), ["Second", "First"])
        XCTAssertEqual(store.checkpoints.map(\.id), [second.id, first.id], "the main thread's copy is kept up to date")
        XCTAssertEqual(checkpoints().map(\.kind), [.automatic, .manual])
    }

    func testAnEmptyNameBecomesATimeAndOddCharactersAreKept() throws {
        try write("x\n", to: "a.txt")
        XCTAssertTrue(try take("").name.hasPrefix("Before "))
        XCTAssertTrue(try take(nil).name.hasPrefix("Before "))
        XCTAssertEqual(try take("  trimmed  ").name, "trimmed")
        XCTAssertEqual(try take("Straße 名前 🚀").name, "Straße 名前 🚀")
        XCTAssertEqual(checkpoints().first?.name, "Straße 名前 🚀")
    }

    func testTheListChangeIsAnnounced() throws {
        try write("x\n", to: "a.txt")
        var announced = 0
        let observer = NotificationCenter.default.addObserver(forName: CheckpointStore.didChangeCheckpoints, object: store, queue: nil) { _ in announced += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = try take()
        XCTAssertEqual(announced, 1)
    }

    func testAnAutomaticCheckpointIsOnlyTakenOncePerHour() throws {
        try write("x\n", to: "a.txt")
        var first: Checkpoint?? = nil
        store.takeAutomaticCheckpointIfDue { first = .some($0) }
        XCTAssertTrue(TestSupport.wait(upTo: 30) { first != nil })
        XCTAssertEqual(first??.kind, .automatic)
        XCTAssertTrue(first??.name.hasPrefix("Opened at ") == true)
        var second: Checkpoint?? = nil
        store.takeAutomaticCheckpointIfDue { second = .some($0) }
        XCTAssertTrue(TestSupport.wait(upTo: 30) { second != nil })
        XCTAssertNil(second ?? nil, "one from a minute ago is recent enough")
        XCTAssertEqual(checkpoints().count, 1)
    }

    func testWorksInAFolderWithoutGitAndLeavesNoGitFolderBehind() throws {
        try write("x\n", to: "a.txt")
        _ = try take()
        XCTAssertFalse(exists(".git"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("git/HEAD").path))
        XCTAssertEqual(try String(contentsOf: store.directory.appendingPathComponent("project-folder.txt"), encoding: .utf8), root.path + "\n")
    }

    func testTheProjectsOwnRepositoryIsNeverTouched() throws {
        try write("x\n", to: "a.txt")
        TestSupport.git(["init", "-q"], in: root)
        TestSupport.git(["add", "."], in: root)
        TestSupport.git(["commit", "-qm", "init"], in: root)
        let before = TestSupport.git(["rev-parse", "HEAD"], in: root)
        try write("y\n", to: "a.txt")
        let checkpoint = try take()
        XCTAssertEqual(TestSupport.git(["rev-parse", "HEAD"], in: root), before)
        XCTAssertEqual(TestSupport.git(["status", "--porcelain"], in: root), " M a.txt\n", "the project's index did not see a thing")
        XCTAssertFalse(TestSupport.git(["for-each-ref"], in: root).contains("checkpoints"))
        try write("z\n", to: "a.txt")
        XCTAssertEqual(changeOf("a.txt", since: checkpoint)?.kind, .changed)
        // A repository nested inside the project is not snapshotted either (git cannot hold it).
        let nested = root.appendingPathComponent("lib")
        try TestSupport.write(["lib/inner.txt": "i\n"], under: root)
        TestSupport.git(["init", "-q"], in: nested)
        let later = try take()
        XCTAssertNil(changeOf("lib/inner.txt", since: later))
    }

    // MARK: - What changed

    func testChangedCreatedAndDeletedFiles() throws {
        try write("one\ntwo\n", to: "changed.txt")
        try write("gone\n", to: "deleted.txt")
        try write("same\n", to: "same.txt")
        let checkpoint = try take()
        XCTAssertEqual(changes(since: checkpoint)?.changes, [], "nothing changed yet")
        try write("one\nTWO\nthree\n", to: "changed.txt")
        try FileManager.default.removeItem(at: root.appendingPathComponent("deleted.txt"))
        try write("new\nfile\n", to: "sub/created.txt")
        guard let snapshot = changes(since: checkpoint) else { return XCTFail("no snapshot") }
        XCTAssertEqual(snapshot.checkpoint, checkpoint)
        XCTAssertEqual(Set(snapshot.changes.map(\.path)), ["changed.txt", "deleted.txt", "sub/created.txt"])
        let changed = try XCTUnwrap(snapshot.changes.first { $0.path == "changed.txt" })
        XCTAssertEqual(changed.kind, .changed)
        XCTAssertEqual(changed.insertions, 2)
        XCTAssertEqual(changed.deletions, 1)
        XCTAssertNotNil(changed.modified)
        let deleted = try XCTUnwrap(snapshot.changes.first { $0.path == "deleted.txt" })
        XCTAssertEqual(deleted.kind, .deleted)
        XCTAssertEqual(deleted.deletions, 1)
        XCTAssertNil(deleted.modified)
        let created = try XCTUnwrap(snapshot.changes.first { $0.path == "sub/created.txt" })
        XCTAssertEqual(created.kind, .created)
        XCTAssertEqual(created.insertions, 2)
        XCTAssertEqual(created.deletions, 0)
        XCTAssertEqual(snapshot.insertions, 4)
        XCTAssertEqual(snapshot.deletions, 2)
        XCTAssertEqual(snapshot.unlisted, 0)
        XCTAssertGreaterThanOrEqual(snapshot.milliseconds, 0)
    }

    func testChangesAreNewestFirst() throws {
        try write("a\n", to: "a.txt")
        try write("b\n", to: "b.txt")
        let checkpoint = try take()
        try write("a2\n", to: "a.txt")
        let earlier = Date().addingTimeInterval(-100)
        try FileManager.default.setAttributes([.modificationDate: earlier], ofItemAtPath: root.appendingPathComponent("a.txt").path)
        try write("b2\n", to: "b.txt")
        XCTAssertEqual(changes(since: checkpoint)?.changes.map(\.path), ["b.txt", "a.txt"])
    }

    func testAFileThatWentAwayAndCameBackIsAChange() throws {
        try write("v1\n", to: "a.txt")
        let first = try take()
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.txt"))
        let second = try take()
        try write("v2\n", to: "a.txt")
        XCTAssertEqual(changeOf("a.txt", since: second)?.kind, .created)
        XCTAssertEqual(changeOf("a.txt", since: first)?.kind, .changed)
    }

    func testBinaryFilesHaveNoLineCounts() throws {
        var data = Data(repeating: 1, count: 64)
        data[3] = 0
        try data.write(to: root.appendingPathComponent("old.bin"))
        let checkpoint = try take()
        data[10] = 9
        try data.write(to: root.appendingPathComponent("old.bin"))
        try data.write(to: root.appendingPathComponent("new.bin"))
        let old = try XCTUnwrap(changeOf("old.bin", since: checkpoint))
        XCTAssertTrue(old.isBinary)
        XCTAssertNil(old.insertions)
        XCTAssertNil(old.deletions)
        let new = try XCTUnwrap(changeOf("new.bin", since: checkpoint))
        XCTAssertEqual(new.kind, .created)
        XCTAssertTrue(new.isBinary)
        XCTAssertNil(new.insertions)
    }

    func testBuiltInExcludesAndTheProjectsGitignoreAreHonoured() throws {
        try write("x\n", to: "node_modules/dep/index.js")
        try write("x\n", to: "build/out.o")
        try write("x\n", to: "src/cache.pyc")
        try write("secret\n", to: "ignored.log")
        try write("*.log\n", to: ".gitignore")
        try write("keep\n", to: "src/main.py")
        let checkpoint = try take()
        try FileManager.default.removeItem(at: root.appendingPathComponent("src/main.py"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("node_modules/dep/index.js"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("ignored.log"))
        let paths = Set(changes(since: checkpoint)?.changes.map(\.path) ?? [])
        XCTAssertEqual(paths, ["src/main.py"], "only what was in the checkpoint counts")
        try write("y\n", to: "dist/bundle.js")
        try write("y\n", to: "new.log")
        try write("y\n", to: "src/new.py")
        XCTAssertEqual(Set(changes(since: checkpoint)?.changes.map(\.path) ?? []), ["src/main.py", "src/new.py"])
    }

    func testAHugeNewFileIsLeftOut() throws {
        try Data(count: CheckpointStore.maxFileBytes + 1).write(to: root.appendingPathComponent("video.bin"))
        try write("x\n", to: "small.txt")
        let checkpoint = try take()
        XCTAssertNil(changeOf("video.bin", since: checkpoint), "never in the checkpoint, so never a new file either")
        try FileManager.default.removeItem(at: root.appendingPathComponent("video.bin"))
        XCTAssertNil(changeOf("video.bin", since: checkpoint))
        XCTAssertNil(changeOf("small.txt", since: checkpoint))
    }

    func testUnicodeAndSpacedFileNamesComeThroughUnquoted() throws {
        let checkpoint = try take()
        try write("x\n", to: "Ünïcödé 名前/my file.txt")
        XCTAssertEqual(changes(since: checkpoint)?.changes.map(\.path), ["Ünïcödé 名前/my file.txt"])
        let later = try take()
        try write("y\n", to: "Ünïcödé 名前/my file.txt")
        XCTAssertEqual(changeOf("Ünïcödé 名前/my file.txt", since: later)?.kind, .changed)
        let outcome = restore(to: later, only: ["Ünïcödé 名前/my file.txt"])
        XCTAssertEqual(outcome?.restored, ["Ünïcödé 名前/my file.txt"])
        XCTAssertEqual(try text("Ünïcödé 名前/my file.txt"), "x\n")
    }

    // MARK: - Undoing

    func testRestoringOneFileLeavesTheOthersAlone() throws {
        try write("a1\n", to: "a.txt")
        try write("b1\n", to: "b.txt")
        let checkpoint = try take("Before")
        try write("a2\n", to: "a.txt")
        try write("b2\n", to: "b.txt")
        guard let outcome = restore(to: checkpoint, only: ["a.txt"]) else { return XCTFail("no outcome") }
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.restored, ["a.txt"])
        XCTAssertEqual(outcome.touched, ["a.txt"])
        XCTAssertTrue(outcome.trashed.isEmpty)
        XCTAssertEqual(try text("a.txt"), "a1\n")
        XCTAssertEqual(try text("b.txt"), "b2\n")
        // A safety checkpoint of the moment before, named for the file, sits on top of the list.
        let safety = try XCTUnwrap(outcome.safety)
        XCTAssertEqual(safety.kind, .safety)
        XCTAssertTrue(safety.name.hasPrefix("Before restoring “a.txt”"), safety.name)
        XCTAssertEqual(checkpoints().first?.id, safety.id)
        // Undoing the undo brings the edit back.
        _ = restore(to: safety, only: ["a.txt"])
        XCTAssertEqual(try text("a.txt"), "a2\n")
    }

    func testUndoingEverythingRestoresDeletesAndTrashesNewFiles() throws {
        try write("keep me\n", to: "changed.txt")
        try write("gone\n", to: "deleted/inner.txt")
        let checkpoint = try take()
        try write("edited\n", to: "changed.txt")
        try FileManager.default.removeItem(at: root.appendingPathComponent("deleted"))
        try write("new\n", to: "fresh/created.txt")
        var announced = false
        let observer = NotificationCenter.default.addObserver(forName: CheckpointStore.didRestoreFiles, object: store, queue: nil) { _ in announced = true }
        defer { NotificationCenter.default.removeObserver(observer) }
        guard let outcome = restore(to: checkpoint) else { return XCTFail("no outcome") }
        XCTAssertNil(outcome.error)
        XCTAssertTrue(announced)
        XCTAssertEqual(Set(outcome.restored), ["changed.txt", "deleted/inner.txt"])
        XCTAssertEqual(outcome.trashed, ["fresh/created.txt"])
        XCTAssertEqual(outcome.trashedURLs.count, 1)
        XCTAssertTrue(outcome.safety?.name.hasPrefix("Before undoing changes") == true)
        XCTAssertEqual(try text("changed.txt"), "keep me\n")
        XCTAssertEqual(try text("deleted/inner.txt"), "gone\n")
        XCTAssertFalse(exists("fresh/created.txt"))
        XCTAssertFalse(exists("fresh"), "a folder that only held new files goes too")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.trashedURLs[0].path), "the new file is in the Trash, not gone")
        XCTAssertEqual(changes(since: checkpoint)?.changes, [])
    }

    func testFilesToSkipAreLeftAsTheyAre() throws {
        try write("a1\n", to: "a.txt")
        try write("b1\n", to: "b.txt")
        let checkpoint = try take()
        try write("a2\n", to: "a.txt")
        try write("b2\n", to: "b.txt")
        guard let outcome = restore(to: checkpoint, skipping: ["b.txt"]) else { return XCTFail("no outcome") }
        XCTAssertEqual(outcome.restored, ["a.txt"])
        XCTAssertEqual(outcome.skipped, ["b.txt"])
        XCTAssertEqual(try text("b.txt"), "b2\n")
    }

    func testRestoringWhenNothingChangedDoesNothing() throws {
        try write("a\n", to: "a.txt")
        let checkpoint = try take()
        guard let outcome = restore(to: checkpoint) else { return XCTFail("no outcome") }
        XCTAssertNil(outcome.error)
        XCTAssertTrue(outcome.touched.isEmpty)
        XCTAssertNotNil(outcome.safety)
    }

    func testWindowsLineEndingsAndAMissingFinalNewlineComeBackByteForByte() throws {
        let original = Data("one\r\ntwo\r\nthree".utf8)
        try original.write(to: root.appendingPathComponent("crlf.txt"))
        let checkpoint = try take()
        try Data("one\r\nTWO\r\nthree\r\n".utf8).write(to: root.appendingPathComponent("crlf.txt"))
        let change = try XCTUnwrap(changeOf("crlf.txt", since: checkpoint))
        XCTAssertEqual(change.insertions, 2)
        XCTAssertEqual(change.deletions, 2)
        _ = restore(to: checkpoint, only: ["crlf.txt"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("crlf.txt")), original)
    }

    // MARK: - One file's blocks

    private func loadDiff(_ path: String, since checkpoint: Checkpoint) -> Result<FileDiff, FileDiff.Problem>? {
        var result: Result<FileDiff, FileDiff.Problem>?
        store.perform({ self.store.loadDiff(path: path, since: checkpoint) }) { result = $0 }
        XCTAssertTrue(TestSupport.wait(upTo: 30) { result != nil })
        return result
    }

    func testTheDiffOfANewFileIsOneBlockAndOfAChangedFileItsBlocks() throws {
        try write((1...10).map { "line \($0)" }.joined(separator: "\n") + "\n", to: "a.txt")
        let checkpoint = try take()
        try write("new\nfile\n", to: "new.txt")
        guard case .success(let fresh)? = loadDiff("new.txt", since: checkpoint) else { return XCTFail("no diff") }
        XCTAssertEqual(fresh.hunks.count, 1)
        XCTAssertEqual(fresh.hunks[0].newCount, 2)
        XCTAssertFalse(fresh.canPatchBlocks)
        XCTAssertEqual(fresh.insertions, 2)
        var lines = (1...10).map { "line \($0)" }
        lines[1] = "LINE 2"
        lines[8] = "LINE 9"
        try write(lines.joined(separator: "\n") + "\n", to: "a.txt")
        guard case .success(let edited)? = loadDiff("a.txt", since: checkpoint) else { return XCTFail("no diff") }
        XCTAssertEqual(edited.hunks.count, 2)
        XCTAssertTrue(edited.canPatchBlocks)
        XCTAssertEqual(edited.oldLines.count, 10)
        XCTAssertEqual(edited.newLines[1], "LINE 2")
        // A deleted file is one block of old lines.
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.txt"))
        guard case .success(let gone)? = loadDiff("a.txt", since: checkpoint) else { return XCTFail("no diff") }
        XCTAssertEqual(gone.hunks.count, 1)
        XCTAssertEqual(gone.deletions, 10)
        XCTAssertEqual(gone.newLines, [])
    }

    func testABinaryFileCannotBeCompared() throws {
        var data = Data(count: 32)
        try data.write(to: root.appendingPathComponent("blob.bin"))
        let checkpoint = try take()
        data[1] = 5
        try data.write(to: root.appendingPathComponent("blob.bin"))
        guard case .failure(let problem)? = loadDiff("blob.bin", since: checkpoint) else { return XCTFail("expected a problem") }
        XCTAssertEqual(problem, .binary)
    }

    func testUndoingOneBlockOnDiskAndRefusingAStaleOne() throws {
        try write("a\nb\nc\nd\n", to: "f.txt")
        let checkpoint = try take()
        try write("a\nB\nc\nD\n", to: "f.txt")
        guard case .success(let diff)? = loadDiff("f.txt", since: checkpoint) else { return XCTFail("no diff") }
        XCTAssertEqual(diff.hunks.count, 2)
        var result: GitResult?
        store.perform({ self.store.undoBlock(diff.hunks[1].patch, path: "f.txt", since: checkpoint) }) { result = $0 }
        XCTAssertTrue(TestSupport.wait(upTo: 30) { result != nil })
        XCTAssertEqual(result?.ok, true, result?.message ?? "")
        XCTAssertEqual(try text("f.txt"), "a\nB\nc\nd\n")
        // The same block again: it is no longer in the file, so nothing happens.
        result = nil
        store.perform({ self.store.undoBlock(diff.hunks[1].patch, path: "f.txt", since: checkpoint) }) { result = $0 }
        XCTAssertTrue(TestSupport.wait(upTo: 30) { result != nil })
        XCTAssertEqual(result?.ok, false)
        XCTAssertTrue(result?.message.contains("changed since") == true)
        XCTAssertEqual(try text("f.txt"), "a\nB\nc\nd\n")
    }

    func testChangedLinesForTheFlash() throws {
        try write("a\nb\nc\nd\ne\n", to: "f.txt")
        let checkpoint = try take()
        try write("a\nB\nc\nd\nx\ny\ne\n", to: "f.txt")
        var ranges: [Range<Int>]?
        store.changedLines(of: "f.txt", since: checkpoint) { ranges = $0 }
        XCTAssertTrue(TestSupport.wait(upTo: 30) { ranges != nil })
        XCTAssertEqual(ranges, [1..<2, 4..<6])
        try FileManager.default.removeItem(at: root.appendingPathComponent("f.txt"))
        ranges = nil
        store.changedLines(of: "f.txt", since: checkpoint) { ranges = $0 }
        XCTAssertTrue(TestSupport.wait(upTo: 30) { ranges != nil })
        XCTAssertEqual(ranges, [0..<1], "a file with nothing left still flashes its first line")
    }

    // MARK: - Housekeeping

    func testOnlyTheNewestCheckpointsAreKept() throws {
        try write("x\n", to: "a.txt")
        for index in 0...CheckpointStore.keepCount {
            try write("\(index)\n", to: "a.txt")
            _ = try take("Checkpoint \(index)")
        }
        let list = checkpoints()
        XCTAssertEqual(list.count, CheckpointStore.keepCount)
        XCTAssertEqual(list.first?.name, "Checkpoint \(CheckpointStore.keepCount)")
        XCTAssertEqual(list.last?.name, "Checkpoint 1", "the oldest one was dropped")
    }

    func testDiskUseAndClearing() throws {
        try write(String(repeating: "x", count: 10_000) + "\n", to: "a.txt")
        _ = try take()
        var used: Int?
        store.diskUse { used = $0 }
        XCTAssertTrue(TestSupport.wait(upTo: 30) { used != nil })
        XCTAssertGreaterThan(used ?? 0, 0)
        var cleared = false
        store.clear { cleared = true }
        XCTAssertTrue(TestSupport.wait(upTo: 30) { cleared })
        XCTAssertTrue(checkpoints().isEmpty)
        XCTAssertEqual(try text("a.txt").count, 10_001, "the project's files are not touched")
        // The store makes itself again on the next checkpoint.
        _ = try take("After clearing")
        XCTAssertEqual(checkpoints().map(\.name), ["After clearing"])
    }

    func testErrorMessages() {
        XCTAssertTrue(CheckpointStore.CheckpointError.tooBig(50_000).message.contains("50000 files"))
        XCTAssertEqual(CheckpointStore.CheckpointError.failed("  boom \n").message, "boom")
    }
}
