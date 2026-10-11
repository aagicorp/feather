import AppKit

final class SearchFileResult: NSObject {
    let url: URL
    let relativePath: String
    var matches: [SearchMatch] = []

    init(url: URL, relativePath: String) {
        self.url = url
        self.relativePath = relativePath
    }
}

final class SearchMatch: NSObject {
    let url: URL
    let line: Int          // one-based
    let column: Int        // UTF-16 offset within the line
    let length: Int
    let preview: String
    let previewHighlight: NSRange

    init(url: URL, line: Int, column: Int, length: Int, preview: String, previewHighlight: NSRange) {
        self.url = url
        self.line = line
        self.column = column
        self.length = length
        self.preview = preview
        self.previewHighlight = previewHighlight
    }
}

enum ProjectSearch {
    static let maxFileSize = 2_000_000
    static let maxMatches = 5_000
    /// Rows listed per file; the file's replacement still covers every match.
    static let maxMatchesPerFile = 200
    private static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "ico", "icns", "bmp", "tiff", "pdf", "zip", "gz", "tar", "tgz", "jar", "war",
        "class", "o", "a", "so", "dylib", "exe", "dll", "bin", "woff", "woff2", "ttf", "otf", "eot", "mp3", "mp4", "mov", "wav",
        "sqlite", "db", "lock",
    ]

    static func run(root: URL, query: String, caseSensitive: Bool, isCancelled: @escaping () -> Bool) -> [SearchFileResult] {
        run(root: root, query: query, options: SearchOptions(caseSensitive: caseSensitive), isCancelled: isCancelled)
    }

    /// Every match of `query` under the project, by file. A plain search (no whole word, no regex) first looks for
    /// the text with a string search, which is far cheaper than a regular expression over thousands of files; the
    /// regular expression is then used only on the files that contain it, so the rows it makes are the very ones a
    /// replacement would change.
    /// `openTexts` holds the text of files being edited, by URL, so a match that was just typed (or replaced)
    /// is found (or gone) before the file is saved, as in VS Code.
    static func run(root: URL, query: String, options: SearchOptions, openTexts: [URL: String] = [:],
                    isCancelled: @escaping () -> Bool) -> [SearchFileResult] {
        guard let regex = options.regex(for: query) else { return [] }
        let files = ProjectFiles.list(root: root, isCancelled: isCancelled)
        if isCancelled() { return [] }
        let literal: (String, NSString.CompareOptions)? = options.isRegex ? nil : (query, options.caseSensitive ? [.literal] : [.caseInsensitive])
        let lock = NSLock()
        var results: [SearchFileResult] = []
        var total = 0

        DispatchQueue.concurrentPerform(iterations: files.count) { index in autoreleasepool {
            // Without its own pool, bridged strings from thousands of files pile up until the whole search ends.
            if isCancelled() { return }
            lock.lock(); let full = total >= maxMatches; lock.unlock()
            if full { return }
            let url = root.appendingPathComponent(files[index])
            // Size and type are checked before the file is opened, so a huge or binary file is never read at all.
            if binaryExtensions.contains(url.pathExtension.lowercased()) { return }
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maxFileSize { return }
            let text: String
            if let open = openTexts.isEmpty ? nil : openTexts[url.standardizedFileURL] {
                text = open
            } else {
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      data.count <= maxFileSize, !data.prefix(4096).contains(0),
                      let read = String(data: data, encoding: .utf8) else { return }
                text = read
            }
            if let literal, text.range(of: literal.0, options: literal.1) == nil { return }
            let ns = text as NSString
            guard regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) != nil else { return }

            let result = SearchFileResult(url: url, relativePath: files[index])
            var lineNumber = 0
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { line, lineRange, _, stop in
                lineNumber += 1
                guard let line else { return }
                for match in regex.matches(in: text, options: [], range: lineRange) where match.range.length > 0 {
                    let found = NSRange(location: match.range.location - lineRange.location, length: match.range.length)
                    result.matches.append(makeMatch(url: url, line: lineNumber, lineText: line as NSString, found: found))
                    if result.matches.count >= maxMatchesPerFile { stop.pointee = true; return }
                }
            }
            guard !result.matches.isEmpty else { return }
            lock.lock()
            results.append(result)
            total += result.matches.count
            lock.unlock()
        } }
        return results.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    /// The text of a file the project search would read, under the same rules: not a known binary type, not
    /// over the size limit, no NUL bytes near the start, valid UTF-8. The TODO scan reads files through this.
    static func searchableText(at url: URL) -> String? {
        if binaryExtensions.contains(url.pathExtension.lowercased()) { return nil }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maxFileSize { return nil }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= maxFileSize, !data.prefix(4096).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Turns language-server locations into the same result rows the text search produces.
    static func results(for locations: [LSPLocation], root: URL?, text: (URL) -> String?) -> [SearchFileResult] {
        var byFile: [URL: SearchFileResult] = [:]
        var lines: [URL: [String]] = [:]
        for location in locations {
            let url = location.url
            if lines[url] == nil { lines[url] = (text(url) ?? "").components(separatedBy: "\n") }
            guard let fileLines = lines[url], location.line < fileLines.count else { continue }
            let lineText = fileLines[location.line] as NSString
            let start = min(location.character, lineText.length)
            let length = location.endLine == location.line ? max(0, min(location.endCharacter, lineText.length) - start) : lineText.length - start
            var relative = url.path
            if let root, relative.hasPrefix(root.path + "/") { relative = String(relative.dropFirst(root.path.count + 1)) }
            let file = byFile[url] ?? SearchFileResult(url: url, relativePath: relative)
            byFile[url] = file
            file.matches.append(makeMatch(url: url, line: location.line + 1, lineText: lineText,
                                          found: NSRange(location: start, length: length)))
        }
        return byFile.values.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    /// Trims indentation and very long lines so the match stays visible in a narrow sidebar.
    private static func makeMatch(url: URL, line: Int, lineText: NSString, found: NSRange) -> SearchMatch {
        var start = 0
        while start < lineText.length, let scalar = UnicodeScalar(lineText.character(at: start)),
              CharacterSet.whitespaces.contains(scalar) { start += 1 }
        var prefix = ""
        if found.location - start > 40 {
            start = found.location - 30
            prefix = "…"
        }
        let end = min(lineText.length, start + 220)
        let preview = prefix + lineText.substring(with: NSRange(location: start, length: end - start))
        let highlight = NSRange(location: found.location - start + (prefix as NSString).length,
                                length: min(found.length, end - found.location))
        return SearchMatch(url: url, line: line, column: found.location, length: found.length,
                           preview: preview, previewHighlight: highlight)
    }
}

/// What the Search pane asks the window to replace: the query as it stands, the replacement text, and which
/// of the results. `only` narrows it to particular matches; nil means every match in `files`, listed or not.
struct ReplaceRequest {
    let query: String
    let options: SearchOptions
    let replacement: String
    let files: [SearchFileResult]
    let only: [URL: Set<MatchPlace>]?
    /// True for the Replace All button, which shows a preview first; a row's own button replaces straight away.
    let wantsPreview: Bool

    var regex: NSRegularExpression? { options.regex(for: query) }
}

final class SearchViewController: NSViewController, NSSearchFieldDelegate, NSTextFieldDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onOpenMatch: ((SearchMatch) -> Void)?
    /// Replace All, a row's Replace, a file's Replace All in File: the window does the work (see ReplaceInProject.swift).
    var onReplace: ((ReplaceRequest) -> Void)?
    /// The text of the files with unsaved edits, so the search sees what the editor shows.
    var openTexts: (() -> [URL: String])?
    var rootURL: URL? { didSet { if rootURL != oldValue { clear() } } }

    private let field = NSSearchField()
    private let caseButton = NSButton(title: "Aa", target: nil, action: nil)
    private let wordButton = NSButton(title: "ab", target: nil, action: nil)
    private let regexButton = NSButton(title: ".*", target: nil, action: nil)
    private let toggleButton = NSButton(title: "", target: nil, action: nil)
    private let replaceField = NSTextField()
    private let replaceAllButton = NSButton(title: "Replace All", target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")
    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private var summaryTop: NSLayoutConstraint?
    private var replaceAction: RowHoverAction?
    private var results: [SearchFileResult] = []
    private var generation = 0
    private var debounce: DispatchWorkItem?
    /// The query the rows on screen were found with, so a replacement uses what was searched, not what has been
    /// typed since.
    private var shownQuery: (query: String, options: SearchOptions)?
    private(set) var isReplaceShown = false

    var options: SearchOptions {
        SearchOptions(caseSensitive: caseButton.state == .on, wholeWord: wordButton.state == .on, isRegex: regexButton.state == .on)
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))

        field.placeholderString = "Search in project"
        field.delegate = self
        field.target = self
        field.action = #selector(searchNow)
        field.sendsWholeSearchString = true
        field.controlSize = .small
        field.font = .systemFont(ofSize: 12)

        for (button, tip) in [(caseButton, "Match Case"), (wordButton, "Match Whole Word"), (regexButton, "Use Regular Expression")] {
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .recessed
            button.controlSize = .small
            button.font = .systemFont(ofSize: 10, weight: .medium)
            button.toolTip = tip
            button.target = self
            button.action = #selector(searchNow)
        }

        toggleButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Show Replace")
        toggleButton.isBordered = false
        toggleButton.imagePosition = .imageOnly
        toggleButton.toolTip = "Show or hide the Replace field (⇧⌘H)"
        toggleButton.target = self
        toggleButton.action = #selector(toggleReplace)

        replaceField.placeholderString = "Replace"
        replaceField.delegate = self
        replaceField.target = self
        replaceField.action = #selector(searchNow)
        replaceField.controlSize = .small
        replaceField.font = .systemFont(ofSize: 12)
        replaceField.isHidden = true
        replaceAllButton.bezelStyle = .recessed
        replaceAllButton.controlSize = .small
        replaceAllButton.font = .systemFont(ofSize: 10.5, weight: .medium)
        replaceAllButton.toolTip = "Replace every result, after showing what will change"
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAllClicked)
        replaceAllButton.isHidden = true

        summary.font = .systemFont(ofSize: 11)
        summary.lineBreakMode = .byTruncatingTail

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 20
        outlineView.indentationPerLevel = 10
        outlineView.style = .plain
        outlineView.backgroundColor = .clear
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true         // long lines scroll sideways instead of being cut off
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        column.resizingMask = []
        outlineView.columnAutoresizingStyle = .noColumnAutoresizing
        outlineView.autoresizesOutlineColumn = false
        // One button, moved from row to row: "Replace" on a match, "Replace All in File" on a file. Only while the
        // Replace field is showing, as in VS Code.
        let action = RowHoverAction(table: outlineView, toolTip: "Replace this with the Replace field's text",
                                    title: { [weak self] in self?.outlineView.item(atRow: $0) is SearchFileResult ? "Replace All in File" : "Replace" },
                                    isEligible: { [weak self] in
            guard let self, self.rootURL != nil, self.onReplace != nil else { return false }
            let item = self.outlineView.item(atRow: $0)
            return item is SearchMatch || item is SearchFileResult
        }, perform: { [weak self] in self?.replaceRow($0) })
        action.isEnabled = false
        replaceAction = action

        for subview in [toggleButton, field, caseButton, wordButton, regexButton, replaceField, replaceAllButton, summary, scrollView] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let summaryTop = summary.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 7)
        self.summaryTop = summaryTop
        NSLayoutConstraint.activate([
            toggleButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            toggleButton.widthAnchor.constraint(equalToConstant: 16),
            toggleButton.topAnchor.constraint(equalTo: field.topAnchor),
            toggleButton.bottomAnchor.constraint(equalTo: replaceField.bottomAnchor),
            field.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            field.leadingAnchor.constraint(equalTo: toggleButton.trailingAnchor, constant: 2),
            caseButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 4),
            wordButton.leadingAnchor.constraint(equalTo: caseButton.trailingAnchor, constant: 2),
            regexButton.leadingAnchor.constraint(equalTo: wordButton.trailingAnchor, constant: 2),
            regexButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            caseButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            wordButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            regexButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            caseButton.widthAnchor.constraint(equalToConstant: 24),
            wordButton.widthAnchor.constraint(equalToConstant: 24),
            regexButton.widthAnchor.constraint(equalToConstant: 24),
            replaceField.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 4),
            replaceField.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            replaceAllButton.leadingAnchor.constraint(equalTo: replaceField.trailingAnchor, constant: 4),
            replaceAllButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            replaceAllButton.centerYAnchor.constraint(equalTo: replaceField.centerYAnchor),
            summaryTop,
            summary.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            summary.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 5),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        applyTheme()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyColumnWidth()              // every frame of a sidebar drag: must not look at the results
    }

    /// The column is as wide as the longest row, and never narrower than the pane, so short result sets
    /// fill the sidebar and long lines can be scrolled to.
    private var contentWidth: CGFloat = 0

    /// Measured once, when the results change.
    private func fitColumnToContent() {
        var longest = 0
        for file in results {
            longest = max(longest, file.relativePath.utf16.count + 8)
            for match in file.matches.prefix(400) { longest = max(longest, match.preview.utf16.count) }
        }
        // Previews are monospaced 11pt (about 6.7pt a character); add room for indentation and the disclosure arrow.
        contentWidth = min(CGFloat(longest) * 6.7 + 48, 2400)
        applyColumnWidth()
    }

    private func applyColumnWidth() {
        guard isViewLoaded, let column = outlineView.tableColumns.first else { return }
        let width = max(scrollView.contentSize.width, contentWidth)
        if abs(column.width - width) > 0.5 { column.width = width }
    }

    func applyTheme() {
        guard isViewLoaded else { return }
        summary.textColor = Settings.shared.theme.lineNumber
        toggleButton.contentTintColor = Settings.shared.theme.lineNumber
        outlineView.reloadData()
    }

    func focus(prefill: String?) {
        _ = view
        if let prefill, !prefill.isEmpty, !prefill.contains("\n") {
            field.stringValue = prefill
            searchNow()
        }
        view.window?.makeFirstResponder(field)
    }

    // MARK: - Replace

    /// Shows or hides the Replace row. Showing it also puts the keyboard in the Replace field when there is
    /// already something to search for.
    func showReplace(_ shown: Bool, focusing: Bool = false) {
        _ = view
        isReplaceShown = shown
        replaceField.isHidden = !shown
        replaceAllButton.isHidden = !shown
        toggleButton.image = NSImage(systemSymbolName: shown ? "chevron.down" : "chevron.right", accessibilityDescription: shown ? "Hide Replace" : "Show Replace")
        summaryTop?.isActive = false
        summaryTop = summary.topAnchor.constraint(equalTo: shown ? replaceField.bottomAnchor : field.bottomAnchor, constant: 7)
        summaryTop?.isActive = true
        replaceAction?.isEnabled = shown
        if focusing { view.window?.makeFirstResponder(shown && !field.stringValue.isEmpty ? replaceField : field) }
    }

    @objc private func toggleReplace() { showReplace(!isReplaceShown, focusing: true) }

    /// For the tests and the menu: the same as typing in the Replace field.
    var replacement: String {
        get { replaceField.stringValue }
        set { _ = view; replaceField.stringValue = newValue }
    }

    @objc private func replaceAllClicked() {
        guard let shown = shownQuery, !results.isEmpty else { NSSound.beep(); return }
        onReplace?(ReplaceRequest(query: shown.query, options: shown.options, replacement: replaceField.stringValue,
                                  files: results, only: nil, wantsPreview: true))
    }

    /// A match row's Replace, or a file row's Replace All in File.
    private func replaceRow(_ row: Int) {
        guard let shown = shownQuery else { return }
        let item = outlineView.item(atRow: row)
        if let match = item as? SearchMatch, let file = results.first(where: { $0.url == match.url }) {
            onReplace?(ReplaceRequest(query: shown.query, options: shown.options, replacement: replaceField.stringValue,
                                      files: [file], only: [file.url: [MatchPlace(line: match.line, column: match.column)]], wantsPreview: false))
        } else if let file = item as? SearchFileResult {
            onReplace?(ReplaceRequest(query: shown.query, options: shown.options, replacement: replaceField.stringValue,
                                      files: [file], only: nil, wantsPreview: false))
        }
    }

    /// Runs the search again with the same query, after files changed under it.
    func refresh() {
        guard isViewLoaded, shownQuery != nil else { return }
        searchNow()
    }

    // MARK: - Searching

    func show(_ newResults: [SearchFileResult], summary text: String) {
        _ = view
        debounce?.cancel()
        generation += 1
        results = newResults
        shownQuery = nil                   // references are not something Replace All should act on
        summary.stringValue = text
        replaceAction?.hide()
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        fitColumnToContent()
    }

    private func clear() {
        generation += 1
        results = []
        shownQuery = nil
        if isViewLoaded {
            summary.stringValue = ""
            replaceAction?.hide()
            outlineView.reloadData()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as AnyObject?) === field else { return }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.searchNow() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    @objc private func searchNow() {
        debounce?.cancel()
        let query = field.stringValue
        guard let rootURL else {
            summary.stringValue = "Open a folder to search"
            return
        }
        let options = options
        guard query.count >= (options.isRegex ? 1 : 2) else { clear(); return }
        guard options.regex(for: query) != nil else {
            clear()
            summary.stringValue = "This is not a valid regular expression"
            return
        }
        generation += 1
        let current = generation
        summary.stringValue = "Searching…"
        let openTexts = self.openTexts?() ?? [:]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = ProjectSearch.run(root: rootURL, query: query, options: options, openTexts: openTexts) {
                self?.generation != current
            }
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.results = found
                self.shownQuery = (query, options)
                let count = found.reduce(0) { $0 + $1.matches.count }
                self.summary.stringValue = count == 0 ? "No results"
                    : "\(count)\(count >= ProjectSearch.maxMatches ? "+" : "") result\(count == 1 ? "" : "s") in \(found.count) file\(found.count == 1 ? "" : "s")"
                self.replaceAction?.hide()
                self.outlineView.reloadData()
                if count <= 400 { self.outlineView.expandItem(nil, expandChildren: true) }
                self.fitColumnToContent()
                self.scrollView.contentView.scroll(to: .zero)          // a new search starts at the top-left
                self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            }
        }
    }

    @objc private func rowClicked() {
        let item = outlineView.item(atRow: outlineView.clickedRow)
        if let match = item as? SearchMatch {
            onOpenMatch?(match)
        } else if let file = item as? SearchFileResult {
            if outlineView.isItemExpanded(file) { outlineView.collapseItem(file) } else { outlineView.expandItem(file) }
        }
    }

    // MARK: - Outline view

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SearchFileResult)?.matches.count ?? (item == nil ? results.count : 0)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SearchFileResult)?.matches[index] ?? results[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SearchFileResult
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("SearchCell")
        let label = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField ?? {
            let label = NSTextField(labelWithString: "")
            label.identifier = identifier
            label.usesSingleLineMode = true
            label.lineBreakMode = .byClipping            // the pane scrolls; nothing is elided
            return label
        }()
        let theme = Settings.shared.theme
        if let file = item as? SearchFileResult {
            let path = file.relativePath as NSString
            let text = NSMutableAttributedString(attributedString: FileIcon.attributed(for: file.url))
            text.append(NSAttributedString(
                string: path.lastPathComponent,
                attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: theme.foreground]))
            text.append(NSAttributedString(
                string: "  \(path.deletingLastPathComponent)  (\(file.matches.count))",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: theme.lineNumber]))
            label.attributedStringValue = text
        } else if let match = item as? SearchMatch {
            let text = NSMutableAttributedString(
                string: match.preview,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                             .foregroundColor: theme.lineNumber])
            if NSMaxRange(match.previewHighlight) <= text.length {
                text.addAttributes([.foregroundColor: theme.foreground, .backgroundColor: theme.selection],
                                   range: match.previewHighlight)
            }
            label.attributedStringValue = text
        }
        return label
    }
}

/// Hosts the sidebar panes; the window's activity bar (ActivityBar.swift) switches between them.
final class SidebarContainerViewController: NSViewController {
    let explorer = SidebarViewController()
    let search = SearchViewController()
    let sourceControl = SourceControlViewController()
    let problems = ProblemsViewController()
    let activity = ActivityViewController()
    /// The file being edited, so Source Control can open on the repository that owns it.
    var activeFile: (() -> URL?)?
    private let content = NSView()
    /// The built-in panes, then any an extension added (Extensions.swift); a pane's index is its place in the
    /// activity bar (ActivityBar.swift), which the window owns.
    private var panes: [NSViewController] = []
    private var extensionPanes: [(symbol: String, tooltip: String)] = []
    private(set) var shownPane = 0
    /// Told whenever the list of panes or the shown pane changes, so the activity bar can follow.
    var onPanesChanged: (() -> Void)?

    /// The Source Control icon's place in the bar; it carries the count of changed files.
    static let sourceControlPane = 2
    static let problemsPane = 3
    static let activityPane = 4
    static let builtInItems: [ActivityBar.Item] = [
        .init(symbol: "folder", tooltip: "Explorer (⇧⌘E)"),
        .init(symbol: "magnifyingglass", tooltip: "Search in Project (⇧⌘F)"),
        .init(symbol: "arrow.triangle.branch", tooltip: "Source Control (⌃⇧G)"),
        .init(symbol: "exclamationmark.triangle", tooltip: "Problems and TODOs (⇧⌘M)"),
        .init(symbol: "clock.arrow.circlepath", tooltip: "Activity: what changed since your checkpoint (⌃⇧A)"),
    ]

    /// Every pane's icon and tooltip, built-ins first.
    var barItems: [ActivityBar.Item] {
        SidebarContainerViewController.builtInItems + extensionPanes.map { ActivityBar.Item(symbol: $0.symbol, tooltip: $0.tooltip) }
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        view.wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        panes = [explorer, search, sourceControl, problems, activity]
        panes.forEach(addChild)
        show(pane: 0)
    }

    /// Adds a pane at the end of the activity bar; returns its index. Used by extensions while they are on.
    @discardableResult
    func addPane(_ controller: NSViewController, symbol: String, tooltip: String) -> Int {
        _ = view
        panes.append(controller)
        extensionPanes.append((symbol, tooltip))
        addChild(controller)
        onPanesChanged?()
        return panes.count - 1
    }

    /// Takes an extension's pane away again; the built-in panes keep their indices.
    func removePane(_ controller: NSViewController) {
        guard let index = panes.firstIndex(where: { $0 === controller }), index >= SidebarContainerViewController.builtInItems.count else { return }
        panes.remove(at: index)
        extensionPanes.remove(at: index - SidebarContainerViewController.builtInItems.count)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        if shownPane == index { shownPane = 0 } else if shownPane > index { shownPane -= 1 }
        show(pane: shownPane)
    }

    /// The index of a pane, for showing it (`show(pane:)`).
    func index(of controller: NSViewController) -> Int? { panes.firstIndex { $0 === controller } }

    func applyTheme() {
        explorer.applyTheme()
        search.applyTheme()
        sourceControl.applyTheme()
        problems.applyTheme()
        activity.applyTheme()
    }

    func show(pane: Int) {
        _ = view
        let pane = max(0, min(panes.count - 1, pane))
        shownPane = pane
        onPanesChanged?()
        let child = panes[pane].view
        if pane >= SidebarContainerViewController.builtInItems.count { (panes[pane] as? ExtensionPane)?.paneDidAppear() }
        if pane == SidebarContainerViewController.problemsPane { problems.paneDidAppear() }
        if pane == 2 { sourceControl.discover(preferring: activeFile?()) }
        if pane == 0, Settings.shared.revealInExplorer, let file = activeFile?() {
            // After the pane is back in the window, so the row can be scrolled to.
            DispatchQueue.main.async { [weak self] in self?.explorer.reveal(file) }
        }
        guard child.superview !== content else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        child.frame = content.bounds
        child.autoresizingMask = [.width, .height]
        content.addSubview(child)
        child.applyFeatherScrollers()
    }
}
