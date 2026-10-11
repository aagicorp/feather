import XCTest
@testable import Feather

/// Git/GitGraph.swift: parsing `git log` output in Feather's format (fields, decorations, odd subjects), laying
/// out lanes on hand-built histories (linear, a branch, a merge, an octopus merge) and on a scripted real
/// repository, and the branch pills. The windows and table views are not covered here.
final class GitGraphLayoutTests: XCTestCase {
    private let sep = GitGraphLayout.separator

    private func line(_ hash: String, parents: [String], refs: String = "", subject: String = "msg", date: String = "1700000000") -> String {
        [hash, parents.joined(separator: " "), "Ada", date, refs, subject].joined(separator: sep)
    }

    func testParseReadsEveryField() {
        let output = line("aaa", parents: ["bbb", "ccc"], refs: "HEAD -> refs/heads/main, refs/remotes/origin/main", subject: "Merge it") + "\n"
            + line("bbb", parents: [], subject: "first") + "\n"
        let commits = GitGraphLayout.parse(output)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].hash, "aaa")
        XCTAssertEqual(commits[0].parents, ["bbb", "ccc"])
        XCTAssertTrue(commits[0].isMerge)
        XCTAssertEqual(commits[0].author, "Ada")
        XCTAssertEqual(commits[0].date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(commits[0].subject, "Merge it")
        XCTAssertEqual(commits[0].refs.map(\.name), ["main", "origin/main"])
        XCTAssertEqual(commits[0].refs.map(\.kind), [.head, .remote])
        XCTAssertEqual(commits[1].parents, [])
        XCTAssertFalse(commits[1].isMerge)
        XCTAssertTrue(commits[1].refs.isEmpty)
        XCTAssertEqual(commits[1].shortHash, "bbb")
    }

    func testParseSkipsShortLinesAndKeepsTheSeparatorInsideASubject() {
        let output = "garbage\n" + line("aaa", parents: [], subject: "a\(sep)b") + "\n\n"
        let commits = GitGraphLayout.parse(output)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].subject, "a\(sep)b")
        XCTAssertTrue(GitGraphLayout.parse("").isEmpty)
        XCTAssertEqual(GitGraphLayout.parse(line("a", parents: [], date: "not a date")).first?.date, Date(timeIntervalSince1970: 0))
    }

    func testRefsAreToldApartByTheirFullNames() {
        let refs = GitGraphLayout.parse(line("a", parents: [], refs:
            "HEAD -> refs/heads/feature/login, refs/remotes/origin/login, tag: refs/tags/v1.0, refs/remotes/origin/HEAD, refs/stash, HEAD"))[0].refs
        XCTAssertEqual(refs.map(\.name), ["feature/login", "origin/login", "v1.0", "HEAD"])
        XCTAssertEqual(refs.map(\.kind), [.head, .remote, .tag, .head])
    }

    func testADetachedHeadOnATagIsStillTheHead() {
        let refs = GitGraphLayout.parse(line("a", parents: [], refs: "HEAD -> refs/tags/v2, refs/heads/main"))[0].refs
        XCTAssertEqual(refs.map(\.kind), [.head, .local])
        XCTAssertEqual(refs.map(\.name), ["v2", "main"])
    }

    // MARK: - Lanes

    private func commits(_ history: [(String, [String])]) -> [GitCommit] {
        history.map { GitCommit(hash: $0.0, parents: $0.1, author: "", date: Date(), refs: [], subject: "") }
    }

    func testALinearHistoryIsOneLane() {
        let list = commits([("c", ["b"]), ("b", ["a"]), ("a", [])])
        XCTAssertEqual(GitGraphLayout.assignLanes(list), 1)
        XCTAssertEqual(list.map(\.lane), [0, 0, 0])
        XCTAssertEqual(list[0].incoming.count, 0)
        XCTAssertEqual(list[0].parentLanes, [0])
        XCTAssertEqual(list[1].incoming.map(\.lane), [0])
        XCTAssertEqual(list[1].incoming.map(\.joins), [true])
        XCTAssertEqual(list[2].parentLanes, [], "the root has nothing below it")
        XCTAssertTrue(list.allSatisfy { $0.passing.isEmpty })
    }

    func testABranchAndItsMergeTakeTwoLanes() {
        // m merges f into c; f branched off a. Order is as `git log --date-order` gives it.
        let list = commits([("m", ["c", "f"]), ("c", ["b"]), ("f", ["a"]), ("b", ["a"]), ("a", [])])
        XCTAssertEqual(GitGraphLayout.assignLanes(list), 2)
        // The branch keeps lane 1 down to the commit it branched from, because "f" reserved that lane for "a"
        // before "b" (in lane 0) got to name the same parent.
        XCTAssertEqual(list.map(\.lane), [0, 0, 1, 0, 1])
        XCTAssertEqual(list[0].parentLanes, [0, 1])
        // While "c" is drawn, lane 1 is still waiting for "f" and passes straight through.
        XCTAssertEqual(list[1].passing, [1])
        XCTAssertEqual(list[1].incoming.map(\.joins), [true, false])
        XCTAssertEqual(list[2].parentLanes, [1])
        XCTAssertEqual(list[2].passing, [0])
        // "b" bends across into lane 1 to reach "a"; only lane 1 is left when "a" is drawn.
        XCTAssertEqual(list[3].parentLanes, [1])
        XCTAssertEqual(list[3].incoming.map(\.lane), [0, 1])
        XCTAssertEqual(list[4].incoming.map(\.lane), [1])
        XCTAssertEqual(list[4].incoming.map(\.joins), [true])
    }

    func testAnOctopusMergeOpensALaneForEveryExtraParent() {
        let list = commits([("m", ["a", "b", "c"]), ("a", ["r"]), ("b", ["r"]), ("c", ["r"]), ("r", [])])
        XCTAssertEqual(GitGraphLayout.assignLanes(list), 3)
        XCTAssertEqual(list[0].parentLanes, [0, 1, 2])
        XCTAssertEqual(list.map(\.lane), [0, 0, 1, 2, 0])
        // "a" claims lane 0 for the shared parent; the other two bend into it and their lanes close.
        XCTAssertEqual(list[1].passing, [1, 2])
        XCTAssertEqual(list[2].parentLanes, [0])
        XCTAssertEqual(list[3].parentLanes, [0])
        XCTAssertEqual(list[4].incoming.map(\.lane), [0])
        XCTAssertTrue(list[4].incoming.allSatisfy(\.joins))
    }

    func testAFreedLaneIsReusedByTheNextBranch() {
        // "g" is drawn and its lane closed before "m1" needs a lane for "f", so "f" takes lane 0 rather than a third.
        let list = commits([("m2", ["m1", "g"]), ("g", ["c"]), ("m1", ["c", "f"]), ("f", ["c"]), ("c", [])])
        XCTAssertEqual(GitGraphLayout.assignLanes(list), 2)
        XCTAssertEqual(list.map(\.lane), [0, 1, 0, 0, 1])
        XCTAssertEqual(list[2].parentLanes, [1, 0])
        XCTAssertEqual(list[3].passing, [1])
        XCTAssertEqual(list[4].incoming.map(\.lane), [1])
    }

    func testTwoRootsAreTwoLanes() {
        let list = commits([("b", ["a"]), ("y", ["x"]), ("a", []), ("x", [])])
        XCTAssertEqual(GitGraphLayout.assignLanes(list), 2)
        XCTAssertEqual(list.map(\.lane), [0, 1, 0, 1])
        XCTAssertEqual(GitGraphLayout.assignLanes([]), 1)
    }

    func testLayoutIsTheSameEveryTime() {
        let history: [(String, [String])] = [("m", ["c", "f"]), ("c", ["b"]), ("f", ["a"]), ("b", ["a"]), ("a", [])]
        let first = commits(history), second = commits(history)
        _ = GitGraphLayout.assignLanes(first)
        _ = GitGraphLayout.assignLanes(second)
        XCTAssertEqual(first.map(\.lane), second.map(\.lane))
        XCTAssertEqual(first.map(\.parentLanes), second.map(\.parentLanes))
        XCTAssertEqual(first.map(\.passing), second.map(\.passing))
    }

    // MARK: - A real repository

    func testAScriptedRepositoryLaysOutAsExpected() throws {
        let root = try TestSupport.makeRepository(["a.txt": "1\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        func commit(_ name: String, _ text: String) {
            try? text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
            TestSupport.git(["add", name], in: root)
            TestSupport.git(["commit", "-qm", name], in: root)
        }
        TestSupport.git(["checkout", "-qb", "feature"], in: root)
        commit("f1.txt", "f1")
        commit("f2.txt", "f2")
        TestSupport.git(["checkout", "-q", "main"], in: root)
        commit("m1.txt", "m1")
        TestSupport.git(["merge", "--no-ff", "-q", "-m", "merge feature", "feature"], in: root)
        TestSupport.git(["tag", "v1"], in: root)
        let output = TestSupport.git(["log", "--all", "--date-order", "--decorate=full", "--format=" + GitGraphLayout.format], in: root)
        let commits = GitGraphLayout.parse(output)
        XCTAssertEqual(commits.count, 5)
        XCTAssertEqual(commits.map(\.subject).first, "merge feature")
        XCTAssertEqual(commits[0].refs.map(\.name), ["main", "v1"])
        XCTAssertEqual(commits[0].refs.map(\.kind), [.head, .tag])
        XCTAssertTrue(commits[0].isMerge)
        XCTAssertEqual(GitGraphLayout.assignLanes(commits), 2)
        XCTAssertEqual(commits[0].parentLanes, [0, 1])
        XCTAssertEqual(commits.last?.lane, 0)
        XCTAssertEqual(commits.last?.incoming.count, 1, "both lanes have joined by the first commit")
        let feature = commits.first { $0.refs.contains { $0.name == "feature" } }
        XCTAssertEqual(feature?.subject, "f2.txt")
        XCTAssertEqual(feature?.refs.first?.kind, .local)
    }
}

final class RefPillTests: XCTestCase {
    private func attachments(in text: NSAttributedString) -> Int {
        var count = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { count += 1 }
        }
        return count
    }

    func testColoursByKind() {
        XCTAssertNotEqual(RefPill.color(.head), RefPill.color(.local))
        XCTAssertNotEqual(RefPill.color(.remote), RefPill.color(.tag))
    }

    func testPillsAreLimitedAndTheRestCounted() {
        let refs = (1...6).map { GitRef(name: "b\($0)", kind: .local) }
        XCTAssertEqual(attachments(in: RefPill.attributed(refs, fontSize: 10)), 5, "four pills and a +2")
        XCTAssertEqual(attachments(in: RefPill.attributed(refs, fontSize: 10, limit: 1)), 2)
        XCTAssertEqual(attachments(in: RefPill.attributed(Array(refs.prefix(4)), fontSize: 10)), 4)
        XCTAssertEqual(RefPill.attributed([], fontSize: 10).length, 0)
    }

    func testTrailingSpaceIsOptional() {
        let ref = [GitRef(name: "main", kind: .head)]
        XCTAssertTrue(RefPill.attributed(ref, fontSize: 10).string.hasSuffix("  "))
        XCTAssertTrue(RefPill.attributed(ref, fontSize: 10, trailingSpace: false).string.hasSuffix(" "))
        XCTAssertFalse(RefPill.attributed(ref, fontSize: 10, trailingSpace: false).string.hasSuffix("  "))
    }

    func testImagesAreCachedByTitleColourAndSize() {
        let a = RefPill.image("cache-test", color: .red, fontSize: 10)
        let b = RefPill.image("cache-test", color: .red, fontSize: 10)
        XCTAssertTrue(a === b)
        XCTAssertFalse(a === RefPill.image("cache-test", color: .red, fontSize: 11))
        XCTAssertGreaterThan(a.size.width, 14)
    }
}
