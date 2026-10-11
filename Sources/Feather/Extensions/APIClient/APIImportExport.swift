import AppKit
import UniformTypeIdentifiers

/// Import and export in the formats teams already have: Postman collections and environments, cURL commands,
/// `.http` files and OpenAPI descriptions, plus Feather's own files. Every reader is a pure function of the
/// file's text; the two `present…` functions are the only ones that touch a window, and they hand the result
/// to the workspace.
enum APIImportExport {
    /// What an import produced, with plain-language notes about anything that could not come across as it was.
    struct Imported {
        var collections: [APICollection] = []
        var environments: [APIEnvironment] = []
        var notes: [String] = []

        var isEmpty: Bool { collections.isEmpty && environments.isEmpty }

        mutating func merge(_ other: Imported) {
            collections += other.collections
            environments += other.environments
            notes += other.notes
        }

        /// "2 collections and 1 environment".
        var summary: String {
            func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
            switch (collections.count, environments.count) {
            case (0, 0): return "nothing"
            case (_, 0): return count(collections.count, "collection")
            case (0, _): return count(environments.count, "environment")
            default: return count(collections.count, "collection") + " and " + count(environments.count, "environment")
            }
        }
    }

    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum Format: String {
        case postmanCollection = "Postman collection"
        case postmanEnvironment = "Postman environment"
        case featherCollection = "Feather collection"
        case featherEnvironment = "Feather environment"
        case openAPI = "OpenAPI description"
        case curl = "cURL command"
        case http = "request file"
    }

    static let importableExtensions = ["json", "http", "rest", "yaml", "yml", "txt", "curl", "sh"]

    // MARK: Detecting

    /// Whether a dropped or chosen file is worth trying: by extension, or a folder that may hold such files.
    static func canImport(url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { return true }
        let ext = url.pathExtension.lowercased()
        if importableExtensions.contains(ext) { return true }
        // No or unknown extension: sniff the start of the file.
        guard ext.isEmpty, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 4096), as: UTF8.self)
        return detect(text: head, hint: url) != nil
    }

    /// The format of a text, from its content first and the file name only as a hint.
    static func detect(text: String, hint url: URL? = nil) -> Format? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let json = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] {
            return detect(json: json)
        }
        if trimmed.hasPrefix("{") { return nil }                    // broken JSON is not "probably an .http file"
        // A curl file may start with a comment; the first real line decides.
        let firstLine = trimmed.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        if CurlFormat.looksLikeCurl(firstLine) { return .curl }
        let ext = url?.pathExtension.lowercased() ?? ""
        if ext == "yaml" || ext == "yml" || trimmed.range(of: #"(^|\n)\s*(openapi|swagger)\s*:"#, options: .regularExpression) != nil {
            return trimmed.range(of: #"(^|\n)\s*(openapi|swagger)\s*:"#, options: .regularExpression) != nil ? .openAPI : nil
        }
        if ext == "http" || ext == "rest" || HTTPFileFormat.looksLikeHTTPFile(trimmed) { return .http }
        return nil
    }

    static func detect(json: [String: Any]) -> Format? {
        if PostmanFormat.isCollection(json) { return .postmanCollection }
        if PostmanFormat.isEnvironment(json) { return .postmanEnvironment }
        if OpenAPIImport.isOpenAPI(json) { return .openAPI }
        if json["name"] != nil, json["items"] is [Any] { return .featherCollection }
        if json["name"] != nil, json["variables"] is [Any], json["format"] != nil { return .featherEnvironment }
        return nil
    }

    // MARK: Importing

    /// Reads one file, or every importable file in a folder (one level of subfolders included).
    static func importFile(at url: URL) throws -> Imported {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ImportError(message: "The file was not found: \(url.path)")
        }
        if isDirectory.boolValue { return try importFolder(url) }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError(message: "\(url.lastPathComponent) is not a text file.")
        }
        return try importText(text, named: url.deletingPathExtension().lastPathComponent, hint: url)
    }

    private static func importFolder(_ folder: URL) throws -> Imported {
        var result = Imported()
        var failures: [String] = []
        let contents = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var files: [URL] = []
        for entry in contents {
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                guard !entry.lastPathComponent.hasPrefix(".") else { continue }
                files += ((try? FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? [])
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else {
                files.append(entry)
            }
        }
        for file in files where importableExtensions.contains(file.pathExtension.lowercased()) {
            do {
                let one = try importFile(at: file)
                if one.isEmpty { continue }
                result.merge(one)
            } catch {
                failures.append(file.lastPathComponent)
            }
        }
        if result.isEmpty {
            throw ImportError(message: failures.isEmpty ? "No collections, environments or requests were found in \(folder.lastPathComponent)."
                              : "Nothing could be read from \(folder.lastPathComponent): \(failures.joined(separator: ", ")).")
        }
        if !failures.isEmpty { result.notes.append("Skipped, not in a known format: " + failures.joined(separator: ", ") + ".") }
        return result
    }

    /// Reads text in any supported format; `name` names a collection when the format has none (.http, cURL).
    static func importText(_ text: String, named name: String, hint url: URL? = nil) throws -> Imported {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError(message: "\(name) is empty.") }
        if trimmed.hasPrefix("{") {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] else {
                throw ImportError(message: "\(name) is not valid JSON.")
            }
            return try importJSON(json, named: name)
        }
        guard let format = detect(text: trimmed, hint: url) else {
            throw ImportError(message: "\(name) is not in a format Feather can import (Postman, OpenAPI, .http or cURL).")
        }
        switch format {
        case .curl:
            var collection = APICollection(name: name)
            var skipped = 0
            for command in curlCommands(in: trimmed) {
                if let request = CurlFormat.parse(command) { collection.items.append(.request(request)) } else { skipped += 1 }
            }
            guard !collection.items.isEmpty else { throw ImportError(message: "No complete curl command was found in \(name).") }
            var imported = Imported(collections: [collection])
            if skipped > 0 { imported.notes.append("\(skipped) curl \(skipped == 1 ? "command" : "commands") could not be read (no address).") }
            return imported
        case .http:
            let parsed = HTTPFileFormat.parse(text)
            guard !parsed.requests.isEmpty else { throw ImportError(message: "No requests were found in \(name).") }
            var collection = APICollection(name: name, items: parsed.requests.map { .request($0) })
            collection.variables = parsed.variables
            return Imported(collections: [collection], notes: parsed.notes)
        case .openAPI:
            let document: Any
            do { document = try YAMLSubset.parse(text) }
            catch { throw ImportError(message: "\(name) could not be read as YAML. \(error.localizedDescription)") }
            guard let spec = document as? [String: Any] else { throw ImportError(message: "\(name) does not hold an OpenAPI description.") }
            return try OpenAPIImport.read(spec)
        case .postmanCollection, .postmanEnvironment, .featherCollection, .featherEnvironment:
            throw ImportError(message: "\(name) is not valid JSON.")
        }
    }

    static func importJSON(_ json: [String: Any], named name: String) throws -> Imported {
        switch detect(json: json) {
        case .postmanCollection:
            let (collection, notes) = PostmanFormat.Reader.read(json)
            return Imported(collections: [collection], notes: notes)
        case .postmanEnvironment:
            return Imported(environments: [PostmanFormat.readEnvironment(json)])
        case .openAPI:
            return try OpenAPIImport.read(json)
        case .featherCollection:
            let data = try JSONSerialization.data(withJSONObject: json)
            return Imported(collections: [try APIJSON.decoder.decode(APICollection.self, from: data)])
        case .featherEnvironment:
            let data = try JSONSerialization.data(withJSONObject: json)
            return Imported(environments: [try APIJSON.decoder.decode(APIEnvironment.self, from: data)])
        case .curl, .http, nil:
            throw ImportError(message: "\(name) is JSON, but not a Postman, OpenAPI or Feather file.")
        }
    }

    /// The request a pasted curl command describes, or nil when the text is not one.
    static func importCurl(_ text: String) -> APIRequest? { CurlFormat.parse(text) }

    /// Several commands in one text: each line that starts a command (continuations joined) is one.
    static func curlCommands(in text: String) -> [String] {
        var commands: [String] = []
        var current = ""
        for line in text.replacingOccurrences(of: "\\\r\n", with: "\\\n").components(separatedBy: "\n") {
            if CurlFormat.looksLikeCurl(line), !current.hasSuffix("\\") {
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { commands.append(current) }
                current = line
            } else if !current.isEmpty {
                current += "\n" + line
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { commands.append(current) }
        return commands
    }

    // MARK: Exporting

    static func exportPostman(_ collection: APICollection) -> Data {
        json(PostmanFormat.writeCollection(collection))
    }

    static func exportPostmanEnvironment(_ environment: APIEnvironment) -> Data {
        json(PostmanFormat.writeEnvironment(environment))
    }

    static func exportHTTP(_ collection: APICollection) -> String {
        HTTPFileFormat.serialize(collection)
    }

    /// The curl line for a request as Feather would send it, with the variables of its surroundings.
    static func curl(for request: APIRequest, variables: APIVariables, inheritedAuth: [APIAuth] = [], projectRoot: URL? = nil) -> String {
        CurlFormat.command(for: request, variables: variables, inheritedAuth: inheritedAuth, projectRoot: projectRoot)
    }

    /// Writes every collection and environment of the workspace into `folder` as Postman files, which both
    /// Postman and Feather read back. Secret values stay out. Returns the files written.
    @discardableResult
    static func exportWorkspace(to folder: URL, workspace: APIWorkspace) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [URL] = []
        var used: Set<String> = []
        func file(_ name: String, _ suffix: String) -> URL {
            var base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
            if base.isEmpty { base = "Untitled" }
            var candidate = base
            var counter = 2
            while used.contains(candidate + suffix) { candidate = "\(base) \(counter)"; counter += 1 }
            used.insert(candidate + suffix)
            return folder.appendingPathComponent(candidate + suffix)
        }
        for stored in workspace.collections {
            let url = file(stored.value.name, ".postman_collection.json")
            try exportPostman(stored.value).write(to: url, options: .atomic)
            written.append(url)
        }
        for stored in workspace.environments {
            let url = file(stored.value.name, ".postman_environment.json")
            try exportPostmanEnvironment(stored.value).write(to: url, options: .atomic)
            written.append(url)
        }
        return written
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    // MARK: File dialogs

    private static var importTypes: [UTType] {
        importableExtensions.compactMap { UTType(filenameExtension: $0) } + [.json, .yaml, .plainText]
    }

    /// Asks for files or a folder, imports them into the workspace and reports what happened.
    static func present(importIn window: NSWindow?, workspace: APIWorkspace, completion: ((Imported) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Import"
        panel.message = "Choose Postman, OpenAPI, .http or cURL files, or a folder of them."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = importTypes
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            var imported = Imported()
            var failures: [String] = []
            for url in panel.urls {
                do { imported.merge(try importFile(at: url)) }
                catch { failures.append(error.localizedDescription) }
            }
            add(imported, to: workspace)
            report(imported, failures: failures, in: window)
            completion?(imported)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    /// Saves what was imported into the workspace: the project when a folder is open, else the personal folder.
    static func add(_ imported: Imported, to workspace: APIWorkspace) {
        for collection in imported.collections { workspace.save(collection) }
        for environment in imported.environments { workspace.save(environment) }
    }

    private static func report(_ imported: Imported, failures: [String], in window: NSWindow?) {
        guard !imported.notes.isEmpty || !failures.isEmpty || imported.isEmpty else { return }
        let alert = NSAlert()
        if imported.isEmpty {
            alert.messageText = "Nothing was imported"
            alert.alertStyle = .warning
        } else {
            alert.messageText = "Imported \(imported.summary)"
        }
        alert.informativeText = (failures + imported.notes).joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// Asks where to save a collection, as a Postman file or a request file (the format follows the pop-up).
    static func presentExport(_ collection: APICollection, in window: NSWindow?, completion: ((URL?) -> Void)? = nil) {
        let panel = NSSavePanel()
        panel.title = "Export Collection"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        let formats: [(title: String, ext: String)] = [("Postman collection (.json)", "json"), ("Request file (.http)", "http")]
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
        popup.addItems(withTitles: formats.map(\.title))
        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, popup])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        panel.accessoryView = row
        let safeName = collection.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        func applyFormat() {
            let format = formats[max(0, popup.indexOfSelectedItem)]
            panel.allowedContentTypes = [UTType(filenameExtension: format.ext) ?? .json]
            panel.nameFieldStringValue = (safeName.isEmpty ? "Collection" : safeName) + "." + format.ext
        }
        applyFormat()
        popup.target = FormatChoice.shared
        FormatChoice.shared.onChange = applyFormat
        popup.action = #selector(FormatChoice.changed(_:))
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            FormatChoice.shared.onChange = nil
            guard response == .OK, let url = panel.url else { completion?(nil); return }
            do {
                if url.pathExtension.lowercased() == "http" || url.pathExtension.lowercased() == "rest" || popup.indexOfSelectedItem == 1 {
                    try exportHTTP(collection).write(to: url, atomically: true, encoding: .utf8)
                } else {
                    try exportPostman(collection).write(to: url, options: .atomic)
                }
                completion?(url)
            } catch {
                let alert = NSAlert(error: error)
                if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
                completion?(nil)
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    /// Asks where to save an environment as a Postman environment file.
    static func presentExport(_ environment: APIEnvironment, in window: NSWindow?, completion: ((URL?) -> Void)? = nil) {
        let panel = NSSavePanel()
        panel.title = "Export Environment"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = environment.name.replacingOccurrences(of: "/", with: "-") + ".postman_environment.json"
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { completion?(nil); return }
            do { try exportPostmanEnvironment(environment).write(to: url, options: .atomic); completion?(url) }
            catch {
                let alert = NSAlert(error: error)
                if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
                completion?(nil)
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    /// Asks for a folder and writes every collection and environment into it.
    static func presentExportWorkspace(in window: NSWindow?, workspace: APIWorkspace, completion: (([URL]) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Export Everything"
        panel.message = "Choose a folder for the Postman files of every collection and environment."
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let folder = panel.url else { completion?([]); return }
            do { completion?(try exportWorkspace(to: folder, workspace: workspace)) }
            catch {
                let alert = NSAlert(error: error)
                if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
                completion?([])
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    /// The target of the format pop-up on the export sheet (a pop-up needs an object to call).
    private final class FormatChoice: NSObject {
        static let shared = FormatChoice()
        var onChange: (() -> Void)?
        @objc func changed(_ sender: Any?) { onChange?() }
    }
}
