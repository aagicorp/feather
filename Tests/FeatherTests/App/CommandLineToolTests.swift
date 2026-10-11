/// Covers App/CommandLineTool.swift: how a path with a line and column is read ("src/App.tsx:12:5", a feather://
/// link, a file URL made from such text), and installing and removing the `feather` script without touching
/// anything outside a scratch folder.
import XCTest
@testable import Feather

final class PathArgumentTests: XCTestCase {
    private func parse(_ text: String, existing: Set<String> = []) -> PathArgument {
        PathArgument.parse(text) { existing.contains($0) }
    }

    func testLineAndColumn() {
        XCTAssertEqual(parse("src/App.tsx:12"), PathArgument(path: "src/App.tsx", line: 12, column: nil))
        XCTAssertEqual(parse("src/App.tsx:12:5"), PathArgument(path: "src/App.tsx", line: 12, column: 5))
        XCTAssertEqual(parse("src/App.tsx"), PathArgument(path: "src/App.tsx"))
        XCTAssertEqual(parse("main.c:12:", ), PathArgument(path: "main.c", line: 12, column: nil), "grep leaves a trailing colon")
        XCTAssertEqual(parse("main.c:12:7:"), PathArgument(path: "main.c", line: 12, column: 7))
    }

    func testLinesAndColumnsCountFromOne() {
        XCTAssertEqual(parse("a.py:0"), PathArgument(path: "a.py", line: 1, column: nil))
        XCTAssertEqual(parse("a.py:0:0"), PathArgument(path: "a.py", line: 1, column: 1))
    }

    func testAFileWhoseNameHasAColonWins() {
        XCTAssertEqual(parse("notes:12", existing: ["notes:12"]), PathArgument(path: "notes:12"))
        XCTAssertEqual(parse("notes:12", existing: ["notes"]), PathArgument(path: "notes", line: 12, column: nil))
        // Colons earlier in the path are part of it.
        XCTAssertEqual(parse("a:b/c.txt:3"), PathArgument(path: "a:b/c.txt", line: 3, column: nil))
        // Only the last two numbers count; the rest of the text is the path.
        XCTAssertEqual(parse("x:1:2:3"), PathArgument(path: "x:1", line: 2, column: 3))
    }

    func testTextThatIsNotAPositionIsLeftAlone() {
        XCTAssertEqual(parse(":12"), PathArgument(path: ":12"))
        XCTAssertEqual(parse(":12:3"), PathArgument(path: ":12:3"))
        XCTAssertEqual(parse("file:abc"), PathArgument(path: "file:abc"))
        XCTAssertEqual(parse("file:-3"), PathArgument(path: "file:-3"))
        XCTAssertEqual(parse("file:１２"), PathArgument(path: "file:１２"), "full-width digits are not a line number")
        XCTAssertEqual(parse(""), PathArgument(path: ""))
        XCTAssertEqual(parse("~/notes.md:4"), PathArgument(path: "~/notes.md", line: 4, column: nil), "the tilde is the caller's to expand")
    }

    func testFeatherLinks() throws {
        let plain = try XCTUnwrap(PathArgument.parse(url: URL(string: "feather://open?path=/tmp/a%20b/App.tsx&line=12&column=5")!))
        XCTAssertEqual(plain, PathArgument(path: "/tmp/a b/App.tsx", line: 12, column: 5))
        XCTAssertEqual(PathArgument.parse(url: URL(string: "feather://open?path=/tmp/x.txt")!), PathArgument(path: "/tmp/x.txt"))
        XCTAssertEqual(PathArgument.parse(url: URL(string: "feather://open?path=/tmp/x.txt&line=0")!), PathArgument(path: "/tmp/x.txt", line: 1, column: nil))
        XCTAssertEqual(PathArgument.parse(url: URL(string: "feather://open?path=/tmp/x.txt&line=abc")!), PathArgument(path: "/tmp/x.txt"))
        XCTAssertNil(PathArgument.parse(url: URL(string: "feather://open?path=relative/x.txt")!), "only absolute paths")
        XCTAssertNil(PathArgument.parse(url: URL(string: "feather://open?line=3")!))
        XCTAssertNil(PathArgument.parse(url: URL(string: "https://example.com/open?path=/tmp/x")!))
        XCTAssertEqual(CommandLineTool.urlScheme, "feather")
    }

    func testResolvingURLsHandedToTheApp() throws {
        let root = TestSupport.temporaryDirectory("feather-cli")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.write(["src/App.tsx": "x\n"], under: root)
        let file = root.appendingPathComponent("src/App.tsx")

        XCTAssertNil(PathArgument.resolve(file), "an existing file opens as it always did")
        XCTAssertNil(PathArgument.resolve(root))
        XCTAssertEqual(PathArgument.resolve(URL(fileURLWithPath: file.path + ":12")), PathArgument(path: file.path, line: 12, column: nil))
        XCTAssertEqual(PathArgument.resolve(URL(fileURLWithPath: file.path + ":12:3")), PathArgument(path: file.path, line: 12, column: 3))
        XCTAssertNil(PathArgument.resolve(URL(fileURLWithPath: root.appendingPathComponent("missing.tsx").path + ":12")), "no such file")
        XCTAssertNil(PathArgument.resolve(URL(fileURLWithPath: root.appendingPathComponent("missing.tsx").path)))
        XCTAssertNil(PathArgument.resolve(URL(fileURLWithPath: "~/never-expanded/App.tsx:12")))
        XCTAssertEqual(PathArgument.resolve(URL(string: "feather://open?path=\(file.path)&line=2")!), PathArgument(path: file.path, line: 2, column: nil))
        XCTAssertNil(PathArgument.resolve(URL(string: "https://example.com")!))
    }
}

final class CommandLineToolInstallTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = TestSupport.temporaryDirectory("feather-cli-install")
    }

    override func tearDown() {
        // A folder made read-only by a test must be writable again to be removed.
        if let unwritable = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for folder in unwritable { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        }
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func destination(_ folder: String) -> URL { root.appendingPathComponent(folder).appendingPathComponent("feather") }

    func testScriptQuotesTheAppPath() {
        let script = CommandLineTool.script(appPath: "/Apps/It's Feather.app")
        XCTAssertTrue(script.hasPrefix("#!/bin/bash\n"))
        XCTAssertTrue(script.contains("APP='/Apps/It'\\''s Feather.app'"))
        XCTAssertTrue(script.contains("# Installed by Feather"))
        XCTAssertTrue(CommandLineTool.script(appPath: nil).contains("APP=''\n"))
        XCTAssertTrue(script.contains("feather://open?path="))
    }

    func testInstallsIntoTheFirstWritableFolderAndMakesItExecutable() throws {
        let target = destination("bin")                      // the folder does not exist yet: it is made
        var askedAbout: [URL] = []
        let result = CommandLineTool.install(to: [target], appPath: "/Apps/Feather.app") { askedAbout.append($0); return false }
        XCTAssertEqual(result, .installed(target, onPath: false))
        XCTAssertEqual(askedAbout, [target.deletingLastPathComponent()])
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int).map { $0 & 0o111 }, 0o111)
        let text = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(text.contains("APP='/Apps/Feather.app'"))
        XCTAssertEqual(CommandLineTool.installedCopies(in: [target]), [target])
    }

    func testAScriptThatIsNotOursIsNotReplaced() throws {
        let foreign = destination("foreign"), ours = destination("ours")
        try TestSupport.write(["foreign/feather": "#!/bin/sh\necho someone else's\n"], under: root)
        let result = CommandLineTool.install(to: [foreign, ours], appPath: nil) { _ in true }
        XCTAssertEqual(result, .installed(ours, onPath: true))
        XCTAssertEqual(try String(contentsOf: foreign, encoding: .utf8), "#!/bin/sh\necho someone else's\n")
        XCTAssertEqual(CommandLineTool.installedCopies(in: [foreign, ours]), [ours])

        // Only the foreign one available: a clear reason, nothing written.
        guard case .failed(let reason) = CommandLineTool.install(to: [foreign], appPath: nil, isOnPath: { _ in true }) else {
            return XCTFail("should not install over a foreign script")
        }
        XCTAssertTrue(reason.contains("not installed by Feather"), reason)
    }

    func testAnUnwritableFolderIsPassedOver() throws {
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        let ours = destination("ours")
        XCTAssertEqual(CommandLineTool.install(to: [locked.appendingPathComponent("feather"), ours], appPath: nil, isOnPath: { _ in true }),
                       .installed(ours, onPath: true))
        guard case .failed(let reason) = CommandLineTool.install(to: [locked.appendingPathComponent("feather")], appPath: nil, isOnPath: { _ in true }) else {
            return XCTFail("nowhere to write")
        }
        XCTAssertTrue(reason.hasSuffix("is not writable."), reason)
    }

    func testAMissingSystemFolderIsNotCreated() {
        let system = URL(fileURLWithPath: "/usr/feather-tests-\(UUID().uuidString)/feather")
        guard case .failed = CommandLineTool.install(to: [system], appPath: nil, isOnPath: { _ in true }) else {
            return XCTFail("a folder under /usr would take a password to make")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: system.deletingLastPathComponent().path))
        XCTAssertEqual(CommandLineTool.install(to: [], appPath: nil, isOnPath: { _ in true }), .failed("No destination was given."))
    }

    func testUninstallRemovesOnlyOurScripts() throws {
        let ours = destination("a"), foreign = destination("b"), missing = destination("c")
        try TestSupport.write(["b/feather": "#!/bin/sh\n# somebody else's feather\n"], under: root)
        XCTAssertEqual(CommandLineTool.install(to: [ours], appPath: nil, isOnPath: { _ in true }), .installed(ours, onPath: true))
        XCTAssertEqual(CommandLineTool.uninstall(from: [ours, foreign, missing]), [ours])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ours.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        XCTAssertEqual(CommandLineTool.installedCopies(in: [ours, foreign, missing]), [])
    }

    func testReinstallingReplacesOurOwnScript() throws {
        let ours = destination("a")
        XCTAssertEqual(CommandLineTool.install(to: [ours], appPath: "/Old/Feather.app", isOnPath: { _ in true }), .installed(ours, onPath: true))
        XCTAssertEqual(CommandLineTool.install(to: [ours], appPath: "/New/Feather.app", isOnPath: { _ in true }), .installed(ours, onPath: true))
        XCTAssertTrue(try String(contentsOf: ours, encoding: .utf8).contains("APP='/New/Feather.app'"))
    }

    func testABareBinaryHasNoAppPath() {
        // The test bundle is not a .app either, so the script would leave macOS to find Feather by name.
        XCTAssertNil(CommandLineTool.installedAppPath)
    }
}
