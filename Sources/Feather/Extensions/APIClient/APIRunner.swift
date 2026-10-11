import AppKit

/// Sends every request of a collection or folder in order, one at a time, with an environment. Values captured
/// from one answer reach the next request through the workspace, the way they do when sending by hand.
final class APIRunner {
    struct Row {
        enum State { case waiting, running, done }
        let request: APIRequest
        let path: [APIFolder]
        var state: State = .waiting
        var status: Int?
        var duration: TimeInterval = 0
        var error: String?
        var checks: [APIChecks.Result] = []

        /// Nil until done. Failed: no answer, a status outside 2xx, or a check that did not pass.
        var passed: Bool? {
            guard state == .done else { return nil }
            guard error == nil, let status, (200..<300).contains(status) else { return false }
            return checks.allSatisfy(\.passed)
        }
        var checksPassed: Int { checks.filter(\.passed).count }
    }

    let collection: APICollection
    let folderID: String?
    let environment: APIEnvironment?
    private let workspace: APIWorkspace
    private let makeSender: () -> APIRequestSender
    private(set) var rows: [Row]
    private(set) var isRunning = false
    private var queue: [Int] = []
    private var sender: APIRequestSender?
    /// A row changed (its index), and the whole run finished.
    var onRowChange: ((Int) -> Void)?
    var onFinish: (() -> Void)?

    init(workspace: APIWorkspace, collection: APICollection, folderID: String?, environment: APIEnvironment?,
         makeSender: @escaping () -> APIRequestSender = { APIRequestSender() }) {
        self.workspace = workspace
        self.collection = collection
        self.folderID = folderID
        self.environment = environment
        self.makeSender = makeSender
        let all = collection.allRequests
        let chosen = folderID.map { id in all.filter { $0.path.contains { $0.id == id } } } ?? all
        rows = chosen.map { Row(request: $0.request, path: $0.path) }
    }

    var failedIndices: [Int] { rows.indices.filter { rows[$0].passed == false } }
    var finishedCount: Int { rows.filter { $0.state == .done }.count }

    /// Runs the rows given (all of them by default), in order.
    func start(only indices: [Int]? = nil) {
        guard !isRunning else { return }
        let chosen = indices ?? Array(rows.indices)
        for index in chosen { rows[index] = Row(request: rows[index].request, path: rows[index].path) }
        queue = chosen
        isRunning = !queue.isEmpty
        chosen.forEach { onRowChange?($0) }
        if isRunning { sendNext() } else { onFinish?() }
    }

    func stop() {
        guard isRunning else { return }
        sender?.cancel()
        sender = nil
        queue = []
        isRunning = false
        for index in rows.indices where rows[index].state == .running {
            rows[index].state = .done
            rows[index].error = "Stopped."
            onRowChange?(index)
        }
        onFinish?()
    }

    private func sendNext() {
        guard isRunning, !queue.isEmpty else {
            isRunning = false
            sender = nil
            onFinish?()
            return
        }
        let index = queue.removeFirst()
        rows[index].state = .running
        onRowChange?(index)
        let sender = makeSender()
        self.sender = sender
        let started = Date()
        APISending.send(rows[index].request, in: collection, folders: rows[index].path, workspace: workspace, environment: environment, sender: sender) { [weak self] result, checks in
            guard let self, self.isRunning else { return }
            self.rows[index].state = .done
            self.rows[index].checks = checks
            switch result {
            case .success(let response):
                self.rows[index].status = response.status
                self.rows[index].duration = response.duration
                if let file = response.bodyFile { try? FileManager.default.removeItem(at: file) }
            case .failure(let failure):
                self.rows[index].error = failure.message
                self.rows[index].duration = Date().timeIntervalSince(started)
            }
            self.onRowChange?(index)
            self.sendNext()
        }
    }
}

/// The results of a run in a tab: one row per request with its status, time and checks, and buttons to stop,
/// run again or rerun only what failed.
final class APIRunView: NSView, TabPreview, NSTableViewDataSource, NSTableViewDelegate {
    private weak var controller: APIClientController?
    private weak var pane: APIPaneViewController?
    private(set) var runner: APIRunner?
    private let titleLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let againButton = NSButton(title: "Run Again", target: nil, action: nil)
    private let failedButton = NSButton(title: "Rerun Failed", target: nil, action: nil)
    private let table = NSTableView()
    private let scrollView = NSScrollView()

    var focusView: NSView { table }

    init(controller: APIClientController, pane: APIPaneViewController) {
        self.controller = controller
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        build()
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var theme: Theme { Settings.shared.theme }

    private func build() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        for (button, action, tip) in [(stopButton, #selector(stopClicked), "Stop after the request on its way now (Esc)"),
                                      (againButton, #selector(againClicked), "Run every request again"),
                                      (failedButton, #selector(failedClicked), "Run only the requests that failed")] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
            button.toolTip = tip
        }
        let header = NSStackView(views: [titleLabel, progressLabel, NSView(), failedButton, againButton, stopButton])
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false

        for (id, title, width) in [("request", "Request", nil), ("status", "Status", 70), ("time", "Time", 70), ("checks", "Checks", 70), ("result", "Result", 260)] as [(String, String, CGFloat?)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            if let width { column.width = width; column.minWidth = width; column.maxWidth = width } else { column.minWidth = 120 }
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 22
        table.style = .plain
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.useFeatherScrollers()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Starts (or restarts) a run of the collection or one of its folders with the chosen environment.
    func start(collection: APICollection, folderID: String?) {
        guard let controller else { return }
        runner?.stop()
        let environment = controller.selectedEnvironment
        let runner = APIRunner(workspace: controller.workspace, collection: collection, folderID: folderID, environment: environment)
        runner.onRowChange = { [weak self] index in
            guard let self, self.table.numberOfRows > index else { self?.table.reloadData(); return }
            self.table.reloadData(forRowIndexes: [index], columnIndexes: IndexSet(0..<self.table.numberOfColumns))
            self.updateHeader()
        }
        runner.onFinish = { [weak self] in self?.updateHeader() }
        self.runner = runner
        let folderName = folderID.flatMap { collection.folder(id: $0)?.name }
        titleLabel.stringValue = (folderName.map { collection.name + " ▸ " + $0 } ?? collection.name) + " with " + (environment?.name ?? "no environment")
        table.reloadData()
        runner.start()
        updateHeader()
    }

    private func updateHeader() {
        guard let runner else { return }
        let failed = runner.failedIndices.count
        let done = runner.finishedCount
        progressLabel.stringValue = runner.isRunning ? "\(done) of \(runner.rows.count)…"
            : (runner.rows.isEmpty ? "Nothing to run." : (failed == 0 ? "All \(done) passed" : "\(failed) of \(done) failed"))
        progressLabel.textColor = runner.isRunning ? theme.lineNumber : APIFormat.statusColor(failed == 0 ? 200 : 500, theme: theme)
        stopButton.isHidden = !runner.isRunning
        againButton.isHidden = runner.isRunning
        failedButton.isHidden = runner.isRunning || failed == 0
    }

    @objc private func stopClicked() { runner?.stop() }
    @objc private func againClicked() { runner?.start(); table.reloadData(); updateHeader() }
    @objc private func failedClicked() {
        guard let runner else { return }
        runner.start(only: runner.failedIndices)
        updateHeader()
    }

    override func cancelOperation(_ sender: Any?) {
        if runner?.isRunning == true { runner?.stop() } else { super.cancelOperation(sender) }
    }

    @objc private func rowDoubleClicked() {
        guard let runner, runner.rows.indices.contains(table.clickedRow) else { return }
        pane?.openRequest(id: runner.rows[table.clickedRow].request.id, in: runner.collection.id)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { runner?.rows.count ?? 0 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { APITableRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let runner, runner.rows.indices.contains(row) else { return nil }
        let entry = runner.rows[row]
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = theme.foreground
        switch tableColumn.identifier.rawValue {
        case "request":
            let text = NSMutableAttributedString(string: APIFormat.methodLabel(entry.request.method).padding(toLength: 5, withPad: " ", startingAt: 0),
                                                 attributes: [.foregroundColor: APIFormat.methodColor(entry.request.method, theme: theme), .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)])
            text.append(NSAttributedString(string: (entry.path.map { $0.name + " / " }.joined()) + entry.request.name,
                                           attributes: [.foregroundColor: theme.foreground, .font: NSFont.systemFont(ofSize: 12)]))
            label.attributedStringValue = text
        case "status":
            label.stringValue = entry.status.map(String.init) ?? (entry.state == .running ? "…" : (entry.error == nil ? "" : "—"))
            label.textColor = entry.state == .done ? APIFormat.statusColor(entry.status, theme: theme) : theme.lineNumber
        case "time":
            label.stringValue = entry.state == .done ? APIFormat.duration(entry.duration) : ""
            label.textColor = theme.lineNumber
        case "checks":
            label.stringValue = entry.state == .done && !entry.checks.isEmpty ? "\(entry.checksPassed)/\(entry.checks.count)" : ""
            label.textColor = entry.checksPassed == entry.checks.count ? APIFormat.statusColor(200, theme: theme) : APIFormat.statusColor(500, theme: theme)
        default:
            switch entry.state {
            case .waiting: label.stringValue = "Waiting"; label.textColor = theme.lineNumber
            case .running: label.stringValue = "Sending…"; label.textColor = theme.lineNumber
            case .done:
                if let error = entry.error { label.stringValue = "✕ " + error }
                else if let failedCheck = entry.checks.first(where: { !$0.passed }) { label.stringValue = "✕ " + failedCheck.message }
                else if entry.passed == false { label.stringValue = "✕ status \(entry.status ?? 0)" }
                else { label.stringValue = "✓ Passed" }
                label.textColor = APIFormat.statusColor(entry.passed == true ? 200 : 500, theme: theme)
                label.toolTip = label.stringValue
            }
        }
        return label
    }

    func render() {}

    func applyTheme() {
        layer?.backgroundColor = theme.background.cgColor
        titleLabel.textColor = theme.foreground
        table.reloadData()
        updateHeader()
    }
}
