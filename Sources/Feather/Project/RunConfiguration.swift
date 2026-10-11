import Foundation

struct RunConfiguration {
    let title: String        // terminal tab name
    let command: String
    let directory: URL

    var shellCommand: String {
        "cd \(TerminalPaneController.quote(directory.path)) && \(command)"
    }

    private static let overridesKey = "runCommands"

    /// A command the user typed in "Edit Run Command…", remembered per project folder.
    static func customCommand(for root: URL) -> String? {
        ProjectSettings.load(from: root).run
            ?? (UserDefaults.standard.dictionary(forKey: overridesKey) as? [String: String])?[root.path]   // from before .feather/settings.json
    }

    static func setCustomCommand(_ command: String?, for root: URL) {
        let value: Any? = command?.isEmpty == false ? command : nil       // nil removes the key
        ProjectSettings.update(in: root, ["run": value])
        var legacy = UserDefaults.standard.dictionary(forKey: overridesKey) as? [String: String] ?? [:]
        legacy[root.path] = nil
        UserDefaults.standard.set(legacy, forKey: overridesKey)
    }

    /// Looks for a project marker starting next to the current file and walking up to the project root,
    /// so a repo holding both `backend/` (Spring Boot) and `frontend/` (Next.js) runs whichever you are editing.
    static func detectProject(root: URL?, currentFile: URL?) -> RunConfiguration? {
        if let root, let custom = customCommand(for: root) {
            return RunConfiguration(title: "Run", command: custom, directory: root)
        }
        let rootPath = root?.standardizedFileURL.path
        var directory = currentFile?.deletingLastPathComponent().standardizedFileURL ?? root?.standardizedFileURL
        while let current = directory {
            if let found = projectCommand(in: current) { return found }
            if current.path == rootPath || current.path == "/" || rootPath == nil { break }
            guard let rootPath, current.path.hasPrefix(rootPath + "/") else { break }
            directory = current.deletingLastPathComponent()
        }
        if let root, let found = projectCommand(in: root) { return found }
        return nil
    }

    private static func projectCommand(in directory: URL) -> RunConfiguration? {
        let files = FileManager.default
        func exists(_ name: String) -> Bool { files.fileExists(atPath: directory.appendingPathComponent(name).path) }
        func contents(_ name: String) -> String {
            (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        func make(_ title: String, _ command: String) -> RunConfiguration {
            RunConfiguration(title: title, command: command, directory: directory)
        }

        if exists("pubspec.yaml") {
            let isFlutter = contents("pubspec.yaml").contains("flutter:")
            return isFlutter ? make("Flutter", "flutter run") : make("Dart", "dart run")
        }
        if exists("pom.xml") {
            let maven = exists("mvnw") ? "./mvnw" : "mvn"
            let isSpring = contents("pom.xml").contains("spring-boot")
            return make(isSpring ? "Spring Boot" : "Maven", isSpring ? "\(maven) spring-boot:run" : "\(maven) compile exec:java")
        }
        for gradleFile in ["build.gradle", "build.gradle.kts"] where exists(gradleFile) {
            let gradle = exists("gradlew") ? "./gradlew" : "gradle"
            let isSpring = contents(gradleFile).contains("org.springframework.boot")
            return make(isSpring ? "Spring Boot" : "Gradle", isSpring ? "\(gradle) bootRun" : "\(gradle) run")
        }
        if exists("package.json") {
            let manager = exists("pnpm-lock.yaml") ? "pnpm" : exists("yarn.lock") ? "yarn"
                : (exists("bun.lockb") || exists("bun.lock")) ? "bun" : "npm"
            let data = contents("package.json").data(using: .utf8) ?? Data()
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let scripts = json?["scripts"] as? [String: Any] ?? [:]
            let dependencies = (json?["dependencies"] as? [String: Any] ?? [:]).keys
            guard let script = ["dev", "start", "serve"].first(where: { scripts[$0] != nil }) else { return nil }
            return make(dependencies.contains("next") ? "Next.js" : "Node", "\(manager) run \(script)")
        }
        if exists("manage.py") { return make("Django", "python3 manage.py runserver") }
        if exists("Package.swift") { return make("Swift", "swift run") }
        if exists("Cargo.toml") { return make("Cargo", "cargo run") }
        if exists("go.mod") { return make("Go", "go run .") }
        return nil
    }

    static func currentFile(_ url: URL) -> RunConfiguration? {
        let runners: [String: String] = [
            "py": "python3", "js": "node", "mjs": "node", "ts": "npx tsx", "dart": "dart run",
            "java": "java", "sh": "bash", "zsh": "zsh", "swift": "swift", "rb": "ruby", "go": "go run", "php": "php",
        ]
        guard let runner = runners[url.pathExtension.lowercased()] else { return nil }
        return RunConfiguration(title: url.lastPathComponent,
                                command: "\(runner) \(TerminalPaneController.quote(url.lastPathComponent))",
                                directory: url.deletingLastPathComponent())
    }
}
