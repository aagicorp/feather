import AppKit

/// The strip across the top of the window, in the space the title bar would take. It is part of the content
/// view (`fullSizeContentView`), so it is 30 points tall rather than a toolbar's 38, it draws the project colour
/// itself in every mode, and it stays in place in full screen when the system title bar slides away.
///
/// Left: Back and Forward. Middle: the project's name, which is also the file search. Right: the layout buttons,
/// which show and hide the sidebar and the terminal, as the icons at the right of VS Code's title bar do.
final class HeaderBar: NSView {
    static let height: CGFloat = 30
    /// Room for the close, minimise and zoom buttons, which the system draws over the left end of this view.
    static let trafficLightInset: CGFloat = 78

    let back = NSButton()
    let forward = NSButton()
    let search = TitleSearchButton()
    let sidebarToggle = NSButton()
    let terminalToggle = NSButton()

    /// The project colour, when there is one; otherwise the theme's chrome colour with a hair line under it.
    var tint: NSColor? { didSet { if tint != oldValue { needsDisplay = true; restyle() } } }
    private var theme = Settings.shared.theme
    private var leading: NSLayoutConstraint!
    private var searchWidth: NSLayoutConstraint!

    /// In full screen there are no window buttons to keep clear of.
    var isFullScreen = false {
        didSet { leading.constant = isFullScreen ? 12 : HeaderBar.trafficLightInset }
    }

    private var backdrop: Glass.Backdrop!
    var backdropForTests: Glass.Backdrop { backdrop }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 1200, height: HeaderBar.height))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        backdrop = Glass.backdrop(.titlebar, in: self)
        for (button, symbol, tip) in [(back, "arrow.left", "Go Back (⌃-)"), (forward, "arrow.right", "Go Forward (⌃⇧-)"),
                                      (sidebarToggle, "sidebar.left", "Show or Hide the Sidebar (⌘B)"),
                                      (terminalToggle, "rectangle.bottomhalf.inset.filled", "Show or Hide the Terminal (⌘J)")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = tip
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        let left = NSStackView(views: [back, forward])
        left.spacing = 2
        let right = NSStackView(views: [sidebarToggle, terminalToggle])
        right.spacing = 4
        for stack in [left, right] {
            stack.orientation = .horizontal
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
        }
        addSubview(search)
        leading = left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HeaderBar.trafficLightInset)
        // Centred in the window when there is room; pushed right of the arrows when there is not.
        let centred = search.centerXAnchor.constraint(equalTo: centerXAnchor)
        centred.priority = .defaultHigh
        searchWidth = search.widthAnchor.constraint(equalToConstant: 380)
        searchWidth.priority = .defaultHigh - 1
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: HeaderBar.height),
            leading,
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            search.centerYAnchor.constraint(equalTo: centerYAnchor),
            centred, searchWidth,
            search.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 12),
            search.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -12),
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var onDark: Bool { tint.map { !$0.isLight } ?? theme.isDark }

    /// The ink for icons on this background, dimmed when `enabled` is false.
    private func ink(_ enabled: Bool) -> NSColor {
        (onDark ? NSColor.white : NSColor.black).withAlphaComponent(enabled ? 0.85 : 0.35)
    }

    func update(folderName: String, canGoBack: Bool, canGoForward: Bool) {
        let newTheme = Settings.shared.theme
        if newTheme.name != theme.name { theme = newTheme; needsDisplay = true }
        search.update(folderName: folderName, onDark: onDark)
        back.isEnabled = canGoBack
        forward.isEnabled = canGoForward
        back.contentTintColor = ink(canGoBack)
        forward.contentTintColor = ink(canGoForward)
        restyle()
    }

    /// The layout buttons read as "lit" while their pane is showing.
    func update(sidebarShown: Bool, terminalShown: Bool, terminalOnRight: Bool) {
        sidebarShown_ = sidebarShown
        terminalShown_ = terminalShown
        let symbol = terminalOnRight ? "rectangle.righthalf.inset.filled" : "rectangle.bottomhalf.inset.filled"
        terminalToggle.image = NSImage(systemSymbolName: symbol, accessibilityDescription: terminalToggle.toolTip)
        restyle()
    }

    private var sidebarShown_ = true
    private var terminalShown_ = false

    private func restyle() {
        // A dimmed tint colour is not honoured for a template image; the button's own alpha is.
        for (button, shown) in [(sidebarToggle, sidebarShown_), (terminalToggle, terminalShown_)] {
            button.contentTintColor = ink(true)
            button.alphaValue = shown ? 1 : 0.4
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        backdrop.tint(tint ?? theme.chrome)          // the backdrop paints the ground
        guard tint == nil else { return }
        theme.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    // The bar stands where the title bar was, so it behaves like one: drag to move, double-click to zoom.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window.performMiniaturize(nil) } else if action != "None" { window.performZoom(nil) }
            return
        }
        window.performDrag(with: event)
    }
}

/// The box in the middle of the header: it names the project and opens file search when clicked.
final class TitleSearchButton: NSButton {
    private var folderName = "Feather"
    private var onDark = true

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 22))
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        toolTip = "Search files by name (⌘P). Type # for a symbol anywhere in the project, @ for one in this file, : for a line."
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(folderName: String, onDark: Bool) {
        guard folderName != self.folderName || onDark != self.onDark else { return }
        self.folderName = folderName
        self.onDark = onDark
        render()
    }

    private func render() {
        let ink = onDark ? NSColor.white : NSColor.black
        layer?.backgroundColor = ink.withAlphaComponent(0.10).cgColor
        layer?.borderColor = ink.withAlphaComponent(0.14).cgColor
        let attachment = NSTextAttachment()
        let configuration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink.withAlphaComponent(0.7)]))
        attachment.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        attachment.bounds = NSRect(x: 0, y: -2, width: 12, height: 12)
        let title = NSMutableAttributedString(attachment: attachment)
        title.append(NSAttributedString(string: "  " + folderName, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: ink.withAlphaComponent(0.88)]))
        attributedTitle = title
    }
}
