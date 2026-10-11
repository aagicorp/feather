import AppKit

/// A request in a tab: method, address and Send on top, the request's parts as tabs under it, and the answer in
/// a split below (or beside). Edits mark the tab dirty; ⌘S saves the request into its collection through the
/// workspace, or asks which collection a scratch request should go in.
final class APIRequestView: NSView, TabPreview, NSTextFieldDelegate {
    private(set) var request: APIRequest
    private(set) var collectionID: String?
    /// The tab's identity, for the dirty dot and the title.
    weak var document: TextDocument? { didSet { updateTabIcon() } }

    /// The tab and the breadcrumb show the method in its colour instead of a file icon.
    private func updateTabIcon() {
        document?.tabIcon = APIFormat.methodBadge(request.method, theme: theme)
    }
    private weak var controller: APIClientController?
    private weak var pane: APIPaneViewController?
    private let sender = APIRequestSender()

    private let methodPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// The method on a pill of its own colour, as in the tree and the tab.
    private let methodPill = NSView()
    private let urlField = NSTextField()
    /// The environment whose variables fill in the address, so what will be sent is readable at a glance.
    private let environmentChip = NSButton(title: "", target: nil, action: nil)
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    /// Cookies, Copy as cURL, where the answer goes: used now and then, so under one menu.
    private let moreButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let sections = APITabStrip()
    var sectionsForTests: APITabStrip { sections }
    var environmentChipTitleForTests: String { environmentChip.title }
    private let sectionContainer = NSView()
    private let split = NSSplitView()
    private let requestPart = NSView()
    let response = APIResponseView()

    private var paramsTable: APIEditableTable!
    private var headersTable: APIEditableTable!
    private var checksTable: APIEditableTable!
    private var capturesTable: APIEditableTable!
    private let bodyView = NSView()
    private let bodyKindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let bodyContainer = NSView()
    private var bodyFieldsTable: APIEditableTable!
    private var bodyFilesTable: APIEditableTable!
    private let bodyFilesBox = NSStackView()
    private let bodyNone = NSTextField(labelWithString: "This request sends no body.")
    private var bodyEditor: EditorView?
    private var bodyDocument: TextDocument?
    private let authView = NSView()
    private let authKindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let authRows = NSStackView()
    private var authFields: [String: NSTextField] = [:]
    private let authPlace = NSPopUpButton(frame: .zero, pullsDown: false)
    private let authHint = NSTextField(wrappingLabelWithString: "")

    private static let layoutKey = "apiResponseBeside"
    private var didPlaceDivider = false

    var focusView: NSView { urlField }

    init(request: APIRequest, collectionID: String?, controller: APIClientController, pane: APIPaneViewController) {
        self.request = request
        self.collectionID = collectionID
        self.controller = controller
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        build()
        load()
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { sender.cancel() }

    var isDirty: Bool { document?.isDirty ?? false }
    private var workspace: APIWorkspace? { controller?.workspace }
    private var theme: Theme { Settings.shared.theme }

    // MARK: Building

    private func build() {
        for method in APIMethod.allCases { methodPopup.addItem(withTitle: method.rawValue) }
        methodPopup.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        methodPopup.target = self
        methodPopup.action = #selector(methodChanged)
        methodPopup.toolTip = "What the request does: GET reads, POST creates, PUT and PATCH change, DELETE removes"

        urlField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        urlField.placeholderString = "https://api.example.com/path?query=1 — {{name}} uses a variable"
        urlField.delegate = self
        urlField.isBordered = true
        urlField.bezelStyle = .roundedBezel
        urlField.focusRingType = .none
        urlField.cell?.usesSingleLineMode = true
        urlField.cell?.isScrollable = true
        urlField.lineBreakMode = .byTruncatingTail

        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = [.command]
        sendButton.bezelColor = .controlAccentColor          // the one accent on the bar: what the screen is for
        sendButton.toolTip = "Send the request (⌘↩)"
        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        saveButton.bezelStyle = .rounded
        saveButton.toolTip = "Save the request into its collection (⌘S)"
        saveButton.target = self
        saveButton.action = #selector(saveClicked)

        methodPopup.isBordered = false
        methodPill.wantsLayer = true
        methodPill.layer?.cornerRadius = 6
        methodPill.translatesAutoresizingMaskIntoConstraints = false
        methodPopup.translatesAutoresizingMaskIntoConstraints = false
        methodPill.addSubview(methodPopup)
        NSLayoutConstraint.activate([
            methodPopup.leadingAnchor.constraint(equalTo: methodPill.leadingAnchor, constant: 6),
            methodPopup.trailingAnchor.constraint(equalTo: methodPill.trailingAnchor, constant: -2),
            methodPopup.topAnchor.constraint(equalTo: methodPill.topAnchor, constant: 1),
            methodPopup.bottomAnchor.constraint(equalTo: methodPill.bottomAnchor, constant: -1),
        ])
        environmentChip.isBordered = false
        environmentChip.font = .systemFont(ofSize: 11)
        environmentChip.toolTip = "The environment whose variables fill in {{names}}; change it in the Requests sidebar"
        environmentChip.setContentHuggingPriority(.required, for: .horizontal)
        environmentChip.setContentCompressionResistancePriority(.required, for: .horizontal)
        moreButton.bezelStyle = .rounded
        moreButton.pullsDown = true
        moreButton.addItem(withTitle: "")
        moreButton.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")
        moreButton.toolTip = "Cookies, copy as cURL, where the answer is shown"
        for (title, action) in [("Cookies…", #selector(cookiesClicked)), ("Copy as cURL", #selector(copyCurlClicked)),
                                ("Show Answer Beside the Request", #selector(layoutClicked))] as [(String, Selector)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            moreButton.menu?.addItem(item)
        }
        moreButton.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let top = NSStackView(views: [methodPill, urlField, environmentChip, sendButton, saveButton, moreButton])
        top.spacing = 6
        top.translatesAutoresizingMaskIntoConstraints = false
        methodPill.setContentHuggingPriority(.required, for: .horizontal)
        urlField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        sections.onSelect = { [weak self] index in self?.showSection(index) }
        sections.trailingButton.target = self
        sections.trailingButton.action = #selector(bulkEditClicked)
        sections.translatesAutoresizingMaskIntoConstraints = false
        sectionContainer.translatesAutoresizingMaskIntoConstraints = false

        buildSections()

        requestPart.addSubview(top)
        requestPart.addSubview(sections)
        requestPart.addSubview(sectionContainer)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: requestPart.topAnchor, constant: 8),
            top.leadingAnchor.constraint(equalTo: requestPart.leadingAnchor, constant: 10),
            top.trailingAnchor.constraint(equalTo: requestPart.trailingAnchor, constant: -10),
            sections.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 6),
            sections.leadingAnchor.constraint(equalTo: requestPart.leadingAnchor, constant: 10),
            sections.trailingAnchor.constraint(equalTo: requestPart.trailingAnchor, constant: -10),
            sectionContainer.topAnchor.constraint(equalTo: sections.bottomAnchor, constant: 6),
            sectionContainer.leadingAnchor.constraint(equalTo: requestPart.leadingAnchor, constant: 10),
            sectionContainer.trailingAnchor.constraint(equalTo: requestPart.trailingAnchor, constant: -10),
            sectionContainer.bottomAnchor.constraint(equalTo: requestPart.bottomAnchor, constant: -6),
        ])

        split.isVertical = UserDefaults.standard.bool(forKey: APIRequestView.layoutKey)
        split.dividerStyle = .thin
        split.addArrangedSubview(requestPart)
        split.addArrangedSubview(response)
        split.translatesAutoresizingMaskIntoConstraints = false
        addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: topAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
            requestPart.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            response.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            requestPart.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            response.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        response.onCancel = { [weak self] in self?.cancel() }
        response.onCopyPath = { [weak self] path in self?.controller?.notice("Copied " + path) }
        updateLayoutButton()
        showSection(0)
    }

    private func buildSections() {
        paramsTable = keyValueTable(rows: { [weak self] in self?.request.params ?? [] }, set: { [weak self] rows in
            self?.request.params = rows
            self?.updateURLFromParams()
        }, namePlaceholder: "name", valuePlaceholder: "value", prompt: "Add parameter")
        headersTable = keyValueTable(rows: { [weak self] in self?.request.headers ?? [] }, set: { [weak self] in self?.request.headers = $0 },
                                     namePlaceholder: "Header-Name", valuePlaceholder: "value", prompt: "Add header")
        buildBody()
        buildAuth()
        buildChecks()
        buildCaptures()
    }

    private func keyValueTable(rows: @escaping () -> [APIKeyValue], set: @escaping ([APIKeyValue]) -> Void,
                               namePlaceholder: String, valuePlaceholder: String, prompt: String) -> APIEditableTable {
        let change: (Int, (inout APIKeyValue) -> Void) -> Void = { [weak self] index, edit in
            var list = rows()
            guard list.indices.contains(index) else { return }
            edit(&list[index])
            set(list)
            self?.markDirty()
        }
        let table = APIEditableTable(columns: [
            .init(id: "on", title: "", width: 24, cell: { .toggle(rows()[$0].enabled) }, set: { index, value in change(index) { $0.enabled = value == "1" } }),
            .init(id: "name", title: "Name", width: nil, cell: { .text(rows()[$0].name, placeholder: namePlaceholder) }, set: { index, value in change(index) { $0.name = value } }),
            .init(id: "value", title: "Value", width: nil, cell: { .text(rows()[$0].value, placeholder: valuePlaceholder) }, set: { index, value in change(index) { $0.value = value } }),
            .init(id: "note", title: "Description", width: nil, cell: { .text(rows()[$0].note ?? "", placeholder: "description") },
                  set: { index, value in change(index) { $0.note = value.isEmpty ? nil : value } }),
        ])
        table.count = { rows().count }
        table.addPrompt = prompt
        table.onAdd = { set(rows() + [APIKeyValue("", "")]); }
        table.blankRow = { id in
            switch id {
            case "on": return .toggle(true)
            case "name": return .text("", placeholder: namePlaceholder)
            case "value": return .text("", placeholder: valuePlaceholder)
            default: return .text("", placeholder: "description")
            }
        }
        table.bulkRows = rows
        table.onBulkApply = { [weak self] in set($0); self?.markDirty(); self?.updateSectionLabels() }
        table.onRemove = { index in
            var list = rows()
            guard list.indices.contains(index) else { return }
            list.remove(at: index)
            set(list)
        }
        let originalAdd = table.onAdd
        table.onAdd = { [weak self] in originalAdd?(); self?.markDirty() }
        let originalRemove = table.onRemove
        table.onRemove = { [weak self] in originalRemove?($0); self?.markDirty() }
        return table
    }

    private static let bodyKinds: [(title: String, kind: APIBody.Kind, contentType: String?)] = [
        ("No body", .none, nil), ("JSON", .raw, "application/json"), ("Text", .raw, "text/plain"),
        ("Form", .form, nil), ("Form (URL-encoded)", .urlencoded, nil), ("Multipart form (with files)", .multipart, nil),
    ]

    private func buildBody() {
        for kind in APIRequestView.bodyKinds { bodyKindPopup.addItem(withTitle: kind.title) }
        bodyKindPopup.controlSize = .small
        bodyKindPopup.font = .systemFont(ofSize: 11)
        bodyKindPopup.target = self
        bodyKindPopup.action = #selector(bodyKindChanged)
        let kindLabel = NSTextField(labelWithString: "Body:")
        kindLabel.font = .systemFont(ofSize: 11)
        let row = NSStackView(views: [kindLabel, bodyKindPopup])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        bodyView.addSubview(row)
        bodyView.addSubview(bodyContainer)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: bodyView.topAnchor),
            row.leadingAnchor.constraint(equalTo: bodyView.leadingAnchor),
            bodyContainer.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 6),
            bodyContainer.leadingAnchor.constraint(equalTo: bodyView.leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: bodyView.trailingAnchor),
            bodyContainer.bottomAnchor.constraint(equalTo: bodyView.bottomAnchor),
        ])
        bodyFieldsTable = keyValueTable(rows: { [weak self] in self?.request.body.fields ?? [] }, set: { [weak self] in self?.request.body.fields = $0 },
                                        namePlaceholder: "field", valuePlaceholder: "value", prompt: "Add field")
        let files: () -> [APIFormFile] = { [weak self] in self?.request.body.files ?? [] }
        bodyFilesTable = APIEditableTable(columns: [
            .init(id: "on", title: "", width: 24, cell: { .toggle(files()[$0].enabled) }, set: { [weak self] index, value in self?.changeFileRow(index) { $0.enabled = value == "1" } }),
            .init(id: "name", title: "Field", width: 120, cell: { .text(files()[$0].name, placeholder: "file") }, set: { [weak self] index, value in self?.changeFileRow(index) { $0.name = value } }),
            .init(id: "path", title: "File", width: nil, cell: { .text(files()[$0].path, placeholder: "path, relative to the project") }, set: { [weak self] index, value in self?.changeFileRow(index) { $0.path = value } }),
        ], addTip: "Choose a file to upload", removeTip: "Remove the selected file")
        bodyFilesTable.count = { files().count }
        bodyFilesTable.emptyText = "Files to upload with the form."
        bodyFilesTable.onAdd = { [weak self] in self?.chooseFile() }
        bodyFilesTable.onRemove = { [weak self] index in
            guard let self, self.request.body.files.indices.contains(index) else { return }
            self.request.body.files.remove(at: index)
            self.markDirty()
        }
        bodyFilesBox.orientation = .vertical
        bodyFilesBox.alignment = .leading
        bodyFilesBox.spacing = 4
        bodyFilesBox.distribution = .fillEqually
        bodyFilesBox.addArrangedSubview(bodyFieldsTable)
        bodyFilesBox.addArrangedSubview(bodyFilesTable)
        bodyFieldsTable.widthAnchor.constraint(equalTo: bodyFilesBox.widthAnchor).isActive = true
        bodyFilesTable.widthAnchor.constraint(equalTo: bodyFilesBox.widthAnchor).isActive = true
        bodyNone.font = .systemFont(ofSize: 11.5)
    }

    private func changeFileRow(_ index: Int, _ edit: (inout APIFormFile) -> Void) {
        guard request.body.files.indices.contains(index) else { return }
        edit(&request.body.files[index])
        markDirty()
    }

    private func chooseFile() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the file to upload."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            var path = url.path
            if let root = self.workspace?.projectRoot?.path, path.hasPrefix(root + "/") { path = String(path.dropFirst(root.count + 1)) }
            self.request.body.files.append(APIFormFile(name: "file", path: path))
            self.markDirty()
            self.bodyFilesTable.reload()
        }
    }

    private static let authKinds: [(title: String, kind: APIAuth.Kind)] = [
        ("Inherit from the folder or collection", .inherit), ("No auth", .none), ("Bearer token", .bearer),
        ("Basic (username and password)", .basic), ("API key", .apiKey),
    ]

    private func buildAuth() {
        for kind in APIRequestView.authKinds { authKindPopup.addItem(withTitle: kind.title) }
        authKindPopup.controlSize = .small
        authKindPopup.font = .systemFont(ofSize: 11)
        authKindPopup.target = self
        authKindPopup.action = #selector(authKindChanged)
        authRows.orientation = .vertical
        authRows.alignment = .leading
        authRows.spacing = 6
        authHint.font = .systemFont(ofSize: 11)
        authHint.preferredMaxLayoutWidth = 500
        for (id, placeholder, secure) in [("token", "Token, or {{token}} from a variable", false), ("username", "Username", false), ("password", "Password", true),
                                          ("keyName", "Name of the header or query parameter, e.g. X-Api-Key", false), ("keyValue", "The key, or {{apiKey}}", false)] {
            let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
            field.placeholderString = placeholder
            field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            field.controlSize = .small
            field.delegate = self
            field.identifier = NSUserInterfaceItemIdentifier(id)
            field.widthAnchor.constraint(equalToConstant: 360).isActive = true
            authFields[id] = field
        }
        authPlace.addItem(withTitle: "Send as a header")
        authPlace.addItem(withTitle: "Send as a query parameter")
        authPlace.controlSize = .small
        authPlace.font = .systemFont(ofSize: 11)
        authPlace.target = self
        authPlace.action = #selector(authPlaceChanged)
        let column = NSStackView(views: [authKindPopup, authHint, authRows])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        authView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: authView.topAnchor),
            column.leadingAnchor.constraint(equalTo: authView.leadingAnchor),
            column.trailingAnchor.constraint(lessThanOrEqualTo: authView.trailingAnchor),
        ])
    }

    private func layoutAuthRows() {
        authRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        func row(_ title: String, _ control: NSView) -> NSView {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11)
            label.textColor = theme.lineNumber
            label.widthAnchor.constraint(equalToConstant: 70).isActive = true
            label.alignment = .right
            let stack = NSStackView(views: [label, control])
            stack.spacing = 8
            return stack
        }
        switch request.auth.kind {
        case .inherit:
            authHint.stringValue = "Uses whatever the folder or collection is set to. Collections start with no auth; set theirs from the collection's Variables… sheet."
        case .none:
            authHint.stringValue = "Nothing is added for authentication."
        case .bearer:
            authHint.stringValue = "Sends an Authorization: Bearer header."
            authRows.addArrangedSubview(row("Token", authFields["token"]!))
        case .basic:
            authHint.stringValue = "Sends an Authorization: Basic header with the two joined and encoded."
            authRows.addArrangedSubview(row("Username", authFields["username"]!))
            authRows.addArrangedSubview(row("Password", authFields["password"]!))
        case .apiKey:
            authHint.stringValue = "Sends the key as a header or a query parameter."
            authRows.addArrangedSubview(row("Name", authFields["keyName"]!))
            authRows.addArrangedSubview(row("Key", authFields["keyValue"]!))
            authRows.addArrangedSubview(row("Where", authPlace))
        }
        authFields["token"]?.stringValue = request.auth.token
        authFields["username"]?.stringValue = request.auth.username
        authFields["password"]?.stringValue = request.auth.password
        authFields["keyName"]?.stringValue = request.auth.keyName
        authFields["keyValue"]?.stringValue = request.auth.keyValue
        authPlace.selectItem(at: request.auth.keyIn == .header ? 0 : 1)
    }

    static let checkKinds: [(title: String, kind: APICheck.Kind)] = [
        ("Status code", .status), ("JSON value", .jsonPath), ("Header", .header), ("Body text", .bodyContains), ("Time (ms)", .time),
    ]
    static let operators: [(title: String, op: APICheck.Operator)] = [
        ("is", .equals), ("is not", .notEquals), ("contains", .contains), ("does not contain", .notContains),
        ("is present", .exists), ("is missing", .notExists), ("is under", .lessThan), ("is over", .greaterThan), ("matches (regex)", .matches),
    ]

    private func buildChecks() {
        let checks: () -> [APICheck] = { [weak self] in self?.request.checks ?? [] }
        let kinds = APIRequestView.checkKinds.map { (title: $0.title, value: $0.kind.rawValue) }
        let operators = APIRequestView.operators.map { (title: $0.title, value: $0.op.rawValue) }
        checksTable = APIEditableTable(columns: [
            .init(id: "on", title: "", width: 24, cell: { .toggle(checks()[$0].enabled) }, set: { [weak self] index, value in self?.changeCheck(index) { $0.enabled = value == "1" } }),
            .init(id: "kind", title: "Check", width: 110, cell: { .popup(options: kinds, value: checks()[$0].kind.rawValue) },
                  set: { [weak self] index, value in self?.changeCheck(index) { $0.kind = APICheck.Kind(rawValue: value) ?? .status } }),
            .init(id: "target", title: "Which", width: nil, cell: {
                let check = checks()[$0]
                let needsTarget = check.kind == .jsonPath || check.kind == .header
                return .text(check.target, placeholder: check.kind == .header ? "Content-Type" : (check.kind == .jsonPath ? "$.user.id" : "—"), enabled: needsTarget)
            }, set: { [weak self] index, value in self?.changeCheck(index) { $0.target = value } }),
            .init(id: "op", title: "Is", width: 120, cell: { .popup(options: operators, value: checks()[$0].op.rawValue) },
                  set: { [weak self] index, value in self?.changeCheck(index) { $0.op = APICheck.Operator(rawValue: value) ?? .equals } }),
            .init(id: "expected", title: "Expected", width: nil, cell: {
                let check = checks()[$0]
                let needsValue = check.op != .exists && check.op != .notExists
                return .text(check.expected, placeholder: check.kind == .status ? "200" : (check.kind == .time ? "500" : "value"), enabled: needsValue)
            }, set: { [weak self] index, value in self?.changeCheck(index) { $0.expected = value } }),
        ], addTip: "Add a check", removeTip: "Remove the selected check")
        checksTable.count = { checks().count }
        checksTable.emptyText = "Checks run on the answer: status is 200, a JSON value, a header, the time…"
        checksTable.onAdd = { [weak self] in
            self?.request.checks.append(APICheck.status(200))
            self?.markDirty()
            self?.updateSectionLabels()
        }
        checksTable.onRemove = { [weak self] index in
            guard let self, self.request.checks.indices.contains(index) else { return }
            self.request.checks.remove(at: index)
            self.markDirty()
            self.updateSectionLabels()
        }
    }

    private func changeCheck(_ index: Int, _ edit: (inout APICheck) -> Void) {
        guard request.checks.indices.contains(index) else { return }
        edit(&request.checks[index])
        markDirty()
        updateSectionLabels()
    }

    private func buildCaptures() {
        let captures: () -> [APICapture] = { [weak self] in self?.request.captures ?? [] }
        let sources = [(title: "JSON value", value: APICapture.Source.jsonPath.rawValue), (title: "Header", value: APICapture.Source.header.rawValue),
                       (title: "Status code", value: APICapture.Source.status.rawValue)]
        let scopes = [(title: "Environment", value: APICapture.Scope.environment.rawValue), (title: "Collection", value: APICapture.Scope.collection.rawValue)]
        capturesTable = APIEditableTable(columns: [
            .init(id: "on", title: "", width: 24, cell: { .toggle(captures()[$0].enabled) }, set: { [weak self] index, value in self?.changeCapture(index) { $0.enabled = value == "1" } }),
            .init(id: "variable", title: "Variable", width: 130, cell: { .text(captures()[$0].variable, placeholder: "token") }, set: { [weak self] index, value in self?.changeCapture(index) { $0.variable = value } }),
            .init(id: "source", title: "From", width: 100, cell: { .popup(options: sources, value: captures()[$0].source.rawValue) },
                  set: { [weak self] index, value in self?.changeCapture(index) { $0.source = APICapture.Source(rawValue: value) ?? .jsonPath } }),
            .init(id: "path", title: "Path or name", width: nil, cell: {
                let capture = captures()[$0]
                return .text(capture.path, placeholder: capture.source == .header ? "Set-Cookie" : "$.token", enabled: capture.source != .status)
            }, set: { [weak self] index, value in self?.changeCapture(index) { $0.path = value } }),
            .init(id: "scope", title: "Save in", width: 100, cell: { .popup(options: scopes, value: captures()[$0].scope.rawValue) },
                  set: { [weak self] index, value in self?.changeCapture(index) { $0.scope = APICapture.Scope(rawValue: value) ?? .environment } }),
        ], addTip: "Add a variable to set from the answer", removeTip: "Remove the selected row")
        capturesTable.count = { captures().count }
        capturesTable.emptyText = "Take values from the answer into variables, e.g. $.token → token, for the requests after this one."
        capturesTable.onAdd = { [weak self] in
            self?.request.captures.append(APICapture(variable: "", path: ""))
            self?.markDirty()
            self?.updateSectionLabels()
        }
        capturesTable.onRemove = { [weak self] index in
            guard let self, self.request.captures.indices.contains(index) else { return }
            self.request.captures.remove(at: index)
            self.markDirty()
            self.updateSectionLabels()
        }
    }

    private func changeCapture(_ index: Int, _ edit: (inout APICapture) -> Void) {
        guard request.captures.indices.contains(index) else { return }
        edit(&request.captures[index])
        markDirty()
        updateSectionLabels()
    }

    // MARK: Showing the request

    private func load() {
        methodPopup.selectItem(withTitle: request.method.rawValue)
        colourMethod()
        // A request whose address still carries a query (an import) shows it in the table too.
        if request.url.contains("?") {
            let (base, params) = APIFormat.params(afterEditingURL: request.url, previous: request.params)
            request.url = base
            request.params = params + request.params.filter { row in !params.contains { $0.id == row.id } }
        }
        urlField.stringValue = APIFormat.joinQuery(base: request.url, params: request.params)
        colourURL()
        updateEnvironmentChip()
        if let index = APIRequestView.bodyKinds.firstIndex(where: { $0.kind == request.body.kind && ($0.contentType == nil || $0.contentType == request.body.contentType) }) {
            bodyKindPopup.selectItem(at: index)
        } else {
            bodyKindPopup.selectItem(at: request.body.kind == .raw ? 2 : 0)
        }
        showBodyKind()
        authKindPopup.selectItem(at: APIRequestView.authKinds.firstIndex { $0.kind == request.auth.kind } ?? 0)
        layoutAuthRows()
        updateSectionLabels()
        paramsTable.reload()
        headersTable.reload()
        checksTable.reload()
        capturesTable.reload()
        saveButton.title = collectionID == nil ? "Save…" : "Save"
    }

    /// The tabs' pills: how many rows a list has, what kind of body and auth there is.
    static func sectionItems(for request: APIRequest) -> [APITabStrip.Item] {
        func count(_ n: Int) -> String? { n == 0 ? nil : String(n) }
        let named = { (rows: [APIKeyValue]) in rows.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }.count }
        let body: String?
        switch request.body.kind {
        case .none: body = nil
        case .raw: body = request.body.contentType.lowercased().contains("json") ? "JSON" : "Text"
        case .form, .urlencoded: body = "Form"
        case .multipart: body = "Files"
        }
        let auth: String?
        switch request.auth.kind {
        case .inherit: auth = nil
        case .none: auth = "None"
        case .bearer: auth = "Bearer"
        case .basic: auth = "Basic"
        case .apiKey: auth = "Key"
        }
        return [.init(title: "Params", badge: count(named(request.params))), .init(title: "Headers", badge: count(named(request.headers))),
                .init(title: "Body", badge: body), .init(title: "Auth", badge: auth),
                .init(title: "Checks", badge: count(request.checks.count)), .init(title: "Variables", badge: count(request.captures.count))]
    }

    private func updateSectionLabels() {
        sections.items = APIRequestView.sectionItems(for: request)
        updateBulkButton()
    }

    /// Params, Headers and a form body can be edited as text, one `name: value` a line.
    private var bulkTable: APIEditableTable? {
        switch sections.selectedIndex {
        case 0: return paramsTable
        case 1: return headersTable
        case 2: return request.body.kind == .form || request.body.kind == .urlencoded ? bodyFieldsTable : nil
        default: return nil
        }
    }

    private func updateBulkButton() {
        let table = bulkTable
        sections.trailingButton.isHidden = table == nil
        sections.trailingButton.title = table?.isBulkEditing == true ? "Table" : "Bulk edit"
        sections.trailingButton.toolTip = table?.isBulkEditing == true ? "Back to the table" : "Edit as text, one name: value a line (// in front switches a row off)"
    }

    @objc private func bulkEditClicked() {
        guard let table = bulkTable else { return }
        table.setBulkEditing(!table.isBulkEditing)
        updateBulkButton()
    }

    private func updateEnvironmentChip() {
        let name = controller?.selectedEnvironment?.name
        environmentChip.title = name ?? "No environment"
        environmentChip.contentTintColor = name == nil ? theme.lineNumber : theme.accent
    }

    /// Shows one of Params, Headers, Body, Auth, Checks, Variables.
    func showSection(_ index: Int) {
        let views: [NSView] = [paramsTable, headersTable, bodyView, authView, checksTable, capturesTable]
        guard views.indices.contains(index) else { return }
        sections.selectedIndex = index
        sectionContainer.subviews.forEach { $0.removeFromSuperview() }
        let view = views[index]
        view.frame = sectionContainer.bounds
        view.autoresizingMask = [.width, .height]
        sectionContainer.addSubview(view)
        if index == 2, request.body.kind == .raw { showBodyKind() }
        updateBulkButton()
    }

    private func showBodyKind() {
        bodyContainer.subviews.forEach { $0.removeFromSuperview() }
        let content: NSView
        switch request.body.kind {
        case .none:
            content = bodyNone
        case .raw:
            content = rawBodyEditor()
        case .form, .urlencoded:
            content = bodyFieldsTable
        case .multipart:
            content = bodyFilesBox
        }
        content.frame = bodyContainer.bounds
        content.autoresizingMask = [.width, .height]
        bodyContainer.addSubview(content)
        bodyFieldsTable.reload()
        bodyFilesTable.reload()
    }

    /// The JSON or text editor for a raw body, built the first time it is shown, on a document of its own so the
    /// editor's JSON grammar colours and folds it.
    private func rawBodyEditor() -> EditorView {
        if let bodyEditor, let bodyDocument {
            bodyDocument.url = APIRequestView.bodyURL(for: request.body.contentType)
            return bodyEditor
        }
        let document = TextDocument()
        document.url = APIRequestView.bodyURL(for: request.body.contentType)
        document.replaceAll(with: request.body.text)
        let editor = EditorView(document: document)
        editor.onTextChange = { [weak self, weak document] in
            guard let self, let document else { return }
            self.request.body.text = document.text
            self.markDirty()
        }
        bodyDocument = document
        bodyEditor = editor
        return editor
    }

    private static func bodyURL(for contentType: String) -> URL {
        let ext = contentType.contains("json") ? "json" : (contentType.contains("xml") ? "xml" : "txt")
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("feather-api-body.\(ext)")
    }

    private func colourMethod() {
        updateTabIcon()
        let colour = APIFormat.methodColor(request.method, theme: theme)
        for item in methodPopup.itemArray {
            let method = APIMethod(rawValue: item.title) ?? .get
            item.attributedTitle = NSAttributedString(string: item.title, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: APIFormat.methodColor(method, theme: theme),
            ])
        }
        methodPopup.contentTintColor = colour
        methodPill.layer?.backgroundColor = colour.withAlphaComponent(0.16).cgColor
    }

    /// `{{variables}}` in the accent colour: temporary attributes on the field editor while typing (they never
    /// disturb the caret), the attributed value otherwise.
    private func colourURL() {
        let text = urlField.stringValue
        let ranges = APIFormat.variableRanges(in: text)
        if let editor = urlField.currentEditor() as? NSTextView, let layout = editor.layoutManager {
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: (text as NSString).length))
            for range in ranges { layout.addTemporaryAttribute(.foregroundColor, value: theme.accent, forCharacterRange: range) }
            return
        }
        let attributed = NSMutableAttributedString(string: text, attributes: [.font: urlField.font ?? .systemFont(ofSize: 12), .foregroundColor: theme.foreground])
        for range in ranges { attributed.addAttribute(.foregroundColor, value: theme.accent, range: range) }
        urlField.attributedStringValue = attributed
    }

    // MARK: Edits

    func markDirty() {
        guard let document, !document.isDirty else { return }
        document.isDirty = true
    }

    /// The tab's title and dirty dot, after a save or a rename.
    private func syncDocument(dirty: Bool) {
        guard let document else { return }
        document.displayTitle = request.name
        if document.isDirty == dirty { document.isDirty = !dirty }        // a change either way redraws the tab
        document.isDirty = dirty
    }

    @objc private func methodChanged() {
        guard let method = methodPopup.selectedItem.flatMap({ APIMethod(rawValue: $0.title) }) else { return }
        request.method = method
        colourMethod()
        markDirty()
    }

    @objc private func bodyKindChanged() {
        let choice = APIRequestView.bodyKinds[max(0, bodyKindPopup.indexOfSelectedItem)]
        if request.body.kind == .raw, choice.kind == .raw, let bodyDocument { request.body.text = bodyDocument.text }
        request.body.kind = choice.kind
        if let contentType = choice.contentType { request.body.contentType = contentType }
        showBodyKind()
        updateSectionLabels()
        markDirty()
    }

    @objc private func authKindChanged() {
        request.auth.kind = APIRequestView.authKinds[max(0, authKindPopup.indexOfSelectedItem)].kind
        layoutAuthRows()
        updateSectionLabels()
        markDirty()
    }

    @objc private func authPlaceChanged() {
        request.auth.keyIn = authPlace.indexOfSelectedItem == 0 ? .header : .query
        markDirty()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === urlField {
            let (base, params) = APIFormat.params(afterEditingURL: urlField.stringValue, previous: request.params)
            request.url = base
            request.params = params
            paramsTable.reload()
            updateSectionLabels()
            colourURL()
            markDirty()
        } else if let id = field.identifier?.rawValue {
            switch id {
            case "token": request.auth.token = field.stringValue
            case "username": request.auth.username = field.stringValue
            case "password": request.auth.password = field.stringValue
            case "keyName": request.auth.keyName = field.stringValue
            case "keyValue": request.auth.keyValue = field.stringValue
            default: return
            }
            markDirty()
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as AnyObject? === urlField { colourURL() }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        if notification.object as AnyObject? === urlField { colourURL() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)), sender.isSending { cancel(); return true }
        return false
    }

    private func updateURLFromParams() {
        urlField.stringValue = APIFormat.joinQuery(base: request.url, params: request.params)
        colourURL()
        updateSectionLabels()
    }

    /// The address of a history entry, put back in the field.
    func setURL(_ url: String) {
        urlField.stringValue = url
        let (base, params) = APIFormat.params(afterEditingURL: url, previous: request.params)
        request.url = base
        request.params = params
        paramsTable.reload()
        colourURL()
        updateSectionLabels()
        markDirty()
    }

    func noteRenamed(_ name: String) {
        request.name = name
        syncDocument(dirty: isDirty)
    }

    /// The request was moved to another collection in the tree, or its collection lost it (nil).
    func noteMoved(toCollection id: String?) {
        collectionID = id
        saveButton.title = id == nil ? "Save…" : "Save"
        if id == nil { markDirty() }
    }

    // MARK: Sending

    @objc private func sendClicked() { send() }

    func send() {
        guard let controller else { return }
        if sender.isSending { return }
        window?.makeFirstResponder(urlField)                 // commits whatever table box was being typed in
        if let bodyDocument, request.body.kind == .raw { request.body.text = bodyDocument.text }
        let collection = collectionID.flatMap { controller.workspace.collection(id: $0) }
        let folders = collection?.allRequests.first { $0.request.id == request.id }?.path ?? []
        response.showSending()
        sendButton.isEnabled = false
        controller.send(request, in: collection, folders: folders, sender: sender) { [weak self] result, checks in
            guard let self else { return }
            self.sendButton.isEnabled = true
            self.response.show(result, checks: checks)
        }
    }

    func cancel() {
        guard sender.isSending else { return }
        sender.cancel()
        sendButton.isEnabled = true
        response.showCancelled()
    }

    override func cancelOperation(_ sender: Any?) {
        if self.sender.isSending { cancel() } else { super.cancelOperation(sender) }
    }

    // MARK: Saving

    @objc private func saveClicked() { save() }

    @objc private func cookiesClicked() {
        guard let controller else { return }
        APICookiesSheet.present(in: controller)
    }

    /// The request as a `curl` command, with the variables filled in, on the clipboard.
    @objc private func copyCurlClicked() {
        guard let controller else { return }
        if let bodyDocument, request.body.kind == .raw { request.body.text = bodyDocument.text }
        let collection = collectionID.flatMap { controller.workspace.collection(id: $0) }
        let variables = controller.workspace.variables(for: collection, environment: controller.selectedEnvironment)
        let command = CurlFormat.command(for: request, variables: variables, projectRoot: controller.workspace.projectRoot)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        controller.notice("Copied as cURL")
    }

    /// ⌘S reaches here first: the tab is below the window in the responder chain.
    @objc func saveDocument(_ sender: Any?) { save() }

    /// Closing a dirty tab with Save: saved in place when the request has a collection; otherwise the
    /// "where to save" sheet cannot run under the close alert, so the draft is kept and the tab may close.
    func saveForClosing() -> Bool {
        if collectionID != nil { save(); return !isDirty }
        return true
    }

    func save() {
        guard let controller else { return }
        window?.makeFirstResponder(urlField)
        if let bodyDocument, request.body.kind == .raw { request.body.text = bodyDocument.text }
        if let collectionID, var collection = controller.workspace.collection(id: collectionID) {
            if !collection.update(request) { collection.insert(.request(request), into: nil) }
            controller.workspace.save(collection)
            pane?.drafts[request.id] = nil
            syncDocument(dirty: false)
            saveButton.title = "Save"
            return
        }
        askWhereToSave()
    }

    private func askWhereToSave() {
        guard let controller, let window else { return }
        let workspace = controller.workspace
        let alert = NSAlert()
        alert.messageText = "Save the request in a collection"
        alert.informativeText = "Collections are saved in the project, so the team shares them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        name.stringValue = request.name
        name.placeholderString = "Request name"
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 24), pullsDown: false)
        for stored in workspace.collections {
            picker.addItem(withTitle: stored.value.name)
            picker.lastItem?.representedObject = stored.value.id
        }
        picker.addItem(withTitle: "New collection…")
        let newName = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        newName.placeholderString = "Name of the new collection"
        let stack = NSStackView(views: [name, picker, newName])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 88)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let title = name.stringValue.trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { self.request.name = title }
            var collection: APICollection
            if let id = picker.selectedItem?.representedObject as? String, let existing = workspace.collection(id: id) {
                collection = existing
            } else {
                let made = newName.stringValue.trimmingCharacters(in: .whitespaces)
                collection = APICollection(name: made.isEmpty ? "New Collection" : made)
            }
            collection.insert(.request(self.request), into: nil)
            workspace.save(collection)
            self.collectionID = collection.id
            self.pane?.drafts[self.request.id] = nil
            self.saveButton.title = "Save"
            self.syncDocument(dirty: false)
        }
    }

    // MARK: Layout and theme

    @objc func layoutClicked() {
        split.isVertical.toggle()
        UserDefaults.standard.set(split.isVertical, forKey: APIRequestView.layoutKey)
        split.adjustSubviews()
        split.setPosition((split.isVertical ? bounds.width : bounds.height) * 0.5, ofDividerAt: 0)
        updateLayoutButton()
    }

    private func updateLayoutButton() {
        moreButton.item(at: 3)?.title = split.isVertical ? "Show Answer Under the Request" : "Show Answer Beside the Request"
    }

    func render() {}

    /// The answer gets a fair share the first time the tab has a size; after that the divider is the person's.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard !didPlaceDivider, newSize.height > 400, newSize.width > 400 else { return }
        didPlaceDivider = true
        split.layoutSubtreeIfNeeded()
        split.setPosition((split.isVertical ? newSize.width : newSize.height) * 0.5, ofDividerAt: 0)
    }

    func applyTheme() {
        layer?.backgroundColor = theme.background.cgColor
        requestPart.wantsLayer = true
        requestPart.layer?.backgroundColor = theme.background.cgColor
        bodyNone.textColor = theme.lineNumber
        authHint.textColor = theme.lineNumber
        colourMethod()
        colourURL()
        sections.applyTheme()
        updateEnvironmentChip()
        for table in [paramsTable, headersTable, checksTable, capturesTable, bodyFieldsTable, bodyFilesTable] { table?.applyTheme() }
        bodyEditor?.applySettings()
        response.applyTheme()
        layoutAuthRows()
    }

    /// The tab was closed with edits in it: keep them, so opening the request again shows them.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil, let document, document.useCount <= 0, document.isDirty else { return }
        pane?.drafts[request.id] = (request, collectionID)
    }
}
