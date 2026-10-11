import Foundation

/// One line a compiler or linter printed, before it is tied to a file. Positions are one-based, as tools print
/// them; `path` is as printed, absolute or relative to the folder the tool ran in.
struct CheckerProblem: Equatable {
    var path: String
    var line: Int
    var column: Int
    var severity: Int              // 1 error, 2 warning
    var message: String
    var code: String? = nil
    var endLine: Int? = nil
    var endColumn: Int? = nil
}

/// Turns each tool's output into problems. Pure functions, so the samples in the tests are all they need.
enum CheckerOutput {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    private static func match(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        guard let found = regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
        return (1..<found.numberOfRanges).map { found.range(at: $0).location == NSNotFound ? "" : (line as NSString).substring(with: found.range(at: $0)) }
    }

    /// `tsc --pretty false`: "src/app.ts(12,5): error TS2322: Type 'string' is not assignable to type 'number'."
    /// The lines indented under one are the rest of its message.
    private static let tscLine = regex(#"^(.+?)\((\d+),(\d+)\): (error|warning) (TS\d+): (.*)$"#)

    static func tsc(_ text: String) -> [CheckerProblem] {
        var result: [CheckerProblem] = []
        for line in lines(text) {
            if let fields = match(tscLine, line) {
                result.append(CheckerProblem(path: fields[0], line: Int(fields[1]) ?? 1, column: Int(fields[2]) ?? 1,
                                             severity: fields[3] == "error" ? 1 : 2, message: fields[5], code: fields[4]))
            } else if line.hasPrefix("  "), !result.isEmpty, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                result[result.count - 1].message += "\n" + line.trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }

    /// `pyright --outputjson`. Positions in the JSON are zero-based, unlike everything the other tools print.
    static func pyright(_ text: String) -> [CheckerProblem] {
        // Anything the tool printed before the JSON (a version notice) is skipped.
        guard let start = text.firstIndex(of: "{"), let data = text[start...].data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["generalDiagnostics"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let file = item["file"] as? String, let range = item["range"] as? [String: Any],
                  let start = range["start"] as? [String: Any], let line = start["line"] as? Int else { return nil }
            let severity: Int
            switch item["severity"] as? String {
            case "error": severity = 1
            case "warning": severity = 2
            default: return nil                            // "information" and hints are not problems
            }
            let end = range["end"] as? [String: Any]
            return CheckerProblem(path: file, line: line + 1, column: (start["character"] as? Int ?? 0) + 1, severity: severity,
                                  message: item["message"] as? String ?? "", code: item["rule"] as? String,
                                  endLine: (end?["line"] as? Int).map { $0 + 1 }, endColumn: (end?["character"] as? Int).map { $0 + 1 })
        }
    }

    /// pyflakes: "src/app.py:3:5: undefined name 'foo'" (older versions leave the column out). A syntax error is
    /// followed by the line of code and a caret, which are not problems of their own.
    private static let pyflakesLine = regex(#"^(.+?\.pyi?):(\d+):(?:(\d+):)? (.*)$"#)

    static func pyflakes(_ text: String) -> [CheckerProblem] {
        lines(text).compactMap { line in
            guard let fields = match(pyflakesLine, line) else { return nil }
            let message = fields[3]
            let lowered = message.lowercased()
            let isError = lowered.hasPrefix("undefined name") || lowered.contains("syntax") || lowered.contains("indent")
                || lowered.hasPrefix("invalid") || lowered.hasPrefix("unexpected")
            return CheckerProblem(path: fields[0], line: Int(fields[1]) ?? 1, column: Int(fields[2]) ?? 1,
                                  severity: isError ? 1 : 2, message: message)
        }
    }

    /// `python3 -m py_compile`: a traceback-style block per file, ending in "SyntaxError: invalid syntax"; older
    /// Pythons print "Sorry: SyntaxError: invalid syntax (app.py, line 2)" instead.
    private static let pyCompileFile = regex(#"^\s*File "(.+?)", line (\d+)"#)
    private static let pyCompileError = regex(#"^(\w*Error): (.*)$"#)
    private static let pyCompileSorry = regex(#"^Sorry: (\w+): (.*) \((.+), line (\d+)\)$"#)

    static func pyCompile(_ text: String) -> [CheckerProblem] {
        var result: [CheckerProblem] = []
        var pending: (path: String, line: Int, column: Int)?
        var previous = ""
        for line in lines(text) {
            if let fields = match(pyCompileFile, line) {
                pending = (fields[0], Int(fields[1]) ?? 1, 1)
            } else if let fields = match(pyCompileSorry, line) {
                result.append(CheckerProblem(path: fields[2], line: Int(fields[3]) ?? 1, column: 1, severity: 1, message: fields[1], code: fields[0]))
            } else if let fields = match(pyCompileError, line), let place = pending {
                result.append(CheckerProblem(path: place.path, line: place.line, column: place.column, severity: 1, message: fields[1], code: fields[0]))
                pending = nil
            } else if pending != nil, line.trimmingCharacters(in: .whitespaces).hasPrefix("^"), let caret = line.firstIndex(of: "^") {
                // The caret sits under the code line above, which is indented by four spaces.
                let indent = previous.prefix { $0 == " " }.count
                pending?.column = max(1, line.distance(from: line.startIndex, to: caret) - indent + 1)
            }
            previous = line
        }
        return result
    }

    /// Maven: "[ERROR] /path/App.java:[12,5] cannot find symbol", each printed twice (once in the compiler's
    /// section and again in the summary), with "[ERROR]   symbol: class Foo" lines under the first.
    private static let mavenLine = regex(#"^\[(ERROR|WARNING)\] (.+?\.java):\[(\d+),(\d+)\] (.*)$"#)

    static func maven(_ text: String) -> [CheckerProblem] {
        var result: [CheckerProblem] = []
        var seen = Set<String>()
        for line in lines(text) {
            if let fields = match(mavenLine, line) {
                let problem = CheckerProblem(path: fields[1], line: Int(fields[2]) ?? 1, column: Int(fields[3]) ?? 1,
                                             severity: fields[0] == "ERROR" ? 1 : 2, message: fields[4])
                if seen.insert("\(problem.path):\(problem.line):\(problem.column):\(problem.message)").inserted { result.append(problem) }
            } else if line.hasPrefix("[ERROR]   "), let last = result.last, last.severity == 1, !seen.contains(line) {
                let detail = line.dropFirst("[ERROR]".count).trimmingCharacters(in: .whitespaces)
                if !detail.isEmpty, !result[result.count - 1].message.contains(detail) { result[result.count - 1].message += "\n" + detail }
            }
        }
        return result
    }

    /// javac, as Gradle and plain builds print it: "/path/App.java:12: error: cannot find symbol", then the line
    /// of code, a caret under the place, and "symbol:" details.
    private static let javacLine = regex(#"^(.+?\.java):(\d+): (error|warning): (.*)$"#)

    static func javac(_ text: String) -> [CheckerProblem] {
        var result: [CheckerProblem] = []
        var awaitingCaret = false
        var seen = Set<String>()
        for line in lines(text) {
            if let fields = match(javacLine, line) {
                let problem = CheckerProblem(path: fields[0], line: Int(fields[1]) ?? 1, column: 1, severity: fields[2] == "error" ? 1 : 2, message: fields[3])
                awaitingCaret = seen.insert("\(problem.path):\(problem.line):\(problem.message)").inserted
                if awaitingCaret { result.append(problem) }
            } else if awaitingCaret, line.trimmingCharacters(in: .whitespaces) == "^", let caret = line.firstIndex(of: "^") {
                result[result.count - 1].column = line.distance(from: line.startIndex, to: caret) + 1
                awaitingCaret = false
            } else if let last = result.last, last.severity == 1, line.hasPrefix("  symbol:") || line.hasPrefix("  location:") {
                result[result.count - 1].message += "\n" + line.trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }

    /// `dart analyze --format=machine`: SEVERITY|TYPE|CODE|PATH|LINE|COLUMN|LENGTH|MESSAGE, one a line. A pipe in
    /// the message is escaped as "\|".
    static func dart(_ text: String) -> [CheckerProblem] {
        lines(text).compactMap { line in
            let fields = split(line, on: "|", limit: 8)
            guard fields.count == 8, let number = Int(fields[4]), let column = Int(fields[5]) else { return nil }
            let severity: Int
            switch fields[0] {
            case "ERROR": severity = 1
            case "WARNING": severity = 2
            default: return nil                              // INFO (lints and hints)
            }
            return CheckerProblem(path: fields[3], line: number, column: column, severity: severity,
                                  message: fields[7].replacingOccurrences(of: "\\|", with: "|"), code: fields[2].lowercased(),
                                  endLine: number, endColumn: column + (Int(fields[6]) ?? 1))
        }
    }

    /// Splits on an unescaped separator, at most `limit` pieces; the last piece keeps any further separators.
    private static func split(_ line: String, on separator: Character, limit: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        var escaped = false
        for character in line {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { current.append(character); escaped = true; continue }
            if character == separator, pieces.count < limit - 1 { pieces.append(current); current = "" } else { current.append(character) }
        }
        pieces.append(current)
        return pieces
    }

    /// swiftc and `swift build`: "/path/App.swift:12:5: error: cannot find 'foo' in scope". The same error is
    /// printed once per target that includes the file; it is one problem.
    private static let swiftLine = regex(#"^(.+?\.swift):(\d+):(\d+): (error|warning): (.*)$"#)

    static func swift(_ text: String) -> [CheckerProblem] {
        var result: [CheckerProblem] = []
        var seen = Set<String>()
        for line in lines(text) {
            guard let fields = match(swiftLine, line) else { continue }
            let problem = CheckerProblem(path: fields[0], line: Int(fields[1]) ?? 1, column: Int(fields[2]) ?? 1,
                                         severity: fields[3] == "error" ? 1 : 2, message: fields[4])
            if seen.insert("\(problem.path):\(problem.line):\(problem.column):\(problem.message)").inserted { result.append(problem) }
        }
        return result
    }
}

// MARK: - Commands

/// One tool, ready to run on one project.
struct CheckerCommand {
    enum Tool: String {
        case tsc, pyright, pyflakes, pyCompile = "py_compile", maven = "mvn", gradle, dart, swift

        /// The saved files that make this tool run again.
        var extensions: Set<String> {
            switch self {
            case .tsc: return ["ts", "tsx", "js", "jsx", "mts", "cts", "mjs", "cjs"]
            case .pyright, .pyflakes, .pyCompile: return ["py", "pyi"]
            case .maven, .gradle: return ["java"]
            case .dart: return ["dart"]
            case .swift: return ["swift"]
            }
        }

        func parse(_ output: String) -> [CheckerProblem] {
            switch self {
            case .tsc: return CheckerOutput.tsc(output)
            case .pyright: return CheckerOutput.pyright(output)
            case .pyflakes: return CheckerOutput.pyflakes(output)
            case .pyCompile: return CheckerOutput.pyCompile(output)
            case .maven: return CheckerOutput.maven(output)
            case .gradle: return CheckerOutput.javac(output)
            case .dart: return CheckerOutput.dart(output)
            case .swift: return CheckerOutput.swift(output)
            }
        }
    }

    let tool: Tool
    let executable: String
    let arguments: [String]
    let directory: URL
    /// True for a tool that checks the files it is given rather than the project (py_compile). Its results then
    /// speak only for those files.
    var perFile = false

    var name: String { tool.rawValue }
}

/// What one run of a tool found, tied to files.
struct CheckerRun {
    let name: String
    let root: URL
    let diagnostics: [URL: [LSPDiagnostic]]
    /// The files the run speaks for; nil when it checked the whole project.
    let scope: [URL]?
    /// Why the tool could not be run or gave nothing usable, in plain words. Problems it did print still count.
    let error: String?
    let duration: TimeInterval
}

// MARK: - Running

/// Finds the compilers and linters a project can be checked with, and runs them: on demand, and a moment after a
/// save. There is one per window, it runs one tool at a time, and a new run stops the one under way. Nothing
/// runs while the folder is in Restricted Mode.
final class ProjectChecker {
    static let debounce: TimeInterval = 1.5
    static let maxOutputBytes = 4_000_000
    static let timeout: TimeInterval = 600
    static let maxFilesPerRun = 2_000

    var root: URL? {
        didSet {
            guard root != oldValue else { return }
            cancel()
            detected = nil
            lastRun = nil
            onRootChange?()
            onStateChange?()
        }
    }
    /// Another folder: what the last one's tools found no longer applies.
    var onRootChange: (() -> Void)?
    /// A run finished (main thread). An error alone means the tool did not run.
    var onResults: ((CheckerRun) -> Void)?
    /// Started, finished, folder changed (main thread).
    var onStateChange: (() -> Void)?
    /// How executables are looked up; the tests point it at scripts of their own.
    var find: (String) -> String? = { ShellEnvironment.shared.find($0) }
    /// Whether the project's own tools may be run; false in Restricted Mode.
    var isAllowed: (URL) -> Bool = { !WorkspaceTrust.shared.blocksExecution(in: $0) }

    private(set) var runningName: String?
    private(set) var lastRun: (name: String, date: Date, error: String?)?
    var isRunning: Bool { runningName != nil }

    private var detected: (root: URL, commands: [CheckerCommand])?
    private var queue: [(command: CheckerCommand, files: [URL])] = []
    private var current: (process: Process, generation: Int)?
    private var generation = 0
    private var saveWork: DispatchWorkItem?
    private var savedFiles: [URL] = []

    // MARK: Detection

    /// The tools this project can be checked with, from what is on disk and what is installed. Slow enough
    /// (it may ask python whether pyflakes is there) to belong off the main thread.
    func detect(root: URL) -> [CheckerCommand] {
        let files = FileManager.default
        func exists(_ name: String) -> Bool { files.fileExists(atPath: root.appendingPathComponent(name).path) }
        func executable(_ name: String) -> String? {
            let path = root.appendingPathComponent(name).path
            return files.isExecutableFile(atPath: path) ? path : nil
        }
        var commands: [CheckerCommand] = []
        if exists("tsconfig.json"), let tsc = executable("node_modules/.bin/tsc") ?? find("tsc") {
            commands.append(CheckerCommand(tool: .tsc, executable: tsc, arguments: ["--noEmit", "--pretty", "false", "-p", "tsconfig.json"], directory: root))
        }
        let listing = ProjectFiles.list(root: root)
        let hasPython = ["pyproject.toml", "requirements.txt", "setup.py", "setup.cfg", "Pipfile", "pyrightconfig.json"].contains(where: exists)
            || listing.contains { $0.hasSuffix(".py") }
        if hasPython {
            if let pyright = find("pyright") {
                commands.append(CheckerCommand(tool: .pyright, executable: pyright, arguments: ["--outputjson"], directory: root))
            } else if let python = executable(".venv/bin/python3") ?? executable("venv/bin/python3") ?? find("python3") {
                if ProjectChecker.pythonHasModule("pyflakes", python: python) {
                    commands.append(CheckerCommand(tool: .pyflakes, executable: python, arguments: ["-m", "pyflakes", "."], directory: root))
                } else {
                    commands.append(CheckerCommand(tool: .pyCompile, executable: python, arguments: ["-m", "py_compile"], directory: root, perFile: true))
                }
            }
        }
        if exists("pom.xml"), let maven = executable("mvnw") ?? find("mvn") {
            commands.append(CheckerCommand(tool: .maven, executable: maven, arguments: ["-q", "-B", "-Dstyle.color=never", "compile"], directory: root))
        } else if exists("build.gradle") || exists("build.gradle.kts"), let gradle = executable("gradlew") ?? find("gradle") {
            commands.append(CheckerCommand(tool: .gradle, executable: gradle, arguments: ["compileJava", "-q", "--console=plain"], directory: root))
        }
        if exists("pubspec.yaml"), let dart = find("dart") {
            commands.append(CheckerCommand(tool: .dart, executable: dart, arguments: ["analyze", "--format=machine"], directory: root))
        }
        if exists("Package.swift"), let swift = find("swift") {
            commands.append(CheckerCommand(tool: .swift, executable: swift, arguments: ["build"], directory: root))
        }
        return commands
    }

    private static func pythonHasModule(_ module: String, python: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", "import " + module]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// The names of the tools found for the folder, once detection has run ("tsc, pyright").
    var detectedNames: [String] { detected?.commands.map(\.name) ?? [] }

    // MARK: Starting runs

    /// Check Project: every tool the folder has, one after the other. `found` hears which tools those are, once
    /// detection is done, which is how the window can say when there are none.
    func checkProject(found: (([CheckerCommand]) -> Void)? = nil) {
        guard let root, isAllowed(root) else { return }
        saveWork?.cancel()
        savedFiles = []
        withCommands(root: root) { [weak self] commands in
            found?(commands)
            // A per-file tool needs the project's files, and listing them is not main-thread work.
            DispatchQueue.global(qos: .userInitiated).async {
                let listing = commands.contains(where: \.perFile) ? ProjectFiles.list(root: root) : []
                DispatchQueue.main.async {
                    guard let self, self.root == root else { return }
                    self.cancel()
                    for command in commands {
                        let files = command.perFile
                            ? listing.filter { path in command.tool.extensions.contains((path as NSString).pathExtension) }
                                .prefix(ProjectChecker.maxFilesPerRun).map { root.appendingPathComponent($0) }
                            : []
                        if command.perFile, files.isEmpty { continue }
                        self.queue.append((command, files))
                    }
                    self.startNext()
                }
            }
        }
    }

    /// A file was saved: a moment later, the tools that care about its kind run again (just the saved files
    /// for a per-file tool).
    func fileSaved(_ url: URL) {
        guard Settings.shared.checkOnSave, let root, url.path.hasPrefix(root.path + "/") else { return }
        let ext = url.pathExtension.lowercased()
        guard CheckerCommand.Tool.allExtensions.contains(ext) else { return }
        if !savedFiles.contains(url) { savedFiles.append(url) }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runForSavedFiles() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ProjectChecker.debounce, execute: work)
    }

    private func runForSavedFiles() {
        let files = savedFiles
        savedFiles = []
        guard let root, isAllowed(root), !files.isEmpty else { return }
        withCommands(root: root) { [weak self] commands in
            guard let self, self.root == root else { return }
            let extensions = Set(files.map { $0.pathExtension.lowercased() })
            let wanted = commands.filter { !$0.tool.extensions.isDisjoint(with: extensions) }
            guard !wanted.isEmpty else { return }
            self.cancel()
            for command in wanted {
                let own = command.perFile ? files.filter { command.tool.extensions.contains($0.pathExtension.lowercased()) } : []
                self.queue.append((command, own))
            }
            self.startNext()
        }
    }

    private func withCommands(root: URL, _ body: @escaping ([CheckerCommand]) -> Void) {
        if let detected, detected.root == root { return body(detected.commands) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let commands = self?.detect(root: root) ?? []
            DispatchQueue.main.async {
                guard let self, self.root == root else { return }
                self.detected = (root, commands)
                self.onStateChange?()
                body(commands)
            }
        }
    }

    /// Forget what was found for the folder, so tools installed since are picked up on the next run.
    func forgetDetection() { detected = nil }

    /// Stops the run under way and everything queued behind it.
    func cancel() {
        queue = []
        generation += 1
        if let current, current.process.isRunning { current.process.terminate() }
        current = nil
        if runningName != nil {
            runningName = nil
            onStateChange?()
        }
    }

    private func startNext() {
        guard current == nil, !queue.isEmpty, let root else { return }
        let (command, files) = queue.removeFirst()
        generation += 1
        let generation = generation
        runningName = command.name
        onStateChange?()
        let started = Date()
        ProjectChecker.run(command, files: files, onStart: { [weak self] process in
            self?.current = (process, generation)
        }, completion: { [weak self] problems, error in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.current = nil
                self.runningName = nil
                self.lastRun = (command.name, Date(), error)
                let run = CheckerRun(name: command.name, root: root, diagnostics: ProjectChecker.diagnostics(from: problems, command: command),
                                     scope: command.perFile ? files : nil, error: error, duration: Date().timeIntervalSince(started))
                self.onResults?(run)
                self.onStateChange?()
                self.startNext()
            }
        })
    }

    /// Runs one tool off the main thread and hands back what it printed, parsed. `files` are appended to the
    /// arguments for a per-file tool. Output is capped; a tool that prints more than the cap or runs past the
    /// time limit is stopped, and what it printed so far is used.
    static func run(_ command: CheckerCommand, files: [URL] = [], onStart: ((Process) -> Void)? = nil,
                    completion: @escaping ([CheckerProblem], String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments + files.map(\.path)
        process.currentDirectoryURL = command.directory
        var environment = ShellEnvironment.shared.pathDirectories.isEmpty ? ProcessInfo.processInfo.environment : ShellEnvironment.shared.environment
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        environment["FORCE_COLOR"] = "0"
        environment["CI"] = "1"                              // keeps tsc, npm and gradle from drawing progress
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let lock = NSLock()
        var output = Data()
        var truncated = false
        var timedOut = false
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }           // end of output
            lock.lock()
            if output.count < maxOutputBytes { output.append(chunk) }
            else if !truncated { truncated = true; process.terminate() }
            lock.unlock()
        }
        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return completion([], "Could not start \(command.name): \(error.localizedDescription)")
        }
        onStart?(process)
        let timeoutWork = DispatchWorkItem {
            guard process.isRunning else { return }
            lock.lock(); timedOut = true; lock.unlock()
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            timeoutWork.cancel()
            pipe.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            output.append(pipe.fileHandleForReading.readDataToEndOfFile())
            let text = String(decoding: output, as: UTF8.self)
            let (wasTruncated, didTimeOut) = (truncated, timedOut)
            lock.unlock()
            let problems = command.tool.parse(text)
            var error: String?
            if didTimeOut {
                error = "\(command.name) was stopped after \(Int(timeout / 60)) minutes"
            } else if wasTruncated {
                error = "\(command.name) printed more than Feather reads; only the first problems are listed"
            } else if problems.isEmpty, process.terminationReason == .exit, process.terminationStatus != 0 {
                // It failed without reporting a single problem: the failure itself is the news (a missing
                // dependency, a bad config file).
                let tail = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(3).joined(separator: " ")
                error = "\(command.name) exited with code \(process.terminationStatus)" + (tail.isEmpty ? "" : ": " + String(tail.prefix(300)))
            }
            completion(problems, error)
        }
    }

    /// Ties printed paths to files under the folder the tool ran in, and turns one-based positions into the
    /// zero-based ones the Problems pane and the editor use.
    static func diagnostics(from problems: [CheckerProblem], command: CheckerCommand) -> [URL: [LSPDiagnostic]] {
        var result: [URL: [LSPDiagnostic]] = [:]
        for problem in problems {
            let url = (problem.path.hasPrefix("/") ? URL(fileURLWithPath: problem.path) : command.directory.appendingPathComponent(problem.path)).standardizedFileURL
            let line = max(0, problem.line - 1), character = max(0, problem.column - 1)
            let endLine = max(line, (problem.endLine ?? problem.line) - 1)
            let endCharacter = problem.endColumn.map { max(0, $0 - 1) } ?? character
            result[url, default: []].append(LSPDiagnostic(startLine: line, startCharacter: character, endLine: endLine, endCharacter: endCharacter,
                                                          severity: problem.severity, message: problem.message, source: command.name, code: problem.code))
        }
        return result
    }
}

extension CheckerCommand.Tool {
    static let allExtensions: Set<String> = [tsc, pyright, maven, dart, swift].reduce(into: []) { $0.formUnion($1.extensions) }
}
