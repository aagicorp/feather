import XCTest
@testable import Feather

/// Git/Git.swift: the `git status` parser (renames, conflicts, untracked files, the branch line), the plumbing
/// calls against throwaway repositories (branch status, HEAD, nested repository discovery, merging), the
/// Restricted Mode refusal, and the gutter line diff. `branchByReadingHEAD` is covered in GitBranchTests.
final class GitStatusParsingTests: XCTestCase {
    func testStagedAndUnstagedChangesToTheSameFileAreTwoEntries() {
        let status = Git.parseStatus("## main\0MM a.txt\0A  b.txt\0 D c.txt\0")
        XCTAssertEqual(status.staged, [GitFileChange(path: "a.txt", status: "M", isStaged: true),
                                       GitFileChange(path: "b.txt", status: "A", isStaged: true)])
        XCTAssertEqual(status.unstaged, [GitFileChange(path: "a.txt", status: "M", isStaged: false),
                                         GitFileChange(path: "c.txt", status: "D", isStaged: false)])
    }

    func testARenameCarriesItsOriginalPath() {
        let status = Git.parseStatus("R  new name.txt\0old.txt\0C  copy.txt\0source.txt\0")
        XCTAssertEqual(status.staged.map(\.path), ["new name.txt", "copy.txt"])
        XCTAssertEqual(status.staged.map(\.originalPath), ["old.txt", "source.txt"])
        XCTAssertTrue(status.unstaged.isEmpty, "the original path must not be read as an entry of its own")
    }

    func testARenameWithLaterEditsIsAlsoUnstaged() {
        let status = Git.parseStatus("RM renamed.txt\0old.txt\0")
        XCTAssertEqual(status.staged.map(\.originalPath), ["old.txt"])
        XCTAssertEqual(status.unstaged, [GitFileChange(path: "renamed.txt", status: "M", isStaged: false)])
    }

    func testConflictsAreOneUnstagedEntryEach() {
        let status = Git.parseStatus("UU both.txt\0AA added.txt\0DD gone.txt\0AU a.txt\0UA b.txt\0DU c.txt\0UD d.txt\0")
        XCTAssertTrue(status.staged.isEmpty)
        XCTAssertEqual(status.unstaged.count, 7)
        XCTAssertTrue(status.unstaged.allSatisfy(\.isConflict))
        XCTAssertEqual(status.conflicts.map(\.path), ["both.txt", "added.txt", "gone.txt", "a.txt", "b.txt", "c.txt", "d.txt"])
    }

    func testUntrackedFilesAndFolders() {
        let status = Git.parseStatus("?? new.txt\0?? folder/\0")
        XCTAssertEqual(status.unstaged.map(\.path), ["new.txt", "folder/"])
        XCTAssertTrue(status.unstaged.allSatisfy(\.isUntracked))
        XCTAssertFalse(status.unstaged[0].isConflict)
    }

    func testPathsWithSpacesAndNonASCII() {
        let status = Git.parseStatus(" M dir with spaces/ünïcödé 名前.txt\0")
        XCTAssertEqual(status.unstaged.map(\.path), ["dir with spaces/ünïcödé 名前.txt"])
    }

    func testEmptyAndMalformedInput() {
        XCTAssertEqual(Git.parseStatus(""), GitStatus())
        XCTAssertEqual(Git.parseStatus("\0\0"), GitStatus())
        let short = Git.parseStatus("M \0 M a\0")
        XCTAssertEqual(short.unstaged.map(\.path), ["a"], "an entry shorter than the two status columns and a space is skipped")
    }

    // MARK: - The branch line

    func testBranchWithUpstreamAndCounts() {
        let status = Git.parseStatus("## feature/x...origin/feature/x [ahead 3, behind 2]\0")
        XCTAssertEqual(status.branch, "feature/x")
        XCTAssertEqual(status.upstream, "origin/feature/x")
        XCTAssertEqual(status.ahead, 3)
        XCTAssertEqual(status.behind, 2)
    }

    func testBranchWithOnlyOneCount() {
        let ahead = Git.parseStatus("## main...origin/main [ahead 1]\0")
        XCTAssertEqual(ahead.ahead, 1)
        XCTAssertEqual(ahead.behind, 0)
        let behind = Git.parseStatus("## main...origin/main [behind 4]\0")
        XCTAssertEqual(behind.ahead, 0)
        XCTAssertEqual(behind.behind, 4)
    }

    func testBranchWhoseUpstreamIsGone() {
        let status = Git.parseStatus("## main...origin/main [gone]\0")
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.ahead, 0)
        XCTAssertEqual(status.behind, 0)
    }

    func testBranchWithoutUpstream() {
        let status = Git.parseStatus("## main\0")
        XCTAssertEqual(status.branch, "main")
        XCTAssertNil(status.upstream)
    }

    func testNoCommitsYet() {
        let status = Git.parseStatus("## No commits yet on main\0")
        XCTAssertEqual(status.branch, "main")
        XCTAssertNil(status.upstream)
    }

    func testDetachedHead() {
        let status = Git.parseStatus("## HEAD (no branch)\0 M a.txt\0")
        XCTAssertNil(status.branch)
        XCTAssertEqual(status.unstaged.map(\.path), ["a.txt"])
    }

    func testGitResultMessagePrefersStandardError() {
        XCTAssertEqual(GitResult(status: 1, output: "out\n", error: " fatal: bad\n").message, "fatal: bad")
        XCTAssertEqual(GitResult(status: 1, output: " out \n", error: "\n").message, "out")
        XCTAssertTrue(GitResult(status: 0, output: "", error: "").ok)
    }
}

final class GitRepositoryTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private func repository(_ files: [String: String] = ["README.md": "# Test\n"]) throws -> URL {
        let root = try TestSupport.makeRepository(files)
        roots.append(root)
        return root
    }

    /// Runs one of the completion-based calls and returns what it delivered on the main thread.
    private func collect<T>(_ label: String = "git", _ start: (@escaping (T) -> Void) -> Void) -> T? {
        var result: T?
        var done = false
        start { result = $0; done = true }
        XCTAssertTrue(TestSupport.wait(upTo: 15) { done }, "\(label) did not complete")
        return result
    }

    func testStatusOfAFreshRepositoryIsClean() throws {
        let root = try repository()
        let status = collect("status") { Git.status(in: root, completion: $0) } ?? nil
        XCTAssertEqual(status?.branch, "main")
        XCTAssertEqual(status?.staged, [])
        XCTAssertEqual(status?.unstaged, [])
        XCTAssertEqual(status?.isMerging, false)
    }

    func testStatusListsEveryKindOfChange() throws {
        let root = try repository(["a.txt": "a\n", "b.txt": "b\n", "old.txt": "old\n"])
        try "changed\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.txt"))
        try "new\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try TestSupport.write(["dir/inner.txt": "x\n"], under: root)
        TestSupport.git(["mv", "old.txt", "moved.txt"], in: root)
        guard let status = collect("status", { Git.status(in: root, completion: $0) }) ?? nil else { return XCTFail("no status") }
        XCTAssertEqual(status.staged, [GitFileChange(path: "moved.txt", status: "R", isStaged: true, originalPath: "old.txt")])
        XCTAssertEqual(status.unstaged.map(\.path).sorted(), ["a.txt", "b.txt", "dir/inner.txt", "new.txt"])
        XCTAssertEqual(status.unstaged.first { $0.path == "b.txt" }?.status, "D")
        XCTAssertTrue(status.unstaged.first { $0.path == "new.txt" }?.isUntracked == true)
    }

    func testFoldersOfNewFilesCollapseUnlessAskedFor() throws {
        let root = try repository()
        try TestSupport.write(["dir/one.txt": "1\n", "dir/two.txt": "2\n"], under: root)
        let collapsed = collect("status") { Git.status(in: root, allUntracked: false, completion: $0) } ?? nil
        XCTAssertEqual(collapsed?.unstaged.map(\.path), ["dir/"])
        let full = collect("status") { Git.status(in: root, allUntracked: true, completion: $0) } ?? nil
        XCTAssertEqual(full?.unstaged.map(\.path), ["dir/one.txt", "dir/two.txt"])
    }

    func testMergeConflictIsReportedAsMerging() throws {
        let root = try repository(["shared.txt": "base\n"])
        TestSupport.git(["checkout", "-qb", "other"], in: root)
        try "theirs\n".write(to: root.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        TestSupport.git(["commit", "-qam", "theirs"], in: root)
        TestSupport.git(["checkout", "-q", "main"], in: root)
        try "ours\n".write(to: root.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        TestSupport.git(["commit", "-qam", "ours"], in: root)
        _ = Git.runSync(["merge", "other"], in: root)       // fails with a conflict, which is the point
        guard let status = collect("status", { Git.status(in: root, completion: $0) }) ?? nil else { return XCTFail("no status") }
        XCTAssertTrue(status.isMerging)
        XCTAssertEqual(status.conflicts.map(\.path), ["shared.txt"])
    }

    func testBranchStatusCountsAheadAndBehind() throws {
        let upstream = try repository(["a.txt": "1\n"])
        let clone = TestSupport.temporaryDirectory("feather-clone")
        roots.append(clone)
        TestSupport.git(["clone", "-q", upstream.path, clone.path], in: upstream)
        // One commit of our own; the upstream moves on by two.
        try "2\n".write(to: clone.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        TestSupport.git(["commit", "-qam", "local"], in: clone)
        for step in ["3", "4"] {
            try "\(step)\n".write(to: upstream.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            TestSupport.git(["commit", "-qam", "upstream \(step)"], in: upstream)
        }
        TestSupport.git(["fetch", "-q"], in: clone)
        let status = collect("branch status") { Git.branchStatus(in: clone, completion: $0) } ?? nil
        XCTAssertEqual(status, Git.BranchStatus(name: "main", ahead: 1, behind: 2))
        let detached = try repository()
        TestSupport.git(["checkout", "-q", "--detach"], in: detached)
        XCTAssertEqual(collect("branch status") { Git.branchStatus(in: detached, completion: $0) } ?? nil,
                       Git.BranchStatus(name: nil, ahead: 0, behind: 0))
    }

    func testBranchStatusOutsideARepositoryIsNil() {
        let plain = TestSupport.temporaryDirectory("feather-plain")
        roots.append(plain)
        let status = collect("branch status") { Git.branchStatus(in: plain, completion: $0) } ?? nil
        XCTAssertNil(status)
    }

    func testHeadCommitAndBranchAndRoot() throws {
        let root = try repository()
        let hash = TestSupport.git(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(collect("head") { Git.headCommit(in: root, completion: $0) } ?? nil, hash)
        XCTAssertEqual(collect("branch") { Git.branch(in: root, completion: $0) } ?? nil, "main")
        let nested = root.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let top = collect("root") { Git.repositoryRoot(for: nested, completion: $0) } ?? nil
        XCTAssertEqual(top?.standardizedFileURL.path, root.path)
        let plain = TestSupport.temporaryDirectory("feather-plain")
        roots.append(plain)
        XCTAssertNil(collect("head") { Git.headCommit(in: plain, completion: $0) } ?? nil)
        XCTAssertNil(collect("branch") { Git.branch(in: plain, completion: $0) } ?? nil)
    }

    func testHeadContentIsTheCommittedVersion() throws {
        let root = try repository(["notes.txt": "one\ntwo\n"])
        try "one\ntwo\nthree\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let file = root.appendingPathComponent("notes.txt")
        XCTAssertEqual(collect("content") { Git.headContent(of: file, completion: $0) } ?? nil, "one\ntwo\n")
        XCTAssertEqual(collect("lines") { Git.headLines(of: file, completion: $0) } ?? nil, ["one", "two", ""])
        let untracked = root.appendingPathComponent("new.txt")
        try "x\n".write(to: untracked, atomically: true, encoding: .utf8)
        XCTAssertNil(collect("content") { Git.headContent(of: untracked, completion: $0) } ?? nil)
    }

    func testOtherBranchesLeaveOutTheCurrentOne() throws {
        let root = try repository()
        TestSupport.git(["branch", "feature/a"], in: root)
        TestSupport.git(["branch", "zed"], in: root)
        let names = collect("branches") { Git.otherBranches(in: root, completion: $0) } ?? []
        XCTAssertEqual(names, ["feature/a", "zed"])
    }

    func testRunAllStopsAtTheFirstFailure() throws {
        let root = try repository()
        let result = collect("run all") {
            Git.runAll([["branch", "one"], ["branch", "bad name"], ["branch", "three"]], in: root, completion: $0)
        }
        XCTAssertEqual(result?.ok, false)
        let branches = TestSupport.git(["branch", "--list"], in: root)
        XCTAssertTrue(branches.contains("one"))
        XCTAssertFalse(branches.contains("three"), "nothing after the failing command runs")
    }

    // MARK: - Discovering repositories

    func testDiscoverFindsTheFolderItselfAndNestedRepositories() throws {
        let workspace = TestSupport.temporaryDirectory("feather-workspace")
        roots.append(workspace)
        for name in ["b-service", "a-service", "deeper/inner", "node_modules/dep", "too/deep/for/the/walk"] {
            try FileManager.default.createDirectory(at: workspace.appendingPathComponent(name), withIntermediateDirectories: true)
            TestSupport.git(["init", "-q"], in: workspace.appendingPathComponent(name))
        }
        try TestSupport.write(["plain/readme.txt": "no repository here\n"], under: workspace)
        let found = collect("discover") { Git.discoverRepositories(under: workspace, completion: $0) } ?? []
        XCTAssertEqual(found.map { $0.path.dropFirst(workspace.path.count + 1) }.map(String.init),
                       ["a-service", "b-service", "deeper/inner"],
                       "sorted by name, dependency folders skipped, nothing deeper than three levels")
        // A subfolder of a repository reports the repository it belongs to.
        let repo = try repository()
        let inside = repo.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let owning = collect("discover") { Git.discoverRepositories(under: inside, completion: $0) } ?? []
        XCTAssertEqual(owning.map { $0.standardizedFileURL.path }, [repo.path])
    }

    func testDiscoverDoesNotDescendIntoARepositoryItFound() throws {
        let outer = try repository()
        let inner = outer.appendingPathComponent("vendored/lib")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        TestSupport.git(["init", "-q"], in: inner)
        let found = collect("discover") { Git.discoverRepositories(under: outer, completion: $0) } ?? []
        XCTAssertEqual(found.map(\.standardizedFileURL.path), [outer.path, inner.standardizedFileURL.path])
        XCTAssertEqual(collect("discover") { Git.discoverRepositories(under: outer, maxDepth: 1, completion: $0) }?.count, 1)
    }

    // MARK: - Restricted Mode

    func testGitRefusesToRunInARestrictedFolder() throws {
        let root = try repository()
        let trust = WorkspaceTrust.shared
        guard trust.isEnabled, !trust.isTrusted(root) else { throw XCTSkip("the test folder is trusted in this defaults domain") }
        trust.noteOpen(root, restricted: true)
        defer { trust.noteClosed(root) }
        let refused = Git.runSync(["status"], in: root)
        XCTAssertFalse(refused.ok)
        XCTAssertTrue(refused.message.contains("Restricted Mode"))
        XCTAssertFalse(Git.runSync(["status"], in: root.appendingPathComponent("sub")).ok, "folders below the restricted one are refused too")
        XCTAssertNil(collect("status") { Git.status(in: root, completion: $0) } ?? nil)
        trust.noteClosed(root)
        XCTAssertTrue(Git.runSync(["status"], in: root).ok, "closing the window lifts the refusal")
    }
}

final class LineDiffTests: XCTestCase {
    func testNoChanges() {
        XCTAssertEqual(LineDiff.markers(old: ["a", "b"], new: ["a", "b"]), [:])
        XCTAssertEqual(LineDiff.markers(old: [], new: []), [:])
    }

    func testAddedModifiedAndDeleted() {
        XCTAssertEqual(LineDiff.markers(old: ["a", "b"], new: ["a", "x", "b"]), [1: .added])
        XCTAssertEqual(LineDiff.markers(old: ["a", "b", "c"], new: ["a", "B", "c"]), [1: .modified])
        XCTAssertEqual(LineDiff.markers(old: ["a", "b", "c"], new: ["a", "c"]), [1: .deletedAbove])
    }

    func testDeletionAtTheEndMarksTheLastLine() {
        XCTAssertEqual(LineDiff.markers(old: ["a", "b", "c"], new: ["a", "b"]), [1: .deletedAbove])
        XCTAssertEqual(LineDiff.markers(old: ["a"], new: []), [0: .deletedAbove])
    }

    func testAWholeNewFile() {
        XCTAssertEqual(LineDiff.markers(old: [], new: ["a", "b"]), [0: .added, 1: .added])
    }

    func testAnUnevenReplacementPairsUpWhatItCan() {
        // Two lines became three: two read as modified, the third as added.
        XCTAssertEqual(LineDiff.markers(old: ["a", "b", "z"], new: ["x", "y", "w", "z"]), [0: .modified, 1: .modified, 2: .added])
    }

    func testHugeFilesAreLeftAlone() {
        let big = Array(repeating: "line", count: LineDiff.maxLines + 1)
        XCTAssertEqual(LineDiff.markers(old: big, new: ["other"]), [:])
    }
}
