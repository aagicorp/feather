import AppKit

struct GitRef {
    enum Kind { case head, local, remote, tag }
    let name: String
    let kind: Kind
}

final class GitCommit {
    let hash: String
    let parents: [String]
    let author: String
    let date: Date
    let refs: [GitRef]
    let subject: String

    // Graph layout, filled in by GitGraphLayout.
    var lane = 0
    /// Lanes that are occupied on the row's top edge; `true` means the line bends into this commit's dot.
    var incoming: [(lane: Int, joins: Bool)] = []
    /// Lanes that simply continue through the bottom half of the row.
    var passing: [Int] = []
    /// Lanes this commit's parents continue in, drawn from the dot to the bottom edge.
    var parentLanes: [Int] = []
    /// How many lanes this row draws in (its own dot, lines passing through, lines arriving or leaving), so the
    /// text can start right after them instead of after the widest point of the whole history.
    var laneCount: Int {
        let lanes = [lane] + incoming.map(\.lane) + passing + parentLanes
        return (lanes.max() ?? 0) + 1
    }

    init(hash: String, parents: [String], author: String, date: Date, refs: [GitRef], subject: String) {
        self.hash = hash
        self.parents = parents
        self.author = author
        self.date = date
        self.refs = refs
        self.subject = subject
    }

    var shortHash: String { String(hash.prefix(7)) }
    var isMerge: Bool { parents.count > 1 }
}

enum GitGraphLayout {
    static let separator = "\u{1f}"
    static let format = ["%H", "%P", "%an", "%at", "%D", "%s"].joined(separator: "%x1f")

    static func parse(_ output: String) -> [GitCommit] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: separator)
            guard fields.count >= 6 else { return nil }
            return GitCommit(hash: fields[0],
                             parents: fields[1].split(separator: " ").map(String.init),
                             author: fields[2],
                             date: Date(timeIntervalSince1970: TimeInterval(fields[3]) ?? 0),
                             refs: parseRefs(fields[4]),
                             subject: fields[5...].joined(separator: separator))
        }
    }

    /// Full ref names ("HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1.0"), because a
    /// short name cannot tell the local branch "feature/login" from the remote branch "origin/login".
    private static func parseRefs(_ decoration: String) -> [GitRef] {
        decoration.components(separatedBy: ", ").compactMap { raw in
            var text = raw.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasSuffix("/HEAD") { return nil }
            if text == "HEAD" { return GitRef(name: "HEAD", kind: .head) }
            let isHead = text.hasPrefix("HEAD -> ")
            if isHead { text = String(text.dropFirst(8)) }
            if text.hasPrefix("tag: ") { text = String(text.dropFirst(5)) }
            for (prefix, kind) in [("refs/heads/", GitRef.Kind.local), ("refs/remotes/", .remote), ("refs/tags/", .tag)]
            where text.hasPrefix(prefix) {
                return GitRef(name: String(text.dropFirst(prefix.count)), kind: isHead ? .head : kind)
            }
            return nil      // stashes and other refs are not shown
        }
    }

    /// Assigns each commit a lane. `lanes[i]` holds the hash that lane is waiting for next;
    /// commits must arrive children-before-parents, which `git log` guarantees.
    static func assignLanes(_ commits: [GitCommit]) -> Int {
        var lanes: [String?] = []
        var laneOf: [String: Int] = [:]           // hash a lane is waiting for -> that lane (at most one each)
        var widest = 1
        func freeLane() -> Int {
            if let index = lanes.firstIndex(where: { $0 == nil }) { return index }
            lanes.append(nil)
            return lanes.count - 1
        }
        for commit in commits {
            let lane = laneOf[commit.hash] ?? freeLane()
            commit.lane = lane
            commit.incoming = lanes.enumerated().compactMap { index, expected in
                expected == nil ? nil : (index, expected == commit.hash)
            }
            // Every lane that was waiting for this commit ends here.
            if let waiting = laneOf.removeValue(forKey: commit.hash) { lanes[waiting] = nil }
            commit.passing = lanes.indices.filter { lanes[$0] != nil }

            for (position, parent) in commit.parents.enumerated() {
                if let existing = laneOf[parent] {
                    commit.parentLanes.append(existing)          // another child already reserved a lane for it
                } else {
                    let target = position == 0 ? lane : freeLane()
                    lanes[target] = parent
                    laneOf[parent] = target
                    commit.parentLanes.append(target)
                }
            }
            while let last = lanes.last, last == nil { lanes.removeLast() }
            widest = max(widest, lanes.count, lane + 1)
        }
        return widest
    }
}

/// Branch and tag names drawn as rounded capsules, cached per name.
enum RefPill {
    private static var cache: [String: NSImage] = [:]

    static func color(_ kind: GitRef.Kind) -> NSColor {
        switch kind {
        case .head: return NSColor(hex: 0x2EA043)
        case .local: return NSColor(hex: 0x1F6FEB)
        case .remote: return NSColor(hex: 0x6E5494)
        case .tag: return NSColor(hex: 0x9E6A03)
        }
    }

    static func image(_ title: String, color: NSColor, fontSize: CGFloat) -> NSImage {
        let key = "\(title)|\(color.hashValue)|\(fontSize)"
        if let cached = cache[key] { return cached }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: NSColor.white,
        ]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let size = NSSize(width: ceil(textSize.width) + 14, height: ceil(textSize.height) + 3)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            (title as NSString).draw(at: NSPoint(x: 7, y: 1.5), withAttributes: attributes)
            return true
        }
        if cache.count > 400 { cache.removeAll() }
        cache[key] = image
        return image
    }

    /// At most `limit` pills; the rest collapse into a "+2" pill so a busy commit cannot crowd out its message.
    static func attributed(_ refs: [GitRef], fontSize: CGFloat, limit: Int = 4, maxNameLength: Int = 40,
                           trailingSpace: Bool = true) -> NSAttributedString {
        let text = NSMutableAttributedString()
        // When space is short, the branch you are on matters most, then local branches, remotes, tags.
        let order: [GitRef.Kind] = [.head, .local, .remote, .tag]
        let refs = refs.enumerated().sorted {
            let a = order.firstIndex(of: $0.element.kind) ?? 9, b = order.firstIndex(of: $1.element.kind) ?? 9
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        var pills = refs.prefix(limit).map { ref -> NSImage in
            let prefix = ref.kind == .head ? "◎ " : ref.kind == .tag ? "◆ " : ""
            var name = ref.name
            if name.count > maxNameLength {     // keep both ends: "feature/ar…ap-v2"
                let keep = (maxNameLength - 1) / 2
                name = name.prefix(keep) + "…" + name.suffix(keep)
            }
            return image(prefix + name, color: color(ref.kind), fontSize: fontSize)
        }
        if refs.count > limit { pills.append(image("+\(refs.count - limit)", color: NSColor(hex: 0x57606A), fontSize: fontSize)) }
        for pill in pills {
            let attachment = NSTextAttachment()
            attachment.image = pill
            attachment.bounds = NSRect(x: 0, y: -4, width: pill.size.width, height: pill.size.height)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " "))
        }
        if !pills.isEmpty && trailingSpace { text.append(NSAttributedString(string: " ")) }
        return text
    }
}

final class GraphCellView: NSView {
    static let laneWidth: CGFloat = 12
    static let colors: [NSColor] = [0x3B8EEA, 0x3FB950, 0xE5C07B, 0xC678DD, 0xF14C4C, 0x56B6C2, 0xEE9D28, 0xD16D9E].map {
        NSColor(hex: UInt32($0))
    }
    var commit: GitCommit? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    private func x(_ lane: Int) -> CGFloat { CGFloat(lane) * GraphCellView.laneWidth + 9 }

    private func color(_ lane: Int) -> NSColor { GraphCellView.colors[lane % GraphCellView.colors.count] }

    override func draw(_ dirtyRect: NSRect) {
        guard let commit else { return }
        let top: CGFloat = -1, middle = bounds.midY, bottom = bounds.height + 1
        let dot = NSPoint(x: x(commit.lane), y: middle)

        func stroke(from start: NSPoint, to end: NSPoint, lane: Int) {
            let path = NSBezierPath()
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.move(to: start)
            if start.x == end.x {
                path.line(to: end)
            } else {
                // Leave and arrive vertically so neighbouring rows join without a kink.
                path.curve(to: end, controlPoint1: NSPoint(x: start.x, y: (start.y + end.y) / 2),
                           controlPoint2: NSPoint(x: end.x, y: (start.y + end.y) / 2))
            }
            color(lane).setStroke()
            path.stroke()
        }

        for entry in commit.incoming {
            let start = NSPoint(x: x(entry.lane), y: top)
            stroke(from: start, to: entry.joins ? dot : NSPoint(x: x(entry.lane), y: middle), lane: entry.lane)
        }
        for lane in commit.passing {
            stroke(from: NSPoint(x: x(lane), y: middle), to: NSPoint(x: x(lane), y: bottom), lane: lane)
        }
        for lane in commit.parentLanes {
            stroke(from: dot, to: NSPoint(x: x(lane), y: bottom), lane: lane)
        }

        let isHead = commit.refs.contains { $0.kind == .head }
        let radius: CGFloat = isHead ? 4.5 : commit.isMerge ? 3 : 3.5
        let circle = NSBezierPath(ovalIn: NSRect(x: dot.x - radius, y: dot.y - radius, width: radius * 2, height: radius * 2))
        (commit.isMerge || isHead ? Settings.shared.theme.background : color(commit.lane)).setFill()
        circle.fill()
        color(commit.lane).setStroke()
        circle.lineWidth = isHead ? 2.2 : 1.6
        circle.stroke()
    }
}

final class GitGraphWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    /// Called after an action that changed the repository (checkout, merge, …).
    var onRepositoryChanged: (() -> Void)?

    let root: URL
    private var pendingSelection: String?
    private var reloadGeneration = 0
    private var lastLogOutput: String?
    private var detailWork: DispatchWorkItem?
    private let tableView = NSTableView()
    private let detail = NSTextView()
    private let allBranches = NSButton(checkboxWithTitle: "All branches", target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")
    private var actionButtons: [NSButton] = []
    private var commits: [GitCommit] = []
    private var currentBranch: String?
    private static let limit = 3000
    private let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    init(root: URL) {
        self.root = root
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "Git Graph — \(root.lastPathComponent)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 360)
        super.init(window: window)
        buildUI()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        let theme = Settings.shared.theme
        content.layer?.backgroundColor = theme.chrome.cgColor
        window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window?.backgroundColor = theme.chrome

        for (id, title, width) in [("graph", "Graph", 120.0), ("subject", "Description", 480.0), ("author", "Author", 130.0),
                                  ("date", "Date", 90.0), ("hash", "Commit", 70.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "graph" ? 40 : 50
            tableView.addTableColumn(column)
        }
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 6, height: 0)     // no vertical gap, so lanes join up
        tableView.style = .plain
        tableView.backgroundColor = theme.background
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false

        let tableScroll = NSScrollView()
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.autohidesScrollers = true

        detail.isEditable = false
        detail.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        detail.textColor = theme.foreground
        detail.backgroundColor = theme.background
        detail.textContainerInset = NSSize(width: 8, height: 8)
        detail.autoresizingMask = [.width]
        let detailScroll = NSScrollView()
        detailScroll.documentView = detail
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true

        allBranches.state = .on
        allBranches.target = self
        allBranches.action = #selector(reload)       // a different command, so its output always differs
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = theme.lineNumber
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(reload))
        refresh.bezelStyle = .rounded
        refresh.controlSize = .small

        let actions: [(String, Selector)] = [("Checkout", #selector(checkoutCommit)), ("New Branch Here…", #selector(branchHere)),
                                             ("Merge into Current", #selector(mergeCommit)), ("Cherry-Pick", #selector(cherryPick)),
                                             ("Copy Hash", #selector(copyHash))]
        let menu = NSMenu()
        actionButtons = actions.map { title, action in
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.isEnabled = false
            return button
        }
        tableView.menu = menu

        let toolbar = NSStackView(views: [allBranches, refresh, summary])
        toolbar.spacing = 12
        let actionBar = NSStackView(views: actionButtons)
        actionBar.spacing = 8

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(tableScroll)
        split.addArrangedSubview(detailScroll)

        for view in [toolbar, split, actionBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            // Without fixed heights the bars stretch and squeeze the commit table down to nothing.
            toolbar.heightAnchor.constraint(equalToConstant: 24),
            actionBar.heightAnchor.constraint(equalToConstant: 24),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            split.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: -8),
            actionBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            actionBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        content.applyFeatherScrollers()
        DispatchQueue.main.async { split.setPosition(max(200, split.bounds.height - 190), ofDividerAt: 0) }
    }

    override func showWindow(_ sender: Any?) {
        let wasVisible = window?.isVisible == true
        super.showWindow(sender)
        if !wasVisible || commits.isEmpty { reload() }        // bringing an open window forward does not re-run git
    }

    /// Selects a commit, now or as soon as the log has loaded.
    func select(hash: String) {
        pendingSelection = hash
        if let row = commits.firstIndex(where: { $0.hash == hash }) {
            pendingSelection = nil
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
    }

    @objc func reload() {
        var arguments = ["log", "--date-order", "--decorate=full", "--format=" + GitGraphLayout.format, "-n", "\(GitGraphWindowController.limit)"]
        if allBranches.state == .on { arguments.insert("--all", at: 1) }
        let selected = selectedCommit?.hash
        reloadGeneration += 1
        let generation = reloadGeneration
        let previousOutput = lastLogOutput
        Git.branch(in: root) { [weak self] in self?.currentBranch = $0 }
        // Parsing thousands of commits and laying out their lanes happens on the background thread.
        Git.run(arguments, in: root, transform: { result -> (GitResult, [GitCommit], Int)? in
            if result.ok, result.output == previousOutput { return nil }          // history is unchanged
            let commits = result.ok ? GitGraphLayout.parse(result.output) : []
            return (result, commits, GitGraphLayout.assignLanes(commits))
        }) { [weak self] loaded in
            guard let self, self.reloadGeneration == generation, let (result, commits, lanes) = loaded else { return }
            self.lastLogOutput = result.ok ? result.output : nil
            self.commits = commits
            self.tableView.tableColumns[0].width = min(260, CGFloat(lanes) * GraphCellView.laneWidth + 16)
            self.tableView.reloadData()
            self.summary.stringValue = commits.isEmpty ? (result.ok ? "No commits yet" : result.message)
                : "\(commits.count)\(commits.count >= GitGraphWindowController.limit ? "+" : "") commits"
            if let wanted = self.pendingSelection ?? selected, let row = commits.firstIndex(where: { $0.hash == wanted }) {
                self.pendingSelection = nil
                self.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                self.tableView.scrollRowToVisible(row)
            }
            self.selectionChanged()
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { commits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let commit = commits[row]
        if column.identifier.rawValue == "graph" {
            let id = NSUserInterfaceItemIdentifier("GraphCell")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? GraphCellView ?? {
                let cell = GraphCellView()
                cell.identifier = id
                return cell
            }()
            cell.commit = commit
            return cell
        }
        // A cell view centres its label in the row, which keeps the text level with the graph dots.
        let id = NSUserInterfaceItemIdentifier("TextCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        guard let label = cell.textField else { return cell }
        let theme = Settings.shared.theme
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: theme.lineNumber]
        switch column.identifier.rawValue {
        case "subject": label.attributedStringValue = describe(commit, theme: theme)
        case "author": label.attributedStringValue = NSAttributedString(string: commit.author, attributes: dim)
        case "date":
            label.attributedStringValue = NSAttributedString(
                string: dateFormatter.localizedString(for: commit.date, relativeTo: Date()), attributes: dim)
        default:
            label.attributedStringValue = NSAttributedString(
                string: commit.shortHash,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: theme.lineNumber])
        }
        return cell
    }

    private func describe(_ commit: GitCommit, theme: Theme) -> NSAttributedString {
        GitGraphLayout.describe(commit, theme: theme)
    }
}

extension GitGraphLayout {
    /// Branch and tag names as coloured pills, then the commit subject.
    static func describe(_ commit: GitCommit, theme: Theme, fontSize: CGFloat = 12) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: RefPill.attributed(commit.refs, fontSize: fontSize - 1.5))
        let isHead = commit.refs.contains { $0.kind == .head }
        text.append(NSAttributedString(string: commit.subject, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: isHead ? .semibold : .regular),
            .foregroundColor: theme.foreground,
        ]))
        return text
    }
}

extension GitGraphWindowController {

    func tableViewSelectionDidChange(_ notification: Notification) { selectionChanged() }

    private var selectedCommit: GitCommit? {
        commits.indices.contains(tableView.selectedRow) ? commits[tableView.selectedRow] : nil
    }

    private var clickedOrSelectedCommit: GitCommit? {
        commits.indices.contains(tableView.clickedRow) ? commits[tableView.clickedRow] : selectedCommit
    }

    private func selectionChanged() {
        let commit = selectedCommit
        actionButtons.forEach { $0.isEnabled = commit != nil }
        detailWork?.cancel()
        guard let commit else { detail.string = ""; return }
        // Holding an arrow key walks many rows; only the one you stop on asks git for its details.
        let work = DispatchWorkItem { [weak self] in self?.loadDetail(for: commit) }
        detailWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func loadDetail(for commit: GitCommit) {
        Git.run(["show", "--stat=100", "--format=commit %H%nAuthor: %an <%ae>%nDate:   %ad%n%n%B", "--date=format:%a %d %b %Y, %H:%M",
                 commit.hash], in: root) { [weak self] result in
            guard self?.selectedCommit?.hash == commit.hash else { return }
            self?.detail.string = result.ok ? result.output : result.message
        }
    }

    // MARK: - Actions

    private func perform(_ arguments: [String], describing action: String) {
        Git.run(arguments, in: root) { [weak self] result in
            guard let self else { return }
            if !result.ok {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "\(action) failed"
                alert.informativeText = result.message
                alert.runModal()
            }
            self.reload()
            self.onRepositoryChanged?()
        }
    }

    @objc private func checkoutCommit() {
        guard let commit = clickedOrSelectedCommit else { return }
        if let branch = commit.refs.first(where: { $0.kind == .local })?.name {
            perform(["checkout", branch], describing: "Checkout")
        } else if let remote = commit.refs.first(where: { $0.kind == .remote })?.name {
            perform(["checkout", "--track", remote], describing: "Checkout")
        } else if commit.refs.contains(where: { $0.kind == .head }) {
            NSSound.beep()      // already here
        } else {
            let alert = NSAlert()
            alert.messageText = "Check out commit \(commit.shortHash)?"
            alert.informativeText = "No branch points at this commit, so you would be in “detached HEAD” state. To keep new work from here, use “New Branch Here…” instead."
            alert.addButton(withTitle: "Check Out Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            perform(["checkout", commit.hash], describing: "Checkout")
        }
    }

    @objc private func branchHere() {
        guard let commit = clickedOrSelectedCommit else { return }
        let alert = NSAlert()
        alert.messageText = "New branch at \(commit.shortHash)"
        alert.addButton(withTitle: "Create and Switch")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "feature/my-branch"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let entered = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !entered.isEmpty else { return }
        perform(["checkout", "-b", entered, commit.hash], describing: "Create branch")
    }

    @objc private func mergeCommit() {
        guard let commit = clickedOrSelectedCommit else { return }
        let target = commit.refs.first { $0.kind == .local || $0.kind == .remote }?.name ?? commit.hash
        let alert = NSAlert()
        alert.messageText = "Merge “\(commit.refs.isEmpty ? commit.shortHash : target)” into “\(currentBranch ?? "HEAD")”?"
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform(["merge", "--no-edit", target], describing: "Merge")
    }

    @objc private func cherryPick() {
        guard let commit = clickedOrSelectedCommit else { return }
        perform(["cherry-pick", commit.hash], describing: "Cherry-pick")
    }

    @objc private func copyHash() {
        guard let commit = clickedOrSelectedCommit else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commit.hash, forType: .string)
    }
}

/// A sidebar row: the message takes the space, the branch pills sit at the right edge.
/// One row of the compact graph: the lanes on the left and the message right after them. Rows are ragged on
/// purpose, as in VS Code's Git Graph: a commit on the first lane starts its text near the edge, a row that
/// three branches pass through starts further right.
private final class CompactCommitCell: NSTableCellView {
    let graph = GraphCellView()
    let subject = NSTextField(labelWithString: "")
    let pills = NSTextField(labelWithString: "")
    private var textStart: NSLayoutConstraint!

    /// The graph is drawn under the text across the whole row; only where the text begins changes per commit.
    func show(_ commit: GitCommit) {
        graph.commit = commit
        textStart.constant = CGFloat(commit.laneCount) * GraphCellView.laneWidth + 8
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        graph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(graph)
        textStart = subject.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20)
        NSLayoutConstraint.activate([
            graph.topAnchor.constraint(equalTo: topAnchor), graph.bottomAnchor.constraint(equalTo: bottomAnchor),
            graph.leadingAnchor.constraint(equalTo: leadingAnchor), graph.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        subject.lineBreakMode = .byTruncatingTail
        subject.usesSingleLineMode = true
        subject.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subject.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pills.usesSingleLineMode = true
        pills.lineBreakMode = .byClipping
        pills.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        pills.setContentHuggingPriority(.required, for: .horizontal)
        for view in [subject, pills] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            textStart,
            subject.centerYAnchor.constraint(equalTo: centerYAnchor),
            pills.leadingAnchor.constraint(greaterThanOrEqualTo: subject.trailingAnchor, constant: 6),
            pills.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            pills.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Pills may take at most about half the row; beyond that the message wins.
            pills.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.62),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// The commit tree shown inside the Source Control pane: lanes plus one line per commit.
final class CompactGraphView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// Double-clicking a commit asks for the full graph window, focused on that commit.
    var onOpenCommit: ((String) -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let placeholder = NSTextField(labelWithString: "")
    private var commits: [GitCommit] = []
    private var root: URL?
    private var generation = 0
    private var lastOutput: String?
    private static let limit = 400

    // Hover card
    private var hoverRow = -1
    private var hoverWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var popover: NSPopover?
    private var popoverRow = -1
    private var pointerInsideCard = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        // One column: the lanes and the message share a row, so the message can start where that row's lanes end.
        let subject = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("subject"))
        subject.resizingMask = .autoresizingMask
        tableView.addTableColumn(subject)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openCommit)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        placeholder.font = .systemFont(ofSize: 11)
        placeholder.alignment = .center
        for view in [scrollView, placeholder] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.topAnchor.constraint(equalTo: topAnchor, constant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    func load(root: URL?) {
        if root != self.root { dismissCard(); lastOutput = nil }
        self.root = root
        generation += 1
        let current = generation
        guard let root else {
            commits = []
            tableView.reloadData()
            return
        }
        let arguments = ["log", "--all", "--date-order", "--decorate=full", "--format=" + GitGraphLayout.format,
                         "-n", "\(CompactGraphView.limit)"]
        let previousOutput = lastOutput
        Git.run(arguments, in: root, transform: { result -> (String, [GitCommit], Int)? in
            guard result.ok else { return ("", [], 1) }
            if result.output == previousOutput { return nil }                  // nothing new: skip parsing and reloading
            let commits = GitGraphLayout.parse(result.output)
            return (result.output, commits, GitGraphLayout.assignLanes(commits))
        }) { [weak self] loaded in
            guard let self, self.generation == current, let (output, commits, lanes) = loaded else { return }
            self.lastOutput = output
            self.commits = commits
            _ = lanes                       // rows size their own text start; the widest point no longer matters here
            self.tableView.reloadData()
            self.tableView.sizeLastColumnToFit()
            self.placeholder.stringValue = commits.isEmpty ? "No commits yet" : ""
            self.placeholder.textColor = Settings.shared.theme.lineNumber
        }
    }

    func applyTheme() { tableView.reloadData() }

    @objc private func openCommit() {
        guard commits.indices.contains(tableView.clickedRow) else { return }
        dismissCard()
        onOpenCommit?(commits[tableView.clickedRow].hash)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { commits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let commit = commits[row]
        let id = NSUserInterfaceItemIdentifier("CompactCommitCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CompactCommitCell ?? {
            let cell = CompactCommitCell(frame: .zero)
            cell.identifier = id
            return cell
        }()
        cell.show(commit)
        let theme = Settings.shared.theme
        let isHead = commit.refs.contains { $0.kind == .head }
        let text = NSMutableAttributedString(string: commit.subject, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: isHead ? .semibold : .regular), .foregroundColor: theme.foreground])
        text.append(NSAttributedString(string: "   " + commit.author, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: theme.lineNumber]))
        cell.subject.attributedStringValue = text
        cell.pills.attributedStringValue = RefPill.attributed(commit.refs, fontSize: 10, limit: 1, maxNameLength: 15, trailingSpace: false)
        return cell
    }

    // MARK: - Hover card

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let row = tableView.row(at: tableView.convert(event.locationInWindow, from: nil))
        setHoverRow(commits.indices.contains(row) ? row : -1)
    }

    override func mouseExited(with event: NSEvent) { setHoverRow(-1) }

    @objc private func scrolled() {
        setHoverRow(-1)
        dismissCard()
    }

    private func setHoverRow(_ row: Int) {
        guard row != hoverRow else { return }
        let tint = Settings.shared.theme.isDark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.06)
        if hoverRow >= 0 { tableView.rowView(atRow: hoverRow, makeIfNecessary: false)?.backgroundColor = .clear }
        hoverRow = row
        if row >= 0 { tableView.rowView(atRow: row, makeIfNecessary: false)?.backgroundColor = tint }

        hoverWork?.cancel()
        guard row >= 0 else { scheduleClose(); return }
        closeWork?.cancel()
        // The first card waits for the pointer to settle; once one is open, moving down the list follows quickly.
        let work = DispatchWorkItem { [weak self] in self?.showCard(forRow: row) }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (popover?.isShown == true ? 0.12 : 0.55), execute: work)
    }

    private func scheduleClose() {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerInsideCard, self.hoverRow != self.popoverRow else { return }
            self.dismissCard()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func dismissCard() {
        hoverWork?.cancel()
        popover?.close()
        popover = nil
        popoverRow = -1
        pointerInsideCard = false
    }

    func showCard(forRow row: Int) {
        guard let root, commits.indices.contains(row), window != nil, popoverRow != row else { return }
        let hash = commits[row].hash
        GitCommitDetails.load(hash, in: root) { [weak self] details in
            guard let self, let details, self.commits.indices.contains(row), self.commits[row].hash == hash,
                  self.hoverRow == row || self.hoverRow == -1 && self.popoverRow == -1 else { return }
            self.popover?.close()
            let theme = Settings.shared.theme
            let card = CommitHoverView(details: details, theme: theme)
            card.onPointerInside = { [weak self] inside in
                self?.pointerInsideCard = inside
                if inside { self?.closeWork?.cancel() } else { self?.scheduleClose() }
            }
            let controller = NSViewController()
            controller.view = card
            let popover = NSPopover()
            popover.contentViewController = controller
            popover.behavior = .applicationDefined
            popover.animates = false
            popover.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
            popover.show(relativeTo: self.tableView.rect(ofRow: row), of: self.tableView, preferredEdge: .maxX)
            self.popover = popover
            self.popoverRow = row
        }
    }
}
