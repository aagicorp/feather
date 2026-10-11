import AppKit

struct TabInfo: Equatable {
    let title: String
    let icon: NSImage?
    let toolTip: String?
    let isDirty: Bool

    static func == (a: TabInfo, b: TabInfo) -> Bool {
        a.title == b.title && a.icon === b.icon && a.toolTip == b.toolTip && a.isDirty == b.isDirty
    }
}

final class TabItemView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    /// Built when asked for, by the bar, which knows how many tabs there are and where this one stands.
    var contextMenu: (() -> NSMenu?)?

    /// What the view shows now, so a reload that changes nothing about this tab touches nothing.
    private var shown: (info: TabInfo, selected: Bool, theme: String)?

    init(info: TabInfo, selected: Bool, theme: Theme) {
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close"
        addSubview(closeButton)
        apply(info: info, selected: selected, theme: theme)
    }

    /// Shows another tab, or the same one in another state, in this view. The bar keeps its views across
    /// reloads: making a view per tab per reload meant forty tabs cost forty times forty views to open.
    func apply(info: TabInfo, selected: Bool, theme: Theme) {
        let look = theme.name + (Glass.isActive ? "+glass" : "")
        if let shown, shown.info == info, shown.selected == selected, shown.theme == look { return }
        let iconChanged = shown?.info.icon !== info.icon
        shown = (info, selected, look)
        layer?.backgroundColor = (selected ? Glass.surface(theme.background) : Glass.chrome(theme.chrome)).cgColor
        toolTip = info.toolTip
        if label.stringValue != info.title { label.stringValue = info.title }
        label.textColor = selected ? theme.foreground : theme.lineNumber
        if iconChanged { iconView.image = info.icon; needsLayout = true }
        iconView.alphaValue = selected ? 1 : 0.7
        closeButton.attributedTitle = NSAttributedString(
            string: info.isDirty ? "●" : "✕",
            attributes: [.foregroundColor: selected ? theme.foreground : theme.lineNumber,
                         .font: NSFont.systemFont(ofSize: info.isDirty ? 11 : 10)])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        // A file icon is 16 wide; a wider one (an API request's method) gets its own width.
        let iconWidth = iconView.image.map { max(16, min(44, $0.size.width * 16 / max($0.size.height, 1))) } ?? 0
        iconView.frame = NSRect(x: 10, y: (bounds.height - 16) / 2, width: iconWidth, height: 16)
        let labelX: CGFloat = iconWidth > 0 ? 10 + iconWidth + 5 : 12
        label.frame = NSRect(x: labelX, y: (bounds.height - 16) / 2, width: max(0, bounds.width - labelX - 26), height: 16)
        closeButton.frame = NSRect(x: bounds.width - 24, y: (bounds.height - 18) / 2, width: 18, height: 18)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return closeButton.frame.contains(local) ? closeButton : self
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    override func otherMouseDown(with event: NSEvent) { onClose?() }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

    @objc private func closeClicked() { onClose?() }
}

/// Scrolls sideways for an ordinary mouse wheel too, which only reports vertical movement.
private final class TabScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let documentView else {
            super.scrollWheel(with: event)
            return
        }
        let limit = max(0, documentView.frame.width - contentView.bounds.width)
        let x = max(0, min(limit, contentView.bounds.origin.x - event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10)))
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }
}

/// Tabs keep a readable width. When they no longer fit, the bar scrolls sideways (trackpad or mouse wheel)
/// and a chevron button lists every open tab.
final class TabBarView: NSView {
    static let height: CGFloat = 32
    private static let minTabWidth: CGFloat = 96
    private static let maxTabWidth: CGFloat = 240
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    // The right-click menu's bulk closes; each receives the index of the tab that was clicked.
    var onCloseOthers: ((Int) -> Void)?
    var onCloseToTheRight: ((Int) -> Void)?
    var onCloseAll: ((Int) -> Void)?
    /// "Open Changes": the git diff of the tab's file.
    var onOpenChanges: ((Int) -> Void)?
    /// Space kept free at the right edge for controls drawn over the bar.
    var trailingInset: CGFloat = 0
    private var items: [TabItemView] = []
    var itemViewsForTests: [TabItemView] { items }
    private var infos: [TabInfo] = []
    private var selectedIndex = -1
    private var revealSelection = false
    private var widths: [CGFloat] = []            // measured when the tabs change, not on every layout pass
    private var theme = Settings.shared.theme
    private let scrollView = TabScrollView()
    private let content = NSView()
    private let overflowButton = NSButton(title: "", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.documentView = content
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .allowed
        addSubview(scrollView)

        overflowButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Show all tabs")
        overflowButton.isBordered = false
        overflowButton.imageScaling = .scaleProportionallyDown
        overflowButton.toolTip = "Show all open tabs"
        overflowButton.target = self
        overflowButton.action = #selector(showAllTabs)
        overflowButton.isHidden = true
        addSubview(overflowButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func reload(tabs: [TabInfo], selected: Int) {
        let newTheme = Settings.shared.theme
        // Called on every document state change; most of those change nothing the bar shows.
        if tabs == infos, selected == selectedIndex, newTheme.name == theme.name, items.count == tabs.count { return }
        theme = newTheme
        widths = tabs.map(naturalWidth)
        // Only jump to the selected tab when the selection or the tab list changed, not on every dirty-dot update.
        revealSelection = revealSelection || selected != selectedIndex || tabs.count != infos.count
        infos = tabs
        selectedIndex = selected
        // The views stay; only their contents and count follow the tabs.
        while items.count > tabs.count { items.removeLast().removeFromSuperview() }
        for (index, info) in tabs.enumerated() {
            let item: TabItemView
            if index < items.count {
                item = items[index]
                item.apply(info: info, selected: index == selected, theme: theme)
            } else {
                item = TabItemView(info: info, selected: index == selected, theme: theme)
                content.addSubview(item)
                items.append(item)
            }
            item.onSelect = { [weak self] in self?.onSelect?(index) }
            item.onClose = { [weak self] in self?.onClose?(index) }
            item.contextMenu = { [weak self] in self?.contextMenu(forTabAt: index) }
        }
        overflowButton.contentTintColor = theme.lineNumber
        needsLayout = true
        needsDisplay = true
    }

    private func naturalWidth(_ info: TabInfo) -> CGFloat {
        let text = (info.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        // Icon and padding on the left, close button on the right, plus the label's own inner margins.
        let iconWidth = info.icon.map { max(16, min(44, $0.size.width * 16 / max($0.size.height, 1))) } ?? 0
        let chrome: CGFloat = (iconWidth > 0 ? 15 + iconWidth : 12) + 26 + 12
        return max(TabBarView.minTabWidth, min(TabBarView.maxTabWidth, ceil(text) + chrome))
    }

    override func layout() {
        super.layout()
        let total = widths.reduce(0, +)
        let overflowing = total > bounds.width - trailingInset
        overflowButton.isHidden = !overflowing
        let available = max(0, bounds.width - trailingInset - (overflowing ? 26 : 0))
        scrollView.frame = NSRect(x: 0, y: 1, width: available, height: bounds.height - 1)
        overflowButton.frame = NSRect(x: available + 4, y: (bounds.height - 16) / 2, width: 18, height: 16)

        let offset = scrollView.contentView.bounds.origin
        content.frame = NSRect(x: 0, y: 0, width: max(total, available), height: bounds.height - 1)
        var x: CGFloat = 0
        for (item, width) in zip(items, widths) {
            item.frame = NSRect(x: x, y: 0, width: width - 1, height: bounds.height - 1)
            x += width
        }
        // Rebuilding the tabs must not throw away where the user had scrolled to.
        let limit = max(0, content.frame.width - available)
        scrollView.contentView.scroll(to: NSPoint(x: max(0, min(limit, offset.x)), y: 0))
        if revealSelection, items.indices.contains(selectedIndex) {
            revealSelection = false
            content.scrollToVisible(items[selectedIndex].frame.insetBy(dx: -24, dy: 0))
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func showAllTabs() {
        let menu = NSMenu()
        for (index, info) in infos.enumerated() {
            let item = NSMenuItem(title: (info.isDirty ? "● " : "") + info.title, action: #selector(menuTabChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = info.icon
            item.toolTip = info.toolTip
            item.state = index == selectedIndex ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: overflowButton)
    }

    @objc private func menuTabChosen(_ sender: NSMenuItem) { onSelect?(sender.tag) }

    func contextMenu(forTabAt index: Int) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add("Close", #selector(menuClose(_:)))
        add("Close Others", #selector(menuCloseOthers(_:)), enabled: infos.count > 1)
        add("Close to the Right", #selector(menuCloseToTheRight(_:)), enabled: index < infos.count - 1)
        add("Close All", #selector(menuCloseAll(_:)))
        if onOpenChanges != nil, infos[index].toolTip != nil {
            menu.addItem(.separator())
            add("Open Changes", #selector(menuOpenChanges(_:)))
        }
        return menu
    }

    @objc private func menuOpenChanges(_ sender: NSMenuItem) { onOpenChanges?(sender.tag) }

    @objc private func menuClose(_ sender: NSMenuItem) { onClose?(sender.tag) }

    @objc private func menuCloseOthers(_ sender: NSMenuItem) { onCloseOthers?(sender.tag) }

    @objc private func menuCloseToTheRight(_ sender: NSMenuItem) { onCloseToTheRight?(sender.tag) }

    @objc private func menuCloseAll(_ sender: NSMenuItem) { onCloseAll?(sender.tag) }

    override func draw(_ dirtyRect: NSRect) {
        Glass.chrome(theme.chrome).setFill()
        bounds.fill()
        theme.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
