import Foundation

struct LSPDiagnostic {
    let startLine: Int, startCharacter: Int
    let endLine: Int, endCharacter: Int
    let severity: Int      // 1 error, 2 warning, 3 info, 4 hint
    let message: String
    /// Who reported it ("ts", "pyright") and its rule or error number, for the servers that say. The Problems pane shows them.
    var source: String? = nil
    var code: String? = nil
}

struct LSPCompletionItem {
    let label: String
    let detail: String?
    let kind: Int
    let insertText: String
    let filterText: String
    let sortText: String
    let editStart: (line: Int, character: Int)?
}

struct LSPLocation {
    let url: URL
    let line: Int, character: Int
    let endLine: Int, endCharacter: Int
}

struct LSPTextEdit {
    let startLine: Int, startCharacter: Int
    let endLine: Int, endCharacter: Int
    let newText: String
}

/// One entry of a file's outline. `depth` is how far it is nested, for servers that say; 0 otherwise.
struct LSPSymbol {
    let name: String
    let kind: Int                  // LSP SymbolKind; 0 when it was found without a server
    let container: String?
    let line: Int, character: Int
    let depth: Int
}

struct LSPServerConfig {
    let name: String
    let languageIDs: [String: String]              // file extension -> LSP languageId
    let commands: [(executable: String, arguments: [String])]   // first one found wins
    let installHint: String

    static let all: [LSPServerConfig] = [
        LSPServerConfig(name: "TypeScript",
                        languageIDs: ["ts": "typescript", "tsx": "typescriptreact", "js": "javascript",
                                      "jsx": "javascriptreact", "mjs": "javascript", "cjs": "javascript"],
                        commands: [("typescript-language-server", ["--stdio"])],
                        installHint: "npm install -g typescript-language-server typescript"),
        LSPServerConfig(name: "Python", languageIDs: ["py": "python", "pyw": "python"],
                        commands: [("pyright-langserver", ["--stdio"]), ("basedpyright-langserver", ["--stdio"]), ("pylsp", [])],
                        installHint: "npm install -g pyright"),
        LSPServerConfig(name: "Java", languageIDs: ["java": "java"],
                        commands: [("jdtls", ["-data", "{workspace}"])],
                        installHint: "brew install jdtls"),
        LSPServerConfig(name: "Dart", languageIDs: ["dart": "dart"],
                        commands: [("dart", ["language-server", "--client-id", "feather"])],
                        installHint: "Install Flutter or the Dart SDK"),
        LSPServerConfig(name: "Swift", languageIDs: ["swift": "swift"],
                        commands: [("/usr/bin/xcrun", ["sourcekit-lsp"])],
                        installHint: "Install Xcode"),
        LSPServerConfig(name: "C/C++", languageIDs: ["c": "c", "h": "c", "cpp": "cpp", "cc": "cpp", "cxx": "cpp",
                                                     "hpp": "cpp", "hh": "cpp", "m": "objective-c", "mm": "objective-cpp"],
                        commands: [("/usr/bin/xcrun", ["clangd"])],
                        installHint: "Install Xcode"),
        LSPServerConfig(name: "Go", languageIDs: ["go": "go"], commands: [("gopls", [])],
                        installHint: "go install golang.org/x/tools/gopls@latest"),
        LSPServerConfig(name: "Rust", languageIDs: ["rs": "rust"], commands: [("rust-analyzer", [])],
                        installHint: "rustup component add rust-analyzer"),
        LSPServerConfig(name: "Kotlin", languageIDs: ["kt": "kotlin", "kts": "kotlin"],
                        commands: [("kotlin-language-server", [])],
                        installHint: "brew install kotlin-language-server"),
        LSPServerConfig(name: "HTML", languageIDs: ["html": "html", "htm": "html"],
                        commands: [("vscode-html-language-server", ["--stdio"])],
                        installHint: "npm install -g vscode-langservers-extracted"),
        LSPServerConfig(name: "CSS", languageIDs: ["css": "css", "scss": "scss", "less": "less"],
                        commands: [("vscode-css-language-server", ["--stdio"])],
                        installHint: "npm install -g vscode-langservers-extracted"),
        LSPServerConfig(name: "JSON", languageIDs: ["json": "json", "jsonc": "jsonc"],
                        commands: [("vscode-json-language-server", ["--stdio"])],
                        installHint: "npm install -g vscode-langservers-extracted"),
        LSPServerConfig(name: "YAML", languageIDs: ["yaml": "yaml", "yml": "yaml"],
                        commands: [("yaml-language-server", ["--stdio"])],
                        installHint: "npm install -g yaml-language-server"),
        LSPServerConfig(name: "Bash", languageIDs: ["sh": "shellscript", "bash": "shellscript", "zsh": "shellscript"],
                        commands: [("bash-language-server", ["start"])],
                        installHint: "npm install -g bash-language-server"),
        LSPServerConfig(name: "XML", languageIDs: ["xml": "xml", "xsd": "xml", "xsl": "xml", "xslt": "xml", "fxml": "xml",
                                                   "plist": "xml", "svg": "xml"],
                        commands: [("lemminx", [])],
                        installHint: "Install it from the Languages pane"),
        LSPServerConfig(name: "TOML", languageIDs: ["toml": "toml"], commands: [("taplo", ["lsp", "stdio"])],
                        installHint: "brew install taplo"),
        LSPServerConfig(name: "Markdown", languageIDs: ["md": "markdown", "markdown": "markdown"],
                        commands: [("marksman", ["server"])],
                        installHint: "brew install marksman"),
        LSPServerConfig(name: "SQL", languageIDs: ["sql": "sql"],
                        commands: [("sqls", [])],
                        installHint: "brew install sqls"),
        // Dockerfiles have no extension; see `key(for:)`.
        LSPServerConfig(name: "Docker", languageIDs: ["dockerfile": "dockerfile"],
                        commands: [("docker-langserver", ["--stdio"])],
                        installHint: "npm install -g dockerfile-language-server-nodejs"),
        LSPServerConfig(name: "PHP", languageIDs: ["php": "php"], commands: [("intelephense", ["--stdio"])],
                        installHint: "npm install -g intelephense"),
        LSPServerConfig(name: "Svelte", languageIDs: ["svelte": "svelte"], commands: [("svelteserver", ["--stdio"])],
                        installHint: "npm install -g svelte-language-server"),
        LSPServerConfig(name: "Prisma", languageIDs: ["prisma": "prisma"],
                        commands: [("prisma-language-server", ["--stdio"])],
                        installHint: "npm install -g @prisma/language-server"),
    ]

    /// What `languageIDs` is looked up by: the extension, or for the files that are known by their name
    /// (Dockerfile, Dockerfile.dev, api.dockerfile) that name.
    static func key(for url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name == "dockerfile" || name.hasPrefix("dockerfile.") || name == "containerfile" { return "dockerfile" }
        return url.pathExtension.lowercased()
    }

    static func config(for url: URL) -> LSPServerConfig? {
        let key = key(for: url)
        return all.first { $0.languageIDs[key] != nil }
    }

    /// The user's own copy, from their PATH, comes first: it is their setup and their version. Otherwise the copy
    /// Feather installed, if there is one.
    func resolve(in shell: ShellEnvironment) -> (executable: String, arguments: [String])? {
        for command in commands {
            if let path = shell.find(command.executable) { return (path, command.arguments) }
        }
        for command in commands {
            if let path = LanguageServerStore.executable(named: command.executable) { return (path, command.arguments) }
        }
        return nil
    }
}

/// Owns one lazily started language server per language, and keeps open documents in sync with it.
/// Each window has its own manager, because each window has its own project root.
final class LSPManager {

    var onDiagnostics: ((URL, [LSPDiagnostic]) -> Void)?
    var onStatusChange: (() -> Void)?
    var rootURL: URL? {
        didSet {
            guard rootURL != oldValue else { return }
            stopAll()
            documents.keys.forEach { withServer(for: $0) { _ in } }
        }
    }

    private final class Server {
        let config: LSPServerConfig
        let client: LSPClient
        let executable: String
        var isReady = false
        var queued: [() -> Void] = []
        var versions: [URL: Int] = [:]          // documents the server has open
        var triggerCharacters = Set<Character>()
        /// Whether the server takes range edits. When it does, `shadows` holds each open document exactly as the
        /// server last saw it, in UTF-16, to work the next edit out from.
        var isIncremental = false
        var shadows: [URL: [unichar]] = [:]
        var completionRequest: Int?
        // What the server said it can do when it started. Asking for anything else earns an error, not an answer.
        var formatsDocuments = false
        var formatsRanges = false
        var listsSymbols = false
        init(config: LSPServerConfig, client: LSPClient, executable: String) {
            self.config = config
            self.client = client
            self.executable = executable
        }
    }

    private var servers: [String: Server] = [:]
    private var unavailable: [String: Int] = [:]     // config name -> failed starts
    private var missing = Set<String>()
    private var documents: [URL: () -> String?] = [:]
    private var pendingChanges: [URL: DispatchWorkItem] = [:]
    private static let maxDocumentLength = 1_000_000

    private var storeObserver: NSObjectProtocol?

    init() {
        storeObserver = NotificationCenter.default.addObserver(forName: LanguageServerStore.serversDidChange, object: nil,
                                                               queue: .main) { [weak self] in self?.serversDidChange($0) }
    }

    deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    // MARK: - Document lifecycle

    /// `length` is in UTF-16 units, which the text storage knows without producing the text.
    func open(_ url: URL, length: Int, text: @escaping () -> String?) {
        guard LSPServerConfig.config(for: url) != nil, length <= LSPManager.maxDocumentLength else { return }
        documents[url] = text
        withServer(for: url) { _ in }
    }

    func changed(_ url: URL) {
        guard documents[url] != nil else { return }
        pendingChanges[url]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush(url) }
        pendingChanges[url] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func saved(_ url: URL) {
        guard documents[url] != nil else { return }
        flush(url)
        withServer(for: url) { $0.client.notify("textDocument/didSave", ["textDocument": ["uri": url.absoluteString]]) }
    }

    func close(_ url: URL) {
        guard documents.removeValue(forKey: url) != nil else { return }
        pendingChanges.removeValue(forKey: url)?.cancel()
        guard let config = LSPServerConfig.config(for: url), let server = servers[config.name],
              server.versions.removeValue(forKey: url) != nil else { return }
        server.shadows[url] = nil
        server.client.notify("textDocument/didClose", ["textDocument": ["uri": url.absoluteString]])
    }

    private func flush(_ url: URL) {
        guard let work = pendingChanges.removeValue(forKey: url) else { return }
        work.cancel()
        withServer(for: url) { [weak self] server in
            guard let text = self?.documents[url]?(), let version = server.versions[url] else { return }
            var change: [String: Any] = ["text": text]
            if let shadow = server.shadows[url] {
                // One range edit covering everything between the unchanged start and the unchanged end. Typing
                // sends a few characters instead of the file, and the server re-parses as little as it can.
                let current = DocumentSync.utf16(text)
                guard let edit = DocumentSync.edit(from: shadow, to: current) else { return }
                server.shadows[url] = current
                change = edit.contentChange
            }
            server.versions[url] = version + 1
            server.client.notify("textDocument/didChange", [
                "textDocument": ["uri": url.absoluteString, "version": version + 1],
                "contentChanges": [change],
            ])
        }
    }

    // MARK: - Status

    func statusText(for url: URL?) -> String? {
        guard let url, let config = LSPServerConfig.config(for: url) else { return nil }
        if !isAllowed { return nil }
        if let server = servers[config.name] { return server.isReady ? "\(config.name) checking on" : "\(config.name) checking starting…" }
        if missing.contains(config.name) { return "\(config.name) checking off" }
        return nil
    }

    /// False when the language has no server, the server is not installed, or it is still starting up.
    func isReady(for url: URL?) -> Bool {
        guard let url, documents[url] != nil, let config = LSPServerConfig.config(for: url) else { return false }
        return servers[config.name]?.isReady == true
    }

    /// The status bar's tooltip while the server is missing. Language support will install from the Extensions
    /// window once the catalogue is up; until then a server on the Mac is used, and this says how to get one.
    func installHint(for url: URL?) -> String? {
        guard let url, let config = LSPServerConfig.config(for: url), missing.contains(config.name) else { return nil }
        return "The code helper for this language is not installed, so mistakes are not underlined and suggestions are basic. Language extensions are on their way; until then, paste this into the terminal:\n\(config.installHint)"
    }

    /// Whether the server for this kind of file is running (or starting). The Problems pane drops what a server
    /// reported once that server is gone, including for files that were never open in a tab.
    func hasServer(for url: URL) -> Bool {
        guard let config = LSPServerConfig.config(for: url) else { return false }
        return servers[config.name] != nil
    }

    func triggerCharacters(for url: URL?) -> Set<Character> {
        guard let url, let config = LSPServerConfig.config(for: url) else { return [] }
        return servers[config.name]?.triggerCharacters ?? []
    }

    /// Whether Format Document (or, with `selection`, Format Selection) has a server to go to.
    func canFormat(_ url: URL?, selection: Bool = false) -> Bool {
        guard isReady(for: url), let url, let server = LSPServerConfig.config(for: url).flatMap({ servers[$0.name] }) else { return false }
        return selection ? server.formatsRanges : server.formatsDocuments
    }

    func canListSymbols(_ url: URL?) -> Bool {
        guard isReady(for: url), let url, let config = LSPServerConfig.config(for: url) else { return false }
        return servers[config.name]?.listsSymbols == true
    }

    /// False while the folder is open in Restricted Mode: a language server runs the project's own plugins and
    /// build scripts, so none is started. Documents are still remembered, and get their server once trusted.
    var isAllowed = true {
        didSet {
            guard isAllowed != oldValue else { return }
            if isAllowed {
                for url in documents.keys { withServer(for: url) { _ in } }
            } else {
                let open = servers.values.flatMap { $0.versions.keys }
                stopAll()
                open.forEach { onDiagnostics?($0, []) }
            }
            onStatusChange?()
        }
    }

    func stopAll() {
        servers.values.forEach { $0.client.stop() }
        servers = [:]
        unavailable = [:]
        pendingChanges.values.forEach { $0.cancel() }
        pendingChanges = [:]
        onStatusChange?()
    }

    // MARK: - Requests

    private func position(_ url: URL, _ line: Int, _ character: Int) -> [String: Any] {
        ["textDocument": ["uri": url.absoluteString], "position": ["line": line, "character": character]]
    }

    func completion(_ url: URL, line: Int, character: Int, completion: @escaping ([LSPCompletionItem]) -> Void) {
        guard documents[url] != nil else { return completion([]) }
        flush(url)
        withServer(for: url) { server in
            // A newer request makes the previous answer worthless: the server is told to stop working on it and
            // its callback is dropped. The editor numbers its requests, so it never waits for the old one.
            if let previous = server.completionRequest { server.client.cancel(previous) }
            // Thousands of items may come back; they are turned into values on the client's read queue.
            let parse: (Any?) -> Any? = { result in
                let raw = (result as? [String: Any])?["items"] as? [[String: Any]] ?? result as? [[String: Any]] ?? []
                return raw.prefix(1500).compactMap(LSPManager.parseCompletion)
            }
            var id = 0
            id = server.client.request("textDocument/completion", self.position(url, line, character), transform: parse) {
                [weak server] result in
                if server?.completionRequest == id { server?.completionRequest = nil }
                completion(result as? [LSPCompletionItem] ?? [])
            }
            server.completionRequest = id
        }
    }

    func definition(_ url: URL, line: Int, character: Int, completion: @escaping (LSPLocation?) -> Void) {
        guard documents[url] != nil else { return completion(nil) }
        flush(url)
        withServer(for: url) { server in
            server.client.request("textDocument/definition", self.position(url, line, character)) { result in
                let first = (result as? [[String: Any]])?.first ?? result as? [String: Any]
                completion(first.flatMap(LSPManager.parseLocation))
            }
        }
    }

    func references(_ url: URL, line: Int, character: Int, completion: @escaping ([LSPLocation]) -> Void) {
        guard documents[url] != nil else { return completion([]) }
        flush(url)
        withServer(for: url) { server in
            var params = self.position(url, line, character)
            params["context"] = ["includeDeclaration": true]
            server.client.request("textDocument/references", params) { result in
                completion((result as? [[String: Any]] ?? []).compactMap(LSPManager.parseLocation))
            }
        }
    }

    /// Completion receives the edits grouped by file, or nil when the server refused the rename.
    func rename(_ url: URL, line: Int, character: Int, newName: String,
                completion: @escaping ([URL: [LSPTextEdit]]?) -> Void) {
        guard documents[url] != nil else { return completion(nil) }
        flush(url)
        withServer(for: url) { server in
            var params = self.position(url, line, character)
            params["newName"] = newName
            server.client.request("textDocument/rename", params) { result in
                completion((result as? [String: Any]).map(LSPManager.parseWorkspaceEdit))
            }
        }
    }

    /// The edits that format the document, or just `range` of it. Nil when no server can do that, or it failed;
    /// an empty list means the text is already formatted.
    func formatting(_ url: URL, range: (startLine: Int, startCharacter: Int, endLine: Int, endCharacter: Int)? = nil,
                    completion: @escaping ([LSPTextEdit]?) -> Void) {
        guard canFormat(url, selection: range != nil) else { return completion(nil) }
        flush(url)
        withServer(for: url) { server in
            let settings = Settings.shared
            let config = EditorConfigStore.shared.properties(for: url)          // cached; the file's own indentation wins
            var params: [String: Any] = [
                "textDocument": ["uri": url.absoluteString],
                "options": ["tabSize": config?.tabWidth ?? settings.tabWidth, "insertSpaces": config?.useSpaces ?? settings.useSpaces],
            ]
            if let range {
                params["range"] = ["start": ["line": range.startLine, "character": range.startCharacter],
                                   "end": ["line": range.endLine, "character": range.endCharacter]]
            }
            server.client.request(range == nil ? "textDocument/formatting" : "textDocument/rangeFormatting", params) { result in
                // A server with nothing to change answers null or []; one that failed answers with an error,
                // which the client also hands over as nil. Either way there is nothing to apply.
                completion((result as? [[String: Any]])?.compactMap(LSPManager.parseTextEdit) ?? (result is NSNull ? [] : nil))
            }
        }
    }

    /// The file's outline in document order, or nil when no server can give one.
    func documentSymbols(_ url: URL, completion: @escaping ([LSPSymbol]?) -> Void) {
        guard canListSymbols(url) else { return completion(nil) }
        flush(url)
        withServer(for: url) { server in
            server.client.request("textDocument/documentSymbol", ["textDocument": ["uri": url.absoluteString]],
                                  transform: { ($0 as? [[String: Any]]).map(LSPManager.parseSymbols) }) { result in
                completion(result as? [LSPSymbol])
            }
        }
    }

    func hover(_ url: URL, line: Int, character: Int, completion: @escaping (String?) -> Void) {
        guard documents[url] != nil else { return completion(nil) }
        flush(url)
        withServer(for: url) { server in
            server.client.request("textDocument/hover", self.position(url, line, character)) { result in
                // Servers answer in Markdown; drop the code fences since the popover shows plain text.
                let text = LSPManager.markupText((result as? [String: Any])?["contents"])
                    .components(separatedBy: "\n").filter { !$0.hasPrefix("```") }.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                completion(text.isEmpty ? nil : text)
            }
        }
    }

    // MARK: - Server management

    /// Runs `body` once the right server is initialised and has this document open. No-op if there is no server.
    private func withServer(for url: URL, _ body: @escaping (Server) -> Void) {
        guard isAllowed, let config = LSPServerConfig.config(for: url) else { return }
        ShellEnvironment.shared.whenReady { [weak self] in
            guard let self, self.documents[url] != nil || self.servers[config.name]?.versions[url] != nil,
                  let server = self.servers[config.name] ?? self.start(config, near: url) else { return }
            let work = {
                if server.versions[url] == nil, let text = self.documents[url]?(),
                   let languageID = config.languageIDs[LSPServerConfig.key(for: url)] {
                    server.versions[url] = 1
                    if server.isIncremental { server.shadows[url] = DocumentSync.utf16(text) }
                    server.client.notify("textDocument/didOpen", ["textDocument": [
                        "uri": url.absoluteString, "languageId": languageID, "version": 1, "text": text,
                    ]])
                }
                body(server)
            }
            if server.isReady { work() } else { server.queued.append(work) }
        }
    }

    private func start(_ config: LSPServerConfig, near url: URL) -> Server? {
        guard !missing.contains(config.name), unavailable[config.name, default: 0] < 3 else { return nil }
        let shell = ShellEnvironment.shared
        guard let command = config.resolve(in: shell) else {
            missing.insert(config.name)
            onStatusChange?()
            return nil
        }
        let root = rootURL ?? url.deletingLastPathComponent()
        let arguments = command.arguments.map { $0 == "{workspace}" ? LSPManager.workspaceCache(for: root) : $0 }
        let environment = LanguageServerStore.shared.environment(for: command.executable, base: shell.environment)
        let client = LSPClient(executable: command.executable, arguments: arguments,
                               environment: environment, directory: root)
        let server = Server(config: config, client: client, executable: command.executable)

        client.onNotification = { [weak self] method, params in
            guard method == "textDocument/publishDiagnostics",
                  let uri = params["uri"] as? String, let fileURL = URL(string: uri) else { return }
            let items = (params["diagnostics"] as? [[String: Any]] ?? []).compactMap(LSPManager.parseDiagnostic)
            self?.onDiagnostics?(fileURL.standardizedFileURL, items)
        }
        client.onExit = { [weak self, weak server] in
            guard let self, let server, self.servers[config.name] === server else { return }
            self.servers[config.name] = nil
            self.unavailable[config.name, default: 0] += 1
            for url in server.versions.keys { self.onDiagnostics?(url, []) }
            self.onStatusChange?()
        }
        do { try client.start() } catch {
            unavailable[config.name, default: 0] += 1
            return nil
        }
        servers[config.name] = server
        onStatusChange?()

        let capabilities: [String: Any] = [
            "general": ["positionEncodings": ["utf-16"]],
            "workspace": ["workspaceFolders": true, "configuration": true,
                          "workspaceEdit": ["documentChanges": true]],
            "textDocument": [
                "synchronization": ["didSave": true],
                "publishDiagnostics": ["relatedInformation": false],
                "completion": ["completionItem": ["snippetSupport": false, "documentationFormat": ["plaintext"]]],
                "hover": ["contentFormat": ["plaintext", "markdown"]],
                "definition": ["linkSupport": true],
                "references": [String: Any](),
                "rename": ["prepareSupport": false],
                "formatting": [String: Any](),
                "rangeFormatting": [String: Any](),
                "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
            ],
        ]
        client.request("initialize", [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "clientInfo": ["name": "Feather"],
            "rootUri": root.absoluteString,
            "rootPath": root.path,
            "workspaceFolders": [["uri": root.absoluteString, "name": root.lastPathComponent]],
            "capabilities": capabilities,
        ]) { [weak self, weak server] result in
            guard let self, let server, self.servers[config.name] === server else { return }
            guard let result = result as? [String: Any] else {
                // It runs but will not initialise (typescript-language-server without a usable TypeScript, say).
                // Left alone, the status bar would say it is starting for ever.
                server.client.stop()
                self.servers[config.name] = nil
                self.unavailable[config.name, default: 0] += 1
                self.onStatusChange?()
                return
            }
            let capabilities = result["capabilities"] as? [String: Any]
            // Either the sync kind itself or an options object holding it; 2 means the server takes range edits.
            let sync = capabilities?["textDocumentSync"]
            server.isIncremental = (sync as? Int ?? (sync as? [String: Any])?["change"] as? Int) == 2
            let provider = capabilities?["completionProvider"] as? [String: Any]
            let triggers = provider?["triggerCharacters"] as? [String] ?? []
            server.triggerCharacters = Set(triggers.compactMap { $0.count == 1 ? $0.first : nil })
            server.formatsDocuments = LSPManager.isProvided(capabilities?["documentFormattingProvider"])
            server.formatsRanges = LSPManager.isProvided(capabilities?["documentRangeFormattingProvider"])
            server.listsSymbols = LSPManager.isProvided(capabilities?["documentSymbolProvider"])
            server.client.notify("initialized", [String: Any]())
            server.isReady = true
            server.queued.forEach { $0() }
            server.queued = []
            self.onStatusChange?()
        }
        return server
    }

    /// A server was installed, updated or removed in the Language Servers window. Documents that were waiting
    /// for one get it now, and a running copy from Feather's folder is replaced, since its files just changed
    /// underneath it (or are gone).
    private func serversDidChange(_ notification: Notification) {
        guard let names = notification.userInfo?["configs"] as? [String] else { return }
        for name in names {
            missing.remove(name)
            unavailable[name] = nil
            guard let server = servers[name], LanguageServerStore.isManaged(server.executable) else { continue }
            server.client.stop()
            servers[name] = nil
            for url in server.versions.keys { onDiagnostics?(url, []) }
        }
        for url in documents.keys where LSPServerConfig.config(for: url).map({ names.contains($0.name) }) == true {
            withServer(for: url) { _ in }
        }
        onStatusChange?()
    }

    /// jdtls needs a private data directory per project.
    private static func workspaceCache(for root: URL) -> String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let name = root.path.replacingOccurrences(of: "/", with: "_")
        let directory = caches.appendingPathComponent("Feather/jdtls/\(name)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.path
    }

    // MARK: - Parsing

    private static func parseRange(_ value: Any?) -> (Int, Int, Int, Int)? {
        guard let range = value as? [String: Any],
              let start = range["start"] as? [String: Any], let end = range["end"] as? [String: Any],
              let sl = start["line"] as? Int, let sc = start["character"] as? Int,
              let el = end["line"] as? Int, let ec = end["character"] as? Int else { return nil }
        return (sl, sc, el, ec)
    }

    /// A capability is either `true` or an options object; `false`, null and absent all mean no.
    static func isProvided(_ capability: Any?) -> Bool {
        if let flag = capability as? Bool { return flag }
        return capability is [String: Any]
    }

    static func parseTextEdit(_ raw: [String: Any]) -> LSPTextEdit? {
        guard let (sl, sc, el, ec) = parseRange(raw["range"]), let text = raw["newText"] as? String else { return nil }
        return LSPTextEdit(startLine: sl, startCharacter: sc, endLine: el, endCharacter: ec, newText: text)
    }

    /// Servers answer in one of two shapes: `DocumentSymbol[]`, a tree with children, or the older flat
    /// `SymbolInformation[]`, where each entry names its container instead. Both come out flat, in file order.
    static func parseSymbols(_ raw: [[String: Any]]) -> [LSPSymbol] {
        var found: [LSPSymbol] = []
        func walk(_ items: [[String: Any]], depth: Int, container: String?) {
            for item in items {
                guard let name = item["name"] as? String else { continue }
                let location = item["location"] as? [String: Any]
                guard let (line, character, _, _) = parseRange(item["selectionRange"]) ?? parseRange(item["range"])
                        ?? parseRange(location?["range"]) else { continue }
                found.append(LSPSymbol(name: name, kind: item["kind"] as? Int ?? 0,
                                       container: item["containerName"] as? String ?? container,
                                       line: line, character: character, depth: depth))
                // Far enough for any real code, and a bound on a malformed answer.
                if depth < 12, let children = item["children"] as? [[String: Any]] { walk(children, depth: depth + 1, container: name) }
            }
        }
        walk(raw, depth: 0, container: nil)
        return found.sorted { ($0.line, $0.character) < ($1.line, $1.character) }
    }

    private static func parseDiagnostic(_ raw: [String: Any]) -> LSPDiagnostic? {
        guard let (sl, sc, el, ec) = parseRange(raw["range"]) else { return nil }
        // The code is a string for some servers and a number for others.
        let code = raw["code"] as? String ?? (raw["code"] as? Int).map(String.init)
        return LSPDiagnostic(startLine: sl, startCharacter: sc, endLine: el, endCharacter: ec,
                             severity: raw["severity"] as? Int ?? 1, message: raw["message"] as? String ?? "",
                             source: raw["source"] as? String, code: code)
    }

    private static func parseLocation(_ raw: [String: Any]) -> LSPLocation? {
        let uri = raw["uri"] as? String ?? raw["targetUri"] as? String
        let range = parseRange(raw["range"]) ?? parseRange(raw["targetSelectionRange"]) ?? parseRange(raw["targetRange"])
        guard let uri, let url = URL(string: uri), url.isFileURL, let (sl, sc, el, ec) = range else { return nil }
        return LSPLocation(url: url.standardizedFileURL, line: sl, character: sc, endLine: el, endCharacter: ec)
    }

    private static func parseWorkspaceEdit(_ raw: [String: Any]) -> [URL: [LSPTextEdit]] {
        var grouped: [String: [[String: Any]]] = raw["changes"] as? [String: [[String: Any]]] ?? [:]
        for change in raw["documentChanges"] as? [[String: Any]] ?? [] {
            guard let uri = (change["textDocument"] as? [String: Any])?["uri"] as? String,
                  let edits = change["edits"] as? [[String: Any]] else { continue }
            grouped[uri, default: []] += edits
        }
        var result: [URL: [LSPTextEdit]] = [:]
        for (uri, edits) in grouped {
            guard let url = URL(string: uri), url.isFileURL else { continue }
            result[url.standardizedFileURL] = edits.compactMap(parseTextEdit)
        }
        return result
    }

    private static let snippetPlaceholder = try! NSRegularExpression(pattern: #"\$\{\d+:([^}]*)\}"#)
    private static let snippetTabStop = try! NSRegularExpression(pattern: #"\$\{\d+\}|\$\d+"#)

    private static func parseCompletion(_ raw: [String: Any]) -> LSPCompletionItem? {
        guard let label = raw["label"] as? String else { return nil }
        let edit = raw["textEdit"] as? [String: Any]
        var text = edit?["newText"] as? String ?? raw["insertText"] as? String ?? label
        if raw["insertTextFormat"] as? Int == 2, text.contains("$") {
            for (regex, template) in [(snippetPlaceholder, "$1"), (snippetTabStop, "")] {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                                      withTemplate: template)
            }
        }
        let range = parseRange(edit?["range"]) ?? parseRange(edit?["insert"])
        return LSPCompletionItem(label: label, detail: raw["detail"] as? String, kind: raw["kind"] as? Int ?? 0,
                                 insertText: text, filterText: raw["filterText"] as? String ?? label,
                                 sortText: raw["sortText"] as? String ?? label,
                                 editStart: range.map { ($0.0, $0.1) })
    }

    private static func markupText(_ contents: Any?) -> String {
        if let text = contents as? String { return text }
        if let object = contents as? [String: Any] { return object["value"] as? String ?? "" }
        if let list = contents as? [Any] { return list.map(markupText).filter { !$0.isEmpty }.joined(separator: "\n\n") }
        return ""
    }
}

enum TextEdits {
    /// Applies LSP edits (UTF-16 line/character ranges) to a whole document.
    static func apply(_ edits: [LSPTextEdit], to text: String) -> String {
        let result = NSMutableString(string: text)
        for (range, replacement) in ranges(for: edits, in: result).sorted(by: { $0.0.location > $1.0.location }) {
            result.replaceCharacters(in: range, with: replacement)
        }
        return result as String
    }

    static func ranges(for edits: [LSPTextEdit], in text: NSString) -> [(NSRange, String)] {
        var lineStarts = [0]
        var search = NSRange(location: 0, length: text.length)
        while search.length > 0 {
            let found = text.range(of: "\n", options: .literal, range: search)
            if found.location == NSNotFound { break }
            lineStarts.append(NSMaxRange(found))
            search = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
        }
        func offset(_ line: Int, _ character: Int) -> Int {
            guard line < lineStarts.count else { return text.length }
            let lineEnd = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : text.length
            return min(lineStarts[line] + max(0, character), max(lineStarts[line], lineEnd))
        }
        return edits.map { edit in
            let start = offset(edit.startLine, edit.startCharacter)
            let end = max(start, offset(edit.endLine, edit.endCharacter))
            return (NSRange(location: start, length: end - start), edit.newText)
        }
    }
}
