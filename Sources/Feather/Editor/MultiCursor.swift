import AppKit

/// One caret or selection. `anchor` stays where the selection began while Shift+arrows move `head`.
struct TextCursor: Equatable {
    var anchor: Int
    var head: Int
    /// The x the caret tries to keep while it moves up and down through shorter lines.
    var goalX: CGFloat?

    init(anchor: Int, head: Int, goalX: CGFloat? = nil) {
        self.anchor = anchor
        self.head = head
        self.goalX = goalX
    }

    init(_ range: NSRange) {
        self.init(anchor: range.location, head: NSMaxRange(range))
    }

    var range: NSRange { NSRange(location: min(anchor, head), length: abs(head - anchor)) }
}

/// What one cursor does to the text in one keystroke, and where that cursor is afterwards. `caret` and `selected`
/// describe the cursor after the edit, counted from the start of the replaced range.
struct CursorEdit {
    var range: NSRange
    var text: String
    var caret: Int
    var selected = 0

    var changesText: Bool { range.length > 0 || !text.isEmpty }

    static func replacing(_ range: NSRange, with text: String) -> CursorEdit {
        CursorEdit(range: range, text: text, caret: (text as NSString).length)
    }
}

/// NSTextView can hold several selected ranges, but it only ever edits at the first, shows no caret for the
/// others, and refuses an empty range next to any other. So the text view keeps exactly one selection of its own
/// (the primary cursor: completion, ⌘-hover, the status bar and bracket tint all read it, as before), and this
/// holds the whole set while there is more than one. Every edit is one `shouldChangeText(inRanges:)` batch, so a
/// keystroke is one undo step and the language server sees one ordinary change. Anything that moves the text
/// view's selection from outside (a click, Find, undo, a jump) goes back to a single cursor.
final class MultiCursorState {
    /// Every cursor in document order, the primary included; empty while there is only the text view's own.
    var cursors: [TextCursor] = []
    var primary = 0
    /// Set while this code moves the text view's selection or edits the text, so neither counts as "from outside".
    var isDriving = false
    /// ⌘D that started from a bare caret matches whole words only, as the first press selected one.
    var matchesWholeWords = false
    var caretsShown = true
    var blinkTimer: Timer?
    /// The kind of the last edit made at several cursors. The text view runs successive edits into one undo step
    /// until told otherwise; on its own it is told by its arrow-key and delete methods, which are not used here.
    var lastEdit = EditKind.other

    enum EditKind { case typing, deleting, other }

    deinit { blinkTimer?.invalidate() }
}

extension CodeTextView {
    var isMultiCursor: Bool { multiCursor.cursors.count > 1 }

    /// All cursors, whether or not there is more than one.
    var allCursors: [TextCursor] {
        isMultiCursor ? multiCursor.cursors : [TextCursor(selectedRange())]
    }

    private var primaryIndex: Int { isMultiCursor ? multiCursor.primary : 0 }

    /// Every selected range, for commands that want to know what is selected without caring how.
    var cursorRanges: [NSRange] { allCursors.map(\.range) }

    // MARK: - Keeping the set

    /// Sorts, clamps and merges the cursors, then shows them. One cursor left means ordinary editing again.
    func setCursors(_ list: [TextCursor], primary: Int, scroll: Bool = true, afterEdit: Bool = false) {
        // Moving a cursor ends the run of typing that undo takes back in one step, as it does with one cursor.
        if !afterEdit {
            breakUndoCoalescing()
            multiCursor.lastEdit = .other
        }
        let length = textContents.length
        var tagged = list.enumerated().map { index, cursor -> (cursor: TextCursor, isPrimary: Bool) in
            var cursor = cursor
            cursor.anchor = max(0, min(cursor.anchor, length))
            cursor.head = max(0, min(cursor.head, length))
            return (cursor, index == primary)
        }
        tagged.sort { $0.cursor.range.location != $1.cursor.range.location
            ? $0.cursor.range.location < $1.cursor.range.location : $0.cursor.range.length < $1.cursor.range.length }
        var merged: [(cursor: TextCursor, isPrimary: Bool)] = []
        for entry in tagged {
            guard let last = merged.last else { merged.append(entry); continue }
            let a = last.cursor.range, b = entry.cursor.range
            // Two selections may touch ("aa" twice in "aaaa"); a caret on the edge of anything is part of it.
            let overlaps = NSMaxRange(a) > b.location || (NSMaxRange(a) == b.location && (a.length == 0 || b.length == 0))
            guard overlaps else { merged.append(entry); continue }
            let union = NSUnionRange(a, b)
            let headFirst = entry.cursor.head < entry.cursor.anchor
            let cursor = headFirst ? TextCursor(anchor: NSMaxRange(union), head: union.location)
                                   : TextCursor(anchor: union.location, head: NSMaxRange(union))
            merged[merged.count - 1] = (cursor, last.isPrimary || entry.isPrimary)
        }
        let primaryIndex = merged.firstIndex { $0.isPrimary } ?? max(0, merged.count - 1)
        let state = multiCursor
        state.cursors = merged.count > 1 ? merged.map(\.cursor) : []
        state.primary = primaryIndex
        guard let main = merged.isEmpty ? nil : merged[primaryIndex].cursor else { return }
        state.isDriving = true
        setSelectedRange(main.range)
        state.isDriving = false
        if scroll { scrollRangeToVisible(NSRange(location: main.head, length: 0)) }
        cursorsDidChange()
    }

    private func cursorsDidChange() {
        let state = multiCursor
        state.caretsShown = true
        if isMultiCursor, state.blinkTimer == nil {
            let timer = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.multiCursor.caretsShown.toggle()
                self.setNeedsDisplay(self.visibleRect)
            }
            RunLoop.main.add(timer, forMode: .common)
            state.blinkTimer = timer
        } else if !isMultiCursor {
            state.blinkTimer?.invalidate()
            state.blinkTimer = nil
        }
        setNeedsDisplay(visibleRect)
    }

    /// Forgets every cursor but the text view's own. Safe to call in the middle of an edit: it touches no text
    /// and no selection.
    func dropExtraCursors() {
        guard !multiCursor.cursors.isEmpty else { return }
        multiCursor.cursors = []
        cursorsDidChange()
    }

    /// The text view's selection was moved by something other than this code.
    func selectionChangedFromOutside() {
        guard !multiCursor.isDriving else { return }
        multiCursor.matchesWholeWords = false
        dropExtraCursors()
    }

    /// The text was changed by something other than this code (another pane, a formatter, undo): the remembered
    /// offsets no longer mean anything.
    func textChangedFromOutside() {
        if !multiCursor.isDriving { dropExtraCursors() }
    }

    // MARK: - Commands

    private func isWordCharacter(at index: Int) -> Bool {
        let ns = textContents
        return index >= 0 && index < ns.length && BracketPairs.isWord(ns.character(at: index))
    }

    /// The word the caret is in or touching.
    private func wordRange(touching location: Int) -> NSRange? {
        identifierRange(at: location) ?? identifierRange(at: location - 1)
    }

    /// What ⌘D and ⇧⌘L look for: the primary selection, or (first) the word at the caret. Returns nil after
    /// selecting that word, which is all the first press does.
    private func occurrenceNeedle(selectingWordFirst: Bool) -> String? {
        let cursors = allCursors
        let main = cursors[primaryIndex]
        if main.range.length > 0 { return textContents.substring(with: main.range) }
        guard let word = wordRange(touching: main.head) else { NSSound.beep(); return nil }
        multiCursor.matchesWholeWords = true
        var list = cursors
        list[primaryIndex] = TextCursor(word)
        setCursors(list, primary: primaryIndex)
        return selectingWordFirst ? nil : textContents.substring(with: word)
    }

    private func isAcceptableMatch(_ range: NSRange) -> Bool {
        !multiCursor.matchesWholeWords || (!isWordCharacter(at: range.location - 1) && !isWordCharacter(at: NSMaxRange(range)))
    }

    /// The next place `needle` stands at or after `start` without touching a range already taken. Looks to the
    /// end of the text and then round from the top.
    private func nextMatch(of needle: String, from start: Int, avoiding taken: [NSRange]) -> NSRange? {
        let ns = textContents
        let needleLength = (needle as NSString).length
        for span in [NSRange(location: start, length: ns.length - start), NSRange(location: 0, length: min(ns.length, start + needleLength))] {
            var search = span
            while search.length >= needleLength {
                let found = ns.range(of: needle, options: .literal, range: search)
                if found.location == NSNotFound { break }
                if isAcceptableMatch(found), !taken.contains(where: { NSIntersectionRange($0, found).length > 0 }) { return found }
                search = NSRange(location: found.location + 1, length: NSMaxRange(span) - found.location - 1)
            }
        }
        return nil
    }

    @objc func addSelectionToNextFindMatch(_ sender: Any?) {
        guard let needle = occurrenceNeedle(selectingWordFirst: true), !needle.isEmpty else { return }
        let cursors = allCursors
        let main = cursors[primaryIndex].range
        guard let found = nextMatch(of: needle, from: NSMaxRange(main), avoiding: cursors.map(\.range)) else { NSSound.beep(); return }
        setCursors(cursors + [TextCursor(found)], primary: cursors.count)
    }

    static let occurrenceLimit = 5000

    @objc func selectAllOccurrences(_ sender: Any?) {
        guard let needle = occurrenceNeedle(selectingWordFirst: false), !needle.isEmpty else { return }
        let ns = textContents
        let main = allCursors[primaryIndex].range
        var found: [TextCursor] = []
        var primary = 0
        var search = NSRange(location: 0, length: ns.length)
        while found.count < CodeTextView.occurrenceLimit {
            let match = ns.range(of: needle, options: .literal, range: search)
            if match.location == NSNotFound { break }
            if isAcceptableMatch(match) {
                if match.location == main.location { primary = found.count }
                found.append(TextCursor(match))
                search = NSRange(location: NSMaxRange(match), length: ns.length - NSMaxRange(match))
            } else {
                search = NSRange(location: match.location + 1, length: ns.length - match.location - 1)
            }
        }
        guard !found.isEmpty else { return }
        setCursors(found, primary: primary, scroll: false)
    }

    @objc func addCursorAbove(_ sender: Any?) { addCursor(below: false) }

    @objc func addCursorBelow(_ sender: Any?) { addCursor(below: true) }

    /// A new caret on the next line out from the outermost cursor, in the same column; folded lines are passed over.
    private func addCursor(below: Bool) {
        let ns = textContents
        let cursors = allCursors
        guard let edge = below ? cursors.last : cursors.first else { return }
        let line = ns.lineRange(for: NSRange(location: edge.head, length: 0))
        // The widest column in use: a caret that a short line pulled in must not pull in the ones after it.
        let column = cursors.map { $0.head - ns.lineRange(for: NSRange(location: $0.head, length: 0)).location }.max() ?? 0
        var target: Int
        if below {
            target = NSMaxRange(line)
            while let hidden = folds?.hiddenRange(containing: target) { target = NSMaxRange(hidden) + 1 }
            // The last line has nothing below it; a text that ends in a newline still has its empty last line.
            let endsInNewline = ns.length > 0 && ns.character(at: ns.length - 1) == 0x0A
            guard target < ns.length || (target == ns.length && endsInNewline && line.location < target && NSMaxRange(line) == target) else {
                NSSound.beep(); return
            }
        } else {
            guard line.location > 0 else { NSSound.beep(); return }
            target = ns.lineRange(for: NSRange(location: line.location - 1, length: 0)).location
            if let hidden = folds?.hiddenRange(containing: target) {
                target = ns.lineRange(for: NSRange(location: hidden.location, length: 0)).location
            }
        }
        var contentsEnd = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: min(target, ns.length), length: 0))
        let place = min(target + column, contentsEnd)
        let added = TextCursor(anchor: place, head: place)
        setCursors(below ? cursors + [added] : [added] + cursors, primary: below ? cursors.count : 0)
    }

    /// ⌥-click: a caret where there was none, or away with the one that was there.
    func toggleCursor(at location: Int) {
        var cursors = allCursors
        if cursors.count > 1, let index = cursors.firstIndex(where: { NSLocationInRange(location, $0.range) || $0.head == location }) {
            cursors.remove(at: index)
            setCursors(cursors, primary: min(index, cursors.count - 1), scroll: false)
        } else {
            setCursors(cursors + [TextCursor(anchor: location, head: location)], primary: cursors.count, scroll: false)
        }
    }

    /// Esc: back to the primary cursor alone.
    func collapseToPrimaryCursor() {
        let main = allCursors[primaryIndex]
        setCursors([main], primary: 0)
    }

    // MARK: - Editing at every cursor

    /// Makes one edit per cursor as a single change. Edits that run into each other (two carets deleting the
    /// same pair of brackets) become one.
    func applyCursorEdits(_ edits: [CursorEdit], kind: MultiCursorState.EditKind = .other) {
        if kind == .other || kind != multiCursor.lastEdit { breakUndoCoalescing() }
        multiCursor.lastEdit = kind
        var plans: [CursorEdit] = []
        for edit in edits {
            if let last = plans.last, last.changesText || edit.changesText, edit.range.location < NSMaxRange(last.range) {
                let text = last.text + edit.text
                plans[plans.count - 1] = .replacing(NSUnionRange(last.range, edit.range), with: text)
            } else {
                plans.append(edit)
            }
        }
        let changes = plans.filter(\.changesText)
        let state = multiCursor
        let primary = min(primaryIndex, plans.count - 1)
        state.isDriving = true
        defer { state.isDriving = false }
        if !changes.isEmpty {
            guard shouldChangeText(inRanges: changes.map { NSValue(range: $0.range) }, replacementStrings: changes.map(\.text)),
                  let textStorage else { return }
            textStorage.beginEditing()
            // Bottom-up, so each range still means what it meant when it was worked out.
            for change in changes.reversed() { textStorage.replaceCharacters(in: change.range, with: change.text) }
            textStorage.endEditing()
            didChangeText()
        }
        var shift = 0
        let moved = plans.map { plan -> TextCursor in
            let start = plan.range.location + shift + plan.caret
            shift += (plan.text as NSString).length - plan.range.length
            return TextCursor(anchor: start, head: start + plan.selected)
        }
        setCursors(moved, primary: primary, afterEdit: true)
    }

    func insertAtCursors(_ text: String) {
        let pairing = Settings.shared.autoCloseBrackets && text.utf16.count == 1 && text != "\n"
        applyCursorEdits(allCursors.map { cursor in
            if pairing, let unit = text.utf16.first, let paired = pairedEdit(typing: unit, over: cursor.range) { return paired }
            return .replacing(cursor.range, with: text)
        }, kind: text.count == 1 ? .typing : .other)
    }

    /// Return at one cursor: the same indentation rules as the single-cursor Return, as one replacement.
    private func newlineEdit(at range: NSRange) -> CursorEdit {
        let ns = textContents
        if range.length == 0, range.location > 0, range.location < ns.length,
           let partner = BracketPairs.partner(of: ns.character(at: range.location - 1)), partner.isForward,
           partner.unit == ns.character(at: range.location) {
            let indent = leadingWhitespace(ofLineAt: range.location)
            let inner = "\n" + indent + indentUnit
            return CursorEdit(range: range, text: inner + "\n" + indent, caret: (inner as NSString).length)
        }
        return .replacing(range, with: "\n" + newlineIndent(at: range.location))
    }

    private func tabEdit(at range: NSRange) -> CursorEdit {
        guard indentation.useSpaces else { return .replacing(range, with: "\t") }
        let lineStart = textContents.lineRange(for: NSRange(location: range.location, length: 0)).location
        let width = indentation.width
        return .replacing(range, with: String(repeating: " ", count: width - ((range.location - lineStart) % width)))
    }

    /// Deleting from each caret to wherever `motion` would take it; a selection is simply deleted.
    private func deleteAtCursors(_ motion: CursorMotion) {
        let ns = textContents
        applyCursorEdits(allCursors.map { cursor in
            var range = cursor.range
            if range.length == 0 {
                if motion == .left, Settings.shared.autoCloseBrackets, range.location > 0, range.location < ns.length,
                   BracketPairs.closer(for: ns.character(at: range.location - 1)) == ns.character(at: range.location) {
                    range = NSRange(location: range.location - 1, length: 2)
                } else {
                    let target = destination(of: cursor, motion).head
                    range = NSRange(location: min(target, cursor.head), length: abs(target - cursor.head))
                }
            }
            return .replacing(range, with: "")
        }, kind: motion == .left || motion == .right ? .deleting : .other)
    }

    /// As many lines on the pasteboard as there are cursors: one line each. Otherwise everything at each.
    func pasteAtCursors() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return false }
        let cursors = allCursors
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let perCursor = lines.count == cursors.count
        applyCursorEdits(cursors.enumerated().map { index, cursor in .replacing(cursor.range, with: perCursor ? lines[index] : text) })
        return true
    }

    func copyAtCursors() {
        let ns = textContents
        let pieces = allCursors.filter { $0.range.length > 0 }.map { ns.substring(with: $0.range) }
        guard !pieces.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pieces.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Moving every cursor

    enum CursorMotion {
        case left, right, up, down, wordLeft, wordRight, lineStart, lineEnd, documentStart, documentEnd
    }

    /// Where `motion` takes the head of `cursor`, ignoring whether the anchor follows.
    private func destination(of cursor: TextCursor, _ motion: CursorMotion) -> TextCursor {
        let ns = textContents
        var moved = cursor
        let head = min(cursor.head, ns.length)
        if motion != .up && motion != .down { moved.goalX = nil }
        switch motion {
        case .left: moved.head = head > 0 ? ns.rangeOfComposedCharacterSequence(at: head - 1).location : 0
        case .right: moved.head = head < ns.length ? NSMaxRange(ns.rangeOfComposedCharacterSequence(at: head)) : head
        case .wordLeft:
            var index = head
            while index > 0, !isWordCharacter(at: index - 1) { index -= 1 }
            while index > 0, isWordCharacter(at: index - 1) { index -= 1 }
            moved.head = index
        case .wordRight:
            var index = head
            while index < ns.length, !isWordCharacter(at: index) { index += 1 }
            while index < ns.length, isWordCharacter(at: index) { index += 1 }
            moved.head = index
        case .lineStart:
            // Like most code editors: first to the start of the code, then to the start of the line.
            let line = ns.lineRange(for: NSRange(location: head, length: 0)).location
            let code = line + (leadingWhitespace(ofLineAt: head) as NSString).length
            moved.head = head == code ? line : code
        case .lineEnd:
            var contentsEnd = 0
            ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: head, length: 0))
            moved.head = contentsEnd
        case .documentStart: moved.head = 0
        case .documentEnd: moved.head = ns.length
        case .up, .down:
            let caret = caretRect(at: head)
            let x = cursor.goalX ?? caret.minX
            moved.goalX = x
            let y = motion == .up ? caret.minY - 1 : caret.maxY + 1
            if y < textContainerOrigin.y { moved.head = 0 }
            else if let layoutManager, let textContainer, y > layoutManager.usedRect(for: textContainer).maxY + textContainerOrigin.y {
                moved.head = ns.length
            } else {
                moved.head = characterIndexForInsertion(at: NSPoint(x: x, y: y))
            }
        }
        if let folds { moved.head = folds.steppingOver(from: head, to: moved.head) }
        return moved
    }

    private func moveCursors(_ motion: CursorMotion, extending: Bool) {
        let moved = allCursors.map { cursor -> TextCursor in
            // An arrow without Shift first lets go of the selection, at the end the arrow points to.
            if !extending, cursor.range.length > 0, motion == .left || motion == .right {
                let edge = motion == .left ? cursor.range.location : NSMaxRange(cursor.range)
                return TextCursor(anchor: edge, head: edge)
            }
            var next = destination(of: cursor, motion)
            if !extending { next.anchor = next.head }
            return next
        }
        setCursors(moved, primary: primaryIndex)
    }

    private static let motions: [String: (CursorMotion, Bool)] = {
        let plain: [String: CursorMotion] = [
            "moveLeft": .left, "moveBackward": .left, "moveRight": .right, "moveForward": .right,
            "moveUp": .up, "moveDown": .down,
            "moveWordLeft": .wordLeft, "moveWordBackward": .wordLeft, "moveWordRight": .wordRight, "moveWordForward": .wordRight,
            "moveToLeftEndOfLine": .lineStart, "moveToBeginningOfLine": .lineStart, "moveToBeginningOfParagraph": .lineStart,
            "moveToRightEndOfLine": .lineEnd, "moveToEndOfLine": .lineEnd, "moveToEndOfParagraph": .lineEnd,
            "moveToBeginningOfDocument": .documentStart, "moveToEndOfDocument": .documentEnd,
        ]
        var table: [String: (CursorMotion, Bool)] = [:]
        for (name, motion) in plain {
            table[name + ":"] = (motion, false)
            table[name + "AndModifySelection:"] = (motion, true)
        }
        return table
    }()

    /// A key command while there are several cursors. False means "not one of ours": the text view then does
    /// what it always does, at the primary cursor, and the others go (see `selectionChangedFromOutside`).
    func performAtCursors(_ selector: Selector) -> Bool {
        let name = NSStringFromSelector(selector)
        if let (motion, extending) = CodeTextView.motions[name] {
            moveCursors(motion, extending: extending)
            return true
        }
        lastEditWasTyping = false
        switch name {
        case "cancelOperation:": collapseToPrimaryCursor()
        case "insertNewline:", "insertLineBreak:", "insertNewlineIgnoringFieldEditor:":
            applyCursorEdits(allCursors.map { newlineEdit(at: $0.range) })
        case "insertTab:": applyCursorEdits(allCursors.map { tabEdit(at: $0.range) })
        case "deleteBackward:": deleteAtCursors(.left)
        case "deleteForward:": deleteAtCursors(.right)
        case "deleteWordBackward:": deleteAtCursors(.wordLeft)
        case "deleteWordForward:": deleteAtCursors(.wordRight)
        case "deleteToBeginningOfLine:": deleteAtCursors(.lineStart)
        case "deleteToEndOfLine:", "deleteToEndOfParagraph:": deleteAtCursors(.lineEnd)
        default: return false
        }
        return true
    }

    // MARK: - Drawing

    /// Where a caret at `location` stands, in the view's coordinates.
    func caretRect(at location: Int) -> NSRect {
        guard let layoutManager, let textContainer else { return .zero }
        let ns = textContents
        let origin = textContainerOrigin
        var rect: NSRect
        if location < ns.length {
            let glyph = layoutManager.glyphIndexForCharacter(at: location)
            rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            rect.origin.x += layoutManager.location(forGlyphAt: glyph).x
        } else if ns.length == 0 || ns.character(at: ns.length - 1) == 0x0A {
            rect = layoutManager.extraLineFragmentRect
            rect.origin.x += textContainer.lineFragmentPadding
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: ns.length - 1)
            rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            rect.origin.x = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).maxX
        }
        return NSRect(x: rect.minX + origin.x, y: rect.minY + origin.y, width: 1, height: rect.height)
    }

    /// The cursors (other than the text view's own) that have anything on screen.
    private func visibleExtraCursors(in rect: NSRect) -> [TextCursor] {
        guard isMultiCursor, let layoutManager, let textContainer else { return [] }
        let origin = textContainerOrigin
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: textContainer)
        let visible = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let primary = multiCursor.primary
        return multiCursor.cursors.enumerated().compactMap { index, cursor in
            guard index != primary, cursor.range.location <= NSMaxRange(visible), NSMaxRange(cursor.range) >= visible.location else { return nil }
            return cursor
        }
    }

    func drawExtraSelections(in rect: NSRect) {
        guard let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        let length = textContents.length
        (selectedTextAttributes[.backgroundColor] as? NSColor ?? .selectedTextBackgroundColor).setFill()
        for cursor in visibleExtraCursors(in: rect) where cursor.range.length > 0 && NSMaxRange(cursor.range) <= length {
            let glyphs = layoutManager.glyphRange(forCharacterRange: cursor.range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: textContainer) { box, _ in
                box.offsetBy(dx: origin.x, dy: origin.y).fill()
            }
        }
    }

    func drawExtraCarets(in rect: NSRect) {
        guard multiCursor.caretsShown, window?.firstResponder === self else { return }
        insertionPointColor.setFill()
        for cursor in visibleExtraCursors(in: rect) where cursor.range.length == 0 {
            caretRect(at: cursor.head).fill()
        }
    }
}
