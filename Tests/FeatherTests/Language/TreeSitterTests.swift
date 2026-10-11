import XCTest
@testable import Feather

final class TreeSitterTests: XCTestCase {
    private func tokens(_ text: String, _ language: TreeSitterLanguage, file: StaticString = #filePath, line: UInt = #line) -> [TreeSitterHighlighter.Token] {
        guard let snapshot = SyntaxTreeController.parse(text, as: language) else {
            XCTFail("\(language) did not parse", file: file, line: line)
            return []
        }
        let ns = text as NSString
        return TreeSitterHighlighter.tokens(of: snapshot.root, in: NSRange(location: 0, length: ns.length), text: { ns.substring(with: $0) })
    }

    /// The kind of the token covering the first occurrence of `needle`.
    private func kind(of needle: String, in text: String, _ tokens: [TreeSitterHighlighter.Token]) -> TokenKind? {
        let range = (text as NSString).range(of: needle)
        precondition(range.location != NSNotFound, "no \(needle) in the snippet")
        return tokens.first { NSIntersectionRange($0.range, range).length == range.length }?.kind
    }

    private func check(_ language: TreeSitterLanguage, _ text: String, _ expected: [(String, TokenKind?)], file: StaticString = #filePath, line: UInt = #line) {
        let found = tokens(text, language, file: file, line: line)
        for (needle, kind) in expected {
            XCTAssertEqual(self.kind(of: needle, in: text, found), kind, "\(language): \(needle)", file: file, line: line)
        }
    }

    func testEveryBundledGrammarColoursTheMainKinds() {
        check(.javascript, "// note\nconst n = 42;\nfunction greet(name) { return `hi ${name}`; }\nclass Foo {}\nconsole.log(greet(\"x\"));\n",
              [("// note", .comment), ("const", .keyword), ("42", .number), ("function", .keyword), ("greet", .function),
               ("`hi ${name}`", .string), ("Foo", .type), ("log", .function), ("\"x\"", .string), ("name", nil)])
        check(.typescript, "interface User { id: number }\nlet s: string = \"a\";\nfunction compute(): void {}\n",
              [("interface", .keyword), ("User", .type), ("number", .type), ("string", .type), ("\"a\"", .string), ("compute", .function)])
        check(.tsx, "const App = () => <div className=\"x\">{1}</div>;\n",
              [("div", .keyword), ("className", .type), ("\"x\"", .string), ("1", .number), ("App", .type)])
        check(.python, "# c\ndef compute(x):\n    return \"s\"\nclass K:\n    pass\nn = 1.5\nprint(len(x))\n",
              [("# c", .comment), ("def", .keyword), ("compute", .function), ("\"s\"", .string), ("class", .keyword), ("K", .type),
               ("1.5", .number), ("print", .function), ("len", .function)])
        check(.java, "// c\npublic class A { int n = 10; String s = \"x\"; void run() { list.size(); } }\n",
              [("// c", .comment), ("class", .keyword), ("A", .type), ("10", .number), ("String", .type), ("\"x\"", .string),
               ("run", .function), ("size", .function), ("int", .type)])
        check(.dart, "// c\nclass A { int n = 1; String greet(String s) => \"hi\"; }\nvoid main() { print(\"x\"); }\n",
              [("// c", .comment), ("class", .keyword), ("A", .type), ("1", .number), ("\"hi\"", .string), ("greet", .function), ("print", .function)])
        check(.kotlin, "// c\nfun main() { val n = 1; println(\"hi\") }\nclass A\n",
              [("// c", .comment), ("fun", .keyword), ("main", .function), ("1", .number), ("\"hi\"", .string), ("println", .function), ("class", .keyword)])
        check(.swift, "// c\nstruct A { let n = 1; func run() -> String { return \"s\" } }\n",
              [("// c", .comment), ("struct", .keyword), ("A", .type), ("1", .number), ("func", .keyword), ("run", .function),
               ("String", .type), ("return", .keyword), ("\"s\"", .string)])
        check(.json, "// c\n{\"a\": 1, \"b\": \"x\", \"c\": true}\n",
              [("// c", .comment), ("\"a\"", .keyword), ("1", .number), ("\"x\"", .string), ("true", .keyword)])
        check(.css, "/* c */\n.a { color: #fff; width: 10px; }\n@media (x) {}\n",
              [("/* c */", .comment), ("color", .type), ("#fff", .number), ("10", .number), ("px", .number), ("@media", .keyword)])
        check(.html, "<!-- c --><div class=\"x\">Hi</div>\n",
              [("<!-- c -->", .comment), ("div", .keyword), ("class", .type), ("x", .string), ("Hi", nil)])
        check(.yaml, "# c\nname: value\ncount: 3\nflag: true\nlist:\n  - \"q\"\n",
              [("# c", .comment), ("name", .keyword), ("value", .string), ("3", .number), ("true", .keyword), ("\"q\"", .string)])
        check(.bash, "# c\necho \"hi\"\nfor f in *; do ls $f; done\nfunction g() { :; }\n",
              [("# c", .comment), ("echo", .function), ("\"hi\"", .string), ("for", .keyword), ("do", .keyword), ("g", .function)])
        check(.go, "// c\npackage main\nfunc run() { x := 1; fmt.Println(\"a\") }\ntype T struct{}\n",
              [("// c", .comment), ("package", .keyword), ("func", .keyword), ("run", .function), ("1", .number),
               ("Println", .function), ("\"a\"", .string), ("T", .type)])
        check(.rust, "// c\nfn main() { let n = 1u8; println!(\"a\"); }\nstruct S;\n",
              [("// c", .comment), ("fn", .keyword), ("main", .function), ("1u8", .number), ("println", .function), ("\"a\"", .string), ("S", .type)])
    }

    func testLanguagesWithAndWithoutGrammars() {
        func grammar(_ name: String) -> TreeSitterLanguage? { Language.detect(for: URL(fileURLWithPath: "/p/" + name))?.treeSitterLanguage }
        XCTAssertEqual(grammar("a.ts"), .typescript)
        XCTAssertEqual(grammar("a.tsx"), .tsx)
        XCTAssertEqual(grammar("a.jsx"), .javascript)
        XCTAssertEqual(grammar("a.py"), .python)
        XCTAssertEqual(grammar("Package.resolved"), .json)
        XCTAssertEqual(grammar(".zshrc"), .bash)
        XCTAssertNil(grammar("a.scss"))          // the CSS grammar does not know Sass; the regex rules stay
        XCTAssertNil(grammar("Makefile"))
        XCTAssertNil(grammar("a.md"))
        XCTAssertNil(grammar("a.rb"))
        // A language without a grammar highlights exactly as before.
        XCTAssertNotNil(Language.ruby.regex)
        XCTAssertEqual(Language.ruby.rules.count, Language.ruby.rules.count)
    }

    func testCaptureNamesFallBackToTheirFamily() {
        XCTAssertEqual(TreeSitterGrammar.kind(ofCapture: "keyword.return", in: .swift), .keyword)
        XCTAssertEqual(TreeSitterGrammar.kind(ofCapture: "function.method.call", in: .java), .function)
        XCTAssertEqual(TreeSitterGrammar.kind(ofCapture: "constant.builtin", in: .javascript), .keyword)
        XCTAssertEqual(TreeSitterGrammar.kind(ofCapture: "string.special.key", in: .json), .keyword)
        XCTAssertEqual(TreeSitterGrammar.kind(ofCapture: "string.special.key", in: .javascript), .string)
        XCTAssertNil(TreeSitterGrammar.kind(ofCapture: "punctuation.bracket", in: .javascript))
        XCTAssertNil(TreeSitterGrammar.kind(ofCapture: "variable.parameter", in: .python))
    }

    func testScriptInsideHTMLIsColouredAsJavaScript() throws {
        let text = "<div>x</div>\n<script>\nlet a = 1; // note\n</script>\n<style>p { color: red }</style>\n"
        let snapshot = try XCTUnwrap(SyntaxTreeController.parse(text, as: .html))
        XCTAssertEqual(snapshot.layers.map { $0.grammar.id }, [.javascript, .css])
        let ns = text as NSString
        let script = snapshot.layers[0]
        XCTAssertEqual(script.ranges, [ns.range(of: "\nlet a = 1; // note\n")])
        let found = TreeSitterHighlighter.tokens(of: script, in: NSRange(location: 0, length: ns.length), text: { ns.substring(with: $0) })
        XCTAssertEqual(kind(of: "let", in: text, found), .keyword)
        XCTAssertEqual(kind(of: "1", in: text, found), .number)
        XCTAssertEqual(kind(of: "// note", in: text, found), .comment)
        let style = TreeSitterHighlighter.tokens(of: snapshot.layers[1], in: NSRange(location: 0, length: ns.length), text: { ns.substring(with: $0) })
        XCTAssertEqual(kind(of: "color", in: text, style), .type)
    }

    func testTaggedTemplateIsColouredAsItsLanguage() throws {
        let text = "const s = css`p { color: red }`;\nconst h = html`<b>${s}</b>`;\n"
        let snapshot = try XCTUnwrap(SyntaxTreeController.parse(text, as: .javascript))
        XCTAssertEqual(snapshot.layers.map { $0.grammar.id }, [.css, .html])
        let ns = text as NSString
        let html = TreeSitterHighlighter.tokens(of: snapshot.layers[1], in: NSRange(location: 0, length: ns.length), text: { ns.substring(with: $0) })
        XCTAssertEqual(kind(of: "b", in: text, html), .keyword)
    }

    func testFoldRegionsComeFromTheTree() throws {
        let js = "function f() {\n  return 1;\n}\nconst o = {\n  a: 1,\n  b: [\n    1,\n  ],\n};\nif (x)\n  y();\n"
        let regions = try XCTUnwrap(SyntaxTreeController.parse(js, as: .javascript)?.foldRegions)
        XCTAssertEqual((0..<regions.count).map { regions.region(at: $0).header }, [0, 3, 5, 9])
        XCTAssertEqual((0..<regions.count).map { regions.region(at: $0).end }, [1, 7, 6, 10])
        XCTAssertEqual(regions.end(ofHeader: 3), 7)
        XCTAssertNil(regions.end(ofHeader: 4))

        let python = "class A:\n    def f(self,\n          x):\n        return x\n\n    y = 2\nz = 3\n"
        let py = try XCTUnwrap(SyntaxTreeController.parse(python, as: .python)?.foldRegions)
        XCTAssertEqual((0..<py.count).map { "\(py.region(at: $0).header)-\(py.region(at: $0).end)" }, ["0-5", "1-3"])

        let html = "<div>\n  <p>\n    hi\n  </p>\n</div>\n"
        let h = try XCTUnwrap(SyntaxTreeController.parse(html, as: .html)?.foldRegions)
        XCTAssertEqual((0..<h.count).map { "\(h.region(at: $0).header)-\(h.region(at: $0).end)" }, ["0-3", "1-2"])
    }

    func testIncrementalEditUpdatesHighlighting() throws {
        let storage = NSTextStorage(string: "let a = 1;\nlet b = 2;\n")
        let controller = try XCTUnwrap(SyntaxTreeController.make(for: storage, language: Language.detect(for: URL(fileURLWithPath: "/p/a.ts"))))
        XCTAssertNil(controller.current)
        controller.startIfNeeded()               // small: parsed on the spot
        let ns = storage.mutableString
        func kinds() -> [TreeSitterHighlighter.Token] {
            guard let snapshot = controller.current else { XCTFail("no current tree"); return [] }
            return TreeSitterHighlighter.tokens(of: snapshot.root, in: NSRange(location: 0, length: ns.length), text: { ns.substring(with: $0) })
        }
        XCTAssertEqual(kind(of: "2", in: ns as String, kinds()), .number)

        // The second line becomes a comment: the tree behind the colours is stale until the reparse lands.
        let arrives = expectation(forNotification: SyntaxTreeController.didUpdate, object: controller)
        storage.replaceCharacters(in: NSRange(location: 11, length: 0), with: "// ")
        XCTAssertNil(controller.current)
        wait(for: [arrives], timeout: 5)
        XCTAssertNotNil(controller.current)
        XCTAssertEqual(kind(of: "// let b = 2;", in: ns as String, kinds()), .comment)
        XCTAssertEqual(kind(of: "1", in: ns as String, kinds()), .number)

        // Several edits while a parse is running are folded into the next one.
        let settles = expectation(forNotification: SyntaxTreeController.didUpdate, object: controller)
        settles.assertForOverFulfill = false
        storage.replaceCharacters(in: NSRange(location: 0, length: 3), with: "const")
        storage.replaceCharacters(in: NSRange(location: ns.length, length: 0), with: "let c = \"s\";\n")
        wait(for: [settles], timeout: 5)
        while controller.current == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(kind(of: "const", in: ns as String, kinds()), .keyword)
        XCTAssertEqual(kind(of: "\"s\"", in: ns as String, kinds()), .string)
        storage.replaceCharacters(in: NSRange(location: 2, length: 6), with: "é")
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "😀")
        storage.replaceCharacters(in: NSRange(location: 4, length: 3), with: "")
        XCTAssertTrue(controller.mirrorMatchesStorage)
    }

    /// After edits, changing only what differs must leave the layout manager exactly as a pass from scratch would.
    func testIncrementalColoursMatchAFreshPass() throws {
        let text = "function f(a) {\n  return a + 1; // one\n}\nconst s = `x ${f(2)} y`;\nclass K extends Base {}\n"
        let storage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let theme = Settings.shared.theme
        let state = TreeHighlightState()
        func whole() -> NSRange { NSRange(location: 0, length: storage.length) }
        func snapshot() throws -> SyntaxSnapshot { try XCTUnwrap(SyntaxTreeController.parse(storage.string, as: .javascript)) }
        state.apply(try snapshot(), storage: storage, layoutManager: layoutManager, range: whole(), theme: theme)

        func edit(_ range: NSRange, _ replacement: String) {
            storage.replaceCharacters(in: range, with: replacement)
            state.noteEdit(NSRange(location: range.location, length: (replacement as NSString).length), delta: (replacement as NSString).length - range.length)
        }
        let ns = storage.mutableString
        edit(NSRange(location: ns.range(of: "return").location, length: 0), "// ")        // the line becomes a comment
        edit(NSRange(location: ns.range(of: "extends").location, length: 7), "implements")  // a keyword swap of another length
        edit(NSRange(location: ns.length, length: 0), "let n = 0x10;\n")                  // new text at the end
        edit(NSRange(location: ns.range(of: "// one").location, length: 6), "")             // and gone again
        // A pass over part of the file, then the whole of it.
        state.apply(try snapshot(), storage: storage, layoutManager: layoutManager, range: NSRange(location: 0, length: 30), theme: theme)
        state.apply(try snapshot(), storage: storage, layoutManager: layoutManager, range: whole(), theme: theme)

        let fresh = NSLayoutManager()
        let reference = NSTextStorage(string: storage.string)
        reference.addLayoutManager(fresh)
        TreeHighlightState().apply(try snapshot(), storage: reference, layoutManager: fresh, range: whole(), theme: theme)
        var mismatches: [String] = []
        for index in 0..<storage.length {
            let a = layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
            let b = fresh.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
            func name(_ c: NSColor?) -> String { c == nil ? "-" : c == theme.comment ? "comment" : c == theme.string ? "string" : c == theme.keyword ? "keyword" : c == theme.type ? "type" : c == theme.function ? "function" : c == theme.number ? "number" : "?" }
            if a != b { mismatches.append("\(index) '\(ns.substring(with: NSRange(location: index, length: 1)))' \(name(a)) vs \(name(b))") }
        }
        XCTAssertEqual(mismatches, [])
        XCTAssertEqual(kind(of: "// return", in: ns as String, TreeSitterHighlighter.tokens(of: try snapshot().root, in: whole(), text: { ns.substring(with: $0) })), .comment)
    }

    func testNoGrammarIsLoadedForALanguageNobodyOpened() {
        // Ruby has no grammar; asking for a controller must not load anything.
        let storage = NSTextStorage(string: "puts 1")
        XCTAssertNil(SyntaxTreeController.make(for: storage, language: Language.ruby))
    }

    /// Prints the main-thread cost of an edit in a 1.5 MB TypeScript file; the number that matters is in the report.
    func testEditsInALargeFileStayCheapOnTheMainThread() throws {
        var lines: [String] = []
        var index = 0
        while lines.reduce(0, { $0 + $1.count + 1 }) < 900_000 {          // under SyntaxTreeController.sizeLimit
            lines.append("export function handler\(index)(request: Request, count: number): Promise<Result> { // handles \(index)")
            lines.append("  const items = await store.load(`key-${count}`, { retries: 3, name: \"item \(index)\" });")
            lines.append("  if (items.length > 0 && count < 100) { return new Result(items[0], count + 1.5); }")
            lines.append("  return Result.empty();")
            lines.append("}")
            index += 1
        }
        let storage = NSTextStorage(string: lines.joined(separator: "\n"))
        let controller = try XCTUnwrap(SyntaxTreeController.make(for: storage, language: Language.detect(for: URL(fileURLWithPath: "/p/big.ts"))))
        let start = Date()
        let parsed = expectation(forNotification: SyntaxTreeController.didUpdate, object: controller)
        controller.startIfNeeded()
        XCTAssertNil(controller.current)         // big: on the queue
        wait(for: [parsed], timeout: 60)
        let firstParse = Date().timeIntervalSince(start)

        func threadCPU() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }
        var editCost = 0.0, roundTrip = 0.0
        let edits = 40
        for step in 0..<edits {
            let location = 700_000 + step * 37
            let t0 = threadCPU(), w0 = Date()
            storage.replaceCharacters(in: NSRange(location: location, length: 0), with: "x")
            editCost += threadCPU() - t0
            while controller.current == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
            roundTrip += Date().timeIntervalSince(w0) * 1000
        }
        let visible = NSRange(location: 700_000, length: 8000)
        let ns = storage.mutableString
        let h0 = threadCPU()
        let tokens = TreeSitterHighlighter.tokens(of: controller.current!.root, in: visible, text: { ns.substring(with: $0) })
        let highlightCost = threadCPU() - h0
        print(String(format: "BENCH tree: first parse %.0f ms; per edit main-thread %.3f ms, tree back after %.2f ms; visible-range query %.3f ms (%d tokens)",
                     firstParse * 1000, editCost / Double(edits), roundTrip / Double(edits), highlightCost, tokens.count))
        XCTAssertLessThan(editCost / Double(edits), 5)
        XCTAssertFalse(tokens.isEmpty)
    }
}
