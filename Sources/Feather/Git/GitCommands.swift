import AppKit

// MARK: - Links to the repository's web page

/// Where a repository lives on the web, worked out from its `origin` address. Nothing here touches the network:
/// it only builds the address a browser is then asked to open.
struct GitRemote: Equatable {
    enum Host { case gitHub, gitLab, bitbucket }

    /// "https://github.com/owner/repo", without ".git" or a trailing slash.
    let base: String
    let host: Host

    var hostName: String {
        switch host {
        case .gitHub: return "GitHub"
        case .gitLab: return "GitLab"
        case .bitbucket: return "Bitbucket"
        }
    }

    /// Understands "https://host/o/r(.git)", "https://user@host/o/r.git", "git@host:o/r.git", "ssh://git@host[:port]/o/r.git"
    /// and "git://host/o/r.git". A host that is neither GitLab nor Bitbucket is taken to speak GitHub's addresses,
    /// which is right for GitHub Enterprise.
    static func parse(_ address: String) -> GitRemote? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://"), let colon = text.firstIndex(of: ":"), !text.hasPrefix("/") {
            // The scp form, "git@github.com:owner/repo.git".
            text = "ssh://" + text[..<colon] + "/" + text[text.index(after: colon)...]
        }
        guard let components = URLComponents(string: text), let host = components.host, !host.isEmpty,
              ["https", "http", "ssh", "git"].contains(components.scheme ?? "") else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard path.split(separator: "/").count >= 2 else { return nil }
        let kind: Host = host.contains("gitlab") ? .gitLab : host.contains("bitbucket") ? .bitbucket : .gitHub
        // The port of an ssh address says nothing about where the web pages are, so it is dropped.
        return GitRemote(base: "https://" + host.lowercased() + path, host: kind)
    }

    var repositoryURL: URL? { URL(string: base) }

    var pullRequestsURL: URL? {
        switch host {
        case .gitHub: return URL(string: base + "/pulls")
        case .gitLab: return URL(string: base + "/-/merge_requests")
        case .bitbucket: return URL(string: base + "/pull-requests")
        }
    }

    /// The page of one file at a branch or commit, with one-based lines marked when given.
    func fileURL(ref: String, path: String, lines: ClosedRange<Int>? = nil) -> URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "#?"))
        guard let ref = ref.addingPercentEncoding(withAllowedCharacters: allowed),
              let path = path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        var text: String
        switch host {
        case .gitHub: text = "\(base)/blob/\(ref)/\(path)"
        case .gitLab: text = "\(base)/-/blob/\(ref)/\(path)"
        case .bitbucket: text = "\(base)/src/\(ref)/\(path)"
        }
        if let lines {
            let single = lines.lowerBound == lines.upperBound
            switch host {
            case .gitHub: text += single ? "#L\(lines.lowerBound)" : "#L\(lines.lowerBound)-L\(lines.upperBound)"
            case .gitLab: text += single ? "#L\(lines.lowerBound)" : "#L\(lines.lowerBound)-\(lines.upperBound)"
            case .bitbucket: text += single ? "#lines-\(lines.lowerBound)" : "#lines-\(lines.lowerBound):\(lines.upperBound)"
            }
        }
        return URL(string: text)
    }
}

enum GitLinks {
    /// How a link leaves the app. A variable so that a test can look at the address instead of opening a browser.
    static var open: (URL) -> Void = { NSWorkspace.shared.open($0) }

    struct Place {
        let remote: GitRemote
        /// The file's path inside the repository.
        let path: String
        /// The branch, when it is on the remote; nil when only the commit can be pointed at.
        let branch: String?
        let commit: String
    }

    /// Everything a link to `file` needs, from four quick local git questions asked off the main thread.
    static func place(of file: URL, completion: @escaping (Result<Place, GitMessage>) -> Void) {
        let directory = file.deletingLastPathComponent()
        Git.perform(changesIndex: false, { () -> Result<Place, GitMessage> in
            func ask(_ arguments: [String]) -> String? {
                let result = Git.runSync(arguments, in: directory)
                let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return result.ok && !text.isEmpty ? text : nil
            }
            if WorkspaceTrust.shared.blocksExecution(in: directory) { return .failure(GitMessage("This is not available in Restricted Mode. Trust this folder first: click “Restricted Mode” at the bottom of the window.")) }
            guard let address = ask(["remote", "get-url", "origin"]) else {
                return .failure(GitMessage("This project is not connected to GitHub or another website yet (it has no remote called “origin”)."))
            }
            guard let remote = GitRemote.parse(address) else { return .failure(GitMessage("Feather cannot turn “\(address)” into a web address.")) }
            guard let commit = ask(["rev-parse", "HEAD"]) else { return .failure(GitMessage("Nothing has been committed in this project yet.")) }
            let prefix = Git.runSync(["rev-parse", "--show-prefix"], in: directory).output.trimmingCharacters(in: .whitespacesAndNewlines)
            // "origin/main" for a branch that tracks one; a branch that was never pushed has no page to open.
            var branch: String?
            if let upstream = ask(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]), let slash = upstream.firstIndex(of: "/") {
                branch = String(upstream[upstream.index(after: slash)...])
            }
            return .success(Place(remote: remote, path: prefix + file.lastPathComponent, branch: branch, commit: commit))
        }, completion: completion)
    }

    /// For the links that are about the repository as a whole rather than one file.
    static func place(inRepository root: URL, completion: @escaping (Result<Place, GitMessage>) -> Void) {
        place(of: root.appendingPathComponent("."), completion: completion)
    }
}

/// An explanation for the user, as an Error so it can travel in a Result.
struct GitMessage: Error {
    let text: String
    init(_ text: String) { self.text = text }
}

// MARK: - Diff tabs

extension EditorAreaViewController {
    /// Opens (or comes back to) the diff tab of one changed file.
    func openDiff(root: URL, path: String, originalPath: String? = nil, side: DiffSide) {
        let file = root.appendingPathComponent(path).standardizedFileURL
        let name = file.lastPathComponent
        // The tab needs an identity of its own, distinct from the file's tab. It sits beside the real file so the
        // branch in the status bar still comes out right, keeps the extension for the icon, and does not exist.
        let key = file.deletingLastPathComponent().appendingPathComponent("⟨\(side.label)⟩ " + name)
        if let index = tabs.firstIndex(where: { $0.url == key }) {
            select(index)
            tabs[index].preview?.render()
            return
        }
        let view = GitDiffView(root: root, path: path, originalPath: originalPath, side: side)
        view.onOpenFile = { [weak self] url, line in
            self?.onOpenLocation?(LSPLocation(url: url.standardizedFileURL, line: line ?? 0, character: 0, endLine: line ?? 0, endCharacter: 0))
        }
        view.hasUnsavedEdits = { [weak self] in self?.store.existingDocument(at: file)?.isDirty ?? false }
        addViewTab(for: store.openVirtual(key, title: "\(name) (\(side.label))"), preview: view)
    }

    /// The file a tab stands for: its own, or for a diff tab the file being compared.
    func gitFile(ofTabAt index: Int) -> URL? {
        guard tabs.indices.contains(index) else { return nil }
        if let diff = tabs[index].preview as? GitDiffView { return diff.fileURL }
        return tabs[index].url
    }

    /// "Open Changes": what is not staged yet if there is any, otherwise what is staged.
    func openChanges(forTabAt index: Int) {
        guard tabs.indices.contains(index), !(tabs[index].preview is GitDiffView), let file = tabs[index].url else { NSSound.beep(); return }
        let directory = file.deletingLastPathComponent()
        Git.perform(changesIndex: false, { () -> (root: URL, change: GitFileChange?)? in
            let top = Git.runSync(["rev-parse", "--show-toplevel"], in: directory)
            let rootPath = top.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard top.ok, !rootPath.isEmpty else { return nil }
            let prefix = Git.runSync(["rev-parse", "--show-prefix"], in: directory).output.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = prefix + file.lastPathComponent
            let result = Git.runSync(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", file.lastPathComponent], in: directory)
            let status = Git.parseStatus(result.output)
            let change = status.unstaged.first { $0.path == path && !$0.isConflict } ?? status.staged.first { $0.path == path }
            return (URL(fileURLWithPath: rootPath), change)
        }, completion: { [weak self] found in
            guard let self else { return }
            guard let found, let change = found.change else {
                let alert = NSAlert()
                alert.messageText = WorkspaceTrust.shared.blocksExecution(in: directory) ? "Changes cannot be shown in Restricted Mode. Trust this folder first: click “Restricted Mode” at the bottom of the window."
                    : found == nil ? "“\(file.lastPathComponent)” is not in a project that keeps a history of changes (a Git repository)."
                    : "“\(file.lastPathComponent)” has not changed since the last saved version (commit)."
                alert.runModal()
                return
            }
            self.openDiff(root: found.root, path: change.path, originalPath: change.originalPath, side: change.isStaged ? .index : .workingTree)
        })
    }
}

// MARK: - Menu commands

extension MainWindowController {
    @objc func openChangesForCurrentFile(_ sender: Any?) {
        editorArea.openChanges(forTabAt: editorArea.selectedIndex)
    }

    @objc func stashChanges(_ sender: Any?) { gitSourceControl.stashChanges(sender) }

    // Git ▸ Pull / Push / Sync / Fetch act on the repository selected in Source Control.
    @objc func gitPull(_ sender: Any?) { gitSourceControl.pull() }
    @objc func gitPush(_ sender: Any?) { gitSourceControl.push() }
    @objc func gitSync(_ sender: Any?) { gitSourceControl.sync() }
    @objc func gitFetch(_ sender: Any?) { gitSourceControl.fetch() }

    @objc func popLatestStash(_ sender: Any?) { gitSourceControl.popLatestStash(sender) }

    @objc func toggleBlame(_ sender: Any?) {
        Settings.shared.showBlame.toggle()
        refreshBlame()
    }

    /// The one-based lines the link should mark: the caret's line, or every line the selection touches.
    private var selectedLines: ClosedRange<Int>? {
        guard let tab = editorArea.currentTab, !tab.isPreviewing, let editor = tab.editorIfLoaded else { return nil }
        let first = editor.cursorPosition.line
        let selection = editor.textView.selectedRange()
        guard selection.length > 0 else { return first...first }
        var breaks = 0
        let text = tab.document.storage.mutableString
        var search = selection
        while search.length > 0 {
            let found = text.range(of: "\n", options: [], range: search)
            // A selection that ends just after a line break does not include the next line.
            guard found.location != NSNotFound, NSMaxRange(found) < NSMaxRange(selection) else { break }
            breaks += 1
            search = NSRange(location: NSMaxRange(found), length: NSMaxRange(selection) - NSMaxRange(found))
        }
        return first...(first + breaks)
    }

    private func withPlace(_ body: @escaping (GitLinks.Place) -> Void) {
        guard let file = editorArea.gitFile(ofTabAt: editorArea.selectedIndex) ?? gitSourceControl.repositoryRoot?.appendingPathComponent(".") else {
            NSSound.beep()
            return
        }
        GitLinks.place(of: file) { result in
            switch result {
            case .success(let place): body(place)
            case .failure(let message):
                let alert = NSAlert()
                alert.messageText = "There is no web page to open"
                alert.informativeText = message.text
                alert.runModal()
            }
        }
    }

    /// The branch's page when the branch is on the remote (it reads best and follows new commits); otherwise the commit's.
    @objc func openOnGitHub(_ sender: Any?) {
        guard editorArea.gitFile(ofTabAt: editorArea.selectedIndex) != nil else { NSSound.beep(); return }
        let lines = selectedLines
        withPlace { place in
            if let url = place.remote.fileURL(ref: place.branch ?? place.commit, path: place.path, lines: lines) { GitLinks.open(url) }
        }
    }

    /// Always the commit: a copied link is kept, and must go on pointing at these lines after the branch moves on.
    @objc func copyGitHubLink(_ sender: Any?) {
        guard editorArea.gitFile(ofTabAt: editorArea.selectedIndex) != nil else { NSSound.beep(); return }
        let lines = selectedLines
        withPlace { place in
            guard let url = place.remote.fileURL(ref: place.commit, path: place.path, lines: lines) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }

    @objc func openRepositoryOnGitHub(_ sender: Any?) {
        withPlace { if let url = $0.remote.repositoryURL { GitLinks.open(url) } }
    }

    @objc func openPullRequestsOnGitHub(_ sender: Any?) {
        withPlace { if let url = $0.remote.pullRequestsURL { GitLinks.open(url) } }
    }
}
