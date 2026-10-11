import AppKit

/// Underline tabs with a small pill after the title ("Params 1", "Body JSON"): the section bar of the request
/// editor, the way a modern API client draws it, with room for one text action at the right end.
final class APITabStrip: NSView {
    struct Item: Equatable {
        let title: String
        var badge: String? = nil
    }

    var items: [Item] = [] { didSet { if items != oldValue { rebuild() } } }
    var selectedIndex = 0 { didSet { if selectedIndex != oldValue { restyle() } } }
    var onSelect: ((Int) -> Void)?
    /// A text action at the right end ("Bulk edit"); hidden until it is given a title and shown.
    let trailingButton = NSButton(title: "", target: nil, action: nil)
    private let stack = NSStackView()
    private(set) var buttons: [APITabButton] = []

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        trailingButton.isBordered = false
        trailingButton.font = .systemFont(ofSize: 11)
        trailingButton.isHidden = true
        trailingButton.setContentHuggingPriority(.required, for: .horizontal)
        trailingButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [stack, trailingButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingButton.leadingAnchor, constant: -8),
            trailingButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            trailingButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func rebuild() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = items.enumerated().map { index, item in
            let button = APITabButton(title: item.title, badge: item.badge)
            button.tag = index
            button.target = self
            button.action = #selector(tabClicked(_:))
            stack.addArrangedSubview(button)
            return button
        }
        restyle()
    }

    private func restyle() {
        for (index, button) in buttons.enumerated() { button.isOn = index == selectedIndex }
        needsDisplay = true
    }

    @objc private func tabClicked(_ sender: APITabButton) {
        selectedIndex = sender.tag
        onSelect?(sender.tag)
    }

    func applyTheme() {
        buttons.forEach { $0.needsDisplay = true }
        trailingButton.contentTintColor = Settings.shared.theme.accent
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Settings.shared.theme.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// One tab of the strip: its title, the pill, and the accent line under it when it is the one showing.
final class APITabButton: NSButton {
    let titleText: String
    let badge: String?
    var isOn = false { didSet { needsDisplay = true } }
    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let badgeFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)

    init(title: String, badge: String?) {
        titleText = title
        self.badge = badge
        super.init(frame: .zero)
        self.title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        setAccessibilityLabel(badge.map { "\(title) \($0)" } ?? title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A click from code sends the action straight away: with no title and no bezel, AppKit's own `performClick`
    /// sends it on some systems (macOS 26) and not others (macOS 15), and the strip's tests click this way.
    override func performClick(_ sender: Any?) {
        guard isEnabled, let action else { return }
        _ = sendAction(action, to: target)
    }

    override var intrinsicContentSize: NSSize {
        var width = ceil((titleText as NSString).size(withAttributes: [.font: APITabButton.titleFont]).width) + 20
        if let badge { width += ceil((badge as NSString).size(withAttributes: [.font: APITabButton.badgeFont]).width) + 14 }
        return NSSize(width: width, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = Settings.shared.theme
        let colour = isOn ? theme.foreground : theme.lineNumber
        let title = NSAttributedString(string: titleText, attributes: [.font: APITabButton.titleFont, .foregroundColor: colour])
        let titleSize = title.size()
        var x: CGFloat = 10
        title.draw(at: NSPoint(x: x, y: floor((bounds.height - titleSize.height) / 2) + 1))
        x += titleSize.width + 6
        if let badge {
            let text = NSAttributedString(string: badge, attributes: [.font: APITabButton.badgeFont, .foregroundColor: colour])
            let size = text.size()
            let pill = NSRect(x: x, y: floor((bounds.height - 15) / 2) + 1, width: ceil(size.width) + 8, height: 15)
            colour.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 7.5, yRadius: 7.5).fill()
            text.draw(at: NSPoint(x: pill.minX + 4, y: pill.midY - size.height / 2))
        }
        if isOn {
            theme.accent.setFill()
            NSRect(x: 6, y: 0, width: bounds.width - 12, height: 2).fill()
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A rounded pill of text in a colour: the status of an answer, a count.
final class APIPill: NSView {
    var text = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var color = NSColor.labelColor { didSet { needsDisplay = true } }
    var font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

    override var intrinsicContentSize: NSSize {
        guard !text.isEmpty else { return NSSize(width: 0, height: 20) }
        return NSSize(width: ceil((text as NSString).size(withAttributes: [.font: font]).width) + 16, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        color.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = attributed.size()
        attributed.draw(at: NSPoint(x: floor((bounds.width - size.width) / 2), y: floor((bounds.height - size.height) / 2)))
    }
}
