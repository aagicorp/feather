import AppKit
import SwiftTerm

final class TerminalPaneController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate, NSSplitViewDelegate {
    var onClose: (() -> Void)?
    /// A ⌘-click on a path in any of the terminals: the file, and the one-based line and column if printed.
    var onOpenFile: ((URL, Int?, Int?) -> Void)?
    /// Nil until a folder is open; relative paths are then resolved against the shell's directory alone.
    var projectRoot: URL?

    private let header = TerminalHeaderView()
    let titleLabel = NSTextField(labelWithString: "TERMINAL")
    /// "▶ npm run build · 12 s", right of the title (TerminalStatus.swift).
    let strip = TerminalStatusStrip()
    /// Holds the terminals of a split group side by side; on its own, a terminal sits straight in `content`.
    private let groupSplit = TerminalGroupSplitView()
    /// Where each group's dividers were left, as fractions of the width, for as long as the window is open.
    private var groupSizes: [Int: [CGFloat]] = [:]
    /// The terminal takes the whole window (the window collapses the other panes); the button and the header's
    /// double-click ask for it, and the window says when it has happened so the button can show the way back.
    var onMaximizeRequested: (() -> Void)?
    var isMaximized = false { didSet { updateMaximizeButton() } }
    private var maximizeButton: NSButton?
    private let buttonStack = NSStackView()
    /// Where the terminal (or split group) in front sits, and the "Copied" note over it.
    let content = NSView()
    /// The list of terminals and its resize handle (TerminalPane+List.swift).
    let listScroll = NSScrollView()
    let listTable = NSTableView()
    let listDivider = ListResizeHandle()
    weak var headerKillButton: NSButton?
    var listWidth: NSLayoutConstraint!
    var listHeight: NSLayoutConstraint!
    private var wideConstraints: [NSLayoutConstraint] = []
    private var tallConstraints: [NSLayoutConstraint] = []
    /// Every terminal, in list order. Reordered only by `move(terminalAt:to:)` (TerminalPane+List.swift).
    var sessions: [TerminalSession] = []
    /// The terminal in front; -1 with none. Set by `select` and the list (TerminalPane+List.swift).
    var selectedIndex = -1
    private var workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    private var pollTimer: Timer?
    /// True while `reloadList` replaces the rows, so the selection it restores is not taken for a click.
    var isUpdatingList = false
    private static let listWidthRange: ClosedRange<CGFloat> = 90...420
    private static let listWidthKey = "terminalListWidth"
    /// The user's chosen width for the list; remembered between launches.
    var preferredListWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: TerminalPaneController.listWidthKey)
        return saved > 0 ? CGFloat(saved) : 190
    }()

    /// The terminal in front, for the parts of this controller that live in other files.
    var current: TerminalSession? { sessions.indices.contains(selectedIndex) ? sessions[selectedIndex] : nil }

    // Stored for the parts of this controller that live in other files, which cannot declare their own.
    /// The row the context menu was opened on, held for the submenus' actions (TerminalPane+List.swift).
    var menuRow = -1
    /// The field a name is being typed into, and whether the list changed meanwhile (TerminalPane+List.swift).
    var renameField: NSTextField?
    var needsReloadAfterRename = false
    /// The window shows the pane and comes forward; the pane has already selected the terminal.
    var onRevealRequested: (() -> Void)?
    /// The "Copied" note and the work that fades it (TerminalPane+Attention.swift).
    var copiedToast: NSTextField?
    var copiedWork: DispatchWorkItem?

    override func loadView() {
        let pane = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        pane.controller = self
        view = pane
        view.wantsLayer = true

        titleLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        // The header trash only appears while there is a single terminal (and so no list to carry per-row ones).
        for (symbol, tip, action) in [("plus", "New Terminal (⌃⇧`)", #selector(newTerminalClicked)),
                                      ("square.split.2x1", "Split Terminal (⌃⇧5)", #selector(splitClicked)),
                                      ("rectangle.righthalf.inset.filled", "Move Terminal to the Right", #selector(moveClicked)),
                                      ("arrow.up.left.and.arrow.down.right", "Maximize Terminal (⌃⇧M)", #selector(maximizeClicked)),
                                      ("trash", "Kill Terminal", #selector(killOnlyTerminal)),
                                      ("xmark", "Hide Terminal Panel (⌃`)", #selector(closeClicked))] {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!,
                                  target: self, action: action)
            button.isBordered = false
            button.toolTip = tip
            button.imageScaling = .scaleProportionallyDown
            button.widthAnchor.constraint(equalToConstant: 18).isActive = true
            buttonStack.addArrangedSubview(button)
            if symbol == "trash" { headerKillButton = button }
            if action == #selector(moveClicked) { moveButton = button; updateMoveButton() }
            if action == #selector(maximizeClicked) { maximizeButton = button }
        }
        header.onDoubleClick = { [weak self] in self?.onMaximizeRequested?() }
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        strip.input = { [weak self] in self?.statusInput() }
        strip.isOnScreen = { [weak self] in
            guard let self, self.isViewLoaded, let window = self.view.window else { return false }
            return window.isVisible && !self.view.isHiddenOrHasHiddenAncestor
        }
        groupSplit.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("terminal"))
        column.resizingMask = .autoresizingMask
        listTable.addTableColumn(column)
        listTable.headerView = nil
        listTable.rowHeight = 26
        listTable.style = .plain
        listTable.backgroundColor = .clear
        listTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        listTable.allowsEmptySelection = false
        listTable.dataSource = self
        listTable.delegate = self
        listTable.target = self
        listTable.doubleAction = #selector(renameClicked)
        listTable.registerForDraggedTypes([TerminalPaneController.rowType])
        listTable.draggingDestinationFeedbackStyle = .gap
        let menu = NSMenu()
        menu.delegate = self
        listTable.menu = menu
        listScroll.documentView = listTable
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false
        listScroll.useFeatherScrollers()
        listDivider.onDrag = { [weak self] delta in
            guard let self else { return }
            // Dragging left makes the list wider. Leave the terminal itself at least 200 points.
            let roomy = max(TerminalPaneController.listWidthRange.lowerBound, self.view.bounds.width - 200)
            let limit = min(TerminalPaneController.listWidthRange.upperBound, roomy)
            self.preferredListWidth = max(TerminalPaneController.listWidthRange.lowerBound, min(limit, self.preferredListWidth - delta))
            self.listWidth.constant = self.preferredListWidth
        }
        listDivider.onDragEnded = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(self.preferredListWidth), forKey: TerminalPaneController.listWidthKey)
        }

        for subview in [header, content, listDivider, listScroll] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        for subview in [titleLabel, strip.label, buttonStack] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(subview)
        }
        listWidth = listScroll.widthAnchor.constraint(equalToConstant: 0)
        listHeight = listScroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            strip.label.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 14),
            strip.label.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -10),
            strip.label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            buttonStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            listDivider.topAnchor.constraint(equalTo: header.bottomAnchor),
            listDivider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            listDivider.widthAnchor.constraint(equalToConstant: 7),          // a comfortable target; only 1pt is drawn
            listScroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            listScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        // Along the bottom of the window the list of terminals stands to the right of the terminal. In a tall
        // column on the right there is no width to spare, so the list lies across the top instead.
        wideConstraints = [
            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.trailingAnchor.constraint(equalTo: listDivider.leadingAnchor),
            listDivider.trailingAnchor.constraint(equalTo: listScroll.leadingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            listWidth,
        ]
        tallConstraints = [
            content.topAnchor.constraint(equalTo: listScroll.bottomAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            listScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            listDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),          // hidden, but still placed
            listHeight,
        ]
        NSLayoutConstraint.activate(isTall ? tallConstraints : wideConstraints)
        applySettings()
    }

    /// Set by the window when the pane moves between the bottom of the window and the column on the right.
    /// The header's "move" button: one click takes the terminal from the bottom to the side and back.
    var onMoveRequested: (() -> Void)?
    private var moveButton: NSButton?

    @objc private func moveClicked() { onMoveRequested?() }

    @objc private func maximizeClicked() { onMaximizeRequested?() }

    private func updateMaximizeButton() {
        let symbol = isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        let tip = isMaximized ? "Restore Terminal Size (⌃⇧M)" : "Maximize Terminal (⌃⇧M)"
        maximizeButton?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        maximizeButton?.toolTip = tip
    }

    private func updateMoveButton() {
        let symbol = isTall ? "rectangle.bottomhalf.inset.filled" : "rectangle.righthalf.inset.filled"
        let tip = isTall ? "Move Terminal to the Bottom" : "Move Terminal to the Right"
        moveButton?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        moveButton?.toolTip = tip
    }

    var isTall = false {
        didSet {
            updateMoveButton()
            guard isTall != oldValue, isViewLoaded else { return }
            NSLayoutConstraint.deactivate(isTall ? wideConstraints : tallConstraints)
            NSLayoutConstraint.activate(isTall ? tallConstraints : wideConstraints)
            reloadList()
        }
    }

    func applySettings() {
        guard isViewLoaded else { return }
        let theme = Settings.shared.theme
        view.layer?.backgroundColor = Glass.paneBackground(theme.background)      // the panel behind paints it with glass
        titleLabel.textColor = theme.lineNumber
        buttonStack.arrangedSubviews.forEach { ($0 as? NSButton)?.contentTintColor = theme.lineNumber }
        sessions.forEach { $0.applySettings() }
        groupSplit.needsDisplay = true
        reloadList()
    }

    // MARK: - Sessions

    /// Shells start lazily, the first time the pane is shown, so an unused terminal costs nothing.
    func startIfNeeded() {
        _ = view
        if sessions.isEmpty { addSession(taskTitle: nil) }
        startPolling()
    }

    /// `at` is where in the list the new terminal goes (the end unless it joins a group); `groupTag` the group.
    @discardableResult
    private func addSession(taskTitle: String?, at place: Int? = nil, groupTag: Int = 0) -> TerminalSession {
        let session = TerminalSession(taskTitle: taskTitle)
        session.groupTag = groupTag
        session.applySettings()
        session.view.projectRoot = projectRoot
        session.view.onOpenFile = { [weak self] in self?.onOpenFile?($0, $1, $2) }
        session.view.onCopied = { [weak self] in self?.showCopied($0) }
        session.view.onFocus = { [weak self, weak session] in
            guard let session else { return }
            self?.noteFocused(session)
        }
        session.onStatusChange = { [weak self, weak session] in
            guard let self, let session, session === self.current else { return }
            self.strip.refresh()
        }
        session.onWorkStarted = { [weak self, weak session] in
            guard let self, let session, session.isAssistant, let window = self.view.window else { return }
            NotificationCenter.default.post(name: .assistantDidStartWorking, object: self, userInfo: ["window": window])
        }
        session.onExit = { [weak self] in self?.sessionExited($0) }
        session.onChange = { [weak self, weak session] in
            guard let self, let session, let row = self.sessions.firstIndex(where: { $0 === session }), self.isViewLoaded else { return }
            if session === self.current { self.updateHeaderTitle() }
            // Only this terminal's name changed; and with a single terminal no list is showing at all.
            guard self.sessions.count > 1 else { return }
            if self.renameField != nil { self.needsReloadAfterRename = true; return }
            self.listTable.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }
        session.onWaiting = { [weak self] in self?.sessionIsWaiting($0, reason: $1) }
        session.start(in: workingDirectory)
        let index = min(max(0, place ?? sessions.count), sessions.count)
        sessions.insert(session, at: index)
        select(index)
        startPolling()
        return session
    }

    // MARK: - Split groups (TerminalGroups.swift)

    /// Each terminal's group tag, in list order.
    var tags: [Int] { sessions.map(\.groupTag) }

    /// The terminals shown beside `session`, itself included; just `session` when it is on its own.
    private func members(of session: TerminalSession) -> [TerminalSession] {
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return [session] }
        return TerminalGroups.members(of: index, tags: tags).map { sessions[$0] }
    }

    /// The terminals on screen: the group of the one in front.
    var visibleSessions: [TerminalSession] { current.map(members(of:)) ?? [] }

    /// Split Terminal: a new shell beside the one in front, in its group. With no terminal yet, just a shell.
    func splitTerminal() {
        _ = view
        guard let current, let index = sessions.firstIndex(where: { $0 === current }) else { return newTerminal() }
        split(at: index)
    }

    /// A new shell beside the terminal at `index`. Run tasks keep their own terminal, and a group holds at most
    /// `TerminalGroups.maxMembers`.
    func split(at index: Int) {
        guard sessions.indices.contains(index), !sessions[index].isTask else { return NSSound.beep() }
        let run = TerminalGroups.members(of: index, tags: tags)
        guard run.count < TerminalGroups.maxMembers else { return NSSound.beep() }
        var tag = sessions[index].groupTag
        if tag == 0 {
            tag = TerminalGroups.freshTag(tags)
            sessions[index].groupTag = tag
        }
        groupSizes[tag] = nil                 // one more column: the old positions mean nothing now
        addSession(taskTitle: nil, at: run.upperBound, groupTag: tag)
        focus()
    }

    /// Groups of one are plain terminals again; called after a member is gone.
    private func normaliseTags() {
        for (session, tag) in zip(sessions, TerminalGroups.normalised(tags)) { session.groupTag = tag }
    }

    /// Puts the group of `session` (or `session` alone) into the content area, unless it is there already.
    private func showGroup(of session: TerminalSession) {
        let views = members(of: session).map(\.view)
        let shown = groupSplit.superview === content ? groupSplit.arrangedSubviews : content.subviews.filter { $0 is DropTerminalView }
        if shown.count == views.count, zip(shown, views).allSatisfy({ $0 === $1 }) { return }
        // What is there comes down: the terminals and the split view, not the "Copied" note.
        for view in groupSplit.arrangedSubviews {
            groupSplit.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        content.subviews.filter { $0 is DropTerminalView || $0 === groupSplit }.forEach { $0.removeFromSuperview() }
        if views.count == 1, let terminal = views.first {
            terminal.frame = content.bounds
            terminal.autoresizingMask = [.width, .height]
            content.addSubview(terminal, positioned: .below, relativeTo: nil)
            return
        }
        for view in views {
            view.autoresizingMask = []
            groupSplit.addArrangedSubview(view)
        }
        groupSplit.frame = content.bounds
        groupSplit.autoresizingMask = [.width, .height]
        let saved = groupSizes[session.groupTag]
        groupSplit.pendingFractions = saved?.count == views.count ? saved : Array(repeating: 1 / CGFloat(views.count), count: views.count)
        content.addSubview(groupSplit, positioned: .below, relativeTo: nil)
    }

    /// A terminal in the group on screen took the keyboard: it is the one in front now.
    private func noteFocused(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0 === session }), index != selectedIndex,
              visibleSessions.contains(where: { $0 === session }) else { return }
        selectedIndex = index
        reloadList()
        clearAttentionIfSeen()
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard groupSplit.superview != nil, groupSplit.bounds.width > 0, let tag = current?.groupTag, tag != 0 else { return }
        groupSizes[tag] = groupSplit.fractions
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, CGFloat(dividerIndex + 1) * TerminalGroupSplitView.minimumColumn)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - CGFloat(splitView.arrangedSubviews.count - dividerIndex - 1) * TerminalGroupSplitView.minimumColumn)
    }

    @objc private func splitClicked() { splitTerminal() }

    /// Split Terminal in the list's context menu (TerminalPane+List.swift).
    @objc func splitClickedRow() { split(at: targetRow) }

    /// Ordinary shells only; a Run task is not something to restart behind the user's back.
    var shellCount: Int { sessions.filter { !$0.isTask }.count }

    /// What the session remembers about each shell, in order: the name, colour and icon the user gave it, and
    /// which split group it belongs to ("group": a number shared by the members).
    var shellDescriptors: [[String: String]] {
        let shells = sessions.filter { !$0.isTask }
        let groups = TerminalGroups.groupIndices(forTags: shells.map(\.groupTag))
        return zip(shells, groups).map { session, group in
            var descriptor: [String: String] = [:]
            if let name = session.customName { descriptor["name"] = name }
            if let color = session.customColor { descriptor["color"] = color.hexString }
            if let icon = session.customIcon { descriptor["icon"] = icon }
            if let group { descriptor["group"] = String(group) }
            return descriptor
        }
    }

    /// Opens a shell per descriptor, with its name, colour and icon, split as they were. Nothing of the previous
    /// session's output or scrollback is kept.
    func restoreShells(_ descriptors: [[String: String]]) {
        _ = view
        let wanted = Array(descriptors.prefix(12).dropFirst(shellCount))
        let base = TerminalGroups.freshTag(tags) - 1
        let restoredTags = TerminalGroups.tags(forGroupIndices: wanted.map { $0["group"].flatMap { Int($0) } })
        for (descriptor, tag) in zip(wanted, restoredTags) {
            let session = addSession(taskTitle: nil, groupTag: tag == 0 ? 0 : tag + base)
            if let name = descriptor["name"], !name.isEmpty { session.customName = name }
            if let hex = descriptor["color"] { session.customColor = NSColor(hexString: hex) }
            if let icon = descriptor["icon"], !icon.isEmpty { session.customIcon = icon }
        }
        if !sessions.isEmpty { select(0) }
        startPolling()
    }

    func newTerminal() {
        _ = view
        addSession(taskTitle: nil)
        focus()
    }

    /// Runs `command` in a terminal named `title`, reusing (and interrupting) that terminal if it already exists.
    /// Types `text` into the terminal that is showing, starting a shell first if there is none. False when no
    /// shell could be started.
    @discardableResult
    func sendText(_ text: String) -> Bool {
        startIfNeeded()
        guard let current else { return false }
        current.send(text)
        return true
    }

    func runTask(title: String, command: String) {
        _ = view
        if let index = sessions.firstIndex(where: { $0.taskTitle == title && $0.isRunning }) {
            select(index)
            let session = sessions[index]
            session.interrupt()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { session.send(" clear; " + command + "\n") }
        } else {
            sessions.removeAll { $0.taskTitle == title && !$0.isRunning }
            addSession(taskTitle: title).sendWhenShellIsReady(" " + command + "\n")
        }
        focus()
    }

    /// Sends Ctrl-C to the task terminals; returns false when there was nothing to stop.
    @discardableResult
    func stopTasks() -> Bool {
        let running = sessions.filter { $0.isTask && $0.isRunning }
        running.forEach { $0.interrupt() }
        return !running.isEmpty
    }

    private func sessionExited(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return }
        if session.isTask {
            let code = session.lastExitCode
            let outcome = code.map { $0 == 0 ? "finished" : "failed (exit code \($0))" } ?? "finished"
            session.view.feed(text: "\r\n[\(outcome) — run again with ⌘R]\r\n")
            reloadList()
            taskEnded(session, outcome: outcome, failed: (code ?? 0) != 0)
            return
        }
        remove(at: index)
    }

    /// Kills the terminal at `index` and takes it out of the list.
    func remove(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        TerminalAttention.shared.lower(token: sessions[index].token)
        sessions[index].shutDown()
        let view = sessions[index].view
        if view.superview === groupSplit { groupSplit.removeArrangedSubview(view) }
        view.removeFromSuperview()
        sessions.remove(at: index)
        normaliseTags()
        if sessions.isEmpty {
            selectedIndex = -1
            reloadList()
            onClose?()
        } else {
            select(min(index, sessions.count - 1))
            focus()
        }
    }

    /// Brings the terminal at `index` (and its group) to the front.
    func select(_ index: Int) {
        guard sessions.indices.contains(index) else { return }
        selectedIndex = index
        showGroup(of: sessions[index])
        refreshListRows()               // in place: a click on a row may be the start of a drag
        clearAttentionIfSeen()
    }

    func selectAdjacent(_ delta: Int) {
        guard sessions.count > 1 else { return }
        select((selectedIndex + delta + sessions.count) % sessions.count)
        focus()
    }

    // MARK: - Live names

    /// Names follow whatever is running, so the list is only polled while the pane is on screen.
    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            // The header shows the branch of the terminal in front, the list the name of each; both need a visible pane.
            if self.view.window == nil || self.view.isHiddenOrHasHiddenAncestor || self.sessions.isEmpty { return }
            self.sessions.forEach { $0.refreshProcessInfo() }
            self.strip.refresh()
        }
        pollTimer?.tolerance = 0.5            // lets the system batch this wake-up with others
    }

    // MARK: - AI assistant

    /// The terminal an assistant is running in: the one showing if it is one, otherwise the most recent.
    /// Asks the system what is in the foreground of each terminal first, so a tool started by hand counts.
    func assistantSession() -> TerminalSession? {
        sessions.forEach { $0.refreshProcessInfo() }
        if let current, current.isAssistant { return current }
        return sessions.last { $0.isAssistant }
    }

    /// Opens a terminal named after the tool and types its command. A terminal whose assistant has quit is
    /// used again rather than left behind as a stray shell.
    func startAssistant(name: String, command: String) {
        _ = view
        sessions.forEach { $0.refreshProcessInfo() }
        let session: TerminalSession
        if let idle = sessions.first(where: { $0.aiToolName == name && $0.isRunning && $0.isAtShellPrompt && !$0.isAssistant }),
           let index = sessions.firstIndex(where: { $0 === idle }) {
            session = idle
            select(index)
        } else {
            session = addSession(taskTitle: nil)
            session.aiToolName = name
            session.customName = name
        }
        session.assistantStartedAt = CFAbsoluteTimeGetCurrent()
        session.sendWhenShellIsReady(" " + command + "\n")
        reloadList()
        focus()
    }

    /// Types `text` at the assistant's prompt without entering it. False when no assistant is running.
    @discardableResult
    func sendToAssistant(_ text: String) -> Bool {
        guard let session = assistantSession(), let index = sessions.firstIndex(where: { $0 === session }) else { return false }
        select(index)
        session.send(text)
        focus()
        return true
    }

    // MARK: - Misc

    func setDirectory(_ url: URL) {
        workingDirectory = url.path
        projectRoot = url.standardizedFileURL
        sessions.forEach { $0.view.projectRoot = projectRoot }
        let quoted = TerminalPaneController.quote(url.path)
        sessions.filter { !$0.isTask }.forEach { $0.send(" cd \(quoted) && clear\n", countsAsCommand: false) }
    }

    static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func shutDown() {
        pollTimer?.invalidate()
        pollTimer = nil
        sessions.forEach { TerminalAttention.shared.lower(token: $0.token) }
        sessions.forEach { $0.shutDown() }
    }

    func focus() {
        guard let current else { return }
        view.window?.makeFirstResponder(current.view)
        clearAttentionIfSeen()
    }

    /// The header's plus button, and New Terminal in the list's context menu (TerminalPane+List.swift).
    @objc func newTerminalClicked() { newTerminal() }

    @objc private func killOnlyTerminal() {
        if sessions.count == 1 { remove(at: 0) }
    }

    @objc private func closeClicked() { onClose?() }
}
