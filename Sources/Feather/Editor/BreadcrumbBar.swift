import AppKit

/// A menu that lists one folder and fills itself in only when it is opened, so browsing a deep tree from the
/// breadcrumbs never reads more of the disk than the folders actually visited.
private final class FolderMenu: NSMenu, NSMenuDelegate {
    private let folder: URL
    private let current: URL?
    private let onPick: (URL) -> Void
    private var isLoaded = false
    private static let hidden: Set<String> = [".DS_Store", ".git"]
    private static let limit = 400

    init(folder: URL, current: URL?, onPick: @escaping (URL) -> Void) {
        self.folder = folder
        self.current = current
        self.onPick = onPick
        super.init(title: folder.lastPathComponent)
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !isLoaded else { return }
        isLoaded = true
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        let entries = children
            .filter { !FolderMenu.hidden.contains($0.lastPathComponent) }
            .map { ($0, (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 }
                return a.0.lastPathComponent.localizedStandardCompare(b.0.lastPathComponent) == .orderedAscending
            }
        for (url, isDirectory) in entries.prefix(FolderMenu.limit) {
            let item = NSMenuItem(title: url.lastPathComponent, action: isDirectory ? nil : #selector(picked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.image = FileIcon.image(for: url, isDirectory: isDirectory)
            if isDirectory { item.submenu = FolderMenu(folder: url, current: current, onPick: onPick) }
            // Tick the file being edited and the folders that lead to it.
            if let current, current.path == url.path || current.path.hasPrefix(url.path + "/") { item.state = .on }
            addItem(item)
        }
        if entries.isEmpty { addItem(NSMenuItem(title: "Empty Folder", action: nil, keyEquivalent: "")) }
        if entries.count > FolderMenu.limit {
            addItem(NSMenuItem(title: "… and \(entries.count - FolderMenu.limit) more", action: nil, keyEquivalent: ""))
        }
    }

    @objc private func picked(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { onPick(url) }
    }
}

/// The path of the open file, under the tabs: `project › folder › folder › file`. Click any part to browse
/// what is next to it and jump there.
final class BreadcrumbBar: NSView {
    static let height: CGFloat = 24
    var onOpen: ((URL) -> Void)?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private var segments: [URL] = []
    private var file: URL?
    private var theme = Settings.shared.theme
    private var openMenu: NSMenu?
    private var shownRoot: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            document.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `root` is the opened project folder; paths inside it are shown relative to it, starting with its name.
    /// `fileIcon` replaces the file's icon on the last crumb (an API request's method, say).
    func show(file: URL?, root: URL?, fileIcon: NSImage? = nil) {
        let newTheme = Settings.shared.theme
        if file == self.file, root == shownRoot, newTheme.name == theme.name, !stack.arrangedSubviews.isEmpty || file == nil { return }
        shownRoot = root
        theme = newTheme
        self.file = file
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        segments = []
        guard let file else { needsDisplay = true; return }

        let path = file.standardizedFileURL.path
        if let root, path.hasPrefix(root.standardizedFileURL.path + "/") {
            var url = root.standardizedFileURL
            segments.append(url)
            for component in path.dropFirst(url.path.count + 1).split(separator: "/") {
                url.appendPathComponent(String(component))
                segments.append(url)
            }
        } else {
            // Outside the project: the last few folders are enough to say where it lives.
            var url = file.standardizedFileURL
            var trail = [url]
            for _ in 0..<3 where url.pathComponents.count > 2 {
                url.deleteLastPathComponent()
                trail.insert(url, at: 0)
            }
            segments = trail
        }

        for (index, url) in segments.enumerated() {
            let isFile = index == segments.count - 1
            let button = NSButton(title: "", target: self, action: #selector(segmentClicked(_:)))
            button.isBordered = false
            button.tag = index
            let title = NSMutableAttributedString()
            if isFile {
                if let fileIcon {
                    let attachment = NSTextAttachment()
                    attachment.image = fileIcon
                    attachment.bounds = NSRect(x: 0, y: -3, width: fileIcon.size.width * 14 / fileIcon.size.height, height: 14)
                    title.append(NSAttributedString(attachment: attachment))
                    title.append(NSAttributedString(string: "  "))
                } else {
                    title.append(FileIcon.attributed(for: url))
                }
            }
            title.append(NSAttributedString(string: url.lastPathComponent, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: isFile ? theme.foreground : theme.lineNumber]))
            button.attributedTitle = title
            button.toolTip = url.path
            stack.addArrangedSubview(button)
            if !isFile {
                let chevron = NSTextField(labelWithString: "›")
                chevron.font = .systemFont(ofSize: 12)
                chevron.textColor = theme.lineNumber
                stack.addArrangedSubview(chevron)
            }
        }
        needsDisplay = true
        // A long path keeps its end — the file name — in view; the start can be scrolled to.
        DispatchQueue.main.async { [weak self] in
            guard let self, let document = self.scrollView.documentView else { return }
            self.layoutSubtreeIfNeeded()
            let overflow = document.frame.width - self.scrollView.contentView.bounds.width
            self.scrollView.contentView.scroll(to: NSPoint(x: max(0, overflow), y: 0))
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
    }

    @objc private func segmentClicked(_ sender: NSButton) {
        guard segments.indices.contains(sender.tag) else { return }
        let url = segments[sender.tag]
        let isFile = sender.tag == segments.count - 1
        // A folder lists what is inside it; the file lists its neighbours.
        let menu = FolderMenu(folder: isFile ? url.deletingLastPathComponent() : url, current: file) { [weak self] in self?.onOpen?($0) }
        openMenu = menu
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 3), in: sender)
        openMenu = nil              // popUp returns when the menu closes; do not keep a tree of folder listings alive
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !Glass.isActive else { return }            // the panel behind paints the background
        theme.background.setFill()
        bounds.fill()
    }
}
