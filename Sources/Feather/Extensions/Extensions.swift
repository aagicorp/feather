import AppKit

/// An optional part of Feather that is off until the person switches it on in Feather ▸ Extensions. While off it
/// costs nothing: no menu, no sidebar pane, no object. Switched on, `activate(in:)` runs for every open window
/// (and for each window opened later); switched off, `deactivate(in:)` takes it all away again.
///
/// Extensions are compiled into the app rather than loaded from bundles: Feather is notarized with the hardened
/// runtime, which is at odds with loading outside code, and a plugin API would need to be stable before anyone
/// could build against it. This protocol is the seam for that later: an external bundle would conform to it.
protocol FeatherExtension: AnyObject {
    /// Stable, folder-safe, never shown ("api-client").
    static var id: String { get }
    static var name: String { get }
    /// One sentence for the Extensions list.
    static var summary: String { get }
    /// What switching it on adds, for the list ("A sidebar pane", "A Requests menu").
    static var adds: [String] { get }
    /// SF Symbol name for the list.
    static var symbol: String { get }
    init()
    func activate(in window: MainWindowController)
    func deactivate(in window: MainWindowController)
    /// A top-level menu to add to the menu bar while the extension is on, or nil.
    func makeMenu() -> NSMenu?
}

/// The extensions Feather ships, which of them are on, and the live instance of each one that is.
final class ExtensionRegistry {
    static let shared = ExtensionRegistry()
    static let didChange = Notification.Name("FeatherExtensionsDidChange")

    /// Everything that can be switched on, in the order the Extensions window lists them.
    let available: [FeatherExtension.Type] = [APIClientExtension.self]

    private var instances: [String: FeatherExtension] = [:]
    /// The windows extensions have been activated in, so a switch reaches all of them.
    private var windows: [() -> MainWindowController?] = []

    private init() {}

    func isEnabled(_ type: FeatherExtension.Type) -> Bool { Settings.shared.enabledExtensions.contains(type.id) }

    /// The live instance, when on.
    func instance(_ type: FeatherExtension.Type) -> FeatherExtension? { instances[type.id] }

    func instance<T: FeatherExtension>(of type: T.Type) -> T? { instances[type.id] as? T }

    func setEnabled(_ type: FeatherExtension.Type, _ enabled: Bool) {
        guard enabled != isEnabled(type) else { return }
        var ids = Settings.shared.enabledExtensions
        if enabled { ids.append(type.id) } else { ids.removeAll { $0 == type.id } }
        Settings.shared.enabledExtensions = ids
        if enabled {
            let instance = type.init()
            instances[type.id] = instance
            for window in liveWindows { instance.activate(in: window) }
        } else if let instance = instances.removeValue(forKey: type.id) {
            for window in liveWindows { instance.deactivate(in: window) }
        }
        NotificationCenter.default.post(name: ExtensionRegistry.didChange, object: nil)
        (NSApp.delegate as? AppDelegate)?.rebuildMenu()
    }

    private var liveWindows: [MainWindowController] {
        windows = windows.filter { $0() != nil }
        return windows.compactMap { $0() }
    }

    /// A window that has finished building itself: everything switched on comes alive in it. The first window
    /// also brings the menu bar up to date, since it was built before any extension existed.
    func windowDidOpen(_ window: MainWindowController) {
        windows.append { [weak window] in window }
        var createdOne = false
        for type in available where isEnabled(type) {
            let instance = instances[type.id] ?? {
                let made = type.init()
                instances[type.id] = made
                createdOne = true
                return made
            }()
            instance.activate(in: window)
        }
        if createdOne { (NSApp.delegate as? AppDelegate)?.rebuildMenu() }
    }

    func windowWillClose(_ window: MainWindowController) {
        for instance in instances.values { instance.deactivate(in: window) }
        windows = windows.filter { $0() !== window && $0() != nil }
    }

    /// The menus of the extensions that are on, for the menu bar (before Window).
    func menuItems() -> [NSMenuItem] {
        available.compactMap { type -> NSMenuItem? in
            guard let menu = instances[type.id]?.makeMenu() else { return nil }
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            return item
        }
    }
}

// MARK: - Feather ▸ Extensions…

/// The list of optional features with a switch each. Nothing here loads an extension; the switch does.
final class ExtensionsWindowController: NSWindowController {
    private var switches: [String: NSSwitch] = [:]
    private(set) var comingSoonForTests: NSView?
    var switchesForTests: [String: NSSwitch] { switches }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Extensions"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        window.center()
        NotificationCenter.default.addObserver(self, selector: #selector(sync), name: ExtensionRegistry.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        guard let content = window?.contentView else { return }
        // The catalogue is not here yet: what it will be, in a card at the top; the built-in parts under it.
        let soonIcon = NSImageView(image: NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil) ?? NSImage())
        soonIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .light)
        soonIcon.contentTintColor = .controlAccentColor
        let soonEyebrow = NSTextField(labelWithString: "COMING SOON")
        soonEyebrow.font = .systemFont(ofSize: 10.5, weight: .semibold)
        soonEyebrow.textColor = .controlAccentColor
        let soonTitle = NSTextField(labelWithString: "A catalogue of extensions")
        soonTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        let soonText = NSTextField(wrappingLabelWithString: "Language support (TypeScript, Python, Java, Go, Rust and more, each with its checking and suggestions), tools and integrations, from Feather and from the community, will be listed here and install with one click, as in VS Code. The catalogue needs a home on the web first; it is on its way. Until then, what is built in is below, and a language server already on this Mac is used as it is.")
        soonText.font = .systemFont(ofSize: 12)
        soonText.textColor = .secondaryLabelColor
        let soonColumn = NSStackView(views: [soonEyebrow, soonTitle, soonText])
        soonColumn.orientation = .vertical
        soonColumn.alignment = .leading
        soonColumn.spacing = 4
        let soon = NSStackView(views: [soonIcon, soonColumn])
        soon.alignment = .top
        soon.spacing = 14
        soon.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        soon.wantsLayer = true
        soon.layer?.cornerRadius = 10
        soon.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        soonText.widthAnchor.constraint(equalToConstant: 400).isActive = true
        comingSoonForTests = soon
        let intro = NSTextField(labelWithString: "BUILT IN")
        intro.textColor = .secondaryLabelColor
        intro.font = .systemFont(ofSize: 10.5, weight: .semibold)
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        for type in ExtensionRegistry.shared.available {
            let icon = NSImageView(image: NSImage(systemSymbolName: type.symbol, accessibilityDescription: type.name) ?? NSImage())
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            icon.contentTintColor = .controlAccentColor
            icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
            let name = NSTextField(labelWithString: type.name)
            name.font = .systemFont(ofSize: 14, weight: .semibold)
            let summary = NSTextField(wrappingLabelWithString: type.summary)
            summary.font = .systemFont(ofSize: 12)
            let adds = NSTextField(wrappingLabelWithString: "Adds: " + type.adds.joined(separator: " · "))
            adds.font = .systemFont(ofSize: 11)
            adds.textColor = .secondaryLabelColor
            let text = NSStackView(views: [name, summary, adds])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 3
            let toggle = NSSwitch()
            toggle.identifier = NSUserInterfaceItemIdentifier(type.id)
            toggle.target = self
            toggle.action = #selector(toggled(_:))
            switches[type.id] = toggle
            let row = NSStackView(views: [icon, text, toggle])
            row.alignment = .top
            row.spacing = 12
            text.widthAnchor.constraint(equalToConstant: 380).isActive = true
            rows.addArrangedSubview(row)
        }
        let column = NSStackView(views: [soon, intro, rows])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 18
        column.setCustomSpacing(8, after: intro)
        soon.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            column.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])
        sync()
    }

    @objc private func sync() {
        for type in ExtensionRegistry.shared.available {
            switches[type.id]?.state = ExtensionRegistry.shared.isEnabled(type) ? .on : .off
        }
    }

    @objc private func toggled(_ sender: NSSwitch) {
        guard let type = ExtensionRegistry.shared.available.first(where: { $0.id == sender.identifier?.rawValue }) else { return }
        ExtensionRegistry.shared.setEnabled(type, sender.state == .on)
    }

    override func showWindow(_ sender: Any?) {
        sync()
        super.showWindow(sender)
    }
}

/// A sidebar pane an extension adds. `paneDidAppear` is called each time it is shown, like the built-in panes'.
protocol ExtensionPane: NSViewController {
    func paneDidAppear()
}
