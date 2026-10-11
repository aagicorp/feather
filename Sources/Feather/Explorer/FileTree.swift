import AppKit

final class FileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    /// Ignored by git (.gitignore and friends). Everything inside an ignored folder is ignored too.
    var isIgnored = false
    /// Whether git has been asked about this folder's children since they were last read from disk.
    var ignoreChecked = false
    private var loadedChildren: [FileNode]?
    /// A row that exists only while its name is being typed (New File / New Folder); nothing is on disk yet.
    var isPlaceholder = false
    /// The folder this node was read from; nil for the root.
    private(set) weak var parent: FileNode?
    /// Folders above this one that had nothing but it inside, folded into its row ("com › aagicorp › iam"),
    /// as VS Code's compact folders do. Set by the explorer whenever a folder's rows are listed.
    var compactedNames: [String] = []
    /// A folder folded into a descendant's row; it is never an outline item itself.
    var isHiddenInChain = false
    /// Kept as a row of its own although it holds nothing but one folder: Unfold Folder in the explorer's menu.
    var keepUnfolded = false

    var displayName: String { compactedNames.isEmpty ? name : (compactedNames + [name]).joined(separator: " › ") }

    private static let hiddenNames: Set<String> = [".DS_Store", ".git"]

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    var name: String { isPlaceholder ? "" : url.lastPathComponent }
    /// The key git decorations are looked up by; worked out once, since every redraw of the row asks for it.
    private(set) lazy var standardPath: String = url.standardizedFileURL.path

    /// Where VS Code puts it: a new folder above the folders, a new file above the files.
    func addPlaceholder(isDirectory: Bool) -> FileNode {
        let node = FileNode(url: url.appendingPathComponent("\u{1}new"), isDirectory: isDirectory)
        node.isPlaceholder = true
        var list = children
        list.insert(node, at: isDirectory ? 0 : (list.firstIndex { !$0.isDirectory } ?? list.count))
        loadedChildren = list
        return node
    }

    func removePlaceholders() {
        loadedChildren?.removeAll { $0.isPlaceholder }
    }

    var isLoaded: Bool { loadedChildren != nil }

    var children: [FileNode] {
        if let loadedChildren { return loadedChildren }
        reload()
        return loadedChildren ?? []
    }

    /// Re-reads the directory, reusing existing nodes so expanded folders stay expanded.
    /// Returns false when the names and kinds are exactly as before — the usual case, since saving a file's
    /// contents also raises an event for its folder.
    @discardableResult
    func reload() -> Bool {
        guard isDirectory else { return false }
        var existing: [String: FileNode] = [:]
        for child in loadedChildren ?? [] { existing[child.name] = child }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        let nodes = urls.compactMap { child -> FileNode? in
            let name = child.lastPathComponent
            guard !FileNode.hiddenNames.contains(name) else { return nil }
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if let old = existing[name], old.isDirectory == isDir { return old }
            let node = FileNode(url: child, isDirectory: isDir)
            node.isIgnored = isIgnored
            node.parent = self
            return node
        }
        let sorted = nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        if let loadedChildren, loadedChildren.count == sorted.count, zip(loadedChildren, sorted).allSatisfy({ $0 === $1 }) {
            return false                     // same nodes, same order: keep the ignore check that was already done
        }
        loadedChildren = sorted
        ignoreChecked = false
        return true
    }
}

/// Reports changes under a folder. Several parts of a window watch the same project folder (the explorer, the
/// Activity pane, a web preview), so watchers of one path share a single file-system event stream: each event is
/// delivered by the system once and handed to everyone interested.
final class DirectoryWatcher {
    var onChange: (([String]) -> Void)?
    private let path: String

    init(path: String) {
        self.path = path
        WatchHub.shared.add(self, path: path)
    }

    deinit {
        WatchHub.shared.remove(self, path: path)
    }

    /// One stream per watched path, shared by its watchers. Main queue only, like the watchers themselves.
    private final class WatchHub {
        static let shared = WatchHub()

        private final class Entry {
            var stream: FSEventStreamRef?
            var watchers: [ObjectIdentifier: () -> DirectoryWatcher?] = [:]
        }
        private var entries: [String: Entry] = [:]

        func add(_ watcher: DirectoryWatcher, path: String) {
            let entry = entries[path] ?? start(path)
            entries[path] = entry
            entry.watchers[ObjectIdentifier(watcher)] = { [weak watcher] in watcher }
        }

        func remove(_ watcher: DirectoryWatcher, path: String) {
            guard let entry = entries[path] else { return }
            entry.watchers[ObjectIdentifier(watcher)] = nil
            guard entry.watchers.isEmpty else { return }
            if let stream = entry.stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            entries[path] = nil
        }

        private func start(_ path: String) -> Entry {
            let entry = Entry()
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(entry).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
                guard let info else { return }
                let entry = Unmanaged<Entry>.fromOpaque(info).takeUnretainedValue()
                let changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
                for watcher in entry.watchers.values.compactMap({ $0() }) { watcher.onChange?(changed) }
            }
            let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
            entry.stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4, flags)
            if let stream = entry.stream {
                FSEventStreamSetDispatchQueue(stream, .main)
                FSEventStreamStart(stream)
            }
            return entry
        }
    }
}

/// The tree with the keys a file list is expected to answer: Return or F2 renames, ⌘⌫ moves to the Trash.
/// It also keeps the one hovered row: a tracking area per row let a row stay lit when the pointer left it
/// during a scroll; one area over the tree, resolved to a row on every move, cannot.
final class ExplorerOutlineView: NSOutlineView {
    var onRename: (() -> Void)?
    var onTrash: (() -> Void)?
    private(set) var hoveredRow = -1
    /// Whether the pointer is over the tree.
    private(set) var isMouseInside = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isMouseInside = true; hover(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { isMouseInside = true; hover(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { isMouseInside = false; setHovered(-1) }

    /// After a scroll the row under the still pointer is another one.
    func refreshHover() {
        guard let window else { return }
        let location = window.mouseLocationOutsideOfEventStream
        let inside = visibleRect.contains(convert(location, from: nil))
        isMouseInside = inside
        if inside { hover(at: location) } else { setHovered(-1) }
    }

    private func hover(at windowLocation: NSPoint) { setHovered(row(at: convert(windowLocation, from: nil))) }

    func setHovered(_ row: Int) {
        guard row != hoveredRow else { return }
        func rowView(_ row: Int) -> ExplorerRowView? {
            guard row >= 0, row < numberOfRows else { return nil }
            return self.rowView(atRow: row, makeIfNecessary: false) as? ExplorerRowView
        }
        rowView(hoveredRow)?.isHovered = false
        hoveredRow = row
        rowView(row)?.isHovered = true
    }

    func redrawRowViews() { enumerateAvailableRowViews { row, _ in row.needsDisplay = true } }
    func setHoveredForTests(_ row: Int) { isMouseInside = row >= 0; setHovered(row) }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if selectedRow >= 0, flags.isEmpty, event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 120 {
            onRename?()
        } else if selectedRow >= 0, flags == .command, event.keyCode == 51 {
            onTrash?()
        } else {
            super.keyDown(with: event)
        }
    }
}

extension SidebarViewController {
    static let badgeIdentifier = NSUserInterfaceItemIdentifier("FileCellGitBadge")
    static let rowIdentifier = NSUserInterfaceItemIdentifier("FileRow")
}

/// A row of the explorer: a rounded selection inset from the edges and a faint fill under the pointer. All
/// drawing, no subviews.
final class ExplorerRowView: NSTableRowView {
    var isHovered = false { didSet { if isHovered != oldValue { stateChanged() } } }
    private static let inset: CGFloat = 5
    private static let radius: CGFloat = 5

    override var isEmphasized: Bool { didSet { stateChanged() } }
    override var isSelected: Bool { didSet { if isSelected != oldValue { stateChanged() } } }

    /// The git mark's box takes the row's colour, so the cell lays out again when that changes.
    private func stateChanged() {
        needsDisplay = true
        for case let cell as ExplorerCellView in subviews { cell.needsLayout = true }
    }

    /// What is under the row's content right now: the selection, the hover tint over the sidebar, or the sidebar.
    var groundColor: NSColor {
        let theme = Settings.shared.theme
        // With glass the sidebar is translucent; the mark's ground matches it so it does not read as a box.
        let chrome = Glass.chrome(theme.chrome)
        if isSelected { return isEmphasized ? theme.selection : theme.selection.withAlphaComponent(0.55).blended(over: theme.chrome) }
        if isHovered { return theme.foreground.withAlphaComponent(0.06).blended(over: theme.chrome) }
        return chrome
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }

    /// The selection and hover bars span the visible part of the row, not the whole (possibly wider) column.
    private var shape: NSBezierPath {
        var rect = bounds
        if let clip = enclosingScrollView?.contentView {
            let visible = convert(clip.bounds, from: clip)
            rect.origin.x = max(rect.minX, visible.minX)
            rect.size.width = min(rect.maxX, visible.maxX) - rect.origin.x
        }
        return NSBezierPath(roundedRect: rect.insetBy(dx: ExplorerRowView.inset, dy: 0.5), xRadius: ExplorerRowView.radius, yRadius: ExplorerRowView.radius)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        let theme = Settings.shared.theme
        if isHovered, !isSelected {
            theme.foreground.withAlphaComponent(0.06).setFill()
            shape.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let theme = Settings.shared.theme
        theme.selection.withAlphaComponent(isEmphasized ? 1 : 0.55).setFill()
        shape.fill()
    }

}

/// The content of a row: icon, name, git mark. Laid out by hand, which is a fraction of the cost of Auto Layout
/// for a view made thousands of times while a big folder is scrolled.
final class ExplorerCellView: NSTableCellView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    let mark = NSTextField(labelWithString: "")
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        identifier = NSUserInterfaceItemIdentifier("FileCell")
        label.lineBreakMode = .byTruncatingTail
        label.font = SidebarViewController.rowFont
        label.cell?.truncatesLastVisibleLine = true
        // The git mark: a fixed slot at the right edge of the row, so the letters and dots of neighbouring rows
        // line up in a column and a long name is cut short before it rather than pushing it out of view.
        mark.identifier = SidebarViewController.badgeIdentifier
        mark.font = SidebarViewController.badgeFont
        mark.alignment = .right
        for subview in [icon, label, mark] { addSubview(subview) }
        imageView = icon
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The right edge of what can be seen of this row: the column may be wider than the sidebar and scrolled.
    private var visibleMaxX: CGFloat {
        guard let clip = enclosingScrollView?.contentView else { return bounds.width }
        return min(bounds.width, convert(clip.bounds, from: clip).maxX)
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        icon.frame = NSRect(x: 2, y: floor((height - 16) / 2), width: 16, height: 16)
        // The mark stays at the visible right edge however far the row is scrolled; the name is cut short before
        // it (nothing is drawn behind the mark, so the row's own background shows through, whatever it is).
        let slot = max(SidebarViewController.badgeWidth, ceil(mark.intrinsicContentSize.width)) + 6
        let markHeight = ceil(mark.intrinsicContentSize.height)
        let edge = visibleMaxX
        mark.frame = NSRect(x: edge - SidebarViewController.badgeInset - slot + 3, y: floor((height - markHeight) / 2), width: slot - 3, height: markHeight)
        let labelHeight = ceil(label.intrinsicContentSize.height)
        let labelX = icon.frame.maxX + 5
        // The name runs up to the mark's slot at the visible edge and is cut short there; scrolling sideways moves
        // the edge, so more of it comes into view. With no mark it has the whole column.
        let end = mark.stringValue.isEmpty ? bounds.width - SidebarViewController.badgeInset - slot - 4 : mark.frame.minX - 6
        label.frame = NSRect(x: labelX, y: floor((height - labelHeight) / 2), width: max(0, min(end, bounds.width - 4) - labelX), height: labelHeight)
    }
}

extension NSColor {
    /// This colour laid over an opaque `ground`, as it would look drawn there.
    func blended(over ground: NSColor) -> NSColor {
        guard let top = usingColorSpace(.sRGB), let bottom = ground.usingColorSpace(.sRGB) else { return self }
        let alpha = top.alphaComponent
        return NSColor(srgbRed: top.redComponent * alpha + bottom.redComponent * (1 - alpha),
                       green: top.greenComponent * alpha + bottom.greenComponent * (1 - alpha),
                       blue: top.blueComponent * alpha + bottom.blueComponent * (1 - alpha), alpha: 1)
    }
}

final class SidebarViewController: NSViewController, NSTextFieldDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var onOpenFile: ((URL) -> Void)?
    var onRequestOpenFolder: (() -> Void)?

    private let outlineView = ExplorerOutlineView()
    /// The outline, for tests that check which rows exist.
    var outlineViewForTests: NSOutlineView { outlineView }
    /// A file or folder was renamed or moved in the tree, so open tabs can follow it.
    var onMoveFile: ((URL, URL) -> Void)?
    /// The name being typed in the tree, for a rename or for a new item.
    private struct InlineEdit {
        enum Purpose { case rename(FileNode), create(parent: FileNode, isFolder: Bool) }
        let purpose: Purpose
        let node: FileNode
        weak var field: NSTextField?
        var isCancelled = false
    }
    private var inlineEdit: InlineEdit?
    /// Git's view of the files shown here: M, U, A, D… at the end of the row, as VS Code has it.
    let decorations = GitDecorations()
    /// How many files have changed, over every repository under the folder; the Source Control icon shows it.
    /// Comes from the same `git status` as the marks, so it is right whether or not the Source Control pane is open.
    var onGitChangeCount: ((Int) -> Void)?
    private var reloadAfterEdit = Set<URL>()
    private let scrollView = NSScrollView()
    private let header = NSTextField(labelWithString: "NO FOLDER OPENED")
    private let openButton = NSButton(title: "Open Folder…", target: nil, action: nil)
    /// New File, New Folder, Refresh, Collapse All: at the top, where VS Code has them.
    private let headerButtons = NSStackView()
    private var root: FileNode?
    private var watcher: DirectoryWatcher?

    var rootURL: URL? { root?.url }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        view.wantsLayer = true

        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.lineBreakMode = .byTruncatingTail

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        // The column is as wide as the widest row (never narrower than the sidebar), so a deep tree scrolls
        // sideways and no name is cut short; the git marks are pinned to the visible right edge by the cells.
        column.resizingMask = []
        outlineView.columnAutoresizingStyle = .noColumnAutoresizing
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 14
        outlineView.style = .plain
        outlineView.intercellSpacing = .zero          // .plain adds 17 points after the column; the row would overflow the sidebar by that much
        outlineView.backgroundColor = .clear
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        outlineView.autoresizesOutlineColumn = false
        outlineView.onRename = { [weak self] in self?.renameItem() }
        outlineView.onTrash = { [weak self] in self?.trashItem() }
        // Files can be dragged to the terminal, to other Feather windows, and to Finder, and dropped in from all three.
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        outlineView.setDraggingSourceOperationMask([.copy, .generic], forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        // Scrolling moves the row under a still pointer, and sideways scrolling moves the visible edge the marks sit at.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipDidScroll), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        openButton.target = self
        openButton.action = #selector(openFolderClicked)
        openButton.bezelStyle = .rounded

        let actions: [(String, String, Selector)] = [
            ("doc.badge.plus", "New File (in the selected folder)", #selector(newFile)),
            ("folder.badge.plus", "New Folder (in the selected folder)", #selector(newFolder)),
            ("arrow.clockwise", "Refresh", #selector(refreshTree)),
            ("arrow.down.right.and.arrow.up.left", "Collapse All Folders", #selector(collapseAll)),
        ]
        for (symbol, tip, action) in actions {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)) ?? NSImage()
            let button = NSButton(image: image, target: self, action: action)
            button.isBordered = false
            button.toolTip = tip
            button.widthAnchor.constraint(equalToConstant: 20).isActive = true
            headerButtons.addArrangedSubview(button)
        }
        headerButtons.spacing = 2
        headerButtons.isHidden = true
        headerButtons.setContentCompressionResistancePriority(.required, for: .horizontal)
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for subview in [header, headerButtons, scrollView, openButton] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 9),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(lessThanOrEqualTo: headerButtons.leadingAnchor, constant: -6),
            headerButtons.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            headerButtons.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: TabBarView.height),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            openButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            openButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 60),
        ])
        applyTheme()
    }

    func applyTheme() {
        let theme = Settings.shared.theme
        view.layer?.backgroundColor = Glass.paneBackground(theme.chrome)   // the sidebar's backdrop shows through with glass
        header.textColor = theme.lineNumber
        headerButtons.arrangedSubviews.forEach { ($0 as? NSButton)?.contentTintColor = theme.lineNumber }
        outlineView.reloadData()
    }

    func setRoot(_ url: URL) {
        root = FileNode(url: url, isDirectory: true)
        header.stringValue = url.lastPathComponent.uppercased()
        openButton.isHidden = true
        headerButtons.isHidden = false
        outlineView.reloadData()
        watcher = DirectoryWatcher(path: url.path)
        watcher?.onChange = { [weak self] paths in self?.handleChanges(paths) }
        decorations.onChange = { [weak self] in
            guard let self else { return }
            self.redrawRows()
            self.onGitChangeCount?(self.decorations.files.count)
        }
        decorations.setRoot(url)
    }

    /// Only what the rows look like changed (git marks), not which rows there are.
    private func redrawRows() {
        guard isViewLoaded, inlineEdit == nil, outlineView.numberOfRows > 0 else { return }
        let visible = outlineView.rows(in: outlineView.visibleRect)
        guard visible.length > 0 else { return }
        outlineView.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                               columnIndexes: IndexSet(integer: 0))
    }

    /// Something changed what git would say: a commit, a stage, a checkout, trust being granted.
    func refreshGitDecorations(rediscover: Bool = false) {
        if rediscover { decorations.repositoriesMayHaveChanged() } else { decorations.scheduleRefresh() }
    }

    // MARK: - Revealing the open file

    /// Expands the folders leading to `url`, selects it and scrolls it into view — so the tree always shows
    /// where the file being edited lives, however it was opened (search, Quick Open, ⌘-click, a breadcrumb).
    func reveal(_ url: URL) {
        guard isViewLoaded, let root else { return }
        let rootPath = root.url.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return }
        var current = root
        let components = path.dropFirst(rootPath.count + 1).split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            // `children` loads a folder on first use, so this works for folders never opened before. A folder
            // folded into a chain is not a row: only the rows that exist are expanded, and only rows have their
            // children folded (folding from inside a chain would shorten the chain's own label).
            if !current.isHiddenInChain { _ = visibleChildren(of: current) }
            guard let next = current.children.first(where: { $0.name == component }) else { return }
            if index < components.count - 1, !next.isHiddenInChain { outlineView.expandItem(next) }
            current = next
        }
        // A folded folder is shown by the last link of its chain.
        while current.isHiddenInChain, let only = current.children.first { current = only }
        let row = outlineView.row(forItem: current)
        guard row >= 0 else { return }
        if outlineView.selectedRow != row { outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        // Centre it when it is off screen; leave the scroll position alone when it is already visible.
        let rowRect = outlineView.rect(ofRow: row)
        if !outlineView.visibleRect.contains(rowRect) {
            let visible = outlineView.visibleRect
            outlineView.scroll(NSPoint(x: 0, y: max(0, rowRect.midY - visible.height / 2)))
        }
    }

    // MARK: - Tree maintenance

    private func node(for url: URL) -> FileNode? {
        guard let root else { return nil }
        let rootPath = root.url.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == rootPath { return root }
        guard path.hasPrefix(rootPath + "/") else { return nil }
        var current = root
        for component in path.dropFirst(rootPath.count + 1).split(separator: "/") {
            guard current.isLoaded, let next = current.children.first(where: { $0.name == component }) else { return nil }
            current = next
        }
        return current
    }

    // MARK: - Git-ignored entries

    /// Asks git which of a folder's children are ignored, then dims them. Git decides, so nested .gitignore
    /// files, negations and the global ignore file all behave exactly as they do on the command line.
    private func checkIgnored(in directory: FileNode) {
        guard !directory.ignoreChecked, directory.isLoaded else { return }
        directory.ignoreChecked = true
        // Inside an ignored folder there is nothing to ask: the children were created already dimmed.
        guard !directory.isIgnored else { return }
        let children = directory.children
        guard !children.isEmpty, children.count <= 3000 else { return }
        // Git quotes "unusual" names in its output, writing every non-ASCII byte as an octal escape, so an ignored
        // "Ünïcode build" folder came back as "\303\234n\303\257code build" and never matched: the names are unquoted.
        Git.run(["check-ignore", "--"] + children.map(\.name), in: directory.url) { [weak self, weak directory] result in
            // Exit status 0 = some are ignored, 1 = none are; anything else means this is not a repository.
            guard let self, let directory, result.status == 0 || result.status == 1 else { return }
            let ignored = Set(result.output.split(separator: "\n").map { Git.unquotePath(String($0)) })
            var changed = false
            for child in directory.children where child.isIgnored != ignored.contains(child.name) {
                child.isIgnored = ignored.contains(child.name)
                changed = true
            }
            guard changed else { return }
            // Reloading rows drops the selection, so put it back on the same file afterwards.
            let selected = self.outlineView.item(atRow: self.outlineView.selectedRow)
            self.reloadRows(showing: directory)
            let row = self.outlineView.row(forItem: selected)
            if row >= 0 { self.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
    }

    private func reloadDirectory(_ url: URL) {
        // Reloading rows would take the field away from under the cursor; it is done when the name is finished.
        if inlineEdit != nil { reloadAfterEdit.insert(url); return }
        guard let node = node(for: url), node.isDirectory, node.isLoaded else { return }
        guard node.reload() else { return }                  // nothing was added, removed or renamed
        if let rootURL = root?.url { ProjectFiles.invalidate(root: rootURL) }
        reloadRows(showing: node)
    }

    /// File-system events arrive in bursts (a build, `npm install`): thousands of paths, nearly all in folders the
    /// tree has never opened. They are filtered as plain strings before any URL or tree work is done.
    private func handleChanges(_ paths: [String]) {
        guard let root else { return }
        // Any change on disk, including git's own index after a stage or commit, can change the marks.
        decorations.scheduleRefresh()
        let rootPath = root.url.standardizedFileURL.path
        // Events name the real location (/private/var/…) even when the folder was opened as /var/…; both count.
        let spellings = Set([rootPath, root.url.resolvingSymlinksInPath().path, root.url.path]).sorted { $0.count > $1.count }
        var seen = Set<String>()
        var listingChanged = false
        for var path in paths {
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            guard seen.insert(path).inserted, let base = spellings.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            let relative = path.dropFirst(min(path.count, base.count + 1))
            path = relative.isEmpty ? rootPath : rootPath + "/" + relative
            if let first = relative.split(separator: "/").first {
                if first == ".git" { continue }
                listingChanged = true
                // An unopened first-level folder cannot contain anything the tree is showing.
                if !root.children.contains(where: { $0.name == first && ($0.isLoaded || !$0.isDirectory) }) && relative.contains("/") { continue }
            } else {
                listingChanged = true
            }
            reloadDirectory(URL(fileURLWithPath: path))
        }
        if listingChanged { ProjectFiles.invalidate(root: root.url) }
    }

    // MARK: - Actions

    @objc private func openFolderClicked() { onRequestOpenFolder?() }

    @objc private func rowClicked() {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? FileNode, !node.isPlaceholder else { return }
        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.animator().collapseItem(node)
            } else {
                outlineView.animator().expandItem(node)
            }
        } else {
            onOpenFile?(node.url)
        }
    }

    /// The row under a right-click; for the buttons at the top, which no row was clicked for, the selected row.
    private var clickedNode: FileNode? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        return outlineView.item(atRow: row) as? FileNode
    }

    /// Directory that "New File" / "New Folder" should create into.
    private var targetDirectory: FileNode? {
        guard let node = clickedNode else { return root }
        return node.isDirectory ? node : self.node(for: node.url.deletingLastPathComponent())
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard root != nil else { return }
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("New File", #selector(newFile))
        add("New Folder", #selector(newFolder))
        menu.addItem(.separator())
        if clickedNode != nil {
            add("Copy", #selector(copy(_:)))
            add("Duplicate", #selector(duplicateItem))
        }
        if !pasteboardFileURLs().isEmpty { add("Paste", #selector(paste(_:))) }
        if clickedNode != nil {
            menu.addItem(.separator())
            add("Rename", #selector(renameItem))
            add("Move to Trash", #selector(trashItem))
            menu.addItem(.separator())
            add("Copy Path", #selector(copyPath))
        }
        // A chain can be opened out into one row per folder and folded back, as in Zed and IntelliJ.
        if let node = clickedNode, node.isDirectory, Settings.shared.compactFolders {
            if !node.compactedNames.isEmpty {
                menu.addItem(.separator())
                add("Unfold Folder", #selector(unfoldChain))
            } else if node.keepUnfolded {
                menu.addItem(.separator())
                add("Fold Folder", #selector(foldChain))
            }
        }
        add("Reveal in Finder", #selector(revealInFinder))
    }

    /// The Refresh button, for tests.
    func refreshTreeForTests() { refreshTree() }
    func redrawRowsForTests() { redrawRows() }

    @objc private func refreshTree() {
        guard let root else { return }
        ProjectFiles.invalidate(root: root.url)
        var expanded: [FileNode] = []
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? FileNode, node.isDirectory, outlineView.isItemExpanded(node) { expanded.append(node) }
        }
        reloadDirectory(root.url)
        expanded.forEach { reloadDirectory($0.url) }
        // Folders folded into a chain are not rows, so they are re-read by hand: one of them gaining an entry
        // unfolds the chain.
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? FileNode, !node.compactedNames.isEmpty else { continue }
            var folded = node.parent
            while let folder = folded, folder.isHiddenInChain { reloadDirectory(folder.url); folded = folder.parent }
        }
    }

    @objc private func unfoldChain() { if let node = clickedNode { unfold(node) } }
    @objc private func foldChain() { if let node = clickedNode { fold(node) } }
    func unfoldForTests(_ node: FileNode) { unfold(node) }
    func foldForTests(_ node: FileNode) { fold(node) }

    /// Opens a chain row out into one row per folder, expanded down to where the chain's row was, so the view
    /// shows the same files as before with the folders between them in sight.
    private func unfold(_ node: FileNode) {
        guard !node.compactedNames.isEmpty else { return }
        var links = [node]
        var current = node.parent
        while let folder = current, folder.isHiddenInChain { links.append(folder); current = folder.parent }
        links.forEach { $0.keepUnfolded = true }
        let wasExpanded = outlineView.isItemExpanded(node)
        reloadRows(showing: links.last!)
        for link in links.reversed() where link !== node || wasExpanded { outlineView.expandItem(link) }
        select(node)
    }

    /// Folds `node` and the single-folder chain below it back into one row.
    private func fold(_ node: FileNode) {
        guard node.isDirectory, node.keepUnfolded else { return }
        var last = node
        var current: FileNode? = node
        while let folder = current {
            folder.keepUnfolded = false
            last = folder
            guard folder.children.count == 1, let only = folder.children.first, only.isDirectory, !only.isPlaceholder else { break }
            current = only
        }
        let wasExpanded = outlineView.isItemExpanded(last)
        reloadRows(showing: node.parent ?? node)
        if wasExpanded { outlineView.expandItem(last) }
        select(last)
    }

    private func select(_ node: FileNode) {
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    /// Compact folders were turned on or off in Preferences: list every folder again.
    func applySettings() {
        guard root != nil else { return }
        outlineView.reloadItem(nil, reloadChildren: true)
    }

    @objc private func collapseAll() {
        outlineView.collapseItem(nil, collapseChildren: true)
    }

    private func report(_ error: Error) {
        NSAlert(error: error).runModal()
    }

    @objc private func newFile() { beginCreating(isFolder: false) }
    @objc private func newFolder() { beginCreating(isFolder: true) }

    // MARK: - Typing a name in the tree

    /// Opens an empty row in the target folder with the cursor in it, as VS Code does.
    private func beginCreating(isFolder: Bool) {
        endInlineEdit(commit: true)
        guard let directory = targetDirectory else { return }
        if directory !== root { outlineView.expandItem(directory) }
        let node = directory.addPlaceholder(isDirectory: isFolder)
        outlineView.reloadItem(directory === root ? nil : directory, reloadChildren: true)
        beginEditing(node, purpose: .create(parent: directory, isFolder: isFolder))
    }

    private func beginEditing(_ node: FileNode, purpose: InlineEdit.Purpose) {
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { cleanUpPlaceholder(purpose); return }
        outlineView.scrollRowToVisible(row)
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        let theme = Settings.shared.theme
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = true
        field.backgroundColor = theme.background
        field.textColor = theme.foreground
        field.focusRingType = .exterior
        field.delegate = self
        field.placeholderString = node.isPlaceholder ? (node.isDirectory ? "Folder name" : "File name") : nil
        inlineEdit = InlineEdit(purpose: purpose, node: node, field: field)
        view.window?.makeFirstResponder(field)
        // A rename starts with the name selected and the extension left alone.
        if let editor = field.currentEditor() {
            let name = field.stringValue as NSString
            let dot = name.range(of: ".", options: .backwards).location
            editor.selectedRange = NSRange(location: 0, length: dot == NSNotFound || dot == 0 || node.isDirectory ? name.length : dot)
        }
    }

    /// Escape gives the name up; everything else that ends the editing (Return, Tab, a click elsewhere) keeps it.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)), inlineEdit != nil else { return false }
        inlineEdit?.isCancelled = true
        view.window?.makeFirstResponder(outlineView)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let edit = inlineEdit, notification.object as AnyObject? === edit.field else { return }
        endInlineEdit(commit: !edit.isCancelled)
    }

    private func cleanUpPlaceholder(_ purpose: InlineEdit.Purpose) {
        guard case .create(let parent, _) = purpose else { return }
        parent.removePlaceholders()
        outlineView.reloadItem(parent === root ? nil : parent, reloadChildren: true)
    }

    private func endInlineEdit(commit: Bool) {
        guard let edit = inlineEdit else { return }
        inlineEdit = nil
        let name = (edit.field?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        if let field = edit.field {
            field.delegate = nil
            field.isEditable = false
            field.isSelectable = false
            field.drawsBackground = false
            field.placeholderString = nil
            field.stringValue = edit.node.name
        }
        cleanUpPlaceholder(edit.purpose)
        let pending = reloadAfterEdit
        reloadAfterEdit = []
        pending.forEach(reloadDirectory)

        let parts = name.components(separatedBy: "/")
        let isValid = !name.isEmpty && !name.hasPrefix("/") && !parts.contains("..") && !parts.contains("")
        guard commit, !name.isEmpty else { return }
        guard isValid else { NSSound.beep(); return }
        switch edit.purpose {
        case .create(let parent, let isFolder):
            create(name, isFolder: isFolder, in: parent)
        case .rename(let node):
            guard name != node.name, !name.contains("/") else { return }
            let parent = node.url.deletingLastPathComponent()
            let destination = parent.appendingPathComponent(name)
            // A change of capitals only is a rename on a case-insensitive disk, not a clash.
            if FileManager.default.fileExists(atPath: destination.path), name.lowercased() != node.name.lowercased() {
                NSSound.beep()
                return
            }
            do {
                // Worked out while the file is still there: a path that no longer exists is not standardised the
                // same way (/private/tmp stays as it is), and would not match the open document's.
                let old = node.url.standardizedFileURL
                try FileManager.default.moveItem(at: node.url, to: destination)
                onMoveFile?(old, destination)
                reloadDirectory(parent)
                reveal(destination)
            } catch { report(error) }
        }
    }

    /// For the buttons and menu once a name is known: creates in the selected folder, or the project root.
    func create(_ name: String, isFolder: Bool, inSelectedFolder: Void = ()) { if let directory = targetDirectory { create(name, isFolder: isFolder, in: directory) } }

    private func create(_ name: String, isFolder: Bool, in directory: FileNode) {
        let url = directory.url.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { NSSound.beep(); return }
        do {
            let folder = isFolder ? url : url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if !isFolder { try Data().write(to: url) }
            // A nested name adds a folder to `directory` as well as the file inside it.
            reloadDirectory(directory.url)
            outlineView.expandItem(directory)
            reveal(url)
            if !isFolder { onOpenFile?(url) }
        } catch { report(error) }
    }

    @objc private func renameItem() {
        endInlineEdit(commit: true)
        guard let node = clickedNode, node !== root else { return }
        beginEditing(node, purpose: .rename(node))
    }

    @objc private func trashItem() {
        guard let node = clickedNode else { return }
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            reloadDirectory(node.url.deletingLastPathComponent())
        } catch { report(error) }
    }

    @objc private func copyPath() {
        guard let node = clickedNode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
    }

    // MARK: - Copy, paste and drag & drop

    /// The row that was right-clicked, or else the selected row (for ⌘C / ⌘V from the keyboard).
    private var actionNode: FileNode? {
        clickedNode ?? (outlineView.item(atRow: outlineView.selectedRow) as? FileNode)
    }

    private func pasteboardFileURLs(_ pasteboard: NSPasteboard = .general) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Puts the file itself on the clipboard, so it can be pasted into another Feather window or into Finder.
    @objc func copy(_ sender: Any?) {
        guard let node = actionNode else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([node.url as NSURL])
    }

    @objc func paste(_ sender: Any?) {
        let urls = pasteboardFileURLs()
        guard !urls.isEmpty, let destination = pasteDestination() else { NSSound.beep(); return }
        transfer(urls, into: destination, move: false)
    }

    private func pasteDestination() -> FileNode? {
        guard let node = actionNode else { return root }
        return node.isDirectory ? node : self.node(for: node.url.deletingLastPathComponent())
    }

    @objc private func duplicateItem() {
        guard let node = clickedNode, let parent = self.node(for: node.url.deletingLastPathComponent()) else { return }
        transfer([node.url], into: parent, move: false)
    }

    /// "name.ext", then "name copy.ext", "name copy 2.ext", … — never overwrites. Internal for the tests.
    func availableURL(for name: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var attempt = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let suffix = attempt == 1 ? " copy" : " copy \(attempt)"
            candidate = directory.appendingPathComponent(base + suffix + (ext.isEmpty ? "" : "." + ext))
            attempt += 1
        }
        return candidate
    }

    private func transfer(_ urls: [URL], into directory: FileNode, move: Bool) {
        var lastCreated: URL?
        for source in urls {
            let source = source.standardizedFileURL
            let target = directory.url.standardizedFileURL
            // A folder cannot go inside itself, and moving something to where it already is does nothing.
            if target.path == source.path || target.path.hasPrefix(source.path + "/") { NSSound.beep(); continue }
            if move && source.deletingLastPathComponent().path == target.path { continue }
            let destination = availableURL(for: source.lastPathComponent, in: target)
            do {
                if move {
                    let old = source.standardizedFileURL              // while it still exists; see the rename
                    try FileManager.default.moveItem(at: source, to: destination)
                    onMoveFile?(old, destination)
                }
                else { try FileManager.default.copyItem(at: source, to: destination) }
                lastCreated = destination
                if move { reloadDirectory(source.deletingLastPathComponent()) }
            } catch { report(error) }
        }
        reloadDirectory(directory.url)
        outlineView.expandItem(directory === root ? nil : directory)
        if let lastCreated, let node = node(for: lastCreated) {
            let row = outlineView.row(forItem: node)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? FileNode)?.url as NSURL?
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard root != nil, !pasteboardFileURLs(info.draggingPasteboard).isEmpty else { return [] }
        // Always drop *onto* a folder (or the project root), never between rows.
        var target = item as? FileNode
        if let node = target, !node.isDirectory { target = self.node(for: node.url.deletingLastPathComponent()) }
        outlineView.setDropItem(target === root ? nil : target, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return isMove(info) ? .move : .copy
    }

    /// Dragging inside one project moves (hold ⌥ to copy); anything from another window or Finder is copied.
    private func isMove(_ info: NSDraggingInfo) -> Bool {
        guard let root, !NSEvent.modifierFlags.contains(.option) else { return false }
        let rootPath = root.url.standardizedFileURL.path
        return pasteboardFileURLs(info.draggingPasteboard).allSatisfy { $0.standardizedFileURL.path.hasPrefix(rootPath + "/") }
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let destination = (item as? FileNode) ?? root else { return false }
        transfer(pasteboardFileURLs(info.draggingPasteboard), into: destination, move: isMove(info))
        return true
    }

    @objc private func revealInFinder() {
        guard let url = clickedNode?.url ?? root?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - NSOutlineViewDataSource / Delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = (item as? FileNode) ?? root else { return 0 }
        let count = visibleChildren(of: node).count
        checkIgnored(in: node)
        scheduleColumnFit()
        return count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        visibleChildren(of: ((item as? FileNode) ?? root)!)[index]
    }

    /// A folder's rows, with any chain of folders that hold nothing but one folder folded into its last link
    /// (`src/main/java/com/aagicorp` becomes one row), the way VS Code's compact folders work.
    private func visibleChildren(of node: FileNode) -> [FileNode] {
        let compact = Settings.shared.compactFolders
        return node.children.map { child in
            child.isHiddenInChain = false
            child.compactedNames = []
            guard compact, child.isDirectory, !child.isPlaceholder, !child.keepUnfolded else { return child }
            var names: [String] = []
            var current = child
            while current.isDirectory, current.children.count == 1, let only = current.children.first, only.isDirectory, !only.isPlaceholder, !only.keepUnfolded {
                current.isHiddenInChain = true
                names.append(current.name)
                current = only
            }
            current.isHiddenInChain = false
            current.compactedNames = names
            return current
        }
    }

    /// The nearest folder above `node` that is an outline row (a folder folded into a chain is not one).
    private func visibleContainer(of node: FileNode) -> FileNode? {
        var current: FileNode? = node
        while let candidate = current, candidate !== root {
            if !candidate.isHiddenInChain, outlineView.row(forItem: candidate) >= 0 { return candidate }
            current = candidate.parent
        }
        return root
    }

    /// Reloads the rows that show `node`'s contents, whether or not the node is itself a row.
    private func reloadRows(showing node: FileNode) {
        guard let container = visibleContainer(of: node) else { return }
        outlineView.reloadItem(container === root ? nil : container, reloadChildren: true)
    }

    func outlineViewItemDidExpand(_ notification: Notification) { scheduleColumnFit() }
    func outlineViewItemDidCollapse(_ notification: Notification) { scheduleColumnFit() }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyColumnWidth()
    }

    private var lastClipX: CGFloat = 0
    /// How many rows were told to draw again after sideways scrolls; the display flags themselves are not
    /// observable in a window that is not on screen.
    private(set) var sidewaysRedrawsForTests = 0

    @objc private func clipDidScroll() {
        outlineView.refreshHover()
        // The selection and hover bars and the marks' ground follow the visible edge, so a sideways scroll
        // moves them. The scroll view copies the pixels it already has and redraws only the strip that came
        // into view, which left the bars' old edges behind as stripes: every row is drawn whole again.
        let x = scrollView.contentView.bounds.origin.x
        let sideways = abs(x - lastClipX) > 0.5
        lastClipX = x
        outlineView.enumerateAvailableRowViews { row, _ in
            for case let cell as ExplorerCellView in row.subviews { cell.needsLayout = true }
            if sideways { row.needsDisplay = true; sidewaysRedrawsForTests += 1 }
        }
    }

    // MARK: - Column width

    private var columnFitScheduled = false
    private var neededWidth: CGFloat = 0
    private var nameWidths: [String: CGFloat] = [:]

    /// After a reload or an expand, once: measures every row so the column can be as wide as the widest.
    private func scheduleColumnFit() {
        guard !columnFitScheduled else { return }
        columnFitScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.columnFitScheduled = false
            self?.fitColumnToContent()
        }
    }

    private func fitColumnToContent() {
        var widest: CGFloat = 0
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? FileNode else { continue }
            let name = node.displayName
            let textWidth = nameWidths[name] ?? {
                let width = ceil((name as NSString).size(withAttributes: [.font: SidebarViewController.rowFont]).width)
                if nameWidths.count > 4000 { nameWidths.removeAll() }
                nameWidths[name] = width
                return width
            }()
            // Indentation and the disclosure arrow, the icon and its gap, the text, the mark's slot.
            widest = max(widest, CGFloat(outlineView.level(forRow: row)) * outlineView.indentationPerLevel + 22 + 2 + 16 + 5 + textWidth
                         + 4 + SidebarViewController.badgeWidth + 6 + SidebarViewController.badgeInset)
        }
        neededWidth = widest
        applyColumnWidth()
    }

    /// The column fills the sidebar, and grows past it for the widest row.
    private func applyColumnWidth() {
        guard isViewLoaded, let column = outlineView.tableColumns.first else { return }
        let width = max(scrollView.contentSize.width, neededWidth)
        guard width > 0 else { return }
        if abs(column.width - width) > 0.5 { column.width = width }
        if abs(outlineView.frame.width - width) > 0.5 { outlineView.setFrameSize(NSSize(width: width, height: outlineView.frame.height)) }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        (outlineView.makeView(withIdentifier: SidebarViewController.rowIdentifier, owner: nil) as? ExplorerRowView) ?? {
            let row = ExplorerRowView()
            row.identifier = SidebarViewController.rowIdentifier
            return row
        }()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = (outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("FileCell"), owner: nil) as? ExplorerCellView) ?? ExplorerCellView()
        let theme = Settings.shared.theme
        if inlineEdit?.field !== cell.label {
            cell.label.isEditable = false
            cell.label.drawsBackground = false
        }
        // Git marks: a letter for a changed file, a dot for a folder with changes inside, both in git's colour.
        let kind = node.isPlaceholder || node.isIgnored ? nil
            : (node.isDirectory ? decorations.kind(forFolder: node.standardPath) ?? decorations.kind(forFile: node.standardPath)
                                : decorations.kind(forFile: node.standardPath))
        // Ignored entries recede, so what git tracks is what stands out.
        let color = kind?.color(isDark: theme.isDark) ?? (node.isIgnored ? theme.lineNumber.withAlphaComponent(0.75) : theme.foreground)
        let fullPath = node.compactedNames.isEmpty ? nil : node.url.path
        if let kind {
            cell.mark.stringValue = node.isDirectory ? "•" : kind.letter
            cell.mark.textColor = color
            let tip = node.isDirectory ? "Contains changes" : kind.tip
            cell.toolTip = fullPath.map { $0 + "\n" + tip } ?? tip
        } else {
            cell.mark.stringValue = ""
            cell.toolTip = fullPath
        }
        cell.label.textColor = color
        if inlineEdit?.node === node || node.compactedNames.isEmpty {
            cell.label.stringValue = inlineEdit?.node === node ? node.name : node.displayName
        } else {
            cell.label.attributedStringValue = SidebarViewController.chainLabel(for: node, color: color)
        }
        cell.icon.alphaValue = node.isIgnored ? 0.45 : 1
        cell.icon.image = FileIcon.image(for: node.url, isDirectory: node.isDirectory)
        cell.needsLayout = true
        return cell
    }

    static let rowFont = NSFont.systemFont(ofSize: 12.5)
    static let badgeFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// The git mark's slot and its distance from the right edge; the overlay scroller sits inside the inset.
    static let badgeWidth: CGFloat = 12
    static let badgeInset: CGFloat = 12

    /// A compact folder row ("src › main › java"): the folders folded into it recede, so the folder the row
    /// stands for, the last link, is the one the eye lands on. The whole chain is always written out, as VS
    /// Code, Zed and IntelliJ write it; one too long for the sidebar ends in an ellipsis, the tooltip holds the
    /// whole path, and Unfold Folder in the menu opens it out into rows.
    static func chainLabel(for node: FileNode, color: NSColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let faded: [NSAttributedString.Key: Any] = [.font: rowFont, .foregroundColor: color.withAlphaComponent(0.62), .paragraphStyle: style]
        let plain: [NSAttributedString.Key: Any] = [.font: rowFont, .foregroundColor: color, .paragraphStyle: style]
        let label = NSMutableAttributedString()
        for name in node.compactedNames { label.append(NSAttributedString(string: name + " › ", attributes: faded)) }
        label.append(NSAttributedString(string: node.name, attributes: plain))
        return label
    }
}
