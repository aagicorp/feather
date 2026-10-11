import AppKit

/// The window's side of the project checker: the menu command, the results into the Problems pane and the open
/// editors, and the run after a save.
extension MainWindowController {
    func installProjectChecker() {
        let problems = sidebarContainer.problems
        checker.onResults = { [weak self, weak problems] run in
            guard let self, let problems, run.root == self.projectRoot else { return }
            problems.store.setChecker(run.name, run.diagnostics, scope: run.scope)
            self.checkerDidFinish(run)
        }
        checker.onStateChange = { [weak self, weak problems] in
            guard let self, let problems else { return }
            let last = self.checker.lastRun
            problems.setCheckerStatus(name: self.checker.runningName ?? last?.name, date: last?.date,
                                      running: self.checker.isRunning, error: last?.error)
        }
        checker.onRootChange = { [weak problems] in problems?.store.clearCheckers() }
        // The editors show what the pane shows: a checker's rows get squiggles where no server is speaking.
        problems.store.onCheckerChange = { [weak self, weak problems] urls in
            guard let self, let problems else { return }
            for url in urls {
                guard let document = self.store.existingDocument(at: url) else { continue }
                document.diagnostics = problems.store.diagnostics[url] ?? []
            }
        }
        problems.onCheckProject = { [weak self] in self?.checkProject(nil) }
        let center = NotificationCenter.default
        center.addObserver(forName: DocumentStore.didSaveDocument, object: store, queue: .main) { [weak self] note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            self?.checker.fileSaved(url)
        }
        // A file opened after a run takes up the checker's findings for it.
        center.addObserver(forName: TextDocument.stateDidChange, object: nil, queue: .main) { [weak self, weak problems] note in
            guard let self, let problems, let document = note.object as? TextDocument, document.store === self.store,
                  let url = document.url, document.diagnostics.isEmpty, !problems.store.isSpokenForByServer(url),
                  let items = problems.store.diagnostics[url], !items.isEmpty else { return }
            document.diagnostics = items
        }
    }

    /// Run ▸ Check Project for Errors (⇧⌘B), the Problems pane's button and the Command Palette.
    @objc func checkProject(_ sender: Any?) {
        guard let root = projectRoot else { NSSound.beep(); return }
        if WorkspaceTrust.shared.blocksExecution(in: root) {
            // Like Run: a compiler runs the project's own build scripts, which is what Restricted Mode withholds.
            manageTrust(nil)
            if WorkspaceTrust.shared.blocksExecution(in: root) { return }
        }
        showProblems(nil)
        checker.forgetDetection()             // a tool installed since the last run is picked up now
        checker.checkProject { [weak self] commands in
            guard let self, commands.isEmpty, let window = self.window else { return }
            let card = NoticeCard(kind: "checker", symbol: "questionmark.circle",
                                  text: "Feather found nothing to check this project with. It looks for tsconfig.json with TypeScript installed, Python with pyright or pyflakes, pom.xml with Maven, build.gradle, pubspec.yaml with Dart, and Package.swift.",
                                  actions: [], dismissTitle: "OK")
            WindowNotices.show(card, in: window)
        }
    }

    private func checkerDidFinish(_ run: CheckerRun) {
        guard let error = run.error, let window, run.diagnostics.isEmpty else { return }
        // A save-triggered run keeps quiet about a tool that failed; the pane's status shows it on hover.
        guard window.isKeyWindow, sidebarContainer.problems.view.window != nil else { return }
        let card = NoticeCard(kind: "checker", symbol: "exclamationmark.triangle", text: error, actions: [], dismissTitle: "OK")
        WindowNotices.show(card, in: window)
    }
}
