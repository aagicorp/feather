import AppKit

/// Every error and warning reported for this window's files, by file. Two kinds of reporter feed it: the
/// language servers, and the project's own compilers and linters (ProjectChecker.swift). Neither reads the open
/// documents, so a file keeps its problems after its tab closes, for as long as its reporter stands by them.
///
/// For a file a server has spoken about, the server's word is the only one shown: it sees every keystroke, while a
/// checker only sees saved files, and the same error listed twice helps nobody. A checker's results stand until
/// that checker's next run replaces them.
final class ProblemsStore {
    /// What is shown: per file, the server's diagnostics or, where no server has spoken, the checkers'.
    private(set) var diagnostics: [URL: [LSPDiagnostic]] = [:]
    private(set) var errorCount = 0
    private(set) var warningCount = 0
    /// Any change at all; the pane coalesces these.
    var onChange: (() -> Void)?
    /// Only when the totals moved, which is all the status bar shows.
    var onCountsChange: (() -> Void)?
    /// The files whose shown diagnostics changed because of a checker (a run, or a server letting go of the
    /// file), for the editors showing them.
    var onCheckerChange: (([URL]) -> Void)?

    private var fromServers: [URL: [LSPDiagnostic]] = [:]
    /// Files a server has published for, even an empty list: it is speaking for them.
    private var spokenFor = Set<URL>()
    private var fromCheckers: [String: [URL: [LSPDiagnostic]]] = [:]

    /// What a server just published for one file. An empty list is the server clearing the file.
    func set(_ items: [LSPDiagnostic], for url: URL) {
        let kept = items.filter { $0.severity <= 2 }          // hints and notes are not problems
        let wasSpokenFor = spokenFor.contains(url)
        if wasSpokenFor, fromServers[url] == nil, kept.isEmpty { return }
        spokenFor.insert(url)
        fromServers[url] = kept.isEmpty ? nil : kept
        let hadChecker = hasCheckerResults(for: url)
        refresh([url])
        if !wasSpokenFor, hadChecker { onCheckerChange?([url]) }   // the checker's rows just gave way
    }

    /// A checker's results, replacing what it reported last time. With `scope`, only those files are replaced:
    /// a per-file tool that was run on the saved files says nothing about the rest.
    func setChecker(_ name: String, _ results: [URL: [LSPDiagnostic]], scope: [URL]? = nil) {
        var mine = fromCheckers[name] ?? [:]
        var touched = Set(results.keys)
        if let scope {
            for url in scope { if mine.removeValue(forKey: url) != nil { touched.insert(url) } }
        } else {
            touched.formUnion(mine.keys)
            mine = [:]
        }
        for (url, items) in results {
            let kept = items.filter { $0.severity <= 2 }
            if !kept.isEmpty { mine[url] = kept }
        }
        fromCheckers[name] = mine.isEmpty ? nil : mine
        guard !touched.isEmpty else { return }
        refresh(Array(touched))
        onCheckerChange?(touched.filter { !spokenFor.contains($0) })
    }

    /// Drops what the checkers found in files that no longer exist under the folder (or drops all of it, when
    /// the folder changes).
    func clearCheckers() {
        let touched = Set(fromCheckers.values.flatMap(\.keys))
        fromCheckers = [:]
        guard !touched.isEmpty else { return }
        refresh(Array(touched))
        onCheckerChange?(touched.filter { !spokenFor.contains($0) })
    }

    /// Drops the server's word on the files whose server is gone (stopped, crashed, folder changed, Restricted
    /// Mode): nobody is left to say those problems were fixed. A checker's results for those files show again.
    func prune(keeping isLive: (URL) -> Bool) {
        let dead = spokenFor.filter { !isLive($0) }
        guard !dead.isEmpty else { return }
        for url in dead {
            spokenFor.remove(url)
            fromServers[url] = nil
        }
        refresh(Array(dead))
        onCheckerChange?(dead.filter { hasCheckerResults(for: $0) })
    }

    func isSpokenForByServer(_ url: URL) -> Bool { spokenFor.contains(url) }

    /// Which reporters have something to say about the file, for the pane and the tests.
    func checkerNames(for url: URL) -> [String] { fromCheckers.filter { $0.value[url] != nil }.keys.sorted() }

    private func hasCheckerResults(for url: URL) -> Bool { fromCheckers.values.contains { $0[url] != nil } }

    /// Recomputes what is shown for some files and the totals, telling the listeners once.
    private func refresh(_ urls: [URL]) {
        let before = (errorCount, warningCount)
        var changed = false
        for url in urls {
            let shown: [LSPDiagnostic]
            if spokenFor.contains(url) {
                shown = fromServers[url] ?? []
            } else {
                shown = fromCheckers.keys.sorted().flatMap { fromCheckers[$0]?[url] ?? [] }
            }
            let old = diagnostics[url] ?? []
            if old.isEmpty, shown.isEmpty { continue }
            count(old, sign: -1)
            count(shown, sign: 1)
            diagnostics[url] = shown.isEmpty ? nil : shown
            changed = true
        }
        guard changed else { return }
        if before != (errorCount, warningCount) { onCountsChange?() }
        onChange?()
    }

    private func count(_ items: [LSPDiagnostic], sign: Int) {
        for item in items {
            if item.severity == 1 { errorCount += sign } else { warningCount += sign }
        }
    }
}

// MARK: - Rows

/// One problem or one TODO comment. Positions are zero-based, as the language servers give them.
final class ProblemItem: NSObject {
    let url: URL
    let line: Int, character: Int, endLine: Int, endCharacter: Int
    let severity: Int              // 1 error, 2 warning; 0 for a comment
    let tag: String?               // TODO, FIXME… for a comment
    let message: String            // the first line only
    let fullMessage: String
    let detail: String             // "ts(2322)"; empty when the server gave neither

    init(url: URL, diagnostic: LSPDiagnostic) {
        self.url = url
        line = diagnostic.startLine; character = diagnostic.startCharacter
        endLine = diagnostic.endLine; endCharacter = diagnostic.endCharacter
        severity = diagnostic.severity
        tag = nil
        fullMessage = diagnostic.message
        message = diagnostic.message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        detail = (diagnostic.source ?? "") + (diagnostic.code.map { "(\($0))" } ?? "")
    }

    init(url: URL, tag: String, text: String, line: Int, character: Int) {
        self.url = url
        self.line = line; self.character = character
        endLine = line; endCharacter = character + tag.utf16.count
        severity = 0
        self.tag = tag
        message = text
        fullMessage = text.isEmpty ? tag : tag + ": " + text
        detail = ""
    }
}

final class ProblemGroup: NSObject {
    let url: URL
    let relativePath: String
    /// The rows that were built. `total` may be far larger: what is over the cap is counted, never built.
    let items: [ProblemItem]
    let total: Int
    let errors: Int, warnings: Int
    lazy var overflow = ProblemOverflow(group: self)

    init(url: URL, relativePath: String, items: [ProblemItem], total: Int, errors: Int = 0, warnings: Int = 0) {
        self.url = url
        self.relativePath = relativePath
        self.items = items
        self.total = total
        self.errors = errors
        self.warnings = warnings
    }

    var hiddenCount: Int { total - items.count }
}

/// The "… 4,800 more" row that ends a file with more problems than are worth building rows for.
final class ProblemOverflow: NSObject {
    unowned let group: ProblemGroup
    init(group: ProblemGroup) { self.group = group }
}

// MARK: - TODO comments

/// Finds TODO, FIXME, HACK, XXX and NOTE comments. Runs off the main thread.
enum TodoScanner {
    static let tags = ["TODO", "FIXME", "HACK", "XXX", "NOTE"]
    static let maxPerFile = 500
    static let maxTotal = 10_000

    /// The tag has to follow something that starts a comment in one of the usual languages, so an identifier
    /// such as `TODO_LIST` or a string "NOTE" in code is not listed.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?://|#|/\*|^\s*\*|--|<!--|%|;)\s*@?(TODO|FIXME|HACK|XXX|NOTE)\b(?:\([^)\n]*\))?[ \t]*[:\-]?[ \t]*([^\n]*)"#,
        options: [.anchorsMatchLines])

    static func scan(root: URL, isCancelled: @escaping () -> Bool) -> [ProblemGroup] {
        let files = ProjectFiles.list(root: root, isCancelled: isCancelled)
        if isCancelled() { return [] }
        let lock = NSLock()
        var groups: [ProblemGroup] = []
        var total = 0
        DispatchQueue.concurrentPerform(iterations: files.count) { index in autoreleasepool {
            if isCancelled() { return }
            lock.lock(); let full = total >= maxTotal; lock.unlock()
            if full { return }
            guard let group = scan(file: root.appendingPathComponent(files[index]), relativePath: files[index]) else { return }
            lock.lock()
            groups.append(group)
            total += group.items.count
            lock.unlock()
        } }
        return sorted(groups)
    }

    static func sorted(_ groups: [ProblemGroup]) -> [ProblemGroup] {
        groups.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    /// Nil when the file has no such comment, or is not text the project search would read either.
    static func scan(file url: URL, relativePath: String) -> ProblemGroup? {
        guard let text = ProjectSearch.searchableText(at: url) else { return nil }
        let items = self.items(in: text, url: url)
        return items.isEmpty ? nil : ProblemGroup(url: url, relativePath: relativePath, items: items, total: items.count)
    }

    static func items(in text: String, url: URL) -> [ProblemItem] {
        // Most files have none; five plain substring scans are far cheaper than the expression.
        guard tags.contains(where: { text.contains($0) }) else { return [] }
        let ns = text as NSString
        var items: [ProblemItem] = []
        var line = 0, counted = 0           // newlines before `counted` have been added to `line`
        var lineStart = 0
        pattern.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            guard let match else { return }
            let tagRange = match.range(at: 1)
            var search = NSRange(location: counted, length: tagRange.location - counted)
            while search.length > 0 {
                let newline = ns.range(of: "\n", options: .literal, range: search)
                if newline.location == NSNotFound { break }
                line += 1
                lineStart = NSMaxRange(newline)
                search = NSRange(location: lineStart, length: tagRange.location - lineStart)
            }
            counted = tagRange.location
            var rest = ns.substring(with: match.range(at: 2))
            for closer in ["*/", "-->"] where rest.hasSuffix(closer) { rest.removeLast(closer.count) }
            rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)     // a CRLF file leaves "\r" on the line
            if rest.utf16.count > 300 { rest = String(rest.prefix(300)) + "…" }
            items.append(ProblemItem(url: url, tag: ns.substring(with: tagRange), text: rest,
                                     line: line, character: tagRange.location - lineStart))
            if items.count >= maxPerFile { stop.pointee = true }
        }
        return items
    }
}

// MARK: - Pane

/// An outline that treats Return like a click, so the list can be walked with the keyboard.
private final class ActivatingOutlineView: NSOutlineView {
    var onActivate: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onActivate?() } else { super.keyDown(with: event) }
    }
}

/// The sidebar's fifth pane: the window's problems, and the project's TODO comments behind a switch.
final class ProblemsViewController: NSViewController, NSSearchFieldDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    enum Mode: Int { case problems, todos }

    let store = ProblemsStore()
    /// Opens a file at a position, through the window's usual navigation so Back returns from it.
    var onOpen: ((LSPLocation) -> Void)?
    /// Fix This on a row (a button under the pointer, and the context menu): the window hands the problem to the
    /// AI assistant in its terminal.
    var onFixThis: ((ProblemItem) -> Void)?
    /// The header's check button: run the project's compiler or linter (Run ▸ Check Project for Errors).
    var onCheckProject: (() -> Void)?
    private(set) var fixThisAction: RowHoverAction?
    var rootURL: URL? {
        didSet {
            guard rootURL != oldValue else { return }
            todoGeneration += 1                 // abandons a scan of the previous folder
            todoGroups = nil
            isScanning = false
            if isViewLoaded { mode == .todos ? showTodos(rescan: false) : markDirty() }
        }
    }
    private(set) var mode = Mode.problems

    /// Rows built per file before "… N more". A click on that row lifts it for the file.
    static let rowsPerFile = 100
    private static let expandedRowsPerFile = 2_000
    /// At most this many rows are expanded automatically, so a project with thousands of problems opens as a
    /// list of files rather than as thousands of rows.
    private static let autoExpandBudget = 600
    private static let coalescing: TimeInterval = 0.15

    private let modeSwitch = NSSegmentedControl(labels: ["Problems", "TODOs"], trackingMode: .selectOne, target: nil, action: nil)
    private let field = NSSearchField()
    private let errorsOnlyButton = NSButton(title: "", target: nil, action: nil)
    private let refreshButton = NSButton(title: "", target: nil, action: nil)
    private let checkButton = NSButton(title: "", target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")
    /// "Checked with tsc · just now", at the right of the summary line.
    private let checkStatus = NSTextField(labelWithString: "")
    private var checkerState: (name: String?, date: Date?, running: Bool, error: String?) = (nil, nil, false, nil)
    private lazy var checkStatusHeight = checkStatus.heightAnchor.constraint(equalToConstant: 0)
    private var ageTimer: Timer?
    private let outlineView = ActivatingOutlineView()
    private let scrollView = NSScrollView()

    /// What the outline is showing: filtered, sorted and capped.
    private(set) var groups: [ProblemGroup] = []
    private var isDirty = true
    private var rebuildScheduled = false
    private var collapsed = Set<URL>()
    private var uncapped = Set<URL>()
    private var contentWidth: CGFloat = 0
    /// How long the last rebuild of the problems list took, for the tests and for anyone profiling.
    private(set) var lastRebuildDuration: TimeInterval = 0

    private var todoGroups: [ProblemGroup]?         // nil until the first scan of this folder
    private var todoGeneration = 0
    private var isScanning = false
    private var savedDuringScan = Set<URL>()

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
        store.onChange = { [weak self] in self?.markDirty() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))

        modeSwitch.controlSize = .small
        modeSwitch.segmentDistribution = .fillEqually
        modeSwitch.selectedSegment = 0
        modeSwitch.target = self
        modeSwitch.action = #selector(modeSwitched)

        field.placeholderString = "Filter"
        field.delegate = self
        field.controlSize = .small
        field.font = .systemFont(ofSize: 12)
        field.sendsSearchStringImmediately = true

        errorsOnlyButton.setButtonType(.pushOnPushOff)
        errorsOnlyButton.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Errors Only")
        errorsOnlyButton.toolTip = "Show Errors Only"
        errorsOnlyButton.action = #selector(errorsOnlyToggled)
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.toolTip = "Scan the Project Again"
        refreshButton.action = #selector(refreshClicked)
        refreshButton.isHidden = true
        checkButton.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: "Check Project")
        checkButton.toolTip = "Check the project for errors with its own compiler or linter (⇧⌘B)"
        checkButton.action = #selector(checkClicked)
        for button in [errorsOnlyButton, refreshButton, checkButton] {
            button.bezelStyle = .recessed
            button.controlSize = .small
            button.imagePosition = .imageOnly
            button.target = self
        }

        summary.font = .systemFont(ofSize: 11)
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        checkStatus.font = .systemFont(ofSize: 11)
        checkStatus.lineBreakMode = .byTruncatingTail

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("problem"))
        column.resizingMask = []
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 20
        outlineView.indentationPerLevel = 10
        outlineView.style = .plain
        outlineView.backgroundColor = .clear
        outlineView.columnAutoresizingStyle = .noColumnAutoresizing
        outlineView.autoresizesOutlineColumn = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        outlineView.onActivate = { [weak self] in self?.activate(row: self?.outlineView.selectedRow ?? -1) }

        scrollView.documentView = outlineView
        scrollView.contentView.postsBoundsChangedNotifications = true
        fixThisAction = RowHoverAction(table: outlineView, title: "Fix This",
                                       toolTip: "Ask the AI assistant in the terminal to fix this. Nothing is sent until you press Return there.",
                                       isEligible: { [weak self] in self?.outlineView.item(atRow: $0) is ProblemItem },
                                       perform: { [weak self] in
            guard let self, let problem = self.outlineView.item(atRow: $0) as? ProblemItem else { return }
            self.onFixThis?(problem)
        })
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true         // long messages scroll sideways, as search results do
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        for subview in [modeSwitch, field, errorsOnlyButton, refreshButton, checkButton, summary, checkStatus, scrollView] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            modeSwitch.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            modeSwitch.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            modeSwitch.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            field.topAnchor.constraint(equalTo: modeSwitch.bottomAnchor, constant: 7),
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            checkButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 4),
            checkButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            checkButton.widthAnchor.constraint(equalToConstant: 30),
            errorsOnlyButton.leadingAnchor.constraint(equalTo: checkButton.trailingAnchor, constant: 2),
            errorsOnlyButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            errorsOnlyButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            errorsOnlyButton.widthAnchor.constraint(equalToConstant: 30),
            refreshButton.leadingAnchor.constraint(equalTo: errorsOnlyButton.leadingAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: errorsOnlyButton.trailingAnchor),
            refreshButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            summary.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 7),
            summary.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            summary.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            // Its own line under the summary, which folds away while there is nothing to say.
            checkStatus.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 3),
            checkStatus.leadingAnchor.constraint(equalTo: summary.leadingAnchor),
            checkStatus.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            checkStatusHeight,
            scrollView.topAnchor.constraint(equalTo: checkStatus.bottomAnchor, constant: 5),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        applyTheme()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyColumnWidth()
    }

    /// Also reached when the sidebar is shown again with this pane already selected.
    override func viewDidAppear() {
        super.viewDidAppear()
        paneDidAppear()
    }

    func applyTheme() {
        guard isViewLoaded else { return }
        summary.textColor = Settings.shared.theme.lineNumber
        checkStatus.textColor = Settings.shared.theme.lineNumber
        outlineView.reloadData()
    }

    /// The container calls this when the pane is switched to.
    func paneDidAppear() {
        guard isViewLoaded else { return }
        if mode == .todos {
            if todoGroups == nil, !isScanning { showTodos(rescan: true) }
        } else if isDirty {
            rebuildProblems()
        }
        showCheckStatus()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        ageTimer?.invalidate()
        ageTimer = nil
    }

    func show(_ newMode: Mode) {
        _ = view
        mode = newMode
        modeSwitch.selectedSegment = newMode.rawValue
        errorsOnlyButton.isHidden = newMode == .todos
        checkButton.isHidden = newMode == .todos
        checkStatus.isHidden = newMode == .todos
        refreshButton.isHidden = newMode == .problems
        showCheckStatus()
        if newMode == .todos { showTodos(rescan: todoGroups == nil) } else { rebuildProblems() }
    }

    // MARK: - The project checker's status

    /// What the checker is up to, for the line under the filter: "Checking with tsc…", "Checked with tsc · just
    /// now", or why the last run gave nothing.
    func setCheckerStatus(name: String?, date: Date?, running: Bool, error: String? = nil) {
        _ = view
        checkerState = (name, date, running, error)
        showCheckStatus()
    }

    var checkStatusText: String { checkStatus.stringValue }

    private func showCheckStatus() {
        let state = checkerState
        var text = ""
        if state.running, let name = state.name {
            text = "Checking with \(name)…"
        } else if let name = state.name, let date = state.date {
            text = "Checked with \(name) · " + Checkpoint.age(of: date)
        }
        checkStatus.stringValue = text
        checkStatus.toolTip = state.error
        checkStatusHeight.constant = text.isEmpty || mode == .todos ? 0 : 14
        checkButton.isEnabled = !state.running
        // The age only needs refreshing while someone can see it and it is still counted in seconds or minutes.
        ageTimer?.invalidate()
        ageTimer = nil
        if !state.running, let date = state.date, isOnScreen, Date().timeIntervalSince(date) < 3600 {
            ageTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in self?.showCheckStatus() }
        }
    }

    @objc private func checkClicked() { onCheckProject?() }

    func focusFilter() { view.window?.makeFirstResponder(field) }

    var summaryText: String { summary.stringValue }

    /// Narrows the list from code, exactly as typing in the field and pressing the button would.
    func setFilter(_ text: String, errorsOnly: Bool = false) {
        _ = view
        field.stringValue = text
        errorsOnlyButton.state = errorsOnly ? .on : .off
        if mode == .todos { showTodos(rescan: false) } else { rebuildProblems() }
    }

    @objc private func modeSwitched() { show(Mode(rawValue: modeSwitch.selectedSegment) ?? .problems) }

    @objc private func errorsOnlyToggled() { rebuildProblems() }

    @objc private func refreshClicked() { showTodos(rescan: true) }

    func controlTextDidChange(_ obj: Notification) {
        if mode == .todos { showTodos(rescan: false) } else { rebuildProblems() }
    }

    // MARK: - Problems

    private var isOnScreen: Bool { isViewLoaded && view.window != nil && !view.isHiddenOrHasHiddenAncestor }

    /// Servers publish in bursts (one message per file, again after every edit). The list is rebuilt at most
    /// once per `coalescing` interval, and not at all while nobody can see it.
    private func markDirty() {
        isDirty = true
        guard mode == .problems, isOnScreen, !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + ProblemsViewController.coalescing) { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            if self.isDirty, self.mode == .problems, self.isOnScreen { self.rebuildProblems() }
        }
    }

    private func relativePath(of url: URL) -> String {
        guard let rootURL, url.path.hasPrefix(rootURL.path + "/") else { return url.path }
        return String(url.path.dropFirst(rootURL.path.count + 1))
    }

    /// Filter, sort, cap. Linear in the number of problems apart from the sort; only `rowsPerFile` row objects
    /// are made per file however many the server sent.
    func rebuildProblems() {
        guard isViewLoaded, mode == .problems else { isDirty = true; return }
        let started = CFAbsoluteTimeGetCurrent()
        isDirty = false
        let filter = field.stringValue.trimmingCharacters(in: .whitespaces)
        let errorsOnly = errorsOnlyButton.state == .on
        var built: [ProblemGroup] = []
        var errors = 0, warnings = 0
        for (url, all) in store.diagnostics {
            let path = relativePath(of: url)
            var matching = errorsOnly ? all.filter { $0.severity == 1 } : all
            if !filter.isEmpty, path.range(of: filter, options: .caseInsensitive) == nil {
                matching = matching.filter {
                    $0.message.range(of: filter, options: .caseInsensitive) != nil
                        || $0.source?.range(of: filter, options: .caseInsensitive) != nil
                        || $0.code?.range(of: filter, options: .caseInsensitive) != nil
                }
            }
            guard !matching.isEmpty else { continue }
            matching.sort { ($0.severity, $0.startLine, $0.startCharacter) < ($1.severity, $1.startLine, $1.startCharacter) }
            let cap = uncapped.contains(url) ? ProblemsViewController.expandedRowsPerFile : ProblemsViewController.rowsPerFile
            // Row objects only for what can be shown; the rest are counted, not built.
            let errorCount = matching.reduce(0) { $0 + ($1.severity == 1 ? 1 : 0) }
            let group = ProblemGroup(url: url, relativePath: path,
                                     items: matching.prefix(cap).map { ProblemItem(url: url, diagnostic: $0) },
                                     total: matching.count, errors: errorCount, warnings: matching.count - errorCount)
            errors += group.errors
            warnings += group.warnings
            built.append(group)
        }
        // Files with errors first; within each half, by path.
        built.sort {
            if ($0.errors > 0) != ($1.errors > 0) { return $0.errors > 0 }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        let text: String
        if built.isEmpty {
            text = store.diagnostics.isEmpty ? "No problems reported" : "Nothing matches the filter"
        } else {
            text = "\(ProblemsViewController.plural(errors, "error")), \(ProblemsViewController.plural(warnings, "warning")) in \(ProblemsViewController.plural(built.count, "file"))"
        }
        display(built, summary: text)
        lastRebuildDuration = CFAbsoluteTimeGetCurrent() - started
    }

    private static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// Reloads the outline, keeping what the user collapsed collapsed and the selected problem selected.
    private func display(_ newGroups: [ProblemGroup], summary text: String) {
        let selected = outlineView.item(atRow: outlineView.selectedRow) as? ProblemItem
        groups = newGroups
        summary.stringValue = text
        fixThisAction?.hide()
        outlineView.reloadData()
        var budget = ProblemsViewController.autoExpandBudget
        for group in groups where !collapsed.contains(group.url) {
            guard budget > 0 else { break }
            budget -= group.items.count
            isExpandingProgrammatically = true
            outlineView.expandItem(group)
            isExpandingProgrammatically = false
        }
        if let selected, let group = groups.first(where: { $0.url == selected.url }),
           let same = group.items.first(where: {
               $0.line == selected.line && $0.character == selected.character && $0.message == selected.message }) {
            let row = outlineView.row(forItem: same)
            if row >= 0 { outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
        fitColumnToContent()
    }

    // MARK: - TODOs

    /// Shows the comments found so far, filtered. With `rescan` the project is walked again first, in the
    /// background; a newer scan or another folder abandons it.
    private func showTodos(rescan: Bool) {
        guard isViewLoaded, mode == .todos else { return }
        guard let rootURL else {
            display([], summary: "Open a folder to list its TODOs")
            return
        }
        if rescan {
            todoGeneration += 1
            let generation = todoGeneration
            isScanning = true
            savedDuringScan = []
            summary.stringValue = "Scanning…"
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let found = TodoScanner.scan(root: rootURL) { self?.todoGeneration != generation }
                DispatchQueue.main.async {
                    guard let self, self.todoGeneration == generation else { return }
                    self.isScanning = false
                    self.todoGroups = found
                    // Files saved while the walk was under way may have been read before the save.
                    let again = self.savedDuringScan
                    self.savedDuringScan = []
                    again.forEach { self.fileSaved($0) }
                    self.showTodos(rescan: false)
                }
            }
            return
        }
        guard let todoGroups else { return }
        let filter = field.stringValue.trimmingCharacters(in: .whitespaces)
        var shown: [ProblemGroup] = []
        var count = 0
        for group in todoGroups {
            var items = group.items
            if !filter.isEmpty, group.relativePath.range(of: filter, options: .caseInsensitive) == nil {
                items = items.filter { $0.fullMessage.range(of: filter, options: .caseInsensitive) != nil }
            }
            guard !items.isEmpty else { continue }
            count += items.count
            let cap = uncapped.contains(group.url) ? ProblemsViewController.expandedRowsPerFile : ProblemsViewController.rowsPerFile
            shown.append(ProblemGroup(url: group.url, relativePath: group.relativePath, items: Array(items.prefix(cap)), total: items.count))
        }
        let text = count == 0 ? (todoGroups.isEmpty ? "No TODO comments found" : "Nothing matches the filter")
            : "\(ProblemsViewController.plural(count, "comment")) in \(ProblemsViewController.plural(shown.count, "file"))"
        display(shown, summary: isScanning ? "Scanning…" : text)
    }

    /// A save can add or remove comments in that one file; the rest of the project is not read again.
    func fileSaved(_ url: URL) {
        guard let rootURL, todoGroups != nil || isScanning else { return }
        let url = url.standardizedFileURL
        guard url.path.hasPrefix(rootURL.path + "/") else { return }
        if isScanning { savedDuringScan.insert(url); return }
        let path = relativePath(of: url)
        // The same files the project walk would have skipped stay skipped.
        let parts = path.split(separator: "/")
        guard !parts.contains(where: { $0.hasPrefix(".") || ProjectFiles.ignoredDirectories.contains(String($0)) }) else { return }
        let generation = todoGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let group = TodoScanner.scan(file: url, relativePath: path)
            DispatchQueue.main.async {
                guard let self, self.todoGeneration == generation, var all = self.todoGroups else { return }
                all.removeAll { $0.url == url }
                if let group { all.append(group) }
                self.todoGroups = TodoScanner.sorted(all)
                self.showTodos(rescan: false)
            }
        }
    }

    // MARK: - Clicks

    @objc private func rowClicked() { activate(row: outlineView.clickedRow) }

    /// A click or Return on a row: open the problem, fold the file, or show the rows that were held back.
    func activate(row: Int) {
        let item = outlineView.item(atRow: row)
        if let problem = item as? ProblemItem {
            onOpen?(LSPLocation(url: problem.url, line: problem.line, character: problem.character,
                                endLine: problem.endLine, endCharacter: problem.endCharacter))
        } else if let group = item as? ProblemGroup {
            if outlineView.isItemExpanded(group) { outlineView.collapseItem(group) } else { outlineView.expandItem(group) }
        } else if let overflow = item as? ProblemOverflow {
            uncapped.insert(overflow.group.url)
            if mode == .todos { showTodos(rescan: false) } else { rebuildProblems() }
        }
    }

    // MARK: - Column width

    /// Measured once per rebuild, from text lengths rather than by laying text out.
    private func fitColumnToContent() {
        var longest = 0
        for group in groups {
            longest = max(longest, group.relativePath.utf16.count + 12)
            for item in group.items.prefix(400) {
                longest = max(longest, item.message.utf16.count + item.detail.utf16.count + 18)
            }
        }
        contentWidth = min(CGFloat(longest) * 6.6 + 48, 2400)
        applyColumnWidth()
    }

    private func applyColumnWidth() {
        guard isViewLoaded, let column = outlineView.tableColumns.first else { return }
        let width = max(scrollView.contentSize.width, contentWidth)
        if abs(column.width - width) > 0.5 { column.width = width }
    }

    // MARK: - Outline view

    private var isExpandingProgrammatically = false

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let group = item as? ProblemGroup else { return item == nil ? groups.count : 0 }
        return group.items.count + (group.hiddenCount > 0 ? 1 : 0)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let group = item as? ProblemGroup else { return groups[index] }
        return index < group.items.count ? group.items[index] : group.overflow
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is ProblemGroup }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let group = notification.userInfo?["NSObject"] as? ProblemGroup { collapsed.insert(group.url) }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isExpandingProgrammatically, let group = notification.userInfo?["NSObject"] as? ProblemGroup else { return }
        collapsed.remove(group.url)
    }

    private static var icons: [String: NSAttributedString] = [:]

    /// A coloured SF Symbol as text, so a row stays a single label. Made once per symbol.
    private static func icon(_ symbol: String, _ color: NSColor) -> NSAttributedString {
        if let cached = icons[symbol] { return cached }
        let attachment = NSTextAttachment()
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            // Two layers: the mark itself, then the filled shape around it.
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(hex: 0x1E1E1E), color]))
        attachment.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        attachment.bounds = NSRect(x: 0, y: -2, width: 13, height: 13)
        let text = NSMutableAttributedString(attachment: attachment)
        text.append(NSAttributedString(string: " "))
        icons[symbol] = text
        return text
    }

    private static let tagColors: [String: UInt32] = ["TODO": 0x3794FF, "FIXME": 0xF14C4C, "HACK": 0xCCA700, "XXX": 0xCCA700, "NOTE": 0x3FB950]

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ProblemCell")
        let label = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField ?? {
            let label = NSTextField(labelWithString: "")
            label.identifier = identifier
            label.usesSingleLineMode = true
            label.lineBreakMode = .byClipping
            return label
        }()
        let theme = Settings.shared.theme
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: theme.lineNumber]
        let text = NSMutableAttributedString()
        label.toolTip = nil
        if let group = item as? ProblemGroup {
            let path = group.relativePath as NSString
            text.append(FileIcon.attributed(for: group.url))
            text.append(NSAttributedString(string: path.lastPathComponent, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: theme.foreground]))
            let counts = mode == .todos ? "\(group.total)"
                : [group.errors > 0 ? "✕ \(group.errors)" : nil, group.warnings > 0 ? "⚠ \(group.warnings)" : nil]
                    .compactMap { $0 }.joined(separator: "  ")
            text.append(NSAttributedString(string: "  \(path.deletingLastPathComponent)  \(counts)", attributes: dim))
            label.toolTip = group.url.path
        } else if let problem = item as? ProblemItem {
            if let tag = problem.tag {
                text.append(NSAttributedString(string: tag + " ", attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor(hex: ProblemsViewController.tagColors[tag] ?? 0x3794FF)]))
            } else if problem.severity == 1 {
                text.append(ProblemsViewController.icon("xmark.circle.fill", NSColor(hex: 0xF14C4C)))
            } else {
                text.append(ProblemsViewController.icon("exclamationmark.triangle.fill", NSColor(hex: 0xCCA700)))
            }
            text.append(NSAttributedString(string: problem.message, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: theme.foreground]))
            let detail = problem.detail.isEmpty ? "" : "  " + problem.detail
            text.append(NSAttributedString(string: "\(detail)  [Ln \(problem.line + 1), Col \(problem.character + 1)]", attributes: dim))
            label.toolTip = problem.fullMessage
        } else if let overflow = item as? ProblemOverflow {
            text.append(NSAttributedString(string: "… \(overflow.group.hiddenCount) more (click to show)", attributes: dim))
        }
        label.attributedStringValue = text
        return label
    }
}
