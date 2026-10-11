import AppKit

/// Screenshots for the website and the README: `FEATHER_SHOTS=<folder> .build/debug/Feather` (tools/shots.sh)
/// opens Feather's own repository, which is a real project, stages one state after another and captures the
/// window from the window server (so the terminal, the glass and the project colour are in the picture). No
/// checks, just pictures; the folder gets one PNG per state. The theme is put back at the end.
extension UITestHarness {
    static let shotScenarios: [Scenario] = {
        let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func file(_ path: String) -> URL { repo.appendingPathComponent(path) }
        let themeBefore = Settings.shared.themeName
        /// Every tab in every group, so a diff or a preview opened for one picture is not in the next.
        func clearEditors(_ controller: MainWindowController) {
            for group in controller.editors.groups {
                group.closeAllTabs()
                if controller.editors.groups.count > 1 { group.onEmpty?(group) }      // an emptied extra group goes
            }
        }
        return [
            // The welcome page, with the repository's own project colour on the bars.
            Scenario(name: "welcome") { controller, done in
                guard FileManager.default.fileExists(atPath: file("Package.swift").path) else {
                    report("FAIL shots: run from the Feather repository (no Package.swift in \(repo.path))"); return done()
                }
                Settings.shared.themeName = "Dark"
                HintCards.shownThisSession.formUnion([.activity, .previewBanner])       // no hint cards in the pictures
                controller.openFolder(repo, asksAboutTrust: false)
                clearEditors(controller)
                if !controller.terminalItem.isCollapsed { controller.toggleTerminal(nil) }
                controller.showExplorer(nil)
                after(1.5) { snapshot("welcome"); done() }
            },
            // The editor: a Swift file, breadcrumbs, the explorer with git marks, the terminal below.
            Scenario(name: "editor") { controller, done in
                clearEditors(controller)
                controller.open(file("Sources/Feather/Shared/Glass.swift"), line: 1, column: 1)
                controller.showTerminal()
                controller.terminals.startIfNeeded()
                after(2.0) { snapshot("editor"); done() }
            },
            // Folding: every block folded to one line.
            Scenario(name: "folding") { controller, done in
                controller.editorArea.currentTab?.editor.textView.foldAllBlocks(nil)
                after(0.8) {
                    snapshot("folding")
                    controller.editorArea.currentTab?.editor.textView.unfoldAllBlocks(nil)
                    done()
                }
            },
            // Sticky scroll: deep inside a long file, the enclosing declarations pinned at the top.
            Scenario(name: "sticky") { controller, done in
                controller.open(file("Sources/Feather/Window/MainWindowController.swift"), line: 230, column: 1)
                after(1.5) { snapshot("sticky"); done() }
            },
            // Several cursors: the word under the cursor and its next matches.
            Scenario(name: "cursors") { controller, done in
                controller.open(file("Sources/Feather/Shared/Glass.swift"), line: 1, column: 1)
                after(1.0) {
                    guard let textView = controller.editorArea.currentTab?.editor.textView else { return done() }
                    let text = textView.string as NSString
                    let first = text.range(of: "isActive")
                    guard first.location != NSNotFound else { return done() }
                    textView.setSelectedRange(first)
                    for _ in 0..<3 { textView.addSelectionToNextFindMatch(nil) }
                    after(0.6) { snapshot("cursors"); done() }
                }
            },
            // Markdown preview beside its source.
            Scenario(name: "preview") { controller, done in
                clearEditors(controller)
                controller.open(file("CONTRIBUTING.md"), line: 1, column: 1)
                after(0.8) {
                    controller.openMarkdownPreviewToSide(nil)
                    after(1.5) {
                        snapshot("preview")
                        clearEditors(controller)
                        done()
                    }
                }
            },
            // A diff of a changed file, opened from Source Control.
            Scenario(name: "diff") { controller, done in
                clearEditors(controller)
                controller.showSourceControl(nil)
                after(1.5) {
                    let changed = controller.sourceControl.statusForTests.unstaged.first { $0.path.hasSuffix(".swift") && $0.status == "M" }
                        ?? controller.sourceControl.statusForTests.unstaged.first
                    if let changed { controller.sourceControl.onOpenDiff?(repo, changed) }
                    after(1.5) { snapshot("diff"); done() }
                }
            },
            Scenario(name: "source-control") { controller, done in
                after(0.5) { snapshot("source-control"); done() }
            },
            Scenario(name: "graph") { controller, done in
                controller.showGitGraph(nil)
                after(1.5) { snapshot("graph"); done() }
            },
            // Problems and TODOs: a small project of its own, since Feather's sources carry no TODO comments.
            Scenario(name: "problems") { controller, done in
                let project = output.appendingPathComponent("todo-project")
                try? FileManager.default.removeItem(at: project)
                try? FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
                try? """
                export function loadUsers(id: number) {
                  // TODO: page through the results instead of loading them all
                  return fetch(`/users/${id}`)
                }

                export function saveUser(user: User) {
                  // FIXME: the server answers 500 when the name is empty
                  return fetch("/users", { method: "POST", body: JSON.stringify(user) })
                }
                """.write(to: project.appendingPathComponent("src/users.ts"), atomically: true, encoding: .utf8)
                try? """
                class Invoice:
                    def total(self):
                        # TODO: apply the discount codes
                        return sum(line.amount for line in self.lines)
                """.write(to: project.appendingPathComponent("src/billing.py"), atomically: true, encoding: .utf8)
                clearEditors(controller)
                controller.openFolder(project, asksAboutTrust: false)
                controller.open(project.appendingPathComponent("src/users.ts"), line: 1, column: 1)
                controller.showTodos(nil)
                after(2.5) { snapshot("problems"); done() }
            },
            // Back in the repository: the terminal panel with a few shells, one of them busy.
            Scenario(name: "terminal") { controller, done in
                clearEditors(controller)
                controller.openFolder(repo, asksAboutTrust: false)
                controller.open(file("Sources/Feather/Shared/Glass.swift"), line: 1, column: 1)
                controller.showExplorer(nil)
                controller.showTerminal()
                controller.terminals.startIfNeeded()
                while controller.terminals.sessions.count < 2 { controller.newTerminal(nil) }
                after(1.0) {
                    controller.terminals.current?.send("git log --oneline -5\n")
                    after(1.5) { snapshot("terminal"); done() }
                }
            },
            // The same window in other themes, and with another project colour.
            Scenario(name: "theme-light") { controller, done in
                Settings.shared.themeName = "Light"
                after(1.2) { snapshot("theme-light"); done() }
            },
            Scenario(name: "theme-midnight") { controller, done in
                Settings.shared.themeName = "Midnight"
                after(1.2) { snapshot("theme-midnight"); done() }
            },
            Scenario(name: "theme-solarized") { controller, done in
                Settings.shared.themeName = "Solarized Dark"
                after(1.2) { snapshot("theme-solarized"); done() }
            },
            Scenario(name: "project-colour") { controller, done in
                Settings.shared.themeName = "Dark"
                after(0.8) {
                    // Through the project's own settings file, since a refresh reads the colour back from there;
                    // the repository's own colour is put back right after the picture.
                    let own = ProjectSettings.load(from: repo).color
                    ProjectSettings.update(in: repo, ["color": "#0F766E"])          // teal
                    controller.applyProjectColor()
                    after(0.8) {
                        snapshot("project-colour")
                        ProjectSettings.update(in: repo, ["color": own])
                        controller.applyProjectColor()
                        done()
                    }
                }
            },
            Scenario(name: "activity") { controller, done in
                controller.showActivity(nil)
                after(1.0) { snapshot("activity"); done() }
            },
            // Settings, in its own window.
            Scenario(name: "settings") { controller, done in
                (NSApp.delegate as? AppDelegate)?.showPreferences(nil)
                after(1.2) {
                    if let window = NSApp.windows.first(where: { $0.windowController is PreferencesWindowController }) {
                        snapshot("settings", window: window)
                        window.close()
                    }
                    Settings.shared.themeName = themeBefore
                    done()
                }
            },
        ]
    }()
}
