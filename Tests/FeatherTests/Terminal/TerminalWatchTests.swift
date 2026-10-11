import XCTest
@testable import Feather

final class TerminalActivityTests: XCTestCase {
    func testOneEchoedKeystrokeIsNotBusy() {
        var activity = TerminalActivity()
        XCTAssertTrue(activity.noteOutput(1, at: 100))
        XCTAssertFalse(activity.noteOutput(1, at: 100.1))
        XCTAssertFalse(activity.wasBusy)
    }

    func testSteadyOutputForSeveralSecondsIsBusy() {
        var activity = TerminalActivity()
        for tenth in 0..<40 { _ = activity.noteOutput(50, at: 100 + Double(tenth) / 10) }
        XCTAssertTrue(activity.wasBusy)
    }

    func testOneLineEveryTenSecondsIsNotBusy() {
        var activity = TerminalActivity()
        for step in 0..<6 { _ = activity.noteOutput(50, at: 100 + Double(step) * 10) }
        XCTAssertFalse(activity.wasBusy)      // six seconds of output spread over a minute
    }

    func testTypingResetsTheBurst() {
        var activity = TerminalActivity()
        for tenth in 0..<40 { _ = activity.noteOutput(50, at: 100 + Double(tenth) / 10) }
        activity.noteInput(at: 104)
        XCTAssertFalse(activity.wasBusy)
    }
}

final class TerminalPromptTests: XCTestCase {
    func testQuestions() {
        XCTAssertTrue(TerminalPrompt.isQuestion("Do you want to proceed? (y/n)"))
        XCTAssertTrue(TerminalPrompt.isQuestion("Overwrite the file?"))
        XCTAssertFalse(TerminalPrompt.isQuestion("Done in 3.2s"))
        XCTAssertFalse(TerminalPrompt.isQuestion(""))
    }

    func testMenuRows() {
        XCTAssertTrue(TerminalPrompt.isMenuRow("❯ 1. Yes"))
        XCTAssertTrue(TerminalPrompt.isMenuRow("│ ● Yes, allow once"))
        XCTAssertFalse(TerminalPrompt.isMenuRow("> git status"))
        XCTAssertFalse(TerminalPrompt.isMenuRow("plain text"))
    }
}

final class LocalURLDetectorTests: XCTestCase {
    func testAddressesInOneLine() {
        let urls = LocalURLDetector.addresses(in: "  ➜  Local:   \u{1B}[36mhttp://localhost:5173/\u{1B}[0m")
        XCTAssertEqual(urls.map(\.absoluteString), ["http://localhost:5173/"])
    }

    func testEveryInterfaceMeansLocalhost() {
        XCTAssertEqual(LocalURLDetector.addresses(in: "Listening on http://0.0.0.0:8080").map(\.absoluteString), ["http://localhost:8080"])
    }

    func testSpringBootNamesOnlyThePort() {
        XCTAssertEqual(LocalURLDetector.addresses(in: "Tomcat started on port(s): 8081 (http) with context path '/api'").map(\.absoluteString),
                       ["http://localhost:8081/api"])
    }

    func testEachAddressReportedOncePerDetector() {
        var detector = LocalURLDetector()
        let line = Array("Local: http://localhost:3000/\n".utf8)
        XCTAssertEqual(detector.scan(line[...], at: 1).count, 1)
        XCTAssertEqual(detector.scan(line[...], at: 2).count, 0)
    }
}

final class ShellMarkScannerTests: XCTestCase {
    func testStartAndEndMarks() {
        var scanner = ShellMarkScanner()
        let bytes = Array("\u{1B}]133;C\u{07}hello\n\u{1B}]133;D;2\u{07}prompt> ".utf8)
        XCTAssertEqual(scanner.scan(bytes[...]), [.commandStarted, .commandFinished(exitCode: 2)])
    }

    func testMarkSplitAcrossChunks() {
        var scanner = ShellMarkScanner()
        let whole = Array("output\u{1B}]133;D;0\u{1B}\\more".utf8)
        let cut = 9                                     // inside "\u{1B}]133;"
        XCTAssertEqual(scanner.scan(whole[..<cut]), [])
        XCTAssertEqual(scanner.scan(whole[cut...]), [.commandFinished(exitCode: 0)])
    }

    func testOtherEscapesAreIgnored() {
        var scanner = ShellMarkScanner()
        XCTAssertEqual(scanner.scan(Array("\u{1B}[31mred\u{1B}[0m \u{1B}]0;title\u{07}".utf8)[...]), [])
    }

    func testUnknownMarkKinds() {
        XCTAssertNil(ShellMarkScanner.parse("A"))
        XCTAssertEqual(ShellMarkScanner.parse("D"), .commandFinished(exitCode: nil))
    }
}

final class ShellIntegrationTests: XCTestCase {
    func testZshGetsTheShimAndKeepsTheUsersZDOTDIR() {
        ShellIntegration.directory = FileManager.default.temporaryDirectory.appendingPathComponent("feather-shell-\(UUID().uuidString)")
        let result = ShellIntegration.environment(forShell: "/bin/zsh", from: ["PATH=/usr/bin", "ZDOTDIR=/Users/me/dots"])
        XCTAssertTrue(result.contains("FEATHER_USER_ZDOTDIR=/Users/me/dots"))
        XCTAssertTrue(result.contains { $0.hasPrefix("ZDOTDIR=") && $0.hasSuffix("/zsh") })
        XCTAssertTrue(result.contains("CLICOLOR=1"))
        let shim = URL(fileURLWithPath: String(result.first { $0.hasPrefix("ZDOTDIR=") }!.dropFirst("ZDOTDIR=".count)))
        for name in [".zshenv", ".zprofile", ".zshrc"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: shim.appendingPathComponent(name).path), name)
        }
        let zshrc = try? String(contentsOf: shim.appendingPathComponent(".zshrc"), encoding: .utf8)
        XCTAssertTrue(zshrc?.contains("add-zsh-hook precmd __feather_precmd") == true)
        try? FileManager.default.removeItem(at: ShellIntegration.directory)
    }

    func testBashGetsPromptCommandAndFishNothing() {
        XCTAssertTrue(ShellIntegration.environment(forShell: "/bin/bash", from: []).contains { $0.hasPrefix("PROMPT_COMMAND=") })
        XCTAssertEqual(ShellIntegration.environment(forShell: "/opt/homebrew/bin/fish", from: ["A=1"]), ["A=1", "CLICOLOR=1"])
    }

    func testShellQuoting() {
        XCTAssertEqual(DropTerminalView.shellQuoted("/tmp/it's here"), "'/tmp/it'\\''s here'")
    }
}

/// The detector sees output in arbitrary chunks and must not be fooled by a line cut in two, nor spend time on
/// a flood of output.
final class LocalURLDetectorChunkTests: XCTestCase {
    private func bytes(_ text: String) -> ArraySlice<UInt8> { Array(text.utf8)[...] }

    func testALineCutBetweenChunksIsJoined() {
        var detector = LocalURLDetector()
        XCTAssertEqual(detector.scan(bytes("  Local: http://local"), at: 1), [])
        XCTAssertEqual(detector.scan(bytes("host:5173/\n"), at: 1.01).map(\.absoluteString), ["http://localhost:5173/"])
    }

    func testAnUnfinishedLineWaitsForItsNewline() {
        var detector = LocalURLDetector()
        XCTAssertEqual(detector.scan(bytes("Local: http://localhost:3000"), at: 1), [])
        XCTAssertEqual(detector.scan(bytes("\n"), at: 1.01).map(\.absoluteString), ["http://localhost:3000"])
        // Once reported, the same address in another chunk is not news.
        XCTAssertEqual(detector.scan(bytes("Local: http://localhost:3000/\n"), at: 1.02), [])
    }

    func testTwoAddressesInOneChunkAndTrailingPunctuation() {
        var detector = LocalURLDetector()
        let found = detector.scan(bytes("API at http://127.0.0.1:8080/api). UI at https://localhost:4433/app,\n"), at: 1)
        XCTAssertEqual(found.map(\.absoluteString), ["http://127.0.0.1:8080/api", "https://localhost:4433/app"])
    }

    func testAFloodIsNotSearched() {
        var detector = LocalURLDetector()
        let line = bytes("Local: http://localhost:3000/\n")
        let filler = Array(repeating: UInt8(ascii: "x"), count: 40 * 1024)[...]
        XCTAssertEqual(detector.scan(filler, at: 10), [])
        // Over the budget in this tenth of a second, so even a real announcement is skipped...
        XCTAssertEqual(detector.scan(line, at: 10.05), [])
        // ...and found again once the flood has passed.
        XCTAssertEqual(detector.scan(line, at: 10.5).map(\.absoluteString), ["http://localhost:3000/"])
    }

    func testAtMostFortyLinesASecondAreDecoded() {
        var detector = LocalURLDetector()
        var found = 0
        for port in 0..<60 { found += detector.scan(bytes("http://localhost:\(1000 + port)/\n"), at: 20).count }
        XCTAssertEqual(found, 40)
        // The next second starts afresh.
        XCTAssertEqual(detector.scan(bytes("http://localhost:9999/\n"), at: 21.5).count, 1)
    }

    func testEmptyChunkAndNonASCIIOutput() {
        var detector = LocalURLDetector()
        XCTAssertEqual(detector.scan([][...], at: 1), [])
        XCTAssertEqual(detector.scan(bytes("➜  Lokal: http://localhost:5173/ — bereit\n"), at: 1).map(\.absoluteString), ["http://localhost:5173/"])
    }
}

/// The badge, the notes and the way back to a terminal, with the macOS notification centre and the sound out
/// of the way.
final class TerminalAttentionTests: XCTestCase {
    private var attention: TerminalAttention!
    private var posted: [TerminalAttention.Note] = []
    private var soundWasOn = true

    override func setUp() {
        _ = NSApplication.shared                 // the Dock tile needs an application object; nothing is shown
        soundWasOn = Settings.shared.terminalSound
        Settings.shared.terminalSound = false
        attention = TerminalAttention()
        attention.hasNotificationCenter = false
        attention.isAppActive = { false }
        attention.poster = { [weak self] in self?.posted.append($0) }
    }

    override func tearDown() {
        for token in ["a", "b", "c"] { attention.lower(token: token) }
        Settings.shared.terminalSound = soundWasOn
    }

    private func note(_ token: String) -> TerminalAttention.Note { .init(token: token, title: "Terminal \(token)", body: "wants you") }

    func testRaiseCountsBadgesAndPosts() {
        var clicked: [String] = []
        attention.raise(note("a"), in: nil) { clicked.append("a") }
        XCTAssertEqual(attention.waitingCount, 1)
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "1")
        XCTAssertEqual(posted.map(\.token), ["a"])
        attention.raise(note("b"), in: nil) { clicked.append("b") }
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "2")
        // Raising the same terminal again replaces its note rather than counting it twice.
        attention.raise(note("a"), in: nil) { clicked.append("a2") }
        XCTAssertEqual(attention.waitingCount, 2)
        XCTAssertEqual(posted.count, 3)
        attention.clicked(token: "a")
        XCTAssertEqual(clicked, ["a2"])
    }

    func testLowerRemovesTheBadgeWhenNobodyIsWaiting() {
        attention.raise(note("a"), in: nil) {}
        attention.raise(note("b"), in: nil) {}
        attention.lower(token: "a")
        XCTAssertEqual(attention.waitingCount, 1)
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "1")
        attention.lower(token: "a")                    // already lowered: nothing changes
        attention.lower(token: "never-raised")
        XCTAssertEqual(attention.waitingCount, 1)
        attention.lower(token: "b")
        XCTAssertEqual(attention.waitingCount, 0)
        XCTAssertNil(NSApp.dockTile.badgeLabel)
        attention.clicked(token: "a")                  // a click on a stale notification does nothing
    }

    func testMentionNeitherPostsNorBadges() {
        attention.isAppActive = { true }
        attention.mention(note("c"), in: nil) {}
        XCTAssertEqual(posted.count, 0)
        XCTAssertEqual(attention.waitingCount, 0)
        XCTAssertNil(NSApp.dockTile.badgeLabel)
    }
}

/// What the zsh shim files promise: the user's own start-up files are read, ZDOTDIR is put back, and the marks
/// are printed by hooks that do not replace the user's own.
final class ShellIntegrationFileTests: XCTestCase {
    func testZshenvHandsOverToTheUsersFilesAndBack() {
        let zshenv = ShellIntegration.zshFiles[".zshenv"] ?? ""
        XCTAssertTrue(zshenv.contains(#"ZDOTDIR="${FEATHER_USER_ZDOTDIR:-$HOME}""#))
        XCTAssertTrue(zshenv.contains(#"builtin source "$ZDOTDIR/.zshenv""#))
        XCTAssertTrue(zshenv.contains(#"ZDOTDIR="$FEATHER_ZDOTDIR_SHIM""#), "the shim is ZDOTDIR again for .zprofile and .zshrc")
        XCTAssertTrue(zshenv.hasSuffix("\n"))
        let zprofile = ShellIntegration.zshFiles[".zprofile"] ?? ""
        XCTAssertTrue(zprofile.contains(#"builtin source "$FEATHER_USER_ZDOTDIR/.zprofile""#))
    }

    func testZshrcRestoresZDOTDIRAndAddsHooksWithoutReplacingTheUsers() {
        let zshrc = ShellIntegration.zshFiles[".zshrc"] ?? ""
        XCTAssertTrue(zshrc.contains(#"builtin source "$FEATHER_USER_ZDOTDIR/.zshrc""#))
        XCTAssertTrue(zshrc.contains(#"if [[ "$FEATHER_USER_ZDOTDIR" == "$HOME" ]]; then unset ZDOTDIR; else ZDOTDIR="$FEATHER_USER_ZDOTDIR"; fi"#))
        XCTAssertTrue(zshrc.contains("unset FEATHER_USER_ZDOTDIR FEATHER_ZDOTDIR_SHIM"))
        XCTAssertTrue(zshrc.contains(#"printf '\e]133;C\a'"#))
        XCTAssertTrue(zshrc.contains(#"printf '\e]133;D;%s\a' "$code""#))
        XCTAssertTrue(zshrc.contains("add-zsh-hook preexec __feather_preexec"))
        XCTAssertTrue(zshrc.contains("add-zsh-hook precmd __feather_precmd"))
        XCTAssertFalse(zshrc.components(separatedBy: "\n").contains { $0.hasPrefix("precmd") || $0.hasPrefix("preexec") },
                       "add-zsh-hook, never a precmd of our own that would replace the user's")
        // Every file is a sequence of complete lines; nothing must be sourced by the user's own shell.
        for (name, text) in ShellIntegration.zshFiles { XCTAssertTrue(text.hasSuffix("\n"), name) }
        XCTAssertEqual(Set(ShellIntegration.zshFiles.keys), [".zshenv", ".zprofile", ".zshrc"])
    }

    func testInstallWritesExactlyTheFilesAndRewritesOnlyWhatChanged() throws {
        let saved = ShellIntegration.directory
        ShellIntegration.directory = TestSupport.temporaryDirectory("feather-shell")
        defer { try? FileManager.default.removeItem(at: ShellIntegration.directory); ShellIntegration.directory = saved }
        let folder = try XCTUnwrap(ShellIntegration.installZsh())
        for (name, text) in ShellIntegration.zshFiles {
            XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8), text, name)
        }
        let zshrc = folder.appendingPathComponent(".zshrc")
        let before = try FileManager.default.attributesOfItem(atPath: zshrc.path)[.modificationDate] as? Date
        try "# tampered\n".write(to: folder.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ShellIntegration.installZsh(), folder)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(".zprofile"), encoding: .utf8), ShellIntegration.zshFiles[".zprofile"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: zshrc.path)[.modificationDate] as? Date, before, "an unchanged file is left alone")
    }

    func testEnvironmentLeavesExistingCLICOLORAndReplacesBashPromptCommand() {
        let zsh = ShellIntegration.environment(forShell: "/bin/zsh", from: ["CLICOLOR=0"])
        XCTAssertEqual(zsh.filter { $0.hasPrefix("CLICOLOR=") }, ["CLICOLOR=0"])
        let bash = ShellIntegration.environment(forShell: "/opt/homebrew/bin/bash", from: ["PROMPT_COMMAND=history -a", "X=1"])
        XCTAssertEqual(bash.filter { $0.hasPrefix("PROMPT_COMMAND=") }.count, 1)
        XCTAssertTrue(bash.contains("X=1"))
        XCTAssertFalse(bash.contains("PROMPT_COMMAND=history -a"))
    }
}
