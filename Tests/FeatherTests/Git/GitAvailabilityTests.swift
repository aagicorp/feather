import XCTest
@testable import Feather

/// Git/Git.swift, finding git: `/usr/bin/git` is never used, since on a Mac without the developer tools it is a
/// stub that shows Apple's install dialog and blocks; the developer-tools copies come first, then the shell's
/// PATH. With no git at all every call answers at once with `notInstalledMessage` instead of hanging.
final class GitAvailabilityTests: XCTestCase {
    private var scratch: URL!
    private var savedExecutable: URL?
    private var savedDeveloperPaths: [String] = []
    private var savedAsksXcodeSelect = true

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("feather-git-availability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        savedExecutable = Git.executable
        savedDeveloperPaths = Git.developerPaths
        savedAsksXcodeSelect = Git.asksXcodeSelect
        Git.asksXcodeSelect = false
    }

    override func tearDownWithError() throws {
        Git.executable = savedExecutable
        Git.developerPaths = savedDeveloperPaths
        Git.asksXcodeSelect = savedAsksXcodeSelect
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A file that passes `isExecutableFile`, standing in for a git binary.
    private func fakeGit(in directory: String) throws -> String {
        let folder = scratch.appendingPathComponent(directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("git").path
        try "#!/bin/sh\nexit 0\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func testDeveloperToolsGitComesFirst() throws {
        let tools = try fakeGit(in: "CommandLineTools/usr/bin")
        let brew = try fakeGit(in: "homebrew/bin")
        Git.developerPaths = [scratch.appendingPathComponent("missing/git").path, tools]
        XCTAssertEqual(Git.locate(pathDirectories: [(brew as NSString).deletingLastPathComponent])?.path, tools)
    }

    func testAGitOnTheShellPathIsFoundWhenNoDeveloperToolsAreInstalled() throws {
        let brew = try fakeGit(in: "homebrew/bin")
        Git.developerPaths = []
        let directories = ["/nonexistent/bin", (brew as NSString).deletingLastPathComponent]
        XCTAssertEqual(Git.locate(pathDirectories: directories)?.path, brew)
    }

    func testTheSystemStubIsNeverUsed() throws {
        Git.developerPaths = []
        XCTAssertNil(Git.locate(pathDirectories: ["/usr/bin"]),
                     "/usr/bin/git may be Apple's stub that blocks on an install dialog, so it must not be a candidate")
        XCTAssertNil(Git.locate(pathDirectories: []))
    }

    func testWithoutGitEveryCallAnswersAtOnceWithTheInstallMessage() throws {
        Git.executable = nil
        XCTAssertFalse(Git.isAvailable)
        let result = Git.runSyncData(["status"], in: scratch)
        XCTAssertEqual(result.status, -1)
        XCTAssertEqual(result.error, Git.notInstalledMessage)
        XCTAssertTrue(result.output.isEmpty)
        XCTAssertTrue(Git.notInstalledMessage.contains("xcode-select --install"), "the message must say how to fix it")
    }

    func testRecheckAnnouncesOnlyAChange() throws {
        Git.developerPaths = []
        Git.executable = nil
        var announcements = 0
        let token = NotificationCenter.default.addObserver(forName: Git.availabilityDidChange, object: nil, queue: nil) { _ in announcements += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        Git.recheck()                                    // still nothing to find (PATH lookup is exercised above)
        let before = announcements
        let tools = try fakeGit(in: "CommandLineTools/usr/bin")
        Git.developerPaths = [tools]
        Git.recheck()                                    // the tools were "installed" while Feather ran
        XCTAssertEqual(Git.executable?.path, tools)
        XCTAssertEqual(announcements, before + 1)
        Git.recheck()
        XCTAssertEqual(announcements, before + 1, "no change, no announcement")
    }
}
