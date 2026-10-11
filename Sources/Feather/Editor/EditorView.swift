import AppKit

final class CodeTextView: NSTextView {
    var indentAfterColon = false
    var lineComment: String?

    /// The text without copying it: `string` bridges the whole document into a new Swift String on every call,
    /// which is far too much to do on each Return, Tab or ⌘-hover.
    var textContents: NSString { textStorage?.mutableString ?? "" }

    /// The two brackets currently tinted, so clearing them touches two characters rather than the document.
    var bracketHighlights: [NSRange] = []
    /// Caret and edit count the tint was last worked out for; a keystroke raises both a selection change and a
    /// text change, and the second of the two has nothing new to find.
    var bracketMatchKey: (location: Int, edits: Int) = (-1, -1)
    var editCount = 0

    /// Set when the last edit was a single typed character or a backspace; EditorView reads and clears it.
    var lastEditWasTyping = false
    /// Returns true when the completion popup consumed the key.
    var completionKeyHandler: ((NSEvent) -> Bool)?
    var onCommandClick: ((Int) -> Void)?
    var onGoToDefinition: (() -> Void)?
    var onShowQuickInfo: (() -> Void)?
    var onFindReferences: (() -> Void)?
    var onRenameSymbol: (() -> Void)?
    var onTriggerCompletion: (() -> Void)?
    var onResignFocus: (() -> Void)?
    var onFocus: (() -> Void)?
    var onOpenFiles: (([URL]) -> Void)?

    /// The cursors beyond the text view's own; see MultiCursor.swift.
    let multiCursor = MultiCursorState()
    /// What is folded away in this view, so carets and clicks can keep out of it; see CodeFolding.swift.
    weak var folds: FoldingController?

    private func droppedFiles(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { super.acceptableDragTypes + [.fileURL] }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = droppedFiles(sender)
        guard !files.isEmpty, let onOpenFiles else { return super.performDragOperation(sender) }
        onOpenFiles(files)
        return true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            EditorOnlyKeys.setActive(true)
            onFocus?()
        }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        if completionKeyHandler?(event) == true { return }
        if handleLineKey(event) { return }
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        // Typing with several cursors types at each of them. An explicit range that is not simply the primary
        // selection (an input method, an accepted completion) is about one place only, and is left to be so.
        if isMultiCursor, !hasMarkedText(), replacementRange.location == NSNotFound || replacementRange == selectedRange() {
            lastEditWasTyping = false
            insertAtCursors(text)
            return
        }
        lastEditWasTyping = text.count == 1 && text != "\n"
        // While an input method is composing, the text is its business, not ours.
        if lastEditWasTyping, !hasMarkedText(), Settings.shared.autoCloseBrackets,
           let character = text.utf16.first, text.utf16.count == 1,
           typePaired(character, replacementRange: replacementRange) { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// For the pair commands, which have worked out the text themselves and only need it typed.
    func insertPlain(_ text: String, replacementRange: NSRange) {
        super.insertText(text, replacementRange: replacementRange)
    }

    /// Every key command passes through here on its way to its method, which is where several cursors take over.
    override func doCommand(by selector: Selector) {
        if isMultiCursor, !hasMarkedText(), performAtCursors(selector) { return }
        super.doCommand(by: selector)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        selectionChangedFromOutside()
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }

    override func paste(_ sender: Any?) {
        if isMultiCursor, pasteAtCursors() { return }
        super.paste(sender)
    }

    override func copy(_ sender: Any?) {
        if isMultiCursor { copyAtCursors() } else { super.copy(sender) }
    }

    override func cut(_ sender: Any?) {
        guard isMultiCursor else { return super.cut(sender) }
        copyAtCursors()
        applyCursorEdits(allCursors.map { .replacing($0.range, with: "") })
    }

    /// At the end of a folded header the caret would be drawn one character early (see `doorstepX`).
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var rect = rect
        let location = selectedRange().location
        if let folds, let layoutManager, let textContainer, let hidden = folds.hiddenRange(containing: location + 1), hidden.location == location {
            rect.origin.x = folds.doorstepX(of: hidden, layoutManager: layoutManager, container: textContainer) + textContainerOrigin.x
        }
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if isMultiCursor { drawExtraSelections(in: rect) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isMultiCursor { drawExtraCarets(in: dirtyRect) }
        folds?.drawMarkers(in: dirtyRect)
    }

    override func deleteBackward(_ sender: Any?) {
        lastEditWasTyping = true
        if Settings.shared.autoCloseBrackets, deleteEmptyPair() { return }
        super.deleteBackward(sender)
    }

    // MARK: ⌘-hover link

    /// Asks whether the identifier at (index, word) has somewhere to go; the answer decides if it is underlined.
    var onLinkProbe: ((Int, String, @escaping (Bool) -> Void) -> Void)?
    /// The link colours were laid over the syntax colours of this range; this asks the editor to put those back.
    var onLinkCleared: ((NSRange) -> Void)?
    private var linkRange: NSRange?
    private var probedRange: NSRange?
    private var commandIsDown = false
    private var hoverTracking: NSTrackingArea?
    private static let linkColor = NSColor(hex: 0x4DA3FF)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    func identifierRange(at index: Int) -> NSRange? {
        let ns = textContents
        guard index >= 0, index < ns.length else { return nil }
        func isIdentifier(_ unit: unichar) -> Bool {
            guard let scalar = UnicodeScalar(unit) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || unit == 0x5F || unit == 0x24
        }
        guard isIdentifier(ns.character(at: index)) else { return nil }
        var start = index, end = index
        while start > 0, isIdentifier(ns.character(at: start - 1)) { start -= 1 }
        while end < ns.length, isIdentifier(ns.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private func updateLink(at windowPoint: NSPoint, commandHeld: Bool) {
        commandIsDown = commandHeld
        guard commandHeld, Settings.shared.commandClickNavigation, let layoutManager, let textContainer else { return clearLink() }
        var point = convert(windowPoint, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        // glyphIndex(for:) snaps to the nearest glyph, so make sure the pointer is really on it.
        guard layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(point),
              let range = identifierRange(at: layoutManager.characterIndexForGlyph(at: glyph)) else { return clearLink() }
        if range == linkRange { NSCursor.pointingHand.set(); return }
        if range == probedRange { return }
        clearLink()
        probedRange = range
        let word = (textContents).substring(with: range)
        onLinkProbe?(range.location, word) { [weak self] exists in
            guard let self, exists, self.probedRange == range, self.commandIsDown,
                  NSMaxRange(range) <= (self.textContents).length else { return }
            self.layoutManager?.addTemporaryAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: CodeTextView.linkColor,
                .foregroundColor: CodeTextView.linkColor], forCharacterRange: range)
            self.linkRange = range
            NSCursor.pointingHand.set()
        }
    }

    func clearLink() {
        probedRange = nil
        guard let range = linkRange else { return }
        linkRange = nil
        if NSMaxRange(range) <= (textContents).length {
            layoutManager?.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
            layoutManager?.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
        }
        onLinkCleared?(range)
        NSCursor.iBeam.set()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateLink(at: event.locationInWindow, commandHeld: event.modifierFlags.contains(.command))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearLink()
    }

    /// Pressing or releasing ⌘ with the pointer already resting on a name.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window else { return }
        updateLink(at: window.mouseLocationOutsideOfEventStream, commandHeld: event.modifierFlags.contains(.command))
    }

    override func mouseDown(with event: NSEvent) {
        clearLink()
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command), Settings.shared.commandClickNavigation, let onCommandClick {
            onCommandClick(characterIndexForInsertion(at: point))
            return
        }
        if folds?.unfoldMarker(at: point) == true { return }
        // ⌥-click adds a cursor (or takes one away).
        if event.modifierFlags.intersection([.option, .command, .control, .shift]) == [.option] {
            window?.makeFirstResponder(self)
            toggleCursor(at: characterIndexForInsertion(at: point))
            return
        }
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        onResignFocus?()
        let resigned = super.resignFirstResponder()
        if resigned { EditorOnlyKeys.setActive(false) }
        return resigned
    }

    // Esc / F5 would otherwise open the system word-completion list.
    override func complete(_ sender: Any?) { onTriggerCompletion?() }

    @objc func goToDefinition(_ sender: Any?) { onGoToDefinition?() }

    @objc func showQuickInfo(_ sender: Any?) { onShowQuickInfo?() }

    @objc func findReferences(_ sender: Any?) { onFindReferences?() }

    @objc func renameSymbol(_ sender: Any?) { onRenameSymbol?() }

    @objc func triggerCompletion(_ sender: Any?) { onTriggerCompletion?() }

    var indentUnit: String {
        indentation.unit
    }

    private var selectionSpansLines: Bool {
        let range = selectedRange()
        guard range.length > 0 else { return false }
        return (textContents).substring(with: range).contains("\n")
    }

    override func insertTab(_ sender: Any?) {
        if selectionSpansLines {
            let unit = indentUnit
            transformSelectedLines { $0.isEmpty ? $0 : unit + $0 }
        } else if indentation.useSpaces {
            let ns = textContents
            let location = selectedRange().location
            let lineStart = ns.lineRange(for: NSRange(location: location, length: 0)).location
            let width = indentation.width
            let count = width - ((location - lineStart) % width)
            insertText(String(repeating: " ", count: count), replacementRange: selectedRange())
        } else {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        let width = indentation.width
        transformSelectedLines { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let spaces = line.prefix(width).prefix { $0 == " " }.count
            return String(line.dropFirst(spaces))
        }
    }

    /// What a new line started at `location` begins with: the indentation of the line being left, and one step
    /// more after something that opens a block.
    func newlineIndent(at location: Int) -> String {
        let ns = textContents
        let lineStart = ns.lineRange(for: NSRange(location: location, length: 0)).location
        let beforeCursor = ns.substring(with: NSRange(location: lineStart, length: location - lineStart))
        var indent = String(beforeCursor.prefix { $0 == " " || $0 == "\t" })
        if let last = beforeCursor.trimmingCharacters(in: .whitespaces).last {
            if "{[(".contains(last) || (indentAfterColon && last == ":") { indent += indentUnit }
        }
        return indent
    }

    override func insertNewline(_ sender: Any?) {
        if openPairOntoNewLines() { return }
        let indent = newlineIndent(at: selectedRange().location)
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }
    }

    @objc func toggleComment(_ sender: Any?) {
        guard let token = lineComment else { NSSound.beep(); return }
        let ns = textContents
        let lines = ns.substring(with: ns.lineRange(for: selectedRange())).components(separatedBy: "\n")
        let meaningful = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !meaningful.isEmpty && meaningful.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(token)
        }
        transformSelectedLines { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            var body = String(line.dropFirst(indent.count))
            if allCommented {
                body.removeFirst(token.count)
                if body.hasPrefix(" ") { body.removeFirst() }
                return indent + body
            }
            return indent + token + " " + body
        }
    }

    private func transformSelectedLines(_ transform: (String) -> String) {
        let ns = textContents
        let lineRange = ns.lineRange(for: selectedRange())
        let text = ns.substring(with: lineRange)
        var lines = text.components(separatedBy: "\n")
        let hasTrailingNewline = text.hasSuffix("\n")
        if hasTrailingNewline { lines.removeLast() }
        let replaced = lines.map(transform).joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        guard replaced != text, shouldChangeText(in: lineRange, replacementString: replaced) else { return }
        textStorage?.replaceCharacters(in: lineRange, with: replaced)
        didChangeText()
        let length = (replaced as NSString).length - (hasTrailingNewline ? 1 : 0)
        setSelectedRange(NSRange(location: lineRange.location, length: max(0, length)))
    }
}

final class GutterView: NSView {
    weak var textView: NSTextView?
    var theme = Settings.shared.theme { didSet { rebuildDrawingCache() } }
    var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular) { didSet { rebuildDrawingCache() } }

    var changeMarkers: [Int: LineChange] = [:] { didSet { needsDisplay = true } }
    var errorLines = Set<Int>() { didSet { if errorLines != oldValue { needsDisplay = true } } }

    /// Offset at which each line starts. Kept up to date edit by edit; only a whole-text replacement rebuilds it.
    private var lineStarts: [Int] = [0]
    private var lineStartsDirty = true

    // Built once per theme/font rather than once per line per redraw.
    private var normalAttributes: [NSAttributedString.Key: Any] = [:]
    private var activeAttributes: [NSAttributedString.Key: Any] = [:]
    private var errorAttributes: [NSAttributedString.Key: Any] = [:]
    private(set) var digitWidth: CGFloat = 7
    private var digitHeight: CGFloat = 13
    private static let addedColor = NSColor(hex: 0x3FB950), modifiedColor = NSColor(hex: 0x3B8EEA), deletedColor = NSColor(hex: 0xF14C4C)
    /// The line the caret is on, so a caret move within one line does not redraw the gutter.
    private var drawnActiveLine = -1

    /// Says which lines are folded away (they get no number) and which open a block (they get a chevron).
    weak var folding: FoldingController?
    /// Room between the numbers and the text for the fold chevron and the git bar.
    static let chevronStrip: CGFloat = 20
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// A click on a chevron folds or unfolds that line's block.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x >= bounds.width - GutterView.chevronStrip, let folding, let line = line(atY: point.y) else {
            return super.mouseDown(with: event)
        }
        folding.toggle(line: line)
    }

    /// The line drawn at this height of the gutter, if there is one.
    private func line(atY y: CGFloat) -> Int? {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
              textView.textStorage?.length ?? 0 > 0 else { return nil }
        let inText = textView.convert(NSPoint(x: 0, y: y), from: self).y - textView.textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: inText), in: container)
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard inText >= rect.minY, inText <= rect.maxY else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        return line(containing: folding?.hiddenRange(containing: character)?.location ?? character).index
    }

    private func drawChevron(folded: Bool, lineRect: NSRect, y: CGFloat) {
        let center = NSPoint(x: bounds.width - 12, y: y + lineRect.height / 2)
        let path = NSBezierPath()
        if folded {
            path.move(to: NSPoint(x: center.x - 1.5, y: center.y - 3.5))
            path.line(to: NSPoint(x: center.x + 2, y: center.y))
            path.line(to: NSPoint(x: center.x - 1.5, y: center.y + 3.5))
        } else {
            path.move(to: NSPoint(x: center.x - 3.5, y: center.y - 1.5))
            path.line(to: NSPoint(x: center.x, y: center.y + 2))
            path.line(to: NSPoint(x: center.x + 3.5, y: center.y - 1.5))
        }
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        (folded ? theme.activeLineNumber : theme.lineNumber).setStroke()
        path.stroke()
    }

    override var isFlipped: Bool { true }

    private func rebuildDrawingCache() {
        normalAttributes = [.font: font, .foregroundColor: theme.lineNumber]
        activeAttributes = [.font: font, .foregroundColor: theme.activeLineNumber]
        errorAttributes = [.font: font, .foregroundColor: GutterView.deletedColor]
        // The font has fixed-width digits, so a number's width is its digit count times this.
        let size = ("8" as NSString).size(withAttributes: normalAttributes)
        digitWidth = size.width
        digitHeight = size.height
        needsDisplay = true
    }

    func invalidateLines() {
        lineStartsDirty = true
        needsDisplay = true
    }

    /// Call from the storage's did-process-editing notification, while `editedRange`/`changeInLength` are valid.
    /// Adjusts the table for just the edited span: the lines after it shift by `delta`, which is a tight integer loop.
    func applyEdit(_ edited: NSRange, delta: Int) {
        needsDisplay = true
        guard !lineStartsDirty, let ns = textView?.textStorage?.mutableString else { return }
        let oldEnd = NSMaxRange(edited) - delta
        guard oldEnd >= edited.location, NSMaxRange(edited) <= ns.length else { lineStartsDirty = true; return }
        // First line start strictly after the edit's beginning…
        var low = 0, high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= edited.location { low = mid + 1 } else { high = mid }
        }
        // …through the last one whose newline was inside the replaced text.
        var end = low
        while end < lineStarts.count, lineStarts[end] <= oldEnd { end += 1 }
        var fresh: [Int] = []
        var search = edited
        while search.length > 0 {
            let found = ns.range(of: "\n", options: .literal, range: search)
            if found.location == NSNotFound { break }
            fresh.append(NSMaxRange(found))
            search = NSRange(location: NSMaxRange(found), length: NSMaxRange(edited) - NSMaxRange(found))
        }
        if delta != 0 { for index in end..<lineStarts.count { lineStarts[index] += delta } }
        lineStarts.replaceSubrange(low..<end, with: fresh)
    }

    private func rebuildLineStartsIfNeeded() {
        guard lineStartsDirty, let ns = textView?.textStorage?.mutableString else { return }
        lineStartsDirty = false
        var starts = [0]
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let found = ns.range(of: "\n", options: .literal, range: search)
            if found.location == NSNotFound { break }
            let next = NSMaxRange(found)
            starts.append(next)
            search = NSRange(location: next, length: ns.length - next)
        }
        lineStarts = starts
    }

    var lineCount: Int {
        rebuildLineStartsIfNeeded()
        return lineStarts.count
    }

    /// For tests: the incrementally maintained table must always equal a from-scratch rebuild.
    var lineTableMatchesFullRebuild: Bool {
        rebuildLineStartsIfNeeded()
        let current = lineStarts
        lineStartsDirty = true
        rebuildLineStartsIfNeeded()
        return current == lineStarts
    }

    /// Zero-based line index and that line's start offset for a character location.
    func line(containing location: Int) -> (index: Int, start: Int) {
        rebuildLineStartsIfNeeded()
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return (low, lineStarts[low])
    }

    func startOfLine(_ index: Int) -> Int {
        rebuildLineStartsIfNeeded()
        return lineStarts[max(0, min(index, lineStarts.count - 1))]
    }

    /// Redraws only if the caret moved to a different line.
    func caretMoved() {
        guard let textView else { return }
        if line(containing: textView.selectedRange().location).index != drawnActiveLine { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        if !Glass.isActive {            // with glass the panel behind paints the background
            theme.background.setFill()
            bounds.fill()
        }
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer, let ns = textView.textStorage?.mutableString else { return }
        if normalAttributes.isEmpty { rebuildDrawingCache() }

        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let activeLine = line(containing: textView.selectedRange().location)
        drawnActiveLine = activeLine.index
        let activeLineStart = activeLine.start

        func drawNumber(_ number: Int, lineRect: NSRect, active: Bool) {
            let attributes = errorLines.contains(number - 1) ? errorAttributes : (active ? activeAttributes : normalAttributes)
            let y = convert(NSPoint(x: 0, y: lineRect.minY + origin.y), from: textView).y
            if let change = changeMarkers[number - 1] {
                switch change {
                case .added: GutterView.addedColor.setFill()
                case .modified: GutterView.modifiedColor.setFill()
                case .deletedAbove: GutterView.deletedColor.setFill()
                }
                let bar = change == .deletedAbove
                    ? NSRect(x: bounds.width - 6, y: y - 1, width: 6, height: 3)
                    : NSRect(x: bounds.width - 4, y: y, width: 3, height: lineRect.height)
                bar.fill()
            }
            let label = String(number)
            let width = CGFloat(label.count) * digitWidth
            (label as NSString).draw(at: NSPoint(x: bounds.width - width - GutterView.chevronStrip, y: y + (lineRect.height - digitHeight) / 2),
                                     withAttributes: attributes)
        }

        var index = charRange.location
        // Should the first thing on screen be folded away, start from the header it is folded into.
        if let hidden = folding?.hiddenRange(containing: index) { index = hidden.location }
        var number = line(containing: index).index + 1
        index = startOfLine(number - 1)
        let regions = isHovered ? folding?.regions : nil
        while index < ns.length && index <= NSMaxRange(charRange) {
            let glyph = layoutManager.glyphIndexForCharacter(at: index)
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            drawNumber(number, lineRect: rect, active: index == activeLineStart)
            // The table already knows where the next line starts; no need to ask the string.
            let next = number < lineStarts.count ? lineStarts[number] : ns.length
            let hidden = folding?.hiddenRange(startingIn: NSRange(location: index, length: next - index))
            if hidden != nil || regions?.isHeader(number - 1) == true {
                drawChevron(folded: hidden != nil, lineRect: rect, y: convert(NSPoint(x: 0, y: rect.minY + origin.y), from: textView).y)
            }
            if let hidden {
                // The folded lines have no place on screen and get no number: on to the line after the block.
                number = line(containing: NSMaxRange(hidden)).index + 1
                index = number < lineStarts.count ? lineStarts[number] : ns.length
            } else {
                index = next
            }
            number += 1
        }
        // The empty last line (after a trailing newline, or in an empty file) has no glyphs of its own.
        let endsWithNewline = ns.length == 0 || ns.character(at: ns.length - 1) == 0x0A
        if endsWithNewline && NSMaxRange(charRange) >= ns.length {
            let rect = layoutManager.extraLineFragmentRect
            if rect.height > 0 {
                drawNumber(lineCount, lineRect: rect, active: activeLineStart == ns.length)
            }
        }
    }
}

/// Where the user was in a file. A tab keeps this while it has no editor, so a rebuilt editor opens at the same place.
struct EditorViewState {
    var selection: NSRange
    /// The top of the viewport as "this far into the line that starts at this character", which survives a different
    /// pane width, word wrap and font size; a plain y offset would not.
    var topCharacter: Int
    var topOffset: CGFloat
    var x: CGFloat
    /// The hidden character ranges of the folds. Put back only where the text still has the same block there.
    var folds: [NSRange] = []
}

final class EditorView: NSView, NSTextViewDelegate {
    let textView: CodeTextView
    let scrollView = NSScrollView()
    let document: TextDocument
    private let storage: NSTextStorage
    let gutter = GutterView()
    let folding: FoldingController
    let stickyHeader = StickyHeaderView()
    var stickyHeight: NSLayoutConstraint!
    /// The line at the top of the viewport when the pinned lines were last worked out.
    var stickyTopLine = -1
    private var gutterWidth: NSLayoutConstraint!
    private var highlightPending = false
    private var caretCheckPending = false
    private var fullHighlightWork: DispatchWorkItem?
    /// What this view has coloured from the syntax tree, so a pass changes only what differs.
    private let treeColours = TreeHighlightState()
    private var colouredLanguage: TreeSitterLanguage?
    private var needsRefreshWhenShown = false
    /// Below this size the whole document is re-highlighted on edit; above it only the visible region is.
    private let fullHighlightLimit = 120_000

    /// Merge conflict blocks in this file: tinted, with Accept buttons after each `<<<<<<<` line.
    let conflicts = MergeConflictController()
    var onTextChange: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var onOpenFiles: (([URL]) -> Void)?

    // Code intelligence hooks, wired to the language server by the editor area. Positions are (line, UTF-16 column).
    var onCompletionRequest: ((Int, Int, @escaping ([LSPCompletionItem]) -> Void) -> Void)?
    /// (line, character, the identifier there)
    var onDefinitionRequest: ((Int, Int, String) -> Void)?
    /// Whether a language server is answering for this file; without one, suggestions come from the file itself.
    var isLanguageServerReady: (() -> Bool)?
    /// (line, character, identifier, answer): does this name have a definition to jump to?
    var onDefinitionProbe: ((Int, Int, String, @escaping (Bool) -> Void) -> Void)?
    var onHoverRequest: ((Int, Int, @escaping (String?) -> Void) -> Void)?
    /// (line, character, the identifier under the cursor)
    var onReferencesRequest: ((Int, Int, String) -> Void)?
    var onRenameRequest: ((Int, Int, String) -> Void)?
    var completionTriggers: (() -> Set<Character>)?

    var diagnostics: [LSPDiagnostic] { document.diagnostics }
    var onFocus: (() -> Void)?
    private let completionPopup = CompletionPopup()
    private var completionItems: [LSPCompletionItem] = [] {
        didSet {
            // The file's own word list arrives with its keys already made (see `localWords`).
            if let ready = readyKeys, ready.count == completionItems.count { completionKeys = ready }
            else { completionKeys = completionItems.map { Array($0.filterText.lowercased().utf16) } }
            readyKeys = nil
        }
    }
    /// Each item's lower-cased filter text, made once per list: the list is narrowed on every keystroke, and
    /// lower-casing and walking a few thousand Swift strings each time was most of the cost of typing in a big file.
    private var completionKeys: [[UInt16]] = []
    private var readyKeys: [[UInt16]]?
    /// The words of this file, as suggestions. Scanning a big file for them costs tens of milliseconds, and it used
    /// to happen each time a new word was started; the list is now kept until enough has changed to matter.
    private struct LocalWords {
        var items: [LSPCompletionItem]
        var keys: [[UInt16]]
        var changeCount: Int
        var centre: Int
        var date: Date
    }
    private var localWords: LocalWords?
    private var completionAnchor = 0
    private var completionRequestID = 0
    private var hoverPopover: NSPopover?

    private var gitDiffGeneration = 0
    private var gitDiffWork: DispatchWorkItem?
    private static let diffQueue = DispatchQueue(label: "feather.diff", qos: .utility)

    var language: Language? { document.language }

    /// Several editor views can show one document; each adds its own layout manager to the shared storage.
    init(document: TextDocument) {
        self.document = document
        storage = document.storage
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        folding = FoldingController(textView: textView, gutter: gutter)
        super.init(frame: .zero)
        layoutManager.delegate = folding
        textView.folds = folding
        gutter.folding = folding
        folding.onChange = { [weak self] in
            self?.gutter.needsDisplay = true
            self?.updateStickyScroll(force: true)
        }

        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 6)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.hasHorizontalScroller = true
        scrollView.useFeatherScrollers()
        textView.postsFrameChangedNotifications = true

        gutter.textView = textView
        conflicts.attach(to: textView)
        for view in [gutter, scrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        gutterWidth = gutter.widthAnchor.constraint(equalToConstant: 44)
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutterWidth,
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // Added last, so it lies over the top of both the gutter and the text.
        stickyHeader.translatesAutoresizingMaskIntoConstraints = false
        stickyHeader.isHidden = true
        stickyHeader.onClick = { [weak self] line in self?.goToLine(line + 1) }
        addSubview(stickyHeader)
        stickyHeight = stickyHeader.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stickyHeader.leadingAnchor.constraint(equalTo: leadingAnchor),
            stickyHeader.trailingAnchor.constraint(equalTo: trailingAnchor),
            stickyHeader.topAnchor.constraint(equalTo: topAnchor),
            stickyHeight,
        ])

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(viewportChanged(_:)),
                           name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        center.addObserver(self, selector: #selector(viewportChanged(_:)),
                           name: NSView.frameDidChangeNotification, object: textView)

        textView.completionKeyHandler = { [weak self] in self?.handleCompletionKey($0) ?? false }
        textView.onTriggerCompletion = { [weak self] in self?.requestCompletion(manual: true) }
        textView.onResignFocus = { [weak self] in self?.completionPopup.hide() }
        textView.onCommandClick = { [weak self] index in
            guard let self else { return }
            let position = self.position(of: index)
            self.onDefinitionRequest?(position.line, position.character, self.word(at: index))
        }
        textView.onGoToDefinition = { [weak self] in
            guard let self else { return }
            let cursor = self.textView.selectedRange().location
            let position = self.position(of: cursor)
            self.onDefinitionRequest?(position.line, position.character, self.word(at: cursor))
        }
        textView.onShowQuickInfo = { [weak self] in self?.showQuickInfo() }
        textView.onLinkProbe = { [weak self] index, word, answer in
            guard let self, let probe = self.onDefinitionProbe else { return answer(false) }
            // Keywords never lead anywhere, so do not even ask.
            if self.language?.keywordList.contains(word) == true { return answer(false) }
            let position = self.position(of: index)
            probe(position.line, position.character, word, answer)
        }
        textView.onLinkCleared = { [weak self] range in
            self?.treeColours.noteEdit(range, delta: 0)          // the link colour sits where a token's was
            self?.scheduleHighlight()
            self?.applyDiagnostics()
        }
        textView.onFindReferences = { [weak self] in
            guard let self else { return }
            let position = self.position(of: self.textView.selectedRange().location)
            self.onReferencesRequest?(position.line, position.character, self.wordAtCursor)
        }
        textView.onRenameSymbol = { [weak self] in
            guard let self, !self.wordAtCursor.isEmpty else { NSSound.beep(); return }
            let position = self.position(of: self.textView.selectedRange().location)
            self.onRenameRequest?(position.line, position.character, self.wordAtCursor)
        }
        completionPopup.onAccept = { [weak self] in self?.accept($0) }
        textView.onFocus = { [weak self] in self?.onFocus?() }
        textView.onOpenFiles = { [weak self] in self?.onOpenFiles?($0) }

        center.addObserver(self, selector: #selector(storageDidChange(_:)),
                           name: NSTextStorage.didProcessEditingNotification, object: storage)
        center.addObserver(self, selector: #selector(documentStateChanged),
                           name: TextDocument.stateDidChange, object: document)
        center.addObserver(self, selector: #selector(diagnosticsChanged),
                           name: TextDocument.diagnosticsDidChange, object: document)
        center.addObserver(self, selector: #selector(gitBaseChanged),
                           name: TextDocument.gitBaseDidChange, object: document)
        center.addObserver(self, selector: #selector(syntaxTreeUpdated(_:)), name: SyntaxTreeController.didUpdate, object: nil)
        documentStateChanged()
        applySettings()
        scheduleGitDiff(delay: 0)
        folding.scheduleRegions(after: 0.05)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // Tabs release editors that have not been shown for a while; neither popup may outlive its editor.
        completionPopup.hide()
        hoverPopover?.close()
        // The storage belongs to the document and may outlive this view.
        if let layoutManager = textView.layoutManager { storage.removeLayoutManager(layoutManager) }
    }

    var text: String { storage.string }

    func undoManager(for view: NSTextView) -> UndoManager? { document.undoManager }

    /// Fires for edits made in any view of this document, not just this one.
    @objc private func storageDidChange(_ notification: Notification) {
        guard storage.editedMask.contains(.editedCharacters) else { return }
        // The line table is corrected here, synchronously, so anything that asks for the cursor's line during this
        // same edit (the status bar, navigation history) gets the right answer.
        gutter.applyEdit(storage.editedRange, delta: storage.changeInLength)
        textView.bracketsNoteEdit(storage.editedRange, delta: storage.changeInLength)
        folding.noteEdit(storage.editedRange, delta: storage.changeInLength)
        treeColours.noteEdit(storage.editedRange, delta: storage.changeInLength)
        // A pane that is not on screen (an unselected tab showing the same file) catches up when it is shown.
        guard window != nil else { needsRefreshWhenShown = true; return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateGutterWidth()
            self.scheduleHighlight()
            self.scheduleGitDiff()
            self.folding.scheduleRegions()
            // For the pane that was not typed in: its caret did not move, but the brackets around it may have.
            self.textView.updateBracketMatch()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, needsRefreshWhenShown else { return }
        needsRefreshWhenShown = false
        updateGutterWidth()
        scheduleHighlight()
        scheduleGitDiff(delay: 0)
        folding.scheduleRegions(after: 0)
    }

    /// The URL (and with it the language) changes on Save As.
    @objc private func documentStateChanged() {
        textView.indentAfterColon = language?.indentAfterColon ?? false
        textView.lineComment = language?.lineComment
        // This also fires for the dirty flag; only a change of grammar means starting the colours over.
        let hasTree = document.syntaxTree != nil
        if document.language?.treeSitterLanguage != colouredLanguage {
            colouredLanguage = document.language?.treeSitterLanguage
            treeColours.reset()
        }
        if hasTree != folding.usesTreeRegions {
            folding.usesTreeRegions = hasTree
            folding.treeRegions = hasTree ? { [weak self] in self?.document.syntaxTreeIfLoaded?.current?.foldRegions } : nil
            if !hasTree { folding.scheduleRegions(after: 0) }
        }
        scheduleHighlight()
    }

    /// A tree matching the text is ready: colour from it, and take its blocks for the gutter chevrons.
    @objc private func syntaxTreeUpdated(_ notification: Notification) {
        guard let controller = notification.object as? SyntaxTreeController, controller === document.syntaxTreeIfLoaded else { return }
        guard window != nil else { needsRefreshWhenShown = true; return }
        scheduleHighlight()
        if let regions = controller.snapshot?.foldRegions { folding.adopt(regions) }
    }

    @objc private func diagnosticsChanged() { applyDiagnostics() }

    @objc private func gitBaseChanged() { scheduleGitDiff(delay: 0) }

    func applySettings() {
        let settings = Settings.shared
        let theme = settings.theme
        let font = settings.editorFont

        let paragraph = NSMutableParagraphStyle()
        let charWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        paragraph.tabStops = []
        paragraph.defaultTabInterval = charWidth * CGFloat(document.indentation.width)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: theme.foreground, .paragraphStyle: paragraph,
        ]
        let signature = "\(font.fontName)|\(font.pointSize)|\(document.indentation.width)|\(theme.name)"
        if document.attributeSignature != signature {
            document.attributeSignature = signature
            storage.beginEditing()
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
        treeColours.reset()          // the colours themselves may have changed
        // `textView.font` and `.textColor` would restyle the whole text again; the storage pass above already did.
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = attributes
        textView.backgroundColor = theme.background
        // With glass the panel behind the editor paints the (translucent) background; the editor paints none.
        textView.drawsBackground = !Glass.isActive
        scrollView.drawsBackground = !Glass.isActive
        textView.insertionPointColor = theme.foreground
        textView.selectedTextAttributes = [.backgroundColor: theme.selection]
        scrollView.backgroundColor = theme.background
        scrollView.scrollerKnobStyle = theme.isDark ? .light : .dark

        gutter.theme = theme
        gutter.font = .monospacedDigitSystemFont(ofSize: max(9, font.pointSize - 2), weight: .regular)
        applyWrapping()
        gutter.invalidateLines()
        updateGutterWidth()
        scheduleHighlight()
        applyDiagnostics()
        textView.updateBracketMatch(force: true)        // the tint is a theme colour
        applyStickySettings()
    }

    private func applyWrapping() {
        guard let container = textView.textContainer else { return }
        let huge = CGFloat.greatestFiniteMagnitude
        if Settings.shared.wrapLines {
            let width = max(100, scrollView.contentSize.width)
            textView.isHorizontallyResizable = false
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: width, height: huge)
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            scrollView.hasHorizontalScroller = false
        } else {
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: huge, height: huge)
            textView.isHorizontallyResizable = true
            scrollView.hasHorizontalScroller = true
        }
        scrollView.useFeatherScrollers()          // turning a scroller back on creates a stock one
    }

    private func updateGutterWidth() {
        guard Settings.shared.showLineNumbers else {
            gutter.isHidden = true
            gutterWidth.constant = 0
            return
        }
        gutter.isHidden = false
        let digits = max(3, String(gutter.lineCount).count)
        let width = ceil(CGFloat(digits) * gutter.digitWidth) + 14 + GutterView.chevronStrip
        if gutterWidth.constant != width { gutterWidth.constant = width }
    }

    var cursorPosition: (line: Int, column: Int) {
        let location = textView.selectedRange().location
        let line = gutter.line(containing: location)
        return (line.index + 1, location - line.start + 1)
    }

    func goToLine(_ number: Int) {
        pendingViewState = nil
        let start = gutter.startOfLine(number - 1)
        folding.reveal(NSRange(location: start, length: 0))
        textView.setSelectedRange(NSRange(location: start, length: 0))
        textView.scrollRangeToVisible(NSRange(location: start, length: 0))
        keepCaretBelowStickyHeader()
        window?.makeFirstResponder(textView)
    }

    // MARK: - Remembered place

    /// Scrolling only sticks once the view has a size and its lines a layout, so the scroll half waits for that.
    private var pendingViewState: EditorViewState?

    var viewState: EditorViewState {
        // Never reached the screen since it was restored: what was remembered still stands, bar the selection.
        if var pending = pendingViewState {
            pending.selection = textView.selectedRange()
            pending.folds = folding.folds
            return pending
        }
        let clip = scrollView.contentView.bounds
        var state = EditorViewState(selection: textView.selectedRange(), topCharacter: 0, topOffset: 0, x: clip.minX)
        state.folds = folding.folds
        let origin = textView.textContainerOrigin
        guard clip.minY > origin.y, storage.length > 0, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return state }
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: clip.minY - origin.y), in: container)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        state.topCharacter = layoutManager.characterIndexForGlyph(at: glyph)
        state.topOffset = clip.minY - origin.y - line.minY
        return state
    }

    func restore(_ state: EditorViewState) {
        // Folds first: they decide where a caret may be.
        folding.restore(state.folds)
        // The selection is put back at once, so the status bar and navigation history read the right cursor.
        let location = min(state.selection.location, storage.length)
        folding.reveal(NSRange(location: location, length: 0))
        textView.setSelectedRange(NSRange(location: location, length: min(state.selection.length, storage.length - location)))
        pendingViewState = state
        applyPendingViewState()
    }

    private func applyPendingViewState() {
        guard let state = pendingViewState, window != nil, scrollView.contentSize.height > 0,
              let layoutManager = textView.layoutManager else { return }
        pendingViewState = nil
        var target = NSPoint(x: state.x, y: 0)
        if state.topCharacter > 0 || state.topOffset > 0, storage.length > 0 {
            let character = min(state.topCharacter, storage.length - 1)
            // Layout is lazy, and until the lines above are really laid out their height is an estimate. With word
            // wrap that estimate is off by screens, so lay them out before asking where the line is.
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: character + 1))
            textView.sizeToFit()
            let line = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: character),
                                                      effectiveRange: nil)
            target.y = line.minY + textView.textContainerOrigin.y + min(state.topOffset, line.height)
        }
        let limit = max(0, textView.frame.height - scrollView.contentSize.height)
        target.y = max(0, min(target.y, limit))
        scrollView.contentView.scroll(to: target)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scheduleHighlight()             // the first pass may have coloured the top of the file instead
    }

    override func layout() {
        super.layout()
        applyPendingViewState()
        conflicts.schedule()
    }

    // MARK: - Highlighting

    private func scheduleHighlight() {
        guard !highlightPending else { return }
        highlightPending = true
        DispatchQueue.main.async { [weak self] in
            self?.highlightPending = false
            self?.highlightNow()
        }
    }

    /// Colours what is on screen straight away. Colours already applied elsewhere shift along with the text, so the
    /// rest of the file stays right enough until a full pass runs once typing pauses. Re-colouring a whole 100 KB
    /// file on every keystroke is what this avoids.
    private func highlightNow() {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let ns = storage.mutableString
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let theme = Settings.shared.theme
        // With a grammar, the colours come from the tree; while a fresh one is being made after an edit the old
        // colours stay (they move with the text) and its arrival brings this pass round again. The tree knows
        // where a comment or string begins, so only a little beyond the screen is asked for.
        let syntaxTree = document.syntaxTree
        syntaxTree?.startIfNeeded()
        let padding = syntaxTree == nil ? 4000 : 1500
        // Start well above the screen, so a comment or string opened just off-screen is still seen.
        let start = max(0, chars.location - padding)
        let end = min(ns.length, NSMaxRange(chars) + padding)
        let range = ns.lineRange(for: NSRange(location: start, length: end - start))
        if let syntaxTree {
            guard let snapshot = syntaxTree.current else { return }
            treeColours.apply(snapshot, storage: storage, layoutManager: layoutManager, range: range, theme: theme)
        } else {
            SyntaxHighlighter.highlight(storage: storage, layoutManager: layoutManager, language: language, range: range, theme: theme)
        }

        fullHighlightWork?.cancel()
        guard ns.length <= fullHighlightLimit, range.length < ns.length else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let layoutManager = self.textView.layoutManager, self.window != nil else { return }
            let whole = NSRange(location: 0, length: self.storage.length)
            if let syntaxTree = self.document.syntaxTreeIfLoaded {
                guard let snapshot = syntaxTree.current else { return }
                self.treeColours.apply(snapshot, storage: self.storage, layoutManager: layoutManager, range: whole, theme: Settings.shared.theme)
            } else {
                SyntaxHighlighter.highlight(storage: self.storage, layoutManager: layoutManager, language: self.language,
                                            range: whole, theme: Settings.shared.theme)
            }
        }
        fullHighlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    @objc private func viewportChanged(_ notification: Notification) {
        textView.clearLink()
        gutter.needsDisplay = true
        // Typing can grow the text view's frame; only real scrolling should dismiss the suggestions.
        if notification.name == NSView.boundsDidChangeNotification {
            completionPopup.hide()
            updateStickyScroll()
        }
        if storage.length > fullHighlightLimit { scheduleHighlight() }
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        textView.clearLink()
        textView.updateBracketMatch()
        onTextChange?()
        if textView.lastEditWasTyping {
            textView.lastEditWasTyping = false
            requestCompletion(manual: false)
        } else {
            completionPopup.hide()
        }
    }

    /// Carets and stretched selections are kept out of folded text; a selection made inside it opens the fold.
    /// (The several-ranges form of this delegate method on purpose: implementing the single-range one makes the
    /// text view give up ⌥-drag column selection.)
    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRanges oldSelectedCharRanges: [NSValue],
                  toCharacterRanges newSelectedCharRanges: [NSValue]) -> [NSValue] {
        guard folding.hasFolds, newSelectedCharRanges.count == 1, let new = newSelectedCharRanges.first?.rangeValue,
              let old = oldSelectedCharRanges.first?.rangeValue else { return newSelectedCharRanges }
        return [NSValue(range: folding.adjustedSelection(from: old, to: new))]
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // An arrow key may have taken the caret under the pinned lines; the text view scrolls after this, so look then.
        if !stickyHeader.isHidden, !caretCheckPending {
            caretCheckPending = true
            DispatchQueue.main.async { [weak self] in
                self?.caretCheckPending = false
                self?.keepCaretBelowStickyHeader()
            }
        }
        gutter.caretMoved()
        textView.updateBracketMatch()
        onSelectionChange?()
        guard completionPopup.isVisible else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.completionPopup.isVisible else { return }
            let cursor = self.textView.selectedRange().location
            if self.wordStart(before: cursor) != self.completionAnchor { self.completionPopup.hide() }
        }
    }

    // MARK: - Positions

    func position(of location: Int) -> (line: Int, character: Int) {
        let line = gutter.line(containing: location)
        return (line.index, location - line.start)
    }

    func location(line: Int, character: Int) -> Int {
        let ns = storage.mutableString
        guard line < gutter.lineCount else { return ns.length }
        let start = gutter.startOfLine(line)
        let lineRange = ns.lineRange(for: NSRange(location: start, length: 0))
        return min(start + max(0, character), NSMaxRange(lineRange))
    }

    func select(line: Int, character: Int, endLine: Int, endCharacter: Int) {
        let start = location(line: line, character: character)
        let end = max(start, location(line: endLine, character: endCharacter))
        let range = NSRange(location: start, length: min(end - start, 400))
        pendingViewState = nil          // going somewhere new beats returning to the remembered place
        folding.reveal(range)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        keepCaretBelowStickyHeader()
        window?.makeFirstResponder(textView)
    }

    // MARK: - Batches of edits

    /// Makes a batch of edits (normalised: in order, not overlapping) as one undo step, through the text view
    /// so undo, redo and the language server see it as they see typing. The caret stays with the text it was
    /// in, and the view is not scrolled: after formatting, the screen should show what it showed before.
    @discardableResult
    func apply(_ edits: [RangeEdit], named name: String) -> Bool {
        guard !edits.isEmpty else { return true }
        let selection = textView.selectedRange()
        let startPlace = position(of: selection.location), endPlace = position(of: NSMaxRange(selection))
        guard textView.shouldChangeText(inRanges: edits.map { NSValue(range: $0.range) },
                                        replacementStrings: edits.map(\.text)) else { return false }
        storage.beginEditing()
        // Bottom-up, so each edit's offsets still mean what they meant when it was worked out.
        for edit in edits.reversed() { storage.replaceCharacters(in: edit.range, with: edit.text) }
        storage.endEditing()
        textView.didChangeText()
        document.undoManager.setActionName(name)

        func moved(_ location: Int, _ place: (line: Int, character: Int)) -> Int {
            let mapped = DocumentEdits.map(location, through: edits)
            // Inside a rewritten stretch an offset means nothing any more; the same line and column is the best guess.
            return mapped.rewritten ? self.location(line: place.line, character: place.character) : min(mapped.location, storage.length)
        }
        let start = moved(selection.location, startPlace)
        let end = selection.length == 0 ? start : max(start, moved(NSMaxRange(selection), endPlace))
        textView.setSelectedRange(NSRange(location: start, length: end - start))
        return true
    }

    // MARK: - Diagnostics

    private func applyDiagnostics() {
        guard let layoutManager = textView.layoutManager else { return }
        let ns = storage.mutableString
        let full = NSRange(location: 0, length: ns.length)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
        var errorLines = Set<Int>()
        for item in diagnostics.sorted(by: { $0.severity > $1.severity }) {
            let start = location(line: item.startLine, character: item.startCharacter)
            var end = location(line: item.endLine, character: item.endCharacter)
            if end <= start { end = min(ns.length, start + 1) }
            guard end > start else { continue }
            let color: NSColor
            switch item.severity {
            case 1: color = NSColor(hex: 0xF14C4C); errorLines.insert(item.startLine)
            case 2: color = NSColor(hex: 0xCCA700)
            default: color = NSColor(hex: 0x3794FF)
            }
            layoutManager.addTemporaryAttributes(
                [.underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: color],
                forCharacterRange: NSRange(location: start, length: end - start))
        }
        gutter.errorLines = errorLines
    }

    /// The most severe diagnostic on the cursor's line, for the status bar.
    var diagnosticAtCursor: LSPDiagnostic? {
        let line = position(of: textView.selectedRange().location).line
        return diagnostics.filter { $0.startLine <= line && line <= $0.endLine }.min { $0.severity < $1.severity }
    }

    // MARK: - Completion

    private func isIdentifier(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || unit == 0x5F || unit == 0x24
    }

    private func wordStart(before location: Int) -> Int {
        let ns = storage.mutableString
        var start = min(location, ns.length)
        while start > 0, isIdentifier(ns.character(at: start - 1)) { start -= 1 }
        return start
    }

    var wordAtCursor: String { word(at: textView.selectedRange().location) }

    func word(at location: Int) -> String {
        let ns = storage.mutableString
        let start = wordStart(before: location)
        var end = min(location, ns.length)
        while end < ns.length, isIdentifier(ns.character(at: end)) { end += 1 }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    // Suggestions that need no language server: the language's keywords, and the words already in this file.
    private static let wordPattern = try! NSRegularExpression(pattern: #"[A-Za-z_$][A-Za-z0-9_$]{2,}"#)
    private static let maxScannedLength = 400_000

    /// Below this many characters the words are gathered on the spot; above it the scan runs off the main thread
    /// and the list arrives a moment later. Scanning 400k characters took tens of milliseconds on the first
    /// keystroke in a big file, the one keystroke that stuttered.
    private static let syncScanLimit = 60_000

    private func localCompletions(excludingWordAt anchor: Int, cursor: Int, then deliver: @escaping ([LSPCompletionItem]) -> Void) {
        let ns = storage.mutableString
        let typed = ns.substring(with: NSRange(location: anchor, length: max(0, cursor - anchor)))
        // Reuse the last scan while it is still a fair picture: few edits since, same part of the file, recent.
        if let cached = localWords, document.changeCount - cached.changeCount < 400, abs(cursor - cached.centre) < 120_000,
           Date().timeIntervalSince(cached.date) < 20 {
            if let own = cached.items.firstIndex(where: { $0.label == typed }) {
                var items = cached.items, keys = cached.keys
                items.remove(at: own); keys.remove(at: own)
                readyKeys = keys
                return deliver(items)
            }
            readyKeys = cached.keys
            return deliver(cached.items)
        }
        let keywords = language?.keywordList ?? []
        // For a very large file, the part around the cursor is what matters.
        let window = ns.length <= EditorView.maxScannedLength ? NSRange(location: 0, length: ns.length)
            : NSRange(location: max(0, cursor - EditorView.maxScannedLength / 2),
                      length: min(EditorView.maxScannedLength, ns.length - max(0, cursor - EditorView.maxScannedLength / 2)))
        let changeCount = document.changeCount
        let finish: ([LSPCompletionItem], [[UInt16]]) -> Void = { [weak self] items, keys in
            guard let self else { return }
            self.localWords = LocalWords(items: items, keys: keys, changeCount: changeCount, centre: cursor, date: Date())
            self.readyKeys = keys
            deliver(items)
        }
        if window.length <= EditorView.syncScanLimit {
            // Matched straight on the storage's string, no copy.
            let (items, keys) = EditorView.gatherWords(in: ns as String, window: window, cursor: cursor, keywords: keywords)
            finish(items, keys)
            return
        }
        // A copy of the window, so the scan can run while the main thread keeps up with the typing.
        let text = ns.substring(with: window)
        let requestID = completionRequestID
        DispatchQueue.global(qos: .userInitiated).async {
            let (items, keys) = EditorView.gatherWords(in: text, window: NSRange(location: 0, length: (text as NSString).length),
                                                       cursor: cursor - window.location, keywords: keywords)
            DispatchQueue.main.async { [weak self] in
                guard let self, requestID == self.completionRequestID else { return }
                finish(items, keys)
            }
        }
    }

    /// The language's keywords, then every word of three letters or more in `window`, each once; the word the
    /// cursor is inside is left out so it does not suggest itself. Pure, so it can run on any thread.
    static func gatherWords(in text: String, window: NSRange, cursor: Int, keywords: [String]) -> ([LSPCompletionItem], [[UInt16]]) {
        var seen = Set<String>()
        var items: [LSPCompletionItem] = []
        func add(_ word: String, kind: Int, detail: String, rank: String) {
            guard seen.insert(word).inserted else { return }
            items.append(LSPCompletionItem(label: word, detail: detail, kind: kind, insertText: word, filterText: word,
                                           sortText: rank + word.lowercased(), editStart: nil))
        }
        for keyword in keywords { add(keyword, kind: 14, detail: "keyword", rank: "1") }
        let ns = text as NSString
        wordPattern.enumerateMatches(in: text, options: [], range: window) { match, _, stop in
            guard let range = match?.range else { return }
            if range.location <= cursor && cursor <= range.location + range.length { return }
            add(ns.substring(with: range), kind: 1, detail: "", rank: "0")
            if items.count > 4000 { stop.pointee = true }
        }
        return (items, items.map { Array($0.filterText.lowercased().utf16) })
    }

    private func requestCompletion(manual: Bool) {
        guard manual || Settings.shared.autoSuggest else { completionPopup.hide(); return }
        let ns = storage.mutableString
        let cursor = textView.selectedRange().location
        let anchor = wordStart(before: cursor)
        var isTrigger = false
        if cursor > 0, let scalar = UnicodeScalar(ns.character(at: cursor - 1)) {
            isTrigger = completionTriggers?().contains(Character(scalar)) ?? false
        }
        guard manual || anchor < cursor || isTrigger else { completionPopup.hide(); return }

        // Narrow what is already showing straight away; the fresh server result replaces it when it lands.
        let continuingSameWord = completionPopup.isVisible && anchor == completionAnchor
        let serverReady = isLanguageServerReady?() == true
        // With a server, narrow the current list at once and let the fresh answer replace it. Without one the
        // list is filtered exactly once, below.
        if continuingSameWord { if serverReady { showFiltered() } } else { completionPopup.hide() }
        completionAnchor = anchor
        completionRequestID += 1
        let requestID = completionRequestID

        guard serverReady, let onCompletionRequest else {
            // No server for this file: suggest from the language and the text. One typed letter matches too
            // much to be useful, so wait for two unless the list was asked for.
            guard manual || cursor - anchor >= 2 else { completionPopup.hide(); return }
            if continuingSameWord && !completionItems.isEmpty {
                showFiltered()
            } else {
                localCompletions(excludingWordAt: anchor, cursor: cursor) { [weak self] items in
                    guard let self, requestID == self.completionRequestID else { return }
                    self.completionItems = items
                    self.showFiltered()
                }
            }
            return
        }
        let position = position(of: cursor)
        onCompletionRequest(position.line, position.character) { [weak self] items in
            guard let self, requestID == self.completionRequestID,
                  self.textView.selectedRange().location == cursor,
                  self.window?.firstResponder === self.textView else { return }
            // A server that has nothing to say (inside a comment, say) still leaves the file's own words.
            if items.isEmpty && cursor - anchor >= 2 {
                self.localCompletions(excludingWordAt: anchor, cursor: cursor) { [weak self] words in
                    guard let self, requestID == self.completionRequestID else { return }
                    self.completionItems = words
                    self.showFiltered()
                }
            } else {
                self.completionItems = items
                self.showFiltered()
            }
        }
    }

    private func showFiltered() {
        guard let window else { return }
        let ns = storage.mutableString
        let cursor = textView.selectedRange().location
        guard cursor >= completionAnchor else { completionPopup.hide(); return }
        let prefix = ns.substring(with: NSRange(location: completionAnchor, length: cursor - completionAnchor)).lowercased()

        let needle = Array(prefix.utf16)
        var ranked: [(rank: Int, item: LSPCompletionItem)] = []
        for (index, item) in completionItems.enumerated() {
            let candidate = completionKeys[index]
            if needle.isEmpty || candidate.starts(with: needle) {
                ranked.append((0, item))
            } else if candidate.count > needle.count, EditorView.isSubsequence(needle, of: candidate) {
                ranked.append((1, item))
            }
        }
        ranked.sort { ($0.rank, $0.item.sortText) < ($1.rank, $1.item.sortText) }
        let visible = ranked.prefix(200).map(\.item)
        // Nothing left to offer once the only candidate is exactly what was typed.
        if visible.count == 1, visible[0].insertText.lowercased() == prefix { completionPopup.hide(); return }
        let caret = textView.firstRect(forCharacterRange: NSRange(location: completionAnchor, length: 0), actualRange: nil)
        completionPopup.show(visible, caret: caret, in: window)
    }

    private static func isSubsequence(_ needle: [UInt16], of haystack: [UInt16]) -> Bool {
        var next = 0
        for unit in haystack where unit == needle[next] {
            next += 1
            if next == needle.count { return true }
        }
        return needle.isEmpty
    }

    private func handleCompletionKey(_ event: NSEvent) -> Bool {
        guard completionPopup.isVisible else { return false }
        switch event.keyCode {
        case 125: completionPopup.moveSelection(by: 1)
        case 126: completionPopup.moveSelection(by: -1)
        case 36, 48, 76: completionPopup.acceptSelection()
        case 53: completionPopup.hide()
        default: return false
        }
        return true
    }

    private func accept(_ item: LSPCompletionItem) {
        let cursor = textView.selectedRange().location
        var start = min(completionAnchor, cursor)
        if let edit = item.editStart, edit.line == position(of: cursor).line {
            start = min(start, location(line: edit.line, character: edit.character))
        }
        textView.insertText(item.insertText, replacementRange: NSRange(location: start, length: cursor - start))
    }

    // MARK: - Quick info

    private func showQuickInfo() {
        let cursor = textView.selectedRange().location
        let position = position(of: cursor)
        onHoverRequest?(position.line, position.character) { [weak self] text in
            guard let self, let text, let layoutManager = self.textView.layoutManager,
                  let container = self.textView.textContainer,
                  self.textView.selectedRange().location == cursor else { return }
            let label = NSTextField(wrappingLabelWithString: String(text.prefix(2000)))
            label.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            label.isSelectable = true
            label.preferredMaxLayoutWidth = 480
            let size = label.sizeThatFits(NSSize(width: 480, height: 600))
            let controller = NSViewController()
            controller.view = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 24, height: min(size.height, 360) + 20))
            label.frame = NSRect(x: 12, y: 10, width: size.width, height: min(size.height, 360))
            controller.view.addSubview(label)

            let ns = self.storage.mutableString
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: min(cursor, max(0, ns.length - 1)), length: ns.length == 0 ? 0 : 1),
                actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += self.textView.textContainerOrigin.x
            rect.origin.y += self.textView.textContainerOrigin.y

            self.hoverPopover?.close()
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = controller
            popover.show(relativeTo: rect, of: self.textView, preferredEdge: .maxY)
            self.hoverPopover = popover
        }
    }

    // MARK: - Git change markers

    private func scheduleGitDiff(delay: TimeInterval = 0.4) {
        gitDiffWork?.cancel()
        guard let base = document.gitBaseLines else {
            gutter.changeMarkers = [:]
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.gitDiffGeneration += 1
            let generation = self.gitDiffGeneration
            let current = self.storage.string
            EditorView.diffQueue.async {
                let markers = LineDiff.markers(old: base, new: current.components(separatedBy: "\n"))
                DispatchQueue.main.async {
                    if generation == self.gitDiffGeneration { self.gutter.changeMarkers = markers }
                }
            }
        }
        gitDiffWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
