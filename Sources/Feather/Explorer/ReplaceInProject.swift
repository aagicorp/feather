import AppKit

/// Everything a Replace All would do, ready to be looked at.
struct ReplacePlan {
    let request: ReplaceRequest
    let files: [FileReplacement]
    /// Files the results listed that could not be read again (deleted or changed to binary since the search).
    let unreadable: [String]

    var count: Int { files.reduce(0) { $0 + $1.count } }
}

// MARK: - The preview tab

/// A row of the preview: one line as it is, or as it becomes.
private final class PreviewRow: NSObject {
    enum Kind { case old, new }
    let kind: Kind
    let line: Int
    let text: String
    let spans: [NSRange]
    let file: FileReplacement

    init(kind: Kind, line: Int, text: String, spans: [NSRange], file: FileReplacement) {
        self.kind = kind
        self.line = line
        self.text = text
        self.spans = spans
        self.file = file
    }
}

/// "… 40 more" under a file with more changed lines than are worth building rows for.
private final class PreviewOverflow: NSObject {
    let count: Int
    init(count: Int) { self.count = count }
}

/// A file's row: the Keep/Skip switch and the name. Laid out by hand, so it costs no constraints per row.
private final class PreviewFileRowView: NSView {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        checkbox.controlSize = .small
        checkbox.sizeToFit()
        label.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(checkbox)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let box = checkbox.frame.size
        checkbox.frame = NSRect(x: 2, y: (bounds.height - box.height) / 2, width: box.width, height: box.height)
        let x = checkbox.frame.maxX + 4
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: max(0, bounds.width - x - 4), height: height)
    }
}

/// Tints the whole row red or green, the way the diff view colours changed lines.
private final class PreviewRowView: NSTableRowView {
    var tint: NSColor?

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let tint else { return }
        tint.setFill()
        bounds.fill()
    }
}

/// The tab Replace All opens first: every file's changed lines, old above new, with a switch per file. Nothing
/// is changed until Apply; the search pane's own rows still replace one at a time without coming here.
final class ReplacePreviewView: NSView, TabPreview, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private static let rowsPerFile = 150

    private(set) var plan: ReplacePlan
    /// Apply: the files whose switch is on. The window does the replacing and closes the tab.
    var onApply: ((ReplacePlan, [FileReplacement]) -> Void)?
    var onCancel: (() -> Void)?
    /// Opens the file at a zero-based line.
    var onOpenFile: ((URL, Int) -> Void)?

    private let header = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let applyButton = NSButton(title: "Replace", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private var rows: [ObjectIdentifier: [NSObject]] = [:]

    var focusView: NSView { outlineView }

    init(plan: ReplacePlan) {
        self.plan = plan
        super.init(frame: .zero)
        wantsLayer = true
        build()
        applyTheme()
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statsLabel.font = .systemFont(ofSize: 11)
        applyButton.bezelStyle = .rounded
        applyButton.controlSize = .small
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(applyClicked)
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        let bar = NSStackView(views: [titleLabel, statsLabel, NSView(), cancelButton, applyButton])
        bar.spacing = 10
        bar.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(bar)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("change"))
        column.resizingMask = [.autoresizingMask]
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 20
        outlineView.indentationPerLevel = 12
        outlineView.style = .plain
        outlineView.backgroundColor = .clear
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(rowDoubleClicked)
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        for view in [header, scrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),
            bar.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            bar.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - TabPreview

    func applyTheme() {
        let theme = Settings.shared.theme
        layer?.backgroundColor = theme.background.cgColor
        header.wantsLayer = true
        header.layer?.backgroundColor = theme.chrome.cgColor
        titleLabel.textColor = theme.foreground
        statsLabel.textColor = theme.lineNumber
        outlineView.reloadData()
    }

    func render() {
        rows = [:]
        let request = plan.request
        titleLabel.stringValue = "Replace “\(request.query)” with “\(request.replacement)”"
        titleLabel.toolTip = request.options.isRegex ? "A regular expression; $1, $2… in the replacement stand for its groups." : nil
        outlineView.reloadData()
        for file in plan.files { outlineView.expandItem(file) }
        updateCounts()
    }

    /// The same preview again with a new plan, when Replace All is pressed while the tab is open.
    func show(_ plan: ReplacePlan) {
        self.plan = plan
        render()
    }

    var keptFiles: [FileReplacement] { plan.files.filter(\.isKept) }

    private func updateCounts() {
        let kept = keptFiles
        let count = kept.reduce(0) { $0 + $1.count }
        let skipped = plan.files.count - kept.count
        var stats = ProjectReplace.summary(count: count, files: kept.count)
        if skipped > 0 { stats += "  ·  \(skipped) skipped" }
        if !plan.unreadable.isEmpty { stats += "  ·  \(plan.unreadable.count) could not be read" }
        statsLabel.stringValue = stats
        applyButton.title = count == 0 ? "Replace" : "Replace \(count) in \(kept.count) File\(kept.count == 1 ? "" : "s")"
        applyButton.isEnabled = count > 0
    }

    @objc private func applyClicked() { onApply?(plan, keptFiles) }

    @objc private func cancelClicked() { onCancel?() }

    @objc private func rowDoubleClicked() {
        let item = outlineView.item(atRow: outlineView.clickedRow)
        if let row = item as? PreviewRow { onOpenFile?(row.file.url, row.line) }
        else if let file = item as? FileReplacement { onOpenFile?(file.url, file.lines.first?.line ?? 0) }
    }

    @objc private func keepToggled(_ sender: NSButton) {
        guard let file = plan.files.first(where: { ObjectIdentifier($0).hashValue == sender.tag }) else { return }
        file.isKept = sender.state == .on
        updateCounts()
        outlineView.reloadItem(file, reloadChildren: true)
        if file.isKept { outlineView.expandItem(file) }
    }

    /// The tests read the switches through this.
    func setKept(_ kept: Bool, fileAt index: Int) {
        guard plan.files.indices.contains(index) else { return }
        plan.files[index].isKept = kept
        updateCounts()
        outlineView.reloadItem(plan.files[index], reloadChildren: true)
    }

    // MARK: - Rows

    private func rows(of file: FileReplacement) -> [NSObject] {
        if let built = rows[ObjectIdentifier(file)] { return built }
        var built: [NSObject] = []
        for change in file.lines.prefix(ReplacePreviewView.rowsPerFile) {
            let spans = FileDiff.changedSpans(change.old, change.new)
            built.append(PreviewRow(kind: .old, line: change.line, text: change.old, spans: spans.old, file: file))
            built.append(PreviewRow(kind: .new, line: change.line, text: change.new, spans: spans.new, file: file))
        }
        if file.lines.count > ReplacePreviewView.rowsPerFile { built.append(PreviewOverflow(count: file.lines.count - ReplacePreviewView.rowsPerFile)) }
        rows[ObjectIdentifier(file)] = built
        return built
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let file = item as? FileReplacement else { return item == nil ? plan.files.count : 0 }
        return file.isKept ? rows(of: file).count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let file = item as? FileReplacement else { return plan.files[index] }
        return rows(of: file)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileReplacement)?.isKept ?? false }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("PreviewRowView")
        let view = outlineView.makeView(withIdentifier: identifier, owner: nil) as? PreviewRowView ?? {
            let view = PreviewRowView()
            view.identifier = identifier
            return view
        }()
        let theme = Settings.shared.theme
        let alpha: CGFloat = theme.isDark ? 0.14 : 0.12
        switch (item as? PreviewRow)?.kind {
        case .old: view.tint = NSColor(hex: 0xF85149).withAlphaComponent(alpha)
        case .new: view.tint = NSColor(hex: 0x3FB950).withAlphaComponent(alpha)
        case nil: view.tint = nil
        }
        return view
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let theme = Settings.shared.theme
        if let file = item as? FileReplacement {
            let identifier = NSUserInterfaceItemIdentifier("PreviewFileCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? PreviewFileRowView ?? {
                let cell = PreviewFileRowView(frame: .zero)
                cell.identifier = identifier
                cell.checkbox.target = self
                cell.checkbox.action = #selector(keepToggled(_:))
                return cell
            }()
            cell.checkbox.state = file.isKept ? .on : .off
            cell.checkbox.tag = ObjectIdentifier(file).hashValue
            cell.checkbox.toolTip = file.isKept ? "Skip this file" : "Include this file"
            let path = file.relativePath as NSString
            let text = NSMutableAttributedString(attributedString: FileIcon.attributed(for: file.url))
            text.append(NSAttributedString(string: path.lastPathComponent, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: file.isKept ? theme.foreground : theme.lineNumber]))
            text.append(NSAttributedString(string: "  \(path.deletingLastPathComponent)  \(file.count) replacement\(file.count == 1 ? "" : "s")\(file.isKept ? "" : "  — skipped")",
                                           attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: theme.lineNumber]))
            cell.label.attributedStringValue = text
            cell.toolTip = file.url.path
            cell.needsLayout = true
            return cell
        }
        let identifier = NSUserInterfaceItemIdentifier("PreviewLineCell")
        let label = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField ?? {
            let label = NSTextField(labelWithString: "")
            label.identifier = identifier
            label.usesSingleLineMode = true
            label.lineBreakMode = .byClipping
            return label
        }()
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        if let row = item as? PreviewRow {
            let text = NSMutableAttributedString()
            let sign = row.kind == .old ? "−" : "+"
            let signColor = row.kind == .old ? NSColor(hex: 0xF85149) : NSColor(hex: 0x3FB950)
            text.append(NSAttributedString(string: sign + " ", attributes: [.font: mono, .foregroundColor: signColor]))
            text.append(NSAttributedString(string: String(format: "%4d  ", row.line + 1), attributes: [.font: mono, .foregroundColor: theme.lineNumber]))
            let start = text.length
            var shown = row.text.replacingOccurrences(of: "\t", with: "    ")
            if shown.utf16.count > 3000 { shown = String(shown.prefix(3000)) + " …" }
            text.append(NSAttributedString(string: shown, attributes: [.font: mono, .foregroundColor: theme.foreground]))
            if !row.text.contains("\t") {
                let strong = signColor.withAlphaComponent(theme.isDark ? 0.42 : 0.3)
                for span in row.spans where NSMaxRange(span) + start <= text.length {
                    text.addAttribute(.backgroundColor, value: strong, range: NSRange(location: start + span.location, length: span.length))
                }
            }
            label.attributedStringValue = text
            label.toolTip = "Double-click to open the file here"
        } else if let overflow = item as? PreviewOverflow {
            label.attributedStringValue = NSAttributedString(string: "… \(overflow.count) more changed line\(overflow.count == 1 ? "" : "s") in this file",
                                                             attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: theme.lineNumber])
            label.toolTip = nil
        }
        return label
    }
}

// MARK: - Opening the preview

extension EditorAreaViewController {
    /// The one preview tab of the group: opened, or brought forward and refilled.
    @discardableResult
    func openReplacePreview(_ plan: ReplacePlan, root: URL) -> ReplacePreviewView {
        let key = root.appendingPathComponent("⟨replace⟩ Replace Preview")
        if let index = tabs.firstIndex(where: { $0.url == key }), let view = tabs[index].preview as? ReplacePreviewView {
            select(index)
            view.show(plan)
            return view
        }
        let view = ReplacePreviewView(plan: plan)
        view.onOpenFile = { [weak self] url, line in
            self?.onOpenLocation?(LSPLocation(url: url.standardizedFileURL, line: line, character: 0, endLine: line, endCharacter: 0))
        }
        addViewTab(for: store.openVirtual(key, title: "Replace Preview"), preview: view)
        return view
    }

    func closeReplacePreview() {
        if let index = tabs.firstIndex(where: { $0.preview is ReplacePreviewView }) { close(at: index) }
    }
}

// MARK: - The window's side

extension MainWindowController {
    /// Edit ▸ Replace in Project… (⇧⌘H): the Search pane with its Replace field showing.
    @objc func replaceInProject(_ sender: Any?) {
        findInProject(sender)
        sidebarContainer.search.showReplace(true, focusing: true)
    }

    func installReplaceInProject() {
        sidebarContainer.search.onReplace = { [weak self] request in self?.replace(request) }
        sidebarContainer.search.openTexts = { [weak self] in
            guard let self else { return [:] }
            return Dictionary(uniqueKeysWithValues: self.store.dirtyDocuments.compactMap { document in
                document.url.map { ($0.standardizedFileURL, document.text) }
            })
        }
    }

    /// A request from the Search pane: straight to the files for one row or one file, through the preview for
    /// Replace All.
    private func replace(_ request: ReplaceRequest) {
        guard let root = projectRoot else { NSSound.beep(); return }
        planReplacement(request, root: root) { [weak self] plan in
            guard let self else { return }
            guard !plan.files.isEmpty else {
                self.sidebarContainer.search.refresh()          // the results were stale: nothing matched any more
                return
            }
            if request.wantsPreview {
                let preview = self.editorArea.openReplacePreview(plan, root: root)
                preview.onApply = { [weak self] plan, kept in
                    self?.editorArea.closeReplacePreview()
                    self?.applyReplacement(plan.request, to: kept.map(\.url), root: root)
                }
                preview.onCancel = { [weak self] in self?.editorArea.closeReplacePreview() }
            } else {
                self.applyReplacement(request, to: plan.files.map(\.url), root: root)
            }
        }
    }

    /// Works out the replacement per file without changing anything: open documents from their text in memory
    /// (they may have unsaved edits), the rest from disk, off the main thread.
    func planReplacement(_ request: ReplaceRequest, root: URL, completion: @escaping (ReplacePlan) -> Void) {
        guard let regex = request.regex else { return completion(ReplacePlan(request: request, files: [], unreadable: [])) }
        let open = Dictionary(uniqueKeysWithValues: request.files.compactMap { file -> (URL, String)? in
            guard let document = store.existingDocument(at: file.url) else { return nil }
            return (file.url, document.text)
        })
        let files = request.files.map { ($0.url, $0.relativePath) }
        let only = request.only
        DispatchQueue.global(qos: .userInitiated).async {
            var planned: [FileReplacement] = []
            var unreadable: [String] = []
            for (url, path) in files {
                guard let text = open[url] ?? ProjectReplace.read(url)?.text else { unreadable.append(path); continue }
                if let file = ProjectReplace.plan(url: url, relativePath: path, text: text, regex: regex, replacement: request.replacement,
                                                  isRegex: request.options.isRegex, only: only?[url]) {
                    planned.append(file)
                }
            }
            DispatchQueue.main.async { completion(ReplacePlan(request: request, files: planned, unreadable: unreadable)) }
        }
    }

    /// Makes the replacement in `urls`, working from each file's text as it is now rather than as it was
    /// previewed. Open documents are edited in memory, as one undoable step each and left unsaved; the others are
    /// rewritten on disk after a checkpoint, so Undo All in the Activity pane can put them back.
    func applyReplacement(_ request: ReplaceRequest, to urls: [URL], root: URL, completion: (() -> Void)? = nil) {
        guard let regex = request.regex, !urls.isEmpty else { completion?(); return }
        let onDisk = urls.filter { store.existingDocument(at: $0) == nil }
        let proceed = { [weak self] (checkpointed: Bool) in
            guard let self else { return }
            var count = 0, files = 0
            for url in urls {
                guard let document = self.store.existingDocument(at: url) else { continue }
                let edits = ProjectReplace.edits(in: document.text, regex: regex, replacement: request.replacement,
                                                 isRegex: request.options.isRegex, only: request.only?[url])
                guard !edits.isEmpty else { continue }
                let tabs = [self.editorArea.currentTab].compactMap { $0 } + self.editors.groups.flatMap(\.tabs)
                if let editor = tabs.first(where: { $0.document === document && $0.isEditorLoaded })?.editorIfLoaded {
                    if !editor.apply(edits, named: "Replace in Project") { continue }
                } else {
                    document.apply(edits)
                }
                count += edits.count
                files += 1
            }
            let isRegex = request.options.isRegex, replacement = request.replacement, only = request.only
            DispatchQueue.global(qos: .userInitiated).async {
                var diskCount = 0, diskFiles = 0, failed: [String] = []
                for url in onDisk {
                    guard let (text, _) = ProjectReplace.read(url) else { failed.append(url.lastPathComponent); continue }
                    let edits = ProjectReplace.edits(in: text, regex: regex, replacement: replacement, isRegex: isRegex, only: only?[url])
                    guard !edits.isEmpty else { continue }
                    let file = FileReplacement(url: url, relativePath: url.lastPathComponent, edits: edits, lines: [])
                    if ProjectReplace.rewrite(file, expecting: text) { diskCount += edits.count; diskFiles += 1 } else { failed.append(url.lastPathComponent) }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if diskFiles > 0 { self.store.syncWithDisk(refreshGitBases: true) }
                    self.sidebarContainer.search.refresh()
                    self.showReplaceNotice(count: count + diskCount, files: files + diskFiles, checkpointed: checkpointed && diskFiles > 0, failed: failed)
                    completion?()
                }
            }
        }
        if onDisk.isEmpty {
            proceed(false)
        } else {
            activity.newCheckpoint(named: "Before replacing “\(request.query)”") { checkpoint in proceed(checkpoint != nil) }
        }
    }

    private func showReplaceNotice(count: Int, files: Int, checkpointed: Bool, failed: [String]) {
        guard let window else { return }
        var text = count == 0 ? "Nothing was replaced." : "Made " + ProjectReplace.summary(count: count, files: files) + "."
        if checkpointed { text += " A checkpoint was saved first: Undo All in the Activity pane puts the files back." }
        if !failed.isEmpty { text += " Could not change: " + failed.prefix(3).joined(separator: ", ") + (failed.count > 3 ? "…" : "") + "." }
        var actions: [NoticeCard.Action] = []
        if checkpointed {
            actions.append(NoticeCard.Action(title: "Show Activity") { [weak self] in self?.showActivity(nil) })
        }
        let card = NoticeCard(kind: "replace", symbol: count == 0 || !failed.isEmpty ? "exclamationmark.circle" : "checkmark.circle",
                              text: text, actions: actions, dismissTitle: "OK")
        WindowNotices.show(card, in: window)
    }
}
