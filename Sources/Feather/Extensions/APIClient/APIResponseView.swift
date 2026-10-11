import AppKit

/// The answer to a request: status, time and size in a line, then the body (pretty-printed and coloured by the
/// editor's JSON grammar), the raw text, the headers, the cookies and the checks' results. While a request is on
/// its way it shows a spinner and Cancel; an error is said in plain words.
final class APIResponseView: NSView {
    /// The status code on a pill in its colour: green 2xx, amber 3xx and 4xx, red 5xx and failures.
    private let statusPill = APIPill()
    private let statusLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let copyPathButton = NSButton(title: "Copy Path", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save to File…", target: nil, action: nil)
    private let tabs = NSSegmentedControl()
    /// Pretty-printed or as it came, for a JSON body.
    private let prettyToggle = NSSegmentedControl()
    private var header: NSStackView!
    private let container = NSView()
    var isHeaderHiddenForTests: Bool { header.isHidden }
    var statusTextForTests: String { statusPill.text }
    var statusColorForTests: NSColor { statusPill.color }
    var tabLabelsForTests: [String] { (0..<tabs.segmentCount).map { tabs.label(forSegment: $0) ?? "" } }
    private let message = NSTextField(wrappingLabelWithString: "")
    /// Shown in the middle of the area until something is sent: an icon and one line.
    private let emptyState = NSStackView()
    private let emptyIcon = NSImageView()
    private let emptyTitle = NSTextField(labelWithString: "Send the request to see the answer here")
    private let emptyHint = NSTextField(labelWithString: "⌘↩ sends. The status, time, body, headers and cookies appear in this space.")

    private var bodyEditor: EditorView?
    private var bodyDocument: TextDocument?
    private let rawScroll = NSScrollView()
    private let rawText = NSTextView()
    private let headersTable = APIReadOnlyTable(columns: [("Header", 180), ("Value", nil)])
    private let cookiesTable = APIReadOnlyTable(columns: [("Cookie", 140), ("Value", nil), ("Domain", 120), ("Path", 80), ("Expires", 140)])
    private let checksTable = APIReadOnlyTable(columns: [("", 24), ("Check", nil), ("Answer had", 200)])

    private(set) var response: APIResponse?
    private(set) var checks: [APIChecks.Result] = []
    private var prettyBody = ""
    var onCancel: (() -> Void)?
    var onCopyPath: ((String) -> Void)?

    /// Bodies over this are shown as plain text: no pretty-printing, no grammar.
    static let prettyLimit = 5 * 1024 * 1024

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        build()
        showEmpty()
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var theme: Theme { Settings.shared.theme }

    private func build() {
        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for (button, action, tip) in [(cancelButton, #selector(cancelClicked), "Stop waiting for the answer (Esc)"),
                                      (copyButton, #selector(copyClicked), "Copy the body"),
                                      (copyPathButton, #selector(copyPathClicked), "Copy the path of the JSON value under the caret, for a check or a variable"),
                                      (saveButton, #selector(saveClicked), "Save the body as a file")] {
            button.bezelStyle = .recessed
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.target = self
            button.action = action
            button.toolTip = tip
        }
        // The actions as icons, together at the right; their titles stay for accessibility.
        for (button, symbol) in [(copyButton, "doc.on.doc"), (copyPathButton, "curlybraces"), (saveButton, "square.and.arrow.down")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.title)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel(button.title)
            button.title = ""
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        }
        tabs.segmentCount = 4
        for (index, label) in ["Body", "Headers", "Cookies", "Checks"].enumerated() { tabs.setLabel(label, forSegment: index) }
        tabs.trackingMode = .selectOne
        tabs.controlSize = .small
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)
        prettyToggle.segmentCount = 2
        prettyToggle.setLabel("Pretty", forSegment: 0)
        prettyToggle.setLabel("Raw", forSegment: 1)
        prettyToggle.trackingMode = .selectOne
        prettyToggle.controlSize = .mini
        prettyToggle.selectedSegment = 0
        prettyToggle.target = self
        prettyToggle.action = #selector(tabChanged)
        prettyToggle.toolTip = "The body pretty-printed, or exactly as it came"
        timeLabel.toolTip = "How long the answer took"
        sizeLabel.toolTip = "The size of the body"

        header = NSStackView(views: [statusPill, statusLabel, timeLabel, sizeLabel, spinner, cancelButton, NSView(), tabs, prettyToggle, copyButton, copyPathButton, saveButton])
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        message.font = .systemFont(ofSize: 12)
        message.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(container)
        addSubview(message)
        emptyIcon.image = NSImage(systemSymbolName: "paperplane", accessibilityDescription: nil)
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .light)
        emptyTitle.font = .systemFont(ofSize: 13, weight: .medium)
        emptyTitle.alignment = .center
        emptyHint.font = .systemFont(ofSize: 11.5)
        emptyHint.alignment = .center
        emptyHint.lineBreakMode = .byWordWrapping
        emptyHint.maximumNumberOfLines = 2
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        emptyState.addArrangedSubview(emptyIcon)
        emptyState.addArrangedSubview(emptyTitle)
        emptyState.addArrangedSubview(emptyHint)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            container.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            message.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            message.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])

        rawText.isEditable = false
        rawText.isRichText = false
        rawText.usesFindBar = true
        rawText.isIncrementalSearchingEnabled = true
        rawText.isHorizontallyResizable = false
        rawText.isVerticallyResizable = true
        rawText.autoresizingMask = [.width]
        rawText.textContainerInset = NSSize(width: 6, height: 6)
        rawText.textContainer?.widthTracksTextView = true
        rawScroll.documentView = rawText
        rawScroll.hasVerticalScroller = true
        rawScroll.autohidesScrollers = true
        rawScroll.borderType = .noBorder
        rawScroll.useFeatherScrollers()
    }

    // MARK: States

    private func showEmpty() {
        response = nil
        checks = []
        // Until something is sent the empty state speaks alone; the header has nothing to say yet.
        header.isHidden = true
        statusPill.text = ""
        statusLabel.stringValue = ""
        statusLabel.textColor = theme.lineNumber
        prettyToggle.isHidden = true
        timeLabel.stringValue = ""
        sizeLabel.stringValue = ""
        spinner.stopAnimation(nil)
        cancelButton.isHidden = true
        setButtons(hidden: true)
        tabs.isHidden = true
        message.stringValue = ""
        message.textColor = theme.lineNumber
        message.isHidden = true
        emptyIcon.contentTintColor = theme.lineNumber
        emptyTitle.textColor = theme.foreground.withAlphaComponent(0.8)
        emptyHint.textColor = theme.lineNumber
        emptyState.isHidden = false
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    func showSending() {
        showEmpty()
        emptyState.isHidden = true
        header.isHidden = false
        statusLabel.stringValue = "Sending…"
        message.stringValue = ""
        spinner.startAnimation(nil)
        cancelButton.isHidden = false
    }

    func showCancelled() {
        showEmpty()
        emptyState.isHidden = true
        message.stringValue = "Cancelled."
        message.isHidden = false
    }

    func show(_ result: Result<APIResponse, APIRequestSender.Failure>, checks: [APIChecks.Result]) {
        spinner.stopAnimation(nil)
        cancelButton.isHidden = true
        switch result {
        case .failure(let failure):
            showEmpty()
            emptyState.isHidden = true
            header.isHidden = false
            statusPill.text = "No answer"
            statusPill.color = APIFormat.statusColor(nil, theme: theme)
            message.stringValue = failure.message
            message.textColor = theme.foreground
            message.isHidden = false
        case .success(let response):
            self.response = response
            self.checks = checks
            header.isHidden = false
            statusPill.text = "\(response.status) " + (response.status == 200 ? "OK" : response.statusText)
            statusPill.color = APIFormat.statusColor(response.status, theme: theme)
            statusLabel.stringValue = ""
            timeLabel.stringValue = APIFormat.duration(response.duration)
            sizeLabel.stringValue = APIFormat.size(response.size)
            timeLabel.textColor = theme.lineNumber
            sizeLabel.textColor = theme.lineNumber
            message.isHidden = true
            emptyState.isHidden = true
            tabs.isHidden = false
            let failed = checks.filter { !$0.passed }.count
            tabs.setLabel(checks.isEmpty ? "Checks" : "Checks \(checks.count - failed)/\(checks.count)" + (failed > 0 ? " ✕" : " ✓"), forSegment: 3)
            tabs.setLabel("Headers \(response.headers.count)", forSegment: 1)
            tabs.setLabel(response.cookies.isEmpty ? "Cookies" : "Cookies \(response.cookies.count)", forSegment: 2)
            prettyBody = response.bodyFile == nil && response.size <= APIResponseView.prettyLimit && response.isJSON
                ? APIFormat.prettyJSON(response.text) : response.text
            headersTable.rows = response.headers.map { [$0.name, $0.value] }
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            cookiesTable.rows = response.cookies.map { cookie in
                var flags: [String] = []
                if cookie.secure { flags.append("Secure") }
                if cookie.httpOnly { flags.append("HttpOnly") }
                if let sameSite = cookie.sameSite { flags.append("SameSite=" + sameSite) }
                let when = (cookie.expires.map(formatter.string) ?? "Session") + (flags.isEmpty ? "" : "  " + flags.joined(separator: " "))
                return [cookie.name, cookie.value, cookie.domain, cookie.path, cookie.notStored.map { when + "  — " + $0 } ?? when]
            }
            checksTable.rows = checks.map { [$0.passed ? "✓" : "✕", $0.message, $0.actual] }
            checksTable.rowColor = { [weak self] row in
                guard let self, self.checks.indices.contains(row) else { return nil }
                return APIFormat.statusColor(self.checks[row].passed ? 200 : 500, theme: self.theme)
            }
            // A failed check is what the person wants to see first.
            if failed > 0 { tabs.selectedSegment = 3 } else if tabs.selectedSegment == 3 { tabs.selectedSegment = 0 }
            showTab()
        }
    }

    private func setButtons(hidden: Bool) {
        copyButton.isHidden = hidden
        copyPathButton.isHidden = hidden
        saveButton.isHidden = hidden
    }

    @objc private func tabChanged() { showTab() }

    private func showTab() {
        guard let response else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        let content: NSView
        let isBodyTab = tabs.selectedSegment == 0
        let canPretty = response.isJSON && response.bodyFile == nil && response.size <= APIResponseView.prettyLimit
        let showsPretty = canPretty && prettyToggle.selectedSegment == 0
        setButtons(hidden: !isBodyTab)
        prettyToggle.isHidden = !(isBodyTab && canPretty)
        saveButton.isHidden = !isBodyTab
        copyPathButton.isHidden = !(isBodyTab && showsPretty)
        copyButton.isHidden = !isBodyTab || response.bodyFile != nil
        switch tabs.selectedSegment {
        case 0:
            if response.bodyFile != nil {
                content = largeBodyNotice(response)
            } else if showsPretty || !response.isJSON {
                content = bodyEditorView(for: response)
            } else {
                rawText.string = response.text
                rawText.font = Settings.shared.editorFont
                rawText.textColor = theme.foreground
                rawText.backgroundColor = theme.background
                content = rawScroll
            }
        case 1: content = headersTable
        case 2: content = cookiesTable
        default: content = checksTable
        }
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
    }

    private func largeBodyNotice(_ response: APIResponse) -> NSView {
        let label = NSTextField(wrappingLabelWithString: "The answer is \(APIFormat.size(response.size)), too large to show here. Save it to a file to look at it.")
        label.font = .systemFont(ofSize: 12)
        label.textColor = theme.lineNumber
        let box = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
        ])
        return box
    }

    /// A read-only editor on a document of its own, so the JSON grammar colours and folds the body and ⌘F finds in it.
    private func bodyEditorView(for response: APIResponse) -> NSView {
        let document = bodyDocument ?? TextDocument()
        let type = response.contentType.lowercased()
        let ext = response.size > APIResponseView.prettyLimit ? "txt"
            : (response.isJSON ? "json" : (type.contains("html") ? "html" : (type.contains("xml") ? "xml" : "txt")))
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("feather-api-answer.\(ext)")
        if document.url != url { document.url = url }
        document.replaceAll(with: prettyBody)
        document.isDirty = false
        if bodyDocument == nil {
            bodyDocument = document
            let editor = EditorView(document: document)
            editor.textView.isEditable = false
            bodyEditor = editor
        }
        bodyEditor?.applySettings()
        bodyEditor?.textView.setSelectedRange(NSRange(location: 0, length: 0))
        return bodyEditor ?? NSView()
    }

    // MARK: Buttons

    @objc private func cancelClicked() { onCancel?() }

    @objc private func copyClicked() {
        guard response != nil else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prettyToggle.selectedSegment == 0 ? prettyBody : (response?.text ?? ""), forType: .string)
    }

    @objc private func copyPathClicked() {
        guard let editor = bodyEditor else { return }
        let caret = editor.textView.selectedRange().location
        guard let path = APIFormat.jsonPath(at: caret, in: prettyBody) else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        onCopyPath?(path)
    }

    @objc private func saveClicked() {
        guard let response, let window else { return }
        let panel = NSSavePanel()
        let ext = response.isJSON ? "json" : "txt"
        panel.nameFieldStringValue = "answer.\(ext)"
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            if let file = response.bodyFile {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.copyItem(at: file, to: url)
            } else {
                try? response.body.write(to: url)
            }
        }
    }

    func applyTheme() {
        layer?.backgroundColor = theme.background.cgColor
        message.textColor = response == nil ? theme.lineNumber : theme.foreground
        headersTable.applyTheme()
        cookiesTable.applyTheme()
        checksTable.applyTheme()
        bodyEditor?.applySettings()
        if let response { statusPill.color = APIFormat.statusColor(response.status, theme: theme); showTab() } else { statusLabel.textColor = theme.lineNumber }
    }
}

/// A plain table of text, for headers, cookies and check results. Rows can be selected and copied (⌘C).
final class APIReadOnlyTable: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let scrollView = NSScrollView()
    var rows: [[String]] = [] { didSet { table.reloadData() } }
    /// A colour for the first column of a row, when it has one (✓ and ✕).
    var rowColor: ((Int) -> NSColor?)?

    init(columns: [(title: String, width: CGFloat?)]) {
        super.init(frame: .zero)
        for (index, column) in columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            tableColumn.title = column.title
            if let width = column.width { tableColumn.width = width; tableColumn.minWidth = width; tableColumn.maxWidth = width }
            else { tableColumn.minWidth = 80 }
            table.addTableColumn(tableColumn)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = 20
        table.style = .plain
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.useFeatherScrollers()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyTheme() { table.reloadData() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { APITableRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Int(tableColumn.identifier.rawValue), rows.indices.contains(row), rows[row].indices.contains(column) else { return nil }
        let label = NSTextField(labelWithString: rows[row][column])
        label.font = .monospacedSystemFont(ofSize: 11.5, weight: column == 0 ? .semibold : .regular)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = (column == 0 ? rowColor?(row) : nil) ?? Settings.shared.theme.foreground
        label.toolTip = rows[row][column]
        return label
    }

    @objc func copy(_ sender: Any?) {
        let text = table.selectedRowIndexes.map { rows[$0].joined(separator: "\t") }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
