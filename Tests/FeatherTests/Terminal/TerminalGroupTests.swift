import XCTest
@testable import Feather

final class TerminalGroupsTests: XCTestCase {
    func testMembersAreTheAdjacentRunWithTheSameTag() {
        let tags = [0, 3, 3, 0, 5, 5, 5]
        XCTAssertEqual(TerminalGroups.members(of: 0, tags: tags), 0..<1)
        XCTAssertEqual(TerminalGroups.members(of: 2, tags: tags), 1..<3)
        XCTAssertEqual(TerminalGroups.members(of: 5, tags: tags), 4..<7)
        XCTAssertEqual(TerminalGroups.members(of: 9, tags: tags), 9..<9)
    }

    func testGroupsOfOneAreNormalisedAway() {
        XCTAssertEqual(TerminalGroups.normalised([0, 3, 0, 5, 5]), [0, 0, 0, 5, 5])
    }

    func testEncodingNumbersGroupsInOrderOfAppearance() {
        XCTAssertEqual(TerminalGroups.groupIndices(forTags: [0, 7, 7, 0, 2, 2, 2, 9]), [nil, 0, 0, nil, 1, 1, 1, nil])
    }

    func testRoundTripThroughTheSessionFile() {
        let tags = [4, 4, 0, 9, 9, 9, 0]
        let stored = TerminalGroups.groupIndices(forTags: tags)
        let restored = TerminalGroups.tags(forGroupIndices: stored)
        XCTAssertEqual(TerminalGroups.groupIndices(forTags: restored), stored)
        XCTAssertEqual(TerminalGroups.members(of: 0, tags: restored), 0..<2)
        XCTAssertEqual(TerminalGroups.members(of: 4, tags: restored), 3..<6)
        XCTAssertEqual(restored[2], 0)
        XCTAssertEqual(restored[6], 0)
    }

    func testRestoringADamagedFileKeepsOnlyAdjacentMembersAndTheCap() {
        // The same number far apart is two lone terminals; a run beyond the cap is cut at the cap.
        XCTAssertEqual(TerminalGroups.tags(forGroupIndices: [0, nil, 0]), [0, 0, 0])
        let big = TerminalGroups.tags(forGroupIndices: [1, 1, 1, 1, 1, 1])
        XCTAssertEqual(TerminalGroups.members(of: 0, tags: big).count, TerminalGroups.maxMembers)
        XCTAssertEqual(TerminalGroups.members(of: 4, tags: big).count, 2)
    }

    func testReorderMovesAWholeGroupAndNeverLandsInsideOne() {
        let tags = [0, 2, 2, 0]
        XCTAssertEqual(TerminalGroups.reorder(tags: tags, from: 1, to: 0), [1, 2, 0, 3])        // the group to the top
        XCTAssertEqual(TerminalGroups.reorder(tags: tags, from: 3, to: 2), [0, 3, 1, 2])        // a drop in the middle lands before the group
        XCTAssertEqual(TerminalGroups.reorder(tags: tags, from: 0, to: 4), [1, 2, 3, 0])        // to the end
        XCTAssertNil(TerminalGroups.reorder(tags: tags, from: 3, to: 3))                        // onto itself
        XCTAssertNil(TerminalGroups.reorder(tags: tags, from: 1, to: 3))                        // right after itself
        XCTAssertNil(TerminalGroups.reorder(tags: tags, from: 7, to: 0))
    }
}

final class TerminalCommandTextTests: XCTestCase {
    func testStripsCommonPrompts() {
        XCTAssertEqual(TerminalCommandText.command(fromPromptLine: "me@mac feather % npm run build"), "npm run build")
        XCTAssertEqual(TerminalCommandText.command(fromPromptLine: "❯ swift test --filter Foo"), "swift test --filter Foo")
        XCTAssertEqual(TerminalCommandText.command(fromPromptLine: "bash-5.2$ ls -la"), "ls -la")
        XCTAssertEqual(TerminalCommandText.command(fromPromptLine: "me@mac ~/p> make"), "make")
    }

    func testACommandMayContainAMarkerOfItsOwn() {
        XCTAssertEqual(TerminalCommandText.command(fromPromptLine: "❯ echo a > b"), "echo a > b")
        XCTAssertEqual(TerminalCommandText.command(fromPromptLine: "me % printf '%s\\n' x"), "printf '%s\\n' x")
    }

    func testRightPromptAndEmptyLinesAreDropped() {
        XCTAssertEqual(TerminalCommandText.command(fromPromptLine: "❯ git status                     main ✓ 10:42"), "git status")
        XCTAssertNil(TerminalCommandText.command(fromPromptLine: "❯ "))
        XCTAssertNil(TerminalCommandText.command(fromPromptLine: "   "))
        XCTAssertNil(TerminalCommandText.command(fromPromptLine: "no prompt here"))
    }

    func testShortening() {
        let long = String(repeating: "x", count: 80)
        XCTAssertEqual(TerminalCommandText.shortened(long).count, TerminalCommandText.maxLength)
        XCTAssertTrue(TerminalCommandText.shortened(long).hasSuffix("…"))
        XCTAssertEqual(TerminalCommandText.shortened("ls"), "ls")
    }
}

final class TerminalStatusTextTests: XCTestCase {
    func testRunningCommand() {
        var input = TerminalStatusInput()
        input.command = "npm run build"
        input.commandSeconds = 12.7
        XCTAssertEqual(TerminalStatusText.describe(input)?.text, "▶ npm run build · 12 s")
        XCTAssertTrue(TerminalStatusText.isLive(input))
    }

    func testEndings() {
        var input = TerminalStatusInput()
        input.ending = .init(exitCode: 0, seconds: 14, age: 3)
        XCTAssertEqual(TerminalStatusText.describe(input)?.text, "✓ finished in 14 s")
        XCTAssertEqual(TerminalStatusText.describe(input)?.tone, .good)
        input.ending = .init(exitCode: 1, seconds: 14, age: 3)
        XCTAssertEqual(TerminalStatusText.describe(input)?.text, "✕ exit 1 · 14 s")
        XCTAssertEqual(TerminalStatusText.describe(input)?.tone, .bad)
        input.ending = .init(exitCode: nil, seconds: 90, age: 3)
        XCTAssertEqual(TerminalStatusText.describe(input)?.text, "finished in 1 m 30 s")
        // Gone after a while, and never for a quick success (an empty Return, `ls`).
        input.ending = .init(exitCode: 0, seconds: 14, age: TerminalStatusText.endingLingers + 1)
        XCTAssertNil(TerminalStatusText.describe(input))
        XCTAssertFalse(TerminalStatusText.isLive(input))
        input.ending = .init(exitCode: 0, seconds: 0.02, age: 1)
        XCTAssertNil(TerminalStatusText.describe(input))
        input.ending = .init(exitCode: 2, seconds: 0.02, age: 1)
        XCTAssertEqual(TerminalStatusText.describe(input)?.text, "✕ exit 2 · 0 s")
    }

    func testAssistantStates() {
        var input = TerminalStatusInput()
        input.assistantName = "Claude Code"
        XCTAssertNil(TerminalStatusText.describe(input))
        input.isBusy = true
        input.secondsWithOutput = 1
        input.busySeconds = 125
        XCTAssertNil(TerminalStatusText.describe(input))                  // one echoed keystroke is not work
        XCTAssertTrue(TerminalStatusText.isLive(input))
        input.secondsWithOutput = 5
        XCTAssertEqual(TerminalStatusText.describe(input)?.text, "Claude Code · working 2 m 5 s")
        input.isWaiting = true
        XCTAssertEqual(TerminalStatusText.describe(input)?.text, "Claude Code · waiting for you")
        XCTAssertFalse(TerminalStatusText.isLive(input))
        input.workedSeconds = 120
        XCTAssertEqual(TerminalStatusText.describe(input)?.text, "Claude Code · stopped after 2 m")
    }

    func testDurations() {
        XCTAssertEqual(TerminalStatusText.duration(0.4), "0 s")
        XCTAssertEqual(TerminalStatusText.duration(59.9), "59 s")
        XCTAssertEqual(TerminalStatusText.duration(60), "1 m")
        XCTAssertEqual(TerminalStatusText.duration(3661), "1 h 01 m")
    }
}

final class ChangedLinesTests: XCTestCase {
    func testNothingChanged() {
        XCTAssertEqual(ChangedLines.ranges(from: "a\nb\n", to: "a\nb\n"), [])
    }

    func testInsertedAndReplacedLines() {
        XCTAssertEqual(ChangedLines.ranges(from: "a\nb\nc\n", to: "a\nb\nX\nY\nc\n"), [2..<4])
        XCTAssertEqual(ChangedLines.ranges(from: "a\nb\nc\n", to: "a\nB\nc\n"), [1..<2])
        XCTAssertEqual(ChangedLines.ranges(from: "a\nb\nc\nd\ne\n", to: "a\nB\nc\nd\nE\n"), [1..<2, 4..<5])
    }

    func testDeletionsAreEmptyRangesWhereTheLinesWere() {
        XCTAssertEqual(ChangedLines.ranges(from: "a\nb\nc\n", to: "a\nc\n"), [1..<1])
        XCTAssertEqual(ChangedLines.ranges(from: "a\nb\nc\nd\ne\n", to: "a\nc\nd\nE\n"), [1..<1, 3..<4])
    }

    func testAWholesaleRewriteIsOneBlock() {
        let old = (0..<3000).map(String.init).joined(separator: "\n")
        let new = (0..<3000).map { String($0 * 7) }.joined(separator: "\n")
        XCTAssertEqual(ChangedLines.ranges(from: old, to: new), [1..<3000])          // line 0 ("0") is the same
    }
}

/// The corners of the group arithmetic the tests above leave out.
final class TerminalGroupsEdgeTests: XCTestCase {
    func testFreshTagIsAboveEveryTagInUse() {
        XCTAssertEqual(TerminalGroups.freshTag([]), 1)
        XCTAssertEqual(TerminalGroups.freshTag([0, 0]), 1)
        XCTAssertEqual(TerminalGroups.freshTag([0, 7, 7, 3]), 8)
    }

    func testNormalisingKeepsRealGroupsAndEmptyLists() {
        XCTAssertEqual(TerminalGroups.normalised([]), [])
        XCTAssertEqual(TerminalGroups.normalised([2, 2, 0, 2]), [2, 2, 0, 0])
        XCTAssertEqual(TerminalGroups.groupIndices(forTags: [0, 0, 0]), [nil, nil, nil])
        XCTAssertEqual(TerminalGroups.tags(forGroupIndices: []), [])
        XCTAssertEqual(TerminalGroups.tags(forGroupIndices: [nil, 0]), [0, 0])
    }

    func testMembersOfAnUngroupedTerminalIsItself() {
        XCTAssertEqual(TerminalGroups.members(of: 1, tags: [0, 0, 0]), 1..<2)
        XCTAssertEqual(TerminalGroups.members(of: -1, tags: [0]), -1 ..< -1)
    }

    func testReorderingLoneTerminalsAndDroppingAfterAGroup() {
        XCTAssertEqual(TerminalGroups.reorder(tags: [0, 0, 0], from: 0, to: 3), [1, 2, 0])
        XCTAssertEqual(TerminalGroups.reorder(tags: [0, 0, 0], from: 2, to: 0), [2, 0, 1])
        XCTAssertNil(TerminalGroups.reorder(tags: [0, 0], from: 0, to: 1))
        // Dropping right after a group's last member lands after the group, not inside it.
        XCTAssertEqual(TerminalGroups.reorder(tags: [0, 4, 4, 0], from: 0, to: 3), [1, 2, 0, 3])
        XCTAssertNil(TerminalGroups.reorder(tags: [0, 4, 4], from: 1, to: 5))
    }
}

final class TerminalStatusTextEdgeTests: XCTestCase {
    func testALongCommandIsShortenedInTheHeader() {
        var input = TerminalStatusInput()
        input.command = String(repeating: "a", count: 100)
        input.commandSeconds = 0
        let text = TerminalStatusText.describe(input)?.text ?? ""
        XCTAssertTrue(text.hasPrefix("▶ " + String(repeating: "a", count: TerminalCommandText.maxLength - 1) + "…"))
        XCTAssertTrue(text.hasSuffix(" · 0 s"))
    }

    func testARunningCommandWinsOverAnOldEnding() {
        var input = TerminalStatusInput()
        input.command = "make"
        input.ending = .init(exitCode: 1, seconds: 5, age: 1)
        XCTAssertEqual(TerminalStatusText.describe(input)?.text, "▶ make · 0 s")
    }

    func testTheEndingGoesExactlyWhenItsTimeIsUp() {
        var input = TerminalStatusInput()
        input.ending = .init(exitCode: 1, seconds: 5, age: TerminalStatusText.endingLingers)
        XCTAssertNil(TerminalStatusText.describe(input))
        XCTAssertFalse(TerminalStatusText.isLive(input))
        input.ending?.age = TerminalStatusText.endingLingers - 0.5
        XCTAssertNotNil(TerminalStatusText.describe(input))
        XCTAssertTrue(TerminalStatusText.isLive(input))
    }

    func testNothingGoingOn() {
        XCTAssertNil(TerminalStatusText.describe(TerminalStatusInput()))
        XCTAssertFalse(TerminalStatusText.isLive(TerminalStatusInput()))
    }

    func testDurationCorners() {
        XCTAssertEqual(TerminalStatusText.duration(-3), "0 s")
        XCTAssertEqual(TerminalStatusText.duration(3600), "1 h 00 m")
        XCTAssertEqual(TerminalStatusText.duration(7199), "1 h 59 m")
        XCTAssertEqual(TerminalStatusText.duration(125), "2 m 5 s")
    }

    func testPromptLinesWithPaddingCells() {
        XCTAssertEqual(TerminalCommandText.command(fromPromptLine: "❯ ls\0\0\0\0"), "ls")
        XCTAssertEqual(TerminalCommandText.command(fromPromptLine: "root# make all"), "make all")
        XCTAssertEqual(TerminalCommandText.command(fromPromptLine: "~ % git commit -m 'a > b'"), "git commit -m 'a > b'")
    }
}
