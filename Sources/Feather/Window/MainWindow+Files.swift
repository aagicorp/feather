import AppKit

/// Opening files and folders, saving, folder trust, and running the project and its tasks.
extension MainWindowController {
    func open(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue { openFolder(url) } else { editorArea.open(url) }
    }

    /// `asksAboutTrust` is false when a session is being put back: a window that reappears at launch does not
    /// interrupt with a question, it opens restricted and says so in the status bar.
    func openFolder(_ url: URL, asksAboutTrust: Bool = true) {
        let trust = WorkspaceTrust.shared
        if let previous = sidebar.rootURL { trust.noteClosed(previous) }
        if !trust.isTrusted(url), asksAboutTrust {
            switch trust.ask(about: url, in: window) {
            case .trust: trust.trust(url)
            case .trustParent: trust.trust(url.deletingLastPathComponent())
            case .restricted: break
            }
        }
        isRestricted = !trust.isTrusted(url)
        trust.noteOpen(url.standardizedFileURL, restricted: isRestricted)
        lsp.isAllowed = !isRestricted
        sidebar.setRoot(url.standardizedFileURL)
        sidebarContainer.search.rootURL = url.standardizedFileURL
        sidebarContainer.problems.rootURL = url.standardizedFileURL
        checker.root = url.standardizedFileURL
        lsp.rootURL = url.standardizedFileURL
        store.projectRoot = url.standardizedFileURL
        sourceControl.setProjectRoot(url.standardizedFileURL)
        activity.setRoot(url.standardizedFileURL)
        graphWindow?.close()
        graphWindow = nil
        refreshBranch()
        watchGit(under: url.standardizedFileURL)
        apiClient?.projectDidChange()
        terminalPane.setDirectory(url)
        Settings.shared.lastFolder = url.path
        Settings.shared.noteRecentFolder(url.standardizedFileURL)
        editors.refreshWelcome()
        applyProjectColor()
        if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
        updateChrome()
        if isRestricted { HintCards.showOnce(.restrictedMode, in: window) }
    }

    // MARK: - Menu actions

    @objc func newDocument(_ sender: Any?) {
        editorArea.newUntitled()
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose a folder to open as a project, or one or more files"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(open)
    }

    @objc func saveDocument(_ sender: Any?) {
        // The editor group's own save formats first when that is switched on; this is the same command arriving
        // while the focus is in the sidebar or the terminal.
        editorArea.saveDocument(sender)
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let document = editorArea.currentTab?.document else { return }
        store.saveAs(document)
    }

    @objc func saveAllDocuments(_ sender: Any?) {
        _ = store.saveAll()
    }

    // MARK: - Running

    private func run(_ configuration: RunConfiguration?) {
        guard let configuration else {
            let alert = NSAlert()
            alert.messageText = "Feather could not work out how to run this."
            alert.informativeText = "Choose Run ▸ Edit Run Command… and type the command for this project, for example “./mvnw spring-boot:run” or “flutter run -d chrome”."
            alert.runModal()
            return
        }
        _ = store.saveAll()
        showTerminal()
        terminalPane.runTask(title: configuration.title, command: configuration.shellCommand)
    }

    /// Running a project executes whatever its files say, which is exactly what Restricted Mode withholds.
    func refusesToRun() -> Bool {
        guard isRestricted else { return false }
        manageTrust(nil)
        return isRestricted
    }

    /// From the status bar's Restricted Mode label and the File menu.
    @objc func manageTrust(_ sender: Any?) {
        guard let root = sidebar.rootURL else { NSSound.beep(); return }
        let trust = WorkspaceTrust.shared
        if trust.isTrusted(root) {
            let alert = NSAlert()
            alert.messageText = "“\(root.lastPathComponent)” is trusted"
            alert.informativeText = trust.isEnabled
                ? "Feather can run this project, check its code as you type and track its changes. Choose Stop Trusting to go back to Restricted Mode."
                : "Folder trust is switched off in Settings, so every folder is treated as trusted."
            alert.addButton(withTitle: "OK")
            if trust.isEnabled, trust.trustedFolders.contains(root.standardizedFileURL.path) { alert.addButton(withTitle: "Stop Trusting") }
            if alert.runModal() == .alertSecondButtonReturn { trust.revoke(root) }
        } else {
            switch trust.ask(about: root, in: window) {
            case .trust: trust.trust(root)
            case .trustParent: trust.trust(root.deletingLastPathComponent())
            case .restricted: break
            }
        }
    }

    /// Trust changed here or in another window (a parent folder may cover this one).
    func trustDidChange() {
        guard let root = sidebar.rootURL else { return }
        let restricted = !WorkspaceTrust.shared.isTrusted(root)
        guard restricted != isRestricted else { return }
        isRestricted = restricted
        WorkspaceTrust.shared.noteOpen(root, restricted: restricted)
        lsp.isAllowed = !restricted
        sourceControl.setProjectRoot(root)
        sidebar.refreshGitDecorations(rediscover: true)
        refreshBranch()
        store.syncWithDisk(refreshGitBases: true)
        updateChrome()
    }

    @objc func runProject(_ sender: Any?) {
        guard !refusesToRun() else { return }
        run(RunConfiguration.detectProject(root: sidebar.rootURL, currentFile: editorArea.currentTab?.url))
    }

    @objc func runCurrentFile(_ sender: Any?) {
        guard !refusesToRun() else { return }
        run(editorArea.currentTab?.url.flatMap(RunConfiguration.currentFile))
    }

    @objc func stopRunning(_ sender: Any?) {
        if !terminalPane.stopTasks() { NSSound.beep() }
    }

    @objc func editRunCommand(_ sender: Any?) {
        guard let root = sidebar.rootURL else { NSSound.beep(); return }
        let detected = RunConfiguration.detectProject(root: root, currentFile: editorArea.currentTab?.url)
        let alert = NSAlert()
        alert.messageText = "Run command for “\(root.lastPathComponent)”"
        alert.informativeText = "Runs from the project folder when you press ⌘R. Leave it empty to detect the command automatically."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.stringValue = RunConfiguration.customCommand(for: root) ?? ""
        field.placeholderString = detected?.command ?? "command"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        RunConfiguration.setCustomCommand(field.stringValue.trimmingCharacters(in: .whitespaces), for: root)
    }

    // MARK: - Tasks (ProjectTasks.swift)

    /// Lists what the project's own files say can be run. The panel comes up at once with what is already known,
    /// and the rows are replaced if a look at the manifests (off the main thread) finds they have changed.
    @objc func showRunTask(_ sender: Any?) {
        guard let window, let root = sidebar.rootURL else { NSSound.beep(); return }
        guard !refusesToRun() else { return }
        taskList.setRoot(root)
        shownTasks = taskList.tasks
        taskPanel.show(over: window, items: taskItems(shownTasks, root: root, isLooking: true)) { [weak self] index in
            guard let self, self.shownTasks.indices.contains(index) else { return }
            self.run(self.shownTasks[index])
        }
        taskList.refresh { [weak self] tasks in
            guard let self, self.taskPanel.isVisible, self.sidebar.rootURL == root else { return }
            self.shownTasks = tasks
            self.taskPanel.setItems(self.taskItems(tasks, root: root, isLooking: false))
        }
    }

    private func taskItems(_ tasks: [ProjectTask], root: URL, isLooking: Bool) -> [FilterPanelController.Item] {
        if tasks.isEmpty {
            return [FilterPanelController.Item(title: isLooking ? "Looking for tasks…" : "No tasks found in this project",
                                               detail: isLooking ? "" : "add \"tasks\" to .feather/settings.json")]
        }
        return tasks.map { task in
            let folder = task.folder(relativeTo: root)
            return FilterPanelController.Item(title: task.name, detail: task.command + "  —  " + (folder.isEmpty ? task.source : "\(folder)  ·  \(task.source)"))
        }
    }

    /// Runs a task in a terminal named after it. `asksAboutTrust` false refuses outright in Restricted Mode
    /// instead of putting the trust question first. Returns whether the task was started.
    @discardableResult
    func run(_ task: ProjectTask, asksAboutTrust: Bool = true) -> Bool {
        guard let root = sidebar.rootURL else { return false }
        if isRestricted, !asksAboutTrust || refusesToRun() { return false }
        guard !WorkspaceTrust.shared.blocksExecution(in: task.directory) else { return false }
        ProjectTaskList.noteRun(task, in: root)
        _ = store.saveAll()
        showTerminal()
        terminalPane.runTask(title: task.title(relativeTo: root), command: task.shellCommand)
        return true
    }

    @objc func rerunLastTask(_ sender: Any?) {
        guard let root = sidebar.rootURL, let last = ProjectTaskList.recents(for: root).first else {
            showRunTask(sender)          // nothing to repeat yet: choosing one is the next best thing
            return
        }
        run(last)
    }
}
