import XCTest
@testable import Feather

/// Project/ProjectColor.swift: reading "JSON with comments", the project's own settings file (colour, border,
/// run command, custom tasks; updating it in place), which colour wins between `.feather/settings.json` and
/// VS Code's or Peacock's, hex colours in and out, and the brightness test for text on a tint.
final class JSONCommentsTests: XCTestCase {
    private func json(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(ProjectColor.stripJSONComments(text).utf8))) as? [String: Any]
    }

    func testLineAndBlockCommentsAreRemoved() {
        let text = """
        {
          // the title bar
          "a": 1, /* inline */ "b": 2,
          /* a block
             over lines */
          "c": 3 // trailing
        }
        """
        XCTAssertEqual(json(text)?["a"] as? Int, 1)
        XCTAssertEqual(json(text)?["b"] as? Int, 2)
        XCTAssertEqual(json(text)?["c"] as? Int, 3)
    }

    func testCommentMarkersInsideStringsStay() {
        let text = #"{ "url": "https://example.com/path", "note": "a /* not */ comment // either", "quote": "say \"hi\" // x" }"#
        XCTAssertEqual(json(text)?["url"] as? String, "https://example.com/path")
        XCTAssertEqual(json(text)?["note"] as? String, "a /* not */ comment // either")
        XCTAssertEqual(json(text)?["quote"] as? String, #"say "hi" // x"#)
    }

    func testTrailingCommasAreRemoved() {
        let text = "{ \"list\": [1, 2, 3, ], \"nested\": { \"x\": true, }, }"
        XCTAssertEqual(json(text)?["list"] as? [Int], [1, 2, 3])
        XCTAssertEqual((json(text)?["nested"] as? [String: Any])?["x"] as? Bool, true)
        XCTAssertEqual(ProjectColor.stripJSONComments("[1,\n  2,\n\n]"), "[1,\n  2\n\n]")
    }

    func testADivisionSignIsNotAComment() {
        XCTAssertEqual(ProjectColor.stripJSONComments("a / b"), "a / b")
        XCTAssertEqual(ProjectColor.stripJSONComments("a /"), "a /")
        XCTAssertEqual(ProjectColor.stripJSONComments("/"), "/")
    }

    func testUnterminatedCommentsAndEmptyInput() {
        XCTAssertEqual(ProjectColor.stripJSONComments(""), "")
        XCTAssertEqual(ProjectColor.stripJSONComments("{} // no newline at the end"), "{} \n")
        XCTAssertEqual(ProjectColor.stripJSONComments("{} /* never closed"), "{} ")
    }

    func testNonASCIIPassesThrough() {
        XCTAssertEqual(json(#"{ "name": "Straße 名前 🚀" } // ünïcödé"#)?["name"] as? String, "Straße 名前 🚀")
    }
}

final class ProjectSettingsTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = TestSupport.temporaryDirectory("feather-project")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func write(_ text: String) throws {
        try TestSupport.write([".feather/settings.json": text], under: root)
    }

    func testDefaultsWhenThereIsNoFile() {
        let settings = ProjectSettings.load(from: root)
        XCTAssertNil(settings.color)
        XCTAssertTrue(settings.border)
        XCTAssertNil(settings.run)
        XCTAssertTrue(settings.tasks.isEmpty)
        XCTAssertEqual(ProjectSettings.fileURL(in: root).path, root.appendingPathComponent(".feather/settings.json").path)
    }

    func testEveryKeyIsRead() throws {
        try write("""
        {
          // comments are fine here too
          "color": "#3B0764",
          "border": false,
          "run": "./mvnw spring-boot:run",
          "tasks": [
            { "name": "Seed", "command": "make seed", "cwd": "backend" },
            { "name": " Lint ", "command": " npm run lint ", "cwd": "" },
            { "name": "", "command": "ignored" },
            { "name": "No command" },
            "not an object",
          ],
        }
        """)
        let settings = ProjectSettings.load(from: root)
        XCTAssertEqual(settings.color, "#3B0764")
        XCTAssertFalse(settings.border)
        XCTAssertEqual(settings.run, "./mvnw spring-boot:run")
        XCTAssertEqual(settings.tasks.map(\.name), ["Seed", "Lint"])
        XCTAssertEqual(settings.tasks.map(\.command), ["make seed", "npm run lint"])
        XCTAssertEqual(settings.tasks.map(\.cwd), ["backend", nil])
    }

    func testEmptyStringsMeanUnset() throws {
        try write(#"{ "color": "", "run": "   " }"#)
        let settings = ProjectSettings.load(from: root)
        XCTAssertNil(settings.color)
        XCTAssertNil(settings.run)
    }

    func testABrokenFileIsTheSameAsNone() throws {
        try write("{ this is not json")
        XCTAssertNil(ProjectSettings.load(from: root).color)
        try write("[1, 2]")
        XCTAssertTrue(ProjectSettings.load(from: root).border)
    }

    func testUpdateKeepsOtherKeysAndRemovesNilOnes() throws {
        try write(##"{ "color": "#112233", "custom": "kept", "run": "old" }"##)
        ProjectSettings.update(in: root, ["run": "new", "color": nil, "border": false])
        let settings = ProjectSettings.load(from: root)
        XCTAssertEqual(settings.run, "new")
        XCTAssertNil(settings.color)
        XCTAssertFalse(settings.border)
        let text = try String(contentsOf: ProjectSettings.fileURL(in: root), encoding: .utf8)
        XCTAssertTrue(text.contains("\"custom\" : \"kept\""), text)
        XCTAssertFalse(text.contains("color"))
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func testUpdateCreatesTheFolderAndFile() {
        ProjectSettings.update(in: root, ["run": "go run ."])
        XCTAssertEqual(ProjectSettings.load(from: root).run, "go run .")
    }

    func testCreateIfMissingWritesEveryOptionOnce() throws {
        let file = ProjectSettings.createIfMissing(in: root, currentColor: NSColor(hexString: "#FF0000"))
        XCTAssertEqual(file, ProjectSettings.fileURL(in: root))
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("\"color\" : \"#FF0000\""))
        XCTAssertTrue(text.contains("\"run\" : \"\""))
        XCTAssertTrue(text.contains("$help"))
        XCTAssertTrue(text.contains("\"border\" : true"))
        // A second call leaves what is there.
        ProjectSettings.update(in: root, ["run": "keep"])
        _ = ProjectSettings.createIfMissing(in: root, currentColor: nil)
        XCTAssertEqual(ProjectSettings.load(from: root).run, "keep")
        // Without a current colour the default purple is written.
        let other = TestSupport.temporaryDirectory("feather-project")
        defer { try? FileManager.default.removeItem(at: other) }
        _ = ProjectSettings.createIfMissing(in: other, currentColor: nil)
        XCTAssertEqual(ProjectSettings.load(from: other).color, "#3B0764")
    }
}

final class ProjectColorTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = TestSupport.temporaryDirectory("feather-project")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func vscode(_ text: String) throws {
        try TestSupport.write([".vscode/settings.json": text], under: root)
    }

    func testNoSettingsMeansNoColour() {
        XCTAssertNil(ProjectColor.color(for: root))
        XCTAssertNil(ProjectColor.vscodeColor(in: root))
    }

    func testPeacockComesFirstThenTheTitleBar() throws {
        try vscode("""
        {
          "workbench.colorCustomizations": {
            "statusBar.background": "#111111",
            "titleBar.activeBackground": "#222222",
            "activityBar.background": "#333333",
          },
          "peacock.color": "#444444", // Peacock keeps its own copy
        }
        """)
        XCTAssertEqual(ProjectColor.vscodeColor(in: root)?.hexString, "#444444")
        try vscode(##"{ "workbench.colorCustomizations": { "statusBar.background": "#111111", "titleBar.activeBackground": "#222222" } }"##)
        XCTAssertEqual(ProjectColor.color(for: root)?.hexString, "#222222")
        try vscode(##"{ "workbench.colorCustomizations": { "activityBar.background": "#333333", "statusBar.background": "#111111" } }"##)
        XCTAssertEqual(ProjectColor.color(for: root)?.hexString, "#111111")
        try vscode(##"{ "workbench.colorCustomizations": { "window.activeBorder": "#555555" } }"##)
        XCTAssertEqual(ProjectColor.color(for: root)?.hexString, "#555555")
    }

    func testAnInvalidVSCodeColourIsSkippedForTheNextOne() throws {
        try vscode(##"{ "peacock.color": "not a colour", "workbench.colorCustomizations": { "titleBar.activeBackground": "#ABCDEF" } }"##)
        XCTAssertEqual(ProjectColor.color(for: root)?.hexString, "#ABCDEF")
        try vscode("{ broken")
        XCTAssertNil(ProjectColor.color(for: root))
    }

    func testFeathersOwnColourWins() throws {
        try vscode(##"{ "peacock.color": "#444444" }"##)
        try TestSupport.write([".feather/settings.json": ##"{ "color": "#123456" }"##], under: root)
        XCTAssertEqual(ProjectColor.color(for: root)?.hexString, "#123456")
        // Settings already loaded can be passed in, so the file is not read twice.
        var settings = ProjectSettings()
        settings.color = "#654321"
        XCTAssertEqual(ProjectColor.color(for: root, settings: settings)?.hexString, "#654321")
    }

    func testNoneSwitchesTheTintOffDespiteVSCode() throws {
        try vscode(##"{ "peacock.color": "#444444" }"##)
        try TestSupport.write([".feather/settings.json": #"{ "color": "None" }"#], under: root)
        XCTAssertNil(ProjectColor.color(for: root))
        XCTAssertEqual(ProjectColor.none, "none")
    }

    func testAnInvalidFeatherColourFallsBackToNothingNotVSCode() throws {
        try vscode(##"{ "peacock.color": "#444444" }"##)
        try TestSupport.write([".feather/settings.json": #"{ "color": "blue" }"#], under: root)
        XCTAssertNil(ProjectColor.color(for: root), "a colour was chosen, it just does not parse")
    }

    func testThePaletteIsSixRowsOfTwelveValidColours() {
        let rows = ProjectColor.palette
        XCTAssertEqual(rows.count, 6)
        XCTAssertTrue(rows.allSatisfy { $0.count == 12 })
        for hex in rows.flatMap({ $0 }) {
            XCTAssertNotNil(NSColor(hexString: hex), hex)
            XCTAssertEqual(hex.count, 7)
        }
        XCTAssertEqual(Set(rows.flatMap { $0 }).count, 72, "no two swatches are the same")
        XCTAssertTrue(rows[4].allSatisfy { NSColor(hexString: $0)?.isLight == false }, "the darkest shades read as dark")
        XCTAssertTrue(NSColor(hexString: rows[5][0])?.isLight == true, "the lightest grey reads as light")
    }

    func testTheWindowWearsAColourDyedIntoTheChrome() throws {
        let purple = try XCTUnwrap(NSColor(hexString: "#6A3FB5"))
        let dark = NSColor(hex: 0x1E1E1E), light = NSColor(hex: 0xF3F3F3)
        for chrome in [dark, light] {
            let worn = ProjectColor.chromeTint(purple, over: chrome).usingColorSpace(.sRGB)!
            XCTAssertEqual(worn.alphaComponent, 1, "opaque: the glass alpha is added when it is painted")
            XCTAssertEqual(worn.hueComponent, purple.usingColorSpace(.sRGB)!.hueComponent, accuracy: 0.03, "the hue is kept")
            XCTAssertLessThan(worn.saturationComponent, purple.usingColorSpace(.sRGB)!.saturationComponent, "but calmer than the swatch")
        }
        let onDark = ProjectColor.chromeTint(purple, over: dark).usingColorSpace(.sRGB)!
        let onLight = ProjectColor.chromeTint(purple, over: light).usingColorSpace(.sRGB)!
        XCTAssertFalse(onDark.isLight, "a dark theme stays dark")
        XCTAssertTrue(onLight.isLight, "a light theme stays light")
        XCTAssertGreaterThan(onLight.brightnessComponent, onDark.brightnessComponent)
    }

    func testSwatchHasAFixedSize() {
        XCTAssertEqual(ProjectColor.swatch(.red).size, NSSize(width: 14, height: 14))
    }

    // MARK: - Hex colours

    func testHexParsing() throws {
        let six = try XCTUnwrap(NSColor(hexString: "#FF8000"))
        XCTAssertEqual(six.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(six.greenComponent, 128 / 255, accuracy: 0.001)
        XCTAssertEqual(six.blueComponent, 0, accuracy: 0.001)
        XCTAssertEqual(six.alphaComponent, 1)
        let three = try XCTUnwrap(NSColor(hexString: "#f80"))
        XCTAssertEqual(three.hexString, "#FF8800")
        let eight = try XCTUnwrap(NSColor(hexString: "#FF800080"))
        XCTAssertEqual(eight.hexString, "#FF8000")
        XCTAssertEqual(eight.alphaComponent, 128 / 255, accuracy: 0.001)
        XCTAssertEqual(NSColor(hexString: "  #abcdef ")?.hexString, "#ABCDEF", "surrounding spaces are fine")
    }

    func testHexParsingRejectsWhatItCannotRead() {
        XCTAssertNil(NSColor(hexString: "FF8000"), "the # is required")
        XCTAssertNil(NSColor(hexString: "#FF80"))
        XCTAssertNil(NSColor(hexString: "#GGGGGG"))
        XCTAssertNil(NSColor(hexString: "#"))
        XCTAssertNil(NSColor(hexString: ""))
        XCTAssertNil(NSColor(hexString: "#FF8000FF00"))
    }

    func testHexRoundTrip() {
        for hex in ["#000000", "#FFFFFF", "#3B0764", "#7F7F7F", "#010203"] {
            XCTAssertEqual(NSColor(hexString: hex)?.hexString, hex)
        }
        XCTAssertEqual(NSColor(calibratedWhite: 0.5, alpha: 1).hexString.count, 7)
        XCTAssertEqual(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).hexString, "#FF0000")
    }

    func testIsLight() {
        XCTAssertTrue(NSColor(hexString: "#FFFFFF")?.isLight == true)
        XCTAssertTrue(NSColor(hexString: "#FFFF00")?.isLight == true, "yellow is bright")
        XCTAssertFalse(NSColor(hexString: "#000000")?.isLight == true)
        XCTAssertFalse(NSColor(hexString: "#0000FF")?.isLight == true, "pure blue is dark to the eye")
        XCTAssertFalse(NSColor(hexString: "#3B0764")?.isLight == true)
        XCTAssertTrue(NSColor(hexString: "#A0A0A0")?.isLight == true)
        XCTAssertFalse(NSColor(hexString: "#909090")?.isLight == true)
    }
}
