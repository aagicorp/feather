import AppKit

/// A non-activating list that floats under the caret; the text view keeps keyboard focus.
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onAccept: ((LSPCompletionItem) -> Void)?
    private(set) var items: [LSPCompletionItem] = []

    private let panel: NSPanel
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private static let rowHeight: CGFloat = 21
    private static let width: CGFloat = 420

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: CompletionPopup.width, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.width = CompletionPopup.width - 4
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = CompletionPopup.rowHeight
        tableView.intercellSpacing = .zero
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(acceptSelection)
        tableView.refusesFirstResponder = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.useFeatherScrollers()
        scrollView.drawsBackground = !Glass.isActive
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 6
        scrollView.layer?.borderWidth = Glass.isActive ? 0 : 1
        scrollView.layer?.masksToBounds = true
        surface = Glass.panel(around: scrollView, cornerRadius: 8, tint: Settings.shared.theme.chrome)
        panel.contentView = surface
    }

    private var surface: NSView!

    var isVisible: Bool { panel.isVisible }

    /// `caret` is the screen rect of the start of the word being completed.
    func show(_ newItems: [LSPCompletionItem], caret: NSRect, in window: NSWindow) {
        guard !newItems.isEmpty else { hide(); return }
        items = newItems
        let theme = Settings.shared.theme
        panel.appearance = window.appearance
        scrollView.backgroundColor = theme.chrome
        scrollView.layer?.borderColor = theme.border.cgColor
        Glass.retint(surface, theme.chrome)
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)

        let height = CGFloat(min(items.count, 9)) * CompletionPopup.rowHeight + 2
        var origin = NSPoint(x: caret.minX - 26, y: caret.minY - height - 3)
        if let screen = window.screen?.visibleFrame {
            if origin.y < screen.minY { origin.y = caret.maxY + 3 }
            origin.x = max(screen.minX, min(origin.x, screen.maxX - CompletionPopup.width))
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: CompletionPopup.width, height: height)), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        items = []
        tableView.reloadData()          // the table must never believe in rows that are gone
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let row = (tableView.selectedRow + delta + items.count) % items.count
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    @objc func acceptSelection() {
        let row = tableView.selectedRow
        guard items.indices.contains(row) else { return }
        let item = items[row]
        hide()
        onAccept?(item)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    private static func badge(for kind: Int) -> (String, NSColor) {
        switch kind {
        case 1: return ("ab", NSColor(hex: 0x9AA0A6))               // a word from the file
        case 2, 3, 4: return ("ƒ", NSColor(hex: 0xB180D7))          // method, function, constructor
        case 5, 6, 10, 21: return ("v", NSColor(hex: 0x75BEFF))     // field, variable, property, constant
        case 7, 8, 22, 13, 25: return ("T", NSColor(hex: 0xEE9D28)) // class, interface, struct, enum, type param
        case 9: return ("M", NSColor(hex: 0x9AA0A6))                // module
        case 14: return ("k", NSColor(hex: 0x569CD6))               // keyword
        case 15: return ("s", NSColor(hex: 0x9AA0A6))               // snippet
        case 17, 19: return ("f", NSColor(hex: 0x9AA0A6))           // file, folder
        default: return ("•", NSColor(hex: 0x9AA0A6))
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("CompletionCell")
        let label = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField ?? {
            let label = NSTextField(labelWithString: "")
            label.identifier = identifier
            label.lineBreakMode = .byTruncatingTail
            return label
        }()
        guard items.indices.contains(row) else { return label }
        let item = items[row]
        let theme = Settings.shared.theme
        let (symbol, color) = CompletionPopup.badge(for: item.kind)
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let text = NSMutableAttributedString(string: " \(symbol)  ", attributes: [.font: mono, .foregroundColor: color])
        text.append(NSAttributedString(string: item.label, attributes: [.font: mono, .foregroundColor: theme.foreground]))
        if let detail = item.detail, !detail.isEmpty {
            text.append(NSAttributedString(string: "   " + detail.replacingOccurrences(of: "\n", with: " "),
                                           attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: theme.lineNumber]))
        }
        label.attributedStringValue = text
        return label
    }
}
