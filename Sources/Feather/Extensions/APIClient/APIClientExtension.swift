import AppKit

/// The API client: send requests, keep collections and environments in the project, check the answers.
/// Off until switched on in Feather ▸ Extensions. Each window gets an `APIClientController`, which owns that
/// window's workspace, pane and open request tabs.
final class APIClientExtension: FeatherExtension {
    static let id = "api-client"
    static let name = "API Client"
    static let summary = "Send HTTP requests and check the answers, like Postman: collections and environments saved in the project, import and export, checks without scripts."
    static let adds = ["An API pane in the sidebar", "A Requests menu", "Commands in the Command Palette", ".http files you can send from"]
    static let symbol = "paperplane"

    private var controllers: [ObjectIdentifier: APIClientController] = [:]
    /// The editor strip, the terminal's curl link and the assistant command (APIDevTouches.swift).
    private let devTouches = APIDevTouches()

    init() {}

    func activate(in window: MainWindowController) {
        guard controllers[ObjectIdentifier(window)] == nil else { return }
        let controller = APIClientController(window: window)
        controllers[ObjectIdentifier(window)] = controller
        controller.install()
        EditorAreaViewController.refreshAccessories()          // the .http strip needs this window's controller
    }

    func deactivate(in window: MainWindowController) {
        controllers.removeValue(forKey: ObjectIdentifier(window))?.uninstall()
    }

    /// The controller for a window, when the extension is on there.
    func controller(for window: MainWindowController) -> APIClientController? { controllers[ObjectIdentifier(window)] }

    static func controller(for window: MainWindowController) -> APIClientController? {
        ExtensionRegistry.shared.instance(of: APIClientExtension.self)?.controller(for: window)
    }

    func makeMenu() -> NSMenu? {
        let menu = NSMenu(title: "Requests")
        func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            KeyBindings.shared.apply(to: item)
            return item
        }
        for entry in [
            item("Show API Pane", #selector(MainWindowController.apiShowPane(_:)), "i", [.control, .shift]),
            item("New Request", #selector(MainWindowController.apiNewRequest(_:)), "n", [.command, .option, .shift]),
            item("Send Request", #selector(MainWindowController.apiSendRequest(_:)), "\r", [.command]),
            .separator(),
            item("New Collection…", #selector(MainWindowController.apiNewCollection(_:))),
            item("New Environment…", #selector(MainWindowController.apiNewEnvironment(_:))),
            .separator(),
            item("Import…", #selector(MainWindowController.apiImport(_:))),
            item("Export Collection…", #selector(MainWindowController.apiExportCollection(_:))),
            .separator(),
            item("Run Collection or Folder…", #selector(MainWindowController.apiRunFolder(_:)), "r", [.command, .shift, .option]),
            item("Cookies…", #selector(MainWindowController.apiShowCookies(_:))),
            .separator(),
            item("Ask Assistant About Last Request", #selector(MainWindowController.apiAskAssistantAboutLastRequest(_:))),
        ] { menu.addItem(entry) }
        return menu
    }
}

/// One window's API client: the workspace on disk and the pane and tabs that show it. The UI parts are
/// installed lazily; until the pane is shown nothing is loaded from disk.
final class APIClientController {
    private(set) weak var window: MainWindowController?
    private(set) var workspace: APIWorkspace
    /// The sidebar pane, once installed.
    private(set) var pane: APIPaneViewController?
    /// The chosen environment, per project, remembered between launches.
    var selectedEnvironmentID: String? {
        get { UserDefaults.standard.string(forKey: environmentKey) }
        set { UserDefaults.standard.set(newValue, forKey: environmentKey) }
    }
    private var environmentKey: String { "apiEnvironment:" + (workspace.projectRoot?.path ?? "") }
    /// The last request sent from this window and what it produced, for Ask Assistant About Last Request.
    private(set) var lastExchange: APIAssistant.Exchange?

    init(window: MainWindowController) {
        self.window = window
        workspace = APIWorkspace(projectRoot: window.projectRoot)
    }

    /// Adds the pane to the window's sidebar. The pane loads the workspace the first time it is shown.
    func install() {
        guard let window, pane == nil else { return }
        let pane = APIPaneViewController(controller: self)
        window.sidebarContainer.addPane(pane, symbol: APIClientExtension.symbol, tooltip: "API: send requests and check the answers (⌃⇧I)")
        self.pane = pane
    }

    func uninstall() {
        guard let window, let pane else { return }
        window.sidebarContainer.removePane(pane)
        self.pane = nil
    }

    /// The folder changed: a new workspace for it.
    func projectDidChange() {
        workspace = APIWorkspace(projectRoot: window?.projectRoot)
        pane?.workspaceDidChange()
    }

    func showPane() {
        guard let window, let pane, let index = window.sidebarContainer.index(of: pane) else { return }
        window.showSidebarPane(index)
    }

    // MARK: Sending

    var selectedEnvironment: APIEnvironment? { selectedEnvironmentID.flatMap { workspace.environment(id: $0) } }

    /// Resolves and sends a request that belongs to `collection` (nil for a scratch request), applying the
    /// collection's variables and auth chain, then records history and captures.
    func send(_ request: APIRequest, in collection: APICollection?, folders: [APIFolder] = [], sender: APIRequestSender,
              completion: @escaping (Result<APIResponse, APIRequestSender.Failure>, [APIChecks.Result]) -> Void) {
        var exchange = APIAssistant.Exchange(request: request, resolved: nil, result: nil, checks: [], date: Date())
        APISending.send(request, in: collection, folders: folders, workspace: workspace, environment: selectedEnvironment, sender: sender,
                        onResolved: { exchange.resolved = $0 }) { [weak self] result, checks in
            exchange.result = result
            exchange.checks = checks
            self?.lastExchange = exchange
            completion(result, checks)
        }
    }
}

/// Sending as the controller does it, without a window, so it can be tested and reused by the runner.
enum APISending {
    static func send(_ request: APIRequest, in collection: APICollection?, folders: [APIFolder] = [], workspace: APIWorkspace,
                     environment: APIEnvironment?, sender: APIRequestSender, onResolved: ((APIResolvedRequest) -> Void)? = nil,
                     completion: @escaping (Result<APIResponse, APIRequestSender.Failure>, [APIChecks.Result]) -> Void) {
        let context = APIRequestSender.Context(variables: workspace.variables(for: collection, environment: environment),
                                               inheritedAuth: folders.reversed().map(\.auth) + [collection?.auth ?? .none],
                                               environment: environment, projectRoot: workspace.projectRoot)
        var resolved: APIResolvedRequest
        do { resolved = try APIRequestSender.resolve(request, context: context) }
        catch let failure as APIRequestSender.Failure { completion(.failure(failure), []); return }
        catch { completion(.failure(APIRequestSender.Failure(message: error.localizedDescription)), []); return }
        // The jar's cookies for this address, unless the request carries its own Cookie header.
        if !resolved.headers.contains(where: { $0.name.caseInsensitiveCompare("Cookie") == .orderedSame }),
           let cookie = workspace.cookies.header(for: resolved.url) {
            resolved.headers.append((name: "Cookie", value: cookie))
        }
        onResolved?(resolved)
        let started = Date()
        sender.send(resolved, environment: environment) { result in
            var checks: [APIChecks.Result] = []
            var result = result
            switch result {
            case .success(var response):
                if let url = response.url ?? Optional(resolved.url) { response.cookies = workspace.cookies.store(response.cookies, from: url) }
                result = .success(response)
                checks = APIChecks.evaluate(request.checks, response: response)
                let captured = APIChecks.capture(request.captures, response: response)
                workspace.noteCaptured(Dictionary(captured.filter { $0.capture.scope == .collection }.map { ($0.capture.variable, $0.value) }) { _, new in new },
                                       collectionID: collection?.id)
                workspace.noteCaptured(Dictionary(captured.filter { $0.capture.scope == .environment }.map { ($0.capture.variable, $0.value) }) { _, new in new },
                                       collectionID: nil)
                workspace.record(APIHistoryEntry(date: started, method: request.method, url: resolved.url.absoluteString, status: response.status,
                                                 duration: response.duration, size: response.size, requestID: request.id, collectionID: collection?.id))
            case .failure(let failure):
                workspace.record(APIHistoryEntry(date: started, method: request.method, url: resolved.url.absoluteString, status: nil,
                                                 duration: Date().timeIntervalSince(started), size: 0, requestID: request.id,
                                                 collectionID: collection?.id, error: failure.message))
            }
            completion(result, checks)
        }
    }
}

// MARK: - Menu actions (the Requests menu and the Command Palette)

extension MainWindowController {
    var apiClient: APIClientController? { APIClientExtension.controller(for: self) }

    /// Shows a sidebar pane by index, for extensions.
    func showSidebarPane(_ index: Int) {
        if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
        sidebarContainer.show(pane: index)
    }

    @objc func apiShowPane(_ sender: Any?) { apiClient?.showPane() }
    @objc func apiNewRequest(_ sender: Any?) { apiClient?.showPane(); apiClient?.pane?.newRequest() }
    @objc func apiSendRequest(_ sender: Any?) {
        if apiClient?.sendRequestUnderCursor() == true { return }       // a .http file in front: the block the cursor is in
        apiClient?.pane?.sendCurrentRequest()
    }
    @objc func apiNewCollection(_ sender: Any?) { apiClient?.showPane(); apiClient?.pane?.newCollection() }
    @objc func apiNewEnvironment(_ sender: Any?) { apiClient?.showPane(); apiClient?.pane?.newEnvironment() }
    @objc func apiImport(_ sender: Any?) { apiClient?.showPane(); apiClient?.pane?.importFiles() }
    @objc func apiExportCollection(_ sender: Any?) { apiClient?.pane?.exportSelectedCollection() }
    @objc func apiRunFolder(_ sender: Any?) { apiClient?.showPane(); apiClient?.pane?.runSelection() }
    /// Forgets every cookie the API client holds for this project (sign-ins included).
    @objc func apiClearCookies(_ sender: Any?) {
        guard let client = apiClient else { return }
        let count = client.workspace.cookies.cookies.count
        client.workspace.cookies.clear()
        client.notice(count == 0 ? "There were no cookies to clear." : "Cleared \(count) cookie\(count == 1 ? "" : "s").")
    }
}
