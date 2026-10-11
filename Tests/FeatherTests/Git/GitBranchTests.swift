import XCTest
@testable import Feather

final class GitBranchTests: XCTestCase {
    private func makeRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feather-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/feature/x\n".write(to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        return root
    }

    func testBranchFromHEADAnywhereInTheTree() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(Git.branchByReadingHEAD(nearPath: root.path), "feature/x")
        XCTAssertEqual(Git.branchByReadingHEAD(nearPath: root.appendingPathComponent("src/deep").path), "feature/x")
    }

    func testDetachedHeadIsTheShortHash() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try "0123456789abcdef0123456789abcdef01234567\n".write(to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Git.branchByReadingHEAD(nearPath: root.path), "0123456")
    }

    func testWorktreeGitFile() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/worktrees/wt"), withIntermediateDirectories: true)
        try "ref: refs/heads/other\n".write(to: root.appendingPathComponent(".git/worktrees/wt/HEAD"), atomically: true, encoding: .utf8)
        try "gitdir: \(root.path)/.git/worktrees/wt\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Git.branchByReadingHEAD(nearPath: worktree.path), "other")
    }

    func testOutsideARepository() {
        XCTAssertNil(Git.branchByReadingHEAD(nearPath: "/private/tmp"))
    }

    /// The walk up must end at the root on every macOS: on macOS 15 a URL walk past "/" yields "/..", "/../.."
    /// for ever, which spun the terminal's branch poll at 100 % on the main thread (the "only loading" hang).
    func testTheWalkUpAlwaysEnds() {
        for start in ["/", "/..", "/../..", "//", "/nonexistent/deep/folder/", "/Users/nobody/Desktop/project"] {
            let started = Date()
            XCTAssertNil(Git.branchByReadingHEAD(nearPath: start), start)
            XCTAssertLessThan(Date().timeIntervalSince(started), 1, "walking up from \(start) must not spin")
        }
        for start in ["", "relative/path"] {                   // relative to the working directory; only the ending matters
            let started = Date()
            _ = Git.branchByReadingHEAD(nearPath: start)
            XCTAssertLessThan(Date().timeIntervalSince(started), 1, "walking up from \(start) must not spin")
        }
    }

    func testStatusParsingCountsAheadAndBehind() {
        let status = Git.parseStatus("## main...origin/main [ahead 2, behind 1]\0 M a.txt\0?? b.txt\0")
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertEqual(status.unstaged.map(\.path), ["a.txt", "b.txt"])
    }
}
