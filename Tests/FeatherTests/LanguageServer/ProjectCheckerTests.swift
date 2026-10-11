import XCTest
@testable import Feather

final class CheckerOutputTests: XCTestCase {
    func testTsc() {
        let output = """
        src/app.ts(12,5): error TS2322: Type 'string' is not assignable to type 'number'.
        src/lib/util.tsx(3,1): error TS2304: Cannot find name 'foo'.
          Did you mean 'for'?
        Found 2 errors in 2 files.
        """
        let problems = CheckerOutput.tsc(output)
        XCTAssertEqual(problems.count, 2)
        XCTAssertEqual(problems[0], CheckerProblem(path: "src/app.ts", line: 12, column: 5, severity: 1,
                                                   message: "Type 'string' is not assignable to type 'number'.", code: "TS2322"))
        XCTAssertEqual(problems[1].path, "src/lib/util.tsx")
        XCTAssertEqual(problems[1].message, "Cannot find name 'foo'.\nDid you mean 'for'?")
    }

    func testPyright() {
        let output = """
        {"version": "1.1.300", "generalDiagnostics": [
          {"file": "/p/app.py", "severity": "error", "message": "\\"foo\\" is not defined",
           "range": {"start": {"line": 2, "character": 4}, "end": {"line": 2, "character": 7}}, "rule": "reportUndefinedVariable"},
          {"file": "/p/app.py", "severity": "warning", "message": "Import \\"os\\" is not accessed",
           "range": {"start": {"line": 0, "character": 7}, "end": {"line": 0, "character": 9}}},
          {"file": "/p/app.py", "severity": "information", "message": "ignored",
           "range": {"start": {"line": 5, "character": 0}, "end": {"line": 5, "character": 1}}}
        ], "summary": {"errorCount": 1}}
        """
        let problems = CheckerOutput.pyright(output)
        XCTAssertEqual(problems.count, 2)
        XCTAssertEqual(problems[0], CheckerProblem(path: "/p/app.py", line: 3, column: 5, severity: 1, message: "\"foo\" is not defined",
                                                   code: "reportUndefinedVariable", endLine: 3, endColumn: 8))
        XCTAssertEqual(problems[1].severity, 2)
    }

    func testPyflakes() {
        let output = """
        ./app.py:1:1: 'os' imported but unused
        ./app.py:4:5: undefined name 'foo'
        ./bad.py:2:7: invalid syntax
            def f(:
                  ^
        lib/old.py:9: local variable 'x' is assigned to but never used
        """
        let problems = CheckerOutput.pyflakes(output)
        XCTAssertEqual(problems.map { "\($0.path):\($0.line):\($0.column):\($0.severity)" },
                       ["./app.py:1:1:2", "./app.py:4:5:1", "./bad.py:2:7:1", "lib/old.py:9:1:2"])
        XCTAssertEqual(problems[3].message, "local variable 'x' is assigned to but never used")
    }

    func testPyCompile() {
        // Exactly what python3 -m py_compile prints on this Mac (Python 3.14), and the older one-line form.
        let output = """
          File "bad.py", line 1
            def f(:
                  ^
        SyntaxError: invalid syntax
        Sorry: IndentationError: unexpected indent (other.py, line 3)
        """
        let problems = CheckerOutput.pyCompile(output)
        XCTAssertEqual(problems, [
            CheckerProblem(path: "bad.py", line: 1, column: 7, severity: 1, message: "invalid syntax", code: "SyntaxError"),
            CheckerProblem(path: "other.py", line: 3, column: 1, severity: 1, message: "unexpected indent", code: "IndentationError"),
        ])
    }

    func testMaven() {
        let output = """
        [ERROR] COMPILATION ERROR :
        [ERROR] /Users/me/app/src/main/java/com/acme/App.java:[12,17] cannot find symbol
        [ERROR]   symbol:   class Foo
        [ERROR]   location: class com.acme.App
        [WARNING] /Users/me/app/src/main/java/com/acme/Old.java:[3,1] [deprecation] thing() in Old has been deprecated
        [ERROR] Failed to execute goal org.apache.maven.plugins:maven-compiler-plugin:3.11.0:compile (default-compile) on project app: Compilation failure
        [ERROR] /Users/me/app/src/main/java/com/acme/App.java:[12,17] cannot find symbol
        [ERROR]   symbol:   class Foo
        """
        let problems = CheckerOutput.maven(output)
        XCTAssertEqual(problems.count, 2)
        XCTAssertEqual(problems[0].path, "/Users/me/app/src/main/java/com/acme/App.java")
        XCTAssertEqual(problems[0].line, 12)
        XCTAssertEqual(problems[0].column, 17)
        XCTAssertEqual(problems[0].message, "cannot find symbol\nsymbol:   class Foo\nlocation: class com.acme.App")
        XCTAssertEqual(problems[1].severity, 2)
    }

    func testJavacAsGradlePrintsIt() {
        let output = """
        /Users/me/app/src/main/java/com/acme/App.java:12: error: cannot find symbol
                Foo x = null;
                ^
          symbol:   class Foo
          location: class App
        /Users/me/app/src/main/java/com/acme/App.java:20: warning: [unchecked] unchecked call
                list.add(1);
                        ^
        2 errors
        """
        let problems = CheckerOutput.javac(output)
        XCTAssertEqual(problems.count, 2)
        XCTAssertEqual(problems[0].line, 12)
        XCTAssertEqual(problems[0].column, 9)
        XCTAssertEqual(problems[0].message, "cannot find symbol\nsymbol:   class Foo\nlocation: class App")
        XCTAssertEqual(problems[1].severity, 2)
        XCTAssertEqual(problems[1].column, 17)
    }

    func testDartMachineFormat() {
        // Exactly what `dart analyze --format=machine` printed on this Mac.
        let output = """
        ERROR|COMPILE_TIME_ERROR|INVALID_ASSIGNMENT|/p/lib/main.dart|2|11|7|A value of type 'String' can't be assigned to a variable of type 'int'.
        WARNING|STATIC_WARNING|UNUSED_LOCAL_VARIABLE|/p/lib/main.dart|3|7|1|The value of the local variable 'y' isn't used.
        INFO|LINT|PREFER_CONST|/p/lib/main.dart|4|3|5|Use const.
        ERROR|SYNTAX|X|/p/lib/a.dart|1|1|1|Expected '\\|' here.
        """
        let problems = CheckerOutput.dart(output)
        XCTAssertEqual(problems.count, 3)
        XCTAssertEqual(problems[0], CheckerProblem(path: "/p/lib/main.dart", line: 2, column: 11, severity: 1,
                                                   message: "A value of type 'String' can't be assigned to a variable of type 'int'.",
                                                   code: "invalid_assignment", endLine: 2, endColumn: 18))
        XCTAssertEqual(problems[1].severity, 2)
        XCTAssertEqual(problems[2].message, "Expected '|' here.")
    }

    func testSwiftBuild() {
        let output = """
        Building for debugging...
        /Users/me/pkg/Sources/App/main.swift:3:7: error: cannot find 'foo' in scope
        let x = foo
              ^~~
        /Users/me/pkg/Sources/App/main.swift:3:7: error: cannot find 'foo' in scope
        /Users/me/pkg/Sources/App/main.swift:5:5: warning: variable 'y' was never used; consider replacing with '_' or removing it
        error: fatalError
        """
        let problems = CheckerOutput.swift(output)
        XCTAssertEqual(problems.count, 2)
        XCTAssertEqual(problems[0], CheckerProblem(path: "/Users/me/pkg/Sources/App/main.swift", line: 3, column: 7, severity: 1, message: "cannot find 'foo' in scope"))
        XCTAssertEqual(problems[1].severity, 2)
    }

    func testDiagnosticsResolveRelativePathsAndZeroBasePositions() {
        let root = URL(fileURLWithPath: "/tmp/proj")
        let command = CheckerCommand(tool: .tsc, executable: "/bin/true", arguments: [], directory: root)
        let problems = [CheckerProblem(path: "src/a.ts", line: 12, column: 5, severity: 1, message: "m", code: "TS1"),
                        CheckerProblem(path: "/tmp/other/b.ts", line: 1, column: 1, severity: 2, message: "w", endLine: 1, endColumn: 4)]
        let diagnostics = ProjectChecker.diagnostics(from: problems, command: command)
        let a = diagnostics[URL(fileURLWithPath: "/tmp/proj/src/a.ts")]?.first
        XCTAssertEqual(a?.startLine, 11)
        XCTAssertEqual(a?.startCharacter, 4)
        XCTAssertEqual(a?.source, "tsc")
        XCTAssertEqual(a?.code, "TS1")
        let b = diagnostics[URL(fileURLWithPath: "/tmp/other/b.ts")]?.first
        XCTAssertEqual(b?.endCharacter, 3)
        XCTAssertEqual(b?.severity, 2)
    }
}

final class ProjectCheckerRunTests: XCTestCase {
    /// A stand-in checker: a shell script (not named after any real tool) that prints tsc-style lines.
    private func makeProject() throws -> (root: URL, script: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feather-checker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "const x: number = 'no';\n".write(to: root.appendingPathComponent("src/app.ts"), atomically: true, encoding: .utf8)
        let script = root.appendingPathComponent("feather-pretend-checker.sh")
        try """
        #!/bin/sh
        echo "src/app.ts(1,7): error TS2322: Type 'string' is not assignable to type 'number'."
        echo "  Did you mean something else?"
        echo "extra: $*" >&2
        exit 2
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (root, script)
    }

    func testRunParsesOutputIntoFileDiagnostics() throws {
        let (root, script) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = CheckerCommand(tool: .tsc, executable: script.path, arguments: ["--noEmit"], directory: root)
        let done = expectation(description: "run")
        var found: [CheckerProblem] = []
        var error: String?
        ProjectChecker.run(command) { problems, message in found = problems; error = message; done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertNil(error)                    // it exited 2, but it reported problems, which is what exit 2 means
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.message, "Type 'string' is not assignable to type 'number'.\nDid you mean something else?")
        let diagnostics = ProjectChecker.diagnostics(from: found, command: command)
        XCTAssertEqual(diagnostics[root.appendingPathComponent("src/app.ts").standardizedFileURL]?.first?.startCharacter, 6)
    }

    func testFailureWithoutProblemsIsReported() throws {
        let (root, _) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = CheckerCommand(tool: .swift, executable: "/bin/sh", arguments: ["-c", "echo 'boom: no tsconfig'; exit 1"], directory: root)
        let done = expectation(description: "run")
        var error: String?
        ProjectChecker.run(command) { _, message in error = message; done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(error, "swift exited with code 1: boom: no tsconfig")
    }

    func testCheckerRunsAndFeedsTheStoreOnTheMainThread() throws {
        let (root, script) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try "{}".write(to: root.appendingPathComponent("tsconfig.json"), atomically: true, encoding: .utf8)
        let checker = ProjectChecker()
        checker.find = { name in name == "tsc" ? script.path : nil }          // the pretend tool stands in for tsc
        checker.isAllowed = { _ in true }
        checker.root = root
        let store = ProblemsStore()
        let done = expectation(description: "results")
        var states: [String] = []
        checker.onStateChange = { states.append(checker.runningName ?? "-") }
        checker.onResults = { run in
            XCTAssertTrue(Thread.isMainThread)
            store.setChecker(run.name, run.diagnostics, scope: run.scope)
            done.fulfill()
        }
        var detected: [String] = []
        checker.checkProject { detected = $0.map(\.name) }
        wait(for: [done], timeout: 15)
        XCTAssertEqual(detected, ["tsc"])
        XCTAssertTrue(states.contains("tsc"))
        XCTAssertEqual(store.errorCount, 1)
        XCTAssertEqual(store.diagnostics[root.appendingPathComponent("src/app.ts").standardizedFileURL]?.first?.source, "tsc")
        XCTAssertEqual(checker.lastRun?.name, "tsc")
        XCTAssertFalse(checker.isRunning)
    }

    func testRestrictedFolderNeverRuns() throws {
        let (root, script) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try "{}".write(to: root.appendingPathComponent("tsconfig.json"), atomically: true, encoding: .utf8)
        let checker = ProjectChecker()
        checker.find = { _ in script.path }
        checker.isAllowed = { _ in false }
        checker.root = root
        var ran = false
        checker.onResults = { _ in ran = true }
        checker.checkProject()
        checker.fileSaved(root.appendingPathComponent("src/app.ts"))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.2))
        XCTAssertFalse(ran)
        XCTAssertFalse(checker.isRunning)
    }
}

final class ProblemsStoreTests: XCTestCase {
    private let a = URL(fileURLWithPath: "/p/a.ts"), b = URL(fileURLWithPath: "/p/b.ts")
    private func diagnostic(_ message: String, severity: Int = 1, source: String? = nil) -> LSPDiagnostic {
        LSPDiagnostic(startLine: 0, startCharacter: 0, endLine: 0, endCharacter: 1, severity: severity, message: message, source: source)
    }

    func testCheckerResultsStayUntilTheNextRunReplacesThem() {
        let store = ProblemsStore()
        var counts = 0
        store.onCountsChange = { counts += 1 }
        store.setChecker("tsc", [a: [diagnostic("one")], b: [diagnostic("two", severity: 2)]])
        XCTAssertEqual(store.errorCount, 1)
        XCTAssertEqual(store.warningCount, 1)
        // A server stopping prunes nothing of the checker's.
        store.prune { _ in false }
        XCTAssertEqual(store.diagnostics.count, 2)
        // The next run says b is fine now.
        store.setChecker("tsc", [a: [diagnostic("one")]])
        XCTAssertNil(store.diagnostics[b])
        XCTAssertEqual(store.warningCount, 0)
        XCTAssertEqual(counts, 2)
    }

    func testAServerSpeakingForAFileWins() {
        let store = ProblemsStore()
        var changed: [[URL]] = []
        store.onCheckerChange = { changed.append($0.sorted { $0.path < $1.path }) }
        store.setChecker("tsc", [a: [diagnostic("from tsc")], b: [diagnostic("b from tsc")]])
        store.set([diagnostic("from server", source: "ts")], for: a)
        XCTAssertEqual(store.diagnostics[a]?.map(\.message), ["from server"])       // no duplicate
        XCTAssertEqual(store.errorCount, 2)
        XCTAssertTrue(store.isSpokenForByServer(a))
        // The server clears the file: still its word, so the checker's stale row does not come back.
        store.set([], for: a)
        XCTAssertNil(store.diagnostics[a])
        XCTAssertEqual(store.errorCount, 1)
        // The server goes away: the checker's result shows again until its next run.
        store.prune { _ in false }
        XCTAssertEqual(store.diagnostics[a]?.map(\.message), ["from tsc"])
        XCTAssertFalse(store.isSpokenForByServer(a))
        XCTAssertEqual(changed, [[a, b], [a], [a]])
    }

    func testPerFileScopeReplacesOnlyThoseFiles() {
        let store = ProblemsStore()
        store.setChecker("py_compile", [a: [diagnostic("a")], b: [diagnostic("b")]])
        store.setChecker("py_compile", [:], scope: [a])
        XCTAssertNil(store.diagnostics[a])
        XCTAssertEqual(store.diagnostics[b]?.count, 1)
        store.clearCheckers()
        XCTAssertTrue(store.diagnostics.isEmpty)
        XCTAssertEqual(store.errorCount, 0)
    }

    func testTwoCheckersOnOneFileAreBothListed() {
        let store = ProblemsStore()
        store.setChecker("pyflakes", [a: [diagnostic("unused", severity: 2)]])
        store.setChecker("mvn", [a: [diagnostic("odd but possible")]])
        XCTAssertEqual(store.diagnostics[a]?.count, 2)
        XCTAssertEqual(store.checkerNames(for: a), ["mvn", "pyflakes"])
    }
}
