import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let recentMenu = NSMenu(title: "Open Recent")
    private lazy var commandPalette = CommandPaletteController()
    /// Closing the last window quits the app; that is already a deliberate act, so it skips the quit question.
    private var lastWindowJustClosed = false
    private var sessionFromLastWindow: [[String: Any]]?

    private var windows: [MainWindowController] = []
    private var didFinishLaunching = false

    private var activeWindow: MainWindowController? {
        windows.first { $0.window?.isKeyWindow == true } ?? windows.first { $0.window?.isMainWindow == true } ?? windows.last
    }
    private lazy var preferences = PreferencesWindowController()
    private lazy var shortcutsEditor = KeyboardShortcutsWindowController()
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        didFinishLaunching = true
        // Paths given on the command line ("Feather ~/project src/App.tsx") open like files dropped on the icon.
        for argument in CommandLine.arguments.dropFirst() where !argument.hasPrefix("-") {
            let url = URL(fileURLWithPath: (argument as NSString).expandingTildeInPath)
            // "src/App.tsx:12" names no file as it stands; `open` below takes it apart.
            if FileManager.default.fileExists(atPath: url.path) || PathArgument.resolve(url) != nil { pendingURLs.append(url) }
        }
        // Shift held while Feather starts: nothing from last time is reopened, the way out when a saved session or
        // folder is what stops it from coming up. The session itself is kept, so a normal launch restores it.
        let safeMode = NSEvent.modifierFlags.contains(.shift) || CommandLine.arguments.contains("--safe")
        let session = Settings.shared.restoreSession && pendingURLs.isEmpty && !safeMode ? Settings.shared.savedSession : []
        if session.isEmpty {
            let first = makeWindow()
            // Reopening at launch is not the moment for a question about trust; an unknown folder opens restricted.
            if pendingURLs.isEmpty, !safeMode, let last = Settings.shared.lastFolder { first.openFolder(URL(fileURLWithPath: last), asksAboutTrust: false) }
            if safeMode, let window = first.window {
                let card = NoticeCard(kind: "safe-mode", symbol: "shield", text: "Started without reopening the last folder and files (Shift was held). Feather ▸ Reset Feather… clears the saved state for good.",
                                      actions: [], dismissTitle: "OK")
                WindowNotices.show(card, in: window)
            }
        } else {
            for state in session { makeWindow().restore(state) }
        }
        open(pendingURLs)
        pendingURLs = []
        NSApp.activate(ignoringOtherApps: true)
        PointerCursorMonitor.shared.start()
        PreviewBanner.shared.start()
        NotificationCenter.default.addObserver(self, selector: #selector(requiredUpdateFound), name: AppUpdater.requiredUpdateFound, object: nil)
        LanguageServerStore.shared.refresh()
        if let controller = windows.first { ReleaseNotes.showIfUpdated(in: controller) }
        if let controller = windows.first { UITestHarness.runIfRequested(controller) }      // tools/uitest.sh only
    }

    @discardableResult
    private func makeWindow() -> MainWindowController {
        let controller = MainWindowController(cascadingFrom: windows.isEmpty ? nil : activeWindow?.window)
        controller.isLastWindow = { [weak self] in (self?.windows.count ?? 1) <= 1 }
        controller.onClose = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
            if self?.windows.isEmpty == true {
                self?.lastWindowJustClosed = true
                // Closing the last window quits the app, so that window is the session.
                self?.sessionFromLastWindow = closed.closingSnapshot.map { [$0] }
            }
        }
        windows.append(controller)
        controller.showWindow(nil)
        return controller
    }

    private func confirmQuit() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Quit Feather?"
        alert.informativeText = windows.count > 1
            ? "All \(windows.count) windows will close, and any running terminals and tasks will stop."
            : "Any running terminals and tasks will stop."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        let quit = alert.runModal() == .alertFirstButtonReturn
        if quit, alert.suppressionButton?.state == .on { Settings.shared.confirmBeforeQuit = false }
        return quit
    }

    // MARK: - Open Recent

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for url in Settings.shared.recentFolders {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.image = FileIcon.image(for: url, isDirectory: true)
            item.toolTip = url.path.replacingOccurrences(of: home, with: "~")
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            menu.addItem(NSMenuItem(title: "No Recent Folders", action: nil, keyEquivalent: ""))
        } else {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecent(_:)), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        open([url])
    }

    @objc private func clearRecent(_ sender: Any?) {
        Settings.shared.clearRecentFolders()
    }

    @objc func showCommandPalette(_ sender: Any?) {
        guard let window = activeWindow?.window else { return }
        commandPalette.show(over: window)
    }

    @objc func newWindow(_ sender: Any?) {
        makeWindow()
    }

    /// Files open in the active window. A folder takes over an empty window, otherwise it gets a window of its own.
    private func open(_ urls: [URL]) {
        for url in urls {
            // feather://check-updates: the link on the What's New page.
            if url.scheme == "feather", url.host == "check-updates" { AppUpdater.shared.checkForUpdates(nil); continue }
            // `feather src/App.tsx:12:5` and feather:// links carry a place in the file along with its path.
            let place = PathArgument.resolve(url)
            let url = place.map { URL(fileURLWithPath: $0.path) } ?? url
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let target = windows.first { $0.isPristine } ?? (activeWindow?.hasFolder == false ? activeWindow : nil)
                (target ?? makeWindow()).open(url)
            } else if let line = place?.line {
                (activeWindow ?? makeWindow()).open(url, line: line, column: place?.column)
            } else {
                (activeWindow ?? makeWindow()).open(url)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if didFinishLaunching { open(urls) } else { pendingURLs.append(contentsOf: urls) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Settings.shared.confirmBeforeQuit && !lastWindowJustClosed && !confirmQuit() { return .terminateCancel }
        for controller in windows where !controller.confirmDiscardingChanges() {
            lastWindowJustClosed = false
            return .terminateCancel
        }
        // Windows closed earlier in the session were closed on purpose; only what is open now comes back.
        Settings.shared.savedSession = windows.isEmpty ? (sessionFromLastWindow ?? []) : windows.map { $0.sessionState() }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        windows.forEach { $0.shutDown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func showPreferences(_ sender: Any?) {
        preferences.showWindow(sender)
        preferences.window?.makeKeyAndOrderFront(sender)
    }

    // MARK: - Editor commands

    // These act on the front window's current editor group wherever the keyboard focus is (the sidebar, the
    // terminal), so they live at the end of the responder chain rather than on the text view.

    @objc func goToSymbolInFile(_ sender: Any?) { activeWindow?.editorArea.showSymbolPicker() }

    @objc func formatDocument(_ sender: Any?) { activeWindow?.editorArea.formatCurrentDocument(selectionOnly: false) }

    @objc func formatSelection(_ sender: Any?) { activeWindow?.editorArea.formatCurrentDocument(selectionOnly: true) }

    @objc func reopenClosedTab(_ sender: Any?) { activeWindow?.editorArea.reopenClosedTab() }

    @objc func closeOtherTabs(_ sender: Any?) { closeTabs(.others) }

    @objc func closeTabsToTheRight(_ sender: Any?) { closeTabs(.toTheRight) }

    @objc func closeAllTabs(_ sender: Any?) { closeTabs(.all) }

    private func closeTabs(_ set: EditorAreaViewController.TabSet) {
        guard let area = activeWindow?.editorArea else { return }
        area.closeTabs(set, relativeTo: area.selectedIndex)
    }

    @objc func showKeyboardShortcuts(_ sender: Any?) {
        shortcutsEditor.showWindow(sender)
        shortcutsEditor.window?.makeKeyAndOrderFront(sender)
    }

    /// After a shortcut was changed: the menu bar is made again with the new keys. The editor's own keys
    /// (EditorOnlyKeys) come back in whatever state they were.
    func rebuildMenu() {
        let editorHadKeys = EditorOnlyKeys.isActive
        EditorOnlyKeys.forgetAll()
        KeyBindings.shared.reload()
        // The Open Recent menu is kept across rebuilds; it can hang off only one item at a time.
        recentMenu.supermenu?.items.first { $0.submenu === recentMenu }?.submenu = nil
        NSApp.mainMenu = buildMenu()
        EditorOnlyKeys.setActive(editorHadKeys)
    }

    private lazy var extensionsWindow = ExtensionsWindowController()

    /// Feather ▸ Extensions…: the optional parts of Feather, with a switch each.
    @objc func showExtensions(_ sender: Any?) { extensionsWindow.showWindow(sender) }

    /// The feed offered an update marked critical: every window says so until it is installed.
    @objc private func requiredUpdateFound() {
        guard let version = AppUpdater.shared.requiredUpdate?.displayVersionString else { return }
        for window in NSApp.windows where window.windowController is MainWindowController {
            let card = NoticeCard(kind: "required-update", symbol: "exclamationmark.arrow.circlepath",
                                  text: AppUpdater.requiredUpdateText(version: version),
                                  actions: [.init(title: "Install Now", isProminent: true) { AppUpdater.shared.checkForUpdates(nil) }],
                                  dismissTitle: "Later")
            WindowNotices.show(card, in: window)
        }
    }

    /// Feather ▸ Reset Feather…: forgets every setting, the saved session, recent folders, trust decisions and
    /// Feather's own caches (checkpoints, language servers stay). Projects and their `.feather` folders are untouched.
    @objc func resetFeather(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Reset Feather?"
        alert.informativeText = "Settings, the saved session, recent folders, folder trust and Feather's own caches go back to how they were on a first install. Your projects and files are not touched. Feather quits afterwards; open it again to start fresh."
        alert.addButton(withTitle: "Reset and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        FeatherReset.perform()
        exit(0)
    }

    @objc func showReleaseNotes(_ sender: Any?) {
        guard let controller = (NSApp.keyWindow?.windowController as? MainWindowController) ?? windows.first else { return }
        controller.window?.makeKeyAndOrderFront(sender)
        ReleaseNotes.show(in: controller)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        AppUpdater.shared.checkForUpdates(sender)
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
            if title == "Window" { NSApp.windowsMenu = menu }
            if title == "Help" { NSApp.helpMenu = menu }
        }
        func item(_ title: String, _ action: Selector, _ key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = [.command], tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = tag
            KeyBindings.shared.apply(to: item)          // the user's own shortcut, if one was set
            return item
        }
        /// An invisible item that only contributes an extra keyboard shortcut. It is not a command of its own in
        /// the Keyboard Shortcuts editor, so it keeps its key whatever the visible item's is changed to.
        func alias(_ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
            let hidden = NSMenuItem(title: "", action: action, keyEquivalent: key)
            hidden.keyEquivalentModifierMask = modifiers
            hidden.isHidden = true
            hidden.allowsKeyEquivalentWhenHidden = true
            return hidden
        }
        let finder = #selector(NSTextView.performTextFinderAction(_:))
        let upArrow = "\u{F700}", downArrow = "\u{F701}"          // NSUpArrowFunctionKey, NSDownArrowFunctionKey

        let colorMenu = NSMenu(title: "Project Color")
        let paletteItem = NSMenuItem()
        paletteItem.view = ColorPaletteView(action: #selector(MainWindowController.chooseProjectColorFromPalette(_:)))
        colorMenu.addItem(paletteItem)
        colorMenu.addItem(.separator())
        colorMenu.addItem(item("More Colors…", #selector(MainWindowController.chooseCustomProjectColor(_:))))
        colorMenu.addItem(item("Window Border", #selector(MainWindowController.toggleProjectBorder(_:))))
        colorMenu.addItem(.separator())
        // No stored value means "follow the project's .vscode/settings.json, if it sets a colour".
        colorMenu.addItem(item("Use Color from .vscode/settings.json", #selector(MainWindowController.chooseProjectColor(_:))))
        let noColor = item("No Color", #selector(MainWindowController.chooseProjectColor(_:)))
        noColor.representedObject = ProjectColor.none
        colorMenu.addItem(noColor)
        colorMenu.addItem(.separator())
        colorMenu.addItem(item("Open Project Settings (.feather/settings.json)", #selector(MainWindowController.openProjectSettings(_:))))
        let colorItem = NSMenuItem(title: "Project Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colorMenu
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recentItem.submenu = recentMenu

        let linesMenu = NSMenu(title: "Lines")
        for entry in [
            item("Move Line Up", #selector(CodeTextView.moveLinesUp(_:)), upArrow, [.option]),
            item("Move Line Down", #selector(CodeTextView.moveLinesDown(_:)), downArrow, [.option]),
            item("Copy Line Up", #selector(CodeTextView.copyLinesUp(_:)), upArrow, [.option, .shift]),
            item("Copy Line Down", #selector(CodeTextView.copyLinesDown(_:)), downArrow, [.option, .shift]),
            item("Insert Line Below", #selector(CodeTextView.insertLineBelow(_:)), "\r"),
            item("Insert Line Above", #selector(CodeTextView.insertLineAbove(_:)), "\r", [.command, .shift]),
            .separator(),
            item("Delete Line", #selector(CodeTextView.deleteLines(_:)), "k", [.command, .shift]),
            item("Indent Lines", #selector(CodeTextView.indentLines(_:)), "]"),
            item("Outdent Lines", #selector(CodeTextView.outdentLines(_:)), "["),
        ] { linesMenu.addItem(entry) }
        // ⌥↑, ⌥↓ and ⌘↩ belong to the editor only while it has the keyboard.
        EditorOnlyKeys.claim(linesMenu.items.filter { ["\r", upArrow, downArrow].contains($0.keyEquivalent) })
        let linesItem = NSMenuItem(title: "Lines", action: nil, keyEquivalent: "")
        linesItem.submenu = linesMenu

        let cursorsMenu = NSMenu(title: "Cursors")
        for entry in [
            item("Add Selection to Next Find Match", #selector(CodeTextView.addSelectionToNextFindMatch(_:)), "d"),
            item("Select All Occurrences", #selector(CodeTextView.selectAllOccurrences(_:)), "l", [.command, .shift]),
            item("Add Cursor Above", #selector(CodeTextView.addCursorAbove(_:)), upArrow, [.command, .option]),
            item("Add Cursor Below", #selector(CodeTextView.addCursorBelow(_:)), downArrow, [.command, .option]),
        ] { cursorsMenu.addItem(entry) }
        // Like the line keys: these mean something only while a code editor has the keyboard.
        EditorOnlyKeys.claim(cursorsMenu.items)
        let cursorsItem = NSMenuItem(title: "Cursors", action: nil, keyEquivalent: "")
        cursorsItem.submenu = cursorsMenu

        let foldingMenu = NSMenu(title: "Folding")
        for entry in [
            item("Fold", #selector(CodeTextView.foldBlock(_:)), "[", [.command, .control]),
            item("Unfold", #selector(CodeTextView.unfoldBlock(_:)), "]", [.command, .control]),
            item("Fold All", #selector(CodeTextView.foldAllBlocks(_:)), "{", [.command, .control, .shift]),        // ⌃⇧⌘[
            item("Unfold All", #selector(CodeTextView.unfoldAllBlocks(_:)), "}", [.command, .control, .shift]),    // ⌃⇧⌘]
        ] { foldingMenu.addItem(entry) }
        let foldingItem = NSMenuItem(title: "Folding", action: nil, keyEquivalent: "")
        foldingItem.submenu = foldingMenu

        submenu("Feather", [
            item("About Feather", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Check for Updates…", #selector(checkForUpdates(_:))),
            item("Settings…", #selector(showPreferences(_:)), ","),
            item("Import VS Code Theme…", #selector(importVSCodeTheme(_:))),
            item("Extensions…", #selector(showExtensions(_:))),
            item("Reset Feather…", #selector(resetFeather(_:))),
        ] + CommandLineTool.shared.menuItems() + [
            .separator(),
            item("Hide Feather", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit Feather", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("File", [
            item("New File", #selector(MainWindowController.newDocument(_:)), "n"),
            item("New Window", #selector(newWindow(_:)), "n", [.command, .shift]),
            item("Open…", #selector(MainWindowController.openDocument(_:)), "o"),
            recentItem,
            .separator(),
            item("Manage Folder Trust…", #selector(MainWindowController.manageTrust(_:))),
            .separator(),
            item("Save", #selector(MainWindowController.saveDocument(_:)), "s"),
            item("Save As…", #selector(MainWindowController.saveDocumentAs(_:)), "s", [.command, .shift]),
            item("Save All", #selector(MainWindowController.saveAllDocuments(_:)), "s", [.command, .option]),
            .separator(),
            item("Close Tab", #selector(MainWindowController.closeTab(_:)), "w"),
            item("Close Other Tabs", #selector(closeOtherTabs(_:)), "t", [.command, .option]),
            item("Close Tabs to the Right", #selector(closeTabsToTheRight(_:))),
            item("Close All Tabs", #selector(closeAllTabs(_:))),
            item("Reopen Closed Tab", #selector(reopenClosedTab(_:)), "t", [.command, .shift]),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find…", finder, "f", tag: NSTextFinder.Action.showFindInterface.rawValue),
            item("Find and Replace…", finder, "f", [.command, .option], tag: NSTextFinder.Action.showReplaceInterface.rawValue),
            item("Find Next", finder, "g", tag: NSTextFinder.Action.nextMatch.rawValue),
            item("Find Previous", finder, "g", [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue),
            item("Use Selection for Find", finder, "e", tag: NSTextFinder.Action.setSearchString.rawValue),
            .separator(),
            item("Find in Project…", #selector(MainWindowController.findInProject(_:)), "f", [.command, .shift]),
            .separator(),
            item("Toggle Line Comment", #selector(CodeTextView.toggleComment(_:)), "/"),
            linesItem,
            .separator(),
            item("Format Document", #selector(formatDocument(_:)), "f", [.option, .shift]),
            item("Format Selection", #selector(formatSelection(_:))),
            .separator(),
            item("Trigger Completion", #selector(CodeTextView.triggerCompletion(_:)), " ", [.control]),
            .separator(),
            cursorsItem,
            .separator(),
            item("Ask AI Assistant About Selection", #selector(MainWindowController.askAboutSelection(_:)), "k", [.control, .option]),
            .separator(),
            item("Replace in Project…", #selector(MainWindowController.replaceInProject(_:)), "h", [.command, .shift]),
        ])
        submenu("View", [
            item("Command Palette…", #selector(showCommandPalette(_:)), "p", [.command, .shift]),
            .separator(),
            item("Toggle Sidebar", #selector(MainWindowController.toggleSidebarPane(_:)), "b"),
            item("Explorer", #selector(MainWindowController.showExplorer(_:)), "e", [.command, .shift]),
            item("Source Control", #selector(MainWindowController.showSourceControl(_:)), "g", [.control, .shift]),
            item("Git Graph", #selector(MainWindowController.showGitGraph(_:)), "h", [.control, .shift]),
            item("Problems", #selector(MainWindowController.showProblems(_:)), "m", [.command, .shift]),
            item("TODO Comments", #selector(MainWindowController.showTodos(_:))),
            item("Toggle Markdown Preview", #selector(MainWindowController.toggleMarkdownPreview(_:)), "v", [.command, .shift]),
            item("Open Markdown Preview to the Side", #selector(MainWindowController.openMarkdownPreviewToSide(_:)), "v", [.command, .option]),
            item("Show Preview", #selector(MainWindowController.showPreviewNow(_:)), "p", [.control, .option]),
            item("Show Preview to the Side", #selector(MainWindowController.showPreviewToSide(_:)), "p", [.control, .option, .shift]),
            item("New Preview Tab", #selector(MainWindowController.newPreviewTab(_:)), "n", [.control, .option]),
            item("Open App in Browser", #selector(MainWindowController.openAppInBrowser(_:)), "b", [.control, .option]),
            item("Open Preview at Another Address…", #selector(MainWindowController.openPreview(_:))),
            item("Preview This Page", #selector(MainWindowController.previewThisPage(_:))),
            item("Split Editor Right", #selector(MainWindowController.splitEditor(_:)), "\\"),
            item("Focus Next Editor Group", #selector(MainWindowController.focusNextGroup(_:)), "\\", [.command, .option]),
            .separator(),
            colorItem,
            item("Toggle Word Wrap", #selector(MainWindowController.toggleWordWrap(_:)), "z", [.option]),
            item("Increase Font Size", #selector(MainWindowController.increaseFontSize(_:)), "="),
            item("Decrease Font Size", #selector(MainWindowController.decreaseFontSize(_:)), "-"),
            .separator(),
            foldingItem,
            .separator(),
            item("Terminal on the Right", #selector(MainWindowController.toggleTerminalOnRight(_:))),
        ])
        submenu("Go", [
            item("Quick Open…", #selector(MainWindowController.showQuickOpen(_:)), "p"),
            item("Back", #selector(MainWindowController.goBack(_:)), "-", [.control]),
            item("Forward", #selector(MainWindowController.goForward(_:)), "_", [.control, .shift]),
            .separator(),
            item("Go to Line…", #selector(MainWindowController.goToLine(_:)), "g", [.control]),
            item("Go to Symbol in File…", #selector(goToSymbolInFile(_:)), "o", [.command, .shift]),
            item("Go to Symbol in Workspace…", #selector(MainWindowController.goToSymbolInWorkspace(_:)), "t"),
            item("Go to Matching Bracket", #selector(CodeTextView.goToMatchingBracket(_:)), "|", [.command, .shift]),      // ⇧⌘\
            item("Go to Definition", #selector(CodeTextView.goToDefinition(_:)),
                 String(UnicodeScalar(NSF12FunctionKey)!), []),
            item("Find References", #selector(CodeTextView.findReferences(_:)),
                 String(UnicodeScalar(NSF12FunctionKey)!), [.shift]),
            item("Rename Symbol…", #selector(CodeTextView.renameSymbol(_:)), String(UnicodeScalar(NSF2FunctionKey)!), []),
            item("Show Quick Info", #selector(CodeTextView.showQuickInfo(_:)), "i", [.command, .option]),
            .separator(),
            item("Next Tab", #selector(MainWindowController.nextTab(_:)), "]", [.command, .shift]),
            item("Previous Tab", #selector(MainWindowController.previousTab(_:)), "[", [.command, .shift]),
            alias(#selector(MainWindowController.nextTab(_:)), "\t", [.control]),
            alias(#selector(MainWindowController.previousTab(_:)), "\t", [.control, .shift]),
        ])
        submenu("Run", [
            item("Run Project", #selector(MainWindowController.runProject(_:)), "r"),
            item("Run Current File", #selector(MainWindowController.runCurrentFile(_:)), "r", [.command, .shift]),
            item("Stop", #selector(MainWindowController.stopRunning(_:)), "."),
            .separator(),
            item("Edit Run Command…", #selector(MainWindowController.editRunCommand(_:))),
            .separator(),
            item("Check Project for Errors", #selector(MainWindowController.checkProject(_:)), "b", [.command, .shift]),
        ])
        // Everything about the terminal in one place, rather than spread over View and Run.
        let chooserItem = NSMenuItem(title: "Choose AI Assistant", action: nil, keyEquivalent: "")
        chooserItem.submenu = AssistantChooser.shared.makeMenu()
        submenu("Terminal", [
            item("New Terminal", #selector(MainWindowController.newTerminal(_:)), "`", [.control, .shift]),
            item("Show or Hide Terminal", #selector(MainWindowController.toggleTerminal(_:)), "`", [.control]),
            alias(#selector(MainWindowController.toggleTerminal(_:)), "j", [.command]),
            item("Maximize Terminal", #selector(MainWindowController.toggleTerminalMaximized(_:)), "m", [.control, .shift]),
            item("Copy on Select", #selector(MainWindowController.toggleTerminalCopyOnSelect(_:))),
            .separator(),
            item("Open Shell Integration Files", #selector(MainWindowController.openShellIntegrationFiles(_:))),
            item("Reveal Shell Integration Folder in Finder", #selector(MainWindowController.revealShellIntegrationFolder(_:))),
            .separator(),
            item("Next Terminal", #selector(MainWindowController.nextTerminal(_:)), "]", [.command, .option]),
            item("Previous Terminal", #selector(MainWindowController.previousTerminal(_:)), "[", [.command, .option]),
            .separator(),
            item("Run Task…", #selector(MainWindowController.showRunTask(_:)), "r", [.command, .option]),
            item("Rerun Last Task", #selector(MainWindowController.rerunLastTask(_:)), "r", [.command, .option, .shift]),
            .separator(),
            item("Send Selection to Terminal", #selector(MainWindowController.sendSelectionToTerminal(_:)), "s", [.control, .option]),
            item("Send File Reference to Terminal", #selector(MainWindowController.sendFileReferenceToTerminal(_:)), "l", [.control, .option]),
            .separator(),
            item("Start AI Assistant", #selector(MainWindowController.startAIAssistant(_:)), "a", [.control, .option]),
            chooserItem,
            .separator(),
            item("Split Terminal", #selector(MainWindowController.splitTerminal(_:)), "5", [.control, .shift]),
        ])
        submenu("Git", [
            item("Open Changes for Current File", #selector(MainWindowController.openChangesForCurrentFile(_:)), "d", [.control, .shift]),
            .separator(),
            item("Pull", #selector(MainWindowController.gitPull(_:))),
            item("Push", #selector(MainWindowController.gitPush(_:))),
            item("Sync Changes (Pull, then Push)", #selector(MainWindowController.gitSync(_:)), "s", [.control, .shift]),
            item("Fetch", #selector(MainWindowController.gitFetch(_:))),
            .separator(),
            item("Stash Changes…", #selector(MainWindowController.stashChanges(_:))),
            item("Pop Latest Stash", #selector(MainWindowController.popLatestStash(_:))),
            .separator(),
            item("Open on GitHub", #selector(MainWindowController.openOnGitHub(_:))),
            item("Copy GitHub Link", #selector(MainWindowController.copyGitHubLink(_:))),
            item("Open Repository on GitHub", #selector(MainWindowController.openRepositoryOnGitHub(_:))),
            item("Open Pull Requests on GitHub", #selector(MainWindowController.openPullRequestsOnGitHub(_:))),
            .separator(),
            item("Toggle Blame in the Status Bar", #selector(MainWindowController.toggleBlame(_:))),
        ])
        ExtensionRegistry.shared.menuItems().forEach(main.addItem)         // an extension's own menu, while it is on
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        submenu("Help", [
            item("Keyboard Shortcuts", #selector(showKeyboardShortcuts(_:))),
            item("What’s New in Feather", #selector(showReleaseNotes(_:))),
            .separator(),
            item("Manage Folder Trust…", #selector(MainWindowController.manageTrust(_:))),
            .separator(),
            item("Check for Updates…", #selector(checkForUpdates(_:))),
        ])
        ActivityMenu.install(in: main)
        return main
    }
}
