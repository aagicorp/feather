import AppKit

/// One file row: a dot while the file is still changing, the name, and at the right how much changed and when.
private final class ActivityFileCell: NSTableCellView {
    let dot = NSView()
    let name = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = NSColor(hex: 0x3FB950).cgColor
        name.lineBreakMode = .byTruncatingTail
        name.usesSingleLineMode = true
        name.maximumNumberOfLines = 1
        name.cell?.wraps = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.alignment = .right
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        detail.setContentHuggingPriority(.required, for: .horizontal)
        for view in [dot, name, detail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            name.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// The Activity pane: what is different in the project since a checkpoint, whoever changed it.
///
/// It only shows; the window's `ActivityCoordinator` owns the checkpoints, the watching and every action.
final class ActivityViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    /// How long a file keeps its "just changed" dot.
    static let recentSeconds: TimeInterval = 6

    enum Row {
        case group(String)
        case file(ActivityChange)
        case note(String)
    }

    var onNewCheckpoint: (() -> Void)?
    var onUndoAll: (() -> Void)?
    var onReview: (() -> Void)?
    /// Nil means "the newest one".
    var onPickCheckpoint: ((Checkpoint) -> Void)?
    var onShowChange: ((ActivityChange) -> Void)?
    var onOpenFile: ((ActivityChange) -> Void)?
    var onRestoreFile: ((ActivityChange) -> Void)?
    var onClear: (() -> Void)?
    var onNotice: (() -> Void)?
    /// The pane came on screen; the coordinator brings it up to date if it missed anything.
    var onAppear: (() -> Void)?

    private(set) var rows: [Row] = []
    private(set) var snapshot: ActivitySnapshot?
    private var checkpoints: [Checkpoint] = []
    private var selected: Checkpoint?

    private let caption = NSTextField(labelWithString: "CHANGES SINCE")
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let newButton = NSButton(title: "＋ Checkpoint", target: nil, action: nil)
    private let undoButton = NSButton(title: "Undo All…", target: nil, action: nil)
    private let reviewButton = NSButton(title: "Review Changes", target: nil, action: nil)
    private let followBox = NSButton(checkboxWithTitle: "Follow changes", target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private let noticeButton = NSButton(title: "", target: nil, action: nil)
    private let noticeBox = NSStackView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let diskLabel = NSTextField(labelWithString: "")
    private let clearButton = NSButton(title: "Clear…", target: nil, action: nil)
    private var dotTimer: Timer?
    private var ageTimer: Timer?

    var isOnScreen: Bool { isViewLoaded && view.window != nil && !view.isHiddenOrHasHiddenAncestor }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 560))

        caption.font = .systemFont(ofSize: 10, weight: .semibold)
        picker.controlSize = .small
        picker.font = .systemFont(ofSize: 11)
        picker.target = self
        picker.action = #selector(pickerChanged)
        picker.menu?.delegate = self
        picker.toolTip = "The checkpoint the project is compared with. Pick an older one to see everything since then."
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        (picker.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail

        for (button, tip, action) in [(newButton, "Save a checkpoint of the whole project now, so you can come back to it", #selector(newClicked)),
                                      (undoButton, "Put every file back as it was at this checkpoint", #selector(undoClicked)),
                                      (reviewButton, "Go through every change since this checkpoint, one block at a time, and keep or undo each (⌃⇧R)", #selector(reviewClicked))] {
            button.bezelStyle = .recessed
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.toolTip = tip
            button.target = self
            button.action = action
        }
        followBox.controlSize = .small
        followBox.font = .systemFont(ofSize: 11)
        followBox.toolTip = "When something other than Feather changes a file, show that file and flash the lines that changed"
        followBox.target = self
        followBox.action = #selector(followClicked)

        let buttons = NSStackView(views: [newButton, undoButton])
        buttons.spacing = 6
        reviewButton.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil)
        reviewButton.imagePosition = .imageLeading
        let review = NSStackView(views: [reviewButton])
        summary.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        summary.lineBreakMode = .byTruncatingTail

        noticeLabel.font = .systemFont(ofSize: 11)
        noticeButton.bezelStyle = .recessed
        noticeButton.controlSize = .small
        noticeButton.font = .systemFont(ofSize: 11)
        noticeButton.target = self
        noticeButton.action = #selector(noticeClicked)
        noticeBox.orientation = .vertical
        noticeBox.alignment = .leading
        noticeBox.spacing = 4
        noticeBox.addArrangedSubview(noticeLabel)
        noticeBox.addArrangedSubview(noticeButton)
        noticeBox.isHidden = true

        let header = NSStackView(views: [caption, picker, buttons, review, followBox, noticeBox, summary])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        header.setHuggingPriority(.required, for: .vertical)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("activity"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.alignment = .center
        diskLabel.font = .systemFont(ofSize: 10.5)
        diskLabel.lineBreakMode = .byTruncatingTail
        diskLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        clearButton.isBordered = false
        clearButton.font = .systemFont(ofSize: 10.5)
        clearButton.toolTip = "Forget this project’s checkpoints and give the disk space back. Your files are not touched."
        clearButton.target = self
        clearButton.action = #selector(clearClicked)
        let footer = NSStackView(views: [diskLabel, NSView(), clearButton])
        footer.spacing = 4

        for subview in [header, scrollView, emptyLabel, footer] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            picker.widthAnchor.constraint(equalTo: header.widthAnchor),
            noticeBox.widthAnchor.constraint(equalTo: header.widthAnchor),
            summary.widthAnchor.constraint(equalTo: header.widthAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 40),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -28),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5),
            footer.heightAnchor.constraint(equalToConstant: 16),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(followChanged), name: Settings.followChangesDidChange, object: nil)
        followChanged()
        applyTheme()
        render()
    }

    func applyTheme() {
        guard isViewLoaded else { return }
        let theme = Settings.shared.theme
        caption.textColor = theme.lineNumber
        summary.textColor = theme.lineNumber
        emptyLabel.textColor = theme.lineNumber
        diskLabel.textColor = theme.lineNumber
        noticeLabel.textColor = theme.foreground
        clearButton.contentTintColor = theme.lineNumber
        clearButton.attributedTitle = NSAttributedString(string: "Clear…", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: theme.lineNumber])
        followBox.attributedTitle = NSAttributedString(string: "Follow changes", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: theme.foreground])
        tableView.reloadData()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        onAppear?()
        // Ages ("5 min ago") move on while the pane is looked at.
        ageTimer?.invalidate()
        ageTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refreshAges() }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        ageTimer?.invalidate()
        ageTimer = nil
        dotTimer?.invalidate()
        dotTimer = nil
    }

    // MARK: - What it shows

    /// The checkpoints for the picker, newest first, and the one being compared with.
    func show(checkpoints: [Checkpoint], selected: Checkpoint?) {
        self.checkpoints = checkpoints
        self.selected = selected
        guard isViewLoaded else { return }
        rebuildPicker()
        render()
    }

    func show(_ snapshot: ActivitySnapshot?) {
        self.snapshot = snapshot
        guard isViewLoaded else { return }
        render()
    }

    /// A line above the list with one button, e.g. after an undo: how to get the changes back.
    func showNotice(_ text: String?, button: String? = nil) {
        _ = view
        noticeLabel.stringValue = text ?? ""
        noticeButton.title = button ?? ""
        noticeButton.isHidden = button == nil
        noticeBox.isHidden = text == nil
    }

    var noticeText: String? { noticeBox.isHidden ? nil : noticeLabel.stringValue }

    func show(diskUse bytes: Int) {
        _ = view
        diskLabel.stringValue = checkpoints.isEmpty ? "" : "\(checkpoints.count) checkpoint\(checkpoints.count == 1 ? "" : "s") · "
            + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        diskLabel.toolTip = "Checkpoints of this project are kept outside it, in Feather’s own folder, and take this much disk. The newest \(CheckpointStore.keepCount) are kept."
        clearButton.isHidden = checkpoints.isEmpty
    }

    var hasFolder = false { didSet { if isViewLoaded { render() } } }

    /// When there is nothing to list: why.
    var emptyMessage = "Open a folder to see what changes in it." { didSet { if isViewLoaded { render() } } }

    private func rebuildPicker() {
        picker.removeAllItems()
        for checkpoint in checkpoints {
            picker.addItem(withTitle: "")           // titles may repeat, and a pop-up drops repeated titles
            picker.lastItem?.title = checkpoint.name + "  ·  " + checkpoint.age
            picker.lastItem?.representedObject = checkpoint.id
        }
        if let index = checkpoints.firstIndex(where: { $0.id == selected?.id }) { picker.selectItem(at: index) }
        picker.isEnabled = !checkpoints.isEmpty
        picker.menu?.delegate = self
    }

    private func render() {
        var rows: [Row] = []
        if let snapshot {
            let groups: [(ActivityChange.Kind, String)] = [(.changed, "Changed"), (.created, "New"), (.deleted, "Deleted")]
            for (kind, title) in groups {
                let files = snapshot.changes.filter { $0.kind == kind }
                guard !files.isEmpty else { continue }
                rows.append(.group("\(title) (\(files.count))"))
                rows.append(contentsOf: files.map(Row.file))
            }
            if snapshot.unlisted > 0 { rows.append(.note("…and \(snapshot.unlisted) more files that changed earlier")) }
        }
        self.rows = rows
        tableView.reloadData()

        let count = (snapshot?.changes.count ?? 0) + (snapshot?.unlisted ?? 0)
        let text = NSMutableAttributedString()
        if let snapshot, count > 0 {
            let font = summary.font ?? NSFont.systemFont(ofSize: 11)
            text.append(NSAttributedString(string: "\(count) file\(count == 1 ? "" : "s")   ", attributes: [.font: font, .foregroundColor: Settings.shared.theme.lineNumber]))
            text.append(NSAttributedString(string: "+\(snapshot.insertions) ", attributes: [.font: font, .foregroundColor: NSColor(hex: 0x3FB950)]))
            text.append(NSAttributedString(string: "−\(snapshot.deletions)", attributes: [.font: font, .foregroundColor: NSColor(hex: 0xF14C4C)]))
        }
        summary.attributedStringValue = text
        summary.isHidden = count == 0
        undoButton.isEnabled = count > 0
        reviewButton.isEnabled = count > 0
        newButton.isEnabled = hasFolder
        if snapshot == nil {
            emptyLabel.stringValue = emptyMessage
        } else {
            emptyLabel.stringValue = "Nothing has changed since this checkpoint."
        }
        emptyLabel.isHidden = !rows.isEmpty
        scheduleDotExpiry()
    }

    /// The dots go out by themselves: one redraw when the youngest of them is due.
    private func scheduleDotExpiry() {
        dotTimer?.invalidate()
        dotTimer = nil
        let now = Date()
        let ages = (snapshot?.changes ?? []).compactMap { $0.modified.map { now.timeIntervalSince($0) } }
        guard let youngest = ages.filter({ $0 < ActivityViewController.recentSeconds }).min() else { return }
        dotTimer = Timer.scheduledTimer(withTimeInterval: ActivityViewController.recentSeconds - youngest + 0.1, repeats: false) { [weak self] _ in
            self?.tableView.reloadData()
            self?.scheduleDotExpiry()
        }
    }

    private func refreshAges() {
        guard isOnScreen else { return }
        tableView.reloadData()
    }

    /// Whether a row shows the "changing right now" dot; also what the test reads.
    func isRecent(_ change: ActivityChange, now: Date = Date()) -> Bool {
        change.modified.map { now.timeIntervalSince($0) < ActivityViewController.recentSeconds } ?? false
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .file = rows[row] { return 22 }
        return 26
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .file = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let theme = Settings.shared.theme
        switch rows[row] {
        case .group(let title), .note(let title):
            // The title sits at the bottom of its row, so the space is above it, away from the group before.
            let identifier = NSUserInterfaceItemIdentifier("ActivityGroup")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                cell.identifier = identifier
                let label = NSTextField(labelWithString: "")
                label.lineBreakMode = .byTruncatingTail
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
                    label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3),
                ])
                return cell
            }()
            guard let label = cell.textField else { return cell }
            var isGroup = false
            if case .group = rows[row] { isGroup = true }
            label.font = isGroup ? .systemFont(ofSize: 10.5, weight: .semibold) : .systemFont(ofSize: 11)
            label.textColor = theme.lineNumber
            label.stringValue = isGroup ? title.uppercased() : title
            return cell
        case .file(let change):
            let identifier = NSUserInterfaceItemIdentifier("ActivityFile")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ActivityFileCell ?? {
                let cell = ActivityFileCell(frame: .zero)
                cell.identifier = identifier
                return cell
            }()
            let path = change.path as NSString
            let name = NSMutableAttributedString(attributedString: FileIcon.attributed(for: URL(fileURLWithPath: change.path)))
            let oneLine = NSMutableParagraphStyle()
            oneLine.lineBreakMode = .byTruncatingTail
            var nameAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: theme.foreground]
            if change.kind == .deleted {
                nameAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                nameAttributes[.foregroundColor] = theme.lineNumber
            }
            name.append(NSAttributedString(string: path.lastPathComponent, attributes: nameAttributes))
            let folder = path.deletingLastPathComponent
            if !folder.isEmpty {
                name.append(NSAttributedString(string: "  " + folder, attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: theme.lineNumber]))
            }
            name.addAttribute(.paragraphStyle, value: oneLine, range: NSRange(location: 0, length: name.length))
            cell.name.attributedStringValue = name
            cell.detail.attributedStringValue = detail(for: change, theme: theme)
            cell.dot.isHidden = !isRecent(change)
            cell.toolTip = tip(for: change)
            return cell
        }
    }

    private func detail(for change: ActivityChange, theme: Theme) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let text = NSMutableAttributedString()
        if change.isBinary {
            text.append(NSAttributedString(string: "not text", attributes: [.font: font, .foregroundColor: theme.lineNumber]))
        } else {
            if let added = change.insertions, added > 0 || change.deletions == 0 {
                text.append(NSAttributedString(string: "+\(added)", attributes: [.font: font, .foregroundColor: NSColor(hex: 0x3FB950)]))
            }
            if let removed = change.deletions, removed > 0 {
                text.append(NSAttributedString(string: (text.length > 0 ? " " : "") + "−\(removed)", attributes: [.font: font, .foregroundColor: NSColor(hex: 0xF14C4C)]))
            }
        }
        if let modified = change.modified {
            text.append(NSAttributedString(string: (text.length > 0 ? "  " : "") + Checkpoint.shortAge(of: modified),
                                           attributes: [.font: font, .foregroundColor: theme.lineNumber]))
        }
        return text
    }

    private func tip(for change: ActivityChange) -> String {
        var parts = [change.path]
        switch change.kind {
        case .changed: parts.append("Changed since the checkpoint.")
        case .created: parts.append("New: it did not exist at the checkpoint.")
        case .deleted: parts.append("Deleted: it existed at the checkpoint and is gone now.")
        }
        if let modified = change.modified { parts.append("Last changed " + Checkpoint.age(of: modified) + ".") }
        parts.append("Click to see what changed.")
        return parts.joined(separator: "\n")
    }

    // MARK: - Actions

    private func change(atRow row: Int) -> ActivityChange? {
        guard rows.indices.contains(row), case .file(let change) = rows[row] else { return nil }
        return change
    }

    @objc private func rowClicked() {
        guard let change = change(atRow: tableView.clickedRow) else { return }
        onShowChange?(change)
    }

    @objc private func pickerChanged() {
        guard let id = picker.selectedItem?.representedObject as? String, let checkpoint = checkpoints.first(where: { $0.id == id }) else { return }
        onPickCheckpoint?(checkpoint)
    }

    @objc private func newClicked() { onNewCheckpoint?() }

    @objc private func undoClicked() { onUndoAll?() }

    @objc private func reviewClicked() { onReview?() }

    @objc private func clearClicked() { onClear?() }

    @objc private func noticeClicked() { onNotice?() }

    @objc private func followClicked() { Settings.shared.followChanges = followBox.state == .on }

    @objc private func followChanged() { followBox.state = Settings.shared.followChanges ? .on : .off }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === picker.menu {
            // Ages in the list are as old as the last time it was built.
            for (item, checkpoint) in zip(menu.items, checkpoints) { item.title = checkpoint.name + "  ·  " + checkpoint.age }
            return
        }
        menu.removeAllItems()
        guard let change = change(atRow: tableView.clickedRow) else { return }
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = change.path
            menu.addItem(item)
        }
        add("See What Changed", #selector(menuShowChange(_:)))
        if change.kind != .deleted { add("Open File", #selector(menuOpenFile(_:))) }
        menu.addItem(.separator())
        switch change.kind {
        case .changed: add("Restore This File…", #selector(menuRestore(_:)))
        case .created: add("Move This New File to the Trash…", #selector(menuRestore(_:)))
        case .deleted: add("Bring This File Back…", #selector(menuRestore(_:)))
        }
    }

    private func change(from item: NSMenuItem) -> ActivityChange? {
        guard let path = item.representedObject as? String else { return nil }
        return snapshot?.changes.first { $0.path == path }
    }

    @objc private func menuShowChange(_ sender: NSMenuItem) { change(from: sender).map { onShowChange?($0) } }

    @objc private func menuOpenFile(_ sender: NSMenuItem) { change(from: sender).map { onOpenFile?($0) } }

    @objc private func menuRestore(_ sender: NSMenuItem) { change(from: sender).map { onRestoreFile?($0) } }
}
