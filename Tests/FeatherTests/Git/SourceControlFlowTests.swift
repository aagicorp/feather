/// Git/SourceControl.swift without a window: the one button's state for every repository state (VS Code's
/// Commit / Publish Branch / Sync Changes and the merge and rebase states), what a failed pull means, where
/// Publish pushes, the GitHub CLI call; then real repositories: a pull that conflicts, resolved through
/// MergeConflict and marked resolved, as a merge and as a rebase.
import XCTest
@testable import Feather

final class SourceControlFlowTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private func status(_ parts: (inout GitStatus) -> Void) -> GitStatus {
        var status = GitStatus()
        status.branch = "main"
        parts(&status)
        return status
    }

    func testTheOneButtonFollowsVSCode() {
        typealias Pane = SourceControlViewController
        let change = GitFileChange(path: "a", status: "M", isStaged: false)
        XCTAssertEqual(Pane.primaryAction(for: status { $0.upstream = "origin/main" }), .nothing)
        XCTAssertEqual(Pane.primaryAction(for: status { $0.upstream = "origin/main"; $0.unstaged = [change] }), .commit("Commit All"))
        XCTAssertEqual(Pane.primaryAction(for: status { $0.upstream = "origin/main"; $0.staged = [change] }), .commit("Commit"))
        XCTAssertEqual(Pane.primaryAction(for: status { _ in }), .publish, "no upstream and nothing to commit")
        XCTAssertEqual(Pane.primaryAction(for: status { $0.unstaged = [change] }), .commit("Commit All"), "changes come before publishing")
        XCTAssertEqual(Pane.primaryAction(for: status { $0.isUnborn = true }), .nothing, "nothing to publish before the first commit")
        XCTAssertEqual(Pane.primaryAction(for: status { $0.branch = nil }), .nothing, "a detached HEAD has no branch to publish")
        XCTAssertEqual(Pane.primaryAction(for: status { $0.upstream = "origin/main"; $0.ahead = 2; $0.behind = 1 }), .sync(ahead: 2, behind: 1))
        XCTAssertEqual(Pane.PrimaryAction.sync(ahead: 2, behind: 1).title, "Sync Changes  ↑2  ↓1")
        XCTAssertEqual(Pane.PrimaryAction.sync(ahead: 0, behind: 3).title, "Sync Changes  ↓3")
        let conflict = GitFileChange(path: "a", status: "!", isStaged: false)
        XCTAssertEqual(Pane.primaryAction(for: status { $0.isMerging = true; $0.unstaged = [conflict] }), .resolveConflicts(1))
        XCTAssertFalse(Pane.PrimaryAction.resolveConflicts(1).isEnabled)
        XCTAssertEqual(Pane.PrimaryAction.resolveConflicts(1).title, "Resolve 1 Conflict First")
        XCTAssertEqual(Pane.primaryAction(for: status { $0.isMerging = true; $0.staged = [GitFileChange(path: "a", status: "M", isStaged: true)] }), .commitMerge)
        XCTAssertEqual(Pane.primaryAction(for: status { $0.isMerging = true }), .commitMerge)
        XCTAssertEqual(Pane.primaryAction(for: status { $0.isRebasing = true }), .continueRebase)
        XCTAssertEqual(Pane.primaryAction(for: status { $0.isRebasing = true; $0.unstaged = [conflict] }), .resolveConflicts(1))
        XCTAssertFalse(Pane.PrimaryAction.nothing.isEnabled)
        XCTAssertEqual(Pane.PrimaryAction.publish.title, "Publish Branch")
    }

    func testAFailedPullIsToldApart() {
        typealias Pane = SourceControlViewController
        func result(_ output: String, _ error: String = "") -> GitResult { GitResult(status: 1, output: output, error: error) }
        XCTAssertEqual(Pane.classify(result("CONFLICT (content): Merge conflict in a.txt\nAutomatic merge failed; fix conflicts and then commit the result.")), .conflict)
        XCTAssertEqual(Pane.classify(result("", "error: could not apply 1234567... local\nResolve all conflicts manually")), .conflict)
        XCTAssertEqual(Pane.classify(result("", "There is no tracking information for the current branch.")), .noUpstream)
        XCTAssertEqual(Pane.classify(result("", "fatal: The current branch feature has no upstream branch.")), .noUpstream)
        XCTAssertEqual(Pane.classify(result("", "error: Your local changes to the following files would be overwritten by merge:\n\ta.txt\nPlease commit your changes or stash them before you merge.")), .localChangesInTheWay)
        XCTAssertEqual(Pane.classify(result("", "fatal: Authentication failed for 'https://github.com/x/y/'")), .authentication)
        XCTAssertEqual(Pane.classify(result("", "git@github.com: Permission denied (publickey).")), .authentication)
        XCTAssertEqual(Pane.classify(result("", "fatal: unable to access 'https://…': Could not resolve host: github.com")), .other)
        XCTAssertEqual(Pane.classify(result("", "hint: You have divergent branches and need to specify how to reconcile them.\nfatal: Need to specify how to reconcile divergent branches.")), .divergent)
    }

    func testWherePublishPushes() {
        typealias Pane = SourceControlViewController
        XCTAssertEqual(Pane.publishPlan(remotes: []), .needsRemote)
        XCTAssertEqual(Pane.publishPlan(remotes: ["origin"]), .push(remote: "origin"))
        XCTAssertEqual(Pane.publishPlan(remotes: ["upstream", "origin"]), .push(remote: "origin"))
        XCTAssertEqual(Pane.publishPlan(remotes: ["fork"]), .push(remote: "fork"))
    }

    func testTheGitHubCLIIsLookedForAndCalledRight() throws {
        typealias Pane = SourceControlViewController
        let folder = TestSupport.temporaryDirectory("feather-gh")
        roots.append(folder)
        XCTAssertNil(Pane.gitHubCLI(pathDirectories: [folder.path]).flatMap { $0.path.hasPrefix(folder.path) ? $0 : nil })
        let gh = folder.appendingPathComponent("gh")
        try "#!/bin/sh\n".write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        XCTAssertEqual(Pane.gitHubCLI(pathDirectories: [folder.path]), gh)
        let root = URL(fileURLWithPath: "/tmp/My Project")
        XCTAssertEqual(Pane.gitHubCreateArguments(name: "my-project", isPrivate: true, root: root),
                       ["repo", "create", "my-project", "--private", "--source", "/tmp/My Project", "--remote", "origin", "--push"])
        XCTAssertTrue(Pane.gitHubCreateArguments(name: "p", isPrivate: false, root: root).contains("--public"))
    }

    // MARK: - Real repositories

    /// A bare origin with two clones: `a` pushes a change, `b` changes the same line and pulls.
    private func divergedClones() throws -> (origin: URL, a: URL, b: URL) {
        let seed = try TestSupport.makeRepository(["a.txt": "1\n", "other.txt": "o\n"])
        let origin = TestSupport.temporaryDirectory("feather-origin")
        let a = TestSupport.temporaryDirectory("feather-clone-a"), b = TestSupport.temporaryDirectory("feather-clone-b")
        roots += [seed, origin, a, b]
        for folder in [origin, a, b] { try? FileManager.default.removeItem(at: folder) }
        TestSupport.git(["clone", "-q", "--bare", seed.path, origin.path], in: seed)
        TestSupport.git(["clone", "-q", origin.path, a.path], in: seed)
        TestSupport.git(["clone", "-q", origin.path, b.path], in: seed)
        for clone in [a, b] {
            TestSupport.git(["config", "user.email", "test@example.com"], in: clone)
            TestSupport.git(["config", "user.name", "Feather Tests"], in: clone)
        }
        try "from a\n".write(to: a.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        TestSupport.git(["commit", "-qam", "a's change"], in: a)
        TestSupport.git(["push", "-q"], in: a)
        try "from b\n".write(to: b.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        TestSupport.git(["commit", "-qam", "b's change"], in: b)
        return (origin, a, b)
    }

    private func gitStatus(_ root: URL) -> GitStatus? {
        var status: GitStatus?
        var done = false
        Git.status(in: root) { status = $0; done = true }
        XCTAssertTrue(TestSupport.wait(upTo: 15) { done })
        return status
    }

    private func run(_ arguments: [String], in root: URL) -> GitResult {
        var result: GitResult?
        Git.run(arguments, in: root) { result = $0 }
        XCTAssertTrue(TestSupport.wait(upTo: 30) { result != nil })
        return result ?? GitResult(status: -1, output: "", error: "no result")
    }

    func testAPullWithConflictsIsAMergeToFinishAndTheEditorFinishesIt() throws {
        let clones = try divergedClones()
        // Modern git first asks how to reconcile; the pane answers "merge" and pulls again.
        let first = run(["pull", "--no-edit"], in: clones.b)
        XCTAssertFalse(first.ok)
        XCTAssertEqual(SourceControlViewController.classify(first), .divergent, first.error)
        let pull = run(["pull", "--no-edit", "--no-rebase"], in: clones.b)
        XCTAssertFalse(pull.ok)
        XCTAssertEqual(SourceControlViewController.classify(pull), .conflict, pull.error)
        var status = try XCTUnwrap(gitStatus(clones.b))
        XCTAssertTrue(status.isMerging)
        XCTAssertFalse(status.isRebasing)
        XCTAssertEqual(status.conflicts.map(\.path), ["a.txt"])
        XCTAssertEqual(SourceControlViewController.primaryAction(for: status), .resolveConflicts(1))

        // The file as git left it, resolved the way the editor's Accept Incoming does.
        let file = clones.b.appendingPathComponent("a.txt")
        let text = try String(contentsOf: file, encoding: .utf8) as NSString
        let conflicts = MergeConflict.find(in: text)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].currentLabel, "HEAD")
        XCTAssertTrue(text.substring(with: conflicts[0].current).contains("from b"))
        XCTAssertTrue(text.substring(with: conflicts[0].incoming).contains("from a"))
        let edit = conflicts[0].edit(.incoming, in: text)
        try text.replacingCharacters(in: edit.range, with: edit.text).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "from a\n")

        // "+" on the row: mark as resolved; the button becomes Commit Merge; the merge commit closes it.
        XCTAssertTrue(run(["add", "--", "a.txt"], in: clones.b).ok)
        status = try XCTUnwrap(gitStatus(clones.b))
        XCTAssertTrue(status.isMerging)
        XCTAssertTrue(status.conflicts.isEmpty)
        XCTAssertEqual(SourceControlViewController.primaryAction(for: status), .commitMerge)
        XCTAssertTrue(run(["commit", "--no-edit"], in: clones.b).ok)
        status = try XCTUnwrap(gitStatus(clones.b))
        XCTAssertFalse(status.isMerging)
        XCTAssertEqual(status.ahead, 2, "b's commit and the merge, ready to push")
        XCTAssertEqual(SourceControlViewController.primaryAction(for: status), .sync(ahead: 2, behind: 0))
    }

    func testAPullThatRebasesPausesAndContinues() throws {
        let clones = try divergedClones()
        let pull = run(["-c", "pull.rebase=true", "pull"], in: clones.b)
        XCTAssertFalse(pull.ok)
        XCTAssertEqual(SourceControlViewController.classify(pull), .conflict, pull.error)
        var status = try XCTUnwrap(gitStatus(clones.b))
        XCTAssertTrue(status.isRebasing)
        XCTAssertFalse(status.isMerging)
        XCTAssertEqual(status.conflicts.map(\.path), ["a.txt"])
        XCTAssertEqual(SourceControlViewController.primaryAction(for: status), .resolveConflicts(1))

        let file = clones.b.appendingPathComponent("a.txt")
        let text = try String(contentsOf: file, encoding: .utf8) as NSString
        let conflict = try XCTUnwrap(MergeConflict.find(in: text).first)
        // While rebasing, "current" is the upstream commit being replayed onto, and "incoming" is b's own commit.
        XCTAssertTrue(text.substring(with: conflict.current).contains("from a"))
        XCTAssertTrue(text.substring(with: conflict.incoming).contains("from b"))
        let edit = conflict.edit(.both, in: text)
        try text.replacingCharacters(in: edit.range, with: edit.text).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(run(["add", "--", "a.txt"], in: clones.b).ok)
        status = try XCTUnwrap(gitStatus(clones.b))
        XCTAssertEqual(SourceControlViewController.primaryAction(for: status), .continueRebase)
        XCTAssertTrue(run(["rebase", "--continue"], in: clones.b).ok, "GIT_EDITOR is set, so no editor opens")
        status = try XCTUnwrap(gitStatus(clones.b))
        XCTAssertFalse(status.isRebasing)
        XCTAssertEqual(status.ahead, 1)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "from a\nfrom b\n")
    }

    func testPublishingABranchGivesItAnUpstream() throws {
        let clones = try divergedClones()
        TestSupport.git(["checkout", "-qb", "feature/publish"], in: clones.a)
        var status = try XCTUnwrap(gitStatus(clones.a))
        XCTAssertNil(status.upstream)
        XCTAssertEqual(SourceControlViewController.primaryAction(for: status), .publish)
        let remotes = run(["remote"], in: clones.a)
        XCTAssertEqual(SourceControlViewController.publishPlan(remotes: remotes.output.split(separator: "\n").map(String.init)), .push(remote: "origin"))
        XCTAssertTrue(run(["push", "-u", "origin", "feature/publish"], in: clones.a).ok)
        status = try XCTUnwrap(gitStatus(clones.a))
        XCTAssertEqual(status.upstream, "origin/feature/publish")
        XCTAssertEqual(SourceControlViewController.primaryAction(for: status), .nothing)
    }

    // MARK: - Through the pane itself

    /// The pane in a window (its refreshes only run on screen), opened on `root`, with its status loaded.
    private func pane(for root: URL) throws -> (SourceControlViewController, NSWindow, [String]) {
        let pane = SourceControlViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = pane.view
        var alerts: [String] = []
        pane.alertHandlerForTests = { alerts.append($0.messageText + "\n" + $0.informativeText) }
        pane.setProjectRoot(root)
        XCTAssertTrue(TestSupport.wait(upTo: 15) { pane.repositoryRoot != nil && pane.statusForTests.branch != nil }, "the pane never found the repository")
        windows.append(window)
        alertLog[ObjectIdentifier(pane)] = { alerts }
        return (pane, window, alerts)
    }
    private var windows: [NSWindow] = []
    private var alertLog: [ObjectIdentifier: () -> [String]] = [:]

    private func settled(_ pane: SourceControlViewController, until condition: @escaping () -> Bool, _ seconds: TimeInterval = 30) -> Bool {
        TestSupport.wait(upTo: seconds) { !pane.isBusyForTests && condition() }
    }

    /// The list is laid out as VS Code's: a "Changes" header with its count on a pill, each file as icon, name,
    /// dimmed folder and a coloured status letter at the right, and the row's actions only under the pointer.
    func testRowsReadLikeVSCodes() throws {
        let clones = try divergedClones()
        let repo = clones.b
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        try "new\n".write(to: repo.appendingPathComponent("src/deep/new.swift"), atomically: true, encoding: .utf8)
        try "changed\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "staged\n".write(to: repo.appendingPathComponent("staged.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(run(["add", "--", "staged.txt"], in: repo).ok)
        let (pane, window, _) = try pane(for: repo)
        XCTAssertTrue(settled(pane, until: { pane.statusForTests.staged.count + pane.statusForTests.unstaged.count == 3 }), "\(pane.statusForTests)")
        let outline = pane.outlineViewForTests
        window.layoutIfNeeded()
        func row(_ index: Int) -> ChangeRowView? { outline.view(atColumn: 0, row: index, makeIfNecessary: true) as? ChangeRowView }
        var rows: [String] = []
        for index in 0..<outline.numberOfRows { rows.append(row(index)?.label.stringValue ?? "?") }
        XCTAssertEqual(rows, ["Staged Changes", "staged.txt", "Changes", "a.txt", "new.swift"], "\(rows)")

        let staged = try XCTUnwrap(row(0))
        XCTAssertFalse(staged.count.isHidden)
        XCTAssertEqual(staged.count.text, "1")
        XCTAssertTrue(staged.letter.isHidden && staged.icon.isHidden)
        let changes = try XCTUnwrap(row(2))
        XCTAssertEqual(changes.count.text, "2")

        let deep = try XCTUnwrap(row(4))
        XCTAssertEqual(deep.detail.stringValue, "src/deep")
        XCTAssertFalse(deep.detail.isHidden)
        XCTAssertEqual(deep.letter.stringValue, "U")
        XCTAssertEqual(deep.letter.textColor, ChangeRowView.statusColor("U"))
        XCTAssertNotNil(deep.icon.image)
        XCTAssertEqual(deep.toolTip, "src/deep/new.swift · Untracked")
        let top = try XCTUnwrap(row(3))
        XCTAssertTrue(top.detail.isHidden, "a file at the root has no folder to show")
        XCTAssertEqual(top.letter.stringValue, "M")
        XCTAssertEqual(top.letter.textColor, ChangeRowView.statusColor("M"))
        XCTAssertEqual(try XCTUnwrap(row(1)).letter.stringValue, "A")

        // Actions show only on the hovered row.
        XCTAssertTrue(deep.actionsHiddenForTests)
        (outline as? ChangesOutlineView)?.setHovered(4)
        XCTAssertFalse(deep.actionsHiddenForTests)
        XCTAssertTrue(top.actionsHiddenForTests)
        (outline as? ChangesOutlineView)?.setHovered(-1)
        XCTAssertTrue(deep.actionsHiddenForTests)

        // The message box names the branch and the button carries an icon, as VS Code's do.
        XCTAssertEqual(pane.messagePlaceholderForTests, "Message (⌘↩ to commit on “main”)")
        XCTAssertNotNil(pane.primaryImageForTests)
        XCTAssertEqual(SourceControlViewController.PrimaryAction.commit("m").symbol, "checkmark")
        XCTAssertEqual(SourceControlViewController.PrimaryAction.sync(ahead: 1, behind: 0).symbol, "arrow.triangle.2.circlepath")
        XCTAssertEqual(SourceControlViewController.PrimaryAction.publish.symbol, "icloud.and.arrow.up")
        XCTAssertEqual(ChangeRowView.statusName("!"), "Conflict")
        XCTAssertEqual(ChangeRowView.statusName("R"), "Renamed")
    }

    func testSyncThroughThePanePullsThenPushes() throws {
        let clones = try divergedClones()
        // Undo b's conflicting commit; give it a commit of its own that merges cleanly instead.
        TestSupport.git(["reset", "-q", "--hard", "HEAD~1"], in: clones.b)
        try "b's own\n".write(to: clones.b.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        TestSupport.git(["commit", "-qam", "b's own"], in: clones.b)
        let (pane, _, _) = try pane(for: clones.b)
        TestSupport.git(["fetch", "-q"], in: clones.b)
        pane.refresh()
        XCTAssertTrue(settled(pane, until: { pane.statusForTests.ahead == 1 && pane.statusForTests.behind == 1 }), "\(pane.statusForTests)")
        XCTAssertEqual(pane.primaryTitleForTests, "Sync Changes  ↑1  ↓1")
        pane.pressPrimaryForTests()
        // Divergent → merge → push: the origin ends up with both sides and a merge commit.
        XCTAssertTrue(settled(pane, until: { pane.statusForTests.ahead == 0 && pane.statusForTests.behind == 0 }), "\(pane.statusForTests)")
        let log = TestSupport.git(["log", "--oneline", "main"], in: clones.origin)
        XCTAssertEqual(log.split(separator: "\n").count, 4, log)
        XCTAssertTrue(log.contains("b's own") && log.contains("a's change"))
        XCTAssertEqual(alertLog[ObjectIdentifier(pane)]?(), [], "nothing to report")
        XCTAssertEqual(pane.primaryTitleForTests, "Commit")
    }

    func testAConflictingPullThroughThePaneGuidesAndFinishesAsAMerge() throws {
        let clones = try divergedClones()
        let (pane, _, _) = try pane(for: clones.b)
        pane.pull()
        XCTAssertTrue(settled(pane, until: { pane.statusForTests.isMerging }), "\(pane.statusForTests)")
        let alerts = alertLog[ObjectIdentifier(pane)]?() ?? []
        XCTAssertEqual(alerts.count, 1, alerts.joined(separator: "\n---\n"))
        XCTAssertTrue(alerts.first?.contains("Accept Current, Accept Incoming and Accept Both") ?? false)
        XCTAssertTrue(alerts.first?.contains("Commit Merge") ?? false)
        XCTAssertEqual(pane.primaryTitleForTests, "Resolve 1 Conflict First")
        XCTAssertEqual(pane.statusForTests.conflicts.map(\.path), ["a.txt"])

        // The editor's Accept Current, then + (git add), then the button.
        let file = clones.b.appendingPathComponent("a.txt")
        let text = try String(contentsOf: file, encoding: .utf8) as NSString
        let edit = try XCTUnwrap(MergeConflict.find(in: text).first).edit(.current, in: text)
        try text.replacingCharacters(in: edit.range, with: edit.text).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(run(["add", "--", "a.txt"], in: clones.b).ok)
        pane.refresh()
        XCTAssertTrue(settled(pane, until: { pane.statusForTests.conflicts.isEmpty && pane.statusForTests.isMerging }))
        XCTAssertEqual(pane.primaryTitleForTests, "Commit Merge")
        pane.pressPrimaryForTests()
        XCTAssertTrue(settled(pane, until: { !pane.statusForTests.isMerging }))
        XCTAssertEqual(pane.primaryTitleForTests, "Sync Changes  ↑2")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "from b\n")
    }

    func testPublishThroughThePane() throws {
        let clones = try divergedClones()
        TestSupport.git(["checkout", "-qb", "feature/pane"], in: clones.a)
        let (pane, _, _) = try pane(for: clones.a)
        XCTAssertTrue(settled(pane, until: { pane.remotesForTests == ["origin"] }))
        XCTAssertEqual(pane.primaryTitleForTests, "Publish Branch")
        pane.pressPrimaryForTests()
        XCTAssertTrue(settled(pane, until: { pane.statusForTests.upstream == "origin/feature/pane" }), "\(pane.statusForTests)")
        XCTAssertEqual(pane.primaryTitleForTests, "Commit")
        XCTAssertTrue(TestSupport.git(["branch", "--list", "feature/pane"], in: clones.origin).contains("feature/pane"))
        XCTAssertEqual(alertLog[ObjectIdentifier(pane)]?(), [])
    }

    func testPullWithoutAnUpstreamSaysSo() throws {
        let clones = try divergedClones()
        TestSupport.git(["checkout", "-qb", "lonely"], in: clones.a)
        let (pane, _, _) = try pane(for: clones.a)
        pane.pull()
        XCTAssertTrue(settled(pane, until: { !(self.alertLog[ObjectIdentifier(pane)]?() ?? []).isEmpty }))
        let alert = alertLog[ObjectIdentifier(pane)]?().first ?? ""
        XCTAssertTrue(alert.contains("not connected to a remote branch") && alert.contains("Publish Branch"), alert)
    }

    func testPullOverUncommittedChangesSaysSo() throws {
        let clones = try divergedClones()
        TestSupport.git(["reset", "-q", "--hard", "HEAD~1"], in: clones.b)
        try "dirty\n".write(to: clones.b.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)   // a changed upstream too
        let (pane, _, _) = try pane(for: clones.b)
        pane.pull()
        XCTAssertTrue(settled(pane, until: { !(self.alertLog[ObjectIdentifier(pane)]?() ?? []).isEmpty }))
        let alert = alertLog[ObjectIdentifier(pane)]?().first ?? ""
        XCTAssertTrue(alert.contains("Your changes are in the way") && alert.contains("Stash Changes"), alert)
    }

    func testTheGitFolderOfAWorktreeIsFoundThroughItsGitFile() throws {
        let main = try TestSupport.makeRepository()
        let worktree = TestSupport.temporaryDirectory("feather-wt")
        roots += [main, worktree]
        try FileManager.default.removeItem(at: worktree)
        TestSupport.git(["worktree", "add", "-q", worktree.path, "-b", "wt"], in: main)
        XCTAssertEqual(Git.gitDirectory(of: main).path, main.appendingPathComponent(".git").path)
        let found = Git.gitDirectory(of: worktree)
        XCTAssertTrue(found.path.contains("/.git/worktrees/"), found.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: found.appendingPathComponent("HEAD").path))
    }
}
