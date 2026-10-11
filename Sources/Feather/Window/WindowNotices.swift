import AppKit

/// Small cards in the bottom-right corner of a window: "your app is running", and the one-line hints shown the
/// first time someone meets a part of Feather. They float over the content and never take the keyboard, so they
/// cannot get in the way of typing; nothing here is built until the first card is shown.
final class NoticeCard: NSView {
    struct Action {
        let title: String
        var isProminent = false
        let run: () -> Void
    }

    /// Tells one kind of card from another, so a window shows at most one of each.
    let kind: String
    private let label = NSTextField(wrappingLabelWithString: "")
    private let iconView = NSImageView()
    private var actions: [Action] = []
    private var buttons: [NSButton] = []
    private var surface: NSView!
    var surfaceForTests: NSView { surface }
    var onDismiss: (() -> Void)?

    init(kind: String, symbol: String, text: String, actions: [Action], dismissTitle: String) {
        self.kind = kind
        super.init(frame: .zero)
        self.actions = actions
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = Glass.isActive ? 0 : 1
        shadow = NSShadow()
        // Under everything: glass on macOS 26, the chrome colour before it.
        surface = Glass.panel(around: NSView(), cornerRadius: 9, tint: Settings.shared.theme.chrome)
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor), surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor), surface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        label.stringValue = text
        label.font = .systemFont(ofSize: 12.5)
        label.isSelectable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttonRow = NSStackView()
        buttonRow.spacing = 8
        for (index, action) in actions.enumerated() {
            let button = NSButton(title: action.title, target: self, action: #selector(actionClicked(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.controlSize = .small
            if action.isProminent { button.keyEquivalent = ""; button.bezelColor = .controlAccentColor }
            buttons.append(button)
            buttonRow.addArrangedSubview(button)
        }
        let dismiss = NSButton(title: dismissTitle, target: self, action: #selector(dismissClicked))
        dismiss.bezelStyle = .rounded
        dismiss.controlSize = .small
        buttons.append(dismiss)
        buttonRow.addArrangedSubview(dismiss)

        let textColumn = NSStackView(views: [label, buttonRow])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 8
        let row = NSStackView(views: [iconView, textColumn])
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            widthAnchor.constraint(equalToConstant: 380),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme), name: Settings.didChange, object: nil)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var text: String { label.stringValue }
    var buttonTitles: [String] { buttons.map(\.title) }

    /// What a click on the button with this title does; also how tests press it.
    func press(_ title: String) {
        guard let button = buttons.first(where: { $0.title == title }) else { return }
        _ = button.target?.perform(button.action, with: button)
    }

    @objc private func applyTheme() {
        let theme = Settings.shared.theme
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderColor = theme.border.cgColor
        Glass.retint(surface, theme.chrome)
        label.textColor = theme.foreground
        iconView.contentTintColor = .controlAccentColor
    }

    @objc private func actionClicked(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        let run = actions[sender.tag].run
        remove()
        run()
    }

    @objc private func dismissClicked() {
        onDismiss?()
        remove()
    }

    func remove() {
        let stack = superview as? NSStackView
        removeFromSuperview()
        if let stack, stack.arrangedSubviews.isEmpty { stack.removeFromSuperview() }
    }
}

enum WindowNotices {
    private static let stackIdentifier = NSUserInterfaceItemIdentifier("FeatherWindowNotices")

    /// The cards a window is showing, newest last.
    static func cards(in window: NSWindow?) -> [NoticeCard] {
        stack(in: window, create: false)?.arrangedSubviews.compactMap { $0 as? NoticeCard } ?? []
    }

    /// Adds a card, replacing one of the same kind.
    static func show(_ card: NoticeCard, in window: NSWindow) {
        cards(in: window).filter { $0.kind == card.kind }.forEach { $0.remove() }
        stack(in: window, create: true)?.addArrangedSubview(card)
    }

    private static func stack(in window: NSWindow?, create: Bool) -> NSStackView? {
        guard let content = window?.contentView else { return nil }
        if let existing = content.subviews.first(where: { $0.identifier == stackIdentifier }) as? NSStackView { return existing }
        guard create else { return nil }
        let stack = NSStackView()
        stack.identifier = stackIdentifier
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -(StatusBarView.height + 12)),
        ])
        return stack
    }
}

// MARK: - First-time hints

/// One line of explanation the first time someone meets a part of Feather. "Got it" is remembered for good;
/// a hint that was only ignored comes back the next time Feather is opened, not again in the same session.
enum HintCards {
    enum Hint: String, CaseIterable {
        case activity, previewBanner, restrictedMode, previewSignIn

        var text: String {
            switch self {
            case .activity: return "Every file your AI assistant changes shows up here. Click one to see what changed."
            case .previewBanner: return "Feather can show your running app here, beside the code."
            case .restrictedMode: return "Restricted Mode: you can read and edit, but nothing in this folder runs until you trust it. Click “Restricted Mode” below when ready."
            case .previewSignIn: return "If signing in here brings you back to this page: many apps mark their sign-in cookie “Secure”, and this preview (like Safari) will not keep such a cookie from http://localhost. Chrome does. Use “Open in Browser” (⌃⌥B) to work signed in, or ask your AI assistant to make that cookie non-Secure for local development."
            }
        }

        var symbol: String {
            switch self {
            case .activity: return "list.bullet.rectangle"
            case .previewBanner: return "macwindow"
            case .restrictedMode: return "lock.shield"
            case .previewSignIn: return "key"
            }
        }
    }

    private static let dismissedKey = "dismissedHints"
    /// Internal so a test can start each case with nothing shown.
    static var shownThisSession = Set<Hint>()
    /// Where "Got it" is remembered; a test points this at a suite of its own.
    static var defaults: UserDefaults = .standard

    static func isDismissed(_ hint: Hint) -> Bool {
        (defaults.stringArray(forKey: dismissedKey) ?? []).contains(hint.rawValue)
    }

    /// Shows the hint in `window` unless it was dismissed before, or already shown since Feather was opened.
    static func showOnce(_ hint: Hint, in window: NSWindow?) {
        guard let window, !isDismissed(hint), !shownThisSession.contains(hint) else { return }
        // One card at a time: a hint waits for its next occasion rather than stacking up beside another card.
        guard WindowNotices.cards(in: window).isEmpty else { return }
        shownThisSession.insert(hint)
        let card = NoticeCard(kind: "hint." + hint.rawValue, symbol: hint.symbol, text: hint.text, actions: [], dismissTitle: "Got It")
        card.onDismiss = {
            var dismissed = defaults.stringArray(forKey: dismissedKey) ?? []
            if !dismissed.contains(hint.rawValue) { dismissed.append(hint.rawValue) }
            defaults.set(dismissed, forKey: dismissedKey)
        }
        WindowNotices.show(card, in: window)
    }
}

// MARK: - "Your app is running"

/// The terminal notices when a program prints the address it is serving on and posts `didDetectURL`. The window
/// it happened in offers, once per address, to show that page in a preview tab.
final class PreviewBanner {
    static let shared = PreviewBanner()
    /// userInfo: "url" (URL), "window" (NSWindow).
    static let didDetectURL = Notification.Name("FeatherTerminalDidDetectURL")
    static let cardKind = "previewBanner"

    private var offered = Set<String>()
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: PreviewBanner.didDetectURL, object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?["url"] as? URL, let window = note.userInfo?["window"] as? NSWindow else { return }
            self?.offer(url, in: window)
        }
    }

    private func offer(_ url: URL, in window: NSWindow) {
        let url = WebPreviewView.replacingAnyAddress(in: url)
        // An address elsewhere (a "Network:" line, a link in a log) is not this project's app.
        guard WebPreviewView.isLocal(url), let controller = window.windowController as? MainWindowController else { return }
        let name = WebPreviewView.shortName(of: url)
        guard !offered.contains(name) else { return }
        offered.insert(name)
        // Already looking at it: nothing to offer.
        if controller.editorArea.tabs.contains(where: { ($0.preview as? WebPreviewView)?.address.host == url.host
            && ($0.preview as? WebPreviewView)?.address.port == url.port }) { return }
        let card = NoticeCard(kind: PreviewBanner.cardKind, symbol: "play.circle", text: "Your app is running at \(name)", actions: [
            NoticeCard.Action(title: "Open Preview", isProminent: true) { [weak controller] in controller?.openPreview(at: url) },
            NoticeCard.Action(title: "Open in Browser") { WebPreviewView.openInBrowser(url) },
        ], dismissTitle: "Dismiss")
        WindowNotices.show(card, in: window)
        HintCards.showOnce(.previewBanner, in: window)
    }
}
