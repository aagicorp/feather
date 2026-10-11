import AppKit

/// The strip over a `.http` / `.rest` file while the API client is on: one button per request in the file,
/// the way VS Code's REST Client puts "Send Request" over each block. The request the cursor is in is
/// marked; clicking a button opens that request in a tab and sends it. Re-read a moment after the text
/// changes, never while nothing is shown.
final class HTTPRequestStrip: NSView {
    static let height: CGFloat = 28
    private weak var editor: EditorView?
    private weak var controller: APIClientController?
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let hint = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []
    private(set) var blocks: [HTTPFileBlocks.Block] = []
    private var currentIndex = -1
    private var reparseWork: DispatchWorkItem?
    private var theme = Settings.shared.theme

    init(editor: EditorView, controller: APIClientController) {
        self.editor = editor
        self.controller = controller
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
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
        hint.font = .systemFont(ofSize: 11.5)
        hint.lineBreakMode = .byTruncatingTail
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged(_:)), name: NSText.didChangeNotification, object: editor.textView)
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: editor.textView)
        reparse()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { reparseWork?.cancel() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: HTTPRequestStrip.height) }

    @objc private func textChanged(_ notification: Notification) {
        reparseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reparse() }
        reparseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    @objc private func selectionChanged(_ notification: Notification) { markCurrent() }

    private func reparse() {
        guard let editor else { return }
        let found = HTTPFileBlocks.parse(editor.document.text)
        let unchanged = found == blocks && !buttons.isEmpty
        blocks = found
        if !unchanged { render() }
        markCurrent()
    }

    private func render() {
        theme = Settings.shared.theme
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons = []
        currentIndex = -1
        let icon = NSImageView(image: NSImage(systemSymbolName: "paperplane", accessibilityDescription: "API requests") ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        icon.contentTintColor = theme.lineNumber
        stack.addArrangedSubview(icon)
        if blocks.isEmpty {
            hint.stringValue = "No requests yet. Write one like  GET https://example.com/users  and put ### between requests."
            hint.textColor = theme.lineNumber
            stack.addArrangedSubview(hint)
            return
        }
        for (index, block) in blocks.enumerated() {
            let button = NSButton(title: HTTPRequestStrip.title(for: block), target: self, action: #selector(send(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.tag = index
            button.toolTip = "Send \(block.request.method.rawValue) \(block.request.url) (line \(block.line + 1)) and show the answer"
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
        needsDisplay = true
    }

    /// "GET /users", or the request's own name, kept short enough for a row of them.
    static func title(for block: HTTPFileBlocks.Block) -> String {
        let name = block.request.name
        return name.count > 36 ? String(name.prefix(35)) + "…" : name
    }

    /// The button of the block the cursor is in is drawn in the accent colour.
    private func markCurrent() {
        guard let editor, !blocks.isEmpty else { return }
        let location = editor.textView.selectedRange().location
        let current = HTTPFileBlocks.block(at: location, in: blocks).flatMap { block in blocks.firstIndex { $0.range == block.range } } ?? -1
        guard current != currentIndex else { return }
        currentIndex = current
        for (index, button) in buttons.enumerated() {
            button.contentTintColor = index == current ? .controlAccentColor : nil
            button.font = .systemFont(ofSize: 11, weight: index == current ? .semibold : .regular)
        }
    }

    @objc private func send(_ sender: NSButton) {
        guard blocks.indices.contains(sender.tag), let controller else { return }
        controller.open(blocks[sender.tag].request, sends: true)
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.background.setFill()
        bounds.fill()
        theme.lineNumber.withAlphaComponent(0.25).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
