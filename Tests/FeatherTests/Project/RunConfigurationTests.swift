import XCTest
@testable import Feather

/// Project/RunConfiguration.swift: which command ⌘R runs, worked out from fixture folders (Node with each
/// package manager, Next.js, Maven and Gradle with and without Spring Boot, Flutter and Dart, Django, Swift,
/// Cargo, Go), the `.feather/settings.json` override, walking up from the file being edited in a monorepo, and
/// running the current file by its extension.
final class RunConfigurationTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = TestSupport.temporaryDirectory("feather-run")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func detect(files: [String: String], currentFile: String? = nil) throws -> RunConfiguration? {
        try TestSupport.write(files, under: root)
        return RunConfiguration.detectProject(root: root, currentFile: currentFile.map { root.appendingPathComponent($0) })
    }

    private func command(_ files: [String: String], currentFile: String? = nil) throws -> String? {
        try detect(files: files, currentFile: currentFile)?.command
    }

    func testNothingRecognisedIsNil() throws {
        XCTAssertNil(try detect(files: ["README.md": "hi\n"]))
        XCTAssertNil(RunConfiguration.detectProject(root: nil, currentFile: nil))
    }

    func testNodeScriptsAndPackageManagers() throws {
        let package = #"{ "scripts": { "dev": "vite", "start": "node ." } }"#
        let found = try detect(files: ["package.json": package])
        XCTAssertEqual(found?.title, "Node")
        XCTAssertEqual(found?.command, "npm run dev")
        XCTAssertEqual(found?.directory.path, root.path)
        XCTAssertEqual(try command(["package.json": package, "pnpm-lock.yaml": ""]), "pnpm run dev")
        try FileManager.default.removeItem(at: root.appendingPathComponent("pnpm-lock.yaml"))
        XCTAssertEqual(try command(["yarn.lock": ""]), "yarn run dev")
        try FileManager.default.removeItem(at: root.appendingPathComponent("yarn.lock"))
        XCTAssertEqual(try command(["bun.lock": ""]), "bun run dev")
    }

    func testNodeScriptOrderAndNextJS() throws {
        XCTAssertEqual(try command(["package.json": #"{ "scripts": { "start": "x", "serve": "y" } }"#]), "npm run start")
        XCTAssertEqual(try command(["package.json": #"{ "scripts": { "serve": "y", "test": "z" } }"#]), "npm run serve")
        XCTAssertNil(try command(["package.json": #"{ "scripts": { "test": "z" } }"#]), "no runnable script, no command")
        XCTAssertNil(try command(["package.json": "{ not json"]))
        let next = try detect(files: ["package.json": #"{ "scripts": { "dev": "next dev" }, "dependencies": { "next": "14" } }"#])
        XCTAssertEqual(next?.title, "Next.js")
        XCTAssertEqual(next?.command, "npm run dev")
    }

    func testMavenAndSpringBoot() throws {
        let plain = try detect(files: ["pom.xml": "<project></project>"])
        XCTAssertEqual(plain?.title, "Maven")
        XCTAssertEqual(plain?.command, "mvn compile exec:java")
        let spring = try detect(files: ["pom.xml": "<project><parent><artifactId>spring-boot-starter-parent</artifactId></parent></project>"])
        XCTAssertEqual(spring?.title, "Spring Boot")
        XCTAssertEqual(spring?.command, "mvn spring-boot:run")
        XCTAssertEqual(try command(["mvnw": "#!/bin/sh\n"]), "./mvnw spring-boot:run")
    }

    func testGradleAndSpringBoot() throws {
        XCTAssertEqual(try detect(files: ["build.gradle": "plugins {}"])?.title, "Gradle")
        XCTAssertEqual(try command(["build.gradle": "plugins {}"]), "gradle run")
        XCTAssertEqual(try command(["gradlew": "#!/bin/sh\n"]), "./gradlew run")
        try FileManager.default.removeItem(at: root.appendingPathComponent("build.gradle"))
        let spring = try detect(files: ["build.gradle.kts": "plugins { id(\"org.springframework.boot\") }"])
        XCTAssertEqual(spring?.title, "Spring Boot")
        XCTAssertEqual(spring?.command, "./gradlew bootRun")
    }

    func testFlutterAndDart() throws {
        let flutter = try detect(files: ["pubspec.yaml": "name: app\ndependencies:\n  flutter:\n    sdk: flutter\n"])
        XCTAssertEqual(flutter?.title, "Flutter")
        XCTAssertEqual(flutter?.command, "flutter run")
        let dart = try detect(files: ["pubspec.yaml": "name: tool\ndependencies:\n  args: ^2.0.0\n"])
        XCTAssertEqual(dart?.title, "Dart")
        XCTAssertEqual(dart?.command, "dart run")
    }

    func testDjangoSwiftCargoAndGo() throws {
        XCTAssertEqual(try command(["manage.py": "#!/usr/bin/env python\n"]), "python3 manage.py runserver")
        try FileManager.default.removeItem(at: root.appendingPathComponent("manage.py"))
        XCTAssertEqual(try detect(files: ["Package.swift": "// swift-tools-version:5.9\n"])?.title, "Swift")
        XCTAssertEqual(try command([:]), "swift run")
        try FileManager.default.removeItem(at: root.appendingPathComponent("Package.swift"))
        XCTAssertEqual(try command(["Cargo.toml": "[package]\n"]), "cargo run")
        try FileManager.default.removeItem(at: root.appendingPathComponent("Cargo.toml"))
        XCTAssertEqual(try command(["go.mod": "module example.com/x\n"]), "go run .")
    }

    func testMarkersAreCheckedInAFixedOrder() throws {
        // Everything at once: the mobile app wins over the backend, which wins over the web app.
        let all = ["pubspec.yaml": "name: x\n", "pom.xml": "<project/>", "build.gradle": "", "package.json": #"{ "scripts": { "dev": "x" } }"#,
                   "manage.py": "", "Package.swift": "", "Cargo.toml": "", "go.mod": ""]
        XCTAssertEqual(try detect(files: all)?.title, "Dart")
        try FileManager.default.removeItem(at: root.appendingPathComponent("pubspec.yaml"))
        XCTAssertEqual(try command([:]), "mvn compile exec:java")
        try FileManager.default.removeItem(at: root.appendingPathComponent("pom.xml"))
        XCTAssertEqual(try command([:]), "gradle run")
        try FileManager.default.removeItem(at: root.appendingPathComponent("build.gradle"))
        XCTAssertEqual(try command([:]), "npm run dev")
    }

    func testTheProjectSettingsOverrideEverything() throws {
        let found = try detect(files: ["package.json": #"{ "scripts": { "dev": "x" } }"#, ".feather/settings.json": #"{ "run": "make serve" }"#])
        XCTAssertEqual(found?.title, "Run")
        XCTAssertEqual(found?.command, "make serve")
        XCTAssertEqual(found?.directory.path, root.path)
        XCTAssertEqual(RunConfiguration.customCommand(for: root), "make serve")
        RunConfiguration.setCustomCommand(nil, for: root)
        XCTAssertNil(RunConfiguration.customCommand(for: root))
        XCTAssertEqual(try command([:]), "npm run dev")
        RunConfiguration.setCustomCommand("", for: root)
        XCTAssertNil(RunConfiguration.customCommand(for: root), "an empty command means detect")
        RunConfiguration.setCustomCommand("./run.sh", for: root)
        XCTAssertEqual(ProjectSettings.load(from: root).run, "./run.sh")
    }

    func testTheOldDefaultsOverrideStillCountsUntilItIsReplaced() throws {
        try TestSupport.write(["package.json": #"{ "scripts": { "dev": "x" } }"#], under: root)
        let defaults = UserDefaults.standard
        var legacy = defaults.dictionary(forKey: "runCommands") as? [String: String] ?? [:]
        legacy[root.path] = "legacy command"
        defaults.set(legacy, forKey: "runCommands")
        defer {
            var cleaned = defaults.dictionary(forKey: "runCommands") as? [String: String] ?? [:]
            cleaned[root.path] = nil
            defaults.set(cleaned, forKey: "runCommands")
        }
        XCTAssertEqual(RunConfiguration.customCommand(for: root), "legacy command")
        RunConfiguration.setCustomCommand("fresh", for: root)
        XCTAssertEqual(RunConfiguration.customCommand(for: root), "fresh")
        XCTAssertNil((defaults.dictionary(forKey: "runCommands") as? [String: String])?[root.path], "moved into the project file")
    }

    func testTheFileBeingEditedPicksItsOwnSubproject() throws {
        let files = ["backend/pom.xml": "<project>spring-boot</project>", "backend/src/Main.java": "",
                     "frontend/package.json": #"{ "scripts": { "dev": "next" } }"#, "frontend/app/page.tsx": "",
                     "docs/readme.md": "", "package.json": #"{ "scripts": { "start": "root" } }"#]
        let backend = try detect(files: files, currentFile: "backend/src/Main.java")
        XCTAssertEqual(backend?.command, "mvn spring-boot:run")
        XCTAssertEqual(backend?.directory.path, root.appendingPathComponent("backend").path)
        let frontend = try detect(files: [:], currentFile: "frontend/app/page.tsx")
        XCTAssertEqual(frontend?.command, "npm run dev")
        XCTAssertEqual(frontend?.directory.path, root.appendingPathComponent("frontend").path)
        // A file in a folder without a marker falls back to the project folder.
        XCTAssertEqual(try detect(files: [:], currentFile: "docs/readme.md")?.command, "npm run start")
        XCTAssertEqual(try detect(files: [:])?.command, "npm run start")
    }

    func testAFileOutsideTheProjectFallsBackToTheProject() throws {
        let elsewhere = TestSupport.temporaryDirectory("feather-elsewhere")
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try TestSupport.write(["go.mod": "module x\n", "main.go": ""], under: elsewhere)
        let found = try detect(files: ["Cargo.toml": ""], currentFile: nil)
        XCTAssertEqual(found?.command, "cargo run")
        let outside = RunConfiguration.detectProject(root: root, currentFile: elsewhere.appendingPathComponent("main.go"))
        XCTAssertEqual(outside?.command, "go run .", "the file's own folder is looked at first")
        let unrelated = RunConfiguration.detectProject(root: root, currentFile: elsewhere.appendingPathComponent("sub/none.go"))
        XCTAssertEqual(unrelated?.command, "cargo run", "then the walk stops and the project decides")
    }

    func testWithoutAProjectFolderTheFilesFolderDecides() throws {
        try TestSupport.write(["go.mod": "module x\n", "main.go": ""], under: root)
        XCTAssertEqual(RunConfiguration.detectProject(root: nil, currentFile: root.appendingPathComponent("main.go"))?.command, "go run .")
    }

    func testRunningTheCurrentFile() {
        let file = URL(fileURLWithPath: "/tmp/proj/my script.py")
        let found = RunConfiguration.currentFile(file)
        XCTAssertEqual(found?.title, "my script.py")
        XCTAssertEqual(found?.command, "python3 'my script.py'")
        XCTAssertEqual(found?.directory.path, "/tmp/proj")
        XCTAssertEqual(RunConfiguration.currentFile(URL(fileURLWithPath: "/x/a.TS"))?.command, "npx tsx 'a.TS'", "the extension is matched regardless of case")
        XCTAssertEqual(RunConfiguration.currentFile(URL(fileURLWithPath: "/x/a.mjs"))?.command, "node 'a.mjs'")
        XCTAssertEqual(RunConfiguration.currentFile(URL(fileURLWithPath: "/x/it's.go"))?.command, "go run 'it'\\''s.go'", "a quote in the name is escaped for the shell")
        XCTAssertNil(RunConfiguration.currentFile(URL(fileURLWithPath: "/x/notes.md")))
        XCTAssertNil(RunConfiguration.currentFile(URL(fileURLWithPath: "/x/Makefile")))
    }

    func testTheShellCommandChangesFolderFirst() {
        let configuration = RunConfiguration(title: "t", command: "npm run dev", directory: URL(fileURLWithPath: "/tmp/my proj"))
        XCTAssertEqual(configuration.shellCommand, "cd '/tmp/my proj' && npm run dev")
    }
}
