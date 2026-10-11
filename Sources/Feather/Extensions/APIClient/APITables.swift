import AppKit

/// A small editable table: a tick box, text boxes and popups per row. The owner keeps the rows and answers for
/// each cell through closures, so one class serves Params, Headers, form fields, Checks, Set variables and the
/// variables of an environment. A name/value list ends in a blank row that says what to type ("Add parameter")
/// and becomes a real row as soon as something is typed; every row shows ✕ under the pointer; tables of other
/// shapes (checks, captures) get an "Add…" link under them. Name/value lists can also be edited as text, one
/// `name: value` a line.
final class APIEditableTable: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    enum Cell {
        case toggle(Bool)
        /// `secret` shows dots instead of the text.
        case text(String, placeholder: String, enabled: Bool = true, secret: Bool = false)
        /// Options are (title, value); `value` is the current one.
        case popup(options: [(title: String, value: String)], value: String)
    }

    struct Column {
        let id: String
        let title: String
        /// Nil for a column that takes what is left.
        let width: CGFloat?
        let cell: (Int) -> Cell
        /// The new value: "1"/"0" for a tick box, the option's value for a popup, the text for a text box.
        let set: (Int, String) -> Void
    }

    static let deleteColumnID = "_delete"

    let table = APIEditableTableView()
    private let scrollView = NSScrollView()
    private let root = NSStackView()
    private let footer = NSStackView()
    private let addLink = NSButton(title: "", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "")
    private let bulkScroll = NSScrollView()
    private let bulkText = NSTextView()
    private var columns: [Column] = []
    var count: () -> Int = { 0 }
    var onAdd: (() -> Void)?
    var onRemove: ((Int) -> Void)?
    /// What the list says under itself when it has no rows (tables without a blank row).
    var emptyText = "" { didSet { emptyLabel.stringValue = emptyText } }
    /// A blank row under the real ones that becomes a real row as soon as something is typed into it, so a
    /// name/value list never needs "+" first. The closure gives the blank cell for a column id.
    var blankRow: ((String) -> Cell)? { didSet { table.reloadData(); footer.isHidden = blankRow != nil } }
    /// What the blank row's first text box says: "Add parameter", "Add header".
    var addPrompt = "" { didSet { table.reloadData() } }
    /// The rows as name/value pairs, for editing as text; nil for a table of another shape.
    var bulkRows: (() -> [APIKeyValue])?
    var onBulkApply: (([APIKeyValue]) -> Void)?
    private(set) var isBulkEditing = false
    var canBulkEdit: Bool { bulkRows != nil }
    private var rowCount: Int { count() + (blankRow == nil ? 0 : 1) }
    private func isBlankRow(_ row: Int) -> Bool { blankRow != nil && row == count() }

    init(columns: [Column], addTip: String = "Add a row", removeTip: String = "Remove the selected row") {
        super.init(frame: .zero)
        self.columns = columns
        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            if let width = column.width {
                tableColumn.width = width
                tableColumn.minWidth = width
                tableColumn.maxWidth = width
            } else {
                tableColumn.minWidth = 60
            }
            tableColumn.resizingMask = column.width == nil ? .autoresizingMask : []
            table.addTableColumn(tableColumn)
        }
        let deleteColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(APIEditableTable.deleteColumnID))
        deleteColumn.title = ""
        deleteColumn.width = 22
        deleteColumn.minWidth = 22
        deleteColumn.maxWidth = 22
        deleteColumn.resizingMask = []
        table.addTableColumn(deleteColumn)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = 24
        table.style = .plain
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.allowsEmptySelection = true
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.dataSource = self
        table.delegate = self
        table.headerView?.wantsLayer = true
        table.onDeleteKey = { [weak self] in self?.removeSelected() }
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.useFeatherScrollers()

        addLink.title = addTip
        addLink.isBordered = false
        addLink.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        addLink.imagePosition = .imageLeading
        addLink.font = .systemFont(ofSize: 11)
        addLink.target = self
        addLink.action = #selector(addClicked)
        addLink.setContentHuggingPriority(.required, for: .horizontal)
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.lineBreakMode = .byTruncatingTail
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.addArrangedSubview(addLink)
        footer.addArrangedSubview(emptyLabel)
        footer.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 0, right: 0)

        bulkText.isRichText = false
        bulkText.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        bulkText.isAutomaticQuoteSubstitutionEnabled = false
        bulkText.isAutomaticDashSubstitutionEnabled = false
        bulkText.isAutomaticTextReplacementEnabled = false
        bulkText.isAutomaticSpellingCorrectionEnabled = false
        bulkText.isVerticallyResizable = true
        bulkText.autoresizingMask = [.width]
        bulkText.textContainerInset = NSSize(width: 6, height: 6)
        bulkText.textContainer?.widthTracksTextView = true
        bulkText.delegate = self
        bulkScroll.documentView = bulkText
        bulkScroll.hasVerticalScroller = true
        bulkScroll.autohidesScrollers = true
        bulkScroll.borderType = .noBorder
        bulkScroll.drawsBackground = false
        bulkScroll.useFeatherScrollers()

        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.distribution = .fill
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(scrollView)
        root.addArrangedSubview(footer)
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor), root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor), root.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        footer.setContentHuggingPriority(.required, for: .vertical)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyTheme() {
        let theme = Settings.shared.theme
        emptyLabel.textColor = theme.lineNumber
        addLink.contentTintColor = theme.accent
        bulkText.textColor = theme.foreground
        bulkText.backgroundColor = theme.background
        bulkText.insertionPointColor = theme.foreground
        table.reloadData()
    }

    func reload() {
        // A reload while a box is being typed in would throw the typing away.
        guard table.currentEditor() == nil else { return }
        table.reloadData()
        emptyLabel.isHidden = count() > 0
        footer.isHidden = blankRow != nil
    }

    // MARK: Bulk editing

    /// Swaps the table for a text view of `name: value` lines (a disabled row starts with `//`), and back,
    /// applying the text to the rows on the way back.
    func setBulkEditing(_ on: Bool) {
        guard canBulkEdit, on != isBulkEditing else { return }
        if on {
            bulkText.string = APIEditableTable.bulkText(bulkRows?() ?? [])
            root.removeArrangedSubview(scrollView); scrollView.removeFromSuperview()
            root.removeArrangedSubview(footer); footer.removeFromSuperview()
            root.addArrangedSubview(bulkScroll)
            bulkScroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
            isBulkEditing = true
            window?.makeFirstResponder(bulkText)
        } else {
            applyBulkText()
            root.removeArrangedSubview(bulkScroll); bulkScroll.removeFromSuperview()
            root.addArrangedSubview(scrollView)
            root.addArrangedSubview(footer)
            isBulkEditing = false
            reload()
        }
    }

    private func applyBulkText() {
        guard let bulkRows, let onBulkApply else { return }
        let rows = APIEditableTable.parseBulk(bulkText.string, previous: bulkRows())
        if rows != bulkRows() { onBulkApply(rows) }
    }

    func textDidEndEditing(_ notification: Notification) {
        if isBulkEditing { applyBulkText() }
    }

    /// `name: value` a line; a row that is switched off starts with `//`; rows with nothing in them are left out.
    static func bulkText(_ rows: [APIKeyValue]) -> String {
        rows.compactMap { row in
            guard !(row.name.isEmpty && row.value.isEmpty) else { return nil }
            return (row.enabled ? "" : "// ") + row.name + ": " + row.value
        }.joined(separator: "\n")
    }

    /// The rows for the text: `name: value` or `name=value` a line, `//` or `#` first for a row switched off.
    /// A row whose name was there before keeps its identity (and its description).
    static func parseBulk(_ text: String, previous: [APIKeyValue]) -> [APIKeyValue] {
        var unused = previous
        var rows: [APIKeyValue] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var enabled = true
            for marker in ["//", "#"] where line.hasPrefix(marker) {
                enabled = false
                line = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            let name: String, value: String
            if let separator = line.firstIndex(where: { $0 == ":" || $0 == "=" }) {
                name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
                value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            } else {
                name = line
                value = ""
            }
            guard !name.isEmpty else { continue }
            var row: APIKeyValue
            if let index = unused.firstIndex(where: { $0.name == name }) {
                row = unused.remove(at: index)
                row.value = value
            } else {
                row = APIKeyValue(name, value)
            }
            row.enabled = enabled
            rows.append(row)
        }
        return rows
    }

    // MARK: Adding and removing

    @objc private func addClicked() {
        window?.makeFirstResponder(table)
        onAdd?()
        reload()
        let last = count() - 1
        guard last >= 0 else { return }
        table.selectRowIndexes([last], byExtendingSelection: false)
        table.scrollRowToVisible(last)
        // Straight into the first text box of the new row.
        if let column = columns.firstIndex(where: { if case .text = $0.cell(last) { return true } else { return false } }) {
            table.editColumn(column, row: last, with: nil, select: true)
        }
    }

    private func removeSelected() {
        let row = table.selectedRow
        guard row >= 0, !isBlankRow(row) else { NSSound.beep(); return }
        window?.makeFirstResponder(table)
        onRemove?(row)
        reload()
    }

    @objc private func deleteClicked(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard row >= 0, !isBlankRow(row) else { return }
        window?.makeFirstResponder(table)
        onRemove?(row)
        reload()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let theme = Settings.shared.theme
        if tableColumn.identifier.rawValue == APIEditableTable.deleteColumnID {
            guard !isBlankRow(row) else { return nil }
            let button = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)) ?? NSImage(), target: self, action: #selector(deleteClicked(_:)))
            button.isBordered = false
            button.contentTintColor = theme.lineNumber
            button.toolTip = "Remove this row"
            button.identifier = NSUserInterfaceItemIdentifier(APIEditableTable.deleteColumnID)
            button.isHidden = !((table.rowView(atRow: row, makeIfNecessary: false) as? APITableRowView)?.isHovered ?? false)
            return button
        }
        guard let index = columns.firstIndex(where: { $0.id == tableColumn.identifier.rawValue }) else { return nil }
        let column = columns[index]
        let cell = isBlankRow(row) ? (blankRow?(column.id) ?? .text("", placeholder: "")) : column.cell(row)
        switch cell {
        case .toggle(let on):
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
            box.state = on ? .on : .off
            box.identifier = tableColumn.identifier
            box.isEnabled = !isBlankRow(row)
            box.toolTip = on ? "Sent. Untick to leave this row out without deleting it." : "Not sent. Tick to include it."
            return box
        case .text(let text, let placeholder, let enabled, let secret):
            let field: NSTextField = secret ? NSSecureTextField(string: text) : NSTextField(string: text)
            field.identifier = tableColumn.identifier
            // The blank row's first text box says what the list is for. Asked of the blank row's own cells: with
            // no real rows there is no row to ask.
            let isFirstText = isBlankRow(row) && columns.firstIndex { column in
                if case .text = blankRow?(column.id) ?? .toggle(false) { return true } else { return false }
            } == index
            field.placeholderString = isFirstText && !addPrompt.isEmpty ? addPrompt : placeholder
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            field.textColor = enabled ? theme.foreground : theme.lineNumber
            field.isEditable = enabled
            field.isSelectable = true
            field.lineBreakMode = .byTruncatingTail
            field.delegate = self
            field.cell?.usesSingleLineMode = true
            field.cell?.isScrollable = true
            return field
        case .popup(let options, let value):
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.identifier = tableColumn.identifier
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 11)
            popup.isBordered = false
            for option in options {
                popup.addItem(withTitle: option.title)
                popup.lastItem?.representedObject = option.value
            }
            if let selected = options.firstIndex(where: { $0.value == value }) { popup.selectItem(at: selected) }
            popup.target = self
            popup.action = #selector(popupChanged(_:))
            return popup
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { APITableRowView() }

    private func column(for view: NSView) -> Column? {
        columns.first { $0.id == view.identifier?.rawValue }
    }

    @objc private func toggled(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard row >= 0, let column = column(for: sender) else { return }
        column.set(row, sender.state == .on ? "1" : "0")
        reload()
    }

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        let row = table.row(for: sender)
        guard row >= 0, let column = column(for: sender), let value = sender.selectedItem?.representedObject as? String else { return }
        column.set(row, value)
        reload()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        var row = table.row(for: field)
        guard row >= 0, let column = column(for: field) else { return }
        if isBlankRow(row) {
            // Typing into the blank row makes it real (and a new blank one appears under it).
            guard !field.stringValue.isEmpty, let onAdd else { return }
            onAdd()
            row = count() - 1
        }
        column.set(row, field.stringValue)
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    /// Tab from the last box of the last row adds a row, the way a spreadsheet keeps going.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertTab(_:)), let field = control as? NSTextField else { return false }
        let row = table.row(for: field)
        let columnIndex = table.column(for: field)
        guard !isBlankRow(row) else { return false }
        let isLastText = !columns.indices.contains(columnIndex + 1) || !columns[(columnIndex + 1)...].contains { if case .text = $0.cell(row) { return true } else { return false } }
        guard row == count() - 1, isLastText, onAdd != nil else { return false }
        column(for: field)?.set(row, field.stringValue)
        addClicked()
        return true
    }
}

/// The table itself: ⌫ removes the selected row, and the pointer's row is told it is hovered so its ✕ shows.
final class APIEditableTableView: NSTableView {
    var onDeleteKey: (() -> Void)?
    private var hoveredRow = -1

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 51 || event.keyCode == 117), selectedRow >= 0, currentEditor() == nil, let onDeleteKey {
            onDeleteKey()
        } else {
            super.keyDown(with: event)
        }
    }

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

/// A row whose selection is the theme's, not the system blue, so the tables sit with the rest of the window; it
/// also knows whether the pointer is over it and shows the row's actions (✕, duplicate) only then.
final class APITableRowView: NSTableRowView {
    static let actionsIdentifier = NSUserInterfaceItemIdentifier("api-row-actions")

    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            // The action views sit in the cell, or inside a stack of the cell (the Source Control rows).
            for cell in subviews {
                if isAction(cell) { cell.isHidden = !isHovered }
                for view in cell.subviews {
                    if isAction(view) { view.isHidden = !isHovered }
                    for deeper in view.subviews where isAction(deeper) { deeper.isHidden = !isHovered }
                }
            }
            needsDisplay = true
        }
    }

    private func isAction(_ view: NSView) -> Bool {
        view.identifier?.rawValue == APIEditableTable.deleteColumnID || view.identifier == APITableRowView.actionsIdentifier
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isHovered, !isSelected else { return }
        Settings.shared.theme.foreground.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 4, yRadius: 4).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        Settings.shared.theme.selection.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 4, yRadius: 4).fill()
    }
}
