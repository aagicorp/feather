import Foundation

/// A language server Feather can download, or one that comes with another tool and is only reported on.
struct ManagedServer {
    enum Source {
        case npm([String])              // packages, from the npm registry through the user's own npm
        case jdtls                      // download.eclipse.org
        case rustAnalyzer               // a release asset of rust-lang/rust-analyzer on GitHub
        case gopls                      // built by the user's own Go toolchain
        case github(GitHubRelease)      // an asset of the project's latest release on GitHub
        case external(String)           // comes with another tool, found on the PATH; the text says which
        case xcode                      // comes with Xcode, found and started through xcrun
    }

    /// One file from a project's latest GitHub release, and what to do with it once it is here.
    struct GitHubRelease {
        enum Packing { case binary, gzip, zip }
        let repository: String          // "owner/name"
        let armAsset: String
        let intelAsset: String
        let packing: Packing
        let binary: String              // where the executable is, inside the server's folder, after unpacking
        let needsJava: Bool

        var asset: String {
            #if arch(arm64)
            return armAsset
            #else
            return intelAsset
            #endif
        }
    }

    let id: String                      // also the folder name
    let language: String
    let serverName: String
    let sizeHint: String
    let source: Source
    let executables: [String]           // the names LSPServerConfig asks for
    let configNames: [String]           // the LSPServerConfig entries that start it

    static let all: [ManagedServer] = [
        // typescript-language-server drives tsserver, and TypeScript 7 (the native rewrite) no longer ships one, so
        // its fallback compiler is held below 7. A project's own node_modules/typescript is still preferred by it.
        ManagedServer(id: "typescript", language: "TypeScript / JavaScript", serverName: "typescript-language-server",
                      sizeHint: "about 25 MB", source: .npm(["typescript-language-server", "typescript@<7"]),
                      executables: ["typescript-language-server"], configNames: ["TypeScript"]),
        ManagedServer(id: "pyright", language: "Python", serverName: "pyright", sizeHint: "about 35 MB",
                      source: .npm(["pyright"]), executables: ["pyright-langserver"], configNames: ["Python"]),
        ManagedServer(id: "jdtls", language: "Java", serverName: "Eclipse JDT Language Server", sizeHint: "about 50 MB",
                      source: .jdtls, executables: ["jdtls"], configNames: ["Java"]),
        ManagedServer(id: "web", language: "HTML / CSS / JSON", serverName: "vscode-langservers-extracted",
                      sizeHint: "about 95 MB", source: .npm(["vscode-langservers-extracted"]),
                      executables: ["vscode-html-language-server", "vscode-css-language-server",
                                    "vscode-json-language-server"],
                      configNames: ["HTML", "CSS", "JSON"]),
        ManagedServer(id: "yaml", language: "YAML", serverName: "yaml-language-server", sizeHint: "about 25 MB",
                      source: .npm(["yaml-language-server"]), executables: ["yaml-language-server"], configNames: ["YAML"]),
        ManagedServer(id: "bash", language: "Bash", serverName: "bash-language-server", sizeHint: "about 25 MB",
                      source: .npm(["bash-language-server"]), executables: ["bash-language-server"], configNames: ["Bash"]),
        ManagedServer(id: "rust-analyzer", language: "Rust", serverName: "rust-analyzer", sizeHint: "14 MB download",
                      source: .rustAnalyzer, executables: ["rust-analyzer"], configNames: ["Rust"]),
        ManagedServer(id: "gopls", language: "Go", serverName: "gopls", sizeHint: "built by Go, about 30 MB",
                      source: .gopls, executables: ["gopls"], configNames: ["Go"]),
        ManagedServer(id: "kotlin", language: "Kotlin", serverName: "kotlin-language-server", sizeHint: "85 MB download",
                      source: .github(GitHubRelease(repository: "fwcd/kotlin-language-server", armAsset: "server.zip",
                                                    intelAsset: "server.zip", packing: .zip,
                                                    binary: "server/bin/kotlin-language-server", needsJava: true)),
                      executables: ["kotlin-language-server"], configNames: ["Kotlin"]),
        ManagedServer(id: "xml", language: "XML (pom.xml, plist, SVG)", serverName: "LemMinX", sizeHint: "16 MB download",
                      source: .github(GitHubRelease(repository: "redhat-developer/vscode-xml",
                                                    armAsset: "lemminx-osx-aarch_64.zip", intelAsset: "lemminx-osx-x86_64.zip",
                                                    packing: .zip, binary: "lemminx", needsJava: false)),
                      executables: ["lemminx"], configNames: ["XML"]),
        ManagedServer(id: "docker", language: "Dockerfile", serverName: "dockerfile-language-server", sizeHint: "about 5 MB",
                      source: .npm(["dockerfile-language-server-nodejs"]), executables: ["docker-langserver"],
                      configNames: ["Docker"]),
        ManagedServer(id: "markdown", language: "Markdown", serverName: "Marksman", sizeHint: "44 MB download",
                      source: .github(GitHubRelease(repository: "artempyanykh/marksman", armAsset: "marksman-macos",
                                                    intelAsset: "marksman-macos", packing: .binary, binary: "marksman",
                                                    needsJava: false)),
                      executables: ["marksman"], configNames: ["Markdown"]),
        ManagedServer(id: "toml", language: "TOML", serverName: "Taplo", sizeHint: "5 MB download",
                      source: .github(GitHubRelease(repository: "tamasfe/taplo", armAsset: "taplo-darwin-aarch64.gz",
                                                    intelAsset: "taplo-darwin-x86_64.gz", packing: .gzip, binary: "taplo",
                                                    needsJava: false)),
                      executables: ["taplo"], configNames: ["TOML"]),
        ManagedServer(id: "prisma", language: "Prisma", serverName: "prisma-language-server", sizeHint: "about 40 MB",
                      source: .npm(["@prisma/language-server"]), executables: ["prisma-language-server"],
                      configNames: ["Prisma"]),
        ManagedServer(id: "svelte", language: "Svelte", serverName: "svelte-language-server", sizeHint: "about 60 MB",
                      source: .npm(["svelte-language-server"]), executables: ["svelteserver"], configNames: ["Svelte"]),
        ManagedServer(id: "php", language: "PHP", serverName: "Intelephense (free edition)", sizeHint: "about 10 MB",
                      source: .npm(["intelephense"]), executables: ["intelephense"], configNames: ["PHP"]),
        ManagedServer(id: "dart", language: "Dart / Flutter", serverName: "dart language-server", sizeHint: "",
                      source: .external("Provided by Flutter or the Dart SDK"), executables: ["dart"], configNames: ["Dart"]),
        ManagedServer(id: "swift", language: "Swift", serverName: "sourcekit-lsp", sizeHint: "",
                      source: .xcode, executables: ["sourcekit-lsp"], configNames: ["Swift"]),
        ManagedServer(id: "clangd", language: "C / C++ / Objective-C", serverName: "clangd", sizeHint: "",
                      source: .xcode, executables: ["clangd"], configNames: ["C/C++"]),
    ]

    var isExternal: Bool {
        switch source {
        case .external, .xcode: return true
        default: return false
        }
    }

    /// Where an executable ends up inside this server's folder.
    fileprivate func relativePath(of executable: String) -> String {
        switch source {
        case .npm: return "node_modules/.bin/" + executable
        case .jdtls: return "bin/jdtls"
        case .github(let release): return release.binary
        case .rustAnalyzer, .gopls, .external, .xcode: return executable
        }
    }
}

/// The language servers Feather has downloaded for the user. Everything lives in one folder under Application
/// Support: nothing is installed globally, nothing needs sudo, and deleting the folder undoes all of it.
final class LanguageServerStore {
    static let shared = LanguageServerStore()
    /// The Language Servers window needs redrawing: progress or a result for the row `userInfo["id"]`, or, without
    /// an id, new facts about the machine that may concern every row.
    static let stateDidChange = Notification.Name("FeatherLanguageServerStateDidChange")
    /// A server was installed, updated or removed. `userInfo["configs"]` names the LSPServerConfig entries it
    /// serves; every window's LSPManager listens, so open files pick the server up without a restart.
    static let serversDidChange = Notification.Name("FeatherLanguageServersDidChange")

    /// FEATHER_SERVERS_DIR points the store somewhere else, so installs can be tried out without touching the
    /// real folder. A variable only so tests can point it at a temporary folder.
    static var baseDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["FEATHER_SERVERS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Feather/servers", isDirectory: true)
    }()

    enum Status {
        case managed(version: String?)
        case system(path: String, alsoManaged: Bool)
        case notInstalled
        case needs(String)                  // cannot be installed yet; the text says what is missing
    }

    enum Activity {
        case waiting
        case running(String)                // the last line of output, or download progress
        case failed(String)
    }

    /// What the installers depend on. Looked up in the background, because two of the answers mean starting a process.
    private struct Tools {
        var node: String?, npm: String?, go: String?, python: String?
        var javaHome: String?
        var xcodeTools = Set<String>()
        var environment: [String: String] = [:]
    }

    private static let javaHomeKey = "languageServerJavaHome"
    private var tools = Tools()
    private var hasProbed = false
    private(set) var activity: [String: Activity] = [:]          // by server id; main queue only
    /// Installs run one at a time: two npm processes sharing a cache is asking for trouble, and the row that is
    /// waiting says so.
    private let queue = DispatchQueue(label: "feather.servers.install", qos: .userInitiated)
    private let probeQueue = DispatchQueue(label: "feather.servers.probe", qos: .utility)

    // MARK: - Finding installed servers

    private static func directory(of server: ManagedServer) -> URL {
        baseDirectory.appendingPathComponent(server.id, isDirectory: true)
    }

    /// The Feather-installed copy of an executable, if there is one. A copy on the user's PATH is their own setup
    /// and is tried first by the caller.
    static func executable(named name: String) -> String? {
        guard let server = ManagedServer.all.first(where: { !$0.isExternal && $0.executables.contains(name) }) else { return nil }
        let path = directory(of: server).appendingPathComponent(server.relativePath(of: name)).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static func isManaged(_ executable: String) -> Bool {
        executable.hasPrefix(baseDirectory.path + "/")
    }

    /// The npm servers are scripts that begin "#!/usr/bin/env node", so the user's node has to be on the PATH they
    /// are started with. jdtls is started by the JDK that was found for it, whatever JAVA_HOME the project prefers.
    func environment(for executable: String, base: [String: String]) -> [String: String] {
        guard LanguageServerStore.isManaged(executable) else { return base }
        var environment = base
        if let node = tools.node ?? ShellEnvironment.shared.find("node") {
            let directory = (node as NSString).deletingLastPathComponent
            environment["PATH"] = directory + ":" + (base["PATH"] ?? "")
        }
        // A Java file restored at launch starts jdtls before the JDK has been looked for; the last answer does.
        let javaHome = tools.javaHome ?? UserDefaults.standard.string(forKey: LanguageServerStore.javaHomeKey)
        if executable.hasSuffix("/bin/jdtls") || executable.hasSuffix("/bin/kotlin-language-server"), let javaHome {
            environment["JAVA_HOME"] = javaHome
        }
        return environment
    }

    // MARK: - Status

    /// Looks again for node, npm, Go, Python, a JDK and Xcode's servers, then announces the result.
    func refresh() {
        ShellEnvironment.shared.whenReady { [weak self] in
            let shell = ShellEnvironment.shared
            var found = Tools()
            found.node = shell.find("node")
            found.npm = shell.find("npm")
            found.go = shell.find("go")
            found.python = shell.find("python3")
            found.environment = shell.environment
            self?.probeQueue.async {
                // jdtls is an Eclipse application, and current builds refuse to start on anything older than Java 21.
                found.javaHome = LanguageServerStore.output(of: "/usr/libexec/java_home", ["-v", "21+"])
                // Without Xcode or the Command Line Tools, xcrun is a stub that asks to install them; not from here.
                let hasDeveloperTools = FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin")
                    || FileManager.default.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin")
                for tool in ["sourcekit-lsp", "clangd"]
                where hasDeveloperTools && LanguageServerStore.output(of: "/usr/bin/xcrun", ["--find", tool]) != nil {
                    found.xcodeTools.insert(tool)
                }
                DispatchQueue.main.async {
                    self?.tools = found
                    UserDefaults.standard.set(found.javaHome, forKey: LanguageServerStore.javaHomeKey)
                    self?.hasProbed = true
                    NotificationCenter.default.post(name: LanguageServerStore.stateDidChange, object: nil)
                }
            }
        }
    }

    /// The first line a short-lived tool prints (or all of it), or nil when it fails.
    private static func output(of executable: String, _ arguments: [String], wholeOutput: Bool = false) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let line = wholeOutput ? text : text.components(separatedBy: "\n").first ?? ""
        return process.terminationStatus == 0 && !line.isEmpty ? line : nil
    }

    /// jdtls's launcher only checks for Java 21, but the Eclipse bundles inside say what they really need, and one
    /// that asks for more than the JDK offers stops the server at startup with nothing but a log file to show for
    /// it. Better to find that out at install time and say so. Nil when all is well.
    static func javaProblem(inPlugins folder: URL, javaHome: String?) -> String? {
        guard let javaHome, let release = try? String(contentsOfFile: javaHome + "/release", encoding: .utf8),
              let found = release.range(of: #"JAVA_VERSION="\d+"#, options: .regularExpression),
              let available = Int(release[found].filter(\.isNumber)) else { return nil }
        var needed = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".jar") {
            let jar = folder.appendingPathComponent(name).path
            guard let manifest = output(of: "/usr/bin/unzip", ["-p", jar, "META-INF/MANIFEST.MF"], wholeOutput: true) else { continue }
            // Long manifest lines are folded; a fold is a line break followed by one space.
            let text = manifest.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n ", with: "")
            for line in text.components(separatedBy: "\n") where line.hasPrefix("Bundle-RequiredExecutionEnvironment:") {
                let versions = line.components(separatedBy: "JavaSE-").dropFirst().compactMap { Int($0.prefix { $0.isNumber }) }
                needed = max(needed, versions.min() ?? 0)
            }
        }
        guard needed > available else { return nil }
        return "This release of jdtls needs Java \(needed) to run, and the newest JDK on this Mac is Java \(available) "
            + "(\(javaHome)). Install a newer JDK and try again."
    }

    /// The newest milestone (a release, in Eclipse's words). Each one sits in a folder named after its version,
    /// with a latest.txt naming the archive. The nightly snapshot has a fixed address but is built against
    /// unreleased Eclipse, which at times needs a newer Java than any release does; it is only the fallback.
    static func latestJdtlsArchive() -> URL {
        let milestones = "https://download.eclipse.org/jdtls/milestones/"
        let snapshot = URL(string: "https://download.eclipse.org/jdtls/snapshots/jdt-language-server-latest.tar.gz")!
        guard let listing = text(at: milestones) else { return snapshot }
        var versions = Set<String>()
        let pattern = try? NSRegularExpression(pattern: #"milestones/(\d+\.\d+\.\d+)"#)
        let whole = NSRange(location: 0, length: (listing as NSString).length)
        pattern?.enumerateMatches(in: listing, range: whole) { match, _, _ in
            if let range = match?.range(at: 1) { versions.insert((listing as NSString).substring(with: range)) }
        }
        guard let newest = versions.max(by: { $0.compare($1, options: .numeric) == .orderedAscending }),
              let name = text(at: milestones + newest + "/latest.txt")?.trimmingCharacters(in: .whitespacesAndNewlines),
              name.hasSuffix(".tar.gz"), !name.contains("/"),
              let url = URL(string: milestones + newest + "/" + name) else { return snapshot }
        return url
    }

    /// A small text file from the web. Blocks, so never on the main thread.
    private static func text(at address: String) -> String? {
        guard let url = URL(string: address) else { return nil }
        var result: String?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data { result = String(data: data, encoding: .utf8) }
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    func status(of server: ManagedServer) -> Status {
        let managedPath = server.executables.first.flatMap(LanguageServerStore.executable(named:))
        let systemPath: String?
        switch server.source {
        case .xcode:
            systemPath = tools.xcodeTools.contains(server.executables[0]) ? "/usr/bin/xcrun \(server.executables[0])" : nil
        default:
            systemPath = server.executables.lazy.compactMap { ShellEnvironment.shared.find($0) }.first
        }
        if let systemPath { return .system(path: systemPath, alsoManaged: managedPath != nil) }
        if managedPath != nil {
            let file = LanguageServerStore.directory(of: server).appendingPathComponent(".feather-version")
            let version = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .managed(version: version?.isEmpty == false ? version : nil)
        }
        return missingRequirement(of: server).map(Status.needs) ?? .notInstalled
    }

    private func missingRequirement(of server: ManagedServer) -> String? {
        guard hasProbed else { return "Checking…" }
        switch server.source {
        case .npm:
            return tools.node == nil || tools.npm == nil ? "Needs Node.js (node and npm were not found on your PATH)" : nil
        case .jdtls:
            if tools.javaHome == nil { return "Needs a JDK, version 21 or newer (/usr/libexec/java_home found none)" }
            return tools.python == nil ? "Needs Python 3 (jdtls is started by a python3 script)" : nil
        case .gopls:
            return tools.go == nil ? "Needs Go (gopls is built with “go install”)" : nil
        case .rustAnalyzer:
            return nil
        case .github(let release):
            return release.needsJava && tools.javaHome == nil ? "Needs a JDK (/usr/libexec/java_home found none)" : nil
        case .external(let origin):
            return "Not found. " + origin
        case .xcode:
            return "Not found. Provided by Xcode"
        }
    }

    func isBusy(_ server: ManagedServer) -> Bool {
        switch activity[server.id] {
        case .waiting, .running: return true
        case .failed, nil: return false
        }
    }

    func canInstall(_ server: ManagedServer) -> Bool {
        !server.isExternal && !isBusy(server) && missingRequirement(of: server) == nil
    }

    /// Servers "Install All Missing" would fetch: not on the PATH, not installed, and nothing in the way.
    var missingServers: [ManagedServer] {
        ManagedServer.all.filter {
            guard canInstall($0), case .notInstalled = status(of: $0) else { return false }
            return true
        }
    }

    // MARK: - Installing and removing

    private func set(_ activity: Activity?, for server: ManagedServer) {
        self.activity[server.id] = activity
        NotificationCenter.default.post(name: LanguageServerStore.stateDidChange, object: nil, userInfo: ["id": server.id])
    }

    private func announceChange(of server: ManagedServer) {
        NotificationCenter.default.post(name: LanguageServerStore.serversDidChange, object: nil,
                                        userInfo: ["configs": server.configNames])
    }

    /// Installs, or installs again over the top, which is what Update means.
    func install(_ server: ManagedServer) {
        guard canInstall(server) else { return }
        set(.waiting, for: server)
        let tools = self.tools
        queue.async {
            let installer = Installer(server: server, tools: tools) { line in
                DispatchQueue.main.async { self.set(.running(line), for: server) }
            }
            let result = Result { try installer.run() }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.set(nil, for: server)
                    self.announceChange(of: server)
                case .failure(let error):
                    self.set(.failed((error as? InstallError)?.message ?? error.localizedDescription), for: server)
                }
            }
        }
    }

    func remove(_ server: ManagedServer) {
        guard !server.isExternal, !isBusy(server) else { return }
        // Renaming is instant, so the windows can be told straight away; the slow part happens afterwards.
        let directory = LanguageServerStore.directory(of: server)
        let doomed = LanguageServerStore.baseDirectory.appendingPathComponent(".\(server.id).removing-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: directory, to: doomed)
            set(nil, for: server)
            announceChange(of: server)
            queue.async { try? FileManager.default.removeItem(at: doomed) }     // thousands of small files
        } catch {
            set(.failed("Could not remove \(directory.path): \(error.localizedDescription)"), for: server)
        }
    }

    // MARK: - The work itself (install queue)

    private struct InstallError: Error {
        let message: String
    }

    private final class Installer {
        let server: ManagedServer
        let tools: Tools
        let report: (String) -> Void
        private let files = FileManager.default

        init(server: ManagedServer, tools: Tools, report: @escaping (String) -> Void) {
            self.server = server
            self.tools = tools
            self.report = report
        }

        /// Everything is built in a hidden folder next to the real one and renamed into place at the very end, so
        /// a failed or interrupted install leaves the previous state exactly as it was.
        func run() throws {
            let base = LanguageServerStore.baseDirectory
            let final = LanguageServerStore.directory(of: server)
            let prefix = ".\(server.id)."
            try files.createDirectory(at: base, withIntermediateDirectories: true)
            // Left behind only if the app was quit or killed half way through an earlier install.
            for name in (try? files.contentsOfDirectory(atPath: base.path)) ?? [] where name.hasPrefix(prefix) {
                try? files.removeItem(at: base.appendingPathComponent(name))
            }
            let staging = base.appendingPathComponent(prefix + "installing-" + UUID().uuidString, isDirectory: true)
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            do {
                let version = try build(in: staging)
                guard let executable = server.executables.first,
                      files.isExecutableFile(atPath: staging.appendingPathComponent(server.relativePath(of: executable)).path) else {
                    throw InstallError(message: "The download finished, but \(server.executables.first ?? server.id) is not in it.")
                }
                try? (version ?? "").write(to: staging.appendingPathComponent(".feather-version"), atomically: true, encoding: .utf8)
                // An update: the old copy steps aside, and comes back if the new one cannot take its place.
                let previous = base.appendingPathComponent(prefix + "previous-" + UUID().uuidString, isDirectory: true)
                let hadPrevious = (try? files.moveItem(at: final, to: previous)) != nil
                do { try files.moveItem(at: staging, to: final) } catch {
                    if hadPrevious { try? files.moveItem(at: previous, to: final) }
                    throw error
                }
                if hadPrevious { try? files.removeItem(at: previous) }
            } catch {
                try? files.removeItem(at: staging)
                throw error
            }
        }

        /// Returns the version that was installed, when finding it out costs nothing.
        private func build(in directory: URL) throws -> String? {
            switch server.source {
            case .npm(let packages):
                guard let npm = tools.npm, let node = tools.node else { throw InstallError(message: "npm was not found.") }
                // Without a package.json of its own, npm may decide a folder further up is the project.
                try #"{"name": "feather-language-server", "private": true}"#
                    .write(to: directory.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
                var environment = tools.environment
                environment["PATH"] = (node as NSString).deletingLastPathComponent + ":" + (environment["PATH"] ?? "")
                environment["NPM_CONFIG_UPDATE_NOTIFIER"] = "false"
                report("Asking the npm registry…")
                // The "http" log level prints one line per package fetched, which is the progress shown in the row.
                try run(npm, ["install", "--prefix", directory.path, "--no-audit", "--no-fund", "--loglevel=http"] + packages,
                        environment: environment, directory: directory)
                let manifest = directory.appendingPathComponent("node_modules/\(packages[0])/package.json")
                let json = (try? Data(contentsOf: manifest)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
                return (json as? [String: Any])?["version"] as? String

            case .jdtls:
                let archive = directory.appendingPathComponent("jdtls.tar.gz")
                report("Looking for the latest release on download.eclipse.org…")
                _ = try Download(report: report).fetch(LanguageServerStore.latestJdtlsArchive(), to: archive)
                report("Unpacking…")
                try run("/usr/bin/tar", ["-xzf", archive.path, "-C", directory.path],
                        environment: tools.environment, directory: directory)
                try files.removeItem(at: archive)
                // The launcher is a Python script; the archive does not always mark it executable.
                try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent("bin/jdtls").path)
                let plugins = (try? files.contentsOfDirectory(atPath: directory.appendingPathComponent("plugins").path)) ?? []
                report("Checking which Java it needs…")
                if let problem = LanguageServerStore.javaProblem(inPlugins: directory.appendingPathComponent("plugins"),
                                                                 javaHome: tools.javaHome) {
                    throw InstallError(message: problem)
                }
                let core = plugins.first { $0.hasPrefix("org.eclipse.jdt.ls.core_") }
                let version = core?.dropFirst("org.eclipse.jdt.ls.core_".count).split(separator: ".").prefix(3)
                return version?.joined(separator: ".")

            case .rustAnalyzer:
                #if arch(arm64)
                let asset = "rust-analyzer-aarch64-apple-darwin.gz"
                #else
                let asset = "rust-analyzer-x86_64-apple-darwin.gz"
                #endif
                let archive = directory.appendingPathComponent("rust-analyzer.gz")
                let url = URL(string: "https://github.com/rust-lang/rust-analyzer/releases/latest/download/\(asset)")!
                let tag = try Download(report: report).fetch(url, to: archive)
                report("Unpacking…")
                try run("/usr/bin/gunzip", ["-f", archive.path], environment: tools.environment, directory: directory)
                let binary = directory.appendingPathComponent("rust-analyzer").path
                try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary)
                return tag

            case .github(let release):
                let archive = directory.appendingPathComponent(release.asset)
                let url = URL(string: "https://github.com/\(release.repository)/releases/latest/download/\(release.asset)")!
                let tag = try Download(report: report).fetch(url, to: archive)
                let binary = directory.appendingPathComponent(release.binary)
                switch release.packing {
                case .binary:
                    if archive.path != binary.path { try files.moveItem(at: archive, to: binary) }
                case .gzip:
                    report("Unpacking…")
                    try run("/usr/bin/gunzip", ["-f", archive.path], environment: tools.environment, directory: directory)
                    let unpacked = archive.deletingPathExtension()
                    if unpacked.path != binary.path { try files.moveItem(at: unpacked, to: binary) }
                case .zip:
                    report("Unpacking…")
                    try run("/usr/bin/unzip", ["-q", "-o", archive.path, "-d", directory.path],
                            environment: tools.environment, directory: directory)
                    try files.removeItem(at: archive)
                    // Some projects name the file inside after the platform ("lemminx-osx-aarch_64").
                    let platformNamed = archive.deletingPathExtension()
                    if !files.fileExists(atPath: binary.path), files.fileExists(atPath: platformNamed.path) {
                        try files.moveItem(at: platformNamed, to: binary)
                    }
                }
                guard files.fileExists(atPath: binary.path) else {
                    throw InstallError(message: "The download did not contain \(release.binary).")
                }
                try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
                return tag

            case .gopls:
                guard let go = tools.go else { throw InstallError(message: "go was not found.") }
                var environment = tools.environment
                environment["GOBIN"] = directory.path
                report("Building gopls with go install…")
                try run(go, ["install", "golang.org/x/tools/gopls@latest"], environment: environment, directory: directory)
                let version = LanguageServerStore.output(of: directory.appendingPathComponent("gopls").path, ["version"])
                return version?.split(separator: " ").last.map(String.init)

            case .external, .xcode:
                throw InstallError(message: "\(server.serverName) is not something Feather installs.")
            }
        }

        /// Runs a tool with an explicit argument list (never through a shell), reporting each line it prints.
        /// A failure carries the end of the tool's own output, because that is where the reason is.
        private func run(_ executable: String, _ arguments: [String], environment: [String: String], directory: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = directory
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch {
                throw InstallError(message: "Could not start \(executable): \(error.localizedDescription)")
            }
            var tail: [String] = []
            var partial = ""
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                partial += String(decoding: data, as: UTF8.self)
                var lines = partial.components(separatedBy: CharacterSet(charactersIn: "\n\r"))
                partial = lines.removeLast()
                lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard let last = lines.last else { continue }
                tail = Array((tail + lines).suffix(40))
                report(last)
            }
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return }
            if !partial.isEmpty { tail.append(partial) }
            // npm's progress lines would bury the message that matters.
            let useful = tail.filter { !$0.hasPrefix("npm http") }
            let name = (executable as NSString).lastPathComponent
            throw InstallError(message: "\(name) failed (exit code \(process.terminationStatus)).\n"
                               + useful.suffix(12).joined(separator: "\n"))
        }
    }

    /// One file download with progress. Blocks the calling (background) thread until it is done.
    private final class Download: NSObject, URLSessionDownloadDelegate {
        private let report: (String) -> Void
        private let done = DispatchSemaphore(value: 0)
        private var destination: URL?
        private var failure: String?
        private var releaseTag: String?
        private var lastReport = Date.distantPast

        init(report: @escaping (String) -> Void) {
            self.report = report
        }

        /// Returns the GitHub release tag when the download went through a ".../releases/download/<tag>/..." redirect.
        func fetch(_ url: URL, to destination: URL) throws -> String? {
            self.destination = destination
            report("Connecting to \(url.host ?? "the server")…")
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            session.downloadTask(with: url).resume()
            done.wait()
            session.finishTasksAndInvalidate()
            if let failure { throw InstallError(message: "Downloading \(url.absoluteString) failed.\n\(failure)") }
            return releaseTag
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            let parts = request.url?.pathComponents ?? []
            if let index = parts.firstIndex(of: "download"), index > 0, parts[index - 1] == "releases", index + 1 < parts.count {
                releaseTag = parts[index + 1]
            }
            // Never follow a redirect down to plain http.
            completionHandler(request.url?.scheme == "https" ? request : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard Date().timeIntervalSince(lastReport) > 0.1 else { return }
            lastReport = Date()
            let megabytes = { (bytes: Int64) in String(format: "%.1f", Double(bytes) / 1_000_000) }
            report(totalBytesExpectedToWrite > 0
                   ? "Downloading… \(megabytes(totalBytesWritten)) of \(megabytes(totalBytesExpectedToWrite)) MB"
                   : "Downloading… \(megabytes(totalBytesWritten)) MB")
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The temporary file is deleted as soon as this method returns, so it is moved here and now.
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let destination else {
                failure = "The server answered with HTTP status \(status)."
                return
            }
            do { try FileManager.default.moveItem(at: location, to: destination) } catch { failure = error.localizedDescription }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error, failure == nil { failure = error.localizedDescription }
            done.signal()
        }
    }
}
