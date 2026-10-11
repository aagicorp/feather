import AppKit

final class StatusBarView: NSView {
    static let height: CGFloat = 22
    private let stack = NSStackView()
    private let position = NSTextField(labelWithString: "")
    private let indentation = NSTextField(labelWithString: "")
    private let encoding = NSTextField(labelWithString: "")
    private let language = NSTextField(labelWithString: "")
    private let server = NSTextField(labelWithString: "")
    /// Invisible, and laid exactly over the server label: a click anywhere on "No TypeScript LSP" opens the
    /// Language Servers window, and being a button it gets the pointing hand like everything else clickable.
    private let serverButton = NSButton(title: "", target: nil, action: #selector(AppDelegate.showExtensions(_:)))
    private let leftStack = NSStackView()
    private let restrictedButton = NSButton(title: "", target: nil, action: #selector(MainWindowController.manageTrust(_:)))
    /// Shown while follow mode is on (Activity.swift); a click opens the Activity pane, where it is switched.
    private let followButton = NSButton(title: "", target: nil, action: #selector(MainWindowController.showActivity(_:)))
    /// Shown while the folder is open without being trusted; a click asks about trusting it.
    var isRestricted = false {
        didSet { restrictedButton.isHidden = !isRestricted }
    }
    private let branchLabel = NSTextField(labelWithString: "")
    /// Invisible, over the branch: a click opens Source Control, where the branch can be switched or pushed.
    private let branchButton = NSButton(title: "", target: nil, action: #selector(MainWindowController.showSourceControl(_:)))
    private let problems = NSTextField(labelWithString: "")
    /// Invisible, over the counts: a click opens the Problems pane.
    private let problemsButton = NSButton(title: "", target: nil, action: #selector(MainWindowController.showProblems(_:)))
    /// Errors and warnings in the whole window, from the Problems store; the counts shown are these.
    var problemTotals = (errors: 0, warnings: 0)
    private let message = NSTextField(labelWithString: "")
    /// Who last changed the caret's line; filled in by the window, which owns the blame cache.
    let blameButton = BlameStatusButton()
    private var theme = Settings.shared.theme
    /// The project colour, when there is one; it replaces the neutral bar colour.
    var tint: NSColor? { didSet { needsDisplay = true } }

    /// "⎇ main ↑2 ↓1": the branch and what is waiting to be pushed or pulled. Nil outside a repository.
    var branch: Git.BranchStatus? {
        didSet {
            guard branch != oldValue else { return }
            var text = branch.map { "⎇ " + ($0.name ?? "HEAD") } ?? ""
            if let branch {
                if branch.ahead > 0 { text += "  ↑\(branch.ahead)" }
                if branch.behind > 0 { text += "  ↓\(branch.behind)" }
            }
            branchLabel.stringValue = text
            branchLabel.isHidden = branch == nil
            branchButton.isHidden = branch == nil
            var tip = "Click for Source Control."
            if let branch, branch.ahead + branch.behind > 0 {
                var parts: [String] = []
                if branch.ahead > 0 { parts.append("\(branch.ahead) commit\(branch.ahead == 1 ? "" : "s") to push") }
                if branch.behind > 0 { parts.append("\(branch.behind) to pull") }
                tip = parts.joined(separator: ", ") + ". " + tip
            }
            branchButton.toolTip = tip
        }
    }

    init() {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 18
        for label in [position, indentation, encoding, language, server] {
            label.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(label)
        }
        leftStack.orientation = .horizontal
        leftStack.spacing = 14
        for label in [branchLabel, problems, message] {
            label.font = .systemFont(ofSize: 11)
            label.lineBreakMode = .byTruncatingTail
            leftStack.addArrangedSubview(label)
        }
        leftStack.addArrangedSubview(blameButton)
        branchLabel.isHidden = true
        restrictedButton.isBordered = false
        restrictedButton.attributedTitle = NSAttributedString(string: "🛡 Restricted Mode", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.systemOrange])
        restrictedButton.toolTip = "Until you say you trust this folder, Feather will not run anything from it, check its code or track its changes. Click to decide."
        restrictedButton.isHidden = true
        leftStack.insertArrangedSubview(restrictedButton, at: 0)
        followButton.isBordered = false
        followButton.toolTip = "Follow mode is on: files are shown as something other than Feather changes them. Click for the Activity pane."
        leftStack.addArrangedSubview(followButton)
        NotificationCenter.default.addObserver(self, selector: #selector(followChanged), name: Settings.followChangesDidChange, object: nil)
        followChanged()
        message.setContentCompressionResistancePriority(.defaultLow - 10, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [stack, leftStack] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        serverButton.isTransparent = true
        serverButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(serverButton)
        problemsButton.isTransparent = true
        problemsButton.isHidden = true
        problemsButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(problemsButton)
        branchButton.isTransparent = true
        branchButton.isHidden = true
        branchButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(branchButton)
        NSLayoutConstraint.activate([
            branchButton.leadingAnchor.constraint(equalTo: branchLabel.leadingAnchor),
            branchButton.trailingAnchor.constraint(equalTo: branchLabel.trailingAnchor),
            branchButton.topAnchor.constraint(equalTo: topAnchor),
            branchButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NSLayoutConstraint.activate([
            problemsButton.leadingAnchor.constraint(equalTo: problems.leadingAnchor),
            problemsButton.trailingAnchor.constraint(equalTo: problems.trailingAnchor),
            problemsButton.topAnchor.constraint(equalTo: topAnchor),
            problemsButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NSLayoutConstraint.activate([
            serverButton.leadingAnchor.constraint(equalTo: server.leadingAnchor),
            serverButton.trailingAnchor.constraint(equalTo: server.trailingAnchor),
            serverButton.topAnchor.constraint(equalTo: topAnchor),
            serverButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leftStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: stack.leadingAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func followChanged() {
        followButton.isHidden = !Settings.shared.followChanges
        followButton.attributedTitle = NSAttributedString(string: "◉ Following changes", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor(hex: 0x3FB950)])
    }

    private func set(_ label: NSTextField, _ value: String) { if label.stringValue != value { label.stringValue = value } }

    private func colour(_ label: NSTextField, _ color: NSColor) { if label.textColor != color { label.textColor = color } }

    private func tip(_ label: NSTextField, _ value: String?) { if label.toolTip != value { label.toolTip = value } }

    /// The colour of the quiet items, which depends on the project colour behind them.
    var quietColour: NSColor { tint.map { ($0.isLight ? NSColor.black : NSColor.white).withAlphaComponent(0.85) } ?? theme.lineNumber }

    /// Runs on every cursor move, so it only touches what actually changed.
    func update(tab: EditorTab?, lsp: LSPManager) {
        let newTheme = Settings.shared.theme
        if newTheme.name != theme.name { theme = newTheme; needsDisplay = true }
        let hideDetails = tab == nil || tab?.document.isMedia == true       // a picture has no cursor or encoding
        if stack.isHidden != hideDetails { stack.isHidden = hideDetails }
        // A tab showing a picture or a preview has no editor, and asking for one here would build it just to read
        // a cursor nobody can see. `editorIfLoaded` never creates.
        let editor = tab?.editorIfLoaded
        if let tab, !hideDetails {
            if let cursor = editor?.cursorPosition { set(position, "Ln \(cursor.line), Col \(cursor.column)") } else { set(position, "") }
            // The document's own indentation: what `.editorconfig` says for it, else the settings.
            let indent = tab.document.indentation
            set(indentation, indent.useSpaces ? "Spaces: \(indent.width)" : "Tab Size: \(indent.width)")
            set(encoding, tab.encoding == .utf8 ? "UTF-8" : (tab.encoding == .utf16 ? "UTF-16" : "Latin-1"))
            set(language, tab.document.language?.name ?? "Plain Text")
        }
        set(server, lsp.statusText(for: tab?.url) ?? "")
        if server.isHidden != server.stringValue.isEmpty { server.isHidden = server.stringValue.isEmpty }
        if serverButton.isHidden != (server.isHidden || hideDetails) { serverButton.isHidden = server.isHidden || hideDetails }
        let hint = lsp.installHint(for: tab?.url) ?? "Open Extensions"
        if serverButton.toolTip != hint { serverButton.toolTip = hint }

        var errors = 0, warnings = 0
        for diagnostic in tab?.document.diagnostics ?? [] {
            if diagnostic.severity == 1 { errors += 1 } else if diagnostic.severity == 2 { warnings += 1 }
        }
        // The counts are the window's, so the way into the Problems pane stays there while another file is in front.
        let totals = (errors: max(errors, problemTotals.errors), warnings: max(warnings, problemTotals.warnings))
        set(problems, totals.errors + totals.warnings == 0 ? "" : "✕ \(totals.errors)   ⚠ \(totals.warnings)")
        if problems.isHidden != problems.stringValue.isEmpty { problems.isHidden = problems.stringValue.isEmpty }
        if problemsButton.isHidden != problems.isHidden { problemsButton.isHidden = problems.isHidden }
        let problemsTip = "\(totals.errors) errors and \(totals.warnings) warnings in this window. Click to list them (⇧⌘M)."
        if problemsButton.toolTip != problemsTip { problemsButton.toolTip = problemsTip }
        let atCursor = errors + warnings == 0 ? nil : editor?.diagnosticAtCursor
        set(message, atCursor?.message.replacingOccurrences(of: "\n", with: " ") ?? "")
        tip(message, atCursor?.message)

        let quiet = self.tint.map { ($0.isLight ? NSColor.black : NSColor.white).withAlphaComponent(0.85) } ?? theme.lineNumber
        for label in [position, indentation, encoding, language, server, branchLabel] { colour(label, quiet) }
        colour(message, atCursor?.severity == 1 ? NSColor(hex: 0xF14C4C) : quiet)
        colour(problems, totals.errors > 0 ? NSColor(hex: 0xF14C4C) : NSColor(hex: 0xCCA700))
    }

    private lazy var backdrop: Glass.Backdrop = Glass.backdrop(.titlebar, in: self)
    var backdropForTests: Glass.Backdrop { backdrop }

    override func draw(_ dirtyRect: NSRect) {
        backdrop.tint(tint ?? theme.chrome)          // the backdrop paints the ground
        guard tint == nil else { return }
        theme.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/// Places the cursor has been, across files, for the Back and Forward arrows.
final class NavigationHistory {
    struct Entry: Equatable {
        let url: URL
        var line: Int
        var character: Int
    }
    private var entries: [Entry] = []
    private var index = -1
    /// Moving within a few lines is the same "place"; it updates the current entry instead of adding one.
    private static let nearbyLines = 8
    private static let limit = 120

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < entries.count - 1 }

    func record(_ entry: Entry) {
        if index >= 0, entries[index].url == entry.url, abs(entries[index].line - entry.line) < NavigationHistory.nearbyLines {
            entries[index] = entry
            return
        }
        entries.removeSubrange((index + 1)...)          // a new place discards the "forward" branch
        entries.append(entry)
        if entries.count > NavigationHistory.limit { entries.removeFirst() }
        index = entries.count - 1
    }

    func back() -> Entry? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index]
    }

    func forward() -> Entry? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index]
    }
}
