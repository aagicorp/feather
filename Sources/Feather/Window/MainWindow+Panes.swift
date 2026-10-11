import AppKit

/// The View menu and the sidebar: its panes, editor tabs and groups, the Problems pane, Quick Open, zoom.
extension MainWindowController {
    // MARK: - Editor tabs and groups

    @objc func splitEditor(_ sender: Any?) { editors.splitActive() }

    @objc func toggleMarkdownPreview(_ sender: Any?) { editorArea.togglePreview() }

    @objc func openMarkdownPreviewToSide(_ sender: Any?) { editors.openPreviewToSide() }

    @objc func focusNextGroup(_ sender: Any?) { editors.focusGroup(1) }

    @objc func closeTab(_ sender: Any?) {
        if editorArea.currentTab == nil {
            window?.performClose(sender)
        } else {
            editorArea.close(at: editorArea.selectedIndex)
        }
    }

    @objc func nextTab(_ sender: Any?) { editorArea.selectAdjacent(1) }

    @objc func previousTab(_ sender: Any?) { editorArea.selectAdjacent(-1) }

    // MARK: - Sidebar panes

    @objc func toggleSidebarPane(_ sender: Any?) {
        sidebarItem.animator().isCollapsed.toggle()
    }

    @objc func showSourceControl(_ sender: Any?) {
        if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
        sidebarContainer.show(pane: 2)
        sourceControl.focusMessage()
    }

    @objc func showExplorer(_ sender: Any?) {
        if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
        sidebarContainer.show(pane: 0)
    }

    /// Also what a click on the status bar's server label sends.
    /// The Activity pane: what changed since the checkpoint. The welcome screen sends this too.
    @objc func showActivity(_ sender: Any?) {
        if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
        sidebarContainer.show(pane: SidebarContainerViewController.activityPane)
        if let window { HintCards.showOnce(.activity, in: window) }
    }

    // MARK: - Problems, TODOs and terminal links

    /// The document store already listens for diagnostics (it gives them to open documents); the Problems store
    /// is chained behind it, so it also hears about files that are not open. Called once, from `init`.
    func installProblems() {
        let problems = sidebarContainer.problems
        _ = store
        let toDocuments = lsp.onDiagnostics
        lsp.onDiagnostics = { [weak problems] url, items in
            toDocuments?(url, items)
            problems?.store.set(items, for: url)
        }
        let statusChanged = lsp.onStatusChange
        lsp.onStatusChange = { [weak self, weak problems] in
            // A server that stopped will never clear what it reported.
            if let lsp = self?.lsp { problems?.store.prune { lsp.hasServer(for: $0) } }
            statusChanged?()
        }
        problems.store.onCountsChange = { [weak self, weak problems] in
            guard let self, let problems else { return }
            self.statusBar.problemTotals = (problems.store.errorCount, problems.store.warningCount)
            self.statusBar.update(tab: self.editorArea.currentTab, lsp: self.lsp)
        }
        problems.onOpen = { [weak self] in self?.navigate(to: $0) }
        problems.onFixThis = { [weak self] in self?.fixThis($0) }
        terminalPane.onOpenFile = { [weak self] url, line, column in
            guard let self else { return }
            guard let line else { self.editorArea.open(url); return }
            // Tools print one-based positions.
            let character = max(0, (column ?? 1) - 1)
            self.navigate(to: LSPLocation(url: url, line: max(0, line - 1), character: character,
                                          endLine: max(0, line - 1), endCharacter: character))
        }
    }

    /// Opens a place the way Go to Definition does, with one difference: the top of the newly opened file, where
    /// the cursor sits for an instant before it is moved, is not recorded as a place of its own. One Back
    /// returns to where the jump was made from.
    func navigate(to location: LSPLocation) {
        recordCurrentPlace()
        isReplayingHistory = true
        editors.open(location)
        isReplayingHistory = false
        recordCurrentPlace()
    }

    /// Also what a click on the status bar's error and warning counts sends.
    @objc func showProblems(_ sender: Any?) {
        if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
        sidebarContainer.show(pane: SidebarContainerViewController.problemsPane)
        sidebarContainer.problems.show(.problems)
    }

    @objc func showTodos(_ sender: Any?) {
        if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
        sidebarContainer.show(pane: SidebarContainerViewController.problemsPane)
        sidebarContainer.problems.show(.todos)
    }

    @objc func findInProject(_ sender: Any?) {
        if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
        sidebarContainer.show(pane: 1)
        var selection: String?
        if let textView = editorArea.currentTab?.editorIfLoaded?.textView, textView.selectedRange().length > 0 {
            selection = (textView.string as NSString).substring(with: textView.selectedRange())
        }
        sidebarContainer.search.focus(prefill: selection)
    }

    @objc func showQuickOpen(_ sender: Any?) {
        guard let window, let root = sidebar.rootURL else {
            openDocument(sender)
            return
        }
        quickOpen.show(over: window, root: root)
    }

    /// ⌘+ and ⌘− zoom whatever is in front: a picture if one is showing, otherwise the editor's text.
    @objc func increaseFontSize(_ sender: Any?) {
        if let media = editorArea.currentTab?.preview as? MediaPreviewView { media.zoom(by: 1.25) } else { Settings.shared.fontSize += 1 }
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        if let media = editorArea.currentTab?.preview as? MediaPreviewView { media.zoom(by: 1 / 1.25) } else { Settings.shared.fontSize -= 1 }
    }

    @objc func toggleWordWrap(_ sender: Any?) { Settings.shared.wrapLines.toggle() }
}
