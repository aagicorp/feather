import AppKit

private final class QuickOpenPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class QuickOpenController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    var onOpen: ((URL) -> Void)?
    /// "#", "@" or ":" typed first: the panel closes and this takes over with the rest of the text (VS Code's
    /// symbol-anywhere, symbol-in-file and line-number modes).
    var onPrefix: ((Character, String) -> Void)?
    static let prefixes: Set<Character> = ["#", "@", ":"]

    private let panel: NSPanel
    private let field = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    struct Entry {
        let path: String          // relative to root
        let lower: [UInt8]
        let nameStart: Int

        init(path: String) {
            self.path = path
            lower = Array(path.lowercased().utf8)
            nameStart = (lower.lastIndex(of: UInt8(ascii: "/")) ?? -1) + 1
        }
    }
    static let maxResults = 60
    private var root: URL?
    private var entries: [Entry] = []
    private var results: [Entry] = []
    private var indexGeneration = 0

    override init() {
        panel = QuickOpenPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
                               styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.delegate = self
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        field.placeholderString = "Search files by name   (# symbol anywhere, @ symbol in file, : line)"
        field.font = .systemFont(ofSize: 15)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelection)
        tableView.action = #selector(openSelection)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.useFeatherScrollers()

        let content = NSView()
        for subview in [field, scrollView] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
        // The panel is a sheet of glass (macOS 26) or of the chrome colour, with rounded corners of its own.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        surface = Glass.panel(around: content, cornerRadius: 12, tint: Settings.shared.theme.chrome)
        panel.contentView = surface
    }

    private var surface: NSView?

    func show(over window: NSWindow, root: URL) {
        panel.appearance = window.appearance
        if let surface { Glass.retint(surface, Settings.shared.theme.chrome) }
        if self.root != root {
            self.root = root
            entries = []
        }
        field.stringValue = ""
        rebuildIndex(root: root)          // cheap now: the listing is cached until the file tree reports a change
        updateResults()
        let frame = window.frame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2,
                                     y: frame.maxY - panel.frame.height - 90))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func rebuildIndex(root: URL) {
        indexGeneration += 1
        let generation = indexGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = ProjectFiles.list(root: root).map(Entry.init(path:))
            DispatchQueue.main.async {
                guard let self, self.indexGeneration == generation else { return }
                self.entries = found
                self.updateResults()
            }
        }
    }

    /// Subsequence match; rewards consecutive characters, word starts, and hits inside the file name.
    static func score(_ query: [UInt8], _ entry: Entry) -> Int? {
        let text = entry.lower
        var queryIndex = 0
        var score = 0
        var previous = -2
        for (index, byte) in text.enumerated() where queryIndex < query.count && byte == query[queryIndex] {
            score += 1
            if index == previous + 1 { score += 5 }
            if index == entry.nameStart { score += 8 }
            else if index > 0 {
                let before = text[index - 1]        // "/", "_", "-" or "." (a literal array here was allocated per character)
                if before == 47 || before == 95 || before == 45 || before == 46 { score += 3 }
            }
            if index >= entry.nameStart { score += 2 }
            previous = index
            queryIndex += 1
        }
        return queryIndex == query.count ? score * 4 - text.count / 8 : nil
    }

    /// The best `maxResults` entries for what was typed, best first; the first entries in their own order for
    /// nothing. Spaces in the query are ignored. A pure function, so the ranking can be tested.
    static func topMatches(for typed: String, in entries: [Entry]) -> [Entry] {
        let query = Array(typed.lowercased().replacingOccurrences(of: " ", with: "").utf8)
        if query.isEmpty { return Array(entries.prefix(maxResults)) }
        // Score into plain (score, index) pairs — no copies of the entries — and keep only the best 60.
        var scored: [(score: Int, index: Int)] = []
        scored.reserveCapacity(min(entries.count, 4096))
        for (index, entry) in entries.enumerated() {
            if let value = score(query, entry) { scored.append((value, index)) }
        }
        if scored.count > maxResults {
            // Drop everything that cannot make the top 60 before sorting.
            let cutoff = scored.map(\.score).sorted(by: >)[maxResults - 1]
            scored = scored.filter { $0.score >= cutoff }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.prefix(maxResults).map { entries[$0.index] }
    }

    private func updateResults() {
        results = QuickOpenController.topMatches(for: field.stringValue, in: entries)
        tableView.reloadData()
        if !results.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    @objc private func openSelection() {
        let row = tableView.selectedRow
        guard let root, results.indices.contains(row) else { return }
        let url = root.appendingPathComponent(results[row].path)
        panel.orderOut(nil)
        onOpen?(url)
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let row = max(0, min(results.count - 1, tableView.selectedRow + delta))
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    // MARK: - Delegates

    func controlTextDidChange(_ obj: Notification) {
        if let first = field.stringValue.first, QuickOpenController.prefixes.contains(first), let onPrefix {
            let rest = String(field.stringValue.dropFirst())
            panel.orderOut(nil)
            onPrefix(first, rest)
            return
        }
        updateResults()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)): openSelection()
        case #selector(NSResponder.cancelOperation(_:)): panel.orderOut(nil)
        default: return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) { panel.orderOut(nil) }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("QuickOpenCell")
        let label = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField ?? {
            let label = NSTextField(labelWithString: "")
            label.identifier = identifier
            label.usesSingleLineMode = true
            label.lineBreakMode = .byTruncatingMiddle
            return label
        }()
        let path = results[row].path as NSString
        let text = NSMutableAttributedString(attributedString: FileIcon.attributed(for: URL(fileURLWithPath: path as String)))
        text.append(NSAttributedString(
            string: path.lastPathComponent,
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
        let directory = path.deletingLastPathComponent
        if !directory.isEmpty {
            text.append(NSAttributedString(
                string: "   " + directory,
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        label.attributedStringValue = text
        return label
    }
}
