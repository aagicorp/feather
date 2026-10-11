import Foundation

/// The collections, environments and history of one window: files in the project's `.feather/api` (shared
/// through git) and in the person's own folder under Application Support. Loaded when the API pane is first
/// shown, saved atomically on every change, and re-read when something else (a `git pull`, a text editor)
/// changes the files.
final class APIWorkspace {
    static let didChange = Notification.Name("FeatherAPIWorkspaceDidChange")

    /// Where personal collections, history and the run log go. Tests point it at a scratch folder.
    static var personalBaseDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Feather/api", isDirectory: true)
    }()
    static var secrets: SecretStore = KeychainSecretStore()
    static let historyLimit = 500

    struct Stored<T: Codable & Identifiable> {
        var value: T
        var location: APIStorageLocation
        var url: URL
    }

    /// The project folder, or nil when no folder is open (then only personal items exist).
    private(set) var projectRoot: URL?
    private(set) var collections: [Stored<APICollection>] = []
    private(set) var environments: [Stored<APIEnvironment>] = []
    private(set) var history: [APIHistoryEntry] = []
    /// Cookies from answers, sent back with later requests; kept in the personal folder, never the project.
    private(set) lazy var cookies = APICookieJar(file: personalDirectory.appendingPathComponent("cookies.json"))
    /// Values captured from answers this session, per collection id (environment-scoped captures go under "").
    private(set) var captured: [String: [String: String]] = [:]
    private var watcher: DirectoryWatcher?
    private var ownWrites: Set<String> = []
    private var reloadWork: DispatchWorkItem?

    init(projectRoot: URL?) {
        self.projectRoot = projectRoot?.standardizedFileURL
    }

    // MARK: Folders

    var projectDirectory: URL? { projectRoot?.appendingPathComponent(".feather/api", isDirectory: true) }
    var personalDirectory: URL {
        let key = projectRoot.map { String($0.path.hashValue, radix: 36).replacingOccurrences(of: "-", with: "n") } ?? "no-folder"
        return APIWorkspace.personalBaseDirectory.appendingPathComponent("personal/" + key, isDirectory: true)
    }
    private var historyFile: URL { APIWorkspace.personalBaseDirectory.appendingPathComponent("history/" + (personalDirectory.lastPathComponent) + ".jsonl") }

    func directory(for location: APIStorageLocation) -> URL? {
        location == .project ? projectDirectory : personalDirectory
    }

    // MARK: Loading

    /// Reads everything from disk. Safe to call again; unknown or broken files are skipped and reported.
    @discardableResult
    func load() -> [String] {
        var problems: [String] = []
        var found: [Stored<APICollection>] = []
        var foundEnvironments: [Stored<APIEnvironment>] = []
        for location in [APIStorageLocation.project, .personal] {
            guard let directory = directory(for: location) else { continue }
            for url in files(in: directory.appendingPathComponent("collections")) {
                do { found.append(Stored(value: try read(APICollection.self, url), location: location, url: url)) }
                catch { problems.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            for url in files(in: directory.appendingPathComponent("environments")) {
                do { foundEnvironments.append(Stored(value: try read(APIEnvironment.self, url), location: location, url: url)) }
                catch { problems.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
        }
        collections = found.sorted { $0.value.name.localizedCaseInsensitiveCompare($1.value.name) == .orderedAscending }
        environments = foundEnvironments.sorted { $0.value.name.localizedCaseInsensitiveCompare($1.value.name) == .orderedAscending }
        history = loadHistory()
        startWatching()
        NotificationCenter.default.post(name: APIWorkspace.didChange, object: self)
        return problems
    }

    private func files(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try APIJSON.decoder.decode(type, from: data)
    }

    // MARK: Saving

    /// Writes a collection where it lives (or, for a new one, where `location` says) and remembers it.
    @discardableResult
    func save(_ collection: APICollection, location: APIStorageLocation? = nil) -> Bool {
        let existing = collections.firstIndex { $0.value.id == collection.id }
        let where_ = existing.map { collections[$0].location } ?? location ?? (projectRoot == nil ? .personal : .project)
        guard let directory = directory(for: where_) else { return false }
        let url = existing.map { collections[$0].url } ?? unusedURL(in: directory.appendingPathComponent("collections"), name: collection.name)
        var toWrite = collection
        toWrite.variables = stripSecrets(collection.variables, scope: collection.id)
        guard write(toWrite, to: url) else { return false }
        let stored = Stored(value: collection, location: where_, url: url)
        if let existing { collections[existing] = stored } else { collections.append(stored) }
        NotificationCenter.default.post(name: APIWorkspace.didChange, object: self)
        return true
    }

    @discardableResult
    func save(_ environment: APIEnvironment, location: APIStorageLocation? = nil) -> Bool {
        let existing = environments.firstIndex { $0.value.id == environment.id }
        let where_ = existing.map { environments[$0].location } ?? location ?? (projectRoot == nil ? .personal : .project)
        guard let directory = directory(for: where_) else { return false }
        let url = existing.map { environments[$0].url } ?? unusedURL(in: directory.appendingPathComponent("environments"), name: environment.name)
        var toWrite = environment
        toWrite.variables = stripSecrets(environment.variables, scope: environment.id)
        guard write(toWrite, to: url) else { return false }
        let stored = Stored(value: environment, location: where_, url: url)
        if let existing { environments[existing] = stored } else { environments.append(stored) }
        NotificationCenter.default.post(name: APIWorkspace.didChange, object: self)
        return true
    }

    func delete(collectionID: String) {
        guard let index = collections.firstIndex(where: { $0.value.id == collectionID }) else { return }
        for variable in collections[index].value.variables where variable.secret { APIWorkspace.secrets.delete(scope: collectionID, name: variable.name) }
        ownWrites.insert(collections[index].url.path)
        try? FileManager.default.removeItem(at: collections[index].url)
        collections.remove(at: index)
        NotificationCenter.default.post(name: APIWorkspace.didChange, object: self)
    }

    func delete(environmentID: String) {
        guard let index = environments.firstIndex(where: { $0.value.id == environmentID }) else { return }
        for variable in environments[index].value.variables where variable.secret { APIWorkspace.secrets.delete(scope: environmentID, name: variable.name) }
        ownWrites.insert(environments[index].url.path)
        try? FileManager.default.removeItem(at: environments[index].url)
        environments.remove(at: index)
        NotificationCenter.default.post(name: APIWorkspace.didChange, object: self)
    }

    /// Secret values go to the secret store; the file keeps only the name.
    private func stripSecrets(_ variables: [APIVariable], scope: String) -> [APIVariable] {
        variables.map { variable in
            guard variable.secret else { return variable }
            if !variable.value.isEmpty { APIWorkspace.secrets.write(scope: scope, name: variable.name, value: variable.value) }
            var stripped = variable
            stripped.value = ""
            return stripped
        }
    }

    /// Variables with their secret values filled back in from the store, for sending and editing.
    func variables(of collection: APICollection) -> [APIVariable] { filled(collection.variables, scope: collection.id) }
    func variables(of environment: APIEnvironment) -> [APIVariable] { filled(environment.variables, scope: environment.id) }

    private func filled(_ variables: [APIVariable], scope: String) -> [APIVariable] {
        variables.map { variable in
            guard variable.secret, variable.value.isEmpty else { return variable }
            var full = variable
            full.value = APIWorkspace.secrets.read(scope: scope, name: variable.name) ?? ""
            return full
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try APIJSON.encoder.encode(value)
            ownWrites.insert(url.path)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// "Name.json", or "Name 2.json" when that exists.
    private func unusedURL(in folder: URL, name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        let base = safe.isEmpty ? "Untitled" : safe
        var candidate = folder.appendingPathComponent(base + ".json")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(counter).json")
            counter += 1
        }
        return candidate
    }

    // MARK: Lookups

    func collection(id: String) -> APICollection? { collections.first { $0.value.id == id }?.value }
    func environment(id: String) -> APIEnvironment? { environments.first { $0.value.id == id }?.value }

    /// The collection holding the request with that id.
    func collection(containingRequest id: String) -> APICollection? {
        collections.first { $0.value.request(id: id) != nil }?.value
    }

    // MARK: Captures

    func noteCaptured(_ values: [String: String], collectionID: String?) {
        guard !values.isEmpty else { return }
        let key = collectionID ?? ""
        captured[key, default: [:]].merge(values) { _, new in new }
    }

    /// The variables that apply to a request: collection, then environment, then what answers captured.
    func variables(for collection: APICollection?, environment: APIEnvironment?) -> APIVariables {
        var captures = captured[""] ?? [:]
        if let collection { captures.merge(captured[collection.id] ?? [:]) { _, new in new } }
        return APIVariables(collection: collection.map(variables(of:)) ?? [], environment: environment.map(variables(of:)) ?? [],
                            captured: captures, secrets: nil, collectionID: collection?.id, environmentID: environment?.id)
    }

    // MARK: History

    func record(_ entry: APIHistoryEntry) {
        history.insert(entry, at: 0)
        if history.count > APIWorkspace.historyLimit { history.removeLast(history.count - APIWorkspace.historyLimit) }
        guard let data = try? JSONEncoder.lineEncoder.encode(entry) else { return }
        let url = historyFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: url)
        }
        NotificationCenter.default.post(name: APIWorkspace.didChange, object: self)
    }

    func clearHistory() {
        history = []
        try? FileManager.default.removeItem(at: historyFile)
        NotificationCenter.default.post(name: APIWorkspace.didChange, object: self)
    }

    private func loadHistory() -> [APIHistoryEntry] {
        guard let text = try? String(contentsOf: historyFile, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n").suffix(APIWorkspace.historyLimit)
        return lines.compactMap { try? APIJSON.decoder.decode(APIHistoryEntry.self, from: Data($0.utf8)) }.reversed()
    }

    // MARK: Watching

    /// Changes made by something else (git, an editor) are read back after a moment; Feather's own writes are not.
    private func startWatching() {
        guard watcher == nil, let directory = projectDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let watcher = DirectoryWatcher(path: directory.path)
        watcher.onChange = { [weak self] paths in
            guard let self else { return }
            let foreign = paths.contains { path in
                // An event names the folder; anything in it we did not just write counts.
                !self.ownWrites.contains(where: { $0.hasPrefix(path) || path.hasPrefix(($0 as NSString).deletingLastPathComponent) })
            }
            self.ownWrites.removeAll()
            guard foreign else { return }
            self.reloadWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.load() }
            self.reloadWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
        self.watcher = watcher
    }
}

private extension JSONEncoder {
    /// One line per entry, for the history file.
    static let lineEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
