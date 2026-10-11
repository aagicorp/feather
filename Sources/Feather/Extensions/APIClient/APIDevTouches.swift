import AppKit

// The developer and AI touches of the API client: the "send" strip over .http files, "Add to API" on a curl
// line in the terminal, "Ask Assistant About Last Request" and "Generate Requests" from an OpenAPI file.
// All of it is alive only while the extension is on (`APIDevTouches` is owned by the extension instance).

extension APIClientExtension {
    /// Something outside the pane wants a request shown in a tab. Posted on the main queue with the
    /// controller as `object` and, in `userInfo`: "request" (APIRequest), "send" (Bool: send it at once),
    /// "collectionID" (String, when the request lives in a collection) and "window" (MainWindowController).
    /// The pane observes it and opens the request; a request without a collection is a scratch one.
    static let openRequest = Notification.Name("FeatherAPIOpenRequest")
    /// A ⌘-click on a `curl` line in a terminal (DropTerminalView.swift): "command" (String) and "window" (NSWindow).
    static let curlCommandClicked = Notification.Name("FeatherAPICurlCommandClicked")
}

/// What the extension keeps while it is on: the editor strip provider and the terminal's curl link. Made in
/// `APIClientExtension.init`, gone when the extension is switched off.
final class APIDevTouches {
    private static let providerKey = "api-client"
    private var observers: [NSObjectProtocol] = []

    init() {
        EditorAreaViewController.accessoryProviders[APIDevTouches.providerKey] = { tab, area in
            guard HTTPFileBlocks.isHTTPFile(tab.url), let main = area.view.window?.windowController as? MainWindowController,
                  let controller = main.apiClient else { return nil }
            return HTTPRequestStrip(editor: tab.editor, controller: controller)
        }
        observers.append(NotificationCenter.default.addObserver(forName: APIClientExtension.curlCommandClicked, object: nil, queue: .main) { note in
            guard let command = note.userInfo?["command"] as? String, let window = note.userInfo?["window"] as? NSWindow,
                  let main = window.windowController as? MainWindowController, let controller = main.apiClient else { return }
            controller.addFromTerminal(command)
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        EditorAreaViewController.accessoryProviders[APIDevTouches.providerKey] = nil
    }
}

extension APIClientController {
    /// The personal collection that keeps what was added from the terminal.
    static let terminalCollectionName = "From terminal"

    /// Shows a request in a tab, and sends it when `sends`. The pane does the showing: this posts
    /// `APIClientExtension.openRequest` for it (see there for the payload).
    func open(_ request: APIRequest, in collection: APICollection? = nil, sends: Bool = false) {
        var info: [String: Any] = ["request": request, "send": sends]
        if let collection { info["collectionID"] = collection.id }
        if let window { info["window"] = window }
        NotificationCenter.default.post(name: APIClientExtension.openRequest, object: self, userInfo: info)
    }

    /// The workspace is read when the pane is first shown; a command that needs it earlier reads it here.
    func loadWorkspaceIfNeeded() {
        if workspace.collections.isEmpty, workspace.environments.isEmpty { workspace.load() }
    }

    /// A `curl` line from the terminal becomes a request in the "From terminal" collection, which is opened.
    @discardableResult
    func addFromTerminal(_ command: String) -> APIRequest? {
        guard let request = CurlParser.parse(command) else { NSSound.beep(); return nil }
        showPane()
        loadWorkspaceIfNeeded()
        var collection = workspace.collections.first { $0.value.name == APIClientController.terminalCollectionName && $0.location == .personal }?.value
            ?? APICollection(name: APIClientController.terminalCollectionName)
        collection.items.append(.request(request))
        guard workspace.save(collection, location: .personal) else {
            NSSound.beep()
            return nil
        }
        open(request, in: collection)
        if let window = window?.window {
            let card = NoticeCard(kind: "api-terminal", symbol: "paperplane", text: "Added \(request.name) to the \"From terminal\" collection in the API pane.",
                                  actions: [], dismissTitle: "OK")
            WindowNotices.show(card, in: window)
        }
        return request
    }

    /// Send Request while a `.http` file is in front: the block the cursor is in. False when the file in
    /// front is not one, so the caller can fall back to the request tab.
    @discardableResult
    func sendRequestUnderCursor() -> Bool {
        guard let tab = window?.editorArea.currentTab, HTTPFileBlocks.isHTTPFile(tab.url), let editor = tab.editorIfLoaded else { return false }
        let blocks = HTTPFileBlocks.parse(editor.document.text)
        guard let block = HTTPFileBlocks.block(at: editor.textView.selectedRange().location, in: blocks) else { NSSound.beep(); return true }
        open(block.request, sends: true)
        return true
    }

    // MARK: OpenAPI

    /// OpenAPI files in the project, for the pane's empty state.
    func openAPIFiles() -> [URL] { workspace.projectRoot.map(APIProjectScan.findOpenAPIFiles) ?? [] }

    /// The box offering to generate requests, or nil when the project has no OpenAPI file.
    func makeOpenAPIOffer() -> NSView? {
        let files = openAPIFiles()
        guard !files.isEmpty else { return nil }
        return APIOpenAPIOfferView(files: files, root: workspace.projectRoot) { [weak self] in self?.generateFromOpenAPI($0) }
    }

    /// One request per operation of the OpenAPI file, saved as a collection in the project.
    func generateFromOpenAPI(_ file: URL) {
        guard let window = window?.window else { return }
        guard let generator = APIProjectScan.generator else {
            let card = NoticeCard(kind: "api-openapi", symbol: "doc.text.magnifyingglass",
                                  text: "Making requests from an OpenAPI file is not in this version of Feather yet.", actions: [], dismissTitle: "OK")
            WindowNotices.show(card, in: window)
            return
        }
        loadWorkspaceIfNeeded()
        do {
            var collection = try generator(file)
            if collection.name.isEmpty { collection.name = file.deletingPathExtension().lastPathComponent }
            guard workspace.save(collection) else { throw APIRequestSender.Failure(message: "The collection could not be saved.") }
            showPane()
            let count = collection.allRequests.count
            let card = NoticeCard(kind: "api-openapi", symbol: "paperplane",
                                  text: "Made \(count) request\(count == 1 ? "" : "s") from \(file.lastPathComponent) in the collection \"\(collection.name)\".",
                                  actions: [], dismissTitle: "OK")
            WindowNotices.show(card, in: window)
        } catch {
            let card = NoticeCard(kind: "api-openapi", symbol: "exclamationmark.triangle",
                                  text: "\(file.lastPathComponent) could not be read: \(error.localizedDescription)", actions: [], dismissTitle: "OK")
            WindowNotices.show(card, in: window)
        }
    }
}

// MARK: - Requests ▸ Ask Assistant About Last Request

extension MainWindowController {
    /// Hands the last request and its answer to the AI assistant as a short brief, the way Fix This hands over
    /// an error. Typed, not entered, so a question can be added. An assistant that takes pasted text (bracketed
    /// paste, which Claude Code, Codex and aider all do) gets the brief on several lines; anything else gets it
    /// on one, since a newline would press Return.
    @objc func apiAskAssistantAboutLastRequest(_ sender: Any?) {
        guard let exchange = apiClient?.lastExchange else {
            if let window {
                let card = NoticeCard(kind: "api-assistant", symbol: "paperplane", text: "Send a request first; then the assistant can be asked about it.",
                                      actions: [], dismissTitle: "OK")
                WindowNotices.show(card, in: window)
            }
            return
        }
        let brief = APIAssistant.describe(exchange)
        let pastes = terminals.assistantSession()?.view.getTerminal().bracketedPasteMode ?? false
        handToAssistant(pastes ? "\u{1b}[200~" + brief + "\u{1b}[201~" : APIAssistant.singleLine(brief) + " ")
    }
}
