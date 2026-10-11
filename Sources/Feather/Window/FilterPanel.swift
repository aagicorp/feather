import AppKit

private final class FilterPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A floating list you narrow by typing: the Command Palette and Go to Symbol are both one of these. It knows
/// nothing about what the rows mean; it is given titles and reports which one was chosen.
final class FilterPanelController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    struct Item {
        let title: String
        /// Shown after the title in grey: a shortcut, a setting's state, a symbol's kind and line.
        let detail: String
        /// Nesting, drawn as leading space. It is not part of what typing matches against.
        var indent = 0
    }

    private let panel: NSPanel
    private let field = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var items: [Item] = []
    /// Each title lowercased and split once per showing, not once per keystroke per row.
    private var searchable: [[Character]] = []
    private var results: [Int] = []
    var onChoose: ((Int) -> Void)?

    var isVisible: Bool { panel.isVisible }

    init(placeholder: String, size: NSSize = NSSize(width: 600, height: 380)) {
        panel = FilterPanelWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.delegate = self
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 15)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.delegate = self

        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item")))
        tableView.headerView = nil
        tableView.rowHeight = 26
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(chooseSelection)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.useFeatherScrollers()

        let content = NSView()
        for subview in [field, scrollView] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
        panel.isOpaque = false
        panel.backgroundColor = .clear
        surface = Glass.panel(around: content, cornerRadius: 12, tint: Settings.shared.theme.chrome)
        panel.contentView = surface
    }

    private var surface: NSView?

    /// `onChoose` receives the index into `items` of the row that was picked, after the panel has gone. `typed`
    /// is text already in the box, carried over from Quick Open.
    func show(over window: NSWindow, items: [Item], typed: String = "", onChoose: @escaping (Int) -> Void) {
        if let surface { Glass.retint(surface, Settings.shared.theme.chrome) }
        panel.appearance = window.appearance
        self.onChoose = onChoose
        field.stringValue = typed
        setItems(items)
        let frame = window.frame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - 90))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// Replaces the rows of a panel that is already up, keeping whatever has been typed.
    func setItems(_ items: [Item]) {
        self.items = items
        searchable = items.map { Array($0.title.lowercased()) }
        updateResults()
    }

    // MARK: - Searching

    /// Subsequence match; rewards consecutive characters and hits at the start of a word.
    static func score(_ query: [Character], in text: [Character]) -> Int? {
        var queryIndex = 0, score = 0, previous = -2
        for (index, character) in text.enumerated() where queryIndex < query.count && character == query[queryIndex] {
            score += 1
            if index == previous + 1 { score += 4 }
            if index == 0 || text[index - 1] == " " { score += 3 }
            previous = index
            queryIndex += 1
        }
        return queryIndex == query.count ? score * 4 - text.count / 10 : nil
    }

    /// Row order for what is typed: the given order for nothing, best match first otherwise.
    func matches(for typed: String) -> [Int] {
        let query = Array(typed.lowercased().replacingOccurrences(of: " ", with: ""))
        if query.isEmpty { return Array(items.indices) }
        return searchable.enumerated()
            .compactMap { index, text in FilterPanelController.score(query, in: text).map { (score: $0, index: index) } }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.index)
    }

    private func updateResults() {
        results = matches(for: field.stringValue)
        tableView.reloadData()
        if !results.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    @objc private func chooseSelection() {
        let row = tableView.selectedRow
        guard results.indices.contains(row) else { return }
        let chosen = results[row]
        let onChoose = self.onChoose
        panel.orderOut(nil)
        // After this turn of the run loop, so the main window is key again before the choice acts on it.
        DispatchQueue.main.async { onChoose?(chosen) }
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let row = max(0, min(results.count - 1, tableView.selectedRow + delta))
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    // MARK: - Delegates

    func controlTextDidChange(_ obj: Notification) { updateResults() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)): chooseSelection()
        case #selector(NSResponder.cancelOperation(_:)): panel.orderOut(nil)
        default: return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) { panel.orderOut(nil) }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("FilterPanelCell")
        let label = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField ?? {
            let label = NSTextField(labelWithString: "")
            label.identifier = identifier
            label.usesSingleLineMode = true
            label.lineBreakMode = .byTruncatingTail
            return label
        }()
        let item = items[results[row]]
        // Nesting only reads as nesting while the rows are in file order, which is while nothing is typed.
        let indent = field.stringValue.isEmpty ? String(repeating: "    ", count: item.indent) : ""
        let text = NSMutableAttributedString(string: indent + item.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        if !item.detail.isEmpty {
            text.append(NSAttributedString(string: "     " + item.detail, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        label.attributedStringValue = text
        return label
    }
}
