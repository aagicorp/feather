import XCTest
@testable import Feather

/// Project/ProjectTasks.swift: what Run ▸ Run Task… finds in a folder (npm scripts, Maven goals, Gradle,
/// Flutter and Dart, pytest, Django, FastAPI, Makefile targets, the project's own custom tasks), the subfolders
/// of a monorepo, the manifest signature, the tab titles, and the "recently run" ordering.
final class MakeTargetsTests: XCTestCase {
    func testPlainTargetsInOrderWithoutDuplicates() {
        let makefile = """
        build: deps
        \tgo build ./...
        test:
        \tgo test ./...
        build:
        \techo again
        """
        XCTAssertEqual(TaskDiscovery.makeTargets(in: makefile), ["build", "test"])
    }

    func testSpecialsVariablesAndPatternRulesAreLeftOut() {
        let makefile = """
        # a comment: with a colon
        .PHONY: build test
        CC := gcc
        CFLAGS ::= -O2
        VERSION = 1.0
        %.o: %.c
        \t$(CC) -c $<
        $(TARGET): main.o
        \t$(CC) -o $@ $<
          indented: nope
        ifeq ($(OS),Windows_NT)
        endif
        build: main.o
        deploy staging: build
        """
        XCTAssertEqual(TaskDiscovery.makeTargets(in: makefile), ["build", "deploy", "staging"])
    }

    func testEmptyAndOddInput() {
        XCTAssertEqual(TaskDiscovery.makeTargets(in: ""), [])
        XCTAssertEqual(TaskDiscovery.makeTargets(in: "no targets here\n"), [])
        XCTAssertEqual(TaskDiscovery.makeTargets(in: "run:\r\nclean:\r\n"), ["run", "clean"])
        XCTAssertEqual(TaskDiscovery.makeTargets(in: "déploy-ünïcödé: build"), ["déploy-ünïcödé"])
    }
}

final class TaskDiscoveryTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = TestSupport.temporaryDirectory("feather-tasks")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func tasks(_ files: [String: String]) throws -> [ProjectTask] {
        try TestSupport.write(files, under: root)
        return TaskDiscovery.tasks(inFolder: root)
    }

    private func names(_ files: [String: String]) throws -> [String] { try tasks(files).map(\.name) }

    func testAnEmptyFolderHasNoTasks() {
        XCTAssertEqual(TaskDiscovery.tasks(inFolder: root), [])
        XCTAssertEqual(TaskDiscovery.tasks(in: root), [])
    }

    func testNPMScriptsAreSortedAndFollowedByInstall() throws {
        let found = try tasks(["package.json": #"{ "scripts": { "test": "jest", "build": "tsc", "dev": "vite", "weird": 3 } }"#])
        XCTAssertEqual(found.map(\.name), ["build", "dev", "test", "install"])
        XCTAssertEqual(found.map(\.command), ["npm run build", "npm run dev", "npm run test", "npm install"])
        XCTAssertTrue(found.allSatisfy { $0.source == "npm" })
        XCTAssertTrue(found.allSatisfy { $0.directory.path == root.path })
    }

    func testThePackageManagerComesFromTheLockFile() throws {
        XCTAssertEqual(try tasks(["package.json": #"{ "scripts": { "dev": "x" } }"#, "pnpm-lock.yaml": ""]).map(\.command), ["pnpm run dev", "pnpm install"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("pnpm-lock.yaml"))
        XCTAssertEqual(try tasks(["yarn.lock": ""]).map(\.source), ["yarn", "yarn"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("yarn.lock"))
        XCTAssertEqual(try tasks(["bun.lockb": ""]).map(\.command), ["bun run dev", "bun install"])
    }

    func testABrokenPackageJSONHasNoScriptsAndNoInstall() throws {
        XCTAssertEqual(try names(["package.json": "{ broken", "Makefile": "build:\n\tmake it\n"]), ["make build"])
        XCTAssertEqual(try names(["package.json": "{}"]), ["install", "make build"], "valid but without scripts")
    }

    func testMavenGoalsAndSpringBoot() throws {
        XCTAssertEqual(try names(["pom.xml": "<project/>"]), ["clean", "compile", "test", "package", "verify"])
        XCTAssertEqual(try tasks([:]).first?.command, "mvn clean")
        let spring = try tasks(["pom.xml": "<plugin><artifactId>spring-boot-maven-plugin</artifactId></plugin>", "mvnw": ""])
        XCTAssertEqual(spring.last?.name, "spring-boot:run")
        XCTAssertEqual(spring.last?.command, "./mvnw spring-boot:run")
        XCTAssertTrue(spring.allSatisfy { $0.source == "Maven" && $0.command.hasPrefix("./mvnw ") })
    }

    func testGradleTasksAndSpringBoot() throws {
        XCTAssertEqual(try tasks(["build.gradle": ""]).map(\.command), ["gradle build", "gradle test", "gradle clean"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("build.gradle"))
        let spring = try tasks(["build.gradle.kts": "id(\"org.springframework.boot\")", "gradlew": ""])
        XCTAssertEqual(spring.map(\.command), ["./gradlew build", "./gradlew test", "./gradlew clean", "./gradlew bootRun"])
        XCTAssertTrue(spring.allSatisfy { $0.source == "Gradle" })
    }

    func testFlutterIsToldFromDart() throws {
        XCTAssertEqual(try tasks(["pubspec.yaml": "name: tool\n"]).map(\.command), ["dart run", "dart test", "dart pub get", "dart analyze"])
        XCTAssertEqual(try tasks(["pubspec.yaml": "name: app\ndependencies:\n  flutter:\n    sdk: flutter\n"]).map(\.source), Array(repeating: "Flutter", count: 4))
        XCTAssertEqual(try tasks(["pubspec.yaml": "name: app\nflutter:\n  uses-material-design: true\n"]).first?.command, "flutter run")
        XCTAssertEqual(try tasks(["pubspec.yaml": "flutter:\n  assets: []\n"]).first?.source, "Flutter")
        XCTAssertEqual(try tasks(["pubspec.yaml": "name: not_flutter_yet\n# flutter: mentioned in a comment only\n"]).first?.source, "Dart",
                       "an indented mention is not the top-level key")
    }

    func testPytestIsFoundByAnyOfItsConfigurations() throws {
        XCTAssertEqual(try names(["pyproject.toml": "[tool.poetry]\n"]), [])
        XCTAssertEqual(try names(["pyproject.toml": "[tool.pytest.ini_options]\n"]), ["pytest"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("pyproject.toml"))
        XCTAssertEqual(try names(["setup.cfg": "[tool:pytest]\n"]), ["pytest"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("setup.cfg"))
        XCTAssertEqual(try names(["tox.ini": "[pytest]\n"]), ["pytest"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("tox.ini"))
        XCTAssertEqual(try names(["conftest.py": ""]), ["pytest"])
        XCTAssertEqual(try tasks(["pytest.ini": ""]).count, 1, "found twice over, listed once")
        XCTAssertEqual(try tasks([:]).first?.source, "Python")
    }

    func testDjangoAndFastAPI() throws {
        XCTAssertEqual(try tasks(["manage.py": ""]).map(\.command), ["python3 manage.py runserver"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("manage.py"))
        XCTAssertEqual(try tasks(["main.py": "from fastapi import FastAPI\napp = FastAPI()\n"]).map(\.command), ["uvicorn main:app --reload"])
        XCTAssertEqual(try tasks(["main.py": "import fastapi\napi: fastapi.FastAPI = fastapi.FastAPI(title='x')\n"]).map(\.command), ["uvicorn main:api --reload"])
        XCTAssertEqual(try tasks(["main.py": "def make():\n    app = FastAPI()\n"]), [], "only a module-level app can be served")
        try FileManager.default.removeItem(at: root.appendingPathComponent("main.py"))
        let nested = try tasks(["app/main.py": "server = FastAPI()\n"])
        XCTAssertEqual(nested.map(\.command), ["uvicorn app.main:server --reload"])
        XCTAssertEqual(nested.first?.name, "uvicorn")
        XCTAssertEqual(nested.first?.source, "FastAPI")
    }

    func testMakefileTargetsAndWhichMakefileWins() throws {
        XCTAssertEqual(try tasks(["Makefile": "build:\n\techo\ntest: build\n\techo\n"]).map(\.command), ["make build", "make test"])
        XCTAssertEqual(try tasks(["GNUmakefile": "gnu:\n\techo\n"]).map(\.name), ["make gnu"], "GNU make reads GNUmakefile first")
        XCTAssertEqual(try tasks([:]).first?.source, "Make")
    }

    func testEverythingAtOnceKeepsAFixedOrder() throws {
        let sources = try tasks(["package.json": #"{ "scripts": { "dev": "x" } }"#, "pom.xml": "", "build.gradle": "", "pubspec.yaml": "",
                                 "pytest.ini": "", "manage.py": "", "main.py": "app = FastAPI()", "Makefile": "all:\n"]).map(\.source)
        XCTAssertEqual(sources, ["npm", "npm", "Maven", "Maven", "Maven", "Maven", "Maven", "Gradle", "Gradle", "Gradle",
                                 "Dart", "Dart", "Dart", "Dart", "Python", "Django", "FastAPI", "Make"])
    }

    // MARK: - The whole project

    func testTheProjectFolderAndItsDirectSubfoldersAreSearched() throws {
        try TestSupport.write(["Makefile": "all:\n", "backend/pom.xml": "", "frontend/package.json": #"{ "scripts": { "dev": "x" } }"#,
                               "frontend/deep/package.json": #"{ "scripts": { "ignored": "x" } }"#, "node_modules/dep/package.json": #"{ "scripts": { "no": "x" } }"#,
                               ".hidden/Makefile": "hidden:\n", "build/Makefile": "built:\n", "plain.txt": ""], under: root)
        XCTAssertEqual(TaskDiscovery.folders(in: root).map(\.lastPathComponent), [root.lastPathComponent, "backend", "frontend"])
        let found = TaskDiscovery.tasks(in: root)
        XCTAssertEqual(found.map(\.name), ["make all", "clean", "compile", "test", "package", "verify", "dev", "install"])
        XCTAssertEqual(found.map { $0.folder(relativeTo: root) }, ["", "backend", "backend", "backend", "backend", "backend", "frontend", "frontend"])
        XCTAssertEqual(found.map { $0.title(relativeTo: root) }.first, "make all")
        XCTAssertEqual(found.map { $0.title(relativeTo: root) }.last, "install (frontend)")
    }

    func testCustomTasksComeFirstAndMayNameAFolder() throws {
        try TestSupport.write([".feather/settings.json": #"{ "tasks": [{ "name": "Seed", "command": "make seed", "cwd": "backend" }, { "name": "Lint", "command": "npm run lint" }] }"#,
                               "backend/Makefile": "seed:\n", "package.json": #"{ "scripts": { "dev": "x" } }"#], under: root)
        let found = TaskDiscovery.tasks(in: root)
        XCTAssertEqual(found.map(\.name), ["Seed", "Lint", "dev", "install", "make seed"])
        XCTAssertEqual(found[0].source, "Custom")
        XCTAssertEqual(found[0].directory.path, root.appendingPathComponent("backend").path)
        XCTAssertEqual(found[0].title(relativeTo: root), "Seed (backend)")
        XCTAssertEqual(found[1].directory.path, root.path)
        XCTAssertEqual(found[0].shellCommand, "cd \(TerminalPaneController.quote(root.appendingPathComponent("backend").path)) && make seed")
        XCTAssertEqual(TaskDiscovery.customTasks(in: root).count, 2)
    }

    func testAFastAPIAppInASubfolderIsNotListedTwice() throws {
        try TestSupport.write(["app/main.py": "app = FastAPI()\n", "app/__init__.py": ""], under: root)
        let found = TaskDiscovery.tasks(in: root)
        XCTAssertEqual(found.map(\.command), ["uvicorn app.main:app --reload"])
        XCTAssertEqual(found.first?.directory.path, root.path, "served from the project folder, where the module path holds")
    }

    func testPathsSpelledDifferentlyStillCountAsTheProjectFolder() throws {
        try TestSupport.write(["api/Makefile": "run:\n"], under: root)
        let task = try XCTUnwrap(TaskDiscovery.tasks(in: root).first)
        // /var and /private/var are the same folder; a folder elsewhere is shown in full.
        let alias = root.path.hasPrefix("/private/") ? URL(fileURLWithPath: String(root.path.dropFirst("/private".count)))
            : URL(fileURLWithPath: "/private" + root.path)
        XCTAssertEqual(task.folder(relativeTo: alias), "api")
        XCTAssertEqual(task.folder(relativeTo: URL(fileURLWithPath: "/elsewhere")), root.appendingPathComponent("api").path)
    }

    func testTheSignatureFollowsTheManifests() throws {
        try TestSupport.write(["package.json": "{}", "src/index.js": ""], under: root)
        let first = TaskDiscovery.signature(of: root)
        XCTAssertTrue(first.contains("package.json"))
        try TestSupport.write(["src/index.js": "changed"], under: root)
        XCTAssertEqual(TaskDiscovery.signature(of: root), first, "source files are not manifests")
        try TestSupport.write(["package.json": "{ \"scripts\": {} }"], under: root)
        XCTAssertNotEqual(TaskDiscovery.signature(of: root), first, "a bigger manifest is a different signature")
        let grown = TaskDiscovery.signature(of: root)
        try TestSupport.write(["api/pom.xml": ""], under: root)
        XCTAssertNotEqual(TaskDiscovery.signature(of: root), grown, "a manifest in a subfolder counts")
        XCTAssertEqual(TaskDiscovery.signature(of: TestSupport.temporaryDirectory("feather-empty")), "")
    }
}

final class ProjectTaskListTests: XCTestCase {
    private func task(_ name: String, in folder: String = "/p") -> ProjectTask {
        ProjectTask(name: name, command: "run \(name)", directory: URL(fileURLWithPath: folder), source: "test")
    }

    func testRecentlyRunTasksFloatToTheTopInOrder() {
        let all = [task("a"), task("b"), task("c"), task("d")]
        XCTAssertEqual(ProjectTaskList.ordered(all, recents: []).map(\.name), ["a", "b", "c", "d"])
        XCTAssertEqual(ProjectTaskList.ordered(all, recents: [task("c"), task("a")]).map(\.name), ["c", "a", "b", "d"])
        XCTAssertEqual(ProjectTaskList.ordered(all, recents: [task("zzz"), task("d")]).map(\.name), ["d", "a", "b", "c"], "a recent that no longer exists is ignored")
        XCTAssertEqual(ProjectTaskList.ordered(all, recents: [task("b", in: "/other")]).map(\.name), ["a", "b", "c", "d"], "the same command in another folder is another task")
    }

    func testRecentsAreRememberedPerProjectAndCapped() {
        let root = TestSupport.temporaryDirectory("feather-recents")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(ProjectTaskList.recents(for: root), [])
        for index in 1...10 { ProjectTaskList.noteRun(task("t\(index)"), in: root) }
        let recents = ProjectTaskList.recents(for: root)
        XCTAssertEqual(recents.count, 8, "only the last eight are kept")
        XCTAssertEqual(recents.first?.name, "t10")
        XCTAssertEqual(recents.first?.command, "run t10")
        XCTAssertEqual(recents.first?.directory.path, "/p")
        XCTAssertEqual(recents.first?.source, "test")
        // Running one again moves it to the top rather than adding it twice.
        ProjectTaskList.noteRun(task("t5"), in: root)
        XCTAssertEqual(ProjectTaskList.recents(for: root).map(\.name).prefix(2), ["t5", "t10"])
        XCTAssertEqual(ProjectTaskList.recents(for: root).filter { $0.name == "t5" }.count, 1)
        XCTAssertEqual(ProjectTaskList.recents(for: TestSupport.temporaryDirectory("feather-recents")), [], "another project has its own list")
    }

    func testTheListRefreshesOnlyWhenAManifestChanges() throws {
        let root = TestSupport.temporaryDirectory("feather-tasklist")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.write(["Makefile": "build:\n"], under: root)
        let list = ProjectTaskList()
        XCTAssertTrue(list.tasks.isEmpty)
        var delivered: [ProjectTask]?
        list.refresh { delivered = $0 }
        XCTAssertEqual(delivered, [], "no folder yet")
        list.setRoot(root)
        delivered = nil
        list.refresh { delivered = $0 }
        XCTAssertTrue(TestSupport.wait { delivered != nil })
        XCTAssertEqual(delivered?.map(\.name), ["make build"])
        XCTAssertEqual(list.tasks.map(\.name), ["make build"])
        try TestSupport.write(["Makefile": "build:\ntest:\n"], under: root)
        delivered = nil
        list.refresh { delivered = $0 }
        XCTAssertTrue(TestSupport.wait { delivered != nil })
        XCTAssertEqual(delivered?.map(\.name), ["make build", "make test"])
        // A folder change empties the list until the next refresh; an old answer is dropped.
        list.setRoot(nil)
        XCTAssertTrue(list.tasks.isEmpty)
    }
}
