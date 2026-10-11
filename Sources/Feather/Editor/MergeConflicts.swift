import AppKit

/// A `<<<<<<< ours … ======= … >>>>>>> theirs` block, as git leaves it in a file after a merge, a pull or a rebase
/// that it could not combine by itself; with `merge.conflictStyle diff3` there is a `||||||| base` section too.
/// Found by scanning the text; resolved by replacing the whole block with the lines to keep, the way VS Code's
/// Accept Current / Accept Incoming / Accept Both do.
struct MergeConflict: Equatable {
    enum Choice: Equatable {
        case current, incoming, both

        var actionName: String {
            switch self {
            case .current: return "Accept Current Change"
            case .incoming: return "Accept Incoming Change"
            case .both: return "Accept Both Changes"
            }
        }
    }

    /// The whole block, marker lines included.
    let range: NSRange
    /// The `<<<<<<<` line, with its line break.
    let header: NSRange
    /// What Accept Current keeps: the lines between `<<<<<<<` and `=======` (or `|||||||`).
    let current: NSRange
    /// The diff3 base section, its `|||||||` line included; nil without diff3.
    let base: NSRange?
    /// The `=======` line.
    let separator: NSRange
    /// What Accept Incoming keeps: the lines between `=======` and `>>>>>>>`.
    let incoming: NSRange
    /// The `>>>>>>>` line.
    let footer: NSRange
    let currentLabel: String
    let incomingLabel: String

    static let currentMarker = "<<<<<<< "
    static let incomingMarker = ">>>>>>> "
    static let separatorMarker = "======="
    static let baseMarker = "|||||||"

    /// Every well-formed block in `text`, in order. A `<<<<<<<` with no `=======` and `>>>>>>>` after it (before
    /// the next `<<<<<<<`) is not a conflict; a `=======` on its own never is.
    static func find(in text: NSString) -> [MergeConflict] {
        var found: [MergeConflict] = []
        var from = 0
        while from < text.length {
            let hit = text.range(of: currentMarker, options: [], range: NSRange(location: from, length: text.length - from))
            guard hit.location != NSNotFound else { break }
            from = hit.location + 1
            guard hit.location == 0 || text.character(at: hit.location - 1) == 0x0A else { continue }
            if let conflict = parse(at: hit.location, in: text) {
                found.append(conflict)
                from = NSMaxRange(conflict.range)
            }
        }
        return found
    }

    private static func parse(at start: Int, in text: NSString) -> MergeConflict? {
        func lines(_ location: Int) -> (start: Int, end: Int, contentsEnd: Int) {
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            return (lineStart, lineEnd, contentsEnd)
        }
        func begins(_ marker: String, _ line: (start: Int, end: Int, contentsEnd: Int)) -> Bool {
            let count = marker.utf16.count
            return line.contentsEnd - line.start >= count && text.substring(with: NSRange(location: line.start, length: count)) == marker
        }
        func label(after marker: String, _ line: (start: Int, end: Int, contentsEnd: Int)) -> String {
            let count = marker.utf16.count
            return text.substring(with: NSRange(location: line.start + count, length: max(0, line.contentsEnd - line.start - count)))
        }
        let headerLine = lines(start)
        let header = NSRange(location: headerLine.start, length: headerLine.end - headerLine.start)
        let currentLabel = label(after: currentMarker, headerLine)
        var position = headerLine.end
        let currentStart = position
        var current: NSRange?
        var baseStart: Int?
        var base: NSRange?
        var separator: NSRange?
        var incomingStart = 0
        while position < text.length {
            let line = lines(position)
            if separator == nil {
                if begins(currentMarker, line) { return nil }
                if begins(baseMarker, line), baseStart == nil {
                    baseStart = line.start
                    current = NSRange(location: currentStart, length: line.start - currentStart)
                } else if line.contentsEnd - line.start == separatorMarker.utf16.count, begins(separatorMarker, line) {
                    separator = NSRange(location: line.start, length: line.end - line.start)
                    if let baseStart {
                        base = NSRange(location: baseStart, length: line.start - baseStart)
                    } else {
                        current = NSRange(location: currentStart, length: line.start - currentStart)
                    }
                    incomingStart = line.end
                }
            } else if begins(incomingMarker, line) {
                guard let current, let separator else { return nil }
                return MergeConflict(range: NSRange(location: headerLine.start, length: line.end - headerLine.start),
                                     header: header, current: current, base: base, separator: separator,
                                     incoming: NSRange(location: incomingStart, length: line.start - incomingStart),
                                     footer: NSRange(location: line.start, length: line.end - line.start),
                                     currentLabel: currentLabel, incomingLabel: label(after: incomingMarker, line))
            } else if begins(currentMarker, line) {
                return nil
            }
            guard line.end > position else { break }
            position = line.end
        }
        return nil
    }

    /// The edit that resolves the block: the kept lines in place of the whole block.
    func edit(_ choice: Choice, in text: NSString) -> RangeEdit {
        let kept: String
        switch choice {
        case .current: kept = text.substring(with: current)
        case .incoming: kept = text.substring(with: incoming)
        case .both: kept = text.substring(with: current) + text.substring(with: incoming)
        }
        return RangeEdit(range: range, text: kept)
    }
}

/// Keeps a text view's conflicts marked and actionable: the current side tinted green and the incoming side blue,
/// as VS Code colours them, and after each `<<<<<<<` line the three Accept buttons. Resolving is an ordinary
/// undoable edit. Nothing is done for a file without a `<<<<<<< ` in it beyond one search of its text.
final class MergeConflictController: NSObject {
    private(set) var conflicts: [MergeConflict] = []
    private(set) var actionViews: [ConflictActionsView] = []
    private weak var textView: CodeTextView?
    private var decorated: [NSRange] = []
    private var scheduled = false
    /// Called with the number of conflicts whenever it changes.
    var onChange: ((Int) -> Void)?

    // VS Code's merge colours.
    static let currentHeader = NSColor(srgbRed: 64 / 255, green: 200 / 255, blue: 174 / 255, alpha: 0.5)
    static let currentContent = NSColor(srgbRed: 64 / 255, green: 200 / 255, blue: 174 / 255, alpha: 0.2)
    static let incomingHeader = NSColor(srgbRed: 64 / 255, green: 166 / 255, blue: 255 / 255, alpha: 0.5)
    static let incomingContent = NSColor(srgbRed: 64 / 255, green: 166 / 255, blue: 255 / 255, alpha: 0.2)
    static let baseContent = NSColor(srgbRed: 128 / 255, green: 128 / 255, blue: 128 / 255, alpha: 0.2)

    func attach(to textView: CodeTextView) {
        self.textView = textView
        if let storage = textView.textStorage {
            NotificationCenter.default.addObserver(self, selector: #selector(schedule), name: NSTextStorage.didProcessEditingNotification, object: storage)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(schedule), name: NSView.frameDidChangeNotification, object: textView)
        schedule()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Coalesces the edits of one turn of the run loop into one scan.
    @objc func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.scheduled = false
            self?.update()
        }
    }

    func update() {
        guard let textView, let storage = textView.textStorage, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let text = storage.mutableString
        let found = text.range(of: MergeConflict.currentMarker).location == NSNotFound ? [] : MergeConflict.find(in: text)
        let changed = found != conflicts
        conflicts = found
        for range in decorated {
            let clamped = NSRange(location: min(range.location, text.length), length: 0)
            let length = min(range.length, text.length - clamped.location)
            if length > 0 { layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: clamped.location, length: length)) }
        }
        decorated = []
        func tint(_ range: NSRange, _ color: NSColor) {
            guard range.length > 0 else { return }
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
            decorated.append(range)
        }
        for conflict in conflicts {
            tint(conflict.header, MergeConflictController.currentHeader)
            tint(conflict.current, MergeConflictController.currentContent)
            if let base = conflict.base { tint(base, MergeConflictController.baseContent) }
            tint(conflict.incoming, MergeConflictController.incomingContent)
            tint(conflict.footer, MergeConflictController.incomingHeader)
        }
        while actionViews.count > conflicts.count { actionViews.removeLast().removeFromSuperview() }
        while actionViews.count < conflicts.count {
            let view = ConflictActionsView()
            view.onChoose = { [weak self, weak view] choice in
                guard let self, let view, let index = self.actionViews.firstIndex(where: { $0 === view }) else { return }
                self.resolve(index, choice)
            }
            textView.addSubview(view)
            actionViews.append(view)
        }
        for (index, conflict) in conflicts.enumerated() {
            let view = actionViews[index]
            view.setLabels(current: conflict.currentLabel, incoming: conflict.incomingLabel)
            // The line fragment's used rect ends where "<<<<<<< HEAD" ends. The glyph range's bounding rect
            // would take in the line break, which spans the whole (unbounded) container width.
            let glyphs = layoutManager.glyphRange(forCharacterRange: conflict.header, actualCharacterRange: nil)
            var line = glyphs.length > 0 ? layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                                         : layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            line.origin.x += textView.textContainerOrigin.x
            line.origin.y += textView.textContainerOrigin.y
            let size = view.fittingSize
            view.frame = NSRect(x: line.maxX + 16, y: line.minY + floor((line.height - size.height) / 2), width: size.width, height: size.height)
        }
        if changed { onChange?(conflicts.count) }
    }

    /// Replaces the block with the chosen lines; one undo step named after the choice.
    func resolve(_ index: Int, _ choice: MergeConflict.Choice) {
        guard let textView, let storage = textView.textStorage, conflicts.indices.contains(index) else { return }
        let edit = conflicts[index].edit(choice, in: storage.mutableString)
        guard textView.shouldChangeText(in: edit.range, replacementString: edit.text) else { return }
        storage.replaceCharacters(in: edit.range, with: edit.text)
        textView.didChangeText()
        textView.undoManager?.setActionName(choice.actionName)
        textView.setSelectedRange(NSRange(location: edit.range.location, length: 0))
        update()
    }

    /// Every block at once, as VS Code's "Accept All Current/Incoming" commands do; bottom-up so the ranges hold.
    func resolveAll(_ choice: MergeConflict.Choice) {
        guard let textView, let storage = textView.textStorage, !conflicts.isEmpty else { return }
        let edits = conflicts.map { $0.edit(choice, in: storage.mutableString) }
        guard textView.shouldChangeText(inRanges: edits.map { NSValue(range: $0.range) }, replacementStrings: edits.map(\.text)) else { return }
        storage.beginEditing()
        for edit in edits.reversed() { storage.replaceCharacters(in: edit.range, with: edit.text) }
        storage.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName(choice.actionName)
        update()
    }
}

/// "Accept Current | Accept Incoming | Accept Both" after a `<<<<<<<` line: small text buttons on a rounded
/// ground of the editor's colour, so they read over the green header.
final class ConflictActionsView: NSView {
    var onChoose: ((MergeConflict.Choice) -> Void)?
    private let stack = NSStackView()
    private var buttons: [NSButton] = []
    private static let choices: [(String, MergeConflict.Choice)] = [("Accept Current", .current), ("Accept Incoming", .incoming), ("Accept Both", .both)]

    private var surface: NSView!

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 18))
        wantsLayer = true
        surface = Glass.panel(around: NSView(), cornerRadius: 9, tint: Settings.shared.theme.background)
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor), surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor), surface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 1, left: 6, bottom: 1, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for (index, (title, _)) in ConflictActionsView.choices.enumerated() {
            if index > 0 {
                let divider = NSTextField(labelWithString: "|")
                divider.font = .systemFont(ofSize: 10)
                divider.textColor = Settings.shared.theme.lineNumber
                stack.addArrangedSubview(divider)
            }
            let button = NSButton(title: title, target: self, action: #selector(clicked(_:)))
            button.isBordered = false
            button.tag = index
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.contentTintColor = Settings.shared.theme.accent
            button.setContentHuggingPriority(.required, for: .horizontal)
            buttons.append(button)
            stack.addArrangedSubview(button)
        }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func applyTheme() {
        let theme = Settings.shared.theme
        Glass.retint(surface, Glass.isActive ? theme.background : theme.background.withAlphaComponent(0.92))
        for button in buttons { button.contentTintColor = theme.accent }
    }

    func setLabels(current: String, incoming: String) {
        buttons[0].toolTip = "Keep what is on this branch (\(current))"
        buttons[1].toolTip = "Keep what is coming in (\(incoming))"
        buttons[2].toolTip = "Keep both, this branch's lines first"
    }

    @objc private func clicked(_ sender: NSButton) { onChoose?(ConflictActionsView.choices[sender.tag].1) }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
