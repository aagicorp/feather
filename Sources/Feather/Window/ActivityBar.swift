import AppKit

/// The strip of icons down the left edge of the window, one per sidebar pane, as in VS Code. It stays when the
/// sidebar is hidden; clicking the lit icon hides the sidebar, clicking another shows that pane. Settings and
/// Extensions sit at the bottom.
final class ActivityBar: NSView {
    static let width: CGFloat = 46

    struct Item: Equatable {
        let symbol: String
        let tooltip: String
    }

    /// Called with the index of the icon clicked.
    var onSelect: ((Int) -> Void)?
    private(set) var items: [Item] = []
    private var buttons: [ActivityButton] = []
    private let stack = NSStackView()
    private let bottom = NSStackView()
    private var theme = Settings.shared.theme
    /// The project colour, when there is one; the icons pick black or white to suit it.
    var tint: NSColor? { didSet { if tint != oldValue { restyle() } } }
    /// Which icon is lit: the shown pane, dimmed to "none" while the sidebar is hidden.
    private var selected = 0
    private var isSidebarShown = true
    /// Counts shown on icons, by index: the number of changed files on Source Control, as VS Code has it.
    private var badges: [Int: Int] = [:]

    private var backdrop: Glass.Backdrop!
    var backdropForTests: Glass.Backdrop { backdrop }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: ActivityBar.width, height: 600))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        backdrop = Glass.backdrop(.sidebar, in: self)
        for column in [stack, bottom] {
            column.orientation = .vertical
            column.spacing = 0
            column.translatesAutoresizingMaskIntoConstraints = false
            addSubview(column)
        }
        let settings = ActivityButton(symbol: "gearshape", tooltip: "Settings (⌘,)")
        settings.target = NSApp.delegate
        settings.action = #selector(AppDelegate.showPreferences(_:))
        let extensions = ActivityButton(symbol: "puzzlepiece.extension", tooltip: "Extensions (a catalogue is coming; what is built in is listed)")
        extensions.target = NSApp.delegate
        extensions.action = #selector(AppDelegate.showExtensions(_:))
        bottom.addArrangedSubview(extensions)
        bottom.addArrangedSubview(settings)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: ActivityBar.width),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            bottom.leadingAnchor.constraint(equalTo: leadingAnchor), bottom.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: Settings.didChange, object: nil)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Replaces the icons; the lit one is kept by index when it still exists.
    func setItems(_ newItems: [Item]) {
        guard newItems != items else { return }
        items = newItems
        buttons.forEach { $0.removeFromSuperview() }
        buttons = newItems.enumerated().map { index, item in
            let button = ActivityButton(symbol: item.symbol, tooltip: item.tooltip)
            button.tag = index
            button.target = self
            button.action = #selector(clicked(_:))
            stack.addArrangedSubview(button)
            button.badge = badges[index] ?? 0
            return button
        }
        restyle()
    }

    /// Puts `count` on the icon at `index` (0 removes it); kept across `setItems`, so an extension pane arriving
    /// does not clear it.
    func setBadge(_ count: Int, at index: Int) {
        badges[index] = count
        guard buttons.indices.contains(index) else { return }
        buttons[index].badge = count
    }

    func badge(at index: Int) -> Int { badges[index] ?? 0 }

    func update(selected: Int, sidebarShown: Bool) {
        self.selected = selected
        isSidebarShown = sidebarShown
        restyle()
    }

    @objc private func clicked(_ sender: ActivityButton) { onSelect?(sender.tag) }

    @objc private func themeChanged() {
        let newTheme = Settings.shared.theme
        guard newTheme.name != theme.name else { return }
        theme = newTheme
        restyle()
    }

    private var ink: NSColor { tint.map { $0.isLight ? NSColor.black : NSColor.white } ?? theme.foreground }

    private func restyle() {
        let ground = tint ?? theme.chrome
        backdrop.tint(ground, solid: tint != nil)
        // The badge is the accent on the plain bar; on a project colour it is the ink, with the colour as its text,
        // so it stands out whatever the colour is.
        let badge = tint.map { ActivityButton.BadgeStyle(fill: ink, text: $0, ring: ground) }
            ?? ActivityButton.BadgeStyle(fill: theme.accent, text: .white, ring: ground)
        for (index, button) in buttons.enumerated() {
            button.isLit = isSidebarShown && index == selected
            button.apply(ink: ink, badge: badge)
        }
        for case let button as ActivityButton in bottom.arrangedSubviews { button.apply(ink: ink, badge: badge) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // The backdrop paints the ground; only the dividing line is drawn here.
        guard tint == nil else { return }
        theme.border.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}

/// One icon: dimmed until hovered, full and marked with a bar down its left edge while its pane is showing.
/// A count, when it has one, sits in a pill over the icon's bottom-right corner, as VS Code's badges do.
final class ActivityButton: NSButton {
    struct BadgeStyle {
        let fill: NSColor, text: NSColor, ring: NSColor
    }

    var isLit = false { didSet { needsDisplay = true } }
    var badge = 0 {
        didSet {
            guard badge != oldValue else { return }
            needsDisplay = true
            let tooltip = badge > 0 ? "\(baseTooltip) — \(badge) \(badge == 1 ? "change" : "changes")" : baseTooltip
            toolTip = tooltip
            setAccessibilityLabel(tooltip)
        }
    }
    private var isHovered = false { didSet { needsDisplay = true } }
    private var ink = Settings.shared.theme.foreground
    private var badgeStyle = BadgeStyle(fill: Settings.shared.theme.accent, text: .white, ring: Settings.shared.theme.chrome)
    private let symbol: String
    private let baseTooltip: String

    /// What the pill says: the count, or "99+" past two digits, since the pill must stay smaller than the icon.
    static func badgeText(_ count: Int) -> String { count > 99 ? "99+" : String(count) }

    init(symbol: String, tooltip: String) {
        self.symbol = symbol
        baseTooltip = tooltip
        super.init(frame: NSRect(x: 0, y: 0, width: ActivityBar.width, height: 42))
        isBordered = false
        title = ""
        toolTip = tooltip
        setAccessibilityLabel(tooltip)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: ActivityBar.width), heightAnchor.constraint(equalToConstant: 42)])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(ink: NSColor, badge: BadgeStyle) {
        self.ink = ink
        badgeStyle = badge
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let ink = isLit || isHovered ? self.ink : self.ink.withAlphaComponent(0.45)
        if isLit {
            self.ink.setFill()
            NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 19, weight: .regular).applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let size = image.size
        image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        guard badge > 0 else { return }
        let text = ActivityButton.badgeText(badge) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8.5, weight: .bold), .foregroundColor: badgeStyle.text]
        let textSize = text.size(withAttributes: attributes)
        let height: CGFloat = 13
        let width = max(height, ceil(textSize.width) + 7)
        // A small pill on the icon's lower-right corner (the view is flipped: y grows downwards), as VS Code
        // places it, covering only the corner so the icon still reads; a ring of the bar's colour sets it apart.
        let pill = NSRect(x: bounds.width / 2 + 14 - width, y: bounds.height / 2 + 2, width: width, height: height)
        badgeStyle.ring.setFill()
        NSBezierPath(roundedRect: pill.insetBy(dx: -1.5, dy: -1.5), xRadius: height / 2 + 1.5, yRadius: height / 2 + 1.5).fill()
        badgeStyle.fill.setFill()
        NSBezierPath(roundedRect: pill, xRadius: height / 2, yRadius: height / 2).fill()
        text.draw(at: NSPoint(x: pill.midX - textSize.width / 2, y: pill.midY - textSize.height / 2), withAttributes: attributes)
    }
}
