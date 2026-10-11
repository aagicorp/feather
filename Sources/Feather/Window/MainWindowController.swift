import AppKit

final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    /// Back, Forward, the project name (file search) and the layout buttons, in place of a title bar. HeaderBar.swift.
    let header = HeaderBar()
    /// The icons down the left edge that switch sidebar panes (ActivityBar.swift).
    let activityBar = ActivityBar()
    private let history = NavigationHistory()
    /// Set while Back/Forward is moving the cursor, so that move is not itself recorded as a new place.
    var isReplayingHistory = false
    /// The assistant the Terminal menu's Start item names; kept rather than worked out, since menus validate often.
    var assistantToolName: String?
    private var paneObservations: [NSKeyValueObservation] = []
    /// For code outside this file, as `gitSourceControl` is.
    var terminals: TerminalPaneController { terminalPane }

    let lsp = LSPManager()
    /// Compilers and linters run on the project when no language server is there. See ProjectChecker.swift.
    let checker = ProjectChecker()
    private(set) lazy var store = DocumentStore(lsp: lsp)
    private(set) lazy var editors = EditorGroupsController(store: store)
    /// The editor group that currently has focus.
    var editorArea: EditorAreaViewController { editors.active }
    /// The sidebar's panes. For the parts of this controller that live in other files (ReplaceInProject.swift).
    let sidebarContainer = SidebarContainerViewController()
    /// The explorer, for the parts of this controller that live in other files.
    var sidebar: SidebarViewController { sidebarContainer.explorer }
    /// The open folder, for the parts of this controller that live in other files (WorkspaceSymbols.swift).
    var projectRoot: URL? { sidebar.rootURL }
    private(set) lazy var workspaceSymbols = WorkspaceSymbolIndex()
    lazy var workspaceSymbolPanel = FilterPanelController(placeholder: "Go to a function, class or type anywhere in the project",
                                                          size: NSSize(width: 640, height: 380))
    let terminalPane = TerminalPaneController()
    /// The rounded, slightly inset panels the editor and the terminal sit in (FloatingPanel.swift).
    private(set) lazy var sidebarPanel = FloatingPanelController(content: sidebarContainer, surface: \.chrome)
    private(set) lazy var editorPanel = FloatingPanelController(content: editors)
    private(set) lazy var terminalPanel = FloatingPanelController(content: terminalPane)
    /// The glass behind everything, seen in the gaps between the panels.
    private(set) var rootBackdrop: Glass.Backdrop?
    let statusBar = StatusBarView()
    private let outerSplit = NSSplitViewController()
    /// Editors above the terminal, or beside it (MainWindow+Terminal.swift).
    let innerSplit = NSSplitViewController()
    /// The three panes; the files that show and hide them are MainWindow+Panes.swift and MainWindow+Terminal.swift.
    var sidebarItem: NSSplitViewItem!
    var terminalItem: NSSplitViewItem!
    var editorItem: NSSplitViewItem!
    /// The terminal has the editors' room as well; they come back with the next toggle. The sidebar is not
    /// involved: it shows and hides as usual beside a maximized terminal, as in VS Code. Set only by
    /// `toggleTerminalMaximized` (MainWindow+Terminal.swift).
    var isTerminalMaximized = false
    let quickOpen = QuickOpenController()
    /// Whether the terminal divider has been placed once (MainWindow+Terminal.swift).
    var terminalSized = false
    var graphWindow: GitGraphWindowController?
    private var branchDirectory: URL?
    /// A commit, checkout, push or pull made in the terminal (or anywhere else) changes files under `.git`;
    /// this hears it and brings the branch, Source Control and the explorer marks up to date by themselves.
    private var gitWatcher: DirectoryWatcher?
    private var gitRefreshWork: DispatchWorkItem?
    /// The folder is open but not trusted: no language servers, no Run, no git. Set from MainWindow+Files.swift.
    var isRestricted = false {
        didSet { statusBar.isRestricted = isRestricted }
    }
    /// The window's content view, whose layer draws the project border (MainWindow+ProjectColor.swift).
    weak var rootView: NSView?
    /// The tint and border last applied, and the pending write of a colour picked in the panel (MainWindow+ProjectColor.swift).
    var currentTint: NSColor?
    var projectBorderEnabled = false
    var colorWriteWork: DispatchWorkItem?
    private var chromeCache = ChromeCache()

    /// What the title bar and status bar last showed, so a cursor move that changes none of it costs nothing.
    private struct ChromeCache {
        var title = ""
        var isEdited = false
    }
    private var lastRevealedFile: URL?
    /// The Source Control pane, for the parts of this controller that live in other files.
    var sourceControl: SourceControlViewController { sidebarContainer.sourceControl }
    /// For the git commands, which live in GitCommands.swift.
    var gitSourceControl: SourceControlViewController { sourceControl }
    private let blame = BlameStore()
    /// Checkpoints, the Activity pane and follow mode. See Activity.swift.
    private(set) lazy var activity = ActivityCoordinator(controller: self)

    /// Called after the window has closed, so the app delegate can let go of this controller.
    var onClose: ((MainWindowController) -> Void)?
    var hasFolder: Bool { sidebar.rootURL != nil }
    var isPristine: Bool { !hasFolder && editors.groups.allSatisfy { $0.tabs.isEmpty } }

    // Stored for the parts of this controller that live in other files, which cannot declare their own.
    /// The terminal as a tall column beside the editor instead of a strip under it: how an AI assistant is
    /// used while watching the files it changes. The same split view serves both; it is turned on its side.
    /// Set only by `setTerminalOnRight` (MainWindow+Terminal.swift).
    var isTerminalOnRight = false
    /// The size the user left the terminal at, in each layout (true: on the right). MainWindow+Terminal.swift.
    var terminalThickness: [Bool: CGFloat] = [:]
    /// Tasks (ProjectTasks.swift), run from MainWindow+Files.swift.
    let taskList = ProjectTaskList()
    lazy var taskPanel = FilterPanelController(placeholder: "Run a task from this project")
    /// The rows the task panel is showing, in its order; a pick is an index into this.
    var shownTasks: [ProjectTask] = []

    /// Only the first window remembers its frame; later ones cascade from the window they were opened from.
    init(cascadingFrom previous: NSWindow? = nil) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Feather"
        window.tabbingMode = .disallowed
        // No title bar of its own: the header bar stands in its place, under the close/minimise/zoom buttons.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.minSize = NSSize(width: 640, height: 400)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildLayout()
        installHeader()
        window.setContentSize(NSSize(width: 1200, height: 760))
        if let previous {
            window.setFrame(previous.frame.offsetBy(dx: 28, dy: -28), display: false)
        } else {
            window.center()
            window.setFrameAutosaveName("FeatherMainWindow")
        }

        sidebar.onOpenFile = { [weak self] in self?.editorArea.open($0) }
        sidebar.onMoveFile = { [weak self] old, new in self?.store.fileMoved(from: old, to: new) }
        sidebar.onRequestOpenFolder = { [weak self] in self?.openDocument(nil) }
        editors.onRequestOpen = { [weak self] in self?.openDocument(nil) }
        editors.onOpenRecent = { [weak self] in self?.open($0) }
        editors.onStateChange = { [weak self] in self?.updateChrome() }
        editors.onRun = { [weak self] in self?.runProject(nil) }
        terminalPane.onClose = { [weak self] in self?.hideTerminal() }
        terminalPane.onMoveRequested = { [weak self] in self?.toggleTerminalOnRight(nil) }
        terminalPane.onMaximizeRequested = { [weak self] in self?.toggleTerminalMaximized(nil) }
        quickOpen.onPrefix = { [weak self] in self?.quickOpenPrefix($0, typed: $1) }
        quickOpen.onOpen = { [weak self] in self?.editorArea.open($0) }
        sidebarContainer.search.onOpenMatch = { [weak self] match in
            guard let self else { return }
            self.editorArea.open(match.url)
            guard let tab = self.editorArea.currentTab, tab.url == match.url.standardizedFileURL else { return }
            tab.editor.select(line: match.line - 1, character: match.column,
                              endLine: match.line - 1, endCharacter: match.column + match.length)
        }
        lsp.onStatusChange = { [weak self] in self?.updateChrome() }
        installProblems()
        installReplaceInProject()
        installProjectChecker()
        activity.install(pane: sidebarContainer.activity)
        sidebar.onGitChangeCount = { [weak self] count in
            self?.activityBar.setBadge(count, at: SidebarContainerViewController.sourceControlPane)
        }
        sourceControl.onOpenFile = { [weak self] in self?.editorArea.open($0) }
        sourceControl.onShowGraph = { [weak self] hash in
            self?.showGitGraph(nil)
            if let hash { self?.graphWindow?.select(hash: hash) }
        }
        sourceControl.onOpenDiff = { [weak self] root, change in
            self?.editorArea.openDiff(root: root, path: change.path, originalPath: change.originalPath, side: change.isStaged ? .index : .workingTree)
        }
        blame.onUpdate = { [weak self] in self?.refreshBlame() }
        NotificationCenter.default.addObserver(forName: GitDiffView.didChangeRepository, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? NSView)?.window === self.window else { return }
            self.repositoryDidChange(from: nil)
        }
        sidebarContainer.activeFile = { [weak self] in self?.editorArea.currentTab?.url }
        sourceControl.onRepositoryChanged = { [weak self] in self?.repositoryDidChange(from: self?.sourceControl) }
        NotificationCenter.default.addObserver(self, selector: #selector(documentSaved(_:)),
                                               name: DocumentStore.didSaveDocument, object: nil)
        editors.onShowReferences = { [weak self] (locations: [LSPLocation], symbol: String) in
            guard let self else { return }
            guard !locations.isEmpty else { NSSound.beep(); return }
            let results = ProjectSearch.results(for: locations, root: self.sidebar.rootURL) { self.store.text(of: $0) }
            if self.sidebarItem.isCollapsed { self.sidebarItem.isCollapsed = false }
            self.sidebarContainer.show(pane: 1)
            self.sidebarContainer.search.show(results, summary: "\(locations.count) references to “\(symbol)”")
        }
        NotificationCenter.default.addObserver(forName: WorkspaceTrust.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.trustDidChange()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        // Git appeared (Command Line Tools installed, or a Homebrew git found on the shell's PATH): the branch,
        // the Explorer marks and the Source Control pane can fill in now.
        NotificationCenter.default.addObserver(forName: Git.availabilityDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.repositoryDidChange(from: nil)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)),
                                               name: Settings.didChange, object: nil)
        applySettings()
        installAssistant()
        ExtensionRegistry.shared.windowDidOpen(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        // The dividers are the gaps between the floating panels (FloatingPanel.swift).
        innerSplit.splitView = GapSplitView()
        outerSplit.splitView = GapSplitView()
        innerSplit.splitView.isVertical = false
        innerSplit.splitView.dividerStyle = .thin
        editorItem = NSSplitViewItem(viewController: editorPanel)
        editorItem.minimumThickness = 120
        editorItem.canCollapse = true                 // only ever by Maximize Terminal; a drag stops at 120
        terminalItem = NSSplitViewItem(viewController: terminalPanel)
        terminalItem.minimumThickness = 90
        terminalItem.canCollapse = true
        terminalItem.isCollapsed = true
        terminalItem.holdingPriority = NSLayoutConstraint.Priority(260)
        innerSplit.addSplitViewItem(editorItem)
        innerSplit.addSplitViewItem(terminalItem)

        outerSplit.splitView.isVertical = true
        outerSplit.splitView.dividerStyle = .thin
        sidebarItem = NSSplitViewItem(viewController: sidebarPanel)
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 520
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        let contentItem = NSSplitViewItem(viewController: innerSplit)
        contentItem.minimumThickness = 300
        outerSplit.addSplitViewItem(sidebarItem)
        outerSplit.addSplitViewItem(contentItem)

        let root = NSViewController()
        root.view = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 760))
        root.view.wantsLayer = true
        rootBackdrop = Glass.backdrop(.sidebar, in: root.view)       // the ground the three panels float on, seen in the gaps
        root.addChild(outerSplit)
        for subview in [header, activityBar, outerSplit.view, statusBar] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.view.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            activityBar.topAnchor.constraint(equalTo: header.bottomAnchor),
            activityBar.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            activityBar.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            outerSplit.view.topAnchor.constraint(equalTo: header.bottomAnchor),
            outerSplit.view.leadingAnchor.constraint(equalTo: activityBar.trailingAnchor),
            outerSplit.view.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            outerSplit.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: StatusBarView.height),
        ])
        rootView = root.view
        window?.contentViewController = root
        outerSplit.splitView.setPosition(240, ofDividerAt: 0)
        updatePanelInsets()
    }

    /// The editor and terminal panels stand off the window's edges by the gap; a side facing a divider has no
    /// inset of its own, the divider being the gap, unless the pane beyond it is hidden.
    func updatePanelInsets() {
        let gap = GapSplitView.gap
        let terminalShown = !terminalItem.isCollapsed
        let leading: CGFloat = sidebarItem.isCollapsed ? gap : 0          // the divider to the sidebar is the gap
        sidebarPanel.setInsets(top: gap, leading: gap, bottom: gap, trailing: 0)
        editorPanel.setInsets(top: gap,
                              leading: leading,
                              bottom: terminalShown && !isTerminalOnRight ? 0 : gap,
                              trailing: terminalShown && isTerminalOnRight ? 0 : gap)
        // Below the editor the terminal shares its left edge; on the right it shares the top one.
        terminalPanel.setInsets(top: isTerminalOnRight ? gap : 0, leading: isTerminalOnRight ? 0 : leading, bottom: gap, trailing: gap)
    }

    // MARK: - State

    @objc private func settingsChanged(_ notification: Notification) {
        applySettings(Settings.change(in: notification))
    }

    /// Dragging the scroll-bar slider re-tiles scroll views and nothing else; changing the terminal font leaves the
    /// editors alone; and so on. Only a theme change touches everything.
    private func applySettings(_ change: Settings.Change = .everything) {
        if change.contains(.theme) {
            let theme = Settings.shared.theme
            window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
            applyProjectColor()
            sidebarContainer.applyTheme()
            sidebarPanel.applyTheme(theme)
            editorPanel.applyTheme(theme)
            terminalPanel.applyTheme(theme)
        }
        if change.contains(.scrollBars) || change.contains(.theme) { window?.contentView?.applyFeatherScrollers() }
        if change.contains(.editor) || change.contains(.theme) { editors.applySettings() }
        if change.contains(.terminal) || change.contains(.theme) { terminalPane.applySettings() }
        if change.contains(.explorer) { sidebar.applySettings() }
        updateChrome()
    }

    /// Uses the tint worked out by applyProjectColor(); this runs on every cursor move, so it must not touch the disk.
    func updateTitleSearch() {
        header.update(folderName: sidebar.rootURL?.lastPathComponent ?? "Feather",
                      canGoBack: history.canGoBack, canGoForward: history.canGoForward)
    }

    /// The header's layout buttons follow the panes, however they were shown or hidden (menu, shortcut, a drag
    /// of the divider all the way, or a restored session).
    private func updateLayoutButtons() {
        header.update(sidebarShown: !sidebarItem.isCollapsed, terminalShown: !terminalItem.isCollapsed,
                      terminalOnRight: isTerminalOnRight)
        updateActivityBar()
    }

    private func updateActivityBar() {
        activityBar.setItems(sidebarContainer.barItems)
        activityBar.update(selected: sidebarContainer.shownPane, sidebarShown: !sidebarItem.isCollapsed)
    }

    // MARK: - Back / Forward

    /// Remembers where the cursor is, for Back; `navigate(to:)` (MainWindow+Panes.swift) calls it around a jump.
    func recordCurrentPlace() {
        guard !isReplayingHistory, let tab = editorArea.currentTab, let url = tab.url else { return }
        guard tab.document.displayTitle == nil else { return }       // a diff tab is not a file Back could reopen
        // A picture or a preview still counts as a place to come back to; it just has no cursor.
        let cursor = tab.editorIfLoaded?.cursorPosition ?? (line: 1, column: 1)
        history.record(NavigationHistory.Entry(url: url, line: cursor.line - 1, character: cursor.column - 1))
    }

    private func go(to entry: NavigationHistory.Entry?) {
        guard let entry else { NSSound.beep(); return }
        isReplayingHistory = true
        editors.open(LSPLocation(url: entry.url, line: entry.line, character: entry.character,
                                 endLine: entry.line, endCharacter: entry.character))
        isReplayingHistory = false
        updateTitleSearch()
    }

    @objc func goBack(_ sender: Any?) {
        recordCurrentPlace()            // so Forward can return to exactly where you were
        go(to: history.back())
    }

    @objc func goForward(_ sender: Any?) { go(to: history.forward()) }

    // MARK: - Header bar

    private func installHeader() {
        header.search.target = self
        header.search.action = #selector(showQuickOpen(_:))
        header.back.target = self
        header.back.action = #selector(goBack(_:))
        header.forward.target = self
        header.forward.action = #selector(goForward(_:))
        header.sidebarToggle.target = self
        header.sidebarToggle.action = #selector(toggleSidebarPane(_:))
        header.terminalToggle.target = self
        header.terminalToggle.action = #selector(toggleTerminal(_:))
        // The activity bar: click a pane to show it; click the lit one to hide the sidebar, as in VS Code.
        activityBar.onSelect = { [weak self] index in
            guard let self else { return }
            if !self.sidebarItem.isCollapsed, index == self.sidebarContainer.shownPane {
                self.sidebarItem.animator().isCollapsed = true
            } else {
                if self.sidebarItem.isCollapsed { self.sidebarItem.isCollapsed = false }
                self.sidebarContainer.show(pane: index)
            }
        }
        sidebarContainer.onPanesChanged = { [weak self] in self?.updateActivityBar() }
        updateActivityBar()
        for item in [sidebarItem!, terminalItem!] {
            paneObservations.append(item.observe(\.isCollapsed) { [weak self] _, _ in
                self?.updateLayoutButtons()
                self?.updatePanelInsets()
            })
        }
        updateLayoutButtons()
    }

    func windowDidEnterFullScreen(_ notification: Notification) { header.isFullScreen = true }

    func windowDidExitFullScreen(_ notification: Notification) { header.isFullScreen = false }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleProjectBorder(_:)) {
            item.state = projectBorderEnabled ? .on : .off            // cached: menus validate often
            return sidebar.rootURL != nil
        }
        if item.action == #selector(toggleTerminalOnRight(_:)) { item.state = isTerminalOnRight ? .on : .off }
        if item.action == #selector(toggleTerminalMaximized(_:)) { item.state = isTerminalMaximized ? .on : .off }
        if item.action == #selector(toggleTerminalCopyOnSelect(_:)) { item.state = Settings.shared.terminalCopyOnSelect ? .on : .off }
        if [#selector(gitPush(_:)), #selector(gitPull(_:)), #selector(gitSync(_:)), #selector(gitFetch(_:))].contains(item.action) {
            return gitSourceControl.repositoryRoot != nil
        }
        if item.action == #selector(startAIAssistant(_:)) { item.title = "Start " + (assistantToolName ?? "AI Assistant") }
        if item.action == #selector(previewThisPage(_:)) { return editorArea.currentTab?.isHTML == true }
        return true
    }

    /// The title, status bar and explorer follow the tab in front; called wherever that changes.
    func updateChrome() {
        let tab = editorArea.currentTab
        if let directory = tab?.url?.deletingLastPathComponent(), directory != branchDirectory { refreshBranch() }
        let folder = sidebar.rootURL?.lastPathComponent
        // The window's own title still matters for the Window menu, the Dock and Mission Control.
        let title = folder ?? "Feather"
        if title != chromeCache.title { chromeCache.title = title; window?.title = title }
        if tab?.url != lastRevealedFile {
            lastRevealedFile = tab?.url
            if let url = tab?.url, Settings.shared.revealInExplorer { sidebar.reveal(url) }
        }
        recordCurrentPlace()
        updateTitleSearch()
        store.autoSave.focusMoved(to: tab?.document)         // an identity check unless the tab really changed
        let isEdited = tab?.isDirty ?? false
        if isEdited != chromeCache.isEdited { chromeCache.isEdited = isEdited; window?.isDocumentEdited = isEdited }
        statusBar.update(tab: tab, lsp: lsp)
        refreshBlame()
    }

    /// Blame for the caret's line: a lookup in what `git blame` already said, never a git call of its own.
    func refreshBlame() {
        let tab = editorArea.currentTab
        var info: BlameStore.Info?
        if let tab, !tab.isPreviewing, let editor = tab.editorIfLoaded {
            info = blame.info(for: tab.document, line: editor.cursorPosition.line - 1)
        }
        statusBar.blameButton.show(info, colour: statusBar.quietColour)
    }

    /// Any event under a `.git` folder (the root's or a nested repository's) refreshes the window shortly after
    /// the last of the burst. Git writes many files per command, and `index.lock` comes and goes, so one refresh
    /// a moment after the last event is enough.
    func watchGit(under root: URL) {
        let watcher = DirectoryWatcher(path: root.path)
        watcher.onChange = { [weak self] paths in
            guard let self, paths.contains(where: { $0.hasSuffix("/.git") || $0.contains("/.git/") }) else { return }
            self.gitRefreshWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.repositoryDidChange(from: nil) }
            self.gitRefreshWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }
        gitWatcher = watcher
    }

    /// The status bar shows the branch of the repository that owns the file being edited, which matters when
    /// the opened folder holds several repositories.
    func refreshBranch() {
        guard let directory = editorArea.currentTab?.url?.deletingLastPathComponent() ?? sidebar.rootURL else { return }
        branchDirectory = directory
        Git.branchStatus(in: directory) { [weak self] status in
            guard self?.branchDirectory == directory else { return }
            self?.statusBar.branch = status
        }
    }

    /// Commits or checkouts may have happened elsewhere while Feather was in the background.
    @objc private func appBecameActive() {
        Git.recheck()                       // the Command Line Tools may have been installed meanwhile
        applyProjectColor()
        repositoryDidChange(from: nil)
        terminalPane.clearAttentionIfSeen()
        AITools.refresh()                   // a tool may have been installed while Feather was in the background
    }

    @objc private func documentSaved(_ notification: Notification) {
        guard notification.object as AnyObject? === store, let url = notification.userInfo?["url"] as? URL else { return }
        // Only a settings file can change the project colour; every other save skips the disk reads.
        if url.lastPathComponent == "settings.json" { applyProjectColor() }
        sourceControl.fileSaved(url)
        sidebarContainer.problems.fileSaved(url)
        blame.invalidate(url)
        refreshBlame()
    }

    /// Brings every git-aware part of the window up to date. `source` already refreshed itself.
    func repositoryDidChange(from source: AnyObject?) {
        blame.invalidateAll()
        refreshBlame()
        NotificationCenter.default.post(name: Git.repositoryDidChange, object: window)
        refreshBranch()
        sidebar.refreshGitDecorations()
        store.syncWithDisk()
        if source !== sourceControl { sourceControl.refresh() }
        if source !== graphWindow, graphWindow?.window?.isVisible == true { graphWindow?.reload() }
    }

    @objc func showGitGraph(_ sender: Any?) {
        guard let root = sourceControl.repositoryRoot else {
            // Repositories are found in the background; open the pane, which shows them (or says none exist).
            showSourceControl(sender)
            return
        }
        if graphWindow?.root != root {
            graphWindow?.close()
            graphWindow = nil
        }
        if graphWindow == nil {
            let controller = GitGraphWindowController(root: root)
            controller.onRepositoryChanged = { [weak self, weak controller] in self?.repositoryDidChange(from: controller) }
            graphWindow = controller
        }
        graphWindow?.showWindow(nil)
    }

    /// Asks about unsaved tabs; returns false if the user cancels.
    func confirmDiscardingChanges() -> Bool {
        guard !store.dirtyDocuments.isEmpty else { return true }
        window?.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = "“\(window?.title ?? "This window")” has unsaved changes."
        alert.informativeText = "Do you want to save them before closing?"
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return store.saveAll()
        case .alertSecondButtonReturn: return false
        default: return true
        }
    }

    /// Closing the last window quits Feather, so it gets the same question as ⌘Q. Returns false on Cancel.
    var isLastWindow: (() -> Bool)?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if Settings.shared.confirmBeforeQuit {
            let quitting = isLastWindow?() ?? true
            let alert = NSAlert()
            alert.messageText = quitting ? "Quit Feather?" : "Close this window?"
            alert.informativeText = "Any terminals and tasks running in it will stop."
                + (Settings.shared.restoreSession && quitting ? " Your windows and files reopen next time." : "")
            alert.addButton(withTitle: quitting ? "Quit" : "Close")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don’t ask again"
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            if alert.suppressionButton?.state == .on { Settings.shared.confirmBeforeQuit = false }
        }
        return confirmDiscardingChanges()
    }

    // MARK: - Session

    /// Captured just before the window's terminals are shut down, so closing the last window can still be restored.
    private(set) var closingSnapshot: [String: Any]?

    func sessionState() -> [String: Any] {
        var state: [String: Any] = ["groups": editors.sessionState,
                                    "terminalVisible": !terminalItem.isCollapsed,
                                    "terminals": terminalPane.shellDescriptors,
                                    "sidebarHidden": sidebarItem.isCollapsed,
                                    "terminalOnRight": isTerminalOnRight]
        if let folder = sidebar.rootURL?.path { state["folder"] = folder }
        if let frame = window?.frame { state["frame"] = NSStringFromRect(frame) }
        return state
    }

    func restore(_ state: [String: Any]) {
        if let frame = state["frame"] as? String, let screen = window?.screen ?? NSScreen.main {
            let rect = NSRectFromString(frame)
            // Only if it would still be reachable — the monitor it was on may be gone.
            if rect.width > 300, rect.height > 200, screen.visibleFrame.intersects(rect) { window?.setFrame(rect, display: true) }
        }
        if let folder = state["folder"] as? String, FileManager.default.fileExists(atPath: folder) {
            openFolder(URL(fileURLWithPath: folder), asksAboutTrust: false)
        }
        editors.restore(state["groups"] as? [[String: Any]] ?? [])
        if state["sidebarHidden"] as? Bool == true { sidebarItem.isCollapsed = true }
        if let onRight = state["terminalOnRight"] as? Bool { setTerminalOnRight(onRight) }
        // Older sessions kept only a count of shells; newer ones each shell's name, colour and icon.
        let shells = state["terminals"] as? [[String: String]]
            ?? Array(repeating: [:], count: state["terminals"] as? Int ?? 0)
        if state["terminalVisible"] as? Bool == true, !shells.isEmpty {
            showTerminal()
            terminalPane.restoreShells(shells)
            editorArea.focus()          // reopening should leave you in the code, not in a shell
        }
    }

    func windowWillClose(_ notification: Notification) {
        ExtensionRegistry.shared.windowWillClose(self)
        if let root = sidebar.rootURL { WorkspaceTrust.shared.noteClosed(root) }
        closingSnapshot = sessionState()
        shutDown()
        onClose?(self)
    }

    /// Stops this window's language servers and shell.
    func shutDown() {
        graphWindow?.close()
        lsp.stopAll()
        terminalPane.shutDown()
    }

    // MARK: - Auto save, opening at a line

    func windowDidResignKey(_ notification: Notification) { store.autoSave.focusLeft() }

    func windowDidBecomeKey(_ notification: Notification) { terminalPane.clearAttentionIfSeen() }

    /// `feather src/App.tsx:12:5`. Lines and columns count from 1.
    func open(_ url: URL, line: Int, column: Int?) {
        let character = max(0, (column ?? 1) - 1)
        editors.open(LSPLocation(url: url.standardizedFileURL, line: max(0, line - 1), character: character,
                                 endLine: max(0, line - 1), endCharacter: character))
    }

    @objc func goToLine(_ sender: Any?) { goToLine(typed: "") }

    /// `typed` is a number already entered, from ":" in Quick Open.
    func goToLine(typed: String) {
        guard let editor = editorArea.currentTab?.editor else { return }
        if let line = Int(typed), line > 0 { editor.goToLine(line); return }
        let alert = NSAlert()
        alert.messageText = "Go to line"
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        field.placeholderString = "Line number"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, let line = Int(field.stringValue), line > 0 else { return }
        editor.goToLine(line)
    }
}
