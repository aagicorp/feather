import AppKit

private final class ChangeGroup: NSObject {
    let title: String
    let isStaged: Bool
    var changes: [ChangeItem] = []

    init(title: String, isStaged: Bool) {
        self.title = title
        self.isStaged = isStaged
    }
}

private final class ChangeItem: NSObject {
    let change: GitFileChange
    init(_ change: GitFileChange) { self.change = change }
}

/// One repository in the workspace. A folder of microservices has several.
private final class RepositoryEntry {
    let url: URL
    let name: String
    var status: GitStatus?

    init(url: URL, name: String) {
        self.url = url
        self.name = name
    }
}

/// A row with a label on the left and small icon buttons on the right.
/// A row of the changes list, laid out as VS Code lays it out: the file's icon, its name, its folder dimmed after
/// it, the row's actions only under the pointer, and the status letter in its colour at the far right. A group
/// row ("Changes") carries its count on a pill instead of a letter.
final class ChangeRowView: NSTableCellView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let letter = NSTextField(labelWithString: "")
    let count = APIPill()
    private let buttons = NSStackView()
    private var actions: [() -> Void] = []
    var actionsHiddenForTests: Bool { buttons.isHidden }

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        // The name keeps its width; the folder after it is what gives way in a narrow sidebar, as in VS Code.
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        detail.lineBreakMode = .byTruncatingHead
        detail.usesSingleLineMode = true
        detail.font = .systemFont(ofSize: 11)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        letter.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        letter.alignment = .right
        letter.widthAnchor.constraint(equalToConstant: 14).isActive = true
        count.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        buttons.orientation = .horizontal
        buttons.spacing = 2
        buttons.identifier = APITableRowView.actionsIdentifier
        buttons.isHidden = true
        let stack = NSStackView(views: [icon, label, detail, buttons, count, letter])
        stack.spacing = 5
        stack.alignment = .centerY
        stack.setCustomSpacing(6, after: label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A group: "Changes" and how many, no icon or letter.
    func showGroup(title: String, count number: Int, theme: Theme) {
        icon.isHidden = true
        letter.isHidden = true
        detail.isHidden = true
        label.stringValue = title
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = theme.foreground
        count.isHidden = number == 0
        count.text = String(number)
        count.color = theme.accent
    }

    /// A changed file: icon, name, folder, letter.
    func showChange(_ change: GitFileChange, theme: Theme) {
        let path = change.path as NSString
        icon.isHidden = false
        icon.image = FileIcon.image(for: URL(fileURLWithPath: change.path), isDirectory: false)
        label.stringValue = path.lastPathComponent
        label.font = .systemFont(ofSize: 12)
        label.textColor = change.status == "D" ? theme.lineNumber : theme.foreground
        let folder = path.deletingLastPathComponent
        detail.isHidden = folder.isEmpty
        detail.stringValue = folder
        detail.textColor = theme.lineNumber
        count.isHidden = true
        letter.isHidden = false
        letter.stringValue = change.status == "!" ? "!" : String(change.status)
        letter.textColor = ChangeRowView.statusColor(change.status)
        toolTip = change.path + " · " + ChangeRowView.statusName(change.status)
    }

    static func statusColor(_ status: Character) -> NSColor {
        switch status {
        case "A", "U": return NSColor(hex: 0x3FB950)
        case "D": return NSColor(hex: 0xF14C4C)
        case "!": return NSColor(hex: 0xE5534B)
        case "R": return NSColor(hex: 0x56B6C2)
        default: return NSColor(hex: 0xE2C08D)
        }
    }

    static func statusName(_ status: Character) -> String {
        switch status {
        case "A": return "Added"
        case "U": return "Untracked"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "!": return "Conflict"
        default: return "Modified"
        }
    }

    private var shownSymbols: [String] = []

    func setButtons(_ items: [(symbol: String, toolTip: String, action: () -> Void)], tint: NSColor) {
        actions = items.map(\.action)
        // Rows are reconfigured on every reload; the buttons themselves rarely change, so they are reused.
        if items.map(\.symbol) == shownSymbols {
            for (button, item) in zip(buttons.arrangedSubviews.compactMap { $0 as? NSButton }, items) {
                button.toolTip = item.toolTip
                button.contentTintColor = tint
            }
            return
        }
        shownSymbols = items.map(\.symbol)
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, item) in items.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(clicked(_:)))
            button.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.toolTip)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
            if button.image == nil { button.title = String(item.toolTip.prefix(1)) }
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = tint
            button.toolTip = item.toolTip
            button.tag = index
            button.widthAnchor.constraint(equalToConstant: 18).isActive = true
            buttons.addArrangedSubview(button)
        }
    }

    @objc private func clicked(_ sender: NSButton) {
        if actions.indices.contains(sender.tag) { actions[sender.tag]() }
    }
}

/// The changes list: one hovered row for the whole list, so a row's actions show only under the pointer.
final class ChangesOutlineView: NSOutlineView {
    private var hoveredRow = -1

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

final class SourceControlViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate,
                                         NSTableViewDataSource, NSTableViewDelegate {
    var onOpenFile: ((URL) -> Void)?
    /// A click on a changed file: show what changed (repository root, the change).
    var onOpenDiff: ((URL, GitFileChange) -> Void)?
    /// Asks for the full graph window, optionally focused on a commit hash.
    var onShowGraph: ((String?) -> Void)?
    /// Called after any operation that may have changed files, branches or history.
    var onRepositoryChanged: (() -> Void)?

    /// The repository currently selected in the list; everything below the list acts on it.
    private(set) var repositoryRoot: URL?
    private var projectRoot: URL?
    private var repositories: [RepositoryEntry] = []
    private var discoveryGeneration = 0
    /// True while the list is being reloaded in code, so the resulting selection callbacks are not mistaken for clicks.
    private var isUpdatingRepositoryList = false
    private let repositoryTable = NSTableView()
    private let repositoryScroll = NSScrollView()
    private var repositoryListHeight: NSLayoutConstraint!
    private let lowerSplit = NSSplitView()
    private let graphView = CompactGraphView(frame: .zero)
    private let graphHeader = NSTextField(labelWithString: "GRAPH")
    private var graphSized = false
    private var status = GitStatus()
    /// The selected repository's remotes ("origin"); none means Publish has to make or connect one first.
    private var remotes: [String] = []
    /// What the big button does right now: VS Code's one button that is Commit, Publish Branch or Sync Changes.
    private(set) var primary = PrimaryAction.nothing
    var primaryTitleForTests: String { commitButton.title }
    var primaryImageForTests: NSImage? { commitButton.image }
    var messagePlaceholderForTests: String { messageField.placeholderString ?? "" }
    var remotesForTests: [String] { remotes }
    private let staged = ChangeGroup(title: "STAGED CHANGES", isStaged: true)
    private let unstaged = ChangeGroup(title: "CHANGES", isStaged: false)
    private var groups: [ChangeGroup] { [staged, unstaged].filter { !$0.changes.isEmpty } }
    private var isBusy = false

    private let branchButton = NSButton(title: "", target: nil, action: nil)
    private let toolStack = NSStackView()
    private let messageField = NSTextField()
    private let commitButton = NSButton(title: "Commit", target: nil, action: nil)
    private let info = NSTextField(wrappingLabelWithString: "")
    private let outlineView = ChangesOutlineView()
    var outlineViewForTests: NSOutlineView { outlineView }
    private let scrollView = NSScrollView()
    private let graphButton = NSButton(title: "Open Full Graph", target: nil, action: nil)
    private let emptyState = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    /// What the empty state says (the harness checks the no-git message).
    var emptyStateTextForTests: String { emptyLabel.stringValue }
    var isShowingEmptyStateForTests: Bool { !emptyState.isHidden }
    private let initButton = NSButton(title: "Initialize Repository", target: nil, action: nil)
    private var repositoryViews: [NSView] = []

    // MARK: - View

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))

        branchButton.bezelStyle = .recessed
        branchButton.controlSize = .small
        branchButton.target = self
        branchButton.action = #selector(showBranchMenu)
        branchButton.toolTip = "Switch, create or merge branches"
        branchButton.lineBreakMode = .byTruncatingMiddle
        branchButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        toolStack.orientation = .horizontal
        toolStack.spacing = 8
        for (symbol, tip, action) in [("arrow.down", "Pull", #selector(pull)), ("arrow.up", "Push", #selector(push)),
                                      ("arrow.triangle.2.circlepath", "Sync: pull, then push", #selector(sync)),
                                      ("arrow.clockwise", "Fetch and refresh", #selector(fetch))] {
            let button = NSButton(title: "", target: self, action: action)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            if button.image == nil { button.title = tip }
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = tip
            button.widthAnchor.constraint(equalToConstant: 18).isActive = true
            toolStack.addArrangedSubview(button)
        }

        messageField.placeholderString = "Message (⌘↩ to commit)"
        messageField.font = .systemFont(ofSize: 12)
        messageField.cell?.wraps = true
        messageField.cell?.isScrollable = false
        messageField.usesSingleLineMode = false
        messageField.lineBreakMode = .byWordWrapping
        messageField.delegate = self
        messageField.isBordered = false
        messageField.focusRingType = .none
        messageField.wantsLayer = true
        messageField.layer?.cornerRadius = 6
        messageField.layer?.borderWidth = 1

        commitButton.bezelStyle = .rounded
        commitButton.controlSize = .large
        commitButton.imagePosition = .imageLeading
        commitButton.keyEquivalentModifierMask = [.command]
        commitButton.target = self
        commitButton.action = #selector(primaryClicked)
        commitButton.bezelColor = NSColor(hex: 0x1F6FEB)

        info.font = .systemFont(ofSize: 11)
        info.isSelectable = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("change"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 6
        outlineView.style = .plain
        outlineView.backgroundColor = .clear
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        outlineView.doubleAction = #selector(rowDoubleClicked)
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        graphButton.bezelStyle = .recessed
        graphButton.controlSize = .small
        graphButton.target = self
        graphButton.action = #selector(showGraph)

        let repositoryColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("repository"))
        repositoryColumn.resizingMask = .autoresizingMask
        repositoryTable.addTableColumn(repositoryColumn)
        repositoryTable.headerView = nil
        repositoryTable.rowHeight = 24
        repositoryTable.style = .plain
        repositoryTable.backgroundColor = .clear
        repositoryTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        repositoryTable.dataSource = self
        repositoryTable.delegate = self
        repositoryTable.allowsEmptySelection = false
        repositoryScroll.documentView = repositoryTable
        repositoryScroll.hasVerticalScroller = true
        repositoryScroll.autohidesScrollers = true
        repositoryScroll.drawsBackground = false

        // Changes above, commit graph below, with a draggable divider between them.
        graphHeader.font = .systemFont(ofSize: 10.5, weight: .semibold)
        let graphSection = NSView()
        for view in [graphHeader, graphButton, graphView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            graphSection.addSubview(view)
        }
        NSLayoutConstraint.activate([
            graphHeader.topAnchor.constraint(equalTo: graphSection.topAnchor, constant: 7),
            graphHeader.leadingAnchor.constraint(equalTo: graphSection.leadingAnchor, constant: 12),
            graphButton.centerYAnchor.constraint(equalTo: graphHeader.centerYAnchor),
            graphButton.trailingAnchor.constraint(equalTo: graphSection.trailingAnchor, constant: -8),
            graphView.topAnchor.constraint(equalTo: graphHeader.bottomAnchor, constant: 6),
            graphView.leadingAnchor.constraint(equalTo: graphSection.leadingAnchor),
            graphView.trailingAnchor.constraint(equalTo: graphSection.trailingAnchor),
            graphView.bottomAnchor.constraint(equalTo: graphSection.bottomAnchor),
        ])
        graphView.onOpenCommit = { [weak self] in self?.onShowGraph?($0) }
        lowerSplit.isVertical = false
        lowerSplit.dividerStyle = .thin
        lowerSplit.addArrangedSubview(scrollView)
        lowerSplit.addArrangedSubview(graphSection)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.alignment = .center
        initButton.bezelStyle = .rounded
        initButton.target = self
        initButton.action = #selector(initializeRepository)
        emptyState.orientation = .vertical
        emptyState.spacing = 12
        emptyState.addArrangedSubview(emptyLabel)
        emptyState.addArrangedSubview(initButton)

        repositoryViews = [repositoryScroll, branchButton, toolStack, messageField, commitButton, info, lowerSplit]
        repositoryListHeight = repositoryScroll.heightAnchor.constraint(equalToConstant: 0)
        for subview in repositoryViews + [emptyState] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            repositoryScroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
            repositoryScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            repositoryScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            repositoryListHeight,
            branchButton.topAnchor.constraint(equalTo: repositoryScroll.bottomAnchor, constant: 6),
            branchButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            branchButton.trailingAnchor.constraint(lessThanOrEqualTo: toolStack.leadingAnchor, constant: -8),
            toolStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            toolStack.centerYAnchor.constraint(equalTo: branchButton.centerYAnchor),
            messageField.topAnchor.constraint(equalTo: branchButton.bottomAnchor, constant: 8),
            messageField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            messageField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            messageField.heightAnchor.constraint(equalToConstant: 52),
            commitButton.topAnchor.constraint(equalTo: messageField.bottomAnchor, constant: 6),
            commitButton.leadingAnchor.constraint(equalTo: messageField.leadingAnchor),
            commitButton.trailingAnchor.constraint(equalTo: messageField.trailingAnchor),
            info.topAnchor.constraint(equalTo: commitButton.bottomAnchor, constant: 6),
            info.leadingAnchor.constraint(equalTo: messageField.leadingAnchor, constant: 2),
            info.trailingAnchor.constraint(equalTo: messageField.trailingAnchor),
            lowerSplit.topAnchor.constraint(equalTo: info.bottomAnchor, constant: 4),
            lowerSplit.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            lowerSplit.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            lowerSplit.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyState.topAnchor.constraint(equalTo: view.topAnchor, constant: 40),
            emptyState.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -30),
        ])
        applyTheme()
        render()
    }

    func applyTheme() {
        guard isViewLoaded else { return }
        let theme = Settings.shared.theme
        info.textColor = theme.lineNumber
        emptyLabel.textColor = theme.lineNumber
        messageField.backgroundColor = theme.background
        messageField.textColor = theme.foreground
        messageField.layer?.borderColor = theme.border.cgColor
        toolStack.arrangedSubviews.forEach { ($0 as? NSButton)?.contentTintColor = theme.lineNumber }
        graphHeader.textColor = theme.lineNumber
        graphView.applyTheme()
        repositoryTable.reloadData()
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
    }

    func focusMessage() {
        _ = view
        if repositoryRoot != nil { view.window?.makeFirstResponder(messageField) }
    }

    // MARK: - State

    func setProjectRoot(_ url: URL?) {
        projectRoot = url
        repositoryRoot = nil
        repositories = []
        status = GitStatus()
        discover(preferring: nil)
    }

    /// Looks for repositories again (the opened folder itself, and any nested inside it), then refreshes them.
    /// `file` picks the repository that contains it, so the pane follows what you are editing.
    func discover(preferring file: URL?) {
        guard let projectRoot else { render(); return }
        discoveryGeneration += 1
        let generation = discoveryGeneration
        Git.discoverRepositories(under: projectRoot) { [weak self] urls in
            guard let self, self.discoveryGeneration == generation else { return }
            let rootPath = projectRoot.standardizedFileURL.path
            let known = Dictionary(uniqueKeysWithValues: self.repositories.map { ($0.url, $0) })
            self.repositories = urls.map { url in
                if let existing = known[url] { return existing }
                let path = url.standardizedFileURL.path
                let name = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : url.lastPathComponent
                return RepositoryEntry(url: url, name: name)
            }
            var selected = self.repositories.first { $0.url == self.repositoryRoot }
            if let file, selected == nil || !file.path.hasPrefix(selected!.url.path + "/") {
                // Deepest match wins, so a nested repository beats the one that contains it.
                selected = self.repositories.filter { file.path.hasPrefix($0.url.path + "/") }
                    .max { $0.url.path.count < $1.url.path.count } ?? selected
            }
            self.select(selected ?? self.repositories.first, reloadGraph: false)
            self.needsRefreshWhenShown = false
            self.refreshNow(only: nil, reloadGraph: true)
        }
    }

    private func select(_ entry: RepositoryEntry?, reloadGraph: Bool) {
        let changed = repositoryRoot != entry?.url
        repositoryRoot = entry?.url
        status = entry?.status ?? GitStatus()
        if isViewLoaded {
            isUpdatingRepositoryList = true
            repositoryTable.reloadData()
            if let entry, let row = repositories.firstIndex(where: { $0 === entry }) {
                repositoryTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            isUpdatingRepositoryList = false
            if changed { messageField.stringValue = "" }
            if changed || reloadGraph { graphView.load(root: repositoryRoot) }
            if changed, let entry { refreshNow(only: entry, reloadGraph: false) }
        }
        render()
    }

    /// True while the pane is actually on screen. Nothing else shows this data, so while it is hidden a refresh
    /// is only remembered, and done when the pane appears.
    private var isOnScreen: Bool { isViewLoaded && view.window != nil && !view.isHiddenOrHasHiddenAncestor }
    private var needsRefreshWhenShown = false
    private var refreshScheduled = false

    /// Re-reads the status of every repository, and the graph of the selected one. Several requests in quick
    /// succession (Save All, a burst of git actions) become one refresh.
    func refresh() {
        guard isOnScreen else { needsRefreshWhenShown = true; return }
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.refreshScheduled = false
            self?.refreshNow(only: nil, reloadGraph: true)
        }
    }

    /// A save can only change the status of the repository that owns the file, and cannot change history.
    func fileSaved(_ url: URL) {
        guard isOnScreen else { needsRefreshWhenShown = true; return }
        let owner = repositories.filter { url.path.hasPrefix($0.url.path + "/") }.max { $0.url.path.count < $1.url.path.count }
        if let owner { refreshNow(only: owner, reloadGraph: false) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if needsRefreshWhenShown { needsRefreshWhenShown = false; refresh() }
    }

    private func refreshNow(only: RepositoryEntry?, reloadGraph: Bool) {
        guard projectRoot != nil else { render(); return }
        if repositories.isEmpty { render() }
        for entry in repositories where only == nil || entry === only {
            // Every new file is listed for the repository being worked in; for the other rows a folder of new files
            // counting as one change is fine, and much cheaper for git to compute.
            Git.status(in: entry.url, allUntracked: entry.url == repositoryRoot) { [weak self, weak entry] status in
                guard let self, let entry, self.repositories.contains(where: { $0 === entry }) else { return }
                guard status != entry.status else { return }          // unchanged: nothing to redraw
                entry.status = status
                if let row = self.repositories.firstIndex(where: { $0 === entry }), self.isViewLoaded {
                    self.repositoryTable.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
                }
                if entry.url == self.repositoryRoot {
                    self.status = status ?? GitStatus()
                    self.render()
                }
            }
        }
        if let root = repositoryRoot, only == nil || only?.url == root {
            Git.run(["remote"], in: root) { [weak self] result in
                guard let self, self.repositoryRoot == root else { return }
                let names = result.ok ? result.output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : []
                if names != self.remotes {
                    self.remotes = names
                    self.render()
                }
            }
        }
        if reloadGraph, isViewLoaded, Git.isAvailable { graphView.load(root: repositoryRoot) }
    }

    private func render() {
        guard isViewLoaded else { return }
        // A `.git` folder is found without git; nothing in it can be read without git, so the pane says so instead.
        let hasRepository = repositoryRoot != nil && Git.isAvailable
        repositoryViews.forEach { $0.isHidden = !hasRepository }
        emptyState.isHidden = hasRepository
        // The list only earns its space when there is a choice to make.
        let rows = repositories.count > 1 ? min(repositories.count, 7) : 0
        repositoryListHeight.constant = CGFloat(rows) * (repositoryTable.rowHeight + repositoryTable.intercellSpacing.height)
        repositoryScroll.isHidden = rows == 0 || !hasRepository
        if hasRepository, !graphSized, lowerSplit.bounds.height > 200 {
            graphSized = true
            lowerSplit.setPosition(lowerSplit.bounds.height * 0.45, ofDividerAt: 0)
        }
        guard hasRepository else {
            if !Git.isAvailable {
                initButton.isHidden = false
                initButton.title = "Install Command Line Tools…"
                emptyLabel.stringValue = Git.notInstalledMessage
                return
            }
            initButton.title = "Initialize Repository"
            initButton.isHidden = projectRoot == nil
            emptyLabel.stringValue = projectRoot == nil ? "Open a folder to use source control."
                : "This folder does not keep a history of changes yet. “Initialize Repository” starts one (a Git repository)."
            return
        }

        var title = "⎇ " + (status.branch ?? "detached HEAD")
        if status.ahead > 0 { title += "  ↑\(status.ahead)" }
        if status.behind > 0 { title += "  ↓\(status.behind)" }
        branchButton.title = title

        staged.changes = status.staged.map(ChangeItem.init)
        unstaged.changes = status.unstaged.map(ChangeItem.init)
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)

        primary = SourceControlViewController.primaryAction(for: status)
        commitButton.title = primary.title
        commitButton.image = NSImage(systemSymbolName: primary.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        commitButton.isEnabled = !isBusy && primary.isEnabled
        commitButton.toolTip = primary.tip
        messageField.placeholderString = "Message (⌘↩ to commit" + (status.branch.map { " on “\($0)”" } ?? "") + ")"
        if !isBusy { info.stringValue = defaultInfo() }
    }

    private func defaultInfo() -> String {
        let conflicts = status.conflicts.count
        if conflicts > 0 {
            return "\(conflicts) file\(conflicts == 1 ? " has" : "s have") conflicts (marked !). Open each one: above every conflict the editor offers "
                + "Accept Current, Accept Incoming and Accept Both. Save, press + to mark it resolved, then "
                + (status.isRebasing ? "Continue Rebase." : "Commit Merge.")
        }
        if status.isRebasing { return "Rebase paused — Continue Rebase carries on with the next commit." }
        if status.isMerging { return "Merge in progress — Commit Merge finishes it." }
        if status.staged.isEmpty && status.unstaged.isEmpty {
            if status.branch != nil, status.upstream == nil, !status.isUnborn {
                return remotes.isEmpty ? "This repository is only on this Mac. Publish Branch puts it on GitHub, or on any remote address."
                    : "This branch is not on the remote yet. Publish Branch puts it there."
            }
            if status.ahead > 0 || status.behind > 0 {
                var parts: [String] = []
                if status.ahead > 0 { parts.append("\(status.ahead) commit\(status.ahead == 1 ? "" : "s") to push") }
                if status.behind > 0 { parts.append("\(status.behind) to pull") }
                return "Nothing to commit. " + parts.joined(separator: ", ") + "."
            }
            return "No changes."
        }
        if status.upstream == nil && status.branch != nil && !status.isUnborn { return "This branch is not on a remote yet — after committing, Publish Branch puts it there." }
        return ""
    }

    // MARK: - The one button

    /// VS Code's primary button: Commit while there is something to commit; otherwise Publish Branch for a branch
    /// that is not on a remote, or Sync Changes when commits wait to be pushed or pulled; and the merge and rebase
    /// states in between.
    enum PrimaryAction: Equatable {
        case commit(String)
        case commitMerge
        case continueRebase
        case resolveConflicts(Int)
        case publish
        case sync(ahead: Int, behind: Int)
        case nothing

        var title: String {
            switch self {
            case .commit(let title): return title
            case .commitMerge: return "Commit Merge"
            case .continueRebase: return "Continue Rebase"
            case .resolveConflicts(let count): return "Resolve \(count) Conflict\(count == 1 ? "" : "s") First"
            case .publish: return "Publish Branch"
            case .sync(let ahead, let behind):
                var title = "Sync Changes"
                if ahead > 0 { title += "  ↑\(ahead)" }
                if behind > 0 { title += "  ↓\(behind)" }
                return title
            case .nothing: return "Commit"
            }
        }

        var isEnabled: Bool {
            switch self {
            case .resolveConflicts, .nothing: return false
            default: return true
            }
        }

        /// The icon on the button, as VS Code puts one on its.
        var symbol: String {
            switch self {
            case .commit, .commitMerge, .nothing: return "checkmark"
            case .continueRebase: return "arrow.right.circle"
            case .resolveConflicts: return "exclamationmark.triangle"
            case .publish: return "icloud.and.arrow.up"
            case .sync: return "arrow.triangle.2.circlepath"
            }
        }

        var tip: String? {
            switch self {
            case .publish: return "Push this branch to a remote and keep it connected (git push -u)"
            case .sync: return "Pull, then push (what VS Code's Sync does)"
            case .continueRebase: return "git rebase --continue"
            default: return nil
            }
        }
    }

    static func primaryAction(for status: GitStatus) -> PrimaryAction {
        let conflicts = status.conflicts.count
        if conflicts > 0 { return .resolveConflicts(conflicts) }
        if status.isRebasing { return .continueRebase }
        if status.isMerging { return .commitMerge }
        if !status.staged.isEmpty || !status.unstaged.isEmpty { return .commit(status.staged.isEmpty ? "Commit All" : "Commit") }
        if status.branch != nil, status.upstream == nil, !status.isUnborn { return .publish }
        if status.ahead + status.behind > 0 { return .sync(ahead: status.ahead, behind: status.behind) }
        return .nothing
    }

    @objc private func primaryClicked() {
        switch primary {
        case .commit, .commitMerge: commit()
        case .continueRebase: continueRebase()
        case .publish: publish()
        case .sync: sync()
        case .resolveConflicts, .nothing: NSSound.beep()
        }
    }

    /// Why a network command failed, told apart so each gets the right answer instead of git's text.
    enum Failure: Equatable { case conflict, divergent, noUpstream, localChangesInTheWay, authentication, other }

    static func classify(_ result: GitResult) -> Failure {
        let text = result.output + "\n" + result.error
        // git 2.33 and later refuse a plain pull of branches that both moved until told whether to merge or rebase.
        if text.contains("Need to specify how to reconcile divergent branches") || text.contains("You have divergent branches") { return .divergent }
        if text.contains("CONFLICT") || text.contains("Automatic merge failed") || text.contains("fix conflicts") || text.contains("Resolve all conflicts") { return .conflict }
        if text.contains("no tracking information") || text.contains("has no upstream branch") || text.contains("no upstream configured") { return .noUpstream }
        if text.contains("would be overwritten by") || text.contains("Please commit your changes or stash them") { return .localChangesInTheWay }
        if text.contains("Authentication failed") || text.contains("could not read Username") || text.contains("could not read Password")
            || text.contains("Permission denied") || text.contains("terminal prompts disabled") { return .authentication }
        return .other
    }

    /// Where Publish pushes to: origin when there is one, else the only remote, else nothing yet.
    enum PublishPlan: Equatable { case push(remote: String), needsRemote }

    static func publishPlan(remotes: [String]) -> PublishPlan {
        if remotes.contains("origin") { return .push(remote: "origin") }
        if let first = remotes.first { return .push(remote: first) }
        return .needsRemote
    }

    /// The GitHub CLI, when it is installed: Homebrew's folders and the shell's PATH.
    static func gitHubCLI(pathDirectories: [String] = ShellEnvironment.shared.pathDirectories) -> URL? {
        for directory in pathDirectories + ["/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("gh")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// `gh repo create`: makes the repository, adds it as origin and pushes the current branch.
    static func gitHubCreateArguments(name: String, isPrivate: Bool, root: URL) -> [String] {
        ["repo", "create", name, isPrivate ? "--private" : "--public", "--source", root.path, "--remote", "origin", "--push"]
    }

    // MARK: - Running git

    private func run(_ commands: [[String]], busy message: String, network: Bool = false,
                     onFailure: ((GitResult) -> Void)? = nil, then: ((GitResult) -> Void)? = nil) {
        guard let root = repositoryRoot, !isBusy else { return }
        isBusy = true
        info.stringValue = message
        commitButton.isEnabled = false
        let finish: (GitResult) -> Void = { [weak self] result in
            guard let self else { return }
            self.isBusy = false
            if !result.ok {
                if let onFailure { onFailure(result) } else { self.showError(message.replacingOccurrences(of: "…", with: "") + " failed", result.message) }
            }
            then?(result)
            self.refresh()
            self.onRepositoryChanged?()
        }
        if network {
            // One after another on the network queue, stopping at the first failure: Sync's push never runs
            // over a pull that did not finish.
            func step(_ index: Int, after last: GitResult) {
                guard index < commands.count, last.ok else { finish(last); return }
                Git.run(commands[index], in: root, network: true) { step(index + 1, after: $0) }
            }
            step(0, after: GitResult(status: 0, output: "", error: ""))
        } else {
            Git.runAll(commands, in: root, completion: finish)
        }
    }

    /// Tests set this to read alerts instead of having them block on screen.
    var alertHandlerForTests: ((NSAlert) -> Void)?

    private func present(_ alert: NSAlert) {
        if let alertHandlerForTests { alertHandlerForTests(alert) } else { alert.runModal() }
    }

    func pressPrimaryForTests() { primaryClicked() }
    var statusForTests: GitStatus { status }
    var isBusyForTests: Bool { isBusy }

    private func showError(_ title: String, _ details: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        var text = details
        if details.contains("Authentication failed") || details.contains("could not read Username")
            || details.contains("Permission denied") || details.contains("terminal prompts disabled") {
            text += "\n\nFeather never asks for passwords itself. Run the same command once in the terminal (⌃`) so Git can save your credentials, then try again."
        }
        alert.informativeText = String(text.prefix(1500))
        present(alert)
    }

    // MARK: - Actions

    @objc private func commit() {
        let message = messageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status.conflicts.isEmpty else { NSSound.beep(); return }
        guard !message.isEmpty || status.isMerging else {
            info.stringValue = "Type a commit message first."
            view.window?.makeFirstResponder(messageField)
            NSSound.beep()
            return
        }
        var commands: [[String]] = []
        if status.staged.isEmpty && !status.isMerging { commands.append(["add", "-A"]) }
        commands.append(message.isEmpty ? ["commit", "--no-edit"] : ["commit", "-m", message])
        run(commands, busy: "Committing…") { [weak self] result in
            guard result.ok, let field = self?.messageField else { return }
            // Clear the live field editor as well, or it writes the old message back when focus moves.
            field.stringValue = ""
            field.currentEditor()?.string = ""
        }
    }

    /// A branch with no upstream yet is published as `origin/<name>`.
    private var pushCommand: [String]? {
        guard let branch = status.branch else { return nil }
        return status.upstream == nil ? ["push", "-u", "origin", branch] : ["push"]
    }

    @objc func push() {
        guard let command = pushCommand else { NSSound.beep(); return }
        run([command], busy: "Pushing…", network: true)
    }

    @objc func pull() { pullThen(push: false) }

    /// Pull, then push: what VS Code's Sync does. Stops at the pull when it fails (a conflict), so nothing
    /// half-merged is pushed.
    @objc func sync() {
        guard pushCommand != nil else { NSSound.beep(); return }
        pullThen(push: true)
    }

    /// `reconcile`: the branches had both moved and git asked how to combine them; merge, as VS Code does
    /// unless pull.rebase says otherwise (a user who set it never gets here, the first pull obeys it).
    private func pullThen(push thenPush: Bool, reconcile: Bool = false) {
        var pullCommand = ["pull", "--no-edit"]
        if reconcile { pullCommand.append("--no-rebase") }
        var commands = [pullCommand]
        if thenPush, let push = pushCommand { commands.append(push) }
        run(commands, busy: thenPush ? "Syncing: pulling, then pushing…" : "Pulling…", network: true, onFailure: { [weak self] result in
            guard let self else { return }
            if !reconcile, SourceControlViewController.classify(result) == .divergent {
                DispatchQueue.main.async { self.pullThen(push: thenPush, reconcile: true) }
            } else {
                self.pullFailed(result)
            }
        })
    }

    /// A pull that ends in conflicts is a merge to finish, not an error; the other usual endings get a plain answer.
    private func pullFailed(_ result: GitResult) {
        switch SourceControlViewController.classify(result) {
        case .conflict: showConflictGuidance(after: "pull")
        case .divergent: showError("Pull needs to know how to combine the branches", "Both this branch and the remote moved. Feather merges them (git pull --no-rebase); set pull.rebase in your git config to rebase instead.")
        case .noUpstream: showError("This branch is not connected to a remote branch", "Publish Branch connects it and pushes it; after that Pull and Sync know where to look.")
        case .localChangesInTheWay: showError("Your changes are in the way", "Git will not pull over files you have changed but not committed. Commit them, or choose Stash Changes… from the branch menu, then pull again.")
        case .authentication, .other: showError("Pull failed", result.message)
        }
    }

    /// Conflicts are an expected outcome of a merge or a pull, not an error, so they get guidance instead of a failure alert.
    private func showConflictGuidance(after verb: String) {
        let alert = NSAlert()
        alert.messageText = "Both sides changed the same lines"
        alert.informativeText = "The \(verb) brought in changes git could not combine by itself. Files marked ! in the Changes list need a decision: "
            + "open each one — above every conflict the editor offers Accept Current, Accept Incoming and Accept Both — save, "
            + "press + to mark it resolved, then \(status.isRebasing ? "Continue Rebase" : "Commit Merge").\n\n"
            + "To go back to how things were, choose \(status.isRebasing ? "Abort Rebase" : "Abort Merge") from the branch menu."
        present(alert)
    }

    // MARK: - Publish

    /// VS Code's Publish Branch: push with tracking to origin; without any remote, make one first, on GitHub
    /// through its command-line tool or from an address.
    @objc func publish() {
        guard let branch = status.branch else { NSSound.beep(); return }
        switch SourceControlViewController.publishPlan(remotes: remotes) {
        case .push(let remote):
            run([["push", "-u", remote, branch]], busy: "Publishing \(branch)…", network: true)
        case .needsRemote:
            askForRemote(branch: branch)
        }
    }

    private func askForRemote(branch: String) {
        guard let root = repositoryRoot else { return }
        let gh = SourceControlViewController.gitHubCLI()
        let alert = NSAlert()
        alert.messageText = "Publish “\(branch)”"
        alert.informativeText = "This repository is only on this Mac. Where should it go?"
        let github = NSButton(radioButtonWithTitle: "Create a repository on GitHub", target: nil, action: nil)
        let address = NSButton(radioButtonWithTitle: "Connect a remote address", target: nil, action: nil)
        let nameField = NSTextField(string: root.lastPathComponent)
        let privateBox = NSButton(checkboxWithTitle: "Private", target: nil, action: nil)
        privateBox.state = .on
        let urlField = NSTextField(string: "")
        urlField.placeholderString = "git@github.com:you/repo.git  or  https://…"
        let ghNote = NSTextField(wrappingLabelWithString: gh == nil
            ? "Needs the GitHub command-line tool: install it with “brew install gh”, run “gh auth login” once, then come back. Or create the repository on github.com and paste its address below."
            : "Made with the GitHub command-line tool as your signed-in account, then pushed.")
        ghNote.font = .systemFont(ofSize: 11)
        ghNote.textColor = .secondaryLabelColor
        github.isEnabled = gh != nil
        github.state = gh != nil ? .on : .off
        address.state = gh != nil ? .off : .on
        let update = { [weak nameField, weak privateBox, weak urlField] in
            let onGitHub = github.state == .on
            nameField?.isEnabled = onGitHub; privateBox?.isEnabled = onGitHub; urlField?.isEnabled = !onGitHub
        }
        github.target = RadioRelay.shared; github.action = #selector(RadioRelay.changed(_:))
        address.target = RadioRelay.shared; address.action = #selector(RadioRelay.changed(_:))
        RadioRelay.shared.onChange = { sender in
            (sender === github ? address : github).state = .off
            update()
        }
        update()
        let nameRow = NSStackView(views: [NSTextField(labelWithString: "Name:"), nameField, privateBox])
        nameRow.orientation = .horizontal
        nameField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let column = NSStackView(views: [github, ghNote, nameRow, address, urlField])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.setCustomSpacing(12, after: nameRow)
        column.frame = NSRect(x: 0, y: 0, width: 380, height: 150)
        column.translatesAutoresizingMaskIntoConstraints = false
        column.widthAnchor.constraint(equalToConstant: 380).isActive = true
        urlField.widthAnchor.constraint(equalToConstant: 380).isActive = true
        alert.accessoryView = column
        alert.addButton(withTitle: "Publish")
        alert.addButton(withTitle: "Cancel")
        if gh == nil { alert.addButton(withTitle: "Open github.com/new") }
        let response = alert.runModal()
        RadioRelay.shared.onChange = nil
        switch response {
        case .alertFirstButtonReturn:
            if github.state == .on, let gh {
                let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { NSSound.beep(); return }
                createOnGitHub(gh, name: name, isPrivate: privateBox.state == .on, branch: branch)
            } else {
                let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { NSSound.beep(); return }
                run([["remote", "add", "origin", url]], busy: "Connecting origin…") { [weak self] result in
                    guard result.ok else { return }
                    self?.run([["push", "-u", "origin", branch]], busy: "Publishing \(branch)…", network: true)
                }
            }
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(URL(string: "https://github.com/new")!)
        default:
            break
        }
    }

    private func createOnGitHub(_ gh: URL, name: String, isPrivate: Bool, branch: String) {
        guard let root = repositoryRoot, !isBusy else { return }
        isBusy = true
        info.stringValue = "Creating \(name) on GitHub and pushing…"
        commitButton.isEnabled = false
        let arguments = SourceControlViewController.gitHubCreateArguments(name: name, isPrivate: isPrivate, root: root)
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = gh
            process.arguments = arguments
            process.currentDirectoryURL = root
            var environment = ShellEnvironment.shared.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GH_PROMPT_DISABLED"] = "1"
            environment["GH_NO_UPDATE_NOTIFIER"] = "1"
            process.environment = environment
            let output = Pipe(), error = Pipe()
            process.standardOutput = output
            process.standardError = error
            process.standardInput = FileHandle.nullDevice
            var status: Int32 = -1
            var message = ""
            do {
                try process.run()
                let errorText = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let outputText = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                status = process.terminationStatus
                message = errorText.isEmpty ? outputText : errorText
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isBusy = false
                if status != 0 {
                    var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.contains("auth login") || text.contains("not logged") { text += "\n\nRun “gh auth login” once in the terminal (⌃`), then publish again." }
                    self.showError("GitHub did not create the repository", text)
                }
                self.refresh()
                self.onRepositoryChanged?()
            }
        }
    }

    // MARK: - Rebase

    @objc private func continueRebase() {
        run([["rebase", "--continue"]], busy: "Continuing rebase…", onFailure: { [weak self] result in
            if SourceControlViewController.classify(result) == .conflict { self?.showConflictGuidance(after: "rebase") }
            else { self?.showError("Could not continue the rebase", result.message) }
        })
    }

    @objc private func abortRebase() {
        run([["rebase", "--abort"]], busy: "Aborting rebase…")
    }

    @objc func fetch() {
        run([["fetch", "--all", "--prune"]], busy: "Fetching…", network: true)
    }

    @objc private func showGraph() { onShowGraph?(nil) }

    /// Apple's own installer for the Command Line Tools (git among them). This is the one place Feather means
    /// to bring that dialog up; `xcode-select --install` returns at once and the dialog carries on by itself.
    static func installCommandLineTools() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--install"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: - Repository list

    func numberOfRows(in tableView: NSTableView) -> Int { repositories.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("RepositoryRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ChangeRowView ?? {
            let cell = ChangeRowView(frame: .zero)
            cell.identifier = identifier
            return cell
        }()
        let entry = repositories[row]
        let theme = Settings.shared.theme
        let text = NSMutableAttributedString(
            string: entry.name,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: theme.foreground])
        if let status = entry.status {
            var detail = "   ⎇ " + (status.branch ?? "detached")
            if status.ahead > 0 { detail += " ↑\(status.ahead)" }
            if status.behind > 0 { detail += " ↓\(status.behind)" }
            text.append(NSAttributedString(string: detail, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: theme.lineNumber]))
            let changes = status.staged.count + status.unstaged.count
            if changes > 0 {
                text.append(NSAttributedString(string: "   ● \(changes)", attributes: [
                    .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                    .foregroundColor: status.conflicts.isEmpty ? NSColor(hex: 0xE2C08D) : NSColor(hex: 0xF14C4C)]))
            }
        }
        cell.label.attributedStringValue = text
        cell.toolTip = entry.url.path
        cell.setButtons([], tint: theme.lineNumber)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingRepositoryList, notification.object as? NSTableView === repositoryTable,
              repositories.indices.contains(repositoryTable.selectedRow) else { return }
        let entry = repositories[repositoryTable.selectedRow]
        guard entry.url != repositoryRoot else { return }
        select(entry, reloadGraph: true)
    }

    @objc private func initializeRepository() {
        guard Git.isAvailable else { SourceControlViewController.installCommandLineTools(); return }
        guard let projectRoot else { return }
        Git.run(["init"], in: projectRoot) { [weak self] result in
            if !result.ok { self?.showError("Could not start a history of changes here", result.message) }
            self?.discover(preferring: nil)
            self?.onRepositoryChanged?()
        }
    }

    private func stage(_ paths: [String]) { run([["add", "--"] + paths], busy: "Staging…") }

    private func unstage(_ paths: [String]) {
        guard let root = repositoryRoot else { return }
        // `reset` needs a commit to reset to; in a brand-new repository fall back to removing from the index.
        Git.headCommit(in: root) { [weak self] head in
            self?.run([(head != nil ? ["reset", "-q", "--"] : ["rm", "--cached", "-q", "--"]) + paths], busy: "Unstaging…")
        }
    }

    private func discard(_ change: GitFileChange) {
        guard let root = repositoryRoot else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard changes to “\((change.path as NSString).lastPathComponent)”?"
        alert.informativeText = change.isUntracked ? "This new file will be moved to the Trash."
            : "Your edits to this file will be lost. This cannot be undone."
        alert.addButton(withTitle: change.isUntracked ? "Move to Trash" : "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if change.isUntracked {
            try? FileManager.default.trashItem(at: root.appendingPathComponent(change.path), resultingItemURL: nil)
            refresh()
            onRepositoryChanged?()
        } else {
            run([["checkout", "--", change.path]], busy: "Discarding…")
        }
    }

    // MARK: - Branch menu

    @objc private func showBranchMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("Switch Branch…", #selector(switchBranch))
        add("New Branch…", #selector(newBranch))
        menu.addItem(.separator())
        add("Merge Branch into “\(status.branch ?? "HEAD")”…", #selector(mergeBranch))
        if status.isMerging { add("Abort Merge", #selector(abortMerge)) }
        if status.isRebasing {
            add("Continue Rebase", #selector(continueRebase))
            add("Abort Rebase", #selector(abortRebase))
        }
        if status.branch != nil, status.upstream == nil, !status.isUnborn { add("Publish Branch…", #selector(publish)) }
        menu.addItem(.separator())
        add("Stash Changes…", #selector(stashChanges(_:)))
        add("Pop Latest Stash", #selector(popLatestStash(_:)))
        let stashesItem = NSMenuItem(title: "Stashes", action: nil, keyEquivalent: "")
        stashesItem.submenu = NSMenu(title: "Stashes")
        menu.addItem(stashesItem)
        menu.addItem(.separator())
        add("Open Repository on GitHub", #selector(openRepositoryPage))
        add("Open Pull Requests on GitHub", #selector(openPullRequestsPage))
        // The list of stashes is one quick local git call away; the menu opens when it is back.
        loadStashes { [weak self] stashes in
            guard let self else { return }
            self.fill(stashesItem, with: stashes)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: self.branchButton.bounds.height + 4), in: self.branchButton)
        }
    }

    private func chooseBranch(title: String, button: String, completion: @escaping (String) -> Void) {
        guard let root = repositoryRoot else { return }
        Git.otherBranches(in: root) { branches in
            guard !branches.isEmpty else {
                let alert = NSAlert()
                alert.messageText = "There are no other branches yet."
                alert.informativeText = "Create one with “New Branch…”."
                alert.runModal()
                return
            }
            let alert = NSAlert()
            alert.messageText = title
            alert.addButton(withTitle: button)
            alert.addButton(withTitle: "Cancel")
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
            popup.addItems(withTitles: branches)
            alert.accessoryView = popup
            guard alert.runModal() == .alertFirstButtonReturn, let choice = popup.titleOfSelectedItem else { return }
            completion(choice)
        }
    }

    @objc private func switchBranch() {
        chooseBranch(title: "Switch to branch", button: "Switch") { [weak self] branch in
            // "origin/feature" checks out a local "feature" that tracks it.
            let isRemote = branch.contains("/") && !(self?.status.branch ?? "").isEmpty && branch.hasPrefix("origin/")
            self?.run([isRemote ? ["checkout", "--track", branch] : ["checkout", branch]], busy: "Switching…") { result in
                guard !result.ok, isRemote else { return }
                // The tracking branch may already exist locally.
                self?.run([["checkout", String(branch.dropFirst("origin/".count))]], busy: "Switching…")
            }
        }
    }

    @objc private func newBranch() {
        let alert = NSAlert()
        alert.messageText = "New branch from “\(status.branch ?? "HEAD")”"
        alert.addButton(withTitle: "Create and Switch")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "feature/my-branch"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        run([["checkout", "-b", name]], busy: "Creating branch…")
    }

    @objc private func mergeBranch() {
        let current = status.branch ?? "HEAD"
        chooseBranch(title: "Merge into “\(current)”", button: "Merge") { [weak self] branch in
            self?.merge(branch)
        }
    }

    /// Conflicts are an expected outcome of a merge, not an error, so they get guidance instead of a failure alert.
    private func merge(_ branch: String) {
        guard let root = repositoryRoot, !isBusy else { return }
        isBusy = true
        info.stringValue = "Merging \(branch)…"
        Git.run(["merge", "--no-edit", branch], in: root) { [weak self] result in
            guard let self else { return }
            self.isBusy = false
            if !result.ok {
                if SourceControlViewController.classify(result) == .conflict {
                    self.showConflictGuidance(after: "merge")
                } else {
                    self.showError("Merge failed", result.message)
                }
            }
            self.refresh()
            self.onRepositoryChanged?()
        }
    }

    @objc private func abortMerge() {
        run([["merge", "--abort"]], busy: "Aborting merge…")
    }

    // MARK: - Stash

    struct Stash {
        let ref: String            // "stash@{0}"
        let title: String          // "On main: half-done invoice sorting"
        let age: String            // "3 days ago"
    }

    private func loadStashes(completion: @escaping ([Stash]) -> Void) {
        guard let root = repositoryRoot else { return completion([]) }
        Git.run(["stash", "list", "--format=%gd%x1f%gs%x1f%cr"], in: root) { result in
            completion(result.output.split(separator: "\n").compactMap { line in
                let fields = line.components(separatedBy: "\u{1f}")
                return fields.count == 3 ? Stash(ref: fields[0], title: fields[1], age: fields[2]) : nil
            })
        }
    }

    private func fill(_ item: NSMenuItem, with stashes: [Stash]) {
        guard let menu = item.submenu else { return }
        if stashes.isEmpty {
            let none = NSMenuItem(title: "No Stashes", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for stash in stashes {
            let entry = NSMenuItem(title: "\(stash.title)  (\(stash.age))", action: nil, keyEquivalent: "")
            let actions = NSMenu()
            for (title, action) in [("Apply", #selector(applyStashChosen(_:))), ("Pop", #selector(popStashChosen(_:))),
                                    ("Drop…", #selector(dropStashChosen(_:)))] {
                let choice = NSMenuItem(title: title, action: action, keyEquivalent: "")
                choice.target = self
                choice.representedObject = stash.ref
                actions.addItem(choice)
            }
            entry.submenu = actions
            menu.addItem(entry)
        }
    }

    @objc func stashChanges(_ sender: Any?) {
        guard repositoryRoot != nil else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Stash changes on “\(status.branch ?? "HEAD")”"
        alert.informativeText = "Your changes are put aside safely and the files go back to the last saved version (commit). “Pop Latest Stash” brings them back."
        alert.addButton(withTitle: "Stash")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 28, width: 300, height: 24))
        field.placeholderString = "Message (optional)"
        let untracked = NSButton(checkboxWithTitle: "Include untracked (new) files", target: nil, action: nil)
        untracked.state = .on
        untracked.frame = NSRect(x: 0, y: 0, width: 300, height: 20)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 54))
        accessory.addSubview(field)
        accessory.addSubview(untracked)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        stash(message: field.stringValue, includeUntracked: untracked.state == .on)
    }

    func stash(message: String, includeUntracked: Bool) {
        var command = ["stash", "push"]
        if includeUntracked { command.append("--include-untracked") }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { command += ["-m", text] }
        run([command], busy: "Stashing…", onFailure: { [weak self] in self?.showStashError("Could not stash the changes", $0) }) { [weak self] result in
            // Git says this on success too, and leaves everything as it was.
            if result.ok, result.output.contains("No local changes to save") { self?.showError("Nothing to stash", "There are no local changes to put aside.") }
        }
    }

    @objc func popLatestStash(_ sender: Any?) { restoreStash("stash@{0}", pop: true) }

    @objc private func popStashChosen(_ sender: NSMenuItem) {
        if let ref = sender.representedObject as? String { restoreStash(ref, pop: true) }
    }

    @objc private func applyStashChosen(_ sender: NSMenuItem) {
        if let ref = sender.representedObject as? String { restoreStash(ref, pop: false) }
    }

    func restoreStash(_ ref: String, pop: Bool) {
        guard repositoryRoot != nil else { NSSound.beep(); return }
        run([["stash", pop ? "pop" : "apply", ref]], busy: pop ? "Popping stash…" : "Applying stash…",
            onFailure: { [weak self] in self?.showStashError(pop ? "Could not pop the stash" : "Could not apply the stash", $0) })
    }

    @objc private func dropStashChosen(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Drop \(ref)?"
        alert.informativeText = "The changes saved in “\(sender.parent?.title ?? ref)” will be deleted. This cannot be undone."
        alert.addButton(withTitle: "Drop Stash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        dropStash(ref)
    }

    func dropStash(_ ref: String) {
        run([["stash", "drop", ref]], busy: "Dropping stash…", onFailure: { [weak self] in self?.showStashError("Could not drop the stash", $0) })
    }

    /// Git explains a failed stash on both of its outputs (the conflicts on one, "the stash entry is kept" on the
    /// other), so the user is shown both.
    private func showStashError(_ title: String, _ result: GitResult) {
        var text = [result.output, result.error].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
        if text.contains("CONFLICT") {
            // Git follows the conflicts with a full `git status`; the Changes list already shows that.
            text = text.components(separatedBy: "\n").filter { line in
                ["CONFLICT", "Auto-merging", "error:", "The stash entry"].contains { line.hasPrefix($0) }
            }.joined(separator: "\n")
            text += "\n\nFiles marked ! in the Changes list have conflicts. Open each one, fix the <<<<<<< sections, save, then press + to mark it resolved."
        }
        if text.contains("is not a valid reference") { text = "There is no such stash.\n\n" + text }
        showError(text.contains("CONFLICT") ? "The stash was applied with conflicts" : title, text)
    }

    // MARK: - Web pages

    private func openPage(_ choose: @escaping (GitRemote) -> URL?) {
        guard let root = repositoryRoot else { return }
        GitLinks.place(inRepository: root) { [weak self] result in
            switch result {
            case .success(let place): if let url = choose(place.remote) { GitLinks.open(url) }
            case .failure(let message): self?.showError("There is no web page to open", message.text)
            }
        }
    }

    @objc private func openRepositoryPage() { openPage(\.repositoryURL) }

    @objc private func openPullRequestsPage() { openPage(\.pullRequestsURL) }

    // MARK: - Outline

    /// One click shows what changed; a file in conflict has no two sides to compare yet, so it opens as itself.
    @objc private func rowClicked() {
        guard let item = outlineView.item(atRow: outlineView.clickedRow) as? ChangeItem, let root = repositoryRoot else { return }
        if item.change.isConflict || onOpenDiff == nil {
            openSource(of: item.change, in: root)
        } else {
            onOpenDiff?(root, item.change)
        }
    }

    @objc private func rowDoubleClicked() {
        guard let item = outlineView.item(atRow: outlineView.clickedRow) as? ChangeItem, let root = repositoryRoot else { return }
        openSource(of: item.change, in: root)
    }

    private func openSource(of change: GitFileChange, in root: URL) {
        let url = root.appendingPathComponent(change.path)
        if FileManager.default.fileExists(atPath: url.path) { onOpenFile?(url) }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? ChangeGroup)?.changes.count ?? (item == nil ? groups.count : 0)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? ChangeGroup)?.changes[index] ?? groups[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is ChangeGroup }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        (outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("change-row"), owner: nil) as? APITableRowView) ?? {
            let row = APITableRowView()
            row.identifier = NSUserInterfaceItemIdentifier("change-row")
            return row
        }()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ChangeRow")
        let row = outlineView.makeView(withIdentifier: identifier, owner: nil) as? ChangeRowView ?? {
            let row = ChangeRowView(frame: .zero)
            row.identifier = identifier
            return row
        }()
        let theme = Settings.shared.theme
        if let group = item as? ChangeGroup {
            row.showGroup(title: group.isStaged ? "Staged Changes" : "Changes", count: group.changes.count, theme: theme)
            let paths = group.changes.map(\.change.path)
            row.setButtons(group.isStaged
                ? [("minus", "Unstage All", { [weak self] in self?.unstage(paths) })]
                : [("plus", "Stage All", { [weak self] in self?.stage(paths) })], tint: theme.lineNumber)
        } else if let item = item as? ChangeItem {
            let change = item.change
            row.showChange(change, theme: theme)
            if change.isStaged {
                row.setButtons([("minus", "Unstage", { [weak self] in self?.unstage([change.path]) })], tint: theme.lineNumber)
            } else {
                row.setButtons([
                    ("arrow.uturn.backward", "Discard Changes", { [weak self] in self?.discard(change) }),
                    ("plus", change.isConflict ? "Mark as Resolved" : "Stage", { [weak self] in self?.stage([change.path]) }),
                ], tint: theme.lineNumber)
            }
        }
        return row
    }

    // MARK: - Message field

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            commit()
        } else {
            textView.insertNewlineIgnoringFieldEditor(nil)
        }
        return true
    }
}


/// Target for the radio buttons of the publish sheet, which is built and torn down inside one method.
final class RadioRelay: NSObject {
    static let shared = RadioRelay()
    var onChange: ((NSButton) -> Void)?
    @objc func changed(_ sender: NSButton) { onChange?(sender) }
}
