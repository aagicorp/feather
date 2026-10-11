import XCTest
@testable import Feather

/// Covers Language/SymbolFinder.swift on small fixture projects: following JavaScript/TypeScript and Python
/// imports to the file that declares a name, finding a declaration in the file itself (skipping the line that
/// was clicked), searching the project by language family, and the cases that answer nothing.
final class SymbolFinderTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = TestSupport.temporaryDirectory("feather-symbols")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// Runs the finder for `word` as clicked in `file` (with its current contents) and waits for the answer.
    private func find(_ word: String, in file: String, line: Int = 0, root: URL? = nil, cancelled: Bool = false,
                      timeout: TimeInterval = 5) throws -> LSPLocation? {
        let url = self.root.appendingPathComponent(file)
        let text = try String(contentsOf: url, encoding: .utf8)
        var result: LSPLocation??
        SymbolFinder.find(word, from: url, text: text, clickedLine: line, root: root ?? self.root, isCancelled: { cancelled }) { result = .some($0) }
        XCTAssertTrue(TestSupport.wait(upTo: timeout) { result != nil }, "no answer for \(word)")
        return result ?? nil
    }

    private func place(_ location: LSPLocation?) -> String? {
        guard let location else { return nil }
        let path = location.url.path.replacingOccurrences(of: root.path + "/", with: "")
        return "\(path):\(location.line):\(location.character)-\(location.endCharacter)"
    }

    // MARK: - In the same file

    func testDeclarationsInTheSameFile() throws {
        try TestSupport.write(["a.ts": """
        import { unrelated } from "./other"
        export function loadUsers(id: number) { return id }
        const handleClick = async (e: Event) => { }
        class UserService {
          public async save(user: User): Promise<void> {
          }
        }
        loadUsers(1); handleClick(); new UserService().save(u)
        """], under: root)
        XCTAssertEqual(place(try find("loadUsers", in: "a.ts", line: 7)), "a.ts:1:16-25")
        XCTAssertEqual(place(try find("handleClick", in: "a.ts", line: 7)), "a.ts:2:6-17")
        XCTAssertEqual(place(try find("UserService", in: "a.ts", line: 7)), "a.ts:3:6-17")
        XCTAssertNil(try find("save", in: "a.ts", line: 7))                 // a method with a return type is beyond the patterns
    }

    func testTheClickedLineItselfIsSkipped() throws {
        try TestSupport.write(["a.py": "def alpha():\n    pass\n"], under: root)
        XCTAssertEqual(place(try find("alpha", in: "a.py", line: 1)), "a.py:0:4-9")
        XCTAssertNil(try find("alpha", in: "a.py", line: 0))                 // clicked on the declaration: nowhere else to go
    }

    func testWordsThatAreNotNamesAnswerAtOnce() throws {
        try TestSupport.write(["a.ts": "const x = 1\n"], under: root)
        XCTAssertNil(try find("", in: "a.ts"))
        XCTAssertNil(try find("a-b", in: "a.ts"))
        XCTAssertNil(try find("1st", in: "a.ts"))
        XCTAssertNil(try find("x", in: "a.ts", cancelled: true))
    }

    // MARK: - Following imports

    func testScriptImportsAreFollowedToTheDeclaration() throws {
        try TestSupport.write([
            "src/app.ts": "import { helper, other as o } from \"./lib/util\"\nimport Thing from './thing'\nconst { req } = require(\"./req\")\nhelper(); o(); Thing; req\n",
            "src/lib/util.ts": "// util\nexport function helper() {}\nexport const other = () => {}\n",
            "src/thing.tsx": "export default function () {}\n",
            "src/req/index.js": "module.exports = { req: 1 }\n",
        ], under: root)
        XCTAssertEqual(place(try find("helper", in: "src/app.ts", line: 3)), "src/lib/util.ts:1:16-22")
        XCTAssertEqual(place(try find("Thing", in: "src/app.ts", line: 3)), "src/thing.tsx:0:0-0")      // a default export: the top of the file
        XCTAssertEqual(place(try find("req", in: "src/app.ts", line: 3)), "src/req/index.js:0:0-0")     // "./req" means req/index.js
        // "other as o": the import brings "o" in, so it is looked up there, but the file declares "other".
        XCTAssertEqual(place(try find("o", in: "src/app.ts", line: 3)), "src/lib/util.ts:0:0-0")
    }

    func testAliasImportsResolveAgainstThePackageRoot() throws {
        try TestSupport.write([
            "package.json": "{}",
            "src/pages/home.tsx": "import { User } from \"@/models/user\"\nimport { fmt } from \"~/util\"\nUser; fmt\n",
            "src/models/user.ts": "export interface User { id: number }\n",
            "util.ts": "export function fmt() {}\n",
        ], under: root)
        XCTAssertEqual(place(try find("User", in: "src/pages/home.tsx", line: 2)), "src/models/user.ts:0:17-21")
        XCTAssertEqual(place(try find("fmt", in: "src/pages/home.tsx", line: 2)), "util.ts:0:16-19")
    }

    func testPackagesFromNodeModulesAreNotFollowed() throws {
        try TestSupport.write([
            "app.ts": "import { useState } from \"react\"\nuseState()\n",
            "node_modules/react/index.js": "export function useState() {}\n",
        ], under: root)
        XCTAssertNil(try find("useState", in: "app.ts", line: 1))
    }

    func testPythonImportsWalkUpToTheProjectRoot() throws {
        try TestSupport.write([
            "app/main.py": "from services.billing import (charge,\n    refund)\nfrom services import helper\ncharge(); helper()\n",
            "services/billing.py": "def charge(amount):\n    pass\n",
            "services/__init__.py": "def helper():\n    pass\n",
        ], under: root)
        XCTAssertEqual(place(try find("charge", in: "app/main.py", line: 3)), "services/billing.py:0:4-10")
        XCTAssertEqual(place(try find("helper", in: "app/main.py", line: 3)), "services/__init__.py:0:4-10")
    }

    // MARK: - Across the project

    func testProjectSearchPrefersFilesNamedAfterTheSymbolAndStaysInTheFamily() throws {
        try TestSupport.write([
            "pages/index.jsx": "<Widget />\n",
            "components/Widget.tsx": "export const Widget = () => <div />\n",
            "lib/mixed.ts": "export function Widget() {}\n",
            "scripts/tool.py": "def Widget():\n    pass\n",
            "node_modules/lib/Widget.js": "export function Widget() {}\n",
        ], under: root)
        XCTAssertEqual(place(try find("Widget", in: "pages/index.jsx")), "components/Widget.tsx:0:13-19")
        try TestSupport.write(["other.py": "Widget()\n"], under: root)
        ProjectFiles.invalidate(root: root)
        XCTAssertEqual(place(try find("Widget", in: "other.py")), "scripts/tool.py:0:4-10")            // Python looks at Python
        try TestSupport.write(["lonely.rb": "Widget\n"], under: root)
        ProjectFiles.invalidate(root: root)
        XCTAssertNil(try find("Widget", in: "lonely.rb"))
    }

    func testProjectSearchNeedsARootAndSkipsTheFileItself() throws {
        try TestSupport.write(["a.go": "run()\n", "b.go": "func run() {\n}\n"], under: root)
        XCTAssertEqual(place(try find("run", in: "a.go")), "b.go:0:5-8")
        XCTAssertEqual(place(try find("run", in: "b.go", line: 0)), nil)          // its own line is skipped, nothing else declares it
        let text = try String(contentsOf: root.appendingPathComponent("a.go"), encoding: .utf8)
        var answered = false
        var found: LSPLocation?
        SymbolFinder.find("run", from: root.appendingPathComponent("a.go"), text: text, clickedLine: 0, root: nil) { found = $0; answered = true }
        XCTAssertTrue(TestSupport.wait { answered })
        XCTAssertNil(found)
    }

    func testTypedMethodsAndSwiftDeclarations() throws {
        try TestSupport.write([
            "Main.java": "public class Main { static void go() { Service.fetch(); } }\n",
            "Service.java": "public class Service {\n    public static List<String> fetch() throws IOException {\n    }\n}\n",
            "App.swift": "let p = Point()\n",
            "Point.swift": "public struct Point {\n    mutating func move() {}\n}\n",
        ], under: root)
        XCTAssertEqual(place(try find("fetch", in: "Main.java")), "Service.java:1:31-36")
        XCTAssertEqual(place(try find("Point", in: "App.swift")), "Point.swift:0:14-19")
        XCTAssertEqual(place(try find("Service", in: "Main.java")), "Service.java:0:13-20")
    }
}
