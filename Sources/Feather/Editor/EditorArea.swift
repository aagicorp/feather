import AppKit

/// One tab: a view onto a document. The same document can appear in a tab of each editor group.
final class EditorTab {
    let document: TextDocument

    /// An editor is a text view, the layout of the whole file, its colours and a gutter: by far the heaviest thing a
    /// tab owns. So it is built when the tab is first shown, and given up again once the tab has sat in the
    /// background for a while. Everything that must outlive it (text, undo, dirty flag, diagnostics, git base) is on
    /// the document.
    private var loadedEditor: EditorView?
    /// Connects a newly built editor to its group. It runs for every editor this tab builds, not just the first.
    private let wire: (EditorView) -> Void
    /// Cursor and scroll position of the editor that was released, for the next one to take up.
    private var viewState: EditorViewState?
    /// When the group last showed this tab, in the group's own counting; the oldest editors are released first.
    var lastShown = 0

    init(document: TextDocument, wire: @escaping (EditorView) -> Void) {
        self.document = document
        self.wire = wire
    }

    /// The tab's editor, built if need be. Anything that walks over all tabs should use `editorIfLoaded` instead.
    var editor: EditorView {
        if let loadedEditor { return loadedEditor }
        let editor = EditorView(document: document)
        // A media tab shows a viewer and has no text. Callers outside the group still ask any tab for its cursor and
        // diagnostics; they get an empty editor that is gone again as soon as they have their answer.
        if document.isMedia { return editor }
        if let viewState { editor.restore(viewState) }
        wire(editor)
        loadedEditor = editor
        return editor
    }

    var editorIfLoaded: EditorView? { loadedEditor }
    var isEditorLoaded: Bool { loadedEditor != nil }

    func releaseEditor() {
        guard let editor = loadedEditor else { return }
        viewState = editor.viewState
        editor.removeFromSuperview()
        loadedEditor = nil
    }

    /// Where the user is in this tab, whether or not it has an editor right now. A closed tab leaves this
    /// behind, and a reopened one is given it back.
    var place: EditorViewState? {
        get { loadedEditor?.viewState ?? viewState }
        set {
            viewState = newValue
            if let newValue { loadedEditor?.restore(newValue) }
        }
    }

    var url: URL? { document.url }
    var isDirty: Bool { document.isDirty }
    var encoding: String.Encoding { document.encoding }
    var title: String { document.title }

    /// A settings change arrived while this tab was in the background; it is applied when the tab is shown.
    var needsSettings = false
    /// Set while this tab shows something other than the source: rendered Markdown, a drawn SVG, or a media file.
    var preview: TabPreview?
    var isPreviewing: Bool { preview != nil }
    /// A diff tab of a Markdown or SVG file is a diff, not something ⇧⌘V can turn into a rendering.
    private var isFileTab: Bool { document.displayTitle == nil }
    var isMarkdown: Bool { isFileTab && ["md", "markdown", "mdx"].contains(url?.pathExtension.lowercased() ?? "") }
    var isSVG: Bool { isFileTab && url?.pathExtension.lowercased() == "svg" }
    /// Files with both a source and a rendered form, which ⇧⌘V switches between.
    var canPreview: Bool { isMarkdown || isSVG }
}

/// One of the welcome screen's three steps: a wide row with a number, an icon, a title and a line of explanation.
/// It is a button, so it takes a click, the space bar and VoiceOver like any other.
final class WelcomeStepButton: NSButton {
    private let badge = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var theme = Settings.shared.theme
    private var isHovered = false { didSet { restyle() } }
    static let width: CGFloat = 420

    init(number: Int, symbol: String, title: String, detail: String) {
        super.init(frame: .zero)
        self.title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8                    // only the hover highlight has a shape; there is no card
        setAccessibilityLabel("Step \(number): \(title). \(detail)")
        badge.stringValue = "\(number)"
        badge.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        badge.alignment = .center
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13.5, weight: .medium)
        detailLabel.stringValue = detail
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [badge, iconView, text])
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 14),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 46),
            widthAnchor.constraint(equalToConstant: WelcomeStepButton.width),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The labels are decoration; the click belongs to the row.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func draw(_ dirtyRect: NSRect) {}           // the layer is the look; there is no bezel or title to draw

    override var isEnabled: Bool { didSet { restyle() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        restyle()
    }

    private func restyle() {
        let lit = isHovered && isEnabled
        layer?.backgroundColor = lit ? theme.selection.withAlphaComponent(theme.isDark ? 0.35 : 0.30).cgColor : NSColor.clear.cgColor
        badge.textColor = theme.lineNumber
        iconView.contentTintColor = .controlAccentColor
        titleLabel.textColor = theme.foreground
        detailLabel.textColor = theme.lineNumber
        alphaValue = isEnabled ? 1 : 0.4
    }
}

/// What an empty window shows. It is written for someone whose code is written by an AI assistant: three plain
/// steps, then the projects they had open before. The list of shortcuts that used to be here is one click away,
/// in Help ▸ Keyboard Shortcuts, where it is generated from the menus and so is always right.
final class WelcomeView: NSView {
    var onOpenRecent: ((URL) -> Void)?
    var onOpenFolder: (() -> Void)?
    /// Added to MainWindowController by other parts of Feather; a step nobody answers is greyed out, not a beep.
    static let startAssistantAction = #selector(MainWindowController.startAIAssistant(_:))
    static let showActivityAction = #selector(MainWindowController.showActivity(_:))

    private let stack = NSStackView()
    /// The page scrolls when the editor is shorter than its content (the terminal dragged tall), instead of the
    /// top being cut off; with room to spare the content sits in the middle as before.
    private let scroll = NSScrollView()
    private let page = WelcomePage()
    var scrollViewForTests: NSScrollView { scroll }
    var stackForTests: NSStackView { stack }
    private let title = NSTextField(labelWithString: "Feather")
    private let tagline = NSTextField(labelWithString: "Watch, understand and run what your AI assistant builds.")
    private let recentStack = NSStackView()
    private var recentURLs: [URL] = []
    private(set) var steps: [WelcomeStepButton] = []
    private var links: [NSButton] = []
    private let versionLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        title.font = .systemFont(ofSize: 30, weight: .light)
        tagline.font = .systemFont(ofSize: 13)
        stack.orientation = .vertical
        stack.spacing = 8
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(4, after: title)
        stack.addArrangedSubview(tagline)
        stack.setCustomSpacing(22, after: tagline)

        steps = [
            WelcomeStepButton(number: 1, symbol: "folder", title: "Open your project folder",
                              detail: "The folder your app lives in, or an empty one to start fresh."),
            WelcomeStepButton(number: 2, symbol: "sparkles", title: "Start your AI assistant",
                              detail: "Claude Code, Codex, Gemini, or any tool you choose."),
            WelcomeStepButton(number: 3, symbol: "play.rectangle", title: "Watch the changes and run your app",
                              detail: "See every file it touches, as it happens, and try the result."),
        ]
        for (index, step) in steps.enumerated() {
            step.tag = index
            step.target = self
            step.action = #selector(stepClicked(_:))
            stack.addArrangedSubview(step)
        }
        if let last = steps.last { stack.setCustomSpacing(24, after: last) }

        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 5
        stack.addArrangedSubview(recentStack)
        stack.setCustomSpacing(22, after: recentStack)

        // The version, and a way to the release notes, where someone who has just updated will look first.
        versionLabel.stringValue = ReleaseNotes.version.first?.isNumber == true ? "Version \(ReleaseNotes.version)" : "Development build"
        versionLabel.font = .systemFont(ofSize: 12)
        func dot() -> NSTextField {
            let label = NSTextField(labelWithString: "·")
            label.font = .systemFont(ofSize: 12)
            label.textColor = .tertiaryLabelColor
            return label
        }
        links = [("Keyboard Shortcuts", #selector(AppDelegate.showKeyboardShortcuts(_:))), ("What’s New", #selector(AppDelegate.showReleaseNotes(_:)))].map {
            let button = NSButton(title: "", target: nil, action: $0.1)
            button.isBordered = false
            button.attributedTitle = NSAttributedString(string: $0.0, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.controlAccentColor])
            return button
        }
        let linkRow = NSStackView(views: [links[0], dot(), links[1], dot(), versionLabel])
        linkRow.spacing = 8
        stack.addArrangedSubview(linkRow)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.useFeatherScrollers()
        scroll.documentView = page
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        page.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        let margin: CGFloat = 28
        // The page is as tall as the editor, or as tall as its content when that is more; the content is centred
        // when there is room (a wish), and never above the top margin (a rule).
        let centred = stack.centerYAnchor.constraint(equalTo: page.centerYAnchor)
        centred.priority = NSLayoutConstraint.Priority(700)
        let shortest = page.heightAnchor.constraint(equalToConstant: 0)
        shortest.priority = NSLayoutConstraint.Priority(1)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            page.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            page.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            page.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            page.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            page.bottomAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: margin),
            stack.topAnchor.constraint(greaterThanOrEqualTo: page.topAnchor, constant: margin),
            stack.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: page.widthAnchor, constant: -2 * margin),
            centred, shortest,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The scrolling page behind the welcome content: top-down, so a short editor shows the title first.
    private final class WelcomePage: NSView {
        override var isFlipped: Bool { true }
    }

    /// Who would carry out `action` for this window: the views above this one, then the window and its
    /// controller, then the app. The same walk `NSApp.target(forAction:)` makes, but from this window even when
    /// another window has the keyboard.
    private func target(for action: Selector) -> NSObject? {
        var responder: NSResponder? = self
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        let others: [NSObject?] = [window?.delegate as? NSObject, window?.windowController, NSApp, NSApp.delegate as? NSObject]
        return others.compactMap { $0 }.first { $0.responds(to: action) }
    }

    /// Steps two and three are carried out elsewhere; until someone can, they are shown greyed out.
    func validateSteps() {
        steps[1].isEnabled = target(for: WelcomeView.startAssistantAction) != nil
        steps[2].isEnabled = target(for: WelcomeView.showActivityAction) != nil
        for step in steps { step.toolTip = step.isEnabled ? nil : "Not available in this version of Feather" }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { validateSteps() }
    }

    @objc private func stepClicked(_ sender: NSButton) {
        switch sender.tag {
        case 0: onOpenFolder?()
        case 1: NSApp.sendAction(WelcomeView.startAssistantAction, to: target(for: WelcomeView.startAssistantAction), from: self)
        default:
            let window = self.window           // showing the pane may take this view off screen
            NSApp.sendAction(WelcomeView.showActivityAction, to: target(for: WelcomeView.showActivityAction), from: self)
            HintCards.showOnce(.activity, in: window)
        }
    }

    /// Rebuilt whenever the welcome screen is shown, so it always reflects the latest folders.
    private func reloadRecents(_ theme: Theme) {
        recentURLs = Array(Settings.shared.recentFolders.prefix(6))
        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        recentStack.isHidden = recentURLs.isEmpty
        guard !recentURLs.isEmpty else { return }
        let heading = NSTextField(labelWithString: "RECENT PROJECTS")
        heading.font = .systemFont(ofSize: 10.5, weight: .semibold)
        heading.textColor = theme.lineNumber
        recentStack.addArrangedSubview(heading)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for (index, url) in recentURLs.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(recentClicked(_:)))
            button.tag = index
            button.isBordered = false
            let parent = url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
            let title = NSMutableAttributedString(attributedString: FileIcon.attributed(for: url, isDirectory: true))
            title.append(NSAttributedString(string: url.lastPathComponent, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(hex: 0x4DA3FF)]))
            title.append(NSAttributedString(string: "   " + parent, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: theme.lineNumber]))
            button.attributedTitle = title
            button.toolTip = url.path
            // A long path is cut in the middle rather than stretching the page; the tooltip has all of it.
            button.cell?.lineBreakMode = .byTruncatingMiddle
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            recentStack.addArrangedSubview(button)
            button.widthAnchor.constraint(lessThanOrEqualToConstant: WelcomeStepButton.width).isActive = true
        }
    }

    /// The Recent rows, for whoever needs to press one without a mouse.
    var recentButtons: [NSButton] { recentStack.arrangedSubviews.compactMap { $0 as? NSButton } }

    @objc private func recentClicked(_ sender: NSButton) {
        guard recentURLs.indices.contains(sender.tag) else { return }
        onOpenRecent?(recentURLs[sender.tag])
    }

    func applyTheme(_ theme: Theme) {
        reloadRecents(theme)
        layer?.backgroundColor = Glass.paneBackground(theme.background)      // the panel behind paints it with glass
        title.textColor = theme.foreground
        tagline.textColor = theme.lineNumber
        versionLabel.textColor = theme.lineNumber
        steps.forEach { $0.applyTheme(theme) }
        validateSteps()
    }
}

/// One editor group: a tab bar and the editor for its selected tab.
final class EditorAreaViewController: NSViewController {
    /// Called whenever the tab list, selection, dirty state, or cursor changes.
    var onStateChange: (() -> Void)?
    var onRequestOpen: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?
    /// A file or folder was dropped on the editor.
    var onOpenDropped: ((URL) -> Void)?
    var onRun: (() -> Void)?
    var onFocus: ((EditorAreaViewController) -> Void)?
    /// The last tab was closed; secondary groups are removed when this happens.
    var onEmpty: ((EditorAreaViewController) -> Void)?
    /// (locations, symbol name)
    var onShowReferences: (([LSPLocation], String) -> Void)?
    /// Definitions open in whichever group is active, which the groups controller decides.
    var onOpenLocation: ((LSPLocation) -> Void)?

    let store: DocumentStore
    var lsp: LSPManager { store.lsp }
    /// Files whose tabs were closed, most recent last, for Reopen Closed Tab. Only a path and a place are kept.
    var closedTabs: [(url: URL, place: EditorViewState?)] = []
    static let closedTabLimit = 20
    lazy var symbolPanel = FilterPanelController(placeholder: "Go to symbol in this file", size: NSSize(width: 560, height: 340))
    private(set) var tabs: [EditorTab] = []
    private(set) var selectedIndex = -1
    /// How many editors a group keeps besides the one in front. Going back to a recent tab is then instant, while
    /// thirty open tabs cost about as much memory as seven.
    static let backgroundEditorLimit = 6
    private var showCounter = 0
    /// Set while many files are opened at once; the group is drawn once at the end instead of once per file.
    private var isDeferringDisplay = false
    private let tabBar = TabBarView()
    private let container = NSView()
    private let breadcrumbs = BreadcrumbBar()
    private var finderCache: [String: LSPLocation?] = [:]
    private var finderCacheVersion = -1
    private var probeGeneration = 0
    private var breadcrumbHeight: NSLayoutConstraint!
    /// A view an extension puts between the path bar and the editor for some files: the API client's "send
    /// request" strip over a `.http` file. Keyed by the extension; asked whenever a tab is shown, and nil
    /// means nothing for that tab. Setting the dictionary re-asks every open group.
    static var accessoryProviders: [String: (EditorTab, EditorAreaViewController) -> NSView?] = [:] {
        didSet { NotificationCenter.default.post(name: accessoryProvidersDidChange, object: nil) }
    }
    static let accessoryProvidersDidChange = Notification.Name("FeatherEditorAccessoryProvidersDidChange")

    /// Asks every open group again, for a provider whose answer has changed (an extension that has just
    /// finished setting up in a window).
    static func refreshAccessories() { NotificationCenter.default.post(name: accessoryProvidersDidChange, object: nil) }
    private let accessoryHost = NSView()
    private var accessoryHeight: NSLayoutConstraint!
    private weak var accessoryTab: EditorTab?
    private weak var accessoryEditor: EditorView?
    private lazy var welcome: WelcomeView = {
        let view = WelcomeView()
        view.onOpenFolder = { [weak self] in self?.openClicked() }
        view.onOpenRecent = { [weak self] in self?.onOpenRecent?($0) }
        return view
    }()

    var currentTab: EditorTab? { tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil }

    init(store: DocumentStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(documentStateChanged(_:)),
                                               name: TextDocument.stateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(documentStateChanged(_:)),
                                               name: TextDocument.diagnosticsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accessoryProvidersChanged(_:)),
                                               name: EditorAreaViewController.accessoryProvidersDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        breadcrumbs.onOpen = { [weak self] in self?.open($0) }
        breadcrumbHeight = breadcrumbs.heightAnchor.constraint(equalToConstant: 0)
        accessoryHeight = accessoryHost.heightAnchor.constraint(equalToConstant: 0)
        for subview in [tabBar, breadcrumbs, accessoryHost, container] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            breadcrumbs.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            breadcrumbs.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            breadcrumbs.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            breadcrumbHeight,
            accessoryHost.topAnchor.constraint(equalTo: breadcrumbs.bottomAnchor),
            accessoryHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            accessoryHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            accessoryHeight,
            container.topAnchor.constraint(equalTo: accessoryHost.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        tabBar.trailingInset = 6
        tabBar.onSelect = { [weak self] in self?.select($0) }
        tabBar.onClose = { [weak self] in self?.close(at: $0) }
        tabBar.onCloseOthers = { [weak self] in self?.closeTabs(.others, relativeTo: $0) }
        tabBar.onCloseToTheRight = { [weak self] in self?.closeTabs(.toTheRight, relativeTo: $0) }
        tabBar.onCloseAll = { [weak self] in self?.closeTabs(.all, relativeTo: $0) }
        tabBar.onOpenChanges = { [weak self] in self?.openChanges(forTabAt: $0) }
        refresh()
    }

    @objc private func openClicked() { onRequestOpen?() }

    func refreshWelcomeIfShowing() {
        if isViewLoaded, currentTab == nil { welcome.applyTheme(Settings.shared.theme) }
    }

    @objc private func documentStateChanged(_ notification: Notification) {
        guard let document = notification.object as? TextDocument, tabs.contains(where: { $0.document === document }) else { return }
        // Diagnostics are not shown in the tab bar or the path bar, so they must not rebuild either.
        if notification.name == TextDocument.stateDidChange {
            refreshTabBar()
            if currentTab?.document === document { refreshBreadcrumbs() }     // Save As changes the path
        }
        if currentTab?.document === document { noteStateChange() }
    }

    func applySettings() {
        // The tab in front is restyled now; the others when they are next shown. With many tabs open this turns a
        // font-size change from "re-lay-out every document" into "re-lay-out one".
        for tab in tabs { tab.needsSettings = true }
        applyPendingSettings(to: currentTab)
        welcome.applyTheme(Settings.shared.theme)
        refreshTabBar()
        refreshBreadcrumbs()
    }

    // MARK: - Tabs

    private func refreshTabBar() {
        guard isViewLoaded else { return }
        tabBar.reload(tabs: tabs.map { TabInfo(title: ($0.isPreviewing && $0.isMarkdown ? "Preview " : "") + $0.title, icon: $0.document.tabIcon ?? $0.url.map { FileIcon.image(for: $0, isDirectory: false) },
                                             toolTip: $0.url?.path, isDirty: $0.isDirty) },
                      selected: selectedIndex)
    }

    private func applyPendingSettings(to tab: EditorTab?) {
        guard let tab, tab.needsSettings else { return }
        tab.needsSettings = false
        // An editor that does not exist yet reads the settings when it is built.
        tab.editorIfLoaded?.applySettings()
        tab.preview?.applyTheme()
    }

    /// One keystroke raises a text change, a selection change and often a diagnostics update. They are folded into
    /// a single state-change callback per turn of the run loop, so the window refreshes its chrome once.
    private var stateChangePending = false
    private func noteStateChange() {
        guard !stateChangePending else { return }
        stateChangePending = true
        DispatchQueue.main.async { [weak self] in
            self?.stateChangePending = false
            self?.onStateChange?()
        }
    }

    /// The path bar only exists for a saved file; the welcome screen and untitled tabs have nowhere to point.
    private func refreshBreadcrumbs() {
        guard isViewLoaded else { return }
        // A web preview has its own address bar, and its tab names no file.
        let file = currentTab?.preview is WebPreviewView ? nil : currentTab?.url
        breadcrumbHeight.constant = file == nil ? 0 : BreadcrumbBar.height
        breadcrumbs.isHidden = file == nil
        breadcrumbs.show(file: file, root: store.projectRoot, fileIcon: currentTab?.document.tabIcon)
    }

    private func refresh() {
        guard !isDeferringDisplay else { return }
        refreshTabBar()
        refreshBreadcrumbs()
        applyPendingSettings(to: currentTab)
        // This is where a tab gets its editor: when it is first shown, or shown again after its editor was released.
        let content: NSView = currentTab?.preview ?? currentTab?.editor ?? welcome
        if let tab = currentTab {
            showCounter += 1
            tab.lastShown = showCounter
        }
        releaseStaleEditors()
        if content.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            content.frame = container.bounds
            content.autoresizingMask = [.width, .height]
            container.addSubview(content)
        }
        if content === welcome { welcome.applyTheme(Settings.shared.theme) }      // and do not build it until it is needed
        refreshAccessory()
        onStateChange?()
    }

    @objc private func accessoryProvidersChanged(_ notification: Notification) {
        accessoryTab = nil
        if isViewLoaded { refreshAccessory() }
    }

    /// Asks the providers for a strip over the tab in front. The strip is kept while the same tab keeps the
    /// same editor, and built again when the editor is (an editor released in the background comes back new).
    private func refreshAccessory() {
        let tab = currentTab
        let editor = tab?.editorIfLoaded
        if tab === accessoryTab, editor === accessoryEditor { return }
        accessoryHost.subviews.forEach { $0.removeFromSuperview() }
        accessoryTab = tab
        accessoryEditor = editor
        var strip: NSView?
        if let tab, tab.preview == nil, !tab.document.isMedia, !EditorAreaViewController.accessoryProviders.isEmpty {
            for key in EditorAreaViewController.accessoryProviders.keys.sorted() {
                if let made = EditorAreaViewController.accessoryProviders[key]?(tab, self) { strip = made; break }
            }
        }
        guard let strip else { accessoryHeight.constant = 0; accessoryHost.isHidden = true; return }
        let height = strip.intrinsicContentSize.height
        accessoryHeight.constant = height > 0 ? height : strip.frame.height
        accessoryHost.isHidden = false
        strip.translatesAutoresizingMaskIntoConstraints = false
        accessoryHost.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: accessoryHost.topAnchor),
            strip.bottomAnchor.constraint(equalTo: accessoryHost.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: accessoryHost.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: accessoryHost.trailingAnchor),
        ])
    }

    /// Keeps the editors of the most recently shown tabs and lets go of the rest. The tab remembers the cursor and
    /// scroll position, and the document everything else, so the tab comes back as it was left.
    private func releaseStaleEditors() {
        let background = tabs.filter { $0.isEditorLoaded && $0 !== currentTab }
        guard background.count > EditorAreaViewController.backgroundEditorLimit else { return }
        let stale = background.sorted { $0.lastShown > $1.lastShown }.dropFirst(EditorAreaViewController.backgroundEditorLimit)
        // Whatever has the keyboard is in use, however long ago its tab was shown.
        let firstResponder = view.window?.firstResponder
        for tab in stale where tab.editorIfLoaded?.textView !== firstResponder { tab.releaseEditor() }
    }

    /// Runs `body` with the display held back, then shows where things ended up. Restoring a session of forty files
    /// this way builds one editor rather than forty.
    func withDeferredDisplay(_ body: () -> Void) {
        guard !isDeferringDisplay else { return body() }
        isDeferringDisplay = true
        body()
        isDeferringDisplay = false
        if isViewLoaded { refresh() }
    }

    func focus() {
        guard !isDeferringDisplay, let tab = currentTab else { return }
        view.window?.makeFirstResponder(tab.preview?.focusView ?? tab.editor.textView)
    }

    private func makePreview(for tab: EditorTab) -> TabPreview? {
        if tab.isSVG, let url = tab.url { return MediaPreviewView(url: url, kind: .svg, document: tab.document) }
        let preview = MarkdownPreviewView(document: tab.document)
        preview.onOpenFile = { [weak self] in self?.open($0) }
        return preview
    }

    /// Switches the current Markdown or SVG tab between its source and its rendered form.
    func togglePreview() {
        guard let tab = currentTab, tab.canPreview else { NSSound.beep(); return }
        if tab.isPreviewing {
            tab.preview = nil
        } else {
            tab.preview = makePreview(for: tab)
        }
        refresh()
        focus()
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedIndex = index
        refresh()
        focus()
    }

    func selectAdjacent(_ delta: Int) {
        guard tabs.count > 1 else { return }
        select((selectedIndex + delta + tabs.count) % tabs.count)
    }

    /// Adds a tab for a document this group now holds one use of.
    private func addTab(for document: TextDocument, asPicture: Bool = false) {
        let tab = EditorTab(document: document) { [weak self, weak document] editor in
            guard let self, let document else { return }
            self.wire(editor, to: document)
        }
        // A media document has no text to edit, in this group or any other, so it always shows its viewer.
        if document.isMedia, let url = document.url, let kind = MediaPreviewView.kind(of: url) {
            tab.preview = MediaPreviewView(url: url, kind: kind, document: nil)
        } else if asPicture {
            // Decided before the tab is first shown, so the source editor is not built just to be covered up.
            tab.preview = makePreview(for: tab)
        }
        tabs.append(tab)
        select(tabs.count - 1)
    }

    /// A tab whose whole content is a view made elsewhere (a diff). No editor is ever built for it.
    func addViewTab(for document: TextDocument, preview: TabPreview) {
        let tab = EditorTab(document: document) { _ in }
        tab.preview = preview
        tabs.append(tab)
        select(tabs.count - 1)
    }

    /// Everything an editor needs from its group. A tab's editor can be built more than once, so this is a function
    /// of the editor rather than part of adding the tab.
    private func wire(_ editor: EditorView, to document: TextDocument) {
        let lsp = self.lsp
        editor.onFocus = { [weak self] in
            guard let self else { return }
            self.onFocus?(self)
        }
        editor.onSelectionChange = { [weak self] in self?.noteStateChange() }
        editor.onOpenFiles = { [weak self] urls in urls.forEach { self?.onOpenDropped?($0) } }
        editor.onTextChange = { [weak self] in self?.noteStateChange() }
        editor.completionTriggers = { [weak document] in lsp.triggerCharacters(for: document?.url) }
        editor.onCompletionRequest = { [weak document] line, character, done in
            guard let url = document?.url else { return done([]) }
            lsp.completion(url, line: line, character: character, completion: done)
        }
        editor.onHoverRequest = { [weak document] line, character, done in
            guard let url = document?.url else { return done(nil) }
            lsp.hover(url, line: line, character: character, completion: done)
        }
        editor.isLanguageServerReady = { [weak document] in lsp.isReady(for: document?.url) }
        editor.onDefinitionRequest = { [weak self, weak document] line, character, word in
            guard let self, let document else { NSSound.beep(); return }
            self.resolveDefinition(in: document, line: line, character: character, word: word, isProbe: false) { location in
                guard let location else { NSSound.beep(); return }
                self.onOpenLocation?(location)
            }
        }
        editor.onDefinitionProbe = { [weak self, weak document] line, character, word, answer in
            guard let self, let document else { return answer(false) }
            self.resolveDefinition(in: document, line: line, character: character, word: word, isProbe: true) { answer($0 != nil) }
        }
        editor.onReferencesRequest = { [weak self, weak document] line, character, symbol in
            guard let url = document?.url else { return }
            lsp.references(url, line: line, character: character) { self?.onShowReferences?($0, symbol) }
        }
        editor.onRenameRequest = { [weak self, weak document] line, character, symbol in
            guard let self, let url = document?.url, let newName = self.promptForName(current: symbol) else { return }
            lsp.rename(url, line: line, character: character, newName: newName) { changes in
                guard let changes, !changes.isEmpty else { NSSound.beep(); return }
                self.store.apply(changes)
            }
        }
    }

    /// The language server when one is answering, otherwise the built-in finder. Hover probes are cancelled by
    /// the next probe, and what the finder learns is remembered until the file changes.
    private func resolveDefinition(in document: TextDocument, line: Int, character: Int, word: String, isProbe: Bool,
                                   completion: @escaping (LSPLocation?) -> Void) {
        guard let url = document.url else { return completion(nil) }
        let cacheKey = url.path + "#" + word
        let useFinder = { [weak self] in
            guard let self else { return completion(nil) }
            if self.finderCacheVersion != document.storage.length { self.finderCache = [:]; self.finderCacheVersion = document.storage.length }
            // The cache answers "where is it declared"; being on the declaration itself means there is nowhere to go.
            let elsewhere: (LSPLocation?) -> LSPLocation? = { found in
                found.flatMap { $0.url == url.standardizedFileURL && $0.line == line ? nil : $0 }
            }
            if let cached = self.finderCache[cacheKey] { return completion(elsewhere(cached)) }
            self.probeGeneration += 1
            let generation = self.probeGeneration
            SymbolFinder.find(word, from: url, text: document.text, clickedLine: -1, root: self.store.projectRoot,
                              isCancelled: { [weak self] in isProbe && self?.probeGeneration != generation }) { [weak self] location in
                if let self, !isProbe || self.probeGeneration == generation { self.finderCache[cacheKey] = .some(location) }
                completion(elsewhere(location))
            }
        }
        guard lsp.isReady(for: url) else { return useFinder() }
        lsp.definition(url, line: line, character: character) { location in
            if let location { completion(location) } else { useFinder() }
        }
    }

    private func promptForName(current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Rename “\(current)”"
        alert.informativeText = "Every reference in the project is updated."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == current ? nil : name
    }

    func newUntitled() {
        addTab(for: store.newUntitled())
    }

    func open(_ url: URL) {
        let url = url.standardizedFileURL
        if let index = tabs.firstIndex(where: { $0.url == url }) {
            select(index)
            return
        }
        // Pictures, PDFs, audio and video are shown in a viewer; they are never read as text.
        if let kind = MediaPreviewView.kind(of: url), kind != .svg {
            addTab(for: store.openMedia(url))
            return
        }
        do {
            let document = try store.open(url)
            // Reuse a pristine "Untitled" tab instead of leaving it behind.
            if let current = currentTab, current.url == nil, !current.isDirty, current.document.storage.length == 0 {
                store.release(current.document)
                tabs.remove(at: selectedIndex)
            }
            // An SVG opens as the picture; ⇧⌘V shows its source.
            addTab(for: document, asPicture: url.pathExtension.lowercased() == "svg")
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could not open “\(url.lastPathComponent)”"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// Shows a document that is already open elsewhere (used when splitting).
    func show(_ document: TextDocument) {
        if let index = tabs.firstIndex(where: { $0.document === document }) {
            select(index)
            return
        }
        store.retain(document)
        addTab(for: document)
    }

    @discardableResult
    func close(at index: Int) -> Bool {
        guard tabs.indices.contains(index) else { return false }
        let tab = tabs[index]
        // Only ask when this is the last view of the document; another group may still show it.
        if tab.isDirty && tab.document.useCount <= 1 {
            select(index)
            let alert = NSAlert()
            alert.messageText = "Do you want to save the changes you made to “\(tab.title)”?"
            alert.informativeText = "Your changes will be lost if you don’t save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don’t Save")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if let preview = tab.preview as? SavableTabPreview { if !preview.saveForClosing() { return false } }
                else if !store.save(tab.document) { return false }
            case .alertSecondButtonReturn: return false
            default: break
            }
        }
        if let url = tab.url, !tab.document.isMedia {
            closedTabs.append((url, tab.place))
            if closedTabs.count > EditorAreaViewController.closedTabLimit { closedTabs.removeFirst() }
        }
        tabs.remove(at: index)
        store.release(tab.document)
        if selectedIndex > index || selectedIndex >= tabs.count { selectedIndex -= 1 }
        if selectedIndex < 0 && !tabs.isEmpty { selectedIndex = 0 }
        refresh()
        if tabs.isEmpty { onEmpty?(self) } else { focus() }
        return true
    }

    enum TabSet { case others, toTheRight, all }

    /// Closes several tabs the way Close Tab closes one: a tab with unsaved changes asks first, and Cancel
    /// stops there, leaving the rest open. `index` is the tab the command was used on.
    func closeTabs(_ set: TabSet, relativeTo index: Int) {
        guard tabs.indices.contains(index) else { return }
        let anchor = tabs[index]
        let doomed: [EditorTab]
        switch set {
        case .others: doomed = tabs.filter { $0 !== anchor }
        case .toTheRight: doomed = Array(tabs[(index + 1)...])
        case .all: doomed = tabs
        }
        guard !doomed.isEmpty else { return }
        func closeEach(_ candidates: [EditorTab]) -> Bool {
            for tab in candidates.reversed() {
                guard let position = tabs.firstIndex(where: { $0 === tab }) else { continue }
                if !close(at: position) { return false }
            }
            return true
        }
        let needsAsking: (EditorTab) -> Bool = { $0.isDirty && $0.document.useCount <= 1 }
        // Closing a tab shows its neighbour, which builds the neighbour's editor. Held back, the tabs nobody
        // needs to be asked about go without building anything; the ones with a question are shown one by one.
        withDeferredDisplay { _ = closeEach(doomed.filter { !needsAsking($0) }) }
        guard closeEach(doomed.filter(needsAsking)) else { return }
        if set != .all, let kept = tabs.firstIndex(where: { $0 === anchor }) { select(kept) }
    }

    func reopenClosedTab() {
        // Skip what has been opened again by hand, or deleted, since it was closed.
        while let last = closedTabs.popLast() {
            guard !tabs.contains(where: { $0.url == last.url }), FileManager.default.fileExists(atPath: last.url.path) else { continue }
            open(last.url)
            if let tab = currentTab, tab.url == last.url, let place = last.place { tab.place = place }
            return
        }
        NSSound.beep()
    }

    /// Drops every tab without prompting; the caller has already dealt with unsaved changes.
    func closeAllTabs() {
        tabs.forEach { store.release($0.document) }
        tabs = []
        selectedIndex = -1
        if isViewLoaded { refresh() }
    }
}

/// The editor groups of one window, side by side. There is always at least one group.
final class EditorGroupsController: NSSplitViewController {
    static let maxGroups = 3
    var onStateChange: (() -> Void)?
    var onRequestOpen: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?
    var onRun: (() -> Void)?
    var onShowReferences: (([LSPLocation], String) -> Void)?

    private let store: DocumentStore
    private(set) var groups: [EditorAreaViewController] = []
    private(set) var active: EditorAreaViewController!

    init(store: DocumentStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        active = addGroup()
        store.willSave = { [weak self] in self?.tidyForSave($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @discardableResult
    private func addGroup() -> EditorAreaViewController {
        let group = EditorAreaViewController(store: store)
        group.onStateChange = { [weak self, weak group] in
            if group === self?.active { self?.onStateChange?() }
        }
        group.onRequestOpen = { [weak self] in self?.onRequestOpen?() }
        group.onOpenRecent = { [weak self] in self?.onOpenRecent?($0) }
        group.onOpenDropped = { [weak self] in self?.onOpenRecent?($0) }      // same handling: open it in this window
        group.onRun = { [weak self] in self?.onRun?() }
        group.onShowReferences = { [weak self] in self?.onShowReferences?($0, $1) }
        group.onOpenLocation = { [weak self] in self?.open($0) }
        group.onFocus = { [weak self] in self?.activate($0) }
        group.onEmpty = { [weak self] in self?.remove($0) }
        groups.append(group)
        let item = NSSplitViewItem(viewController: group)
        item.minimumThickness = 200
        addSplitViewItem(item)
        group.applySettings()
        return group
    }

    private func activate(_ group: EditorAreaViewController) {
        guard active !== group else { return }
        active = group
        onStateChange?()
    }

    private func remove(_ group: EditorAreaViewController) {
        guard groups.count > 1, let index = groups.firstIndex(where: { $0 === group }) else { return }
        groups.remove(at: index)
        removeSplitViewItem(splitViewItems[index])
        if active === group {
            active = groups[min(index, groups.count - 1)]
            active.focus()
        }
        onStateChange?()
    }

    /// Opens a new group to the right showing the current file.
    func splitActive() {
        guard groups.count < EditorGroupsController.maxGroups, let document = active.currentTab?.document else {
            NSSound.beep()
            return
        }
        let group = addGroup()
        group.show(document)
        active = group
        let width = splitView.bounds.width / CGFloat(groups.count)
        for index in 0..<groups.count - 1 { splitView.setPosition(width * CGFloat(index + 1), ofDividerAt: index) }
        group.focus()
        onStateChange?()
    }

    /// The source stays where it is and its preview opens in a new group beside it; both follow your typing.
    func openPreviewToSide() {
        guard let tab = active.currentTab, tab.canPreview, groups.count < EditorGroupsController.maxGroups else { NSSound.beep(); return }
        let source = active!
        splitActive()
        active.togglePreview()
        active = source
        // An SVG opens as its picture; with the picture now on the right, the left pane turns to the source.
        if tab.isSVG, tab.isPreviewing { source.togglePreview() }
        source.focus()              // keep typing in the source
        onStateChange?()
    }

    func focusGroup(_ delta: Int) {
        guard groups.count > 1, let index = groups.firstIndex(where: { $0 === active }) else { return }
        active = groups[(index + delta + groups.count) % groups.count]
        active.focus()
        onStateChange?()
    }

    func open(_ location: LSPLocation) {
        active.open(location.url)
        guard let tab = active.currentTab, tab.url == location.url else { return }
        tab.editor.select(line: location.line, character: location.character,
                          endLine: location.endLine, endCharacter: location.endCharacter)
    }

    func applySettings() {
        groups.forEach { $0.applySettings() }
    }

    /// Trailing whitespace and the final newline, as the settings ask, just before the file is written. It is
    /// an ordinary edit: it can be undone, and the panes showing the file simply see the text change.
    private func tidyForSave(_ document: TextDocument) {
        let settings = Settings.shared
        // What `.editorconfig` says for this file wins over the user's settings, either way round.
        let trims = document.editorConfig?.trimTrailingWhitespace ?? settings.trimTrailingWhitespace
        let endsWithNewline = document.editorConfig?.insertFinalNewline ?? settings.insertFinalNewline
        guard !document.isMedia, trims || endsWithNewline else { return }
        var edits = DocumentEdits.tidyingForSave(document.storage.mutableString, trimTrailingWhitespace: trims,
                                                 insertFinalNewline: endsWithNewline)
        // Through an editor when one exists, so its caret and undo stay right; Save All also reaches documents
        // whose editors were released, and those are edited directly rather than building an editor to do it.
        let tabs = [active.currentTab].compactMap { $0 } + groups.flatMap(\.tabs)
        let loaded = tabs.filter { $0.document === document && $0.isEditorLoaded }.compactMap(\.editorIfLoaded)
        if store.isAutoSaving {
            // Auto save happens while you type: it must not eat the space you just typed before the next word,
            // nor disturb a character that is still being composed.
            if loaded.contains(where: { $0.textView.hasMarkedText() }) { return }
            let carets = loaded.flatMap { $0.textView.selectedRanges.map(\.rangeValue) }
            edits.removeAll { edit in
                carets.contains { $0.location <= NSMaxRange(edit.range) && NSMaxRange($0) >= edit.range.location }
            }
        }
        guard !edits.isEmpty else { return }
        if let editor = loaded.first {
            editor.apply(edits, named: "Tidy on Save")
        } else {
            document.apply(edits)
        }
    }

    /// The welcome screen lists recent folders; opening a folder only needs that list refreshed, not every editor.
    func refreshWelcome() {
        groups.forEach { $0.refreshWelcomeIfShowing() }
    }

    // MARK: - Session

    /// Saved files only; an untitled tab has nothing on disk to come back to.
    var sessionState: [[String: Any]] {
        groups.map { group in
            ["files": group.tabs.compactMap { $0.url?.path }, "selected": group.currentTab?.url?.path ?? ""]
        }
    }

    func restore(_ state: [[String: Any]]) {
        for (index, saved) in state.prefix(EditorGroupsController.maxGroups).enumerated() {
            let files = (saved["files"] as? [String] ?? []).filter { FileManager.default.fileExists(atPath: $0) }
            guard !files.isEmpty else { continue }
            var carriedOver: TextDocument?
            if index > 0, active.currentTab != nil {
                // A split starts by showing the current file; drop that tab again if this group did not have it.
                carriedOver = active.currentTab?.document
                splitActive()
            }
            let group = active!
            // Opening a file shows it, which builds its editor. Only the tab that ends up in front needs one.
            group.withDeferredDisplay {
                files.forEach { group.open(URL(fileURLWithPath: $0)) }
                if let carriedOver, let url = carriedOver.url, !files.contains(url.path),
                   let extra = group.tabs.firstIndex(where: { $0.document === carriedOver }) {
                    group.close(at: extra)
                }
                if let selected = saved["selected"] as? String, let tab = group.tabs.firstIndex(where: { $0.url?.path == selected }) {
                    group.select(tab)
                }
            }
        }
        if let first = groups.first {
            active = first
            first.focus()
        }
    }
}
