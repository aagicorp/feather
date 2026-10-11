import AppKit

/// Starting the AI assistant and typing to it: Fix This, Ask About Selection.
extension MainWindowController {
    // MARK: - AI assistant (AITools.swift)

    /// Called once, from `init`.
    func installAssistant() {
        if Settings.shared.terminalOnRight { setTerminalOnRight(true) }
        terminalPane.onRevealRequested = { [weak self] in
            guard let self else { return }
            if self.window?.isMiniaturized == true { self.window?.deminiaturize(nil) }
            self.window?.makeKeyAndOrderFront(nil)
            self.showTerminal()
        }
        NotificationCenter.default.addObserver(forName: AITools.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.assistantToolName = AITools.currentChoice?.name
            self?.updateTitleSearch()
        }
        assistantToolName = AITools.currentChoice?.name
        AITools.refresh()
    }

    /// Terminal ▸ Start AI Assistant (⌃⌥A). Shows the assistant if one is already running in this window;
    /// otherwise opens a terminal named after it in the project folder and types its command.
    @objc func startAIAssistant(_ sender: Any?) { startAssistant() }

    /// `asksAboutTrust` false refuses outright in Restricted Mode, as `run(_:asksAboutTrust:)` does. `offersLayout`
    /// false skips the one-time suggestion to move the terminal to the right. Returns false when refused.
    @discardableResult
    func startAssistant(asksAboutTrust: Bool = true, offersLayout: Bool = true,
                        lookup: @escaping (@escaping ([AITool]) -> Void) -> Void = { AITools.refresh(completion: $0) }) -> Bool {
        guard let window, let root = sidebar.rootURL else {
            let alert = NSAlert()
            alert.messageText = "Open your project folder first"
            alert.informativeText = "An AI assistant works on the files of one project. Open the project’s folder, then start the assistant."
            alert.addButton(withTitle: "Open…")
            alert.addButton(withTitle: "Cancel")
            if let window = self.window {
                alert.beginSheetModal(for: window) { [weak self] in if $0 == .alertFirstButtonReturn { self?.openDocument(nil) } }
            }
            return false
        }
        // It runs programs in the project, which is what Restricted Mode withholds: the same gate as Run.
        if isRestricted, !asksAboutTrust || refusesToRun() { return false }
        guard !WorkspaceTrust.shared.blocksExecution(in: root) else { return false }
        if terminalPane.assistantSession() != nil {
            showTerminal()
            terminalPane.sendToAssistant("")
            return true
        }
        lookup { [weak self] installed in
            guard let self, self.sidebar.rootURL == root else { return }
            let settings = Settings.shared
            guard let choice = AITools.choice(setting: settings.aiTool, customCommand: settings.aiToolCustomCommand, installed: installed) else {
                AITools.makeInstallHelp().beginSheetModal(for: window) { [weak self] in
                    if $0 == .alertSecondButtonReturn { self?.newTerminal(nil) }
                }
                return
            }
            let launch = { [weak self] in
                guard let self else { return }
                self.showTerminal()
                self.terminalPane.startAssistant(name: choice.name, command: choice.command)
            }
            guard offersLayout, !self.isTerminalOnRight, !settings.didOfferTerminalOnRight else { return launch() }
            settings.didOfferTerminalOnRight = true
            let alert = NSAlert()
            alert.messageText = "Put the terminal on the right?"
            alert.informativeText = "\(choice.name) is easier to follow in a tall column beside your files than in a strip under them. You can switch at any time with View ▸ Terminal on the Right."
            alert.addButton(withTitle: "Move It to the Right")
            alert.addButton(withTitle: "Keep It at the Bottom")
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn, self?.isTerminalOnRight == false { self?.toggleTerminalOnRight(nil) }
                launch()
            }
        }
        return true
    }

    /// Types `text` at the assistant's prompt, not entered. With no assistant running the user is offered one;
    /// nothing is typed then, because a tool that is still starting may be asking a question of its own.
    private func sendToAssistant(_ text: String) {
        if terminalPane.assistantSession() != nil {
            showTerminal()
            terminalPane.sendToAssistant(text)
            return
        }
        guard let window else { return }
        let name = AITools.currentChoice?.name ?? "an AI assistant"
        let alert = NSAlert()
        alert.messageText = "No AI assistant is running in this window"
        alert.informativeText = "Start \(name), and when it is ready choose the command again."
        alert.addButton(withTitle: "Start \(AITools.currentChoice?.name ?? "AI Assistant")")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] in if $0 == .alertFirstButtonReturn { self?.startAssistant() } }
    }

    /// The same, for commands in other files (an extension's "ask the assistant about…").
    func handToAssistant(_ text: String) { sendToAssistant(text) }

    /// Fix This on a row of the Problems pane.
    func fixThis(_ problem: ProblemItem) {
        sendToAssistant(TerminalText.fixRequest(for: problem, root: sidebar.rootURL))
    }

    /// "src/App.tsx:12-30 " at the assistant's prompt, for the question the user types next.
    @objc func askAboutSelection(_ sender: Any?) {
        guard let reference = TerminalText.fileReference(of: editorArea.currentTab, root: sidebar.rootURL) else { NSSound.beep(); return }
        sendToAssistant(reference + " ")
    }
}
