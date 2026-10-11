import AppKit

/// What a "since checkpoint" diff tab compares with.
struct CheckpointComparison {
    let store: CheckpointStore
    let checkpoint: Checkpoint
}

/// One window's Activity: it owns the folder's checkpoints, watches the folder, keeps the pane current, and
/// carries out New Checkpoint, Undo All, Restore This File and follow mode.
final class ActivityCoordinator {
    /// Posted (object: the project folder's URL) when files in the folder changed, so a "since checkpoint" diff
    /// tab can read its file again.
    static let filesDidChange = Notification.Name("FeatherActivityFilesDidChange")

    /// Follow mode does not open files bigger than this.
    static let maxFollowBytes = 2_000_000
    static let followInterval: TimeInterval = 1.5

    private(set) weak var controller: MainWindowController?
    /// What has been looked at in a review of the current checkpoint's changes (Review.swift).
    let review = ReviewSession()
    private var diskSync: DispatchWorkItem?
    private(set) var pane: ActivityViewController?
    private(set) var store: CheckpointStore?
    private var watcher: DirectoryWatcher?
    /// The checkpoint the user picked to compare with; nil compares with the newest one that is not a safety copy.
    private var pickedID: String?
    private(set) var snapshot: ActivitySnapshot?
    /// The checkpoint an undo left behind, for the pane's "Put Them Back".
    private var lastSafety: Checkpoint?

    private var refreshWork: DispatchWorkItem?
    private var isRefreshing = false
    private var needsAnotherRefresh = false
    /// Something changed while nobody was looking; the pane is brought up to date when it is next shown.
    private(set) var isDirty = true
    private var generation = 0
    /// How long the last refresh took off the main thread, for the tests' timing.
    private(set) var lastRefreshMilliseconds = 0.0
    var onRefresh: (() -> Void)?

    // Follow mode
    /// Each listed file's date at the last refresh; a file whose date moved since has just changed. Nil until the
    /// first refresh after follow mode came on, which only takes stock.
    private var knownDates: [String: Date]?
    /// Files Feather wrote itself (a save, an undo), which are not news.
    private(set) var ownWrites: [String: Date] = [:]
    /// The folders that reported a change, and when (AssistantChanges.swift asks "what changed since").
    var recentDirectoryEvents: [String: Date] = [:]
    /// The document in front as it was when the assistant set to work.
    var frontSnapshot: FrontDocumentSnapshot?
    private var lastJump = Date.distantPast
    private var jumpWork: DispatchWorkItem?
    private var keyMonitor: Any?
    private var lastKeyDown = Date.distantPast
    private var sampledChangeCount: (document: ObjectIdentifier, count: Int)?
    private(set) var followedCount = 0
    private(set) var suppressedCount = 0

    init(controller: MainWindowController) {
        self.controller = controller
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(documentSaved(_:)), name: DocumentStore.didSaveDocument, object: nil)
        center.addObserver(self, selector: #selector(followSettingChanged), name: Settings.followChangesDidChange, object: nil)
        center.addObserver(self, selector: #selector(checkpointsChanged(_:)), name: CheckpointStore.didChangeCheckpoints, object: nil)
        center.addObserver(self, selector: #selector(assistantStartedWorking(_:)), name: .assistantDidStartWorking, object: nil)
        center.addObserver(self, selector: #selector(assistantStopped(_:)), name: .assistantDidStop, object: nil)
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func install(pane: ActivityViewController) {
        self.pane = pane
        pane.onAppear = { [weak self] in self?.paneAppeared() }
        pane.onNewCheckpoint = { [weak self] in self?.askForNewCheckpoint() }
        pane.onUndoAll = { [weak self] in self?.undoAll() }
        pane.onReview = { [weak self] in self?.openReview() }
        pane.onPickCheckpoint = { [weak self] in self?.pick($0) }
        pane.onShowChange = { [weak self] in self?.showChanges(path: $0.path) }
        pane.onOpenFile = { [weak self] change in
            guard let self, let store = self.store else { return }
            self.controller?.editorArea.open(store.root.appendingPathComponent(change.path))
        }
        pane.onRestoreFile = { [weak self] in self?.restoreFile(path: $0.path) }
        pane.onClear = { [weak self] in self?.clearCheckpoints() }
        pane.onNotice = { [weak self] in
            guard let self, let safety = self.lastSafety else { return }
            self.undoAll(to: safety)
        }
        followSettingChanged()
    }

    // MARK: - The folder

    func setRoot(_ root: URL?) {
        generation += 1
        snapshot = nil
        pickedID = nil
        lastSafety = nil
        knownDates = nil
        watcher = nil
        store = root.map(CheckpointStore.store(for:))
        pane?.showNotice(nil)
        pane?.show(nil)
        pane?.hasFolder = store != nil
        guard let store, let root else { return }
        let watcher = DirectoryWatcher(path: root.path)
        watcher.onChange = { [weak self] paths in self?.filesChanged(paths) }
        self.watcher = watcher
        let generation = generation
        let listed: ([Checkpoint]) -> Void = { [weak self] _ in
            guard let self, self.generation == generation else { return }
            self.checkpointListChanged()
        }
        if !Git.isAvailable {
            pane?.showNotice("Checkpoints need git, which is not installed on this Mac. Install Apple's Command Line Tools (Source Control pane) and open the folder again.")
            store.loadCheckpoints(completion: listed)
        } else if Settings.shared.autoCheckpoint {
            store.takeAutomaticCheckpointIfDue { [weak self] _ in listed(self?.store?.checkpoints ?? []) }
        } else {
            store.loadCheckpoints(completion: listed)
        }
    }

    /// The checkpoint the pane compares with.
    var target: Checkpoint? {
        guard let store else { return nil }
        if let pickedID, let picked = store.checkpoints.first(where: { $0.id == pickedID }) { return picked }
        return store.checkpoints.first { $0.kind != .safety } ?? store.checkpoints.first
    }

    @objc private func checkpointsChanged(_ notification: Notification) {
        guard notification.object as AnyObject? === store else { return }
        checkpointListChanged()
    }

    private func checkpointListChanged() {
        guard let store else { return }
        pane?.show(checkpoints: store.checkpoints, selected: target)
        pane?.emptyMessage = store.checkpoints.isEmpty
            ? "No checkpoint yet.\nPress “＋ Checkpoint” to save how the project is now; after that, everything that changes is listed here."
            : "Looking…"
        store.diskUse { [weak self] bytes in self?.pane?.show(diskUse: bytes) }
        refreshSoon(delay: 0)
    }

    private func pick(_ checkpoint: Checkpoint) {
        pickedID = checkpoint.id
        pane?.show(checkpoints: store?.checkpoints ?? [], selected: checkpoint)
        refreshSoon(delay: 0)
    }

    // MARK: - Keeping current

    private func filesChanged(_ paths: [String]) {
        guard let store else { return }
        // Packages being installed and output being built are not activity anyone wants to look at.
        let rootLength = store.root.path.count
        let interesting = paths.filter { path in
            !path.dropFirst(rootLength).split(separator: "/").contains { CheckpointStore.noisyFolders.contains(String($0)) }
        }
        guard !interesting.isEmpty else { return }
        noteDirectoryEvents(interesting)
        // Whatever is open shows what is on disk: when an AI tool rewrites a file the person is looking at, they
        // should see it change there and then, not only after switching away and back. Files with unsaved edits
        // are left alone, and unchanged ones cost one stat each.
        diskSync?.cancel()
        let sync = DispatchWorkItem { [weak self] in self?.controller?.store.syncWithDisk(refreshGitBases: false) }
        diskSync = sync
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: sync)
        sampleTyping()
        NotificationCenter.default.post(name: ActivityCoordinator.filesDidChange, object: store.root)
        refreshSoon(delay: 0.35)
    }

    private var wantsRefresh: Bool { pane?.isOnScreen == true || Settings.shared.followChanges }

    private func paneAppeared() {
        if isDirty { refreshSoon(delay: 0) }
    }

    /// Debounced, one at a time, and only while someone is looking (or follow mode needs it); otherwise the pane
    /// is only marked as out of date.
    func refreshSoon(delay: TimeInterval) {
        isDirty = true
        guard wantsRefresh else { return }
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshNow() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func refreshNow() {
        guard let store, let target else {
            snapshot = nil
            pane?.show(nil)
            return
        }
        if isRefreshing {
            needsAnotherRefresh = true
            return
        }
        isRefreshing = true
        isDirty = false
        let generation = generation
        store.changes(since: target) { [weak self] snapshot in
            guard let self else { return }
            self.isRefreshing = false
            if self.generation == generation, self.target == snapshot.checkpoint {
                self.snapshot = snapshot
                self.lastRefreshMilliseconds = snapshot.milliseconds
                self.pane?.show(snapshot)
                self.follow(snapshot)
                self.onRefresh?()
            }
            if self.needsAnotherRefresh {
                self.needsAnotherRefresh = false
                self.refreshSoon(delay: 0.35)
            }
        }
    }

    // MARK: - Checkpoints

    private func askForNewCheckpoint() {
        guard store != nil else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "New Checkpoint"
        alert.informativeText = "Feather saves a copy of how every file in the project is right now. You can come back to it at any time with “Undo All…”. Give it a name if you like."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.placeholderString = "Before " + CheckpointStore.clock(Date())
        alert.accessoryView = field
        alert.addButton(withTitle: "Save Checkpoint")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        newCheckpoint(named: field.stringValue)
    }

    /// A checkpoint holds what is on disk, which is the project as the tools in the terminal see it; edits that
    /// have not been saved are not part of it.
    func newCheckpoint(named name: String?, completion: ((Checkpoint?) -> Void)? = nil) {
        guard let store else { NSSound.beep(); completion?(nil); return }
        store.newCheckpoint(name: name, kind: .manual) { [weak self] result in
            switch result {
            case .success(let checkpoint):
                self?.pickedID = nil
                self?.lastSafety = nil
                self?.pane?.showNotice(nil)
                self?.checkpointListChanged()
                completion?(checkpoint)
            case .failure(let error):
                self?.report("Could not save a checkpoint", error.message)
                completion?(nil)
            }
        }
    }

    private func clearCheckpoints() {
        guard let store else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear this project’s checkpoints?"
        alert.informativeText = "All \(store.checkpoints.count) checkpoints of this project are forgotten and their disk space is given back. Your files stay exactly as they are, but you will not be able to undo back to those checkpoints."
        alert.addButton(withTitle: "Clear Checkpoints")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.clear { [weak self] in
            self?.pickedID = nil
            self?.lastSafety = nil
            self?.pane?.showNotice(nil)
        }
    }

    // MARK: - Undoing

    private func document(at path: String) -> TextDocument? {
        guard let store else { return nil }
        return controller?.store.existingDocument(at: store.root.appendingPathComponent(path).standardizedFileURL)
    }

    private static func count(_ number: Int, _ one: String, _ many: String) -> String { "\(number) \(number == 1 ? one : many)" }

    /// Undo All Changes Since Checkpoint. `confirmed` skips the question (the tests, which cannot press buttons);
    /// `replacingUnsaved` is then the answer to "what about files with unsaved edits".
    func undoAll(to checkpoint: Checkpoint? = nil, confirmed: Bool = false, replacingUnsaved: Bool = false,
                 completion: ((RestoreOutcome?) -> Void)? = nil) {
        guard let store, let checkpoint = checkpoint ?? target else { NSSound.beep(); completion?(nil); return }
        store.changes(since: checkpoint) { [weak self] snapshot in
            guard let self else { return }
            let changes = snapshot.changes
            guard !changes.isEmpty else {
                if !confirmed { self.report("Nothing to undo", "Every file is already the same as at “\(checkpoint.name)”.", style: .informational) }
                completion?(nil)
                return
            }
            guard snapshot.unlisted == 0 || confirmed || self.confirmsHugeUndo(snapshot) else { completion?(nil); return }
            let unsaved = changes.filter { self.document(at: $0.path)?.isDirty == true }.map(\.path)
            var skipping = Set<String>()
            if !confirmed {
                let changed = changes.filter { $0.kind == .changed }.count
                let created = changes.filter { $0.kind == .created }.count
                let deleted = changes.filter { $0.kind == .deleted }.count
                var parts: [String] = []
                if changed > 0 { parts.append(ActivityCoordinator.count(changed, "file goes back to how it was", "files go back to how they were")) }
                if created > 0 { parts.append(ActivityCoordinator.count(created, "new file moves to the Trash", "new files move to the Trash")) }
                if deleted > 0 { parts.append(ActivityCoordinator.count(deleted, "deleted file comes back", "deleted files come back")) }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Undo all changes since “\(checkpoint.name)”?"
                alert.informativeText = parts.joined(separator: ", ") + ".\n\nFeather first saves a checkpoint of how things are now, so you can undo this too."
                alert.addButton(withTitle: "Undo All Changes")
                alert.addButton(withTitle: "Cancel")
                if !unsaved.isEmpty {
                    let names = unsaved.prefix(4).map { "“" + ($0 as NSString).lastPathComponent + "”" }.joined(separator: ", ")
                    alert.informativeText += "\n\n\(names)\(unsaved.count > 4 ? " and others" : "") \(unsaved.count == 1 ? "has" : "have") edits you have not saved. “Undo All Changes” replaces them as well (⌘Z in the file brings your edits back); “Keep My Unsaved Edits” leaves \(unsaved.count == 1 ? "that file" : "those files") alone."
                    alert.addButton(withTitle: "Keep My Unsaved Edits")
                }
                switch alert.runModal() {
                case .alertFirstButtonReturn: break
                case .alertThirdButtonReturn: skipping = Set(unsaved)
                default: completion?(nil); return
                }
            } else if !replacingUnsaved {
                skipping = Set(unsaved)
            }
            self.restore(to: checkpoint, only: nil, skipping: skipping, completion: completion)
        }
    }

    private func confirmsHugeUndo(_ snapshot: ActivitySnapshot) -> Bool {
        report("Too many changes to undo in one go", "More than \(CheckpointStore.maxListedChanges) files changed since this checkpoint. Restore the files you need one at a time from the list.")
        return false
    }

    /// Restore This File: the same as Undo All, for one file.
    func restoreFile(path: String, confirmed: Bool = false, completion: ((RestoreOutcome?) -> Void)? = nil) {
        guard let checkpoint = target, let change = snapshot?.changes.first(where: { $0.path == path }) else { NSSound.beep(); completion?(nil); return }
        let name = (path as NSString).lastPathComponent
        let isUnsaved = document(at: path)?.isDirty == true
        if !confirmed {
            let alert = NSAlert()
            alert.alertStyle = .warning
            switch change.kind {
            case .changed:
                alert.messageText = "Restore “\(name)”?"
                alert.informativeText = "The file goes back to how it was at “\(checkpoint.name)”."
                alert.addButton(withTitle: "Restore File")
            case .created:
                alert.messageText = "Move “\(name)” to the Trash?"
                alert.informativeText = "The file did not exist at “\(checkpoint.name)”. It is moved to the Trash, not deleted."
                alert.addButton(withTitle: "Move to Trash")
            case .deleted:
                alert.messageText = "Bring “\(name)” back?"
                alert.informativeText = "The file comes back as it was at “\(checkpoint.name)”."
                alert.addButton(withTitle: "Bring It Back")
            }
            alert.informativeText += " Feather first saves a checkpoint of how things are now, so you can undo this too."
            if isUnsaved { alert.informativeText += "\n\nThe file has edits you have not saved; they are replaced as well (⌘Z in the file brings them back)." }
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { completion?(nil); return }
        }
        restore(to: checkpoint, only: [path], skipping: [], completion: completion)
    }

    private func restore(to checkpoint: Checkpoint, only: Set<String>?, skipping: Set<String>, completion: ((RestoreOutcome?) -> Void)?) {
        guard let store else { completion?(nil); return }
        store.restore(to: checkpoint, only: only, skipping: skipping) { [weak self] outcome in
            guard let self else { return }
            let now = Date()
            for path in outcome.touched { self.ownWrites[store.root.appendingPathComponent(path).path] = now }
            // Documents with unsaved edits the user agreed to give up are read again too; the rest follow the
            // usual path (clean documents reload, the explorer and source control catch up).
            for path in outcome.restored {
                if let document = self.document(at: path), document.isDirty { self.controller?.store.revertToDisk(document) }
            }
            if let view = self.pane?.view ?? self.controller?.window?.contentView {
                NotificationCenter.default.post(name: GitDiffView.didChangeRepository, object: view)
            }
            NotificationCenter.default.post(name: ActivityCoordinator.filesDidChange, object: store.root)
            if let error = outcome.error {
                self.report("Some files could not be put back", error)
            } else if let safety = outcome.safety, only == nil {
                self.lastSafety = safety
                var text = "Undone: " + ActivityCoordinator.count(outcome.touched.count, "file", "files") + " put back."
                if !outcome.trashed.isEmpty { text += " New files are in the Trash." }
                if !outcome.skipped.isEmpty { text += " " + ActivityCoordinator.count(outcome.skipped.count, "file was", "files were") + " left alone." }
                self.pane?.showNotice(text, button: "Put the Changes Back")
            }
            self.refreshSoon(delay: 0)
            completion?(outcome)
        }
    }

    private func report(_ title: String, _ details: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = String(details.prefix(1200))
        alert.runModal()
    }

    // MARK: - Seeing one file's changes

    func showChanges(path: String) {
        guard let store, let checkpoint = target, let controller else { NSSound.beep(); return }
        let comparison = CheckpointComparison(store: store, checkpoint: checkpoint)
        controller.editorArea.openCheckpointDiff(comparison, path: path) { [weak self] in self?.restoreFile(path: path) }
    }

    /// Review Changes: every file that differs from the checkpoint, in one tab, block by block. The list is read
    /// afresh, because the pane may not have been looking.
    func openReview() {
        guard let store, let checkpoint = target, let controller else { NSSound.beep(); return }
        review.prepare(for: checkpoint)
        let comparison = CheckpointComparison(store: store, checkpoint: checkpoint)
        let generation = generation
        store.changes(since: checkpoint) { [weak self] snapshot in
            guard let self, self.generation == generation, self.target == checkpoint else { return }
            self.snapshot = snapshot
            self.pane?.show(snapshot)
            controller.editorArea.openReview(comparison, files: snapshot.changes, coordinator: self)
        }
    }

    /// The path of a file inside the project, as checkpoints know it.
    func relativePath(of url: URL) -> String? {
        guard let store else { return nil }
        let root = store.root.path + "/", path = url.standardizedFileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : nil
    }

    // MARK: - Follow mode

    @objc private func documentSaved(_ notification: Notification) {
        guard let url = notification.userInfo?["url"] as? URL else { return }
        ownWrites[url.standardizedFileURL.path] = Date()
    }

    @objc private func followSettingChanged() {
        let isOn = Settings.shared.followChanges
        knownDates = nil
        if isOn, keyMonitor == nil {
            // One date per key press while follow mode is on; nothing looks at the document.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if let self, event.window === self.controller?.window, self.editorHasKeyboard { self.lastKeyDown = Date() }
                return event
            }
        } else if !isOn, let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if isOn { refreshSoon(delay: 0) }
    }

    private var editorHasKeyboard: Bool {
        guard let controller, let responder = controller.window?.firstResponder as? NSTextView else { return false }
        return responder.isDescendant(of: controller.editors.view)
    }

    /// Typing shows as the current document's edit count moving between two looks at it.
    @discardableResult
    private func sampleTyping() -> Bool {
        guard let document = controller?.editorArea.currentTab?.document else { return false }
        let sample = (ObjectIdentifier(document), document.changeCount)
        defer { sampledChangeCount = sample }
        guard let previous = sampledChangeCount, previous.document == sample.0 else { return false }
        return previous.count != sample.1
    }

    private var isUserTyping: Bool {
        let typed = sampleTyping()
        guard editorHasKeyboard else { return false }
        return typed || Date().timeIntervalSince(lastKeyDown) < 3
    }

    /// Called with every fresh snapshot: finds the file something else has just changed, if any.
    private func follow(_ snapshot: ActivitySnapshot) {
        guard Settings.shared.followChanges, let store else { return }
        var dates: [String: Date] = [:]
        for change in snapshot.changes { dates[change.path] = change.modified }
        defer { knownDates = dates }
        guard let known = knownDates else { return }
        let now = Date()
        ownWrites = ownWrites.filter { now.timeIntervalSince($0.value) < 5 }
        let news = snapshot.changes.first { change in          // newest first already
            guard change.kind != .deleted, !change.isBinary, let modified = change.modified, known[change.path] != modified else { return false }
            return ownWrites[store.root.appendingPathComponent(change.path).path] == nil
        }
        guard let news else { return }
        scheduleJump(to: news.path)
    }

    /// At most one jump per interval; a newer file replaces one that is still waiting its turn.
    private func scheduleJump(to path: String) {
        jumpWork?.cancel()
        let wait = max(0, ActivityCoordinator.followInterval - Date().timeIntervalSince(lastJump))
        let work = DispatchWorkItem { [weak self] in self?.jump(to: path) }
        jumpWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func jump(to path: String) {
        guard Settings.shared.followChanges, let store, let controller, let checkpoint = target else { return }
        let url = store.root.appendingPathComponent(path).standardizedFileURL
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= ActivityCoordinator.maxFollowBytes, MediaPreviewView.kind(of: url) == nil else { return }
        // Never while the user is typing, and never into a file that has their unsaved edits.
        if isUserTyping || controller.store.existingDocument(at: url)?.isDirty == true {
            suppressedCount += 1
            return
        }
        lastJump = Date()
        if let document = controller.store.existingDocument(at: url) {
            // Open already: what changed is the difference between what the editor has and what the disk has.
            let old = DocumentSync.utf16(document.text)
            controller.store.syncWithDisk(refreshGitBases: false)
            let new = DocumentSync.utf16(document.text)
            let edit = DocumentSync.edit(from: old, to: new)
            let range = edit.map { NSRange(location: $0.oldRange.location, length: $0.newLength) }
            reveal(url, characters: range, lines: [])
        } else {
            store.changedLines(of: path, since: checkpoint) { [weak self] lines in self?.reveal(url, characters: nil, lines: lines) }
        }
    }

    /// Shows the file without taking the keyboard from wherever it is (the terminal, most of the time).
    private func reveal(_ url: URL, characters: NSRange?, lines: [Range<Int>]) {
        guard let controller, let window = controller.window else { return }
        let responder = window.firstResponder
        let group = controller.editors.groups.first { group in group.tabs.contains { $0.url == url } } ?? controller.editorArea
        group.withDeferredDisplay { group.open(url) }
        if window.firstResponder !== responder, let responder { window.makeFirstResponder(responder) }
        guard let tab = group.currentTab, tab.url == url, tab.preview == nil else { return }
        followedCount += 1
        // A new editor has no layout until the run loop has turned.
        DispatchQueue.main.async {
            guard let textView = tab.editorIfLoaded?.textView else { return }
            let text = textView.string as NSString
            var ranges: [NSRange] = []
            if let characters, NSMaxRange(characters) <= text.length {
                ranges = [text.lineRange(for: characters)]
            } else if !lines.isEmpty {
                ranges = ActivityCoordinator.characterRanges(of: lines, in: text)
            }
            guard let first = ranges.first else { return }
            textView.scrollRangeToVisible(NSRange(location: first.location, length: 0))
            FollowFlash.show(ranges, in: textView)
        }
    }

    /// Line ranges as character ranges, walking the text once and stopping after the last line asked for.
    static func characterRanges(of lines: [Range<Int>], in text: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var line = 0, location = 0
        for wanted in lines.sorted(by: { $0.lowerBound < $1.lowerBound }).prefix(40) {
            while line < wanted.lowerBound, location < text.length {
                location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
                line += 1
            }
            guard line == wanted.lowerBound, location <= text.length else { break }
            var end = location
            for _ in wanted where end < text.length { end = NSMaxRange(text.lineRange(for: NSRange(location: end, length: 0))) }
            result.append(NSRange(location: location, length: end - location))
        }
        return result
    }
}

/// The flash over lines that have just changed: plain coloured views on top of the text view, which fade and are
/// then removed. Nothing in the text, its attributes or the editor is touched, so there is nothing to restore.
final class FollowFlash: NSView {
    static let duration: TimeInterval = 1.0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func clear(in textView: NSTextView) {
        textView.subviews.filter { $0 is FollowFlash }.forEach { $0.removeFromSuperview() }
    }

    static func show(_ ranges: [NSRange], in textView: NSTextView) {
        clear(in: textView)
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let origin = textView.textContainerOrigin
        // Only what is near the first change is measured, so a change at both ends of a long file lays out one end.
        let limit = (ranges.first?.location ?? 0) + 20_000
        var flashes: [FollowFlash] = []
        for range in ranges where range.location <= limit {
            let clipped = NSRange(location: range.location, length: min(range.length, 20_000))
            let glyphs = layoutManager.glyphRange(forCharacterRange: clipped, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            if clipped.length == 0 { rect = layoutManager.lineFragmentRect(forGlyphAt: min(glyphs.location, max(0, layoutManager.numberOfGlyphs - 1)), effectiveRange: nil) }
            let flash = FollowFlash(frame: NSRect(x: 0, y: rect.minY + origin.y, width: textView.bounds.width, height: max(rect.height, 2)))
            flash.wantsLayer = true
            flash.layer?.backgroundColor = NSColor(hex: 0x3FB950).withAlphaComponent(0.28).cgColor
            flash.autoresizingMask = [.width]
            textView.addSubview(flash)
            flashes.append(flash)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            flashes.forEach { $0.animator().alphaValue = 0 }
        }
        // Removal does not depend on the animation finishing (a window that is not on screen never animates).
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) {
            flashes.forEach { $0.removeFromSuperview() }
        }
    }
}

// MARK: - Tabs, commands and menu

extension EditorAreaViewController {
    /// A side-by-side comparison of one file with a checkpoint, in a tab of its own.
    func openCheckpointDiff(_ comparison: CheckpointComparison, path: String, onRestoreFile: @escaping () -> Void) {
        let file = comparison.store.root.appendingPathComponent(path).standardizedFileURL
        let name = file.lastPathComponent
        let key = file.deletingLastPathComponent().appendingPathComponent("⟨since checkpoint⟩ " + name)
        if let index = tabs.firstIndex(where: { $0.url == key }) {
            select(index)
            (tabs[index].preview as? GitDiffView)?.compare(with: comparison)
            return
        }
        let view = GitDiffView(root: comparison.store.root, path: path, originalPath: nil, side: .workingTree, comparison: comparison)
        view.onOpenFile = { [weak self] url, line in
            self?.onOpenLocation?(LSPLocation(url: url.standardizedFileURL, line: line ?? 0, character: 0, endLine: line ?? 0, endCharacter: 0))
        }
        view.hasUnsavedEdits = { [weak self] in self?.store.existingDocument(at: file)?.isDirty ?? false }
        view.onRestoreFile = onRestoreFile
        addViewTab(for: store.openVirtual(key, title: "\(name) (since checkpoint)"), preview: view)
    }
}

extension MainWindowController {
    @objc func newCheckpoint(_ sender: Any?) { activity.pane?.onNewCheckpoint?() }

    @objc func undoAllSinceCheckpoint(_ sender: Any?) {
        showActivity(sender)
        activity.undoAll()
    }

    /// The file a tab stands for, when it is inside the project.
    private var activityPath: String? {
        guard let index = editorArea.tabs.firstIndex(where: { $0 === editorArea.currentTab }),
              let url = editorArea.gitFile(ofTabAt: index) else { return nil }
        return activity.relativePath(of: url)
    }

    @objc func showChangesSinceCheckpoint(_ sender: Any?) {
        guard let path = activityPath else { NSSound.beep(); return }
        activity.showChanges(path: path)
    }

    @objc func restoreFileToCheckpoint(_ sender: Any?) {
        guard let path = activityPath else { NSSound.beep(); return }
        activity.restoreFile(path: path)
    }
}

/// The Activity commands, added to the View menu in one place so the menu bar code itself stays untouched.
final class ActivityMenu: NSObject, NSMenuItemValidation {
    static let shared = ActivityMenu()

    static func install(in main: NSMenu) {
        guard let view = main.items.first(where: { $0.title == "View" })?.submenu else { return }
        func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            KeyBindings.shared.apply(to: item)
            return item
        }
        let follow = item("Follow Changes", #selector(toggleFollowChanges(_:)))
        follow.target = shared
        let items = [
            .separator(),
            item("Activity: What Changed", #selector(MainWindowController.showActivity(_:)), "a", [.control, .shift]),
            follow,
            item("New Checkpoint…", #selector(MainWindowController.newCheckpoint(_:))),
            item("Undo All Changes Since Checkpoint…", #selector(MainWindowController.undoAllSinceCheckpoint(_:))),
            item("See What Changed in This File Since Checkpoint", #selector(MainWindowController.showChangesSinceCheckpoint(_:))),
            item("Restore This File to Checkpoint…", #selector(MainWindowController.restoreFileToCheckpoint(_:))),
            item("Review Changes Since Checkpoint", #selector(MainWindowController.reviewChanges(_:)), "r", [.control, .shift]),
        ]
        // After the pane commands and before the editor ones would be tidier, but the end is where nobody else's
        // edit lands.
        items.forEach(view.addItem)
    }

    @objc func toggleFollowChanges(_ sender: Any?) { Settings.shared.followChanges.toggle() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleFollowChanges(_:)) { item.state = Settings.shared.followChanges ? .on : .off }
        return true
    }
}
