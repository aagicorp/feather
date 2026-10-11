/// Covers App/ReleaseNotes.swift: the "show What's New once after an update" bookkeeping. A first install sees
/// nothing (the welcome page greets it), the launch after an update sees the notes once, and later launches of
/// the same version do not.
import XCTest
@testable import Feather

final class ReleaseNotesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "feather-tests-notes-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAFirstInstallIsNotShownTheNotes() {
        XCTAssertFalse(ReleaseNotes.notesAreDue(defaults: defaults, version: "1.0.0"))
        XCTAssertEqual(defaults.string(forKey: "releaseNotesSeenVersion"), "1.0.0", "but the version is remembered")
        XCTAssertFalse(ReleaseNotes.notesAreDue(defaults: defaults, version: "1.0.0"))
    }

    func testTheLaunchAfterAnUpdateSeesThemOnce() {
        XCTAssertFalse(ReleaseNotes.notesAreDue(defaults: defaults, version: "1.0.0"))
        XCTAssertTrue(ReleaseNotes.notesAreDue(defaults: defaults, version: "1.1.0"))
        XCTAssertFalse(ReleaseNotes.notesAreDue(defaults: defaults, version: "1.1.0"))
        XCTAssertFalse(ReleaseNotes.notesAreDue(defaults: defaults, version: "1.1.0"))
        XCTAssertEqual(defaults.string(forKey: "releaseNotesSeenVersion"), "1.1.0")
    }

    func testAnyChangeOfVersionCounts() {
        // A downgrade, or a development build after a release, is "different from what was seen" too.
        XCTAssertFalse(ReleaseNotes.notesAreDue(defaults: defaults, version: "2.0.0"))
        XCTAssertTrue(ReleaseNotes.notesAreDue(defaults: defaults, version: "1.9.0"))
        XCTAssertTrue(ReleaseNotes.notesAreDue(defaults: defaults, version: "development build"))
    }

    func testVersionIsNeverEmpty() {
        XCTAssertFalse(ReleaseNotes.version.isEmpty)
    }
}

final class ReleaseNotesPageTests: XCTestCase {
    func testThePageStartsWithTheVersionAndTheUpdateLink() {
        let page = ReleaseNotes.page(from: "# What's New in Feather\n\n## 0.14.3\n\n- A fix.\n", version: "0.14.3")
        XCTAssertTrue(page.hasPrefix("# What's New in Feather\n\n> **You have Feather 0.14.3.** [Check for Updates](feather://check-updates)"), page)
        XCTAssertTrue(page.contains("\n## 0.14.3\n"))
        XCTAssertEqual(page.components(separatedBy: "## 0.14.3").count, 2)
        let plain = ReleaseNotes.page(from: "no title here\n", version: "1.0")
        XCTAssertTrue(plain.hasPrefix("> **You have Feather 1.0.**"), "without a title the line simply comes first")
    }

    func testARequiredHeadingStillYieldsNotes() throws {
        let folder = TestSupport.temporaryDirectory("feather-notes")
        defer { try? FileManager.default.removeItem(at: folder) }
        let changelog = folder.appendingPathComponent("CHANGELOG.md")
        try "# What's New\n\n## 0.14.5 (required)\n\n- Fixes a crash on launch.\n\n## 0.14.4\n\n- Older.\n".write(to: changelog, atomically: true, encoding: .utf8)
        let out = folder.appendingPathComponent("notes.html")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["tools/release_notes.py", "0.14.5", changelog.path, out.path]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let html = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(html.contains("<h2>Feather 0.14.5</h2>"), "the marker is not in the notes")
        XCTAssertTrue(html.contains("Fixes a crash on launch"))
        XCTAssertFalse(html.contains("Older"))
    }
}
