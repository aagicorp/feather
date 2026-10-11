import AppKit

/// The terminal pane as the window sees it: showing, hiding, maximizing and moving it to the right, and the
/// Terminal menu's actions.
extension MainWindowController {
    // MARK: - Showing and hiding

    @objc func nextTerminal(_ sender: Any?) {
        showTerminal()
        terminalPane.startIfNeeded()
        terminalPane.selectAdjacent(1)
    }

    @objc func previousTerminal(_ sender: Any?) {
        showTerminal()
        terminalPane.startIfNeeded()
        terminalPane.selectAdjacent(-1)
    }

    @objc func newTerminal(_ sender: Any?) {
        showTerminal()
        terminalPane.newTerminal()
    }

    /// Terminal ▸ Open Shell Integration Files: the zsh files Feather points new terminals at, as tabs, so what
    /// runs at the start of a terminal can be read. Also in the Command Palette.
    @objc func openShellIntegrationFiles(_ sender: Any?) {
        guard let folder = ShellIntegration.installZsh() else { NSSound.beep(); return }
        for name in [".zshenv", ".zprofile", ".zshrc"] { editorArea.open(folder.appendingPathComponent(name)) }
    }

    @objc func revealShellIntegrationFolder(_ sender: Any?) {
        guard let folder = ShellIntegration.installZsh() else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(".zshrc")])
    }

    /// Terminal ▸ Copy on Select: selecting text in a terminal copies it.
    @objc func toggleTerminalCopyOnSelect(_ sender: Any?) { Settings.shared.terminalCopyOnSelect.toggle() }

    /// Terminal ▸ Maximize Terminal (⌃⇧M), the button in the terminal's header, or a double-click on that header.
    /// The editors collapse and the terminal takes their room; they return when it is toggled again or the
    /// terminal hidden. The sidebar is left alone, so it can be opened and closed meanwhile.
    @objc func toggleTerminalMaximized(_ sender: Any?) {
        if isTerminalMaximized {
            isTerminalMaximized = false
            editorItem.isCollapsed = false
            placeTerminalDivider()
            editorArea.focus()
        } else {
            if terminalItem.isCollapsed {
                showTerminal()
                terminalPane.startIfNeeded()
            } else {
                let size = terminalItem.viewController.view.frame.size        // the panel, insets and all
                terminalThickness[isTerminalOnRight] = isTerminalOnRight ? size.width : size.height
            }
            isTerminalMaximized = true
            editorItem.isCollapsed = true
            terminalPane.focus()
        }
        terminalPane.isMaximized = isTerminalMaximized
    }

    func showTerminal() {
        guard terminalItem.isCollapsed else { return }
        terminalItem.isCollapsed = false
        if !terminalSized {
            terminalSized = true
            placeTerminalDivider()
        }
        terminalPane.clearAttentionIfSeen()
    }

    /// Also what the pane's own close button asks for.
    func hideTerminal() {
        guard !terminalItem.isCollapsed else { return }
        if isTerminalMaximized { toggleTerminalMaximized(nil) }
        terminalItem.isCollapsed = true
        repositoryDidChange(from: nil)
        editorArea.focus()
    }

    @objc func toggleTerminal(_ sender: Any?) {
        if terminalItem.isCollapsed {
            showTerminal()
            terminalPane.startIfNeeded()
            terminalPane.focus()
            refreshBranch()
        } else {
            hideTerminal()
        }
    }

    // MARK: - Send to Terminal (SendToTerminal.swift)

    /// The selection, or the line the caret is on, typed into the terminal and entered. For trying a line in a REPL.
    /// The keyboard stays in the editor, so the next line can follow.
    @objc func sendSelectionToTerminal(_ sender: Any?) {
        guard let text = TerminalText.selectionOrLine(of: editorArea.currentTab) else { NSSound.beep(); return }
        showTerminal()
        terminalPane.sendText(text)
    }

    /// "src/App.tsx:12-30" typed at the terminal's prompt, not entered: for telling a command-line tool which
    /// code you mean. The keyboard moves to the terminal, where the rest of the sentence gets typed.
    @objc func sendFileReferenceToTerminal(_ sender: Any?) {
        guard let reference = TerminalText.fileReference(of: editorArea.currentTab, root: sidebar.rootURL) else { NSSound.beep(); return }
        showTerminal()
        terminalPane.sendText(reference + " ")
        terminalPane.focus()
    }

    // MARK: - Terminal on the right

    @objc func toggleTerminalOnRight(_ sender: Any?) {
        setTerminalOnRight(!isTerminalOnRight)
        Settings.shared.terminalOnRight = isTerminalOnRight         // what the next new window starts with
    }

    func setTerminalOnRight(_ onRight: Bool) {
        guard onRight != isTerminalOnRight else { return }
        if isTerminalMaximized { toggleTerminalMaximized(nil) }
        let splitView = innerSplit.splitView
        let isShowing = !terminalItem.isCollapsed
        if isShowing {
            let size = terminalItem.viewController.view.frame.size
            terminalThickness[isTerminalOnRight] = isTerminalOnRight ? size.width : size.height
        }
        isTerminalOnRight = onRight
        splitView.isVertical = onRight
        updatePanelInsets()
        terminalItem.minimumThickness = onRight ? 240 : 90
        terminalPane.isTall = onRight
        splitView.adjustSubviews()
        terminalSized = isShowing
        if isShowing { placeTerminalDivider() }
    }

    /// The remembered size for this layout, or the default: 260 points high, or 45% of the width.
    private func placeTerminalDivider() {
        let splitView = innerSplit.splitView
        splitView.layoutSubtreeIfNeeded()
        let length = isTerminalOnRight ? splitView.bounds.width : splitView.bounds.height
        let wanted = terminalThickness[isTerminalOnRight] ?? (isTerminalOnRight ? (length * 0.45).rounded() : 260)
        splitView.setPosition(max(120, length - wanted - splitView.dividerThickness), ofDividerAt: 0)
    }
}
