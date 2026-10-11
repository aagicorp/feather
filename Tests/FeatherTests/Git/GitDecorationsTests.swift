import XCTest
@testable import Feather

/// Git/GitDecorations.swift: the explorer's git marks. A status letter per changed file, the calmer colour
/// rule for the folders above it (red only for a conflict, green only when everything inside is new), several
/// repositories under one folder, and the ordering of kinds. Runs real `git status` on throwaway repositories.
final class GitDecorationsTests: XCTestCase {
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

    /// Opens `root` in a fresh decorations object and waits for the first set of marks.
    private func decorations(for root: URL, expecting: Int = 1) -> GitDecorations {
        let decorations = GitDecorations()
        var changes = 0
        decorations.onChange = { changes += 1 }
        decorations.setRoot(root)
        XCTAssertTrue(TestSupport.wait(upTo: 15) { changes >= expecting }, "no marks arrived")
        return decorations
    }

    func testKindsOrderFromQuietToLoud() {
        XCTAssertLessThan(GitDecorations.Kind.untracked, .added)
        XCTAssertLessThan(GitDecorations.Kind.modified, .deleted)
        XCTAssertLessThan(GitDecorations.Kind.deleted, .conflict)
        XCTAssertEqual(GitDecorations.Kind.allLetters, ["U", "A", "R", "M", "D", "!"])
        XCTAssertEqual(GitDecorations.Kind.conflict.tip, "Conflict")
        XCTAssertNotEqual(GitDecorations.Kind.modified.color(isDark: true), GitDecorations.Kind.modified.color(isDark: false))
    }

    func testEachStatusGetsItsLetter() throws {
        let root = try repository(["a.txt": "a\n", "b.txt": "b\n", "old.txt": "old\n"])
        try "changed\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.txt"))
        try "new\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try "added\n".write(to: root.appendingPathComponent("added.txt"), atomically: true, encoding: .utf8)
        TestSupport.git(["add", "added.txt"], in: root)
        TestSupport.git(["mv", "old.txt", "moved.txt"], in: root)
        let marks = decorations(for: root)
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("a.txt").path), .modified)
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("b.txt").path), .deleted)
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("new.txt").path), .untracked)
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("added.txt").path), .added)
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("moved.txt").path), .renamed)
        XCTAssertNil(marks.kind(forFile: root.appendingPathComponent("README.md").path))
        XCTAssertNil(marks.kind(forFile: root.appendingPathComponent("old.txt").path))
    }

    func testAFileBothStagedAndChangedShowsTheLouderKind() throws {
        let root = try repository(["a.txt": "a\n"])
        try "staged\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        TestSupport.git(["add", "a.txt"], in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.txt"))
        let marks = decorations(for: root)
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("a.txt").path), .deleted)
    }

    func testFoldersAboveAChangeAreMarkedUpToTheRoot() throws {
        let root = try repository(["src/deep/file.txt": "x\n", "other/untouched.txt": "y\n"])
        try "changed\n".write(to: root.appendingPathComponent("src/deep/file.txt"), atomically: true, encoding: .utf8)
        let marks = decorations(for: root)
        XCTAssertEqual(marks.kind(forFolder: root.appendingPathComponent("src/deep").path), .modified)
        XCTAssertEqual(marks.kind(forFolder: root.appendingPathComponent("src").path), .modified)
        XCTAssertEqual(marks.kind(forFolder: root.path), .modified)
        XCTAssertNil(marks.kind(forFolder: root.appendingPathComponent("other").path))
        XCTAssertNil(marks.kind(forFolder: root.deletingLastPathComponent().path), "nothing above the opened folder")
    }

    func testADeletionInsideDoesNotPaintTheFolderRed() throws {
        let root = try repository(["src/gone.txt": "x\n"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("src/gone.txt"))
        let marks = decorations(for: root)
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("src/gone.txt").path), .deleted)
        XCTAssertEqual(marks.kind(forFolder: root.appendingPathComponent("src").path), .modified)
    }

    func testAFolderOfOnlyNewFilesIsGreenUntilSomethingElseChanges() throws {
        let root = try repository(["src/kept.txt": "x\n"])
        try TestSupport.write(["src/new/one.txt": "1\n", "src/new/two.txt": "2\n"], under: root)
        let untouched = decorations(for: root)
        XCTAssertEqual(untouched.kind(forFolder: root.appendingPathComponent("src/new").path), .untracked)
        XCTAssertEqual(untouched.kind(forFolder: root.appendingPathComponent("src").path), .untracked)
        XCTAssertEqual(untouched.kind(forFile: root.appendingPathComponent("src/new/one.txt").path), .untracked)
        // An edit next to the new folder: "src" is now modified, the new folder stays green.
        try "edited\n".write(to: root.appendingPathComponent("src/kept.txt"), atomically: true, encoding: .utf8)
        let mixed = decorations(for: root)
        XCTAssertEqual(mixed.kind(forFolder: root.appendingPathComponent("src/new").path), .untracked)
        XCTAssertEqual(mixed.kind(forFolder: root.appendingPathComponent("src").path), .modified)
    }

    func testAConflictPaintsEveryFolderAboveIt() throws {
        let root = try repository(["dir/shared.txt": "base\n"])
        TestSupport.git(["checkout", "-qb", "other"], in: root)
        try "theirs\n".write(to: root.appendingPathComponent("dir/shared.txt"), atomically: true, encoding: .utf8)
        TestSupport.git(["commit", "-qam", "theirs"], in: root)
        TestSupport.git(["checkout", "-q", "main"], in: root)
        try "ours\n".write(to: root.appendingPathComponent("dir/shared.txt"), atomically: true, encoding: .utf8)
        TestSupport.git(["commit", "-qam", "ours"], in: root)
        _ = Git.runSync(["merge", "other"], in: root)
        let marks = decorations(for: root)
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("dir/shared.txt").path), .conflict)
        XCTAssertEqual(marks.kind(forFolder: root.appendingPathComponent("dir").path), .conflict)
        XCTAssertEqual(marks.kind(forFolder: root.path), .conflict)
    }

    func testSeveralRepositoriesUnderOneFolder() throws {
        let workspace = TestSupport.temporaryDirectory("feather-workspace")
        roots.append(workspace)
        for name in ["api", "web"] {
            let repo = workspace.appendingPathComponent(name)
            try TestSupport.write(["main.txt": "x\n"], under: repo)
            TestSupport.git(["init", "-q"], in: repo)
            TestSupport.git(["add", "."], in: repo)
            TestSupport.git(["commit", "-qm", "init"], in: repo)
        }
        try "changed\n".write(to: workspace.appendingPathComponent("api/main.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: workspace.appendingPathComponent("web/extra.txt"), atomically: true, encoding: .utf8)
        let marks = decorations(for: workspace)
        XCTAssertEqual(marks.kind(forFile: workspace.appendingPathComponent("api/main.txt").path), .modified)
        XCTAssertEqual(marks.kind(forFile: workspace.appendingPathComponent("web/extra.txt").path), .untracked)
        XCTAssertEqual(marks.kind(forFolder: workspace.appendingPathComponent("api").path), .modified)
        XCTAssertEqual(marks.kind(forFolder: workspace.appendingPathComponent("web").path), .untracked)
        XCTAssertEqual(marks.kind(forFolder: workspace.path), .modified, "the workspace folder shows the louder of the two")
    }

    func testFilesInsideANewFolderAreListedOneByOne() throws {
        let root = try repository()
        try TestSupport.write(["fresh/a.txt": "a\n"], under: root)
        let marks = decorations(for: root)
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("fresh/a.txt").path), .untracked)
        XCTAssertEqual(marks.kind(forFolder: root.appendingPathComponent("fresh").path), .untracked)
        XCTAssertNil(marks.files.keys.first { $0.hasSuffix("/") })
    }

    func testAFolderWithoutARepositoryHasNoMarks() throws {
        let plain = TestSupport.temporaryDirectory("feather-plain")
        roots.append(plain)
        try TestSupport.write(["a.txt": "a\n"], under: plain)
        let decorations = GitDecorations()
        var changes = 0
        decorations.onChange = { changes += 1 }
        decorations.setRoot(plain)
        // Nothing to find: the marks stay empty and there is nothing to announce.
        XCTAssertFalse(TestSupport.wait(upTo: 0.5) { changes > 0 })
        XCTAssertTrue(decorations.files.isEmpty)
        XCTAssertTrue(decorations.folders.isEmpty)
    }

    func testClosingTheFolderClearsTheMarks() throws {
        let root = try repository(["a.txt": "a\n"])
        try "changed\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let marks = decorations(for: root)
        XCTAssertFalse(marks.files.isEmpty)
        var cleared = false
        marks.onChange = { cleared = true }
        marks.setRoot(nil)
        XCTAssertTrue(cleared)
        XCTAssertTrue(marks.files.isEmpty)
        XCTAssertTrue(marks.folders.isEmpty)
    }

    func testARefreshPicksUpNewChanges() throws {
        let root = try repository(["a.txt": "a\n"])
        let decorations = GitDecorations()
        var changes = 0
        decorations.onChange = { changes += 1 }
        decorations.setRoot(root)
        // A clean repository: discovery runs, but there is no change to report.
        XCTAssertFalse(TestSupport.wait(upTo: 0.5) { changes > 0 })
        try "changed\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        decorations.scheduleRefresh()
        XCTAssertTrue(TestSupport.wait(upTo: 15) { changes >= 1 })
        XCTAssertEqual(decorations.kind(forFile: root.appendingPathComponent("a.txt").path), .modified)
    }

    func testANewRepositoryIsFoundWhenAskedToLookAgain() throws {
        let workspace = TestSupport.temporaryDirectory("feather-workspace")
        roots.append(workspace)
        try TestSupport.write(["later/a.txt": "a\n"], under: workspace)
        let decorations = GitDecorations()
        var changes = 0
        decorations.onChange = { changes += 1 }
        decorations.setRoot(workspace)
        XCTAssertFalse(TestSupport.wait(upTo: 0.5) { changes > 0 })
        TestSupport.git(["init", "-q"], in: workspace.appendingPathComponent("later"))
        decorations.repositoriesMayHaveChanged()
        XCTAssertTrue(TestSupport.wait(upTo: 15) { changes >= 1 })
        XCTAssertEqual(decorations.kind(forFile: workspace.appendingPathComponent("later/a.txt").path), .untracked)
    }

    // MARK: - Every row of git's status table, on real repositories

    func testAddedThenDeletedIsGoneAndAddedThenEditedIsModified() throws {
        let root = try repository()
        try "x\n".write(to: root.appendingPathComponent("gone.txt"), atomically: true, encoding: .utf8)
        try "y\n".write(to: root.appendingPathComponent("edited.txt"), atomically: true, encoding: .utf8)
        TestSupport.git(["add", "gone.txt", "edited.txt"], in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone.txt"))                 // AD
        try "y\nmore\n".write(to: root.appendingPathComponent("edited.txt"), atomically: true, encoding: .utf8)   // AM
        let marks = decorations(for: root)
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("gone.txt").path), .deleted)
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("edited.txt").path), .modified)
        XCTAssertEqual(marks.kind(forFolder: root.path), .modified, "a deletion inside never paints the folder red")
        XCTAssertEqual(marks.files.count, 2)
    }

    func testStagedEditThenDeletedAndRenamedThenEdited() throws {
        let root = try repository(["a.txt": "a\n", "b.txt": "b\n"])
        try "a2\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        TestSupport.git(["add", "a.txt"], in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.txt"))                    // MD
        TestSupport.git(["mv", "b.txt", "c.txt"], in: root)
        try "b\nmore\n".write(to: root.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)      // RM
        let marks = decorations(for: root)
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("a.txt").path), .deleted)
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("c.txt").path), .modified)
        XCTAssertNil(marks.kind(forFile: root.appendingPathComponent("b.txt").path), "the old name of a rename is not a file any more")
    }

    func testAFileTurnedIntoASymlinkIsModified() throws {
        let root = try repository(["real.txt": "r\n", "link.txt": "l\n"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("link.txt"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link.txt").path, withDestinationPath: "real.txt")
        let marks = decorations(for: root)
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("link.txt").path), .modified)
        XCTAssertNil(marks.kind(forFile: root.appendingPathComponent("real.txt").path))
    }

    func testARenameAcrossFoldersMovesTheMarkToTheNewFolder() throws {
        let root = try repository(["src/a.txt": "a\n", "src/keep.txt": "k\n", "lib/.keep": ""])
        TestSupport.git(["mv", "src/a.txt", "lib/a.txt"], in: root)
        let marks = decorations(for: root)
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("lib/a.txt").path), .renamed)
        XCTAssertEqual(marks.kind(forFolder: root.appendingPathComponent("lib").path), .modified)
        XCTAssertNil(marks.kind(forFolder: root.appendingPathComponent("src").path), "nothing in src changed")
    }

    func testAWholeFolderDeletedMarksItsFilesAndTheFolder() throws {
        let root = try repository(["src/a.txt": "a\n", "src/b.txt": "b\n", "other.txt": "o\n"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("src"))
        let marks = decorations(for: root)
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("src/a.txt").path), .deleted)
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("src/b.txt").path), .deleted)
        XCTAssertEqual(marks.kind(forFolder: root.appendingPathComponent("src").path), .modified)
        XCTAssertEqual(marks.files.count, 2)
    }

    func testIgnoredFilesHaveNoMarkAndAFolderOfThemNoDot() throws {
        let root = try repository([".gitignore": "build/\n*.log\n", "src/a.txt": "a\n"])
        try TestSupport.write(["build/out.txt": "", "build/deep/x.txt": "", "app.log": "", "src/debug.log": ""], under: root)
        try "new\n".write(to: root.appendingPathComponent("src/new.txt"), atomically: true, encoding: .utf8)
        let marks = decorations(for: root)
        XCTAssertNil(marks.kind(forFile: root.appendingPathComponent("build/out.txt").path))
        XCTAssertNil(marks.kind(forFile: root.appendingPathComponent("app.log").path))
        XCTAssertNil(marks.kind(forFolder: root.appendingPathComponent("build").path))
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("src/new.txt").path), .untracked)
        XCTAssertEqual(marks.files.count, 1)
    }

    func testARepositoryWithNoCommitsYetShowsEverythingAsNew() throws {
        let root = TestSupport.temporaryDirectory("feather-fresh")
        roots.append(root)
        try TestSupport.write(["a.txt": "a\n", "src/b.txt": "b\n"], under: root)
        TestSupport.git(["init", "-q"], in: root)
        TestSupport.git(["add", "a.txt"], in: root)
        let marks = decorations(for: root)
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("a.txt").path), .added)
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("src/b.txt").path), .untracked)
        XCTAssertEqual(marks.kind(forFolder: root.appendingPathComponent("src").path), .untracked)
        XCTAssertEqual(marks.kind(forFolder: root.path), .modified, "added outranks untracked, and a folder with anything but new files is the modified colour")
    }

    func testNamesWithSpacesQuotesArrowsAndUnicode() throws {
        let names = ["with space.txt", "\"quoted\" name.txt", "old -> new.txt", "Ünïcode dir/ß.txt", "émoji 🚀.md"]
        let root = try repository(Dictionary(uniqueKeysWithValues: names.map { ($0, "x\n") }))
        for name in names { try "changed\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let marks = decorations(for: root)
        for name in names {
            XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent(name).path), .modified, name)
        }
        XCTAssertEqual(marks.kind(forFolder: root.appendingPathComponent("Ünïcode dir").path), .modified)
        XCTAssertEqual(marks.files.count, names.count)
    }

    func testAStagedAndChangedFileCountsOnce() throws {
        let root = try repository(["a.txt": "a\n"])
        try "staged\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        TestSupport.git(["add", "a.txt"], in: root)
        try "changed again\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let marks = decorations(for: root)
        XCTAssertEqual(marks.files.count, 1, "the count on the Source Control icon is files, not status rows")
    }

    func testADirtySubmoduleMarksItsFolderAndItsOwnFiles() throws {
        let inner = try repository(["main.txt": "m\n"])
        let outer = try repository(["README.md": "# outer\n"])
        // file:// transport for submodules is off by default since git 2.38.3.
        TestSupport.git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", inner.path, "sub"], in: outer)
        TestSupport.git(["commit", "-qm", "add submodule"], in: outer)
        try "m2\n".write(to: outer.appendingPathComponent("sub/main.txt"), atomically: true, encoding: .utf8)
        let marks = decorations(for: outer)
        XCTAssertEqual(marks.kind(forFile: outer.appendingPathComponent("sub/main.txt").path), .modified, "the submodule is a repository of its own")
        XCTAssertEqual(marks.kind(forFolder: outer.appendingPathComponent("sub").path) ?? marks.kind(forFile: outer.appendingPathComponent("sub").path), .modified,
                       "the outer repository lists the submodule as modified; the explorer shows that on its folder")
        XCTAssertEqual(marks.kind(forFolder: outer.path), .modified)
    }

    func testAWorktreeWithAGitFileIsARepository() throws {
        let main = try repository(["a.txt": "a\n"])
        let worktree = TestSupport.temporaryDirectory("feather-worktree")
        roots.append(worktree)
        try FileManager.default.removeItem(at: worktree)
        TestSupport.git(["worktree", "add", "-q", worktree.path, "-b", "wt"], in: main)
        try "changed\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let marks = decorations(for: worktree)
        XCTAssertEqual(marks.kind(forFile: worktree.appendingPathComponent("a.txt").path), .modified)
        XCTAssertEqual(marks.kind(forFolder: worktree.path), .modified)
    }

    func testARepositoryInsideADependencyFolderIsLeftAlone() throws {
        let root = try repository([".gitignore": "node_modules/\n", "a.txt": "a\n"])
        let package = root.appendingPathComponent("node_modules/pkg")
        try TestSupport.write(["index.js": "x\n"], under: package)
        TestSupport.git(["init", "-q"], in: package)
        TestSupport.git(["add", "."], in: package)
        TestSupport.git(["commit", "-qm", "init"], in: package)
        try "y\n".write(to: package.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        try "changed\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)   // so a set of marks arrives
        let marks = decorations(for: root)
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("a.txt").path), .modified)
        XCTAssertNil(marks.kind(forFile: package.appendingPathComponent("index.js").path), "dependency folders are not searched for repositories")
        XCTAssertNil(marks.kind(forFolder: root.appendingPathComponent("node_modules").path))
        XCTAssertEqual(marks.files.count, 1)
    }

    func testANestedRepositoryDeeperThanTheSearchIsNotFound() throws {
        let workspace = TestSupport.temporaryDirectory("feather-deep-repos")
        roots.append(workspace)
        let shallow = workspace.appendingPathComponent("a/b/repo")              // depth 3: found
        let deep = workspace.appendingPathComponent("a/b/c/d/repo")             // depth 5: past the limit
        for repo in [shallow, deep] {
            try TestSupport.write(["main.txt": "x\n"], under: repo)
            TestSupport.git(["init", "-q"], in: repo)
            TestSupport.git(["add", "."], in: repo)
            TestSupport.git(["commit", "-qm", "init"], in: repo)
            try "changed\n".write(to: repo.appendingPathComponent("main.txt"), atomically: true, encoding: .utf8)
        }
        let marks = decorations(for: workspace)
        XCTAssertEqual(marks.kind(forFile: shallow.appendingPathComponent("main.txt").path), .modified)
        XCTAssertNil(marks.kind(forFile: deep.appendingPathComponent("main.txt").path), "repositories are looked for three folders down")
    }

    func testAMergeWithBothAddedAndBothDeletedConflicts() throws {
        let root = try repository(["shared.txt": "s\n", "gone.txt": "g\n"])
        TestSupport.git(["checkout", "-qb", "other"], in: root)
        try "theirs\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try "theirs\n".write(to: root.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        TestSupport.git(["add", "."], in: root)
        TestSupport.git(["commit", "-qm", "theirs"], in: root)
        TestSupport.git(["checkout", "-q", "main"], in: root)
        try "ours\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try "ours\n".write(to: root.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        TestSupport.git(["add", "."], in: root)
        TestSupport.git(["commit", "-qm", "ours"], in: root)
        _ = TestSupport.gitAllowingFailure(["merge", "other"], in: root)
        let marks = decorations(for: root)
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("new.txt").path), .conflict, "both added")
        XCTAssertEqual(marks.kind(forFile: root.appendingPathComponent("shared.txt").path), .conflict, "both modified")
        XCTAssertEqual(marks.kind(forFolder: root.path), .conflict)
    }

}

private extension GitDecorations.Kind {
    static var allLetters: [String] {
        let kinds: [GitDecorations.Kind] = [.untracked, .added, .renamed, .modified, .deleted, .conflict]
        return kinds.map(\.letter)
    }
}
