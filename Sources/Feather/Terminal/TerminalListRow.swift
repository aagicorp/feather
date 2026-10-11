import AppKit

/// The strip with "TERMINAL" and the buttons. Double-click it to make the terminal fill the window and back,
/// as a panel's title does in VS Code.
final class TerminalHeaderView: NSView {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }
}

/// The row behind a terminal's name: the selected one carries a wash of the accent colour, so which terminal
/// is showing can be told at a glance, whatever the icon and text colours are set to. The other members of a
/// split group, on screen beside it, carry a fainter one.
final class TerminalListRowView: NSTableRowView {
    var isShowing = false

    override func drawSelection(in dirtyRect: NSRect) {
        Settings.shared.terminalListIcon.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isShowing, !isSelected else { return }
        Settings.shared.terminalListIcon.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

/// The line between the terminal and the list of terminals. Drag it to make the list wider or narrower.
final class ListResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?       // horizontal movement in points; negative is leftwards
    var onDragEnded: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        Settings.shared.theme.border.setFill()
        NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) {}       // claim the drag so the window does not move

    override func mouseDragged(with event: NSEvent) { onDrag?(event.deltaX) }

    override func mouseUp(with event: NSEvent) { onDragEnded?() }
}

/// A row in the terminal list: icon, name, folder, and a delete button. The members of a split group are set in
/// from the edge and joined by a bracket down their left, as a tree would show them.
final class TerminalRowView: NSTableCellView {
    enum GroupPosition { case none, first, middle, last }

    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    let closeButton = NSButton(title: "", target: nil, action: nil)
    /// Shown while the terminal has finished or asked something that the user has not seen yet.
    let dot = NSView()
    var onClose: (() -> Void)?
    var groupPosition = GroupPosition.none {
        didSet {
            iconLeading.constant = groupPosition == .none ? 6 : 20
            needsDisplay = true
        }
    }
    private var iconLeading: NSLayoutConstraint!

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard groupPosition != .none else { return }
        Settings.shared.theme.lineNumber.withAlphaComponent(0.7).setFill()
        let x: CGFloat = 10, midY = bounds.midY.rounded()
        let top = groupPosition == .first ? midY : bounds.maxY
        let bottom = groupPosition == .last ? midY : bounds.minY
        NSRect(x: x, y: bottom, width: 1, height: top - bottom).fill()
        NSRect(x: x, y: midY, width: 6, height: 1).fill()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = NSColor(hex: 0x3794FF).cgColor
        dot.isHidden = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7), dot.heightAnchor.constraint(equalToConstant: 7),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Kill terminal")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.toolTip = "Kill this terminal"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true                     // only while the pointer is over the row, as in VS Code
        for view in [icon, label, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        restingTrailing = label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        hoverTrailing = label.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6)
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6)
        NSLayoutConstraint.activate([
            iconLeading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            restingTrailing,
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var restingTrailing: NSLayoutConstraint!
    private var hoverTrailing: NSLayoutConstraint!
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
        closeButton.isHidden = !hovered
        restingTrailing.isActive = !hovered
        hoverTrailing.isActive = hovered
    }

    /// A row going back into the reuse pool must not keep its trash showing.
    override func prepareForReuse() {
        super.prepareForReuse()
        setHovered(false)
        groupPosition = .none
    }

    @objc private func closeClicked() { onClose?() }
}
