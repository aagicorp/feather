import AppKit

/// The list of terminals on the right: its rows, dragging them into a new order, renaming, and the
/// Change Color and Change Icon menus.
extension TerminalPaneController {
    // MARK: - List

    /// Shows or hides the list and redraws its rows; called whenever the terminals or the one in front change.
    func reloadList() {
        guard isViewLoaded else { return }
        // Reloading replaces the row views, and with them the field a name is being typed into; it waits.
        if renameField != nil { needsReloadAfterRename = true; return }
        // One terminal needs no list; the space is better spent on the terminal itself.
        let show = sessions.count > 1
        listWidth.constant = show ? preferredListWidth : 0
        listHeight.constant = show ? min(CGFloat(sessions.count), 4) * (listTable.rowHeight + 2) + 2 : 0
        updateHeaderTitle()
        headerKillButton?.isHidden = sessions.count != 1
        listScroll.isHidden = !show
        listDivider.isHidden = !show || isTall
        isUpdatingList = true
        listTable.reloadData()
        if sessions.indices.contains(selectedIndex) {
            listTable.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        }
        isUpdatingList = false
        strip.refresh()
    }

    /// "TERMINAL  ⎇ main": the branch where the terminal in front is. With one terminal there is no list to
    /// carry the attention dot, so the header does.
    func updateHeaderTitle() {
        var title = "TERMINAL"
        if let branch = current?.branch { title += "  ⎇ " + branch }
        if sessions.count < 2, sessions.contains(where: { $0.needsAttention }) { title += "  ●" }
        if titleLabel.stringValue != title { titleLabel.stringValue = title }
    }

    /// Brings the rows up to date in place: which terminal is selected and showing, the names, the attention
    /// dots. A click on a row, which is also the press that starts a drag, changes the selection; reloading the
    /// table for that would replace the row views under the pointer and cancel the drag before it began. (The
    /// rows for a changed list are rebuilt by `reloadList`.)
    func refreshListRows() {
        guard isViewLoaded, renameField == nil else { return }
        guard listTable.numberOfRows == sessions.count else { reloadList(); return }
        updateHeaderTitle()
        isUpdatingList = true
        for row in 0..<listTable.numberOfRows {
            if let cell = listTable.view(atColumn: 0, row: row, makeIfNecessary: false) as? TerminalRowView { configure(cell, row: row) }
            if let rowView = listTable.rowView(atRow: row, makeIfNecessary: false) as? TerminalListRowView {
                let showing = visibleSessions.contains { $0 === sessions[row] }
                if rowView.isShowing != showing { rowView.isShowing = showing; rowView.needsDisplay = true }
            }
        }
        if sessions.indices.contains(selectedIndex), listTable.selectedRow != selectedIndex {
            listTable.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        }
        isUpdatingList = false
        strip.refresh()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sessions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("TerminalRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? TerminalRowView ?? {
            let cell = TerminalRowView(frame: .zero)
            cell.identifier = identifier
            return cell
        }()
        configure(cell, row: row)
        return cell
    }

    /// Fills a row's cell for the terminal at `row`.
    private func configure(_ cell: TerminalRowView, row: Int) {
        let session = sessions[row]
        let settings = Settings.shared
        let theme = settings.theme
        let isSelected = row == selectedIndex
        // Its own colours (Settings), else the theme's accent for icons and its text colour for names; a task
        // still running is green, and an assistant gets the sparkle. Rows not showing are a little quieter.
        let iconColor = session.customColor ?? (session.isTask && session.isRunning ? NSColor(hex: 0x3FB950) : settings.terminalListIcon)
        let symbol = session.customIcon ?? (session.isTask ? (session.isRunning ? "play.fill" : "stop.fill") : (session.isAssistant ? "sparkles" : "terminal"))
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium).applying(
            NSImage.SymbolConfiguration(paletteColors: [isSelected ? iconColor : iconColor.withAlphaComponent(0.75)]))
        cell.icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        let textColor = settings.terminalListText
        let text = NSMutableAttributedString(string: session.name, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: isSelected ? .semibold : .regular),
            .foregroundColor: isSelected ? textColor : textColor.withAlphaComponent(0.72)])
        if !session.detail.isEmpty {
            text.append(NSAttributedString(string: "  " + session.detail, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: textColor.withAlphaComponent(0.5)]))
        }
        cell.label.attributedStringValue = text
        cell.closeButton.contentTintColor = theme.lineNumber
        cell.dot.layer?.backgroundColor = settings.terminalListIcon.cgColor
        cell.dot.isHidden = !session.needsAttention
        let run = TerminalGroups.members(of: row, tags: tags)
        cell.groupPosition = run.count == 1 ? .none : row == run.lowerBound ? .first : row == run.upperBound - 1 ? .last : .middle
        cell.toolTip = "\(session.name) — \(session.detail)\nDouble-click to rename" + (run.count > 1 ? "\nSplit with \(run.count - 1) other\(run.count > 2 ? "s" : "")" : "")
        cell.onClose = { [weak self, weak session] in
            guard let self, let session, let index = self.sessions.firstIndex(where: { $0 === session }) else { return }
            self.remove(at: index)
        }
    }

    // MARK: Dragging a terminal up or down the list

    /// What a dragged row puts on the pasteboard; `loadView` registers the list for it.
    static let rowType = NSPasteboard.PasteboardType("com.aagicorp.feather.terminal-row")

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: TerminalPaneController.rowType)
        return item
    }

    /// How many drags began and how many drops were taken: the harness drives the list with mouse events.
    private(set) static var dragsBegun = 0, drops = 0
    var dragsBegunForTests: Int { TerminalPaneController.dragsBegun }
    var dropsForTests: Int { TerminalPaneController.drops }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        TerminalPaneController.dragsBegun += 1
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === tableView else { return [] }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let text = info.draggingPasteboard.string(forType: TerminalPaneController.rowType), let from = Int(text) else { return false }
        TerminalPaneController.drops += 1
        return move(terminalAt: from, to: row)
    }

    /// A row dropped just outside the list, which is exactly as tall as its rows so the pointer easily overshoots:
    /// above it lands at the top, below it at the end. Called by TerminalPaneView.
    func dropOutsideList(_ info: NSDraggingInfo, at point: NSPoint) -> Bool {
        guard let text = info.draggingPasteboard.string(forType: TerminalPaneController.rowType), let from = Int(text) else { return false }
        let list = listScroll.frame
        guard point.x >= list.minX - 8, point.x <= list.maxX + 8 else { return false }
        TerminalPaneController.drops += 1
        return move(terminalAt: from, to: point.y > list.midY ? 0 : sessions.count)
    }

    /// Moves the terminal at `from` so that it sits at `to` (an index in the list before the move, as a drop row
    /// is). The terminal showing stays the one showing. False when nothing would change.
    @discardableResult
    func move(terminalAt from: Int, to: Int) -> Bool {
        guard let order = TerminalGroups.reorder(tags: tags, from: from, to: to) else { return false }
        let current = self.current
        sessions = order.map { sessions[$0] }
        selectedIndex = sessions.firstIndex { $0 === current } ?? 0
        reloadList()
        return true
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("TerminalListRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? TerminalListRowView ?? {
            let view = TerminalListRowView()
            view.identifier = identifier
            return view
        }()
        view.isShowing = sessions.indices.contains(row) && visibleSessions.contains { $0 === sessions[row] }
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingList, sessions.indices.contains(listTable.selectedRow), listTable.selectedRow != selectedIndex else { return }
        select(listTable.selectedRow)
        focus()
    }

    /// The colours a terminal can be given, as VS Code offers them: the terminal's own ANSI colours.
    static let rowColors: [(name: String, color: NSColor)] = [
        ("Red", NSColor(hex: 0xF14C4C)), ("Green", NSColor(hex: 0x23D18B)), ("Yellow", NSColor(hex: 0xF5F543)),
        ("Blue", NSColor(hex: 0x3B8EEA)), ("Magenta", NSColor(hex: 0xD670D6)), ("Cyan", NSColor(hex: 0x29B8DB)),
        ("White", NSColor(hex: 0xE5E5E5))]
    static let rowIcons: [(name: String, symbol: String)] = [
        ("Terminal", "terminal"), ("Assistant", "sparkles"), ("Run", "play.fill"), ("Server", "server.rack"),
        ("Web", "globe"), ("Build", "hammer"), ("Tests", "checkmark.circle"), ("Debug", "ladybug"),
        ("Database", "cylinder"), ("Package", "shippingbox"), ("Git", "arrow.triangle.branch"), ("Bolt", "bolt")]

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menuRow = targetRow
        let session = sessions.indices.contains(menuRow) ? sessions[menuRow] : nil
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("Rename…", #selector(renameClicked))
        if session?.isTask == false { add("Split Terminal", #selector(splitClickedRow)) }

        let colors = NSMenu(title: "Change Color")
        for (index, entry) in TerminalPaneController.rowColors.enumerated() {
            let item = NSMenuItem(title: entry.name, action: #selector(colorChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = TerminalPaneController.swatch(entry.color)
            item.state = session?.customColor == entry.color ? .on : .off
            colors.addItem(item)
        }
        colors.addItem(.separator())
        let defaultColor = NSMenuItem(title: "Default", action: #selector(colorChosen(_:)), keyEquivalent: "")
        defaultColor.target = self
        defaultColor.tag = -1
        defaultColor.state = session?.customColor == nil ? .on : .off
        colors.addItem(defaultColor)
        let colorItem = NSMenuItem(title: "Change Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)

        let icons = NSMenu(title: "Change Icon")
        for (index, entry) in TerminalPaneController.rowIcons.enumerated() {
            let item = NSMenuItem(title: entry.name, action: #selector(iconChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: entry.name)
            item.state = session?.customIcon == entry.symbol ? .on : .off
            icons.addItem(item)
        }
        icons.addItem(.separator())
        let defaultIcon = NSMenuItem(title: "Automatic", action: #selector(iconChosen(_:)), keyEquivalent: "")
        defaultIcon.target = self
        defaultIcon.tag = -1
        defaultIcon.state = session?.customIcon == nil ? .on : .off
        icons.addItem(defaultIcon)
        let iconItem = NSMenuItem(title: "Change Icon", action: nil, keyEquivalent: "")
        iconItem.submenu = icons
        menu.addItem(iconItem)

        add("Kill Terminal", #selector(killClickedRow))
        menu.addItem(.separator())
        let new = NSMenuItem(title: "New Terminal", action: #selector(newTerminalClicked), keyEquivalent: "")
        new.target = self
        menu.addItem(new)
    }

    /// The row a context menu or double-click was on, else the one in front.
    var targetRow: Int { listTable.clickedRow >= 0 ? listTable.clickedRow : selectedIndex }

    /// Rename… in the context menu, and the list's double-click action.
    @objc func renameClicked() { beginRename(row: targetRow) }

    // MARK: Renaming in place


    /// A text field over the row's name, as the explorer renames files. Return keeps the name, Esc drops it,
    /// and so does clicking elsewhere (kept). An empty name goes back to the automatic one.
    func beginRename(row: Int) {
        endRename(commit: false)
        guard sessions.indices.contains(row), isViewLoaded,
              let cell = listTable.view(atColumn: 0, row: row, makeIfNecessary: false) as? TerminalRowView else { return }
        let theme = Settings.shared.theme
        let field = NSTextField(frame: NSRect(x: cell.label.frame.minX - 3, y: 2, width: cell.bounds.width - cell.label.frame.minX - 4,
                                              height: cell.bounds.height - 4))
        field.stringValue = sessions[row].customName ?? sessions[row].name
        field.font = .systemFont(ofSize: 12)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = theme.background
        field.textColor = theme.foreground
        field.wantsLayer = true
        field.layer?.borderWidth = 1
        field.layer?.borderColor = Settings.shared.terminalListIcon.cgColor
        field.usesSingleLineMode = true
        field.tag = row
        field.delegate = self
        cell.addSubview(field)
        renameField = field
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func endRename(commit: Bool) {
        guard let field = renameField else { return }
        renameField = nil                     // first: taking the field out ends its editing, which calls back here
        let row = field.tag
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        field.removeFromSuperview()
        if commit, sessions.indices.contains(row) { sessions[row].customName = name.isEmpty ? nil : name }
        needsReloadAfterRename = false
        reloadList()
        focus()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === renameField else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): endRename(commit: true)
        case #selector(NSResponder.cancelOperation(_:)): endRename(commit: false)
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === renameField { endRename(commit: true) }
    }

    @objc private func killClickedRow() { remove(at: targetRow) }

    @objc private func colorChosen(_ sender: NSMenuItem) {
        guard sessions.indices.contains(menuRow) else { return }
        sessions[menuRow].customColor = sender.tag < 0 ? nil : TerminalPaneController.rowColors[sender.tag].color
        reloadList()
    }

    @objc private func iconChosen(_ sender: NSMenuItem) {
        guard sessions.indices.contains(menuRow) else { return }
        sessions[menuRow].customIcon = sender.tag < 0 ? nil : TerminalPaneController.rowIcons[sender.tag].symbol
        reloadList()
    }

    /// A filled circle in the colour, for the Change Color menu.
    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

/// The pane's own view: it takes a terminal row dropped just above or below the list (the overshoot of a drag to
/// the top or the end), which the table, exactly as tall as its rows, would refuse.
final class TerminalPaneView: NSView {
    weak var controller: TerminalPaneController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([TerminalPaneController.rowType])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func isOurRow(_ sender: NSDraggingInfo) -> Bool {
        guard let controller else { return false }
        return sender.draggingSource as? NSTableView === controller.listTable
            && sender.draggingPasteboard.string(forType: TerminalPaneController.rowType) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { isOurRow(sender) ? .move : [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { isOurRow(sender) ? .move : [] }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isOurRow(sender), let controller else { return false }
        return controller.dropOutsideList(sender, at: convert(sender.draggingLocation, from: nil))
    }
}
