/// Every row of the `git status --porcelain` XY table (git-status(1)), through Git.parseStatus and on to the
/// explorer's mark for it: the index letter, the work-tree letter, both at once (AD, AM, MD, RM), type changes,
/// copies with their original path, every conflict pair, ignored paths, and names that would break a
/// line-based parser (spaces, quotes, "->", unicode, a tab) under -z.
import XCTest
@testable import Feather

final class GitStatusCasesTests: XCTestCase {
    private func parse(_ entries: String) -> GitStatus { Git.parseStatus(entries) }

    /// The mark the explorer would show for the one file in `entries`.
    private func mark(_ entries: String) -> GitDecorations.Kind? {
        let status = parse(entries)
        return (status.staged + status.unstaged).map(GitDecorations.kindForTests(of:)).max()
    }

    func testIndexOnlyRows() {
        XCTAssertEqual(parse("M  a\0").staged.map(\.status), ["M"])
        XCTAssertEqual(parse("A  a\0").staged.map(\.status), ["A"])
        XCTAssertEqual(parse("D  a\0").staged.map(\.status), ["D"])
        XCTAssertEqual(parse("R  b\0a\0").staged.map(\.originalPath), ["a"])
        XCTAssertEqual(parse("C  b\0a\0").staged.map(\.originalPath), ["a"])
        XCTAssertEqual(parse("T  a\0").staged.map(\.status), ["T"])
        for entries in ["M  a\0", "A  a\0", "D  a\0", "R  b\0a\0", "C  b\0a\0", "T  a\0"] {
            XCTAssertTrue(parse(entries).unstaged.isEmpty, entries)
        }
        XCTAssertEqual(mark("M  a\0"), .modified)
        XCTAssertEqual(mark("A  a\0"), .added)
        XCTAssertEqual(mark("D  a\0"), .deleted)
        XCTAssertEqual(mark("R  b\0a\0"), .renamed)
        XCTAssertEqual(mark("C  b\0a\0"), .modified, "a copy is a change to the new file")
        XCTAssertEqual(mark("T  a\0"), .modified, "a type change (file to symlink) is a modification")
    }

    func testWorkTreeOnlyRows() {
        XCTAssertEqual(parse(" M a\0").unstaged.map(\.status), ["M"])
        XCTAssertEqual(parse(" D a\0").unstaged.map(\.status), ["D"])
        XCTAssertEqual(parse(" T a\0").unstaged.map(\.status), ["T"])
        XCTAssertEqual(parse(" R b\0a\0").unstaged.map(\.status), ["R"], "a rename in the work tree (status.renames with -z) is still one row")
        for entries in [" M a\0", " D a\0", " T a\0"] { XCTAssertTrue(parse(entries).staged.isEmpty, entries) }
        XCTAssertEqual(mark(" M a\0"), .modified)
        XCTAssertEqual(mark(" D a\0"), .deleted)
        XCTAssertEqual(mark(" T a\0"), .modified)
    }

    func testIndexAndWorkTreeTogetherShowTheLouderOfTheTwo() {
        // Added then deleted again: the file is as good as gone.
        XCTAssertEqual(parse("AD a\0").staged.map(\.status), ["A"])
        XCTAssertEqual(parse("AD a\0").unstaged.map(\.status), ["D"])
        XCTAssertEqual(mark("AD a\0"), .deleted)
        // Added then edited: still new to git, but what shows is that it keeps changing.
        XCTAssertEqual(mark("AM a\0"), .modified)
        // Staged edit, then deleted from disk.
        XCTAssertEqual(mark("MD a\0"), .deleted)
        XCTAssertEqual(mark("MM a\0"), .modified)
        // Renamed then edited: the edit outranks the rename; the original path still travels with the staged half.
        let renamed = parse("RM b\0a\0")
        XCTAssertEqual(renamed.staged.first?.originalPath, "a")
        XCTAssertEqual(renamed.unstaged.map(\.path), ["b"])
        XCTAssertEqual(mark("RM b\0a\0"), .modified)
        XCTAssertEqual(mark("RD b\0a\0"), .deleted)
        XCTAssertEqual(mark("CM b\0a\0"), .modified)
        XCTAssertEqual(mark("TM a\0"), .modified)
    }

    func testEveryConflictPairIsOneConflict() {
        for pair in ["DD", "AU", "UD", "UA", "DU", "AA", "UU"] {
            let status = parse("\(pair) a\0")
            XCTAssertTrue(status.staged.isEmpty, pair)
            XCTAssertEqual(status.unstaged.map(\.status), ["!"], pair)
            XCTAssertEqual(status.conflicts.count, 1, pair)
            XCTAssertEqual(mark("\(pair) a\0"), .conflict, pair)
        }
    }

    func testUntrackedAndIgnoredRows() {
        XCTAssertEqual(parse("?? a\0").unstaged.map(\.status), ["U"])
        XCTAssertEqual(mark("?? a\0"), .untracked)
        XCTAssertEqual(parse("?? new folder/\0").unstaged.map(\.path), ["new folder/"], "an untracked folder keeps its slash for the caller to strip")
        // --ignored rows are not changes; Feather never asks for them, and if it ever did they must not show as conflicts.
        let ignored = parse("!! build/\0!! app.log\0 M a\0")
        XCTAssertEqual(ignored.staged.count + ignored.unstaged.count, 1)
        XCTAssertEqual(ignored.conflicts.count, 0)
    }

    func testNamesThatBreakLineParsersSurviveNULSeparation() {
        let names = ["with space.txt", "\"quoted\" name.txt", "old -> new.txt", "Ünïcode/ß.txt", "tab\tname.txt", "trailing space .txt", "émoji 🚀.md"]
        let entries = names.map { " M \($0)\0" }.joined()
        XCTAssertEqual(parse(entries).unstaged.map(\.path), names)
        let renamed = parse("R  to -> here.txt\0from -> there.txt\0")
        XCTAssertEqual(renamed.staged.first?.path, "to -> here.txt")
        XCTAssertEqual(renamed.staged.first?.originalPath, "from -> there.txt")
    }

    func testQuotedPathsFromLineOutputAreUnquoted() {
        XCTAssertEqual(Git.unquotePath("plain.txt"), "plain.txt")
        XCTAssertEqual(Git.unquotePath("\"\\303\\234n\\303\\257code build\""), "Ünïcode build")
        XCTAssertEqual(Git.unquotePath("\"\\\"quoted\\\" name.txt\""), "\"quoted\" name.txt")
        XCTAssertEqual(Git.unquotePath("\"back\\\\slash\""), "back\\slash")
        XCTAssertEqual(Git.unquotePath("\"tab\\tname\""), "tab\tname")
        XCTAssertEqual(Git.unquotePath("\"\\360\\237\\232\\200.md\""), "🚀.md")
        XCTAssertEqual(Git.unquotePath("\"\""), "")
        XCTAssertEqual(Git.unquotePath("\""), "\"", "a lone quote is not a quoted name")
        XCTAssertEqual(Git.unquotePath("\"ends with backslash\\\""), "ends with backslash\\", "an escape with nothing after it keeps the backslash")
    }

    func testAMixedListKeepsOrderAndTheBranchLine() {
        let status = parse("## main...origin/main [ahead 2]\0M  a\0 M b\0?? c\0UU d\0R  e\0old\0")
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.staged.map(\.path), ["a", "e"])
        XCTAssertEqual(status.unstaged.map(\.path), ["b", "c", "d"])
    }

    func testRowsTooShortToBeEntriesAreSkipped() {
        let status = parse("M\0 M\0M  \0 M a\0")
        XCTAssertEqual(status.unstaged.map(\.path), ["a"])
        XCTAssertTrue(status.staged.isEmpty)
    }
}
