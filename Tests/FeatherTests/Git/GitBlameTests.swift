import XCTest
@testable import Feather

/// Git/GitBlame.swift: the `git blame --porcelain` parser (hand-written output and a real repository's), the
/// line map that follows unsaved edits, and the status bar text for a line. The button and its card are UI
/// and are not covered here.
final class GitBlameParsingTests: XCTestCase {
    private let porcelain = """
    1111111111111111111111111111111111111111 1 1 2
    author Ada Lovelace
    author-mail <ada@example.com>
    author-time 1700000000
    author-tz +0000
    committer Ada Lovelace
    committer-mail <ada@example.com>
    committer-time 1700000000
    committer-tz +0000
    summary First commit
    filename f.txt
    \tline one
    1111111111111111111111111111111111111111 2 2
    \tline two
    2222222222222222222222222222222222222222 3 3 1
    author Bob
    author-mail <bob@example.com>
    author-time 1700003600
    author-tz +0100
    committer Bob
    committer-mail <bob@example.com>
    committer-time 1700003600
    committer-tz +0100
    summary Second commit: a longer subject line
    previous 1111111111111111111111111111111111111111 f.txt
    filename f.txt
    \tline three
    0000000000000000000000000000000000000000 4 4 1
    author Not Committed Yet
    author-mail <not.committed.yet>
    author-time 1700007200
    author-tz +0000
    committer Not Committed Yet
    committer-mail <not.committed.yet>
    committer-time 1700007200
    committer-tz +0000
    summary Version of f.txt from f.txt
    filename f.txt
    \tline four

    """

    func testCommitsAreCollectedInOrderOfFirstAppearance() {
        let parsed = BlameStore.parse(porcelain)
        XCTAssertEqual(parsed.commits.map(\.hash).map { String($0.prefix(4)) }, ["1111", "2222", "0000"])
        XCTAssertEqual(parsed.commits[0].author, "Ada Lovelace")
        XCTAssertEqual(parsed.commits[0].email, "ada@example.com", "the angle brackets are dropped")
        XCTAssertEqual(parsed.commits[0].date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(parsed.commits[0].summary, "First commit")
        XCTAssertEqual(parsed.commits[1].summary, "Second commit: a longer subject line")
        XCTAssertFalse(parsed.commits[1].isUncommitted)
        XCTAssertTrue(parsed.commits[2].isUncommitted)
    }

    func testEveryLineNamesItsCommitAndKeepsItsText() {
        let parsed = BlameStore.parse(porcelain)
        XCTAssertEqual(parsed.lineCommits, [0, 0, 1, 2])
        XCTAssertEqual(parsed.lineTexts, ["line one", "line two", "line three", "line four"])
    }

    func testARepeatedCommitWithoutDetailsStillResolves() {
        // The second line of the first group repeats the hash with no header fields under it.
        let parsed = BlameStore.parse(porcelain)
        XCTAssertEqual(parsed.commits[parsed.lineCommits[1]].author, "Ada Lovelace")
    }

    func testMissingFieldsBecomeEmptyValues() {
        let parsed = BlameStore.parse("abcdefabcdefabcdefabcdefabcdefabcdefabcd 1 1 1\n\tonly\n")
        XCTAssertEqual(parsed.commits.count, 1)
        XCTAssertEqual(parsed.commits[0].author, "")
        XCTAssertEqual(parsed.commits[0].email, "")
        XCTAssertEqual(parsed.commits[0].date, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(parsed.lineTexts, ["only"])
    }

    func testEmptyOutputAndLinesWithTabsInside() {
        XCTAssertTrue(BlameStore.parse("").commits.isEmpty)
        XCTAssertTrue(BlameStore.parse("").lineCommits.isEmpty)
        let parsed = BlameStore.parse("abcdefabcdefabcdefabcdefabcdefabcdefabcd 1 1 1\nsummary s\n\t\tindented\twith tabs\n")
        XCTAssertEqual(parsed.lineTexts, ["\tindented\twith tabs"], "only the first tab is the separator")
    }

    func testNonASCIIAuthorsAndText() {
        let parsed = BlameStore.parse("abcdefabcdefabcdefabcdefabcdefabcdefabcd 1 1 1\nauthor Zoë Ångström\nsummary 变更\n\tcafé ☕\n")
        XCTAssertEqual(parsed.commits[0].author, "Zoë Ångström")
        XCTAssertEqual(parsed.commits[0].summary, "变更")
        XCTAssertEqual(parsed.lineTexts, ["café ☕"])
    }

    func testAnEmptyLineOfTheFileIsKept() {
        let parsed = BlameStore.parse("abcdefabcdefabcdefabcdefabcdefabcdefabcd 1 1 2\n\t\nabcdefabcdefabcdefabcdefabcdefabcdefabcd 2 2\n\tx\n")
        XCTAssertEqual(parsed.lineTexts, ["", "x"])
        XCTAssertEqual(parsed.lineCommits, [0, 0])
    }

    func testAScriptedRepositoryParsesTheSameWay() throws {
        let root = try TestSupport.makeRepository(["f.txt": "one\ntwo\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        try "one\ntwo\nthree\n".write(to: root.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        TestSupport.git(["-c", "user.name=Second Author", "-c", "user.email=second@example.com", "commit", "-qam", "add three"], in: root)
        try "one\ntwo\nthree\nfour\n".write(to: root.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let output = TestSupport.git(["blame", "--porcelain", "--", "f.txt"], in: root)
        let parsed = BlameStore.parse(output)
        XCTAssertEqual(parsed.lineTexts, ["one", "two", "three", "four"])
        XCTAssertEqual(parsed.commits.count, 3)
        XCTAssertEqual(parsed.commits[parsed.lineCommits[0]].summary, "init")
        XCTAssertEqual(parsed.commits[parsed.lineCommits[0]].email, "test@example.com")
        XCTAssertEqual(parsed.commits[parsed.lineCommits[2]].author, "Second Author")
        XCTAssertEqual(parsed.commits[parsed.lineCommits[2]].summary, "add three")
        XCTAssertTrue(parsed.commits[parsed.lineCommits[3]].isUncommitted)
        XCTAssertEqual(parsed.lineCommits[0], parsed.lineCommits[1])
    }

    // MARK: - Following unsaved edits

    func testUnchangedTextMapsLineForLine() {
        XCTAssertEqual(BlameStore.lineMap(from: ["a", "b", "c"], to: "a\nb\nc\n"), [0, 1, 2])
        XCTAssertEqual(BlameStore.lineMap(from: ["a", "b", "c"], to: "a\nb\nc"), [0, 1, 2], "with or without a final newline")
        XCTAssertEqual(BlameStore.lineMap(from: [], to: ""), [])
    }

    func testInsertedLinesHaveNoBlameAndShiftTheRest() {
        XCTAssertEqual(BlameStore.lineMap(from: ["a", "b"], to: "a\nnew\nb\n"), [0, -1, 1])
        XCTAssertEqual(BlameStore.lineMap(from: ["a", "b"], to: "new\na\nb\n"), [-1, 0, 1])
        XCTAssertEqual(BlameStore.lineMap(from: ["a", "b"], to: "a\nb\nnew\n"), [0, 1, -1])
    }

    func testRemovedAndEditedLines() {
        XCTAssertEqual(BlameStore.lineMap(from: ["a", "b", "c"], to: "a\nc\n"), [0, 2])
        XCTAssertEqual(BlameStore.lineMap(from: ["a", "b", "c"], to: "a\nB\nc\n"), [0, -1, 2])
        XCTAssertEqual(BlameStore.lineMap(from: ["a", "b", "c"], to: "x\ny\n"), [-1, -1])
    }

    func testWindowsLineEndingsAreOneLineEach() {
        XCTAssertEqual(BlameStore.lineMap(from: ["a", "b"], to: "a\r\nb\r\n"), [0, 1])
    }

    func testAHugeFileGetsNoMap() {
        let big = Array(repeating: "x", count: LineDiff.maxLines + 1)
        XCTAssertEqual(BlameStore.lineMap(from: big, to: "x\ny\n"), [-1, -1])
    }

    // MARK: - The status bar text

    private func commit(summary: String = "Fix the thing", hash: String = "abc", email: String = "ada@example.com") -> BlameCommit {
        BlameCommit(hash: hash, author: "Ada", email: email, date: Date().addingTimeInterval(-90_000), summary: summary)
    }

    func testTextNamesTheAuthorTheAgeAndTheSummary() {
        let text = BlameStore.Info(commit: commit(), isYou: false, root: nil).text
        XCTAssertTrue(text.hasPrefix("Ada, "), text)
        XCTAssertTrue(text.hasSuffix(" · Fix the thing"), text)
        XCTAssertGreaterThan(text.count, "Ada,  · Fix the thing".count, "the age sits between the two")
    }

    func testYourOwnLinesSayYou() {
        XCTAssertTrue(BlameStore.Info(commit: commit(), isYou: true, root: nil).text.hasPrefix("You, "))
    }

    func testALongSummaryIsCutShort() {
        let long = String(repeating: "word ", count: 30)
        let text = BlameStore.Info(commit: commit(summary: long), isYou: false, root: nil).text
        XCTAssertTrue(text.hasSuffix("…"))
        XCTAssertTrue(text.contains(String(long.prefix(60)) + "…"))
    }

    func testAnUncommittedLineHasNoAuthor() {
        let uncommitted = commit(hash: String(repeating: "0", count: 40))
        XCTAssertTrue(uncommitted.isUncommitted)
        XCTAssertEqual(BlameStore.Info(commit: uncommitted, isYou: true, root: nil).text, "Not committed yet")
    }
}
