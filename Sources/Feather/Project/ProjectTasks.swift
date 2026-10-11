import Foundation

/// Something the project itself says can be run: an npm script, a Maven goal, a Makefile target, or a command
/// written into `.feather/settings.json`. Finding tasks only ever reads files; nothing runs until one is picked.
struct ProjectTask: Equatable {
    /// What the row says: "dev", "spring-boot:run", "make build".
    let name: String
    let command: String
    let directory: URL
    /// "npm", "Maven", "Make", "Custom"…; shown with the command so two "test" rows can be told apart.
    let source: String

    /// The folder relative to the project, "" for the project folder itself.
    func folder(relativeTo root: URL) -> String {
        let rootPath = root.standardizedFileURL.path, path = directory.standardizedFileURL.path
        if path == rootPath { return "" }
        return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
    }

    /// The terminal tab's name. Two subprojects may both have a "dev", so the folder is part of it.
    func title(relativeTo root: URL) -> String {
        let folder = folder(relativeTo: root)
        return folder.isEmpty ? name : "\(name) (\(folder))"
    }

    var shellCommand: String {
        "cd \(TerminalPaneController.quote(directory.path)) && \(command)"
    }
}

enum TaskDiscovery {
    /// The files whose contents decide the task list. Their dates and sizes make up the cache's signature.
    static let manifests = ["package.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock", "pom.xml", "mvnw",
                            "build.gradle", "build.gradle.kts", "gradlew", "pubspec.yaml", "pytest.ini", "pyproject.toml",
                            "setup.cfg", "tox.ini", "conftest.py", "manage.py", "main.py", "app.py", "app/main.py",
                            "src/main.py", "Makefile", "makefile", "GNUmakefile", ".feather/settings.json"]

    /// Folders that are never a subproject, however many manifests they hold.
    private static let skippedFolders: Set<String> = ["node_modules", "build", "dist", "target", "out", "venv", "Pods", "vendor"]

    /// The project folder and the folders directly inside it: where a monorepo keeps `backend/` and `frontend/`.
    static func folders(in root: URL) -> [URL] {
        // Names, not URLs: the URLs the file manager hands back may spell the path differently from `root`
        // (/private/tmp for /tmp), and a task's folder should read the way the project's does.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let subfolders = names.filter { !$0.hasPrefix(".") && !skippedFolders.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { root.appendingPathComponent($0) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        return [root] + subfolders
    }

    /// Changes whenever a manifest is added, removed or rewritten. Costs a stat per candidate, no reads.
    static func signature(of root: URL) -> String {
        var parts: [String] = []
        for folder in folders(in: root) {
            let names = folder == root ? manifests : manifests.filter { $0 != ".feather/settings.json" }
            for name in names {
                let file = folder.appendingPathComponent(name)
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let date = values.contentModificationDate else { continue }
                parts.append("\(file.path)|\(date.timeIntervalSince1970)|\(values.fileSize ?? 0)")
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Everything runnable in `root`: the project's own custom tasks first, then each folder's, in folder order.
    static func tasks(in root: URL) -> [ProjectTask] {
        let root = root.standardizedFileURL
        var found = customTasks(in: root)
        for folder in folders(in: root) { found += tasks(inFolder: folder) }
        // `app/main.py` is found from the project folder as "app.main:app"; the same file seen again from inside
        // `app/` would be a second row that does not start.
        if found.contains(where: { $0.source == "FastAPI" && $0.directory == root }) {
            found.removeAll { $0.source == "FastAPI" && $0.directory != root && ["app", "src"].contains($0.directory.lastPathComponent) }
        }
        return found
    }

    static func customTasks(in root: URL) -> [ProjectTask] {
        ProjectSettings.load(from: root).tasks.map { task in
            let directory = task.cwd.map { root.appendingPathComponent($0).standardizedFileURL } ?? root
            return ProjectTask(name: task.name, command: task.command, directory: directory, source: "Custom")
        }
    }

    static func tasks(inFolder directory: URL) -> [ProjectTask] {
        let files = FileManager.default
        func exists(_ name: String) -> Bool { files.fileExists(atPath: directory.appendingPathComponent(name).path) }
        func contents(_ name: String) -> String {
            (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        var found: [ProjectTask] = []
        func add(_ source: String, _ name: String, _ command: String) {
            found.append(ProjectTask(name: name, command: command, directory: directory, source: source))
        }

        if exists("package.json") {
            let manager = exists("pnpm-lock.yaml") ? "pnpm" : exists("yarn.lock") ? "yarn"
                : (exists("bun.lockb") || exists("bun.lock")) ? "bun" : "npm"
            // A package.json that does not parse simply has no scripts; the rest of the project is still listed.
            let json = (try? JSONSerialization.jsonObject(with: Data(contents("package.json").utf8))) as? [String: Any]
            let scripts = json?["scripts"] as? [String: Any] ?? [:]
            for script in scripts.keys.sorted() where scripts[script] is String { add(manager, script, "\(manager) run \(script)") }
            if json != nil { add(manager, "install", "\(manager) install") }
        }
        if exists("pom.xml") {
            let maven = exists("mvnw") ? "./mvnw" : "mvn"
            for goal in ["clean", "compile", "test", "package", "verify"] { add("Maven", goal, "\(maven) \(goal)") }
            if contents("pom.xml").contains("spring-boot-maven-plugin") { add("Maven", "spring-boot:run", "\(maven) spring-boot:run") }
        }
        if let gradleFile = ["build.gradle", "build.gradle.kts"].first(where: exists) {
            let gradle = exists("gradlew") ? "./gradlew" : "gradle"
            for task in ["build", "test", "clean"] { add("Gradle", task, "\(gradle) \(task)") }
            if contents(gradleFile).contains("org.springframework.boot") { add("Gradle", "bootRun", "\(gradle) bootRun") }
        }
        if exists("pubspec.yaml") {
            // A top-level "flutter:" key, or the SDK dependency, is what makes a Dart package a Flutter app.
            let pubspec = contents("pubspec.yaml")
            if pubspec.contains("sdk: flutter") || pubspec.hasPrefix("flutter:") || pubspec.contains("\nflutter:") {
                for verb in ["run", "test", "pub get", "analyze"] { add("Flutter", "flutter \(verb)", "flutter \(verb)") }
            } else {
                for verb in ["run", "test", "pub get", "analyze"] { add("Dart", "dart \(verb)", "dart \(verb)") }
            }
        }
        if isPytestConfigured(exists: exists, contents: contents) { add("Python", "pytest", "pytest") }
        if exists("manage.py") { add("Django", "runserver", "python3 manage.py runserver") }
        if let app = fastAPIApp(exists: exists, contents: contents) { add("FastAPI", "uvicorn", "uvicorn \(app) --reload") }
        if let makefile = ["GNUmakefile", "makefile", "Makefile"].first(where: exists) {
            for target in makeTargets(in: contents(makefile)) { add("Make", "make \(target)", "make \(target)") }
        }
        return found
    }

    private static func isPytestConfigured(exists: (String) -> Bool, contents: (String) -> String) -> Bool {
        if exists("pytest.ini") || exists("conftest.py") { return true }
        if exists("pyproject.toml"), contents("pyproject.toml").contains("[tool.pytest") { return true }
        if exists("setup.cfg"), contents("setup.cfg").contains("[tool:pytest]") { return true }
        if exists("tox.ini"), contents("tox.ini").contains("[pytest]") { return true }
        return false
    }

    /// "main:app" for `app = FastAPI()` in main.py, "app.main:api" for `api = FastAPI(...)` in app/main.py.
    private static func fastAPIApp(exists: (String) -> Bool, contents: (String) -> String) -> String? {
        for file in ["main.py", "app.py", "app/main.py", "src/main.py"] where exists(file) {
            let text = contents(file)
            guard let range = text.range(of: #"(?m)^([A-Za-z_]\w*)\s*(?::[^=\n]+)?=\s*(?:fastapi\.)?FastAPI\("#, options: .regularExpression) else { continue }
            let variable = text[range].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            let module = file.dropLast(3).replacingOccurrences(of: "/", with: ".")
            return "\(module):\(variable)"
        }
        return nil
    }

    /// The targets a person would type: no pattern rules, no `.PHONY`-style specials, no variable assignments.
    static func makeTargets(in makefile: String) -> [String] {
        var targets: [String] = []
        for line in makefile.split(whereSeparator: \.isNewline) {
            guard let first = line.first, first != "\t", first != "#", first != ".", first != " ",
                  let colon = line.firstIndex(of: ":") else { continue }
            let after = line[line.index(after: colon)...]
            if after.hasPrefix("=") || after.hasPrefix(":=") { continue }              // FOO := bar, FOO ::= bar
            let head = line[..<colon]
            if head.contains("=") || head.contains("%") || head.contains("$") { continue }
            for name in head.split(separator: " ") where !targets.contains(String(name)) { targets.append(String(name)) }
        }
        return targets
    }
}

/// One window's task list: worked out in the background, kept until a manifest changes, and ordered so that
/// what was run lately comes first.
final class ProjectTaskList {
    private static let queue = DispatchQueue(label: "feather.tasks", qos: .userInitiated)
    private static let recentsKey = "recentTasks"
    private static let maxRecents = 8

    private var root: URL?
    private var cached: [ProjectTask] = []
    private var signature: String?
    /// Goes up with every request and every change of folder; an answer carrying an older number is dropped.
    private var generation = 0

    func setRoot(_ root: URL?) {
        guard root?.standardizedFileURL != self.root else { return }
        self.root = root?.standardizedFileURL
        cached = []
        signature = nil
        generation += 1
    }

    /// What is known right now, recent first. May be empty before the first `refresh` has answered.
    var tasks: [ProjectTask] { ProjectTaskList.ordered(cached, recents: root.map(ProjectTaskList.recents) ?? []) }

    /// Checks the manifests off the main thread and reads them again only if one changed. `completion` runs on the
    /// main thread with the ordered list, unless the folder changed or a newer refresh started meanwhile.
    func refresh(completion: @escaping ([ProjectTask]) -> Void) {
        guard let root else { completion([]); return }
        generation += 1
        let generation = self.generation, known = signature
        ProjectTaskList.queue.async { [weak self] in
            let signature = TaskDiscovery.signature(of: root)
            let fresh = signature == known ? nil : TaskDiscovery.tasks(in: root)
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                if let fresh {
                    self.cached = fresh
                    self.signature = signature
                }
                completion(self.tasks)
            }
        }
    }

    // MARK: - Recent tasks

    /// Tasks run lately float to the top, most recent first; the rest keep the order they were found in.
    static func ordered(_ tasks: [ProjectTask], recents: [ProjectTask]) -> [ProjectTask] {
        func rank(_ task: ProjectTask) -> Int {
            recents.firstIndex { $0.command == task.command && $0.directory.path == task.directory.path } ?? Int.max
        }
        return tasks.enumerated().sorted { a, b in
            let rankA = rank(a.element), rankB = rank(b.element)
            return rankA != rankB ? rankA < rankB : a.offset < b.offset
        }.map(\.element)
    }

    static func recents(for root: URL) -> [ProjectTask] {
        let all = UserDefaults.standard.dictionary(forKey: recentsKey) as? [String: [[String: String]]] ?? [:]
        return (all[root.standardizedFileURL.path] ?? []).compactMap { entry in
            guard let name = entry["name"], let command = entry["command"], let directory = entry["directory"] else { return nil }
            return ProjectTask(name: name, command: command, directory: URL(fileURLWithPath: directory), source: entry["source"] ?? "")
        }
    }

    static func noteRun(_ task: ProjectTask, in root: URL) {
        var all = UserDefaults.standard.dictionary(forKey: recentsKey) as? [String: [[String: String]]] ?? [:]
        let key = root.standardizedFileURL.path
        var list = all[key] ?? []
        list.removeAll { $0["command"] == task.command && $0["directory"] == task.directory.path }
        list.insert(["name": task.name, "command": task.command, "directory": task.directory.path, "source": task.source], at: 0)
        all[key] = Array(list.prefix(maxRecents))
        UserDefaults.standard.set(all, forKey: recentsKey)
    }
}
