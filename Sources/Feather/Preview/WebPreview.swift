import AppKit
import WebKit
import Network

/// What every web preview shares, and only while at least one exists: the previews hold it, nobody else does,
/// so closing the last preview tab lets go of it and WebKit's helper processes wind down.
///
/// The data store is the in-memory kind: cookies and site storage last for the session and are never written
/// to disk. (WebKit has used a single process pool per app since macOS 12, whatever pool a web view is handed,
/// so sharing this one configuration source is what keeps the previews on one set of helper processes.)
final class WebPreviewSession {
    private static weak var current: WebPreviewSession?
    static var isAlive: Bool { current != nil }

    static func shared() -> WebPreviewSession {
        if let current { return current }
        let session = WebPreviewSession()
        current = session
        return session
    }

    private let dataStore = WKWebsiteDataStore.nonPersistent()
    /// Lets sign-in cookies marked `Secure` survive on plain-http localhost; see `PreviewAlias`.
    private let relay: PreviewRelay?

    private init() {
        guard #available(macOS 14.0, *), let relay = PreviewRelay(), let port = NWEndpoint.Port(rawValue: relay.port) else {
            relay = nil
            return
        }
        self.relay = relay
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .ipv4(.loopback), port: port))
        proxy.matchDomains = [PreviewAlias.domain]
        dataStore.proxyConfigurations = [proxy]
    }

    /// The address WebKit is given for `url`: a stand-in name for plain-http localhost while the relay is up.
    func wire(_ url: URL) -> URL { relay == nil ? url : PreviewAlias.wire(url) }

    func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        if relay != nil {
            configuration.userContentController.addUserScript(
                WKUserScript(source: PreviewAlias.pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")       // right-click ▸ Inspect Element
        return configuration
    }
}

/// A tab that shows the user's own app, running on this Mac, next to the code that makes it.
///
/// Only addresses on this Mac load here. Anything else (a link to documentation, a sign-in page, a download, a
/// pop-up) is handed to the default browser, which has the user's passwords, extensions and protections.
final class WebPreviewView: NSView, TabPreview, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    /// How pages leave Feather. Tests replace it so that no real browser is opened.
    static var openInBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) }

    enum Device: Int, CaseIterable {
        case phone, tablet, desktop
        /// nil: as wide as the pane.
        var width: CGFloat? { [390, 820, nil][rawValue] }
        var symbol: String { ["iphone", "ipad", "desktopcomputer"][rawValue] }
        var toolTip: String { ["Phone width (390)", "Tablet width (820)", "Full width"][rawValue] }
    }

    private(set) var webView: WKWebView
    private(set) var address: URL
    private(set) var device = Device.desktop
    /// Files of a plain HTML project, served for this preview alone; it stops when the preview goes away.
    private let server: StaticFileServer?
    /// The project whose files, when they change, mean the page should be loaded again.
    private let watchedFolder: URL?
    private var watcher: DirectoryWatcher?
    private let session: WebPreviewSession

    /// The page's title changed (nil or empty when it has none).
    var onTitleChange: ((String?) -> Void)?
    /// Called each time a page finishes loading, or fails to.
    var onDidLoad: ((Bool) -> Void)?
    /// How many times a change to the project has made the page load again.
    private(set) var changeReloadCount = 0

    private let header = NSView()
    private let stage = NSView()
    private let backButton = NSButton(title: "", target: nil, action: nil)
    private let forwardButton = NSButton(title: "", target: nil, action: nil)
    private let reloadButton = NSButton(title: "", target: nil, action: nil)
    private let addressField = NSTextField()
    private let browserButton = NSButton(title: "Open in Browser", target: nil, action: nil)
    private let newTabButton = NSButton(title: "", target: nil, action: nil)
    private let deviceSwitch = NSSegmentedControl()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private var deviceWidth: NSLayoutConstraint!
    private var fullWidth: NSLayoutConstraint!
    private var observations: [NSKeyValueObservation] = []
    private var reloadWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var retriesLeft = 0
    private var needsReloadWhenShown = false
    private var hasFailed = false
    /// Where the page was scrolled to before a reload, to go back to once the same page is up again.
    private var scrollToRestore: (url: URL, x: Double, y: Double)?

    static let reloadDelay = 0.4
    /// The address of a preview tab that has not been given one yet (the "+" button).
    static let blank = URL(string: "about:blank")!
    var focusView: NSView { webView }

    init(address: URL, watching folder: URL?, server: StaticFileServer? = nil) {
        self.address = address
        self.server = server
        self.watchedFolder = folder
        session = WebPreviewSession.shared()
        webView = WKWebView(frame: .zero, configuration: session.makeConfiguration())
        super.init(frame: .zero)
        wantsLayer = true
        build()
        applyTheme()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.canGoBack) { [weak self] _, _ in self?.refreshButtons() },
            webView.observe(\.canGoForward) { [weak self] _, _ in self?.refreshButtons() },
            webView.observe(\.url) { [weak self] view, _ in
                guard let self, let url = view.url, url.scheme != "about" else { return }
                if self.addressField.currentEditor() == nil { self.addressField.stringValue = PreviewAlias.shown(url).absoluteString }
            },
            webView.observe(\.title) { [weak self] view, _ in self?.onTitleChange?(view.title) },
        ]
        NotificationCenter.default.addObserver(self, selector: #selector(documentSaved(_:)), name: DocumentStore.didSaveDocument, object: nil)
        if let folder {
            watcher = DirectoryWatcher(path: folder.path)
            watcher?.onChange = { [weak self] paths in
                guard let self, paths.contains(where: { WebPreviewView.isWorthReloading(for: $0, in: folder) }) else { return }
                self.projectChanged()
            }
        }
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        reloadWork?.cancel()
        retryWork?.cancel()
        server?.stop()
    }

    // MARK: - Which addresses belong here

    /// This Mac, by any of its names. Everything else belongs in the browser.
    static func isLocal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasSuffix(".localhost")
    }

    /// From what a person types ("3000", "localhost:3000", a full address) to an address, or nil.
    static func url(fromTyped text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.allSatisfy(\.isNumber) { text = "localhost:" + text }
        if text.hasPrefix(":") { text = "localhost" + text }
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return replacingAnyAddress(in: url)
    }

    /// Servers say "0.0.0.0" for "every address of this Mac"; it is not an address to visit, localhost is.
    static func replacingAnyAddress(in url: URL) -> URL {
        guard url.host == "0.0.0.0", var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.host = "localhost"
        return parts.url ?? url
    }

    /// "localhost:3000": how an address is said in a sentence or a tab title.
    static func shortName(of url: URL) -> String {
        (url.host ?? url.absoluteString) + (url.port.map { ":\($0)" } ?? "")
    }

    /// Dependencies being installed, build output and git's own files change all the time and are not the page.
    static func isWorthReloading(for path: String, in folder: URL) -> Bool {
        let root = folder.path
        let relative = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
        return !relative.split(separator: "/").contains { $0.hasPrefix(".") || $0 == "node_modules" }
    }

    // MARK: - Loading

    /// Shows `url` here if it is on this Mac; otherwise sends it to the browser and says so. Returns whether it
    /// was loaded here.
    @discardableResult
    func load(_ url: URL) -> Bool {
        let url = WebPreviewView.replacingAnyAddress(in: url)
        if url == WebPreviewView.blank {
            addressField.stringValue = ""
            addressField.placeholderString = "Type your other app's address here, such as localhost:3001, then press Return"
            show(message: "This preview tab is empty.\nClick the address box above, type where your other app is running (for example localhost:3001) and press Return.", overPage: false)
            return false
        }
        guard WebPreviewView.isLocal(url) else {
            WebPreviewView.openInBrowser(PreviewAlias.shown(url))
            show(message: "Opened \(WebPreviewView.shortName(of: url)) in your browser.\nThe preview only shows apps running on this Mac.", overPage: webView.url != nil)
            addressField.stringValue = (webView.url.map(PreviewAlias.shown) ?? address).absoluteString
            return false
        }
        address = url
        addressField.stringValue = url.absoluteString
        addressField.placeholderString = "localhost:3000"
        retriesLeft = 150
        webView.load(URLRequest(url: session.wire(url), cachePolicy: .reloadIgnoringLocalCacheData))
        return true
    }

    func render() { load(address) }

    /// Loads the page again, coming back to where it was scrolled to if the page is still that long.
    @objc func reload() {
        retryWork?.cancel()
        // A page that never came up has nothing to reload; ask for the address again instead.
        guard !hasFailed, let current = webView.url, current.scheme != "about" else { load(address); return }
        webView.evaluateJavaScript("[window.scrollX, window.scrollY]") { [weak self] result, _ in
            guard let self else { return }
            if let position = result as? [Double], position.count == 2 { self.scrollToRestore = (current, position[0], position[1]) }
            self.webView.reload()
        }
    }

    @objc private func documentSaved(_ notification: Notification) { projectChanged() }

    /// A save, or a file changed on disk by the AI tool in the terminal. Many arrive together (a tool writes ten
    /// files, a save is also a disk change), so the page loads again once, after things have been quiet.
    func projectChanged() {
        guard Settings.shared.previewReloadsOnChange else { return }
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Nobody is looking at a tab in the background; it catches up when it is shown.
            guard self.window != nil else { self.needsReloadWhenShown = true; return }
            self.changeReloadCount += 1
            self.reload()
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + WebPreviewView.reloadDelay, execute: work)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, needsReloadWhenShown else { return }
        needsReloadWhenShown = false
        changeReloadCount += 1
        reload()
    }

    // MARK: - Navigation rules

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        let scheme = url.scheme?.lowercased() ?? ""
        if navigationAction.shouldPerformDownload {
            WebPreviewView.openInBrowser(PreviewAlias.shown(url))
            return decisionHandler(.cancel)
        }
        // No frame to load into means the page asked for a new window.
        guard let frame = navigationAction.targetFrame else {
            if scheme == "http" || scheme == "https" { WebPreviewView.openInBrowser(PreviewAlias.shown(url)) }
            return decisionHandler(.cancel)
        }
        if frame.isMainFrame {
            // A link or redirect that says "localhost" outright: the same page, under the name the preview uses.
            if session.wire(url) != url {
                var request = navigationAction.request
                request.url = session.wire(url)
                decisionHandler(.cancel)
                webView.load(request)
                return
            }
            if WebPreviewView.isLocal(url) || url.absoluteString == "about:blank" { return decisionHandler(.allow) }
            if ["http", "https", "mailto"].contains(scheme) { WebPreviewView.openInBrowser(PreviewAlias.shown(url)) }
            return decisionHandler(.cancel)
        }
        // What the user's own page embeds (a video, a map) is part of that page.
        decisionHandler(["http", "https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Something that cannot be shown would become a download; the browser is the place for those.
        if navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType, let url = navigationResponse.response.url {
            WebPreviewView.openInBrowser(PreviewAlias.shown(url))
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            WebPreviewView.openInBrowser(PreviewAlias.shown(url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Without the relay (before macOS 14), a sign-in page over plain http is where WebKit's cookie rule bites.
        if let url = webView.url, session.wire(address) == address, url.scheme == "http",
           url.path.range(of: "login|signin|sign-in|sign_in|auth", options: [.regularExpression, .caseInsensitive]) != nil {
            HintCards.showOnce(.previewSignIn, in: window)
        }
        hasFailed = false
        retryWork?.cancel()
        messageLabel.isHidden = true
        webView.isHidden = false
        if let restore = scrollToRestore, restore.url == webView.url {
            webView.evaluateJavaScript("window.scrollTo(\(restore.x), \(restore.y))", completionHandler: nil)
        }
        scrollToRestore = nil
        refreshButtons()
        onDidLoad?(true)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // macOS may take back the memory of a page nobody is looking at; it simply loads again when it is shown.
        guard window != nil else { needsReloadWhenShown = true; return }
        hasFailed = true
        show(message: "The page stopped working. Press Reload to load it again.", overPage: false)
    }

    private func failed(_ error: Error) {
        let code = (error as NSError).code
        // Cancelled: a newer load replaced this one, or the link was handed to the browser. 102: the same, as
        // WebKit says it ("frame load interrupted").
        guard code != NSURLErrorCancelled, code != 102 else { return }
        hasFailed = true
        scrollToRestore = nil
        let name = WebPreviewView.shortName(of: address)
        let waiting = [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut].contains(code)
        show(message: waiting
             ? "Nothing is running at \(name) yet.\nStart your app (Run ▸ Run Project, or ask your AI assistant to start it) and this page will appear by itself."
             : "\(name) could not be shown.\n\(error.localizedDescription)", overPage: false)
        onDidLoad?(false)
        // An app that is still starting answers in a moment; keep knocking quietly while the tab is in view.
        guard waiting, retriesLeft > 0 else { return }
        retriesLeft -= 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hasFailed, self.window != nil else { return }
            self.webView.load(URLRequest(url: self.session.wire(self.address), cachePolicy: .reloadIgnoringLocalCacheData))
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // The page's own little dialogs. Without these WebKit answers them silently, and an app that says
    // "Saved!" with alert() would seem to do nothing.

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        guard let window else { return completionHandler() }
        let alert = NSAlert()
        alert.messageText = WebPreviewView.shortName(of: address) + " says"
        alert.informativeText = message
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        guard let window else { return completionHandler(false) }
        let alert = NSAlert()
        alert.messageText = WebPreviewView.shortName(of: address) + " asks"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        guard let window else { return completionHandler(nil) }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    // MARK: - Toolbar

    private func build() {
        for (button, symbol, tip, action) in [(backButton, "chevron.left", "Back", #selector(goBackInPage)),
                                              (forwardButton, "chevron.right", "Forward", #selector(goForwardInPage)),
                                              (reloadButton, "arrow.clockwise", "Reload", #selector(reload))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.isBordered = false
            button.toolTip = tip
            button.target = self
            button.action = action
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        addressField.font = .systemFont(ofSize: 12)
        addressField.placeholderString = "localhost:3000"
        addressField.bezelStyle = .roundedBezel
        addressField.controlSize = .small
        addressField.lineBreakMode = .byTruncatingTail
        addressField.cell?.usesSingleLineMode = true
        addressField.cell?.isScrollable = true
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(addressEntered)
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addressField.toolTip = "The address of your app on this Mac"

        deviceSwitch.segmentCount = Device.allCases.count
        deviceSwitch.trackingMode = .selectOne
        deviceSwitch.controlSize = .small
        deviceSwitch.segmentStyle = .texturedRounded
        for device in Device.allCases {
            deviceSwitch.setImage(NSImage(systemSymbolName: device.symbol, accessibilityDescription: device.toolTip), forSegment: device.rawValue)
            deviceSwitch.setToolTip(device.toolTip, forSegment: device.rawValue)
            deviceSwitch.setWidth(30, forSegment: device.rawValue)
        }
        deviceSwitch.selectedSegment = device.rawValue
        deviceSwitch.target = self
        deviceSwitch.action = #selector(deviceChosen)

        browserButton.bezelStyle = .recessed
        browserButton.controlSize = .small
        browserButton.target = self
        browserButton.action = #selector(openCurrentInBrowser)
        browserButton.toolTip = "Open this page in your default browser"
        browserButton.setContentHuggingPriority(.required, for: .horizontal)

        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Preview Tab")
        newTabButton.isBordered = false
        newTabButton.toolTip = "New Preview Tab, for another app (⌃⌥N)"
        newTabButton.target = self
        newTabButton.action = #selector(newTabClicked)
        newTabButton.setContentHuggingPriority(.required, for: .horizontal)

        let bar = NSStackView(views: [backButton, forwardButton, reloadButton, addressField, deviceSwitch, browserButton, newTabButton])
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(bar)

        messageLabel.alignment = .center
        messageLabel.isSelectable = false
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.isHidden = true
        stage.wantsLayer = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(webView)
        for view in [header, stage, messageLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // As wide as the chosen device, but never wider than the pane. The wish for a device's width is a weak
        // one on purpose: anything stronger than a split view's hold on its panes would widen the window instead.
        deviceWidth = webView.widthAnchor.constraint(equalToConstant: 390)
        deviceWidth.priority = NSLayoutConstraint.Priority(200)
        deviceWidth.isActive = false
        fullWidth = webView.widthAnchor.constraint(equalTo: stage.widthAnchor)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 32),
            bar.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            bar.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            stage.topAnchor.constraint(equalTo: header.bottomAnchor),
            stage.leadingAnchor.constraint(equalTo: leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.topAnchor.constraint(equalTo: stage.topAnchor),
            webView.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            webView.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            webView.widthAnchor.constraint(lessThanOrEqualTo: stage.widthAnchor),
            fullWidth,
            messageLabel.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: stage.widthAnchor, constant: -80),
        ])
        refreshButtons()
    }

    private func refreshButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    /// `overPage` keeps the page that is already showing; otherwise the message stands in for it.
    private func show(message: String, overPage: Bool) {
        guard !overPage else { return }          // the page is there and fine; the browser coming forward says the rest
        messageLabel.stringValue = message
        messageLabel.isHidden = false
        webView.isHidden = true
    }

    func setDevice(_ device: Device) {
        self.device = device
        deviceSwitch.selectedSegment = device.rawValue
        fullWidth.isActive = device.width == nil
        deviceWidth.isActive = device.width != nil
        if let width = device.width { deviceWidth.constant = width }
    }

    @objc private func deviceChosen() {
        setDevice(Device(rawValue: deviceSwitch.selectedSegment) ?? .desktop)
    }

    @objc private func goBackInPage() { webView.goBack() }
    @objc private func goForwardInPage() { webView.goForward() }

    @objc private func openCurrentInBrowser() {
        guard address != WebPreviewView.blank || webView.url != nil else { NSSound.beep(); return }
        WebPreviewView.openInBrowser(webView.url.flatMap { $0.scheme == "about" ? nil : PreviewAlias.shown($0) } ?? address)
    }

    @objc private func newTabClicked() {
        NSApp.sendAction(#selector(MainWindowController.newPreviewTab(_:)), to: nil, from: self)
    }

    /// Puts the cursor in the address field, as a browser does for a new tab.
    func focusAddress() { window?.makeFirstResponder(addressField) }

    @objc private func addressEntered() {
        guard let url = WebPreviewView.url(fromTyped: addressField.stringValue) else { NSSound.beep(); return }
        if load(url) { window?.makeFirstResponder(webView) }
    }

    func applyTheme() {
        let theme = Settings.shared.theme
        layer?.backgroundColor = theme.background.cgColor
        header.wantsLayer = true
        header.layer?.backgroundColor = theme.chrome.cgColor
        // Beside a phone-sized page: the colour of the window's furniture, so the page reads as a device.
        stage.layer?.backgroundColor = theme.chrome.cgColor
        messageLabel.textColor = theme.lineNumber
        for button in [backButton, forwardButton, reloadButton, newTabButton] { button.contentTintColor = theme.lineNumber }
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        // The page itself keeps the system's appearance: it is the user's app, not part of Feather's theme.
        webView.appearance = NSApp.effectiveAppearance
    }
}

// MARK: - Preview tabs

extension EditorAreaViewController {
    /// Opens (or comes back to) the preview of one address. `server` is the file server started for it, if any.
    @discardableResult
    func openWebPreview(_ address: URL, server: StaticFileServer? = nil, named name: String? = nil) -> WebPreviewView? {
        let address = WebPreviewView.replacingAnyAddress(in: address)
        guard WebPreviewView.isLocal(address) || address == WebPreviewView.blank else {
            WebPreviewView.openInBrowser(address)
            return nil
        }
        let name = name ?? WebPreviewView.shortName(of: address)
        // Like a diff tab: an identity of its own that names no real file. The extension is for the tab's icon.
        let folder = store.projectRoot ?? FileManager.default.temporaryDirectory
        let key = folder.appendingPathComponent("⟨Preview⟩ \(name).html")
        if let index = tabs.firstIndex(where: { $0.url == key }), let existing = tabs[index].preview as? WebPreviewView {
            select(index)
            if existing.address != address || server != nil { existing.load(address) } else { existing.reload() }
            return existing
        }
        let view = WebPreviewView(address: address, watching: server?.root ?? store.projectRoot, server: server)
        let document = store.openVirtual(key, title: "Preview: \(name)")
        view.onTitleChange = { [weak document] title in
            guard let document else { return }
            let shown = title.flatMap { $0.isEmpty ? nil : $0 } ?? name
            guard document.displayTitle != "Preview: \(shown)" else { return }
            document.displayTitle = "Preview: \(shown)"
            NotificationCenter.default.post(name: TextDocument.stateDidChange, object: document)
        }
        addViewTab(for: document, preview: view)
        return view
    }

    /// The preview in front, if that is what this group is showing.
    var currentWebPreview: WebPreviewView? { currentTab?.preview as? WebPreviewView }

    /// Serves the folder of an HTML file from a server of its own and shows the page.
    func previewPage(_ file: URL) {
        let file = file.standardizedFileURL
        // The whole project is served when the page belongs to it, so "/css/site.css" finds its file; a loose
        // page gets its own folder.
        var root = file.deletingLastPathComponent()
        if let project = store.projectRoot, file.resolvingSymlinksInPath().path.hasPrefix(project.resolvingSymlinksInPath().path + "/") { root = project }
        let server = StaticFileServer(root: root)
        server.start { [weak self] port in
            guard let self, port != nil, let address = server.address(of: file) else {
                server.stop()
                let alert = NSAlert()
                alert.messageText = "The preview could not start"
                alert.informativeText = "Feather could not set up a place on this Mac to show “\(file.lastPathComponent)” from. Try again in a moment."
                alert.runModal()
                return
            }
            self.openWebPreview(address, server: server, named: file.lastPathComponent)
        }
    }
}

extension EditorTab {
    var isHTML: Bool { document.displayTitle == nil && ["html", "htm"].contains(url?.pathExtension.lowercased() ?? "") }
}

extension MainWindowController {
    /// View ▸ Open Preview…: asks where the app is running. The last answer for this project is offered again.
    @objc func openPreview(_ sender: Any?) {
        let root = editorArea.store.projectRoot
        let alert = NSAlert()
        alert.messageText = "Where is your app running?"
        alert.informativeText = "When you start your app, it prints an address such as localhost:3000. Feather shows that page here, beside your code, and loads it again whenever a file changes."
        alert.addButton(withTitle: "Open Preview")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = Settings.shared.previewAddress(for: root)
        field.placeholderString = Settings.defaultPreviewAddress
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let url = WebPreviewView.url(fromTyped: field.stringValue) else { NSSound.beep(); return }
        openPreview(at: url)
    }

    /// Shows `url` in a preview tab of this window and remembers it as this project's address.
    func openPreview(at url: URL) {
        let url = WebPreviewView.replacingAnyAddress(in: url)
        if WebPreviewView.isLocal(url) { Settings.shared.setPreviewAddress(url.absoluteString, for: editorArea.store.projectRoot) }
        editorArea.openWebPreview(url)
    }

    /// View ▸ New Preview Tab (⌃⌥N), and the "+" in a preview: one more preview, for a second app (another front
    /// end, an admin site). It starts empty with the cursor in its address field, as a browser's new tab does.
    @objc func newPreviewTab(_ sender: Any?) {
        var number = 2
        // Counted by the tabs' own keys: a tab's title becomes its page's title once it shows one.
        let taken = Set(editorArea.tabs.compactMap { $0.url?.lastPathComponent })
        while taken.contains("⟨Preview⟩ New Tab \(number).html") { number += 1 }
        guard let view = editorArea.openWebPreview(WebPreviewView.blank, named: "New Tab \(number)") else { return }
        DispatchQueue.main.async { view.focusAddress() }
    }

    /// The address this project's app was last seen at, or the usual one for a project never previewed.
    private var rememberedPreviewURL: URL? {
        WebPreviewView.url(fromTyped: Settings.shared.previewAddress(for: editorArea.store.projectRoot))
    }

    /// View ▸ Show Preview (⌃⌥P): straight to the app, no questions. The address is the one remembered for this
    /// project; "Open Preview…" is where it is changed.
    @objc func showPreviewNow(_ sender: Any?) {
        guard let url = rememberedPreviewURL else { openPreview(sender); return }
        openPreview(at: url)
    }

    /// The same, in a new editor group beside the code.
    @objc func showPreviewToSide(_ sender: Any?) {
        guard let url = rememberedPreviewURL else { openPreview(sender); return }
        splitEditor(sender)
        openPreview(at: url)
    }

    /// The running app in the user's own browser (⌃⌥B).
    @objc func openAppInBrowser(_ sender: Any?) {
        guard let url = rememberedPreviewURL else { NSSound.beep(); return }
        WebPreviewView.openInBrowser(PreviewAlias.shown(url))
    }

    /// View ▸ Preview This Page: the HTML file in front, as a browser would show it.
    @objc func previewThisPage(_ sender: Any?) {
        guard let tab = editorArea.currentTab, tab.isHTML, let file = tab.url else { NSSound.beep(); return }
        editorArea.previewPage(file)
    }
}
