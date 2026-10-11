import AppKit

/// One action offered on the rows of a list two ways: a small button that appears at the right of the row under
/// the pointer, and an item in the row's context menu. A single button is moved from row to row, so the rows
/// themselves stay the plain labels they were and a list of thousands costs nothing extra.
final class RowHoverAction: NSObject, NSMenuDelegate {
    private weak var table: NSTableView?
    /// What the button and menu item say for a row; a list whose rows are of two kinds names the action differently on each.
    private let title: (Int) -> String
    private let isEligible: (Int) -> Bool
    private let perform: (Int) -> Void
    private let button = NSButton(title: "", target: nil, action: nil)
    private var hoveredRow = -1
    /// Turns the button and the menu off altogether, for an action that only applies while a mode is on.
    var isEnabled = true { didSet { if !isEnabled { hide() } } }

    convenience init(table: NSTableView, title: String, toolTip: String, isEligible: @escaping (Int) -> Bool, perform: @escaping (Int) -> Void) {
        self.init(table: table, toolTip: toolTip, title: { _ in title }, isEligible: isEligible, perform: perform)
    }

    init(table: NSTableView, toolTip: String, title: @escaping (Int) -> String, isEligible: @escaping (Int) -> Bool, perform: @escaping (Int) -> Void) {
        self.table = table
        self.title = title
        self.isEligible = isEligible
        self.perform = perform
        super.init()
        button.title = title(0)
        button.bezelStyle = .recessed
        button.controlSize = .small
        button.font = .systemFont(ofSize: 10.5, weight: .medium)
        button.toolTip = toolTip
        button.target = self
        button.action = #selector(buttonClicked)
        button.isHidden = true
        button.sizeToFit()
        table.addSubview(button)
        // `inVisibleRect` keeps the area matched to what is on screen, so it never needs rebuilding.
        table.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                             owner: self, userInfo: nil))
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        NotificationCenter.default.addObserver(self, selector: #selector(hide), name: NSView.boundsDidChangeNotification,
                                               object: table.enclosingScrollView?.contentView)
    }

    @objc func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    @objc func mouseMoved(with event: NSEvent) {
        guard let table else { return }
        let row = table.row(at: table.convert(event.locationInWindow, from: nil))
        guard row != hoveredRow || button.isHidden else { return }
        guard isEnabled, row >= 0, isEligible(row) else { return hide() }
        hoveredRow = row
        place()
    }

    @objc func mouseExited(with event: NSEvent) { hide() }

    /// Scrolling and reloading move the rows out from under the button.
    @objc func hide() {
        hoveredRow = -1
        button.isHidden = true
    }

    private func place() {
        guard let table, hoveredRow >= 0, hoveredRow < table.numberOfRows else { return hide() }
        let rowRect = table.rect(ofRow: hoveredRow)
        let visible = table.visibleRect
        let wanted = title(hoveredRow)
        if button.title != wanted {
            button.title = wanted
            button.sizeToFit()
        }
        let size = button.frame.size
        button.frame = NSRect(x: visible.maxX - size.width - 6, y: rowRect.midY - size.height / 2, width: size.width, height: size.height)
        if button.superview !== table || table.subviews.last !== button { table.addSubview(button) }       // above the row views
        button.isHidden = false
    }

    @objc private func buttonClicked() {
        let row = hoveredRow
        hide()
        if row >= 0 { perform(row) }
    }

    /// For tests and the keyboard: the same thing the button and the menu item do.
    func trigger(row: Int) {
        if isEnabled, isEligible(row) { perform(row) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard isEnabled, let table, table.clickedRow >= 0, isEligible(table.clickedRow) else { return }
        let item = NSMenuItem(title: title(table.clickedRow), action: #selector(menuClicked), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func menuClicked() {
        guard let table, table.clickedRow >= 0 else { return }
        perform(table.clickedRow)
    }
}
