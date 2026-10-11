import XCTest
@testable import Feather

/// Covers Editor/EditorConfig.swift: turning key/value pairs into properties, the section glob grammar, parsing
/// a file (comments, malformed lines, `root`), and the store's lookup up the folder chain with its precedence
/// rules, `unset`, and invalidation.
final class EditorConfigPropertiesTests: XCTestCase {
    func testIndentStyleAndSizes() {
        XCTAssertEqual(EditorConfigProperties(["indent_style": "space"]).useSpaces, true)
        XCTAssertEqual(EditorConfigProperties(["indent_style": "tab"]).useSpaces, false)
        XCTAssertNil(EditorConfigProperties(["indent_style": "spaces"]).useSpaces)
        XCTAssertEqual(EditorConfigProperties(["indent_size": "2"]).tabWidth, 2)
        XCTAssertEqual(EditorConfigProperties(["tab_width": "8"]).tabWidth, 8)
        // With spaces the indent size is what shows; with tabs the tab width is.
        XCTAssertEqual(EditorConfigProperties(["indent_style": "space", "indent_size": "2", "tab_width": "8"]).tabWidth, 2)
        XCTAssertEqual(EditorConfigProperties(["indent_style": "tab", "indent_size": "2", "tab_width": "8"]).tabWidth, 8)
        XCTAssertEqual(EditorConfigProperties(["indent_style": "tab", "indent_size": "2"]).tabWidth, 2)
        XCTAssertEqual(EditorConfigProperties(["indent_size": "tab", "tab_width": "6"]).tabWidth, 6)
        XCTAssertNil(EditorConfigProperties(["indent_size": "tab"]).tabWidth)
        XCTAssertNil(EditorConfigProperties(["indent_size": "two"]).tabWidth)
        XCTAssertEqual(EditorConfigProperties(["indent_size": "0"]).tabWidth, 1)
        XCTAssertEqual(EditorConfigProperties(["indent_size": "99"]).tabWidth, 16)
    }

    func testLineEndingsFlagsAndCharsets() {
        XCTAssertEqual(EditorConfigProperties(["end_of_line": "crlf"]).lineEnding, .crlf)
        XCTAssertEqual(EditorConfigProperties(["end_of_line": "cr"]).lineEnding?.string, "\r")
        XCTAssertNil(EditorConfigProperties(["end_of_line": "native"]).lineEnding)
        XCTAssertEqual(EditorConfigProperties(["insert_final_newline": "true"]).insertFinalNewline, true)
        XCTAssertEqual(EditorConfigProperties(["trim_trailing_whitespace": "false"]).trimTrailingWhitespace, false)
        XCTAssertNil(EditorConfigProperties(["insert_final_newline": "yes"]).insertFinalNewline)
        XCTAssertEqual(EditorConfigProperties(["charset": "utf-8"]).encoding, .utf8)
        XCTAssertEqual(EditorConfigProperties(["charset": "latin1"]).encoding, .isoLatin1)
        XCTAssertEqual(EditorConfigProperties(["charset": "utf-16le"]).encoding, .utf16)
        XCTAssertNil(EditorConfigProperties(["charset": "utf-8-bom"]).encoding)
    }

    func testEmptiness() {
        XCTAssertTrue(EditorConfigProperties().isEmpty)
        XCTAssertTrue(EditorConfigProperties(["unknown_key": "1", "indent_style": "wrong"]).isEmpty)
        XCTAssertFalse(EditorConfigProperties(["tab_width": "4"]).isEmpty)
    }
}

final class EditorConfigGlobTests: XCTestCase {
    private func matches(_ pattern: String, _ path: String) -> Bool { EditorConfigGlob(pattern).matches(path) }

    func testStarStopsAtSlashesAndDoubleStarDoesNot() {
        XCTAssertTrue(matches("*.py", "a.py"))
        XCTAssertTrue(matches("*.py", "src/deep/a.py"))            // no slash: any folder
        XCTAssertFalse(matches("*.py", "a.pyc"))
        XCTAssertTrue(matches("src/*.js", "src/a.js"))
        XCTAssertFalse(matches("src/*.js", "src/x/a.js"))
        XCTAssertFalse(matches("src/*.js", "a.js"))
        XCTAssertTrue(matches("**.json", "x/y/z.json"))
        XCTAssertTrue(matches("lib/**/*.ts", "lib/a.ts"))           // "a/**/b" also matches "a/b"
        XCTAssertTrue(matches("lib/**/*.ts", "lib/x/y/a.ts"))
        XCTAssertFalse(matches("lib/**/*.ts", "src/a.ts"))
        XCTAssertTrue(matches("*", "anything"))
        XCTAssertTrue(matches("*", "deep/anything"))
    }

    func testLeadingSlashRootsThePattern() {
        XCTAssertTrue(matches("/Makefile", "Makefile"))
        XCTAssertFalse(matches("/Makefile", "sub/Makefile"))
        XCTAssertTrue(matches("Makefile", "sub/Makefile"))
    }

    func testQuestionMarkAndCharacterClasses() {
        XCTAssertTrue(matches("a?.txt", "ab.txt"))
        XCTAssertFalse(matches("a?.txt", "a/.txt"))
        XCTAssertFalse(matches("a?.txt", "a.txt"))
        XCTAssertTrue(matches("[abc].txt", "b.txt"))
        XCTAssertFalse(matches("[abc].txt", "d.txt"))
        XCTAssertTrue(matches("[!abc].txt", "d.txt"))
        XCTAssertFalse(matches("[!abc].txt", "a.txt"))
        XCTAssertTrue(matches("[a-c].txt", "b.txt"))
        XCTAssertTrue(matches("[a/b].txt", "[a/b].txt"))            // a slash inside: literal brackets
        XCTAssertTrue(matches("[.txt", "[.txt"))                    // never closed: literal
    }

    func testBracesAlternativesAndRanges() {
        XCTAssertTrue(matches("{package,tsconfig}.json", "tsconfig.json"))
        XCTAssertFalse(matches("{package,tsconfig}.json", "other.json"))
        XCTAssertTrue(matches("*.{js,{ts,tsx}}", "a.tsx"))          // nested
        XCTAssertTrue(matches("{a}.txt", "{a}.txt"))                // no comma, no range: literal braces
        XCTAssertTrue(matches("{a,b", "{a,b"))                      // unbalanced: literal
        XCTAssertTrue(matches("{1..3}.txt", "2.txt"))
        XCTAssertTrue(matches("{3..1}.txt", "2.txt"))
        XCTAssertFalse(matches("{1..3}.txt", "4.txt"))
        XCTAssertFalse(matches("{1..3}.txt", "02.txt"))             // "02" is not "2"
        XCTAssertTrue(matches("{-2..2}.txt", "-1.txt"))
        XCTAssertTrue(matches("{0..0}.txt", "0.txt"))
    }

    func testEscapes() {
        XCTAssertTrue(matches("\\*.txt", "*.txt"))
        XCTAssertFalse(matches("\\*.txt", "a.txt"))
        XCTAssertTrue(matches("a\\{b\\}", "a{b}"))
        XCTAssertTrue(matches("weird\\", "weird\\"))                // a trailing backslash stands for itself
        XCTAssertTrue(matches("näme.*", "näme.md"))
    }
}

final class EditorConfigFileTests: XCTestCase {
    func testParsesRootSectionsAndCasing() {
        let file = EditorConfigFile(text: """
        # top comment
        ; another
        root = TRUE
        stray = value

        [*]
        Indent_Style = Space
        end_of_line=LF

        [*.md]
        trim_trailing_whitespace = false
        not a pair
        = novalue
        """)
        XCTAssertTrue(file.isRoot)
        XCTAssertEqual(file.sections.count, 2)
        XCTAssertEqual(file.sections[0].values.map { "\($0.key)=\($0.value)" }, ["indent_style=space", "end_of_line=lf"])
        XCTAssertEqual(file.sections[1].values.map { "\($0.key)=\($0.value)" }, ["trim_trailing_whitespace=false"])
        XCTAssertTrue(file.sections[1].glob.matches("README.md"))
        XCTAssertFalse(file.sections[1].glob.matches("a.txt"))
    }

    func testRootOnlyCountsBeforeTheFirstSection() {
        XCTAssertFalse(EditorConfigFile(text: "[*]\nroot = true\n").isRoot)
        XCTAssertFalse(EditorConfigFile(text: "root = false\n").isRoot)
        XCTAssertFalse(EditorConfigFile(text: "").isRoot)
        XCTAssertTrue(EditorConfigFile(text: "").sections.isEmpty)
    }

    func testHeadersMayContainBracketsAndFilesMayUseCRLF() {
        let file = EditorConfigFile(text: "[*.[ch]]\r\nindent_size = 8\r\n[{a,b}.txt]\r\ntab_width = 2\r\n")
        XCTAssertEqual(file.sections.count, 2)
        XCTAssertTrue(file.sections[0].glob.matches("main.c"))
        XCTAssertFalse(file.sections[0].glob.matches("main.cpp"))
        XCTAssertEqual(file.sections[0].values.first?.value, "8")
        XCTAssertTrue(file.sections[1].glob.matches("b.txt"))
    }
}

final class EditorConfigStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = TestSupport.temporaryDirectory("feather-editorconfig")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func properties(_ path: String) -> EditorConfigProperties? {
        EditorConfigStore.shared.properties(for: root.appendingPathComponent(path))
    }

    func testNearerFilesAndLaterSectionsWinAndUnsetForgets() throws {
        try TestSupport.write([
            ".editorconfig": "root = true\n[*]\nindent_style = space\nindent_size = 2\ninsert_final_newline = true\n[*.rb]\nindent_size = 4\n",
            "sub/.editorconfig": "[*.txt]\nindent_style = tab\n[*]\nend_of_line = crlf\n[x.txt]\nindent_size = unset\n",
            "a.rb": "", "sub/b.txt": "", "sub/x.txt": "", "sub/c.rb": "",
        ], under: root)
        let ruby = try XCTUnwrap(properties("a.rb"))
        XCTAssertEqual(ruby.useSpaces, true)
        XCTAssertEqual(ruby.tabWidth, 4)
        XCTAssertNil(ruby.lineEnding)
        let text = try XCTUnwrap(properties("sub/b.txt"))
        XCTAssertEqual(text.useSpaces, false)
        XCTAssertEqual(text.tabWidth, 2)                             // no tab_width: the indent size stands in
        XCTAssertEqual(text.lineEnding, .crlf)
        XCTAssertEqual(text.insertFinalNewline, true)                // from the file above
        let unset = try XCTUnwrap(properties("sub/x.txt"))
        XCTAssertNil(unset.tabWidth)
        XCTAssertEqual(unset.useSpaces, false)
        XCTAssertEqual(properties("sub/c.rb")?.tabWidth, 4)
        XCTAssertEqual(properties("sub/c.rb")?.lineEnding, .crlf)
    }

    func testRootStopsTheWalkAndNothingSaidMeansNil() throws {
        try TestSupport.write([
            ".editorconfig": "[*]\ninsert_final_newline = true\n",
            "project/.editorconfig": "root = true\n[*.py]\nindent_size = 4\n",
            "project/a.py": "", "project/b.txt": "",
        ], under: root)
        XCTAssertEqual(properties("project/a.py")?.tabWidth, 4)
        XCTAssertNil(properties("project/a.py")?.insertFinalNewline)
        XCTAssertNil(properties("project/b.txt"))                    // a file was found, but no section applies
    }

    func testPathsAreRelativeToTheFileThatHoldsThePattern() throws {
        try TestSupport.write([
            ".editorconfig": "root = true\n[src/*.js]\nindent_size = 3\n",
            "src/.editorconfig": "[*.js]\ntab_width = 9\n",
            "src/a.js": "", "src/deep/b.js": "", "other/c.js": "",
        ], under: root)
        XCTAssertEqual(properties("src/a.js")?.tabWidth, 3)         // indent_size wins over tab_width with spaces unsaid
        XCTAssertEqual(properties("src/deep/b.js")?.tabWidth, 9)   // "src/*.js" does not reach into deeper folders
        XCTAssertNil(properties("other/c.js"))
    }

    func testInvalidateAnnouncesOnlyWhenSomethingWasCached() throws {
        try TestSupport.write([".editorconfig": "root = true\n[*]\ntab_width = 5\n", "a.txt": ""], under: root)
        XCTAssertEqual(properties("a.txt")?.tabWidth, 5)
        let announced = expectation(forNotification: EditorConfigStore.didInvalidate, object: EditorConfigStore.shared)
        EditorConfigStore.shared.invalidate()
        wait(for: [announced], timeout: 1)
        let quiet = expectation(forNotification: EditorConfigStore.didInvalidate, object: EditorConfigStore.shared)
        quiet.isInverted = true
        EditorConfigStore.shared.invalidate()                        // nothing cached now: nobody is told
        wait(for: [quiet], timeout: 0.2)
        try "root = true\n[*]\ntab_width = 7\n".write(to: root.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
        XCTAssertEqual(properties("a.txt")?.tabWidth, 7)             // read afresh after the cache was emptied
    }

    func testIndentationCombinesConfigAndSettings() {
        XCTAssertEqual(Indentation(useSpaces: true, width: 3).unit, "   ")
        XCTAssertEqual(Indentation(useSpaces: false, width: 3).unit, "\t")
    }
}
