import AppKit

/// The characters that come in pairs. Everything here works on UTF-16 units, straight off the text storage.
enum BracketPairs {
    static let quotes: Set<unichar> = [0x22, 0x27, 0x60]                       // " ' `
    private static let closers: [unichar: unichar] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D]      // ( [ {
    private static let openers: [unichar: unichar] = [0x29: 0x28, 0x5D: 0x5B, 0x7D: 0x7B]

    /// What typing `opener` also types: the closing bracket, or the same quote again.
    static func closer(for opener: unichar) -> unichar? {
        quotes.contains(opener) ? opener : closers[opener]
    }

    static func isClosingBracket(_ unit: unichar) -> Bool { openers[unit] != nil }

    /// The other half of a bracket (quotes have no direction, so they have no partner to look for), and which
    /// way to look for it.
    static func partner(of bracket: unichar) -> (unit: unichar, isForward: Bool)? {
        if let closer = closers[bracket] { return (closer, true) }
        if let opener = openers[bracket] { return (opener, false) }
        return nil
    }

    static func isWord(_ unit: unichar?) -> Bool {
        guard let unit, let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || unit == 0x5F || unit == 0x24
    }

    /// A closer is only typed for you where it cannot get in the way: at the end of a line, before white space,
    /// or before something that closes or separates.
    static func allowsClosing(before next: unichar?) -> Bool {
        guard let next else { return true }
        switch next {
        case 0x20, 0x09, 0x0A, 0x0D, 0x29, 0x5D, 0x7D, 0x2C, 0x3B, 0x3A, 0x2E, 0x3E: return true      // space ) ] } , ; : . >
        default: return false
        }
    }
}

/// AppKit lets a menu item swallow its key equivalent even while the item is disabled. For ⌘/ that costs nothing,
/// but ⌥↑, ⌥↓ and ⌘↩ mean something everywhere else: they move by paragraph in a text field, reach the shell in the
/// terminal, and ⌘↩ commits in Source Control. So those menu items carry their keys only while a code editor has
/// the keyboard, and the keys travel on untouched the rest of the time.
enum EditorOnlyKeys {
    private static var items: [(item: NSMenuItem, key: String)] = []
    /// Whether a code editor has the keyboard at the moment, as last told by `setActive`.
    private(set) static var isActive = false

    /// May be called more than once; each call adds to the list.
    static func claim(_ menuItems: [NSMenuItem]) {
        items += menuItems.map { ($0, $0.keyEquivalent) }
        setActive(false)
    }

    /// Before the menu bar is built again: the old items are gone, so nothing must keep switching their keys.
    static func forgetAll() {
        items = []
    }

    static func setActive(_ active: Bool) {
        isActive = active
        for entry in items where entry.item.keyEquivalent != (active ? entry.key : "") {
            entry.item.keyEquivalent = active ? entry.key : ""
        }
    }
}

// MARK: - Auto-closing pairs

extension CodeTextView {
    private func character(at index: Int) -> unichar? {
        let ns = textContents
        return index >= 0 && index < ns.length ? ns.character(at: index) : nil
    }

    /// Handles one typed character that may be half of a pair. Returns false when it should simply be typed.
    /// Every change goes through `insertText`, so undo and the language server see ordinary typing.
    func typePaired(_ typed: unichar, replacementRange: NSRange) -> Bool {
        guard selectedRanges.count == 1 else { return false }
        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        guard let edit = pairedEdit(typing: typed, over: range) else { return false }
        // Only a freshly typed pair counts as typing (and may bring up suggestions).
        if edit.text.isEmpty || range.length > 0 { lastEditWasTyping = false }
        if !edit.text.isEmpty { insertPlain(edit.text, replacementRange: range) }
        setSelectedRange(NSRange(location: range.location + edit.caret, length: edit.selected))
        return true
    }

    /// What typing `typed` over `range` does when it is half of a pair: step over a closer that is already
    /// there, wrap the selection, or type both halves. Nil when the character should simply be typed. Worked out
    /// without touching anything, so it serves one cursor or many.
    func pairedEdit(typing typed: unichar, over range: NSRange) -> CursorEdit? {
        guard NSMaxRange(range) <= textContents.length else { return nil }
        let previous = character(at: range.location - 1), next = character(at: NSMaxRange(range))
        let isQuote = BracketPairs.quotes.contains(typed)
        // After a backslash the character is an escape, never half of a pair.
        if previous == 0x5C { return nil }

        // The closer is already there: step over it rather than typing a second one.
        if range.length == 0, next == typed, isQuote || BracketPairs.isClosingBracket(typed) {
            return CursorEdit(range: range, text: "", caret: 1)
        }
        guard let closer = BracketPairs.closer(for: typed) else { return nil }
        let open = String(utf16CodeUnits: [typed], count: 1), close = String(utf16CodeUnits: [closer], count: 1)

        if range.length > 0 {
            // Wrap what is selected, and keep it selected so a second bracket can wrap it again.
            let selected = textContents.substring(with: range)
            return CursorEdit(range: range, text: open + selected + close, caret: 1, selected: range.length)
        }
        // An apostrophe in "don't", or a quote typed to close a string somebody else opened.
        if isQuote, BracketPairs.isWord(previous) || BracketPairs.isWord(next) || previous == typed { return nil }
        guard BracketPairs.allowsClosing(before: next) else { return nil }
        return CursorEdit(range: range, text: open + close, caret: 1)
    }

    /// Backspace between `(` and `)` takes both, so an unwanted pair costs one key to remove, as it did to type.
    func deleteEmptyPair() -> Bool {
        let selection = selectedRange()
        guard selectedRanges.count == 1, selection.length == 0, !hasMarkedText(),
              let previous = character(at: selection.location - 1), let next = character(at: selection.location),
              BracketPairs.closer(for: previous) == next else { return false }
        let pair = NSRange(location: selection.location - 1, length: 2)
        guard shouldChangeText(in: pair, replacementString: "") else { return false }
        textStorage?.replaceCharacters(in: pair, with: "")
        didChangeText()
        return true
    }

    /// Return between `{` and `}`: the closer moves to a line of its own and the caret waits, indented, between.
    func openPairOntoNewLines() -> Bool {
        let selection = selectedRange()
        guard selectedRanges.count == 1, selection.length == 0, !hasMarkedText(),
              let previous = character(at: selection.location - 1), let next = character(at: selection.location),
              let partner = BracketPairs.partner(of: previous), partner.isForward, partner.unit == next else { return false }
        let indent = leadingWhitespace(ofLineAt: selection.location)
        let inner = "\n" + indent + indentUnit
        lastEditWasTyping = false
        insertPlain(inner + "\n" + indent, replacementRange: selection)
        setSelectedRange(NSRange(location: selection.location + (inner as NSString).length, length: 0))
        return true
    }

    func leadingWhitespace(ofLineAt location: Int) -> String {
        let ns = textContents
        let line = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        var end = line.location
        while end < NSMaxRange(line), ns.character(at: end) == 0x20 || ns.character(at: end) == 0x09 { end += 1 }
        return ns.substring(with: NSRange(location: line.location, length: end - line.location))
    }
}

// MARK: - Bracket matching

extension CodeTextView {
    /// How far to look for a partner, each way. A bracket whose partner is further than this goes untinted, which
    /// is what keeps a caret move in a huge file cheap.
    static let bracketScanLimit = 20_000

    /// Index of the bracket that pairs with the one at `index`, counting nested brackets of the same kind.
    /// Brackets inside strings and comments are counted too; telling them apart would need the whole file parsed.
    func partner(ofBracketAt index: Int) -> Int? {
        let ns = textContents
        guard index >= 0, index < ns.length else { return nil }
        let bracket = ns.character(at: index)
        guard let partner = BracketPairs.partner(of: bracket) else { return nil }
        // Read in blocks: one call per 2,048 characters instead of one per character.
        var buffer = [unichar](repeating: 0, count: 2048)
        var depth = 0
        if partner.isForward {
            var position = index + 1
            let end = min(ns.length, position + CodeTextView.bracketScanLimit)
            while position < end {
                let count = min(buffer.count, end - position)
                ns.getCharacters(&buffer, range: NSRange(location: position, length: count))
                for offset in 0..<count {
                    let unit = buffer[offset]
                    if unit == bracket { depth += 1 } else if unit == partner.unit {
                        if depth == 0 { return position + offset }
                        depth -= 1
                    }
                }
                position += count
            }
        } else {
            var position = index
            let start = max(0, position - CodeTextView.bracketScanLimit)
            while position > start {
                let count = min(buffer.count, position - start)
                ns.getCharacters(&buffer, range: NSRange(location: position - count, length: count))
                for offset in stride(from: count - 1, through: 0, by: -1) {
                    let unit = buffer[offset]
                    if unit == bracket { depth += 1 } else if unit == partner.unit {
                        if depth == 0 { return position - count + offset }
                        depth -= 1
                    }
                }
                position -= count
            }
        }
        return nil
    }

    /// The bracket touching the caret (the one before it first) and its partner.
    private func bracketPair(around caret: Int) -> (bracket: Int, partner: Int)? {
        for index in [caret - 1, caret] {
            guard let unit = character(at: index), BracketPairs.partner(of: unit) != nil else { continue }
            if let partner = partner(ofBracketAt: index) { return (index, partner) }
        }
        return nil
    }

    /// Called on every caret move and edit. With no bracket beside the caret it reads two characters and returns.
    /// Only `.backgroundColor` is used: syntax colours own `.foregroundColor`, diagnostics and links the underline.
    func updateBracketMatch(force: Bool = false) {
        let selection = selectedRange()
        let key = (location: selection.length == 0 ? selection.location : -2, edits: editCount)
        if !force, key == bracketMatchKey { return }
        bracketMatchKey = key
        clearBracketHighlights()
        guard selection.length == 0, Settings.shared.matchBrackets, let layoutManager,
              let pair = bracketPair(around: selection.location) else { return }
        let ranges = [pair.bracket, pair.partner].map { NSRange(location: $0, length: 1) }
        let color = Settings.shared.theme.bracketMatch
        for range in ranges { layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range) }
        bracketHighlights = ranges
    }

    private func clearBracketHighlights() {
        guard !bracketHighlights.isEmpty else { return }
        let length = textContents.length
        for range in bracketHighlights where NSMaxRange(range) <= length {
            layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        bracketHighlights = []
    }

    /// Called while the storage still knows what was edited. The layout manager hears about the edit only after
    /// this, and will then move its tints along with the text; so the remembered places are moved the same way
    /// here, and the tints themselves are taken off at the next `updateBracketMatch`, which every edit leads to.
    func bracketsNoteEdit(_ edited: NSRange, delta: Int) {
        editCount += 1
        textChangedFromOutside()
        guard !bracketHighlights.isEmpty else { return }
        let oldEnd = NSMaxRange(edited) - delta
        bracketHighlights = bracketHighlights.compactMap { range in
            if range.location < edited.location { return range }
            // A bracket inside the replaced text took its tint with it.
            return range.location >= oldEnd ? NSRange(location: range.location + delta, length: range.length) : nil
        }
    }

    @objc func goToMatchingBracket(_ sender: Any?) {
        let caret = selectedRange().location
        var target: Int?
        if let pair = bracketPair(around: caret) {
            // Land outside the pair on either side, so pressing it again comes straight back.
            target = pair.partner > pair.bracket ? pair.partner + 1 : pair.partner
        } else {
            target = enclosingOpener(before: caret)
        }
        guard let target else { NSSound.beep(); return }
        let range = NSRange(location: target, length: 0)
        setSelectedRange(range)
        scrollRangeToVisible(range)
    }

    /// With no bracket beside the caret, the nearest bracket that is still open at the caret.
    private func enclosingOpener(before caret: Int) -> Int? {
        let ns = textContents
        var pending: [unichar: Int] = [:]           // closers seen whose opener is yet to come, by opener
        var index = min(caret, ns.length) - 1
        let stop = max(0, index - CodeTextView.bracketScanLimit)
        while index >= stop {
            let unit = ns.character(at: index)
            if let partner = BracketPairs.partner(of: unit) {
                if partner.isForward {
                    if pending[unit, default: 0] == 0 { return index }
                    pending[unit, default: 0] -= 1
                } else {
                    pending[partner.unit, default: 0] += 1
                }
            }
            index -= 1
        }
        return nil
    }
}

// MARK: - Line commands

extension CodeTextView {
    /// A line's text and what ends it ("\n", "\r\n", or nothing on the last line).
    private func split(_ line: String) -> (content: String, terminator: String) {
        if line.hasSuffix("\r\n") { return (String(line.dropLast()), "\r\n") }      // "\r\n" is one Character
        if line.hasSuffix("\n") { return (String(line.dropLast()), "\n") }
        return (line, "")
    }

    /// The whole lines the selection touches. A selection that ends at the very start of a line does not
    /// touch that line: selecting three lines by dragging down leaves the caret at the start of the fourth.
    var selectedLinesRange: NSRange {
        let ns = textContents
        var selection = selectedRange()
        if selection.length > 0, ns.character(at: NSMaxRange(selection) - 1) == 0x0A { selection.length -= 1 }
        return ns.lineRange(for: selection)
    }

    /// One replacement, one undo step, through the same door as typing.
    private func replace(_ range: NSRange, with text: String, select selection: NSRange, named name: String) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        undoManager?.setActionName(name)
        setSelectedRange(selection)
        scrollRangeToVisible(selection)
    }

    private func shifted(_ range: NSRange, by delta: Int) -> NSRange {
        NSRange(location: range.location + delta, length: range.length)
    }

    @objc func moveLinesUp(_ sender: Any?) {
        let ns = textContents
        let block = selectedLinesRange
        guard block.location > 0 else { NSSound.beep(); return }
        let above = ns.lineRange(for: NSRange(location: block.location - 1, length: 0))
        let (moving, movingEnd) = split(ns.substring(with: block))
        let (passed, passedEnd) = split(ns.substring(with: above))
        let text = moving + passedEnd + passed + movingEnd
        replace(NSUnionRange(above, block), with: text, select: shifted(selectedRange(), by: -above.length), named: "Move Line Up")
    }

    @objc func moveLinesDown(_ sender: Any?) {
        let ns = textContents
        let block = selectedLinesRange
        let (moving, movingEnd) = split(ns.substring(with: block))
        // Without a line ending this is the last line, and there is nowhere further down to go.
        guard !movingEnd.isEmpty else { NSSound.beep(); return }
        let below = ns.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
        let (passed, passedEnd) = split(ns.substring(with: below))
        let text = passed + movingEnd + moving + passedEnd
        let distance = (passed as NSString).length + (movingEnd as NSString).length
        replace(NSUnionRange(block, below), with: text, select: shifted(selectedRange(), by: distance), named: "Move Line Down")
    }

    @objc func copyLinesUp(_ sender: Any?) { copyLines(down: false) }

    @objc func copyLinesDown(_ sender: Any?) { copyLines(down: true) }

    /// Either way the text ends up twice; the difference is which copy keeps the selection.
    private func copyLines(down: Bool) {
        let block = selectedLinesRange
        let (content, ending) = split(textContents.substring(with: block))
        let separator = ending.isEmpty ? "\n" : ending
        let selection = selectedRange()
        if down {
            let contentLength = (content as NSString).length
            replace(NSRange(location: block.location + contentLength, length: 0), with: separator + content,
                    select: shifted(selection, by: contentLength + (separator as NSString).length), named: "Copy Line Down")
        } else {
            replace(NSRange(location: block.location, length: 0), with: content + separator, select: selection, named: "Copy Line Up")
        }
    }

    @objc func deleteLines(_ sender: Any?) {
        let ns = textContents
        guard ns.length > 0 else { return }
        var doomed = selectedLinesRange
        let column = selectedRange().location - ns.lineRange(for: NSRange(location: selectedRange().location, length: 0)).location
        // The last line has no ending of its own; take the one before it, or an empty line would be left behind.
        if split(ns.substring(with: doomed)).terminator.isEmpty, doomed.location > 0 {
            let above = ns.lineRange(for: NSRange(location: doomed.location - 1, length: 0))
            let ending = (split(ns.substring(with: above)).terminator as NSString).length
            doomed = NSRange(location: doomed.location - ending, length: doomed.length + ending)
        }
        guard shouldChangeText(in: doomed, replacementString: "") else { return }
        textStorage?.replaceCharacters(in: doomed, with: "")
        didChangeText()
        undoManager?.setActionName("Delete Line")
        // The caret keeps its column on whichever line took this one's place.
        let line = ns.lineRange(for: NSRange(location: min(doomed.location, ns.length), length: 0))
        let contentLength = (split(ns.substring(with: line)).content as NSString).length
        let caret = NSRange(location: line.location + min(column, contentLength), length: 0)
        setSelectedRange(caret)
        scrollRangeToVisible(caret)
    }

    @objc func indentLines(_ sender: Any?) {
        let unit = indentUnit
        shiftLines(named: "Indent Lines") { $0.isEmpty ? $0 : unit + $0 }
    }

    @objc func outdentLines(_ sender: Any?) {
        let width = indentation.width
        shiftLines(named: "Outdent Lines") { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            return String(line.dropFirst(line.prefix(width).prefix { $0 == " " }.count))
        }
    }

    /// Changes the start of every selected line and keeps the selection on the same text, which Tab does not:
    /// ⌘] on a line you are typing in must leave the caret where it was in the words.
    private func shiftLines(named name: String, _ transform: (String) -> String) {
        let ns = textContents
        let block = selectedLinesRange
        let selection = selectedRange()
        var pieces: [String] = []
        var firstDelta = 0, totalDelta = 0
        var position = block.location
        while position < NSMaxRange(block) {
            let lineRange = ns.lineRange(for: NSRange(location: position, length: 0))
            let (content, ending) = split(ns.substring(with: lineRange))
            let changed = transform(content)
            let delta = (changed as NSString).length - (content as NSString).length
            if position == block.location { firstDelta = delta }
            totalDelta += delta
            pieces.append(changed + ending)
            position = NSMaxRange(lineRange)
        }
        guard totalDelta != 0 else { return }
        let start = max(block.location, selection.location + firstDelta)
        let end = max(start, NSMaxRange(selection) + totalDelta)
        replace(block, with: pieces.joined(), select: NSRange(location: start, length: end - start), named: name)
    }

    @objc func insertLineBelow(_ sender: Any?) {
        let ns = textContents
        let line = ns.lineRange(for: NSRange(location: NSMaxRange(selectedRange()), length: 0))
        let content = split(ns.substring(with: line)).content
        var indent = leadingWhitespace(ofLineAt: line.location)
        // The same rule Return follows: a line that opens a block is followed by a deeper one.
        if let last = content.trimmingCharacters(in: .whitespaces).last,
           "{[(".contains(last) || (indentAfterColon && last == ":") { indent += indentUnit }
        let end = line.location + (content as NSString).length
        let text = "\n" + indent
        replace(NSRange(location: end, length: 0), with: text,
                select: NSRange(location: end + (text as NSString).length, length: 0), named: "Insert Line Below")
    }

    @objc func insertLineAbove(_ sender: Any?) {
        let line = textContents.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let indent = leadingWhitespace(ofLineAt: line.location)
        replace(NSRange(location: line.location, length: 0), with: indent + "\n",
                select: NSRange(location: line.location + (indent as NSString).length, length: 0), named: "Insert Line Above")
    }

    /// The Lines menu normally takes these keys first (see `EditorOnlyKeys`). Should one get past the menu
    /// anyway, it still does here what the menu says it does, instead of moving the caret by paragraph.
    func handleLineKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (event.keyCode, modifiers) {
        case (126, [.option]): moveLinesUp(nil)
        case (125, [.option]): moveLinesDown(nil)
        case (126, [.option, .shift]): copyLinesUp(nil)
        case (125, [.option, .shift]): copyLinesDown(nil)
        case (36, [.command]): insertLineBelow(nil)
        case (36, [.command, .shift]): insertLineAbove(nil)
        case (42, [.command, .shift]): goToMatchingBracket(nil)          // ⇧⌘\
        default: return false
        }
        return true
    }
}
