import AppKit

/// A tab that compares two versions of one file side by side: the index against the working tree, or HEAD against
/// the index. It is a `TabPreview`, so it never builds an editor; both versions are drawn by one view, which is
/// what keeps the two sides scrolling together and lets a 10,000-line file cost no more than the rows on screen.
final class GitDiffView: NSView, TabPreview {
    /// Posted (object: the view) after a block was staged, unstaged or reverted, so the window can bring its
    /// source-control pane, explorer marks and open documents up to date.
    static let didChangeRepository = Notification.Name("FeatherGitDiffViewDidChangeRepository")

    let root: URL
    let path: String
    let originalPath: String?
    let side: DiffSide
    var fileURL: URL { root.appendingPathComponent(path) }
    /// Set when the tab compares the file with a checkpoint (the Activity pane) rather than with git's versions.
    /// `root` is then the project folder, and the project's own git is never asked anything. See Checkpoints.swift.
    private(set) var comparison: CheckpointComparison?
    /// Checkpoint comparisons only: put the whole file back as the checkpoint has it.
    var onRestoreFile: (() -> Void)?
    /// Checkpoint comparisons only: whether "Undo This Change" asks first.
    var asksBeforeUndoingBlock = true

    /// Open the source file, at a zero-based line when one was pointed at.
    var onOpenFile: ((URL, Int?) -> Void)?
    /// Whether the file has unsaved edits in an editor; reverting a block on disk underneath them is refused.
    var hasUnsavedEdits: (() -> Bool)?
    /// Called each time a load finishes and the rows are in place.
    var onDidLoad: (() -> Void)?
    /// Set by a Review tab (Activity/Review.swift): it decides what buttons each block gets, marks the blocks
    /// already looked at, and takes the review's keys. Everything else about the diff stays as it is.
    weak var reviewer: DiffReviewer?
    /// A tab that draws a header of its own (the Review tab) hides this one.
    var isHeaderHidden = false {
        didSet {
            header.isHidden = isHeaderHidden
            headerHeight?.constant = isHeaderHidden ? 0 : 30
        }
    }
    private var headerHeight: NSLayoutConstraint?

    private(set) var diff: FileDiff?
    private(set) var problem: FileDiff.Problem?
    private(set) var isWorking = false
    /// How long the last load took off the main thread (git, reading, building rows), in milliseconds.
    private(set) var lastLoadMilliseconds = 0.0
    var rows: [DiffRow] { canvas.rows }

    private let canvas = DiffCanvasView()
    private let scrollView = NSScrollView()
    private let header = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let openButton = NSButton(title: "Open File", target: nil, action: nil)
    private let restoreButton = NSButton(title: "Restore This File…", target: nil, action: nil)
    private let previousButton = NSButton(title: "", target: nil, action: nil)
    private let nextButton = NSButton(title: "", target: nil, action: nil)
    private var generation = 0
    private var needsReloadWhenShown = false

    var focusView: NSView { canvas }

    init(root: URL, path: String, originalPath: String?, side: DiffSide, comparison: CheckpointComparison? = nil) {
        self.root = root
        self.path = path
        self.originalPath = originalPath
        self.side = side
        self.comparison = comparison
        super.init(frame: .zero)
        wantsLayer = true
        build()
        applyTheme()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(documentSaved(_:)), name: DocumentStore.didSaveDocument, object: nil)
        center.addObserver(self, selector: #selector(repositoryChanged), name: Git.repositoryDidChange, object: nil)
        if comparison != nil {
            center.addObserver(self, selector: #selector(repositoryChanged), name: ActivityCoordinator.filesDidChange, object: nil)
        }
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        for (button, symbol, tip, action) in [(previousButton, "chevron.up", "Previous Change", #selector(showPreviousChange)),
                                              (nextButton, "chevron.down", "Next Change", #selector(showNextChange))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.isBordered = false
            button.toolTip = tip
            button.target = self
            button.action = action
        }
        openButton.bezelStyle = .recessed
        openButton.controlSize = .small
        openButton.target = self
        openButton.action = #selector(openFileClicked)
        restoreButton.bezelStyle = .recessed
        restoreButton.controlSize = .small
        restoreButton.target = self
        restoreButton.action = #selector(restoreFileClicked)
        restoreButton.isHidden = comparison == nil
        let bar = NSStackView(views: [titleLabel, statsLabel, NSView(), previousButton, nextButton, restoreButton, openButton])
        bar.spacing = 10
        bar.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(bar)

        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        canvas.owner = self
        canvas.autoresizingMask = [.width]

        messageLabel.alignment = .center
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.isHidden = true
        for view in [header, scrollView, messageLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let headerHeight = header.heightAnchor.constraint(equalToConstant: 30)
        self.headerHeight = headerHeight
        NSLayoutConstraint.activate([
            headerHeight,
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            bar.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -80),
        ])
    }

    // MARK: - TabPreview

    func applyTheme() {
        let theme = Settings.shared.theme
        layer?.backgroundColor = theme.background.cgColor
        header.wantsLayer = true
        header.layer?.backgroundColor = theme.chrome.cgColor
        scrollView.backgroundColor = theme.background
        titleLabel.textColor = theme.foreground
        messageLabel.textColor = theme.lineNumber
        for button in [previousButton, nextButton] { button.contentTintColor = theme.lineNumber }
        canvas.applyTheme()
        showStats()
    }

    /// Reads both versions again. Safe to call often: an answer that was overtaken by a newer request is dropped.
    func render() {
        generation += 1
        let generation = generation
        let (root, path, originalPath, side, comparison) = (root, path, originalPath, side, comparison)
        let started = Date()
        isWorking = true
        let work = { () -> (Result<FileDiff, FileDiff.Problem>, [DiffRow], Int) in
            let result = comparison.map { $0.store.loadDiff(path: path, since: $0.checkpoint) }
                ?? FileDiff.load(root: root, path: path, originalPath: originalPath, side: side)
            guard case .success(let diff) = result else { return (result, [], 0) }
            let longest = max(diff.oldLines.reduce(0) { max($0, $1.utf16.count) }, diff.newLines.reduce(0) { max($0, $1.utf16.count) })
            return (result, diff.rows(), longest)
        }
        let completion = { [weak self] (result: Result<FileDiff, FileDiff.Problem>, rows: [DiffRow], longest: Int) in
            guard let self, self.generation == generation else { return }
            self.isWorking = false
            self.lastLoadMilliseconds = Date().timeIntervalSince(started) * 1000
            switch result {
            case .success(let diff):
                self.diff = diff
                self.problem = nil
                self.canvas.show(diff, rows: rows, longestLine: longest, side: self.side, language: Language.detect(for: self.fileURL))
            case .failure(let problem):
                self.diff = nil
                self.problem = problem
                self.canvas.show(nil, rows: [], longestLine: 0, side: self.side, language: nil)
            }
            self.showStats()
            self.onDidLoad?()
        }
        if let comparison {
            comparison.store.perform(work) { completion($0.0, $0.1, $0.2) }
        } else {
            Git.perform(changesIndex: false, work, completion: completion)
        }
    }

    /// Compare with another checkpoint (the pane's picker) in the same tab.
    func compare(with comparison: CheckpointComparison) {
        guard self.comparison != nil, self.comparison?.checkpoint != comparison.checkpoint else { return render() }
        self.comparison = comparison
        render()
    }

    private func showStats() {
        let theme = Settings.shared.theme
        titleLabel.stringValue = path + (side == .workingTree ? "   Index ↔ Working Tree" : "   HEAD ↔ Index")
        var message = problem?.message
        if let diff, diff.hunks.isEmpty { message = side == .workingTree ? "No changes left to stage in this file." : "Nothing is staged for this file." }
        if let comparison {
            titleLabel.stringValue = path + "   Checkpoint “\(comparison.checkpoint.name)” (left) ↔ Now (right)"
            if let diff, diff.hunks.isEmpty { message = "This file is the same as it was at the checkpoint." }
            if problem == .tooLarge { message = "This file is too large to compare here." }
            restoreButton.isEnabled = !(diff?.hunks.isEmpty ?? true) || problem != nil
        }
        messageLabel.stringValue = message ?? ""
        messageLabel.isHidden = message == nil
        scrollView.isHidden = message != nil
        let stats = NSMutableAttributedString()
        if let diff, !diff.hunks.isEmpty {
            let font = statsLabel.font ?? NSFont.systemFont(ofSize: 11)
            stats.append(NSAttributedString(string: "+\(diff.insertions) ", attributes: [.foregroundColor: NSColor(hex: 0x3FB950), .font: font]))
            stats.append(NSAttributedString(string: "−\(diff.deletions)", attributes: [.foregroundColor: NSColor(hex: 0xF14C4C), .font: font]))
            stats.append(NSAttributedString(string: "   \(diff.hunks.count) block\(diff.hunks.count == 1 ? "" : "s")",
                                            attributes: [.foregroundColor: theme.lineNumber, .font: font]))
        }
        statsLabel.attributedStringValue = stats
        let hasBlocks = !(diff?.hunks.isEmpty ?? true)
        previousButton.isEnabled = hasBlocks
        nextButton.isEnabled = hasBlocks
        openButton.isEnabled = FileManager.default.fileExists(atPath: fileURL.path)
    }

    // MARK: - Staying current

    @objc private func documentSaved(_ notification: Notification) {
        guard let url = notification.userInfo?["url"] as? URL, url.standardizedFileURL == fileURL.standardizedFileURL else { return }
        reloadWhenVisible()
    }

    @objc private func repositoryChanged() { reloadWhenVisible() }

    /// A diff tab in the background is only marked; it reads git again when it is next shown.
    private func reloadWhenVisible() {
        if window == nil { needsReloadWhenShown = true } else { render() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, needsReloadWhenShown {
            needsReloadWhenShown = false
            render()
        }
    }

    // MARK: - Actions

    @objc private func openFileClicked() { openFile(line: canvas.firstVisibleNewLine) }

    @objc private func restoreFileClicked() { onRestoreFile?() }

    func openFile(line: Int?) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { NSSound.beep(); return }
        onOpenFile?(fileURL, line)
    }

    @objc func showNextChange() { canvas.scrollToBlock(after: true) }

    @objc func showPreviousChange() { canvas.scrollToBlock(after: false) }

    /// What can be done to a block in this kind of diff.
    var blockActions: [FileDiff.BlockAction] {
        guard let diff, diff.canPatchBlocks else { return [] }
        if comparison != nil { return [.revert] }
        return side == .workingTree ? [.stage, .revert] : [.unstage]
    }

    /// What a block's button says. Someone comparing with a checkpoint is not asked to know what "revert" means.
    func title(for action: FileDiff.BlockAction) -> String {
        comparison != nil && action == .revert ? "Undo This Change" : action.title
    }

    /// The buttons drawn at the right of a block: the git actions, unless a review is in charge.
    func pills(for hunk: Int) -> [DiffPill] {
        if let reviewer { return reviewer.pills(for: hunk, in: self) }
        return blockActions.map { DiffPill(id: "\($0)", title: title(for: $0), isDestructive: $0 == .revert) }
    }

    func chose(_ pill: DiffPill, hunk: Int) {
        if let reviewer { return reviewer.chose(pill, hunk: hunk, in: self) }
        if let action = blockActions.first(where: { "\($0)" == pill.id }) { perform(action, hunk: hunk) }
    }

    /// A word drawn on a block that was already dealt with ("Kept"), or nil.
    func mark(for hunk: Int) -> String? { reviewer?.mark(for: hunk, in: self) }

    /// The block the review is on, drawn with a bar down its left edge; -1 for none.
    var selectedBlock: Int { canvas.selectedBlock }

    /// Picks a block and scrolls it into view.
    func selectBlock(_ index: Int) { canvas.select(block: index) }

    var blockCount: Int { diff?.hunks.count ?? 0 }

    /// Stages, unstages or reverts one block. The diff is read again first, on the git queue: the patch is only
    /// applied if that exact block is still there, because a patch without context lines lands wherever its line
    /// numbers say, right or wrong.
    func perform(_ action: FileDiff.BlockAction, hunk index: Int, completion: ((GitResult) -> Void)? = nil) {
        guard let diff, diff.hunks.indices.contains(index), blockActions.contains(action), !isWorking else { NSSound.beep(); return }
        if action == .revert, comparison != nil {
            if hasUnsavedEdits?() == true {
                report("Save the file first", "“\((path as NSString).lastPathComponent)” has edits you have not saved. Undoing a change rewrites the file, so save it (or close it without saving) and try again.")
                return
            }
            if asksBeforeUndoingBlock {
                let alert = NSAlert()
                alert.messageText = "Undo this change?"
                let hunk = diff.hunks[index]
                let count = max(hunk.oldCount, hunk.newCount)
                alert.informativeText = "\(count) line\(count == 1 ? "" : "s") in “\((path as NSString).lastPathComponent)” will go back to how \(count == 1 ? "it was" : "they were") at the checkpoint. The rest of the file stays as it is."
                alert.addButton(withTitle: "Undo This Change")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
        } else if action == .revert {
            if hasUnsavedEdits?() == true {
                report("Save the file first", "“\((path as NSString).lastPathComponent)” has unsaved edits. Reverting a block changes the file on disk, so save or discard your edits before reverting.")
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Revert this block?"
            let hunk = diff.hunks[index]
            alert.informativeText = "\(max(hunk.oldCount, hunk.newCount)) line\(max(hunk.oldCount, hunk.newCount) == 1 ? "" : "s") in “\((path as NSString).lastPathComponent)” will go back to the staged version. This cannot be undone."
            alert.addButton(withTitle: "Revert Block")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        isWorking = true
        let wanted = diff.hunks[index].patch
        let (root, path, originalPath, side) = (root, path, originalPath, side)
        if let comparison {
            // One block is small and the editor's own undo cannot reach it, but it is still only that block: the
            // rest of the file stays as it is, and Undo All's safety checkpoints are there for anything bigger.
            comparison.store.perform({ comparison.store.undoBlock(wanted, path: path, since: comparison.checkpoint) }) { [weak self] result in
                guard let self else { return }
                self.isWorking = false
                self.render()
                if result.ok {
                    NotificationCenter.default.post(name: GitDiffView.didChangeRepository, object: self)
                } else {
                    self.report("Could not undo this change", result.message)
                }
                completion?(result)
            }
            return
        }
        Git.perform(changesIndex: true, { () -> GitResult in
            guard case .success(let fresh) = FileDiff.load(root: root, path: path, originalPath: originalPath, side: side),
                  let current = fresh.hunks.firstIndex(where: { $0.patch == wanted }) else {
                return GitResult(status: -1, output: "", error: "The file has changed since this comparison was made. It has been refreshed; try again.")
            }
            return fresh.apply(action, hunk: current, root: root)
        }, completion: { [weak self] result in
            guard let self else { return }
            self.isWorking = false
            self.render()
            if result.ok {
                NotificationCenter.default.post(name: GitDiffView.didChangeRepository, object: self)
            } else {
                self.report("Could not \(action == .stage ? "stage" : action == .unstage ? "unstage" : "revert") the block", result.message)
            }
            completion?(result)
        })
    }

    private func report(_ title: String, _ details: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = String(details.prefix(1200))
        alert.runModal()
    }
}

extension FileDiff.BlockAction {
    var title: String {
        switch self {
        case .stage: return "Stage Block"
        case .unstage: return "Unstage Block"
        case .revert: return "Revert Block"
        }
    }
}

/// One button on a block of the diff.
struct DiffPill: Equatable {
    let id: String
    let title: String
    /// Drawn red: it changes a file.
    let isDestructive: Bool
}

/// What a Review tab lends its diff view. See Activity/Review.swift.
protocol DiffReviewer: AnyObject {
    func pills(for hunk: Int, in view: GitDiffView) -> [DiffPill]
    func chose(_ pill: DiffPill, hunk: Int, in view: GitDiffView)
    func mark(for hunk: Int, in view: GitDiffView) -> String?
    /// True when the key was one of the review's (j/k, K, U, ⌘]) and has been acted on.
    func handleKey(_ event: NSEvent, in view: GitDiffView) -> Bool
}

/// Draws the rows of a diff. Only the rows inside the dirty rectangle are touched, and a line's colours are worked
/// out the first time it is drawn, so the cost follows what is on screen rather than the size of the file.
final class DiffCanvasView: NSView {
    weak var owner: GitDiffView?
    private(set) var rows: [DiffRow] = []
    private var diff: FileDiff?
    private var side = DiffSide.workingTree
    private var language: Language?
    private var longestLine = 0
    private var blockStarts: [Int] = []

    private var theme = Settings.shared.theme
    private var font = Settings.shared.editorFont
    private var rowHeight: CGFloat = 18
    private var characterWidth: CGFloat = 8
    private var numberWidth: CGFloat = 40
    private var horizontalOffset: CGFloat = 0
    private var oldCache: [Int: NSAttributedString] = [:]
    private var newCache: [Int: NSAttributedString] = [:]
    private var hoveredBlock = -1
    private(set) var selectedBlock = -1
    private var pillRects: [(rect: NSRect, pill: DiffPill)] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func applyTheme() {
        theme = Settings.shared.theme
        font = Settings.shared.editorFont
        rowHeight = ceil(font.ascender - font.descender + font.leading) + 4
        characterWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        oldCache = [:]
        newCache = [:]
        resize()
    }

    func show(_ diff: FileDiff?, rows: [DiffRow], longestLine: Int, side: DiffSide, language: Language?) {
        self.diff = diff
        self.rows = rows
        self.side = side
        self.language = language
        self.longestLine = longestLine
        oldCache = [:]
        newCache = [:]
        hoveredBlock = -1
        if let diff, selectedBlock >= diff.hunks.count { selectedBlock = diff.hunks.count - 1 }
        if diff == nil { selectedBlock = -1 }
        indexBlocks()
        resize()
    }

    /// The review's current block: marked down its left edge, its buttons showing, and brought on screen.
    func select(block: Int) {
        selectedBlock = block
        if let start = rows.firstIndex(where: { $0.hunk == block }) {
            let top = CGFloat(start) * rowHeight
            let height = enclosingScrollView?.contentSize.height ?? bounds.height
            if top - rowHeight * 2 < visibleRect.minY || top + rowHeight * 3 > visibleRect.maxY {
                scroll(NSPoint(x: 0, y: max(0, min(top - rowHeight * 2, bounds.height - height))))
            }
        }
        setNeedsDisplay(visibleRect)
    }

    private func indexBlocks() {
        blockStarts = []
        var last = -1
        for (index, row) in rows.enumerated() where row.hunk >= 0 && row.hunk != last {
            blockStarts.append(index)
            last = row.hunk
        }
    }

    private func resize() {
        let digits = max(3, String(max(diff?.oldLines.count ?? 0, diff?.newLines.count ?? 0)).count)
        numberWidth = CGFloat(digits) * characterWidth + 18
        let width = enclosingScrollView?.contentSize.width ?? bounds.width
        setFrameSize(NSSize(width: width, height: max(CGFloat(rows.count) * rowHeight, 1)))
        clampOffset()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        clampOffset()
    }

    // MARK: - Geometry

    private var paneWidth: CGFloat { bounds.width / 2 }
    private var textWidth: CGFloat { max(40, paneWidth - numberWidth - 8) }

    private func clampOffset() {
        let widest = CGFloat(longestLine + 4) * characterWidth
        horizontalOffset = max(0, min(horizontalOffset, widest - textWidth))
    }

    private func row(at point: NSPoint) -> Int? {
        let index = Int(point.y / rowHeight)
        return rows.indices.contains(index) ? index : nil
    }

    private func rect(ofRow index: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
    }

    /// The new-side line nearest the top of what is showing, for Open File to land on.
    var firstVisibleNewLine: Int? {
        let first = max(0, Int(visibleRect.minY / rowHeight))
        return rows.dropFirst(first).first { $0.new >= 0 }?.new
    }

    func scrollToBlock(after forward: Bool) {
        guard !blockStarts.isEmpty else { return }
        let top = Int((visibleRect.minY + 1) / rowHeight) + 2
        let target = forward ? (blockStarts.first { $0 > top } ?? blockStarts[0]) : (blockStarts.last { $0 < top } ?? blockStarts[blockStarts.count - 1])
        scroll(NSPoint(x: 0, y: max(0, CGFloat(target - 2) * rowHeight)))
    }

    // MARK: - Drawing

    private func display(_ line: String) -> String {
        var text = line
        if text.utf16.count > 3000 { text = String(text.prefix(3000)) + " …" }          // a minified bundle on one line
        return text.contains("\t") ? text.replacingOccurrences(of: "\t", with: String(repeating: " ", count: Settings.shared.tabWidth)) : text
    }

    private func attributed(_ index: Int, old: Bool) -> NSAttributedString {
        if let cached = old ? oldCache[index] : newCache[index] { return cached }
        guard let diff else { return NSAttributedString() }
        let text = display(old ? diff.oldLines[index] : diff.newLines[index])
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: theme.foreground])
        // The editor's own rules, one line at a time. A construct that spans lines (a block comment) is coloured
        // as ordinary code here; reading the whole file to get that right is not worth it in a comparison.
        if let language, let regex = language.regex {
            let rules = language.rules
            regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) { match, _, _ in
                guard let match else { return }
                for rule in 0..<rules.count where match.range(at: rule + 1).location != NSNotFound {
                    result.addAttribute(.foregroundColor, value: theme.color(for: rules[rule].0), range: match.range(at: rule + 1))
                    break
                }
            }
        }
        if old { oldCache[index] = result } else { newCache[index] = result }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.background.setFill()
        dirtyRect.fill()
        guard let diff, !rows.isEmpty else { return }
        let first = max(0, Int(dirtyRect.minY / rowHeight)), last = min(rows.count - 1, Int(dirtyRect.maxY / rowHeight))
        guard first <= last else { return }
        let red = NSColor(hex: 0xF85149), green = NSColor(hex: 0x3FB950)
        let soft: CGFloat = theme.isDark ? 0.15 : 0.13, strong: CGFloat = theme.isDark ? 0.42 : 0.34
        let blank = theme.foreground.withAlphaComponent(theme.isDark ? 0.045 : 0.04)
        let half = paneWidth
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: max(9, font.pointSize - 2), weight: .regular),
                                                               .foregroundColor: theme.lineNumber]

        // Backgrounds and line numbers first, then each side's text under one clip, so long lines cannot spill
        // into the other side or over the numbers.
        var texts: [(text: NSAttributedString, y: CGFloat, old: Bool)] = []
        for index in first...last {
            let row = rows[index]
            let y = CGFloat(index) * rowHeight
            if row.kind == .fold {
                theme.chrome.setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: rowHeight).fill()
                let label = NSAttributedString(string: "⋯  \(row.count) unchanged line\(row.count == 1 ? "" : "s")  ⋯", attributes: [
                    .font: NSFont.systemFont(ofSize: max(10, font.pointSize - 2)), .foregroundColor: theme.lineNumber])
                let size = label.size()
                label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: y + (rowHeight - size.height) / 2))
                continue
            }
            if row.hunk >= 0, row.hunk == selectedBlock {
                theme.accent.setFill()
                NSRect(x: 0, y: y, width: 3, height: rowHeight).fill()
            }
            for isOld in [true, false] {
                let line = isOld ? row.old : row.new
                let x = isOld ? 0 : half
                let paneRect = NSRect(x: x, y: y, width: half, height: rowHeight)
                if line < 0 {
                    if row.kind != .context { blank.setFill(); paneRect.fill() }
                    continue
                }
                if row.kind != .context {
                    (isOld ? red : green).withAlphaComponent(soft).setFill()
                    paneRect.fill()
                }
                let number = NSAttributedString(string: String(line + 1), attributes: numberAttributes)
                let size = number.size()
                number.draw(at: NSPoint(x: x + numberWidth - 8 - size.width, y: y + (rowHeight - size.height) / 2))
                var text = attributed(line, old: isOld)
                if row.kind == .changed, row.old >= 0, row.new >= 0 {
                    let spans = FileDiff.changedSpans(display(diff.oldLines[row.old]), display(diff.newLines[row.new]))
                    let marks = (isOld ? spans.old : spans.new).filter { $0.length > 0 && NSMaxRange($0) <= text.length }
                    if !marks.isEmpty {
                        let marked = NSMutableAttributedString(attributedString: text)
                        for span in marks {
                            marked.addAttribute(.backgroundColor, value: (isOld ? red : green).withAlphaComponent(strong), range: span)
                        }
                        text = marked
                    }
                }
                texts.append((text, y, isOld))
            }
        }
        for isOld in [true, false] {
            let x = (isOld ? 0 : half) + numberWidth
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: x, y: dirtyRect.minY, width: textWidth + 8, height: dirtyRect.height)).addClip()
            for entry in texts where entry.old == isOld {
                entry.text.draw(at: NSPoint(x: x - horizontalOffset, y: entry.y + 2))
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        theme.border.setFill()
        NSRect(x: half - 0.5, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        drawPills(in: dirtyRect)
    }

    /// The buttons of the block under the pointer (or, in a review, the current block), at the right end of its
    /// first row; and on every block that has one, its mark ("Kept").
    private func drawPills(in dirtyRect: NSRect) {
        pillRects = []
        guard let owner else { return }
        let block = hoveredBlock >= 0 ? hoveredBlock : selectedBlock
        var markLeft: [Int: CGFloat] = [:]
        if block >= 0, let start = rows.firstIndex(where: { $0.hunk == block }) {
            var x = bounds.width - 10
            let y = CGFloat(start) * rowHeight
            for pill in owner.pills(for: block).reversed() {
                let title = NSAttributedString(string: pill.title, attributes: [
                    .font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.white])
                let size = title.size()
                let rect = NSRect(x: x - size.width - 14, y: y + 1, width: size.width + 14, height: rowHeight - 2)
                (pill.isDestructive ? NSColor(hex: 0xB62324) : NSColor(hex: 0x1F6FEB)).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                title.draw(at: NSPoint(x: rect.minX + 7, y: rect.minY + (rect.height - size.height) / 2))
                pillRects.append((rect, pill))
                x = rect.minX - 6
            }
            markLeft[block] = x
        }
        let first = max(0, Int(dirtyRect.minY / rowHeight)), last = Int(dirtyRect.maxY / rowHeight)
        for start in blockStarts where start >= first && start <= last {
            let hunk = rows[start].hunk
            guard let mark = owner.mark(for: hunk) else { continue }
            let label = NSAttributedString(string: mark, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor(hex: 0x3FB950)])
            let size = label.size()
            let x = markLeft[hunk] ?? bounds.width - 10
            let rect = NSRect(x: x - size.width - 12, y: CGFloat(start) * rowHeight + 1, width: size.width + 12, height: rowHeight - 2)
            theme.chrome.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            label.draw(at: NSPoint(x: rect.minX + 6, y: rect.minY + (rect.height - size.height) / 2))
        }
    }

    // MARK: - Pointer and keys

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func hover(_ block: Int) {
        guard block != hoveredBlock else { return }
        hoveredBlock = block
        setNeedsDisplay(visibleRect)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hover(row(at: point).map { rows[$0].hunk } ?? -1)
    }

    override func mouseExited(with event: NSEvent) { hover(-1) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let block = hoveredBlock >= 0 ? hoveredBlock : selectedBlock
        if let pill = pillRects.first(where: { $0.rect.contains(point) }), block >= 0 {
            owner?.chose(pill.pill, hunk: block)
            return
        }
        if let index = row(at: point), rows[index].hunk >= 0, owner?.reviewer != nil { select(block: rows[index].hunk) }
        guard let index = row(at: point) else { return }
        if rows[index].kind == .fold {
            expandFold(at: index)
        } else if event.clickCount == 2 {
            owner?.openFile(line: rows[index...].first { $0.new >= 0 }?.new)
        }
    }

    /// Replaces a "… N unchanged lines" row with the lines themselves.
    func expandFold(at index: Int) {
        guard rows.indices.contains(index), rows[index].kind == .fold else { return }
        rows.replaceSubrange(index...index, with: FileDiff.expanded(rows[index]))
        indexBlocks()
        resize()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if let index = row(at: point), rows[index].hunk >= 0, let owner {
            for pill in owner.pills(for: rows[index].hunk) {
                let item = NSMenuItem(title: pill.title, action: #selector(blockMenuChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = (rows[index].hunk, pill)
                menu.addItem(item)
            }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
        }
        let open = NSMenuItem(title: "Open File", action: #selector(openFromMenu(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = row(at: point).flatMap { index in rows[index...].first { $0.new >= 0 }?.new }
        menu.addItem(open)
        return menu
    }

    @objc private func blockMenuChosen(_ sender: NSMenuItem) {
        guard let (block, pill) = sender.representedObject as? (Int, DiffPill) else { return }
        owner?.chose(pill, hunk: block)
    }

    @objc private func openFromMenu(_ sender: NSMenuItem) { owner?.openFile(line: sender.representedObject as? Int) }

    /// A sideways swipe (or ⇧-scroll) moves both sides' text together; everything else scrolls the rows.
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return super.scrollWheel(with: event) }
        let before = horizontalOffset
        horizontalOffset -= event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : characterWidth * 3)
        clampOffset()
        if horizontalOffset != before { setNeedsDisplay(visibleRect) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let owner, let reviewer = owner.reviewer, reviewer.handleKey(event, in: owner) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let owner, let reviewer = owner.reviewer, reviewer.handleKey(event, in: owner) { return }
        guard let scrollView = enclosingScrollView, let key = event.specialKey else { return super.keyDown(with: event) }
        let page = scrollView.contentSize.height - rowHeight * 2
        var y = visibleRect.minY
        switch key {
        case .upArrow: y -= rowHeight
        case .downArrow: y += rowHeight
        case .pageUp: y -= page
        case .pageDown: y += page
        case .home: y = 0
        case .end: y = bounds.height
        case .leftArrow, .rightArrow:
            horizontalOffset += (key == .leftArrow ? -1 : 1) * characterWidth * 8
            clampOffset()
            setNeedsDisplay(visibleRect)
            return
        default: return super.keyDown(with: event)
        }
        scroll(NSPoint(x: 0, y: max(0, min(y, bounds.height - scrollView.contentSize.height))))
    }
}
