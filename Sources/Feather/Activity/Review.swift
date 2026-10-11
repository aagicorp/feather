import AppKit

/// What a review of one checkpoint's changes has decided so far: which blocks were kept and how many were undone.
/// It lives in memory, one per window, and starts over when the checkpoint being compared with changes.
final class ReviewSession {
    /// One block of one file. Two identical blocks in one file are told apart by their place among the blocks.
    struct Key: Hashable {
        let path: String
        /// The block's lines, without the "@@" line, so the block keeps its identity when an undo above it moves
        /// its line numbers. Empty for a file-level item (a new, deleted or binary file).
        let body: Data
        let ordinal: Int
    }

    private(set) var checkpointID: String?
    private(set) var kept: Set<Key> = []
    /// Blocks that were undone, and files trashed or restored: gone from the diffs, but they still count as done.
    private(set) var undone = 0
    /// The blocks each file has now, once its diff has been read. A file-level item is one block.
    private(set) var keys: [String: [Key]] = [:]
    /// Where the review is: which file, and which block in it.
    var fileIndex = 0
    var blockIndex = 0
    /// Something to redraw changed.
    var onChange: (() -> Void)?

    var total: Int { keys.values.reduce(0) { $0 + $1.count } + undone }
    var reviewed: Int { kept.count + undone }

    /// Starts over when the checkpoint is not the one this review was of.
    func prepare(for checkpoint: Checkpoint) {
        guard checkpointID != checkpoint.id else { return }
        checkpointID = checkpoint.id
        kept = []
        undone = 0
        keys = [:]
        fileIndex = 0
        blockIndex = 0
    }

    static func keys(for path: String, hunks: [DiffHunk]) -> [Key] {
        var seen: [Data: Int] = [:]
        return hunks.map { hunk in
            let bodyStart = hunk.patch.firstIndex(of: 0x0A).map { $0 + 1 } ?? hunk.patch.endIndex
            let body = hunk.patch.isEmpty ? Data() : Data(hunk.patch[bodyStart...])
            let ordinal = seen[body, default: 0]
            seen[body] = ordinal + 1
            return Key(path: path, body: body, ordinal: ordinal)
        }
    }

    static func fileKey(_ path: String) -> Key { Key(path: path, body: Data(), ordinal: 0) }

    /// A file's diff was read: these are its blocks now. Marks on blocks that are gone are dropped.
    func note(_ path: String, hunks: [DiffHunk]) {
        let list = ReviewSession.keys(for: path, hunks: hunks)
        keys[path] = list
        let current = Set(list)
        kept = kept.filter { $0.path != path || current.contains($0) }
        onChange?()
    }

    func isKept(_ key: Key) -> Bool { kept.contains(key) }

    func keep(_ key: Key) {
        kept.insert(key)
        onChange?()
    }

    func keepAll() {
        for list in keys.values { kept.formUnion(list) }
        onChange?()
    }

    func noteUndone(_ key: Key) {
        kept.remove(key)
        keys[key.path]?.removeAll { $0 == key }
        undone += 1
        onChange?()
    }

    /// Undo All put every file back: whatever was not yet looked at is done with too.
    func noteUndoneEverything() {
        undone = total
        kept = []
        keys = keys.mapValues { _ in [] }
        onChange?()
    }
}

/// The Review tab: every file that differs from the checkpoint, one at a time, with Keep and Undo on each block,
/// like going through a pull request. The diff itself is a `GitDiffView` in checkpoint mode; this view adds the
/// file navigation, the progress, and what the block buttons do.
final class ReviewView: NSView, TabPreview, DiffReviewer {
    let session: ReviewSession
    private(set) var comparison: CheckpointComparison
    private(set) var files: [ActivityChange]
    private weak var coordinator: ActivityCoordinator?
    private(set) var diffView: GitDiffView?
    /// Open the source file, at a zero-based line when one was pointed at.
    var onOpenLocation: ((URL, Int?) -> Void)?
    /// Set while an undo or a count is under way; the buttons wait for it.
    private(set) var isBusy = false
    private var isCounting = false

    private let top = NSStackView()
    private let bar = NSView()
    private let previousButton = NSButton(title: "‹ Previous File", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next File ›", target: nil, action: nil)
    private let counterLabel = NSTextField(labelWithString: "")
    private let fileLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private let keepAllButton = NSButton(title: "Keep All", target: nil, action: nil)
    private let undoAllButton = NSButton(title: "Undo All…", target: nil, action: nil)
    private let openButton = NSButton(title: "Open File", target: nil, action: nil)
    private let fileRow = NSView()
    private let fileKindLabel = NSTextField(labelWithString: "")
    private let fileKeepButton = NSButton(title: "Keep", target: nil, action: nil)
    private let fileUndoButton = NSButton(title: "Undo", target: nil, action: nil)
    private let fileMarkLabel = NSTextField(labelWithString: "")
    private let container = NSView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")

    var focusView: NSView { diffView?.focusView ?? self }

    init(comparison: CheckpointComparison, files: [ActivityChange], session: ReviewSession, coordinator: ActivityCoordinator?) {
        self.comparison = comparison
        self.files = files
        self.session = session
        self.coordinator = coordinator
        super.init(frame: .zero)
        wantsLayer = true
        build()
        applyTheme()
        session.onChange = { [weak self] in self?.updateHeader() }
        session.fileIndex = min(session.fileIndex, max(0, files.count - 1))
        showFile(session.fileIndex, block: session.blockIndex)
        countEverything()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        for (button, tip, action) in [(previousButton, "The file before this one (⌘[)", #selector(previousFileClicked)),
                                      (nextButton, "The file after this one (⌘])", #selector(nextFileClicked)),
                                      (keepAllButton, "Mark every change in every file as looked at, without changing anything", #selector(keepAllClicked)),
                                      (undoAllButton, "Put every file back as it was at the checkpoint", #selector(undoAllClicked)),
                                      (openButton, "Open this file in an editor", #selector(openFileClicked)),
                                      (fileKeepButton, "", #selector(fileKeepClicked)),
                                      (fileUndoButton, "", #selector(fileUndoClicked))] {
            button.bezelStyle = .recessed
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.toolTip = tip.isEmpty ? nil : tip
            button.target = self
            button.action = action
        }
        counterLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        counterLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        fileLabel.font = .systemFont(ofSize: 12, weight: .medium)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        progress.style = .bar
        progress.isIndeterminate = false
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.toolTip = "How much of the change has been kept or undone"
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progressLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let navigation = NSStackView(views: [previousButton, counterLabel, nextButton])
        navigation.spacing = 6
        let stack = NSStackView(views: [navigation, fileLabel, statsLabel, NSView(), progress, progressLabel, keepAllButton, undoAllButton, openButton])
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        bar.wantsLayer = true

        fileKindLabel.font = .systemFont(ofSize: 11.5)
        fileKindLabel.lineBreakMode = .byTruncatingTail
        fileMarkLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        fileMarkLabel.textColor = NSColor(hex: 0x3FB950)
        let row = NSStackView(views: [fileKindLabel, fileMarkLabel, fileKeepButton, fileUndoButton, NSView()])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        fileRow.addSubview(row)
        fileRow.wantsLayer = true

        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 0
        top.detachesHiddenViews = true
        top.addArrangedSubview(bar)
        top.addArrangedSubview(fileRow)

        messageLabel.alignment = .center
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.isHidden = true
        for view in [top, container, messageLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor),
            top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.widthAnchor.constraint(equalTo: top.widthAnchor),
            bar.heightAnchor.constraint(equalToConstant: 34),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 110),
            fileRow.widthAnchor.constraint(equalTo: top.widthAnchor),
            fileRow.heightAnchor.constraint(equalToConstant: 30),
            row.leadingAnchor.constraint(equalTo: fileRow.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: fileRow.trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: fileRow.centerYAnchor),
            container.topAnchor.constraint(equalTo: top.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -80),
        ])
    }

    // MARK: - TabPreview

    func applyTheme() {
        let theme = Settings.shared.theme
        layer?.backgroundColor = theme.background.cgColor
        bar.layer?.backgroundColor = theme.chrome.cgColor
        fileRow.layer?.backgroundColor = theme.background.cgColor
        for label in [fileLabel, fileKindLabel] { label.textColor = theme.foreground }
        for label in [counterLabel, progressLabel, messageLabel] { label.textColor = theme.lineNumber }
        diffView?.applyTheme()
        updateHeader()
    }

    func render() {
        if let diffView { diffView.render() } else { showFile(session.fileIndex, block: session.blockIndex) }
    }

    /// The Review tab was asked for again: the list of files is read afresh, and the review stays on the file it
    /// was on when that file is still in it.
    func update(comparison: CheckpointComparison, files: [ActivityChange]) {
        let currentPath = current?.path
        self.comparison = comparison
        self.files = files
        session.prepare(for: comparison.checkpoint)
        let index = currentPath.flatMap { path in files.firstIndex { $0.path == path } } ?? min(session.fileIndex, max(0, files.count - 1))
        showFile(index, block: index == session.fileIndex && currentPath != nil ? session.blockIndex : 0)
        countEverything()
    }

    // MARK: - Files

    var current: ActivityChange? { files.indices.contains(session.fileIndex) ? files[session.fileIndex] : nil }

    private var currentPath: String? { current?.path }

    func showFile(_ index: Int, block: Int = 0) {
        let hadFocus = (window?.firstResponder as? NSView)?.isDescendant(of: self) ?? false
        diffView?.removeFromSuperview()
        diffView = nil
        session.fileIndex = index
        session.blockIndex = block
        guard let change = files.indices.contains(index) ? files[index] : nil else {
            messageLabel.stringValue = "Nothing to review: every file is the same as it was at “\(comparison.checkpoint.name)”."
            messageLabel.isHidden = false
            container.isHidden = true
            updateHeader()
            return
        }
        messageLabel.isHidden = true
        container.isHidden = false
        let view = GitDiffView(root: comparison.store.root, path: change.path, originalPath: nil, side: .workingTree, comparison: comparison)
        view.isHeaderHidden = true
        view.reviewer = self
        view.asksBeforeUndoingBlock = false
        view.onOpenFile = { [weak self] url, line in self?.onOpenLocation?(url, line) }
        view.hasUnsavedEdits = { [weak self] in self?.document(for: change.path)?.isDirty ?? false }
        view.onDidLoad = { [weak self, weak view] in
            guard let self, let view, view === self.diffView else { return }
            self.diffLoaded(view)
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        diffView = view
        if hadFocus { window?.makeFirstResponder(view.focusView) }
        updateHeader()
    }

    /// The diff of the current file is in: its blocks are noted, the current block is put back in place.
    private func diffLoaded(_ view: GitDiffView) {
        let path = view.path
        if let diff = view.diff {
            session.note(path, hunks: diff.canPatchBlocks ? diff.hunks : (diff.hunks.isEmpty ? [] : [DiffHunk(oldStart: 0, oldCount: 0, newStart: 0, newCount: 0, patch: Data())]))
        } else if view.problem != nil {
            session.note(path, hunks: [DiffHunk(oldStart: 0, oldCount: 0, newStart: 0, newCount: 0, patch: Data())])
        }
        let block = view.blockCount == 0 ? -1 : max(0, min(session.blockIndex, view.blockCount - 1))
        session.blockIndex = max(0, block)
        view.selectBlock(block)
        updateHeader()
    }

    /// Whether the current file is dealt with as a whole (new, deleted, binary, too large) rather than by block.
    private var isFileLevel: Bool {
        guard let view = diffView else { return false }
        if view.problem != nil { return true }
        guard let diff = view.diff else { return false }
        return !diff.hunks.isEmpty && !diff.canPatchBlocks
    }

    private func updateHeader() {
        let count = files.count
        let has = current != nil
        counterLabel.stringValue = has ? "\(session.fileIndex + 1) of \(count) file\(count == 1 ? "" : "s")" : "0 files"
        previousButton.isEnabled = session.fileIndex > 0
        nextButton.isEnabled = session.fileIndex + 1 < count
        fileLabel.stringValue = current?.path ?? ""
        fileLabel.toolTip = current?.path
        openButton.isEnabled = current.map { FileManager.default.fileExists(atPath: comparison.store.root.appendingPathComponent($0.path).path) } ?? false
        let theme = Settings.shared.theme
        let stats = NSMutableAttributedString()
        if let diff = diffView?.diff, !diff.hunks.isEmpty {
            let font = statsLabel.font ?? NSFont.systemFont(ofSize: 11)
            stats.append(NSAttributedString(string: "+\(diff.insertions) ", attributes: [.foregroundColor: NSColor(hex: 0x3FB950), .font: font]))
            stats.append(NSAttributedString(string: "−\(diff.deletions)", attributes: [.foregroundColor: NSColor(hex: 0xF14C4C), .font: font]))
            if diff.canPatchBlocks {
                stats.append(NSAttributedString(string: "   \(diff.hunks.count) block\(diff.hunks.count == 1 ? "" : "s")", attributes: [.foregroundColor: theme.lineNumber, .font: font]))
            }
        }
        statsLabel.attributedStringValue = stats

        let total = session.total, reviewed = session.reviewed
        progress.doubleValue = total == 0 ? 0 : Double(reviewed) / Double(total)
        progressLabel.stringValue = total == 0 ? (isCounting ? "Counting…" : "Nothing to review") : "\(reviewed) of \(total) reviewed"
        keepAllButton.isEnabled = total > reviewed && !isBusy
        undoAllButton.isEnabled = has && !isBusy

        // The file-level row.
        if let change = current, isFileLevel {
            let key = ReviewSession.fileKey(change.path)
            let kept = session.isKept(key)
            switch change.kind {
            case .created:
                fileKindLabel.stringValue = "New file: it did not exist at the checkpoint."
                fileKeepButton.title = "Keep"
                fileUndoButton.title = "Move to Trash"
                fileUndoButton.toolTip = "The file goes to the Trash, where it can be found again. It is not deleted."
            case .deleted:
                fileKindLabel.stringValue = "Deleted file: it existed at the checkpoint and is gone now."
                fileKeepButton.title = "Keep Deleted"
                fileUndoButton.title = "Restore"
                fileUndoButton.toolTip = "The file comes back as it was at the checkpoint."
            case .changed:
                fileKindLabel.stringValue = diffView?.problem == .binary ? "Changed: this is not a text file, so its lines cannot be compared."
                    : (diffView?.problem == .tooLarge ? "Changed: this file is too large to compare here." : "Changed as a whole.")
                fileKeepButton.title = "Keep"
                fileUndoButton.title = "Restore File"
                fileUndoButton.toolTip = "The file goes back to how it was at the checkpoint."
            }
            fileKeepButton.toolTip = "Mark this file as looked at; nothing changes"
            fileMarkLabel.stringValue = kept ? "Kept ✓" : ""
            fileMarkLabel.isHidden = !kept
            fileKeepButton.isHidden = kept
            fileKeepButton.isEnabled = !isBusy
            fileUndoButton.isEnabled = !isBusy
            fileRow.isHidden = false
        } else {
            fileRow.isHidden = true
        }
        diffView?.needsDisplay = true
    }

    // MARK: - Counting every file

    /// The blocks of every file are counted once, off the main thread, so the progress bar knows how far there is
    /// to go before each file has been opened.
    private func countEverything() {
        let session = self.session
        let missing = files.map(\.path).filter { session.keys[$0] == nil }
        guard !missing.isEmpty, !isCounting else { return }
        isCounting = true
        let comparison = comparison
        comparison.store.perform({ () -> [(String, [DiffHunk])] in
            missing.map { path in
                switch comparison.store.loadDiff(path: path, since: comparison.checkpoint) {
                case .success(let diff):
                    return (path, diff.canPatchBlocks ? diff.hunks : (diff.hunks.isEmpty ? [] : [DiffHunk(oldStart: 0, oldCount: 0, newStart: 0, newCount: 0, patch: Data())]))
                case .failure:
                    return (path, [DiffHunk(oldStart: 0, oldCount: 0, newStart: 0, newCount: 0, patch: Data())])
                }
            }
        }) { [weak self] counted in
            guard let self, session === self.session, session.checkpointID == comparison.checkpoint.id else { return }
            self.isCounting = false
            for (path, hunks) in counted where session.keys[path] == nil { session.note(path, hunks: hunks) }
            self.updateHeader()
            self.pendingKeepAll?()
            self.pendingKeepAll = nil
        }
    }

    private var pendingKeepAll: (() -> Void)?

    // MARK: - Moving about

    func showNextFile() {
        guard session.fileIndex + 1 < files.count else { NSSound.beep(); return }
        showFile(session.fileIndex + 1, block: 0)
    }

    func showPreviousFile() {
        guard session.fileIndex > 0 else { NSSound.beep(); return }
        showFile(session.fileIndex - 1, block: 0)
    }

    /// The next block, or the first block of the next file when this file has no more.
    func selectNextBlock() {
        guard let view = diffView else { return }
        if session.blockIndex + 1 < view.blockCount {
            session.blockIndex += 1
            view.selectBlock(session.blockIndex)
        } else if session.fileIndex + 1 < files.count {
            showFile(session.fileIndex + 1, block: 0)
        } else {
            NSSound.beep()
        }
    }

    func selectPreviousBlock() {
        guard let view = diffView else { return }
        if session.blockIndex > 0, view.blockCount > 0 {
            session.blockIndex -= 1
            view.selectBlock(session.blockIndex)
        } else if session.fileIndex > 0 {
            showFile(session.fileIndex - 1, block: Int.max)
        } else {
            NSSound.beep()
        }
    }

    @objc private func previousFileClicked() { showPreviousFile() }

    @objc private func nextFileClicked() { showNextFile() }

    @objc private func openFileClicked() { diffView?.openFile(line: nil) }

    // MARK: - Keeping and undoing

    private func key(for hunk: Int) -> ReviewSession.Key? {
        guard let path = currentPath, let list = session.keys[path], list.indices.contains(hunk) else { return nil }
        return list[hunk]
    }

    /// Keep: looked at, nothing changes, and on to the next block.
    func keep(hunk: Int) {
        guard let key = key(for: hunk) else { NSSound.beep(); return }
        session.keep(key)
        if hunk == session.blockIndex { selectNextBlock() }
    }

    /// Undo: the block goes back to the checkpoint's lines, in the file and in any editor showing it. The editor's
    /// own undo (⌘Z) brings it back; a file with unsaved edits around the block is left alone.
    func undo(hunk index: Int, completion: ((Bool) -> Void)? = nil) {
        guard let view = diffView, let diff = view.diff, diff.canPatchBlocks, diff.hunks.indices.contains(index), !isBusy,
              let key = key(for: index) else { NSSound.beep(); completion?(false); return }
        let hunk = diff.hunks[index]
        let url = view.fileURL.standardizedFileURL
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url), let result = HunkPatch.undo(hunk, in: data) else {
            report("The file has changed since this comparison was made", "“\(name)” has been read again; try once more.")
            view.render()
            completion?(false)
            return
        }
        let store = coordinator?.controller?.store
        let document = store?.existingDocument(at: url)
        var edit: RangeEdit?
        if let document {
            guard let found = HunkPatch.edit(for: hunk, in: document.text, encoding: document.encoding) else {
                report("Save the file first", "“\(name)” has edits you have not saved around this change. Save the file (or undo your edits) and try again.")
                completion?(false)
                return
            }
            edit = found
        }
        do { try result.data.write(to: url, options: .atomic) } catch {
            report("Could not undo this change", error.localizedDescription)
            completion?(false)
            return
        }
        if let document, let edit {
            let wasDirty = document.isDirty
            if let editor = loadedEditor(for: document) {
                editor.apply([edit], named: "Undo Change")
            } else {
                document.apply([edit])
            }
            store?.noteWrittenToDisk(document)
            if !wasDirty { document.isDirty = false }
        }
        NotificationCenter.default.post(name: DocumentStore.didSaveDocument, object: store, userInfo: ["url": url])
        session.noteUndone(key)
        coordinator?.refreshSoon(delay: 0)
        view.render()
        completion?(true)
    }

    private func document(for path: String) -> TextDocument? {
        coordinator?.controller?.store.existingDocument(at: comparison.store.root.appendingPathComponent(path).standardizedFileURL)
    }

    private func loadedEditor(for document: TextDocument) -> EditorView? {
        coordinator?.controller?.editors.groups.lazy.flatMap(\.tabs).first { $0.document === document }?.editorIfLoaded
    }

    @objc private func fileKeepClicked() {
        guard let change = current else { return }
        session.keep(ReviewSession.fileKey(change.path))
        if session.fileIndex + 1 < files.count { showFile(session.fileIndex + 1, block: 0) } else { updateHeader() }
    }

    /// Move to Trash, Restore, Restore File: the same as the pane's per-file undo, with its safety checkpoint.
    @objc private func fileUndoClicked() { undoFile() }

    func undoFile(completion: ((Bool) -> Void)? = nil) {
        guard let change = current, let coordinator, !isBusy else { NSSound.beep(); completion?(false); return }
        isBusy = true
        updateHeader()
        coordinator.restoreFile(path: change.path, confirmed: true) { [weak self] outcome in
            guard let self else { return }
            self.isBusy = false
            let done = outcome != nil && outcome?.error == nil
            if done { self.session.noteUndone(ReviewSession.fileKey(change.path)) }
            self.diffView?.render()
            self.updateHeader()
            completion?(done)
        }
    }

    @objc private func keepAllClicked() {
        if isCounting {
            pendingKeepAll = { [weak self] in self?.session.keepAll() }
        } else {
            session.keepAll()
        }
        updateHeader()
    }

    @objc private func undoAllClicked() {
        guard let coordinator else { return }
        coordinator.undoAll { [weak self] outcome in
            guard let self, let outcome, outcome.error == nil else { return }
            self.session.noteUndoneEverything()
            self.diffView?.render()
            self.updateHeader()
        }
    }

    private func report(_ title: String, _ details: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = String(details.prefix(1200))
        alert.runModal()
    }

    // MARK: - DiffReviewer

    func pills(for hunk: Int, in view: GitDiffView) -> [DiffPill] {
        guard view === diffView, let diff = view.diff, diff.canPatchBlocks, let key = key(for: hunk) else { return [] }
        var pills: [DiffPill] = []
        if !session.isKept(key) { pills.append(DiffPill(id: "keep", title: "Keep", isDestructive: false)) }
        pills.append(DiffPill(id: "undo", title: "Undo", isDestructive: true))
        return pills
    }

    func chose(_ pill: DiffPill, hunk: Int, in view: GitDiffView) {
        session.blockIndex = hunk
        view.selectBlock(hunk)
        if pill.id == "keep" { keep(hunk: hunk) } else { undo(hunk: hunk) }
    }

    func mark(for hunk: Int, in view: GitDiffView) -> String? {
        guard let key = key(for: hunk), session.isKept(key) else { return nil }
        return "Kept ✓"
    }

    func handleKey(_ event: NSEvent, in view: GitDiffView) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command] {
            switch event.charactersIgnoringModifiers {
            case "]": showNextFile(); return true
            case "[": showPreviousFile(); return true
            default: return false
            }
        }
        guard flags.subtracting(.shift).isEmpty else { return false }
        if let special = event.specialKey {
            switch special {
            case .downArrow: selectNextBlock(); return true
            case .upArrow: selectPreviousBlock(); return true
            default: return false
            }
        }
        switch event.characters {
        case "j": selectNextBlock(); return true
        case "k": selectPreviousBlock(); return true
        case "K":
            guard view.selectedBlock >= 0 else { NSSound.beep(); return true }
            keep(hunk: view.selectedBlock)
            return true
        case "u", "U":
            guard view.selectedBlock >= 0 else { NSSound.beep(); return true }
            undo(hunk: view.selectedBlock)
            return true
        default: return false
        }
    }
}

extension EditorAreaViewController {
    /// The Review tab for a checkpoint: one per group, brought forward and brought up to date if it is open.
    func openReview(_ comparison: CheckpointComparison, files: [ActivityChange], coordinator: ActivityCoordinator) {
        let key = comparison.store.root.appendingPathComponent("⟨review⟩ Review Changes")
        if let index = tabs.firstIndex(where: { $0.url == key }) {
            select(index)
            (tabs[index].preview as? ReviewView)?.update(comparison: comparison, files: files)
            return
        }
        let view = ReviewView(comparison: comparison, files: files, session: coordinator.review, coordinator: coordinator)
        view.onOpenLocation = { [weak self] url, line in
            self?.onOpenLocation?(LSPLocation(url: url.standardizedFileURL, line: line ?? 0, character: 0, endLine: line ?? 0, endCharacter: 0))
        }
        addViewTab(for: store.openVirtual(key, title: "Review Changes"), preview: view)
    }
}

extension MainWindowController {
    @objc func reviewChanges(_ sender: Any?) { activity.openReview() }
}
