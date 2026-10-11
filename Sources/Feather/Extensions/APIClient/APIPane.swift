import AppKit

/// One row of the API pane's tree. Instances are kept between rebuilds (by `key`), so the outline view keeps
/// what is expanded when the workspace changes underneath it.
final class APINode: NSObject {
    enum Kind {
        case collectionsHeader, historyHeader
        case collection(String)
        case folder(collection: String, id: String)
        case request(collection: String, id: String)
        /// A day in the history: "Today", "Yesterday", a date; holds that day's entries.
        case historyDay(String)
        case history(String)
    }

    let kind: Kind
    let key: String
    var title = ""
    var method: APIMethod?
    var status: Int?
    var detail = ""
    var children: [APINode] = []

    init(kind: Kind, key: String) {
        self.kind = kind
        self.key = key
    }

    var isHeader: Bool {
        switch kind {
        case .collectionsHeader, .historyHeader: return true
        default: return false
        }
    }
    var collectionID: String? {
        switch kind {
        case .collection(let id), .folder(let id, _), .request(let id, _): return id
        default: return nil
        }
    }
    var itemID: String? {
        switch kind {
        case .folder(_, let id), .request(_, let id): return id
        default: return nil
        }
    }
    /// The folder items are added to when this node is the target: the folder itself, or nil for a collection's top.
    var folderID: String? {
        if case .folder(_, let id) = kind { return id }
        return nil
    }
    var canHoldItems: Bool {
        switch kind {
        case .collection, .folder: return true
        default: return false
        }
    }
}

/// The API pane: the environment picker, a search box, the collections as a tree with the method of each request
/// in colour, and the recent history. Right-click for the rest. Loads the workspace the first time it is shown.
final class APIPaneViewController: NSViewController, ExtensionPane, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                   NSMenuDelegate, NSTextFieldDelegate, NSSearchFieldDelegate {
    private(set) weak var controller: APIClientController?
    private var isLoaded = false

    private let header = NSTextField(labelWithString: "API")
    private let headerButtons = NSStackView()
    private let environmentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let searchField = NSSearchField()
    private let outlineView = APIOutlineView()
    private let scrollView = NSScrollView()
    private let emptyView = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: "No collections yet")
    private let emptyHelp = NSTextField(wrappingLabelWithString: "A collection keeps related requests together and is saved with the project, so the team shares it.")
    private let newCollectionButton = NSButton(title: "New Collection", target: nil, action: nil)

    /// New ▾: request, collection, folder, environment, import, paste cURL.
    private let newButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let moreButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let actionRow = NSStackView()
    private let collectionsNode = APINode(kind: .collectionsHeader, key: "collections")
    private let historyNode = APINode(kind: .historyHeader, key: "history")
    private var nodes: [String: APINode] = [:]
    private var filter = ""
    /// The row being renamed in place, when one is.
    private var renaming: (node: APINode, field: NSTextField, cancelled: Bool)?
    private static let dragType = NSPasteboard.PasteboardType("com.aagicorp.feather.api-item")
    private static let historyShown = 50

    /// Unsaved edits of request tabs that were closed, so nothing typed is lost; keyed by request id.
    var drafts: [String: (request: APIRequest, collectionID: String?)] = [:]

    init(controller: APIClientController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: View

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 500))
        view.wantsLayer = true

        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.lineBreakMode = .byTruncatingTail
        let actions: [(String, String, Selector)] = [
            ("doc.badge.plus", "New Request (in the selected collection)", #selector(newRequestClicked)),
            ("folder.badge.plus", "New Collection…", #selector(newCollectionClicked)),
            ("square.and.arrow.down", "Import Postman, OpenAPI, .http or cURL files…", #selector(importClicked)),
        ]
        for (symbol, tip, action) in actions {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)) ?? NSImage()
            let button = NSButton(image: image, target: self, action: action)
            button.isBordered = false
            button.toolTip = tip
            button.widthAnchor.constraint(equalToConstant: 20).isActive = true
            headerButtons.addArrangedSubview(button)
        }
        headerButtons.spacing = 2
        headerButtons.setContentCompressionResistancePriority(.required, for: .horizontal)
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        environmentPopup.controlSize = .small
        environmentPopup.font = .systemFont(ofSize: 11)
        environmentPopup.target = self
        environmentPopup.action = #selector(environmentChosen)
        environmentPopup.toolTip = "The environment whose variables fill in {{names}} when a request is sent"

        // One row: the environment, New ▾ for everything that is made here, and the rest under ⋯. The header's
        // small icons stay for people who know them.
        newButton.bezelStyle = .rounded
        newButton.controlSize = .small
        newButton.pullsDown = true
        newButton.addItem(withTitle: "")
        newButton.item(at: 0)?.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New")
        newButton.toolTip = "New: a request (⌥⇧⌘N), collection, folder or environment; import; paste a cURL command"
        newButton.widthAnchor.constraint(equalToConstant: 44).isActive = true     // icon only, so the environment keeps its room
        for (title, action) in [("New Request", #selector(newRequestClicked)), ("New Collection…", #selector(newCollectionClicked)),
                                ("New Folder", #selector(newFolderClicked)), ("New Environment…", #selector(newEnvironmentClicked)),
                                ("Import Postman, OpenAPI, .http or cURL…", #selector(importClicked)), ("Paste cURL Command", #selector(pasteCurlClicked)),
                                ("Generate Requests from OpenAPI…", #selector(generateFromOpenAPIClicked))] as [(String, Selector)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            newButton.menu?.addItem(item)
        }
        moreButton.bezelStyle = .rounded
        moreButton.controlSize = .small
        moreButton.pullsDown = true
        moreButton.addItem(withTitle: "")
        moreButton.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")
        moreButton.toolTip = "Export a collection; cookies"
        for (title, action) in [("Export Collection…", #selector(exportClicked)), ("Cookies…", #selector(cookiesClicked))] as [(String, Selector)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            moreButton.menu?.addItem(item)
        }
        actionRow.orientation = .horizontal
        actionRow.spacing = 6
        actionRow.addArrangedSubview(environmentPopup)
        actionRow.addArrangedSubview(newButton)
        actionRow.addArrangedSubview(moreButton)
        environmentPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        environmentPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        newButton.setContentHuggingPriority(.required, for: .horizontal)
        moreButton.widthAnchor.constraint(equalToConstant: 36).isActive = true

        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.placeholderString = "Filter by name or address"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 12
        outlineView.style = .plain
        outlineView.backgroundColor = .clear
        outlineView.floatsGroupRows = false
        outlineView.autoresizesOutlineColumn = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        outlineView.onRename = { [weak self] in self?.renameSelected() }
        outlineView.onDelete = { [weak self] in self?.deleteSelected() }
        outlineView.registerForDraggedTypes([APIPaneViewController.dragType, .fileURL])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.useFeatherScrollers()

        emptyTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        emptyTitle.alignment = .center
        emptyHelp.font = .systemFont(ofSize: 11)
        emptyHelp.alignment = .center
        newCollectionButton.target = self
        newCollectionButton.action = #selector(newCollectionClicked)
        newCollectionButton.bezelStyle = .rounded
        newCollectionButton.controlSize = .small
        emptyView.orientation = .vertical
        emptyView.alignment = .centerX
        emptyView.spacing = 8
        emptyView.addArrangedSubview(emptyTitle)
        emptyView.addArrangedSubview(emptyHelp)
        emptyView.addArrangedSubview(newCollectionButton)
        emptyView.isHidden = true

        for subview in [header, headerButtons, actionRow, searchField, scrollView, emptyView] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 9),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(lessThanOrEqualTo: headerButtons.leadingAnchor, constant: -6),
            headerButtons.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            headerButtons.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            actionRow.topAnchor.constraint(equalTo: view.topAnchor, constant: TabBarView.height + 4),
            actionRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            actionRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            searchField.topAnchor.constraint(equalTo: actionRow.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 40),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(workspaceChanged(_:)), name: APIWorkspace.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(openRequested(_:)), name: APIClientExtension.openRequest, object: controller)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)), name: Settings.didChange, object: nil)
        applyTheme()
    }

    func applyTheme() {
        guard isViewLoaded else { return }
        let theme = Settings.shared.theme
        view.layer?.backgroundColor = Glass.paneBackground(theme.chrome)   // the sidebar's backdrop shows through with glass
        header.textColor = theme.lineNumber
        headerButtons.arrangedSubviews.forEach { ($0 as? NSButton)?.contentTintColor = theme.lineNumber }
        emptyTitle.textColor = theme.foreground
        emptyHelp.textColor = theme.lineNumber
        outlineView.reloadData()
    }

    @objc private func settingsChanged(_ notification: Notification) {
        if Settings.change(in: notification).contains(.theme) { applyTheme() }
    }

    // MARK: Loading

    var workspace: APIWorkspace? { controller?.workspace }

    func paneDidAppear() {
        guard let controller else { return }
        if !isLoaded {
            isLoaded = true
            let problems = controller.workspace.load()
            if !problems.isEmpty { controller.notice("Some API files could not be read: " + problems.joined(separator: "; ")) }
        }
        rebuild()
    }

    func workspaceDidChange() {
        isLoaded = false
        drafts = [:]
        if isViewLoaded, view.window != nil { paneDidAppear() }
    }

    /// Something outside the pane (the .http strip, a curl line in the terminal) wants a request in a tab.
    @objc private func openRequested(_ notification: Notification) {
        guard let controller, let request = notification.userInfo?["request"] as? APIRequest else { return }
        if !isLoaded { _ = view; isLoaded = true; controller.workspace.load() }
        let collectionID = notification.userInfo?["collectionID"] as? String
        if let collectionID, controller.workspace.collection(id: collectionID)?.request(id: request.id) != nil {
            openRequest(id: request.id, in: collectionID)
        } else {
            openRequestScratch(request)
        }
        if notification.userInfo?["send"] as? Bool == true { frontRequestView?.send() }
    }

    @objc private func workspaceChanged(_ notification: Notification) {
        guard isViewLoaded, notification.object as AnyObject? === workspace else { return }
        rebuild()
    }

    /// Rebuilds the tree from the workspace, reusing nodes so expansion survives.
    private func rebuild() {
        guard let workspace else { return }
        var seen: Set<String> = []
        func node(_ kind: APINode.Kind, _ key: String) -> APINode {
            seen.insert(key)
            if let existing = nodes[key] { return existing }
            let made = APINode(kind: kind, key: key)
            nodes[key] = made
            return made
        }
        let needle = filter.lowercased()
        func matches(_ text: String...) -> Bool { needle.isEmpty || text.contains { $0.lowercased().contains(needle) } }
        func build(_ items: [APIItem], in collectionID: String) -> [APINode] {
            items.compactMap { item in
                switch item {
                case .request(let request):
                    guard matches(request.name, request.url) else { return nil }
                    let row = node(.request(collection: collectionID, id: request.id), collectionID + "/" + request.id)
                    row.title = request.name
                    row.method = request.method
                    row.detail = request.url
                    return row
                case .folder(let folder):
                    let children = build(folder.items, in: collectionID)
                    guard matches(folder.name) || !children.isEmpty else { return nil }
                    let row = node(.folder(collection: collectionID, id: folder.id), collectionID + "/" + folder.id)
                    row.title = folder.name
                    row.children = children
                    return row
                }
            }
        }
        collectionsNode.children = workspace.collections.compactMap { stored in
            let children = build(stored.value.items, in: stored.value.id)
            guard matches(stored.value.name) || !children.isEmpty else { return nil }
            let row = node(.collection(stored.value.id), stored.value.id)
            row.title = stored.value.name
            row.detail = stored.location == .personal ? "Just for me" : ""
            row.children = children
            return row
        }
        // The history by day: Today, Yesterday, then dates; newest first inside each.
        var days: [APINode] = []
        for entry in workspace.history.prefix(APIPaneViewController.historyShown) where matches(entry.url) {
            let label = APIPaneViewController.dayLabel(for: entry.date)
            let day: APINode
            if let last = days.last, last.title == label {
                day = last
            } else {
                day = node(.historyDay(label), "history-day/" + label)
                day.title = label
                day.children = []
                days.append(day)
            }
            let row = node(.history(entry.id), "history/" + entry.id)
            row.method = entry.method
            row.status = entry.status
            row.title = APIPaneViewController.shortURL(entry.url)
            row.detail = entry.error ?? entry.url
            day.children.append(row)
        }
        historyNode.children = days
        nodes = nodes.filter { seen.contains($0.key) }
        outlineView.reloadData()
        outlineView.expandItem(collectionsNode)
        outlineView.expandItem(historyNode)
        historyNode.children.forEach { outlineView.expandItem($0) }
        if !needle.isEmpty { outlineView.expandItem(nil, expandChildren: true) }
        else if workspace.collections.count == 1, let only = collectionsNode.children.first, !expandedOnce.contains(only.key) {
            expandedOnce.insert(only.key)
            outlineView.expandItem(only)
        }
        let isEmpty = workspace.collections.isEmpty && workspace.history.isEmpty
        emptyView.isHidden = !isEmpty
        scrollView.isHidden = isEmpty
        openAPIOffer?.removeFromSuperview()
        openAPIOffer = nil
        if isEmpty, let offer = controller?.makeOpenAPIOffer() {
            emptyView.addArrangedSubview(offer)
            offer.widthAnchor.constraint(equalTo: emptyView.widthAnchor).isActive = true
            openAPIOffer = offer
        }
        rebuildEnvironments()
    }

    private var expandedOnce: Set<String> = []
    private var openAPIOffer: NSView?

    /// "/bookings?page=2" for the history: the host is the environment's business.
    static func shortURL(_ url: String) -> String {
        guard let components = URLComponents(string: url) else { return url }
        var text = components.path.isEmpty ? "/" : components.path
        if let query = components.query, !query.isEmpty { text += "?" + query }
        return text
    }

    private func rebuildEnvironments() {
        guard let workspace, let controller else { return }
        environmentPopup.removeAllItems()
        environmentPopup.addItem(withTitle: "No environment")
        if !workspace.environments.isEmpty {
            environmentPopup.menu?.addItem(.separator())
            for stored in workspace.environments {
                environmentPopup.addItem(withTitle: stored.value.name)
                environmentPopup.lastItem?.representedObject = stored.value.id
            }
        }
        environmentPopup.menu?.addItem(.separator())
        environmentPopup.addItem(withTitle: "Manage environments…")
        environmentPopup.lastItem?.tag = 1
        if let id = controller.selectedEnvironmentID, let index = environmentPopup.itemArray.firstIndex(where: { $0.representedObject as? String == id }) {
            environmentPopup.selectItem(at: index)
        } else {
            environmentPopup.selectItem(at: 0)
        }
    }

    @objc private func environmentChosen() {
        guard let controller, let item = environmentPopup.selectedItem else { return }
        if item.tag == 1 {
            rebuildEnvironments()                      // back to what it was while the sheet is up
            manageEnvironments()
            return
        }
        controller.selectedEnvironmentID = item.representedObject as? String
    }

    // MARK: Search

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as AnyObject? === searchField {
            filter = searchField.stringValue.trimmingCharacters(in: .whitespaces)
            rebuild()
        }
    }

    // MARK: Outline data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? APINode else { return 2 }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? APINode else { return index == 0 ? collectionsNode : historyNode }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? APINode else { return false }
        return node.isHeader || node.canHoldItems || node.kind.isHistoryDay
    }

    /// "Today", "Yesterday", then the date, for grouping the history.
    static func dayLabel(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = false
        return formatter.string(from: date)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? APINode)?.isHeader ?? false }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? APINode else { return false }
        return !node.isHeader && !node.kind.isHistoryDay
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { APITableRowView() }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? APINode else { return nil }
        let theme = Settings.shared.theme
        if node.isHeader {
            let isHistory = node.kind.isHistory
            let label = NSTextField(labelWithString: isHistory ? "HISTORY" : "COLLECTIONS")
            label.font = .systemFont(ofSize: 10.5, weight: .semibold)
            label.textColor = theme.lineNumber
            let cell = NSTableCellView()
            cell.textField = label
            // The action a section is for, at its right: a new collection, or clearing the history.
            let button = NSButton(image: NSImage(systemSymbolName: isHistory ? "trash" : "plus", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)) ?? NSImage(),
                                  target: self, action: isHistory ? #selector(clearHistoryClicked) : #selector(newCollectionClicked))
            button.isBordered = false
            button.contentTintColor = theme.lineNumber
            button.toolTip = isHistory ? "Clear the history" : "New Collection…"
            for subview in [label, button] as [NSView] {
                subview.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(subview)
            }
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                                         label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                         button.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                                         button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                         button.widthAnchor.constraint(equalToConstant: 18)])
            return cell
        }
        if node.kind.isHistoryDay {
            let label = NSTextField(labelWithString: node.title)
            label.font = .systemFont(ofSize: 10.5, weight: .medium)
            label.textColor = theme.lineNumber
            let cell = NSTableCellView()
            cell.textField = label
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                                         label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        let cell = (outlineView.makeView(withIdentifier: APIRowCell.identifier, owner: nil) as? APIRowCell) ?? APIRowCell()
        cell.show(node, theme: theme)
        // The row's actions show under the pointer: + on a collection or folder, duplicate and delete on an item.
        let hovered = (outlineView.rowView(atRow: outlineView.row(forItem: node), makeIfNecessary: false) as? APITableRowView)?.isHovered ?? false
        cell.setActions(add: node.kind.isCollection || node.kind.isFolder, edit: !node.kind.isHistory, shown: hovered)
        cell.onAdd = { [weak self, weak node] in
            guard let self, let node else { return }
            self.outlineView.selectRowIndexes(IndexSet(integer: self.outlineView.row(forItem: node)), byExtendingSelection: false)
            self.newRequest()
        }
        cell.onDuplicate = { [weak self, weak node] in if let node { self?.duplicate(node) } }
        cell.onDelete = { [weak self, weak node] in if let node { self?.delete(node) } }
        return cell
    }

    private var selectedNode: APINode? { outlineView.item(atRow: outlineView.selectedRow) as? APINode }
    private var clickedNode: APINode? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        return outlineView.item(atRow: row) as? APINode
    }

    @objc private func rowClicked() {
        guard let node = clickedNode else { return }
        switch node.kind {
        case .request(let collectionID, let id): openRequest(id: id, in: collectionID)
        case .history(let id): openHistory(id: id)
        default: break
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        guard let node = clickedNode else {
            add("New Collection…", #selector(newCollectionClicked))
            add("New Environment…", #selector(newEnvironmentClicked))
            add("Import…", #selector(importClicked))
            return
        }
        switch node.kind {
        case .collection:
            add("New Request", #selector(newRequestClicked))
            add("New Folder", #selector(newFolderClicked))
            menu.addItem(.separator())
            add("Rename", #selector(renameClicked))
            add("Duplicate", #selector(duplicateClicked))
            add("Variables…", #selector(variablesClicked))
            menu.addItem(.separator())
            add("Run Collection…", #selector(runClicked))
            add("Export…", #selector(exportClicked))
            menu.addItem(.separator())
            add("Move to Trash…", #selector(deleteClicked))
        case .folder:
            add("New Request", #selector(newRequestClicked))
            add("New Folder", #selector(newFolderClicked))
            menu.addItem(.separator())
            add("Rename", #selector(renameClicked))
            add("Duplicate", #selector(duplicateClicked))
            menu.addItem(.separator())
            add("Run Folder…", #selector(runClicked))
            menu.addItem(.separator())
            add("Delete…", #selector(deleteClicked))
        case .request:
            add("Open", #selector(openClicked))
            add("Rename", #selector(renameClicked))
            add("Duplicate", #selector(duplicateClicked))
            add("Copy as cURL", #selector(copyCurlClicked))
            menu.addItem(.separator())
            add("Delete…", #selector(deleteClicked))
        case .history:
            add("Open", #selector(openClicked))
            add("Copy Address", #selector(copyAddressClicked))
            menu.addItem(.separator())
            add("Clear History", #selector(clearHistoryClicked))
        default: break
        }
    }

    @objc private func openClicked() { rowClicked() }
    @objc private func renameClicked() { if let node = clickedNode { beginRename(node) } }
    @objc private func newRequestClicked() { newRequest() }

    /// More ▸ Paste cURL Command: the clipboard's `curl …` becomes a request in the selected collection, or a
    /// scratch request when none is selected.
    @objc private func pasteCurlClicked() {
        guard let text = NSPasteboard.general.string(forType: .string), let request = APIImportExport.importCurl(text) else {
            controller?.notice("The clipboard does not hold a curl command.")
            return
        }
        guard let workspace else { return }
        if let node = selectedNode, let collectionID = node.collectionID, var collection = workspace.collection(id: collectionID) {
            collection.insert(.request(request), into: node.folderID ?? (node.itemID.flatMap { collection.parentFolderID(of: $0) } ?? nil))
            workspace.save(collection)
            openRequest(id: request.id, in: collectionID)
            reveal(key: collectionID + "/" + request.id, thenRename: false)
        } else {
            openScratchRequest(request)
        }
    }

    @objc private func generateFromOpenAPIClicked() {
        guard let controller, let window = view.window else { return }
        let files = controller.openAPIFiles()
        if files.count == 1 { controller.generateFromOpenAPI(files[0]); return }
        let panel = NSOpenPanel()
        panel.message = "Choose an OpenAPI file (openapi.yaml, openapi.json, swagger.json)"
        panel.allowedContentTypes = [.json, .yaml]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            controller.generateFromOpenAPI(url)
        }
    }

    @objc private func cookiesClicked() {
        guard let controller else { return }
        APICookiesSheet.present(in: controller)
    }
    @objc private func newCollectionClicked() { newCollection() }
    @objc private func newEnvironmentClicked() { newEnvironment() }
    @objc private func importClicked() { importFiles() }
    @objc private func exportClicked() { exportSelectedCollection() }
    @objc private func runClicked() { runSelection() }
    @objc private func deleteClicked() { if let node = clickedNode { delete(node) } }
    @objc private func variablesClicked() {
        guard let node = clickedNode, let id = node.collectionID, let collection = workspace?.collection(id: id) else { return }
        editCollectionVariables(collection)
    }

    @objc private func newFolderClicked() {
        guard let node = clickedNode, let collectionID = node.collectionID, var collection = workspace?.collection(id: collectionID) else { return }
        let folder = APIFolder(name: "New Folder")
        collection.insert(.folder(folder), into: node.folderID)
        workspace?.save(collection)
        reveal(key: collectionID + "/" + folder.id, thenRename: true)
    }

    @objc private func duplicateClicked() {
        if let node = clickedNode { duplicate(node) }
    }

    private func duplicate(_ node: APINode) {
        guard let workspace else { return }
        switch node.kind {
        case .collection(let id):
            guard let original = workspace.collection(id: id), let stored = workspace.collections.first(where: { $0.value.id == id }) else { return }
            var copy = original
            copy.id = UUID().uuidString
            copy.name = original.name + " copy"
            copy.items = APIPaneViewController.withNewIDs(copy.items)
            copy.variables = workspace.variables(of: original)
            workspace.save(copy, location: stored.location)
        case .folder(let collectionID, let id), .request(let collectionID, let id):
            guard var collection = workspace.collection(id: collectionID), let item = collection.item(id: id) else { return }
            let parent = collection.parentFolderID(of: id) ?? nil
            let index = collection.index(of: id, in: parent) ?? 0
            var copy: APIItem
            switch item {
            case .request(var request):
                request.id = UUID().uuidString
                request.name += " copy"
                copy = .request(request)
            case .folder(var folder):
                folder.id = UUID().uuidString
                folder.name += " copy"
                folder.items = APIPaneViewController.withNewIDs(folder.items)
                copy = .folder(folder)
            }
            collection.insert(copy, into: parent, at: index + 1)
            workspace.save(collection)
            reveal(key: collectionID + "/" + copy.id, thenRename: false)
        default: break
        }
    }

    private static func withNewIDs(_ items: [APIItem]) -> [APIItem] {
        items.map { item in
            switch item {
            case .request(var request): request.id = UUID().uuidString; return .request(request)
            case .folder(var folder): folder.id = UUID().uuidString; folder.items = withNewIDs(folder.items); return .folder(folder)
            }
        }
    }

    @objc private func copyCurlClicked() {
        guard let node = clickedNode, case .request(let collectionID, let id) = node.kind, let controller,
              let collection = workspace?.collection(id: collectionID), let found = collection.allRequests.first(where: { $0.request.id == id }) else { return }
        let context = APIRequestSender.Context(variables: controller.workspace.variables(for: collection, environment: controller.selectedEnvironment),
                                               inheritedAuth: found.path.reversed().map(\.auth) + [collection.auth],
                                               environment: controller.selectedEnvironment, projectRoot: controller.workspace.projectRoot)
        do {
            let resolved = try APIRequestSender.resolve(found.request, context: context)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(resolved.curl, forType: .string)
            controller.notice("Copied as a curl command.")
        } catch {
            controller.notice(error.localizedDescription)
        }
    }

    @objc private func copyAddressClicked() {
        guard let node = clickedNode, case .history(let id) = node.kind, let entry = workspace?.history.first(where: { $0.id == id }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.url, forType: .string)
    }

    @objc private func clearHistoryClicked() { workspace?.clearHistory() }

    // MARK: Rename in place

    private func renameSelected() {
        endRename(commit: true)
        if let node = selectedNode, !node.isHeader, !node.kind.isHistory { beginRename(node) }
    }

    private func deleteSelected() {
        if let node = selectedNode, !node.isHeader, !node.kind.isHistory { delete(node) }
    }

    private func beginRename(_ node: APINode) {
        endRename(commit: true)
        let row = outlineView.row(forItem: node)
        guard row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? APIRowCell else { return }
        let theme = Settings.shared.theme
        let field = cell.nameField
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = true
        field.backgroundColor = theme.background
        field.textColor = theme.foreground
        field.focusRingType = .exterior
        field.delegate = self
        renaming = (node, field, false)
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)), renaming != nil else { return false }
        renaming?.cancelled = true
        view.window?.makeFirstResponder(outlineView)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let renaming, notification.object as AnyObject? === renaming.field else { return }
        endRename(commit: !renaming.cancelled)
    }

    private func endRename(commit: Bool) {
        guard let (node, field, _) = renaming else { return }
        renaming = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        field.delegate = nil
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.stringValue = node.title
        guard commit, !name.isEmpty, name != node.title, let workspace else { return }
        switch node.kind {
        case .collection(let id):
            guard var collection = workspace.collection(id: id) else { return }
            collection.name = name
            workspace.save(collection)
        case .folder(let collectionID, let id), .request(let collectionID, let id):
            guard var collection = workspace.collection(id: collectionID), let item = collection.item(id: id) else { return }
            switch item {
            case .request(var request): request.name = name; collection.update(request)
            case .folder(var folder): folder.name = name; collection.replace(folder)
            }
            workspace.save(collection)
            openRequestView(id: id)?.noteRenamed(name)
        default: break
        }
    }

    // MARK: Delete

    private func delete(_ node: APINode) {
        guard let workspace, let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch node.kind {
        case .collection:
            alert.messageText = "Move the collection “\(node.title)” to the Trash?"
            alert.informativeText = "Its file goes to the Trash, so it can be put back from there."
            alert.addButton(withTitle: "Move to Trash")
        case .folder:
            alert.messageText = "Delete the folder “\(node.title)” and everything in it?"
            alert.informativeText = "The collection is saved without it. If the collection is in git, an earlier version still has it."
            alert.addButton(withTitle: "Delete")
        default:
            alert.messageText = "Delete the request “\(node.title)”?"
            alert.informativeText = "The collection is saved without it. If the collection is in git, an earlier version still has it."
            alert.addButton(withTitle: "Delete")
        }
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            switch node.kind {
            case .collection(let id):
                if let stored = workspace.collections.first(where: { $0.value.id == id }) {
                    try? FileManager.default.trashItem(at: stored.url, resultingItemURL: nil)
                }
                workspace.delete(collectionID: id)
            case .folder(let collectionID, let id), .request(let collectionID, let id):
                guard var collection = workspace.collection(id: collectionID) else { return }
                collection.remove(id: id)
                workspace.save(collection)
                self.closeRequestTabs(for: id, in: collection)
            default: break
            }
        }
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? APINode, node.itemID != nil else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(node.key, forType: APIPaneViewController.dragType)
        return pasteboardItem
    }

    private func draggedNode(_ info: NSDraggingInfo) -> APINode? {
        guard let key = info.draggingPasteboard.string(forType: APIPaneViewController.dragType) else { return nil }
        return nodes[key]
    }

    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let files = droppedFiles(info)
        if !files.isEmpty {
            guard files.contains(where: APIImportExport.canImport(url:)) else { return [] }
            outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .copy
        }
        guard let dragged = draggedNode(info), let target = item as? APINode else { return [] }
        // Dropped onto a request: put it next to that request.
        if case .request = target.kind, let parent = outlineView.parent(forItem: target) as? APINode {
            let position = outlineView.childIndex(forItem: target)
            outlineView.setDropItem(parent, dropChildIndex: position + 1)
            return .move
        }
        guard target.canHoldItems else { return [] }
        // A folder cannot go into itself or anything below it.
        var ancestor: APINode? = target
        while let current = ancestor {
            if current === dragged { return [] }
            ancestor = outlineView.parent(forItem: current) as? APINode
        }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let files = droppedFiles(info)
        if !files.isEmpty { return importDropped(files) }
        guard let dragged = draggedNode(info), let target = item as? APINode, let workspace,
              let sourceCollectionID = dragged.collectionID, let targetCollectionID = target.collectionID, let itemID = dragged.itemID,
              var source = workspace.collection(id: sourceCollectionID), let moved = source.item(id: itemID) else { return false }
        let sourceParent = source.parentFolderID(of: itemID) ?? nil
        let sourceIndex = source.index(of: itemID, in: sourceParent) ?? 0
        source.remove(id: itemID)
        var position = index < 0 ? Int.max : index
        if sourceCollectionID == targetCollectionID {
            // Moving down inside the same folder: the rows above shifted up by one when the item left.
            if sourceParent == target.folderID, position > sourceIndex { position -= 1 }
            source.insert(moved, into: target.folderID, at: position)
            workspace.save(source)
        } else {
            guard var destination = workspace.collection(id: targetCollectionID) else { return false }
            destination.insert(moved, into: target.folderID, at: position)
            workspace.save(source)
            workspace.save(destination)
            openRequestView(id: itemID)?.noteMoved(toCollection: targetCollectionID)
        }
        reveal(key: targetCollectionID + "/" + itemID, thenRename: false)
        return true
    }

    /// Selects a row after the workspace has changed (and reloaded the tree), optionally starting a rename.
    private func reveal(key: String, thenRename: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let node = self.nodes[key] else { return }
            var ancestor = self.outlineView.parent(forItem: node) as? APINode
            var chain: [APINode] = []
            while let current = ancestor { chain.append(current); ancestor = self.outlineView.parent(forItem: current) as? APINode }
            chain.reversed().forEach { self.outlineView.expandItem($0) }
            let row = self.outlineView.row(forItem: node)
            guard row >= 0 else { return }
            self.outlineView.selectRowIndexes([row], byExtendingSelection: false)
            self.outlineView.scrollRowToVisible(row)
            if thenRename { self.beginRename(node) }
        }
    }

    // MARK: Entry points (the Requests menu and the Command Palette)

    /// A request in the selected collection or folder; with nothing selected, a scratch request in a tab.
    func newRequest() {
        guard let workspace else { return }
        let node = selectedNode ?? clickedNode
        if let node, let collectionID = node.collectionID, var collection = workspace.collection(id: collectionID) {
            let request = APIRequest(name: "New Request")
            let folderID = node.folderID ?? (node.itemID.flatMap { collection.parentFolderID(of: $0) } ?? nil)
            collection.insert(.request(request), into: folderID)
            workspace.save(collection)
            openRequest(id: request.id, in: collectionID)
            reveal(key: collectionID + "/" + request.id, thenRename: true)
        } else {
            openScratchRequest(APIRequest(name: "New Request"))
        }
    }

    /// Sends whatever request tab is in front.
    func sendCurrentRequest() {
        guard let view = frontRequestView else { NSSound.beep(); return }
        view.send()
    }

    func newCollection() {
        guard let window = view.window, let workspace else { return }
        let alert = NSAlert()
        alert.messageText = "New Collection"
        alert.informativeText = "A collection keeps related requests together."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        name.placeholderString = "Name"
        let location = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        location.addItem(withTitle: "In the project, shared through git")
        location.addItem(withTitle: "Just for me")
        if workspace.projectRoot == nil { location.selectItem(at: 1); location.isEnabled = false }
        let stack = NSStackView(views: [name, location])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        // Explicit widths, or the popup grows to its longest title and runs past the sheet's edge.
        for control in [name, location] as [NSView] {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 60)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let title = name.stringValue.trimmingCharacters(in: .whitespaces)
            let collection = APICollection(name: title.isEmpty ? "New Collection" : title)
            workspace.save(collection, location: location.indexOfSelectedItem == 1 ? .personal : .project)
            self?.reveal(key: collection.id, thenRename: false)
        }
    }

    func newEnvironment() {
        guard let controller else { return }
        APIEnvironmentSheet.present(in: controller, environment: APIEnvironment(name: "New Environment"), isNew: true) { [weak self] saved in
            guard let saved else { return }
            controller.selectedEnvironmentID = saved.id
            self?.rebuildEnvironments()
        }
    }

    private func manageEnvironments() {
        guard let controller else { return }
        let current = controller.selectedEnvironment ?? controller.workspace.environments.first?.value
        guard let current else { newEnvironment(); return }
        APIEnvironmentSheet.present(in: controller, environment: current, isNew: false) { [weak self] _ in self?.rebuildEnvironments() }
    }

    private func editCollectionVariables(_ collection: APICollection) {
        guard let controller else { return }
        APIEnvironmentSheet.present(in: controller, collection: collection)
    }

    /// Postman, OpenAPI, .http and cURL files, through the importers.
    func importFiles() {
        guard let workspace else { return }
        APIImportExport.present(importIn: view.window, workspace: workspace)
    }

    /// The selected collection as a Postman or .http file, secrets left out.
    func exportSelectedCollection() {
        guard let workspace else { return }
        let node = clickedNode ?? selectedNode
        guard let id = node?.collectionID ?? (workspace.collections.count == 1 ? workspace.collections[0].value.id : nil),
              let collection = workspace.collection(id: id) else {
            controller?.notice("Select a collection to export.")
            return
        }
        APIImportExport.presentExport(collection, in: view.window)
    }

    /// Files dropped on the pane: anything the importers understand is added.
    private func importDropped(_ urls: [URL]) -> Bool {
        guard let workspace else { return false }
        let candidates = urls.filter(APIImportExport.canImport(url:))
        guard !candidates.isEmpty else { return false }
        var imported = APIImportExport.Imported()
        var failures: [String] = []
        for url in candidates {
            do { imported.merge(try APIImportExport.importFile(at: url)) }
            catch { failures.append(url.lastPathComponent + ": " + error.localizedDescription) }
        }
        APIImportExport.add(imported, to: workspace)
        if !failures.isEmpty { controller?.notice("Could not import " + failures.joined(separator: "; ")) }
        else { controller?.notice("Imported " + imported.summary + (imported.notes.isEmpty ? "." : ". " + imported.notes.joined(separator: " "))) }
        return true
    }

    /// Runs the selected collection or folder in a results tab.
    func runSelection() {
        guard let controller, let workspace else { return }
        let node = clickedNode ?? selectedNode
        var collectionID = node?.collectionID
        if collectionID == nil, workspace.collections.count == 1 { collectionID = workspace.collections[0].value.id }
        guard let collectionID, let collection = workspace.collection(id: collectionID) else {
            controller.notice("Select a collection or folder to run.")
            return
        }
        let folderID: String? = node.flatMap { $0.folderID ?? $0.itemID.flatMap { collection.parentFolderID(of: $0) ?? nil } }
        openRun(collection: collection, folderID: folderID)
    }

    // MARK: Opening tabs

    private var editorArea: EditorAreaViewController? { controller?.window?.editorArea }

    /// The request tab in front, when the front tab is one.
    var frontRequestView: APIRequestView? { editorArea?.currentTab?.preview as? APIRequestView }

    private func openRequestView(id: String) -> APIRequestView? {
        guard let editorArea else { return nil }
        return editorArea.tabs.lazy.compactMap { $0.preview as? APIRequestView }.first { $0.request.id == id }
    }

    /// What the tab's path bar reads: the collection and the request, not an id. Made unique among the open
    /// tabs, since two requests may share a name.
    private func tabKey(_ request: APIRequest, collectionID: String?) -> URL {
        let root = (workspace?.projectRoot ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent("⟨api⟩ " + (collectionID.flatMap { workspace?.collection(id: $0)?.name } ?? "Unsaved requests"))
        var candidate = root.appendingPathComponent(request.name)
        var counter = 2
        while editorArea?.tabs.contains(where: { $0.url == candidate }) == true {
            candidate = root.appendingPathComponent("\(request.name) (\(counter))")
            counter += 1
        }
        return candidate
    }

    private func selectTab(of view: APIRequestView) {
        guard let editorArea, let index = editorArea.tabs.firstIndex(where: { $0.preview === view }) else { return }
        editorArea.select(index)
    }

    func openRequest(id: String, in collectionID: String?, urlOverride: String? = nil) {
        guard let controller, let editorArea else { return }
        if let open = openRequestView(id: id) {
            selectTab(of: open)
            if let urlOverride { open.setURL(urlOverride) }
            return
        }
        var request: APIRequest?
        var owner = collectionID
        if let draft = drafts[id] {
            request = draft.request
            owner = draft.collectionID
        } else if let collectionID, let collection = controller.workspace.collection(id: collectionID) {
            request = collection.request(id: id)
        }
        guard let request else { NSSound.beep(); return }
        let view = APIRequestView(request: request, collectionID: owner, controller: controller, pane: self)
        guard let document = controller.window?.store.openVirtual(tabKey(request, collectionID: owner), title: request.name) else { return }
        view.document = document
        editorArea.addViewTab(for: document, preview: view)
        if drafts[id] != nil { view.markDirty() }
        if let urlOverride { view.setURL(urlOverride) }
    }

    func openScratchRequest(_ request: APIRequest) {
        openRequestScratch(request)
    }

    private func openRequestScratch(_ request: APIRequest) {
        guard let controller, let editorArea else { return }
        if let open = openRequestView(id: request.id) { selectTab(of: open); return }
        let view = APIRequestView(request: request, collectionID: nil, controller: controller, pane: self)
        guard let document = controller.window?.store.openVirtual(tabKey(request, collectionID: nil), title: request.name) else { return }
        view.document = document
        editorArea.addViewTab(for: document, preview: view)
    }

    private func openHistory(id: String) {
        guard let workspace, let entry = workspace.history.first(where: { $0.id == id }) else { return }
        if let requestID = entry.requestID, let collectionID = entry.collectionID, workspace.collection(id: collectionID)?.request(id: requestID) != nil {
            openRequest(id: requestID, in: collectionID, urlOverride: entry.url)
        } else if let requestID = entry.requestID, let open = openRequestView(id: requestID) {
            selectTab(of: open)
            open.setURL(entry.url)
        } else {
            var request = APIRequest(name: APIPaneViewController.shortURL(entry.url), method: entry.method, url: entry.url)
            request.id = entry.requestID ?? request.id
            openRequestScratch(request)
        }
    }

    func openRun(collection: APICollection, folderID: String?) {
        guard let controller, let editorArea else { return }
        let folderName = folderID.flatMap { collection.folder(id: $0)?.name }
        let title = "Run: " + (folderName ?? collection.name)
        let key = (workspace?.projectRoot ?? URL(fileURLWithPath: NSHomeDirectory())).appendingPathComponent("⟨api⟩ " + collection.name)
            .appendingPathComponent("Run " + (folderName ?? "everything"))
        if let index = editorArea.tabs.firstIndex(where: { $0.url == key }) {
            editorArea.select(index)
            (editorArea.tabs[index].preview as? APIRunView)?.start(collection: collection, folderID: folderID)
            return
        }
        let view = APIRunView(controller: controller, pane: self)
        guard let document = controller.window?.store.openVirtual(key, title: title) else { return }
        editorArea.addViewTab(for: document, preview: view)
        view.start(collection: collection, folderID: folderID)
    }

    /// Tabs of requests that were just deleted (directly or with their folder) lose their collection: they stay
    /// open as scratch requests, so nothing on screen vanishes.
    private func closeRequestTabs(for itemID: String, in collection: APICollection) {
        guard let editorArea else { return }
        for view in editorArea.tabs.compactMap({ $0.preview as? APIRequestView }) where view.collectionID == collection.id && collection.request(id: view.request.id) == nil {
            view.noteMoved(toCollection: nil)
        }
    }
}

private extension APINode.Kind {
    var isHistory: Bool {
        switch self {
        case .history, .historyHeader, .historyDay: return true
        default: return false
        }
    }
    var isHistoryDay: Bool { if case .historyDay = self { return true } else { return false } }
    var isCollection: Bool { if case .collection = self { return true } else { return false } }
    var isFolder: Bool { if case .folder = self { return true } else { return false } }
}

/// The tree with the keys a list is expected to answer: Return or F2 renames, ⌘⌫ deletes.
final class APIOutlineView: NSOutlineView {
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?
    private var hoveredRow = -1

    override func keyDown(with event: NSEvent) {
        let key = event.keyCode
        if key == 36 || key == 76 || key == 120 { onRename?(); return }          // Return, Enter, F2
        if key == 51, event.modifierFlags.contains(.command) { onDelete?(); return }
        super.keyDown(with: event)
    }

    // One hovered row for the whole tree, so a row's actions show only under the pointer and never stick.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { setHovered(row(at: convert(event.locationInWindow, from: nil))) }
    override func mouseEntered(with event: NSEvent) { setHovered(row(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { setHovered(-1) }

    func setHovered(_ row: Int) {
        guard row != hoveredRow else { return }
        func rowView(_ row: Int) -> APITableRowView? {
            guard row >= 0, row < numberOfRows else { return nil }
            return self.rowView(atRow: row, makeIfNecessary: false) as? APITableRowView
        }
        rowView(hoveredRow)?.isHovered = false
        hoveredRow = row
        rowView(row)?.isHovered = true
    }
}

/// A row: the method in colour (or an icon for collections and folders), the name, and for history the status.
final class APIRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("api-row")
    let badge = NSTextField(labelWithString: "")
    let icon = NSImageView()
    let nameField = NSTextField(labelWithString: "")
    let trailing = NSTextField(labelWithString: "")
    /// "+" on a collection or folder row: a new request inside it.
    let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New request here")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)) ?? NSImage(), target: nil, action: nil)
    /// Duplicate and delete, on a request, folder or collection row, under the pointer.
    let duplicateButton = NSButton(image: NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: "Duplicate")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)) ?? NSImage(), target: nil, action: nil)
    let deleteButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Delete")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)) ?? NSImage(), target: nil, action: nil)
    private let actions = NSStackView()
    var onAdd: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onDelete: (() -> Void)?
    private var iconWidth: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = APIRowCell.identifier
        for (button, tip, action) in [(addButton, "New request in here", #selector(addClicked)), (duplicateButton, "Duplicate", #selector(duplicateClicked)),
                                      (deleteButton, "Delete…", #selector(deleteClicked))] {
            button.isBordered = false
            button.toolTip = tip
            button.widthAnchor.constraint(equalToConstant: 18).isActive = true
            button.target = self
            button.action = action
        }
        actions.orientation = .horizontal
        actions.spacing = 0
        actions.identifier = APITableRowView.actionsIdentifier
        actions.isHidden = true
        actions.addArrangedSubview(addButton)
        actions.addArrangedSubview(duplicateButton)
        actions.addArrangedSubview(deleteButton)
        badge.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        badge.alignment = .left
        badge.widthAnchor.constraint(equalToConstant: 34).isActive = true
        badge.isHidden = true
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        icon.imageScaling = .scaleNone
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 16)
        iconWidth.isActive = true
        nameField.font = .systemFont(ofSize: 12)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailing.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        textField = nameField
        let stack = NSStackView(views: [icon, badge, nameField, trailing, actions])
        stack.spacing = 5
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Which actions this row has, and whether they show right now (the pointer is over the row).
    func setActions(add: Bool, edit: Bool, shown: Bool) {
        addButton.isHidden = !add
        duplicateButton.isHidden = !edit
        deleteButton.isHidden = !edit
        actions.isHidden = !shown || !(add || edit)
    }

    @objc private func addClicked() { onAdd?() }
    @objc private func duplicateClicked() { onDuplicate?() }
    @objc private func deleteClicked() { onDelete?() }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ node: APINode, theme: Theme) {
        nameField.stringValue = node.title
        nameField.textColor = theme.foreground
        nameField.toolTip = node.detail.isEmpty ? nil : node.detail
        trailing.stringValue = ""
        trailing.isHidden = true
        switch node.kind {
        case .collection:
            icon.isHidden = false
            badge.isHidden = true
            iconWidth.constant = 16
            icon.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "Collection")
            icon.contentTintColor = theme.lineNumber
            nameField.font = .systemFont(ofSize: 12, weight: .semibold)
            if !node.detail.isEmpty {
                trailing.stringValue = node.detail
                trailing.textColor = theme.lineNumber
                trailing.isHidden = false
            }
        case .folder:
            icon.isHidden = false
            badge.isHidden = true
            iconWidth.constant = 16
            icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
            icon.contentTintColor = theme.lineNumber
            nameField.font = .systemFont(ofSize: 12)
        case .request, .history:
            // The method on its pill, the same width for every method, so the names line up.
            icon.isHidden = false
            badge.isHidden = true
            nameField.font = .systemFont(ofSize: 12)
            if let method = node.method {
                let pill = APIFormat.methodBadge(method, theme: theme)
                icon.image = pill
                icon.contentTintColor = nil
                iconWidth.constant = pill.size.width
            }
            if case .history = node.kind {
                trailing.isHidden = false
                trailing.stringValue = node.status.map(String.init) ?? "—"
                trailing.textColor = APIFormat.statusColor(node.status, theme: theme)
                nameField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            }
        default:
            icon.isHidden = true
            badge.isHidden = true
        }
    }
}

// MARK: - Finding and moving items in a collection

extension APICollection {
    func item(id: String) -> APIItem? {
        func find(in items: [APIItem]) -> APIItem? {
            for item in items {
                if item.id == id { return item }
                if case .folder(let folder) = item, let found = find(in: folder.items) { return found }
            }
            return nil
        }
        return find(in: items)
    }

    func folder(id: String) -> APIFolder? {
        if case .folder(let folder) = item(id: id) { return folder }
        return nil
    }

    /// The folder holding the item: `.some(nil)` at the top level, nil when the item is not here.
    func parentFolderID(of id: String) -> String?? {
        func find(in items: [APIItem], parent: String?) -> String?? {
            for item in items {
                if item.id == id { return .some(parent) }
                if case .folder(let folder) = item, let found = find(in: folder.items, parent: folder.id) { return found }
            }
            return nil
        }
        return find(in: items, parent: nil)
    }

    func index(of id: String, in folderID: String?) -> Int? {
        let list = folderID.flatMap { folder(id: $0)?.items } ?? items
        return list.firstIndex { $0.id == id }
    }

    /// Adds an item at `index` in a folder (or the top level), clamped to the end.
    @discardableResult
    mutating func insert(_ item: APIItem, into folderID: String?, at index: Int) -> Bool {
        guard let folderID else { items.insert(item, at: min(index, items.count)); return true }
        func insert(into items: inout [APIItem]) -> Bool {
            for position in items.indices {
                if case .folder(var folder) = items[position] {
                    if folder.id == folderID {
                        folder.items.insert(item, at: min(index, folder.items.count))
                        items[position] = .folder(folder)
                        return true
                    }
                    if insert(into: &folder.items) { items[position] = .folder(folder); return true }
                }
            }
            return false
        }
        return insert(into: &items)
    }

    /// Replaces the folder with the same id (its items included).
    @discardableResult
    mutating func replace(_ folder: APIFolder) -> Bool {
        func replace(in items: inout [APIItem]) -> Bool {
            for position in items.indices {
                if case .folder(var existing) = items[position] {
                    if existing.id == folder.id { items[position] = .folder(folder); return true }
                    if replace(in: &existing.items) { items[position] = .folder(existing); return true }
                }
            }
            return false
        }
        return replace(in: &items)
    }
}

extension APIClientController {
    /// A small card in the window's corner, for what went wrong or what just happened.
    func notice(_ text: String) {
        guard let window = window?.window else { return }
        WindowNotices.show(NoticeCard(kind: "api-client", symbol: "paperplane", text: text, actions: [], dismissTitle: "OK"), in: window)
    }
}
