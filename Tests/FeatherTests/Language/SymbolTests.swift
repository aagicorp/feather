import XCTest
@testable import Feather

final class SymbolOutlineTests: XCTestCase {
    func testTypeScriptDeclarationsIncludingOneLineMethods() {
        let text = """
        export function loadUsers(id: number) { return id }
        export class UserService {
          fetchAll() { return [] }
          private cache = new Map()
          async save(user: User): Promise<void> {
          }
        }
        const handleClick = async (e: Event) => { }
        if (x) {
        }
        """
        let names = SymbolOutline.scan(text, fileExtension: "ts").map(\.name)
        XCTAssertEqual(names, ["loadUsers", "UserService", "fetchAll", "save", "handleClick"])
    }

    func testPythonAndLines() {
        let symbols = SymbolOutline.scan("class Invoice:\n    def total(self):\n        return 0\n\ndef build():\n    pass\n", fileExtension: "py")
        XCTAssertEqual(symbols.map { "\($0.name):\($0.line)" }, ["Invoice:0", "total:1", "build:4"])
    }

    func testJavaMethods() {
        let text = "public class Foo {\n    public String name() { return \"\"; }\n    private static int count(List<String> items) {\n    }\n}\n"
        XCTAssertEqual(SymbolOutline.scan(text, fileExtension: "java").map(\.name), ["Foo", "name", "count"])
    }
}

final class WorkspaceSymbolIndexTests: XCTestCase {
    func testIndexesTheProjectAndFollowsEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feather-symbols-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "export function alpha() {}\n".write(to: root.appendingPathComponent("src/a.ts"), atomically: true, encoding: .utf8)
        try "def beta():\n    pass\n".write(to: root.appendingPathComponent("b.py"), atomically: true, encoding: .utf8)
        try "not code".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let index = WorkspaceSymbolIndex()
        let first = expectation(description: "first scan")
        var entries: [WorkspaceSymbolIndex.Entry] = []
        index.entries(root: root) { entries = $0; first.fulfill() }
        wait(for: [first], timeout: 5)
        XCTAssertEqual(entries.map { "\($0.symbol.name)@\($0.path)" }, ["beta@b.py", "alpha@src/a.ts"])

        // A changed file is read again; the listing cache is what ProjectFiles keeps, so the file set is the same.
        sleep(1)                       // modification dates have one-second resolution on some file systems
        try "export function alpha() {}\nexport function gamma() {}\n".write(to: root.appendingPathComponent("src/a.ts"), atomically: true, encoding: .utf8)
        let second = expectation(description: "second scan")
        index.entries(root: root) { entries = $0; second.fulfill() }
        wait(for: [second], timeout: 5)
        XCTAssertEqual(entries.map(\.symbol.name), ["beta", "alpha", "gamma"])
    }

    func testItemText() {
        let entry = WorkspaceSymbolIndex.Entry(symbol: LSPSymbol(name: "run", kind: 12, container: nil, line: 9, character: 0, depth: 0), path: "src/x.ts")
        let item = WorkspaceSymbolIndex.item(for: entry)
        XCTAssertEqual(item.title, "run")
        XCTAssertEqual(item.detail, "function  src/x.ts:10")
    }
}

final class QuickOpenPrefixTests: XCTestCase {
    func testPrefixes() {
        XCTAssertEqual(QuickOpenController.prefixes, ["#", "@", ":"])
    }
}

// MARK: - More languages, depth and kinds (Language/SymbolOutline.swift)

/// The outline for the languages beyond TypeScript, Python and Java, and the depth, kind and column each symbol
/// is given.
final class SymbolOutlineLanguageTests: XCTestCase {
    private func outline(_ text: String, _ ext: String) -> [String] {
        SymbolOutline.scan(text, fileExtension: ext).map { "\($0.name):\($0.kind):\($0.depth)" }
    }

    func testKotlin() {
        let text = "class Repo {\n    fun load(): List<String> {\n    }\n    private val cache = mutableMapOf()\n}\nobject Config\ndata class User(val id: Int)\ninterface Store\n"
        XCTAssertEqual(outline(text, "kt"), ["Repo:5:0", "load:6:1", "Config:5:0", "User:5:0", "Store:11:0"])
    }

    func testSwift() {
        let text = "struct Point {\n    func moved() -> Point {\n    }\n}\nprotocol Shape {}\nextension Point {}\nenum Kind {}\nfunc top() {}\nactor Worker {}\ntypealias ID = Int\n@objc private func hidden() {}\n"
        XCTAssertEqual(outline(text, "swift"), ["Point:23:0", "moved:6:1", "Shape:11:0", "Point:5:0", "Kind:10:0", "top:12:0",
                                                "Worker:5:0", "ID:26:0", "hidden:12:0"])
    }

    func testGoWithReceivers() {
        // No package clause here: see testKnownGaps for what one does.
        let text = "import \"fmt\"\n\nfunc run() {\n}\n\ntype Server struct {\n}\n\nfunc (s *Server) Start() error {\n}\n"
        XCTAssertEqual(outline(text, "go"), ["run:12:0", "Server:26:0", "Start:12:0"])
    }

    func testRust() {
        let text = "pub fn run() {}\nstruct Item;\nimpl Item {\n    pub fn create() -> Self {\n    }\n}\ntrait Show {}\npub(crate) fn hidden() {}\n"
        XCTAssertEqual(outline(text, "rs"), ["run:12:0", "Item:23:0", "Item:5:0", "create:6:1", "Show:11:0", "hidden:12:0"])
    }

    /// Once gaps in the patterns; each is now expected to work.
    func testFormerGaps() {
        XCTAssertEqual(outline("package main\n\nfunc main() {\n}\n", "go"), ["main:12:0"])
        XCTAssertEqual(outline("package server\n\nfunc run() {\n}\n", "go"), ["run:12:0"])
        XCTAssertEqual(outline("impl A {\n    pub fn new() -> Self {\n    }\n}\n", "rs"), ["A:5:0", "new:6:1"])
        XCTAssertEqual(outline("mod inner {\n}\n", "rs"), ["inner:3:0"])
        // `new` in JavaScript is still a call, not a declaration.
        XCTAssertEqual(outline("class A {\n  run() {\n    const b = new Foo() {\n  }\n}\n", "js").map { $0.split(separator: ":").first! }, ["A", "run"])
    }

    func testRubyDartAndTypeScriptTypes() {
        XCTAssertEqual(outline("module Billing\n  class Invoice\n    def total\n    end\n  end\nend\ndef helper\nend\n", "rb").map { $0.split(separator: ":").first! },
                       ["Billing", "Invoice", "total", "helper"])
        XCTAssertEqual(outline("mixin Walker {}\nclass Dog with Walker {\n  void bark() {\n  }\n}\n", "dart"), ["Walker:5:0", "Dog:5:0", "bark:6:0"])
        XCTAssertEqual(outline("export type ID = string\nexport interface User {}\nenum Color {}\nnamespace App {}\nexport default class Main {}\n", "ts"),
                       ["ID:26:0", "User:11:0", "Color:10:0", "App:3:0", "Main:5:0"])
    }

    func testMarkdownHeadings() {
        let symbols = SymbolOutline.scan("# Title\n\n## Section ##\ntext\n### Deep\n#not a heading\n####### too many\n", fileExtension: "md")
        XCTAssertEqual(symbols.map { "\($0.name):\($0.depth):\($0.line)" }, ["Title:0:0", "Section:1:2", "Deep:2:4"])
        XCTAssertEqual(symbols.map(\.kind), [0, 0, 0])
        XCTAssertTrue(SymbolOutline.scan("function f() {}\n", fileExtension: "markdown").isEmpty)     // only headings count
    }

    func testControlFlowIsNotAMethod() {
        let script = "class A {\n  if (x) {\n  }\n  for (const y of z) {\n  }\n  real() {\n  }\n}\n"
        XCTAssertEqual(outline(script, "js"), ["A:5:0", "real:6:0"])
        let java = "class A {\n    else if (x) {\n    }\n    return foo(x) {\n    String name() {\n    }\n}\n"
        XCTAssertEqual(outline(java, "java"), ["A:5:0", "name:6:1"])
    }

    func testDepthCountsTabsAsTheTabWidthAndIsCapped() {
        let tabWidth = Settings.shared.tabWidth
        let tabbed = "class A {\n\tvoid run() {\n\t}\n}\n"
        XCTAssertEqual(outline(tabbed, "java"), ["A:5:0", "run:6:1"])
        let deep = String(repeating: " ", count: tabWidth * 9) + "def deep():\n"
        XCTAssertEqual(SymbolOutline.scan(deep, fileExtension: "py").first?.depth, 6)
        XCTAssertEqual(SymbolOutline.scan("  def shallow():\n", fileExtension: "py").first?.depth, 2 / tabWidth)
    }

    func testLineAndColumnAreUTF16Offsets() {
        let symbols = SymbolOutline.scan("// café 😀\nfunction go() {}\r\n  const naïve = () => 1\n", fileExtension: "ts")
        XCTAssertEqual(symbols.map { "\($0.name)@\($0.line):\($0.character)" }, ["go@1:9", "naïve@2:8"])
        XCTAssertEqual(symbols.map(\.container), [nil, nil])
    }

    func testEmptyAndUnknownFiles() {
        XCTAssertTrue(SymbolOutline.scan("", fileExtension: "ts").isEmpty)
        XCTAssertEqual(SymbolOutline.scan("def x():\n", fileExtension: "").map(\.name), ["x"])         // the generic patterns still apply
        XCTAssertEqual(SymbolOutline.scan("def x():\n", fileExtension: "PY").map(\.name), ["x"])
    }

    func testKindNames() {
        XCTAssertEqual(SymbolOutline.kindName(5), "class")
        XCTAssertEqual(SymbolOutline.kindName(6), "method")
        XCTAssertEqual(SymbolOutline.kindName(12), "function")
        XCTAssertEqual(SymbolOutline.kindName(23), "struct")
        XCTAssertEqual(SymbolOutline.kindName(26), "type")
        XCTAssertEqual(SymbolOutline.kindName(0), "")
        XCTAssertEqual(SymbolOutline.kindName(99), "")
    }
}

// MARK: - The workspace index (Language/WorkspaceSymbols.swift)

/// Which files the index reads, what it skips, and how a newer request supersedes an older one.
final class WorkspaceSymbolIndexFilterTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = TestSupport.temporaryDirectory("feather-workspace-symbols")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func entries(_ index: WorkspaceSymbolIndex, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        var result: [WorkspaceSymbolIndex.Entry]?
        index.entries(root: root) { result = $0 }
        XCTAssertTrue(TestSupport.wait { result != nil }, "the index never answered", file: file, line: line)
        return (result ?? []).map { "\($0.symbol.name)@\($0.path)" }
    }

    func testOnlyCodeFilesOutsideIgnoredFoldersAreIndexed() throws {
        try TestSupport.write([
            "run.sh": "function deploy() {\n  :\n}\n",
            "main.go": "func main() {\n}\n",
            "notes.md": "# Heading\n",
            "data.json": "{}",
            "node_modules/dep/index.js": "export function dep() {}\n",
            "build/out.py": "def built():\n    pass\n",
            ".hidden/secret.py": "def hidden():\n    pass\n",
            "src/Deep/Widget.KT": "fun widget() {}\n",
        ], under: root)
        XCTAssertEqual(entries(WorkspaceSymbolIndex()).sorted(), ["deploy@run.sh", "main@main.go", "widget@src/Deep/Widget.KT"])
        XCTAssertFalse(WorkspaceSymbolIndex.extensions.contains("md"))
        XCTAssertTrue(WorkspaceSymbolIndex.extensions.contains("sh"))
    }

    func testFilesThatAreTooBigAreSkipped() throws {
        let filler = String(repeating: "# padding line to make the file big\n", count: WorkspaceSymbolIndex.maxFileSize / 30)
        try TestSupport.write(["big.py": filler + "def needle():\n    pass\n", "small.py": "def small():\n    pass\n"], under: root)
        XCTAssertEqual(entries(WorkspaceSymbolIndex()), ["small@small.py"])
    }

    func testDeletedFilesLeaveTheIndexAndNewOnesJoinOnceTheListingIsRefreshed() throws {
        try TestSupport.write(["a.py": "def a():\n    pass\n", "b.py": "def b():\n    pass\n"], under: root)
        let index = WorkspaceSymbolIndex()
        XCTAssertEqual(entries(index).sorted(), ["a@a.py", "b@b.py"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.py"))
        try TestSupport.write(["c.py": "def c():\n    pass\n"], under: root)
        ProjectFiles.invalidate(root: root)               // what the file watcher does when the tree changes
        XCTAssertEqual(entries(index).sorted(), ["a@a.py", "c@c.py"])
    }

    func testANewerRequestSupersedesAnOlderOne() throws {
        try TestSupport.write(["a.py": "def a():\n    pass\n"], under: root)
        let index = WorkspaceSymbolIndex()
        var firstAnswered = false, secondAnswered = false
        index.entries(root: root) { _ in firstAnswered = true }
        index.entries(root: root) { _ in secondAnswered = true }
        XCTAssertTrue(TestSupport.wait { secondAnswered })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(firstAnswered)                     // only the newest answers
    }

    func testItemsShowKindContainerAndPlace() {
        let entry = WorkspaceSymbolIndex.Entry(symbol: LSPSymbol(name: "save", kind: 6, container: "UserService", line: 4, character: 2, depth: 1), path: "src/x.ts")
        XCTAssertEqual(WorkspaceSymbolIndex.item(for: entry).detail, "method in UserService  src/x.ts:5")
        let bare = WorkspaceSymbolIndex.Entry(symbol: LSPSymbol(name: "Title", kind: 0, container: "", line: 0, character: 0, depth: 0), path: "README.md")
        XCTAssertEqual(WorkspaceSymbolIndex.item(for: bare).detail, "README.md:1")
    }
}
