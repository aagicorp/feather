/// Covers Explorer/ProjectFiles.swift: the cached listing of a project's files — what is skipped (hidden files,
/// dependency and build folders, packages), the limit, the cache and its invalidation, a root spelt /tmp or
/// /private/tmp, and an abandoned walk that must not be cached.
import XCTest
@testable import Feather

final class ProjectFilesTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = TestSupport.temporaryDirectory("feather-files")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func list(_ url: URL? = nil, limit: Int = 40_000) -> Set<String> {
        Set(ProjectFiles.list(root: url ?? root, limit: limit))
    }

    func testListsFilesAndSkipsWhatAProjectSearchShouldNotSee() throws {
        try TestSupport.write([
            "a.txt": "", "src/b.swift": "", "src/deep/c.ts": "",
            "node_modules/x/y.js": "", "build/out.o": "", "Build/out": "", "vendor/lib.rb": "", "target/classes/A.class": "",
            "src/__pycache__/m.pyc": "", "venv/bin/python": "",
            ".hidden/z.txt": "", ".env": "", "src/.secret": "",
            "Thing.app/Contents/Info.plist": "",
            "dist": "a file called dist is still a file",
            "src/héllo wörld.txt": "", "日本語.md": "",
        ], under: root)
        XCTAssertEqual(list(), ["a.txt", "src/b.swift", "src/deep/c.ts", "dist", "src/héllo wörld.txt", "日本語.md"])
    }

    func testEmptyAndMissingRoots() {
        XCTAssertEqual(list(), [])
        XCTAssertEqual(list(root.appendingPathComponent("missing")), [])
    }

    func testTheLimitCutsTheListingAndACutListingIsNotReusedForABiggerAsk() throws {
        try TestSupport.write(Dictionary(uniqueKeysWithValues: (0..<10).map { ("f\($0).txt", "") }), under: root)
        XCTAssertEqual(ProjectFiles.list(root: root, limit: 3).count, 3)
        XCTAssertEqual(ProjectFiles.list(root: root, limit: 2).count, 2, "a smaller ask is served from the cut listing")
        XCTAssertEqual(ProjectFiles.list(root: root).count, 10, "a bigger one walks again")
        XCTAssertEqual(ProjectFiles.list(root: root, limit: 4).count, 4, "and the full listing serves every later ask")
    }

    func testTheListingIsCachedUntilInvalidated() throws {
        try TestSupport.write(["one.txt": ""], under: root)
        XCTAssertEqual(list(), ["one.txt"])
        try TestSupport.write(["two.txt": ""], under: root)
        XCTAssertEqual(list(), ["one.txt"], "the file tree has not reported a change yet")
        ProjectFiles.invalidate(root: URL(fileURLWithPath: root.path + "/"))
        XCTAssertEqual(list(), ["one.txt", "two.txt"])
    }

    func testARootUnderTmpIsListedTheSameUnderEitherSpelling() throws {
        let name = "feather-files-\(UUID().uuidString)"
        let short = URL(fileURLWithPath: "/tmp/" + name, isDirectory: true)
        let long = URL(fileURLWithPath: "/private/tmp/" + name + "/", isDirectory: true)
        try FileManager.default.createDirectory(at: short, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: short) }
        try TestSupport.write(["a.txt": "", "src/b.txt": ""], under: short)
        XCTAssertEqual(Set(ProjectFiles.list(root: short)), ["a.txt", "src/b.txt"])
        XCTAssertEqual(Set(ProjectFiles.list(root: long)), ["a.txt", "src/b.txt"])
        // Both spellings share one cache entry.
        try TestSupport.write(["c.txt": ""], under: short)
        ProjectFiles.invalidate(root: long)
        XCTAssertEqual(Set(ProjectFiles.list(root: short)), ["a.txt", "src/b.txt", "c.txt"])
    }

    func testAnAbandonedWalkReturnsWhatItHasAndCachesNothing() throws {
        try TestSupport.write(Dictionary(uniqueKeysWithValues: (0..<700).map { ("f\($0).txt", "") }), under: root)
        var asked = 0
        let partial = ProjectFiles.list(root: root) { asked += 1; return true }
        XCTAssertGreaterThan(asked, 0)
        XCTAssertLessThan(partial.count, 700)
        XCTAssertEqual(ProjectFiles.list(root: root).count, 700, "the partial listing was not kept")
    }

    func testIgnoredDirectoriesAreTheUsualSuspects() {
        for name in ["node_modules", "build", "DerivedData", "Pods", "dist", "target", "vendor", "__pycache__", "venv"] {
            XCTAssertTrue(ProjectFiles.ignoredDirectories.contains(name), name)
        }
        XCTAssertFalse(ProjectFiles.ignoredDirectories.contains("src"))
    }
}
