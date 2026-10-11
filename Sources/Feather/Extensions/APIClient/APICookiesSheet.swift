import AppKit

/// The cookies the API client holds for this project, as Postman's Cookies window shows them: one row per
/// cookie with where it applies and when it ends, Delete for one, Clear All for the lot. Opened from the
/// Cookies button beside Send and from Requests ▸ Cookies….
final class APICookiesSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private static var open: [APICookiesSheet] = []
    private weak var controller: APIClientController?
    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "")
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private var cookies: [APICookie] = []
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func present(in controller: APIClientController) {
        guard let parent = controller.window?.window else { return }
        let sheet = APICookiesSheet(controller: controller)
        open.append(sheet)
        parent.beginSheet(sheet.window!) { _ in open.removeAll { $0 === sheet } }
    }

    private init(controller: APIClientController) {
        self.controller = controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 380), styleMask: [.titled], backing: .buffered, defer: true)
        super.init(window: window)
        build()
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: APICookieJar.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        guard let content = window?.contentView else { return }
        let theme = Settings.shared.theme
        window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let title = NSTextField(labelWithString: "Cookies")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "What servers set while you sent requests. Each one goes back with later requests to its host (any port, any path under its path). Kept in your own folder, never in the project; session cookies end when Feather quits.")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor

        for (id, name, width) in [("name", "Cookie", 130.0), ("value", "Value", 200.0), ("domain", "Host", 110.0), ("path", "Path", 70.0), ("expires", "Ends", 150.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = name
            column.width = width
            table.addTableColumn(column)
        }
        table.rowHeight = 22
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        let clear = NSButton(title: "Clear All", target: self, action: #selector(clearAll))
        clear.bezelStyle = .rounded
        let done = NSButton(title: "Done", target: self, action: #selector(close(_:)))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [summary, NSView(), deleteButton, clear, done])
        buttons.spacing = 8

        let column = NSStackView(views: [title, intro, scroll, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            buttons.widthAnchor.constraint(equalTo: column.widthAnchor),
            intro.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    @objc private func reload() {
        cookies = controller?.workspace.cookies.cookies.sorted { ($0.domain, $0.name) < ($1.domain, $1.name) } ?? []
        table.reloadData()
        summary.stringValue = cookies.isEmpty ? "No cookies yet. Send a request to a server that signs you in, and its cookie appears here."
            : "\(cookies.count) cookie\(cookies.count == 1 ? "" : "s")"
        deleteButton.isEnabled = !cookies.isEmpty
    }

    @objc private func deleteSelected() {
        guard let jar = controller?.workspace.cookies else { return }
        let selected = table.selectedRowIndexes.map { cookies[$0] }
        for cookie in selected.isEmpty ? [] : selected { jar.remove(name: cookie.name, domain: cookie.domain) }
    }

    @objc private func clearAll() { controller?.workspace.cookies.clear() }

    @objc private func close(_ sender: Any?) {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { cookies.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cookie = cookies[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "name": text = cookie.name
        case "value": text = cookie.value
        case "domain": text = cookie.domain
        case "path": text = cookie.path
        default:
            var flags: [String] = []
            if cookie.secure { flags.append("Secure") }
            if cookie.httpOnly { flags.append("HttpOnly") }
            text = (cookie.expires.map(formatter.string) ?? "When Feather quits") + (flags.isEmpty ? "" : "  " + flags.joined(separator: " "))
        }
        let identifier = NSUserInterfaceItemIdentifier("CookieCell")
        let field = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.font = .systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingTail
            return field
        }()
        field.stringValue = text
        field.toolTip = text
        return field
    }
}

extension MainWindowController {
    /// Requests ▸ Cookies…: what the API client holds and sends back.
    @objc func apiShowCookies(_ sender: Any?) {
        guard let client = apiClient else { return }
        APICookiesSheet.present(in: client)
    }
}
