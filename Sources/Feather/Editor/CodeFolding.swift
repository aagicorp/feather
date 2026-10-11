import AppKit

/// The blocks of a file, by line number: a header line and the last line that belongs to it. Worked out from
/// indentation (which is what every language the editor knows has in common), and from a bracket left open at
/// the end of a line where the indentation says nothing. Regions nest properly, never cross.
struct FoldRegions: Equatable {
    private(set) var headers: [Int32] = []
    private(set) var ends: [Int32] = []
    /// Index of the region each one sits in, or -1.
    private(set) var parents: [Int32] = []

    var isEmpty: Bool { headers.isEmpty }
    var count: Int { headers.count }

    func region(at index: Int) -> (header: Int, end: Int) { (Int(headers[index]), Int(ends[index])) }

    /// Index of the last region whose header is on or before `line`.
    private func lastRegion(startingOnOrBefore line: Int) -> Int {
        var low = 0, high = headers.count
        while low < high {
            let mid = (low + high) / 2
            if Int(headers[mid]) <= line { low = mid + 1 } else { high = mid }
        }
        return low - 1
    }

    func isHeader(_ line: Int) -> Bool {
        let index = lastRegion(startingOnOrBefore: line)
        return index >= 0 && Int(headers[index]) == line
    }

    /// The last line of the block `line` opens, if it opens one.
    func end(ofHeader line: Int) -> Int? {
        let index = lastRegion(startingOnOrBefore: line)
        return index >= 0 && Int(headers[index]) == line ? Int(ends[index]) : nil
    }

    /// Header lines of the blocks `line` is inside (a header is not inside its own block), outermost first.
    func enclosing(_ line: Int) -> [Int] {
        var chain: [Int] = []
        var index = lastRegion(startingOnOrBefore: line - 1)
        while index >= 0 {
            if Int(ends[index]) >= line { chain.append(Int(headers[index])) }
            index = Int(parents[index])
        }
        return chain.reversed()
    }

    /// One pass over the text for indentation and brackets, one over the lines for the blocks. Runs off the main
    /// thread on a copy of the text.
    static func compute(_ text: [unichar], tabWidth: Int) -> FoldRegions {
        build(endOf: lineEnds(text, tabWidth: tabWidth))
    }

    /// For each line, the last line of the block it opens by indentation or by a bracket, or -1. A syntax tree's
    /// blocks are laid over this before `build`.
    static func lineEnds(_ text: [unichar], tabWidth: Int) -> [Int32] {
        struct Opener { let unit: unichar; let line: Int32; var endsItsLine: Bool }
        var indents: [Int32] = []               // -1 for a blank line
        var bracketEnd: [Int32] = []
        var stack: [Opener] = []
        var line: Int32 = 0, column = 0, indent: Int32 = -1
        var inIndent = true, lastWasOpener = false
        for unit in text {
            if unit == 0x0A {
                if lastWasOpener, let top = stack.indices.last, stack[top].line == line { stack[top].endsItsLine = true }
                indents.append(indent)
                bracketEnd.append(-1)
                line += 1
                column = 0; indent = -1; inIndent = true; lastWasOpener = false
                continue
            }
            if unit == 0x20 || unit == 0x0D { column += 1; continue }
            if unit == 0x09 { column += tabWidth - column % tabWidth; continue }
            if inIndent { inIndent = false; indent = Int32(column) }
            lastWasOpener = false
            guard let partner = BracketPairs.partner(of: unit) else { continue }
            if partner.isForward {
                stack.append(Opener(unit: unit, line: line, endsItsLine: false))
                lastWasOpener = true
            } else if let match = stack.suffix(32).lastIndex(where: { $0.unit == partner.unit }) {
                // A closer with no opener near the top of the stack is a stray (in a string, say) and is ignored.
                let opener = stack[match]
                stack.removeSubrange(match...)
                if opener.endsItsLine, line - 1 > opener.line { bracketEnd[Int(opener.line)] = line - 1 }
            }
        }
        indents.append(indent)
        bracketEnd.append(-1)

        // A line owns the lines after it that are indented further, up to the last one that is not blank.
        let lineCount = indents.count
        var endOf = [Int32](repeating: -1, count: lineCount)
        var open: [(line: Int32, indent: Int32)] = []
        var previous: Int32 = -1
        for index in 0..<lineCount where indents[index] >= 0 {
            while let top = open.last, top.indent >= indents[index] {
                open.removeLast()
                if previous > top.line { endOf[Int(top.line)] = previous }
            }
            open.append((Int32(index), indents[index]))
            previous = Int32(index)
        }
        for top in open where previous > top.line { endOf[Int(top.line)] = previous }
        for index in 0..<lineCount where endOf[index] < 0 && bracketEnd[index] > index { endOf[index] = bracketEnd[index] }
        return endOf
    }

    /// The nested table from a per-line list of block ends: a block never reaches past the one it sits in.
    static func build(endOf: [Int32]) -> FoldRegions {
        let lineCount = endOf.count
        var regions = FoldRegions()
        var chain: [Int32] = []
        for index in 0..<lineCount where endOf[index] > index {
            while let top = chain.last, regions.ends[Int(top)] < index { chain.removeLast() }
            var end = endOf[index]
            if let top = chain.last { end = min(end, regions.ends[Int(top)]) }
            guard end > index else { continue }
            regions.headers.append(Int32(index))
            regions.ends.append(end)
            regions.parents.append(chain.last ?? -1)
            chain.append(Int32(regions.headers.count - 1))
        }
        return regions
    }
}

/// Folding for one editor view. A fold is a hidden stretch of characters: from the end of the header line's text
/// to the end of the block's last line, so the header, the "…" and nothing else is left of the block. Hidden
/// characters get null glyphs and the lines they make get no height; the text itself is never touched, so
/// saving, undo, search, line numbers and the language server know nothing of folds.
///
/// Folds are kept as character ranges and moved along with every edit (a short integer loop, like the line
/// table). An edit that reaches into a fold opens it. The region table behind the gutter chevrons and sticky
/// scroll is a different thing: it is rebuilt off the main thread once typing pauses, and the act of folding never
/// trusts it, but reads the block afresh from the lines themselves.
final class FoldingController: NSObject, NSLayoutManagerDelegate {
    private weak var textView: CodeTextView?
    private weak var gutter: GutterView?

    /// Hidden ranges in order of where they start. One may lie inside another.
    private(set) var folds: [NSRange] = []
    private var mergedCache: [NSRange]?
    private var pendingInvalidation: NSRange?

    private(set) var regions = FoldRegions()
    private var regionsGeneration = 0
    private var regionsWork: DispatchWorkItem?
    private static let queue = DispatchQueue(label: "feather.folding", qos: .utility)
    /// Beyond this many characters there are no chevrons and no sticky scroll; folding by command still works.
    private static let regionsLimit = 4_000_000

    /// Folds or regions changed: the gutter and the sticky header have something new to show.
    var onChange: (() -> Void)?

    /// With a syntax tree behind the document, its blocks make the region table (see `adopt`) and `scheduleRegions`
    /// has nothing to do. `treeRegions` gives that table only while it matches the text, so a fold made from it
    /// is right; otherwise the lines are read as they always were.
    var usesTreeRegions = false
    var treeRegions: (() -> FoldRegions?)?

    init(textView: CodeTextView, gutter: GutterView) {
        self.textView = textView
        self.gutter = gutter
    }

    // MARK: - What is hidden

    /// The folds with nested ones absorbed: in order, not touching.
    private var merged: [NSRange] {
        if let mergedCache { return mergedCache }
        var result: [NSRange] = []
        for fold in folds {
            if let last = result.last, fold.location < NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, fold)
            } else {
                result.append(fold)
            }
        }
        mergedCache = result
        return result
    }

    var hasFolds: Bool { !folds.isEmpty }

    /// Index in `merged` of the last range starting before `location`, or -1.
    private func mergedIndex(startingBefore location: Int) -> Int {
        let ranges = merged
        var low = 0, high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].location < location { low = mid + 1 } else { high = mid }
        }
        return low - 1
    }

    /// The hidden range a caret at `location` would be lost in. The place just before a fold belongs to the
    /// header line and is fine; the place just after its last character is the hidden end of a hidden line.
    func hiddenRange(containing location: Int) -> NSRange? {
        guard !folds.isEmpty else { return nil }
        let index = mergedIndex(startingBefore: location)
        guard index >= 0, location <= NSMaxRange(merged[index]) else { return nil }
        return merged[index]
    }

    /// The fold that starts on the line occupying `lineRange`, if any: its header.
    func hiddenRange(startingIn lineRange: NSRange) -> NSRange? {
        guard !folds.isEmpty else { return nil }
        let ranges = merged
        let index = mergedIndex(startingBefore: lineRange.location) + 1
        guard index < ranges.count, ranges[index].location < NSMaxRange(lineRange) else { return nil }
        return ranges[index]
    }

    /// Where a caret going from `old` to `new` should really land: never inside a fold.
    func steppingOver(from old: Int, to new: Int) -> Int {
        guard let hidden = hiddenRange(containing: new) else { return new }
        let length = textView?.textContents.length ?? NSMaxRange(hidden)
        // One step right from the fold's doorstep goes across it. Anything else that ends up inside (a click
        // past the end of the header, ⌘→, a word jump, anything going left) stops at the doorstep.
        if old == hidden.location, new > old, new != NSMaxRange(hidden) { return min(NSMaxRange(hidden) + 1, length) }
        return hidden.location
    }

    /// The text view is about to select `new`. A selection being stretched is kept out of folds; a selection that
    /// appears inside one from elsewhere (Find, a jump) opens it instead.
    func adjustedSelection(from old: NSRange, to new: NSRange) -> NSRange {
        guard !folds.isEmpty else { return new }
        if new.length == 0 {
            let place = steppingOver(from: old.location, to: new.location)
            return NSRange(location: place, length: 0)
        }
        let isStretch = new.location == old.location || NSMaxRange(new) == NSMaxRange(old)
        guard isStretch else { reveal(new); return new }
        var start = new.location, end = NSMaxRange(new)
        if let hidden = hiddenRange(containing: start) { start = hidden.location }
        if let hidden = hiddenRange(containing: end), end < NSMaxRange(hidden) { end = NSMaxRange(hidden) }
        return NSRange(location: start, length: max(0, end - start))
    }

    // MARK: - Layout

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        // No folds, no work: this is on the path of every typed character.
        guard !folds.isEmpty, glyphRange.length > 0 else { return 0 }
        let ranges = merged
        let count = glyphRange.length
        let first = characterIndexes[0], last = characterIndexes[count - 1]
        // The last fold starting at or before these characters, or failing that the first one after.
        var index = max(0, mergedIndex(startingBefore: first + 1))
        if NSMaxRange(ranges[index]) <= first { index += 1 }
        guard index < ranges.count, ranges[index].location <= last else { return 0 }
        var changed = [NSLayoutManager.GlyphProperty](UnsafeBufferPointer(start: properties, count: count))
        var touched = false
        for position in 0..<count {
            let character = characterIndexes[position]
            while index < ranges.count, NSMaxRange(ranges[index]) <= character { index += 1 }
            if index == ranges.count { break }
            if character >= ranges[index].location {
                changed[position] = .null
                touched = true
            }
        }
        guard touched else { return 0 }
        layoutManager.setGlyphs(glyphs, properties: &changed, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return count
    }

    /// A line made only of hidden characters (each hidden line is still a paragraph to the typesetter) is given
    /// no height, so the block takes no room at all.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard !folds.isEmpty else { return false }
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let index = mergedIndex(startingBefore: characters.location + 1)
        guard index >= 0 else { return false }
        let hidden = merged[index]
        // The last hidden line ends with a visible newline (the block's own), and is hidden all the same.
        guard characters.location > hidden.location, characters.location <= NSMaxRange(hidden),
              NSMaxRange(characters) <= NSMaxRange(hidden) + 2 else { return false }
        lineFragmentRect.pointee.size.height = 0
        lineFragmentUsedRect.pointee.size.height = 0
        baselineOffset.pointee = 0
        return true
    }

    private func invalidateLayout(for range: NSRange) {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let ns = textView.textContents
        let start = min(range.location, ns.length), end = min(NSMaxRange(range), ns.length)
        let lines = ns.lineRange(for: NSRange(location: start, length: end - start))
        layoutManager.invalidateGlyphs(forCharacterRange: lines, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: lines, actualCharacterRange: nil)
        textView.needsDisplay = true
    }

    private func foldsDidChange(invalidating range: NSRange?) {
        mergedCache = nil
        if let range { invalidateLayout(for: range) }
        onChange?()
    }

    // MARK: - Reading blocks from the lines

    /// Width of the line's leading white space; nil for a blank line.
    private func indent(ofLine line: Int, in ns: NSString, tabWidth: Int) -> Int? {
        guard let gutter, line < gutter.lineCount else { return nil }
        var index = gutter.startOfLine(line), column = 0
        while index < ns.length {
            switch ns.character(at: index) {
            case 0x20: column += 1
            case 0x09: column += tabWidth - column % tabWidth
            case 0x0A, 0x0D: return nil
            default: return column
            }
            index += 1
        }
        return nil
    }

    private func contentsEnd(ofLine line: Int, in ns: NSString) -> Int {
        guard let gutter else { return 0 }
        var end = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: min(gutter.startOfLine(line), ns.length), length: 0))
        return end
    }

    /// The last line of the block `header` opens, by the same rules as `FoldRegions.compute` but reading only
    /// that block. This is what folding acts on, so a fold is right even while the region table is stale.
    func blockEnd(ofHeader header: Int) -> Int? {
        guard let textView, let gutter else { return nil }
        if let table = treeRegions?(), let end = table.end(ofHeader: header) { return end }
        let ns = textView.textContents
        let tabWidth = Settings.shared.tabWidth
        guard let own = indent(ofLine: header, in: ns, tabWidth: tabWidth) else { return nil }
        var last: Int?
        var line = header + 1
        while line < gutter.lineCount {
            if let next = indent(ofLine: line, in: ns, tabWidth: tabWidth) {
                if next <= own { break }
                last = line
            }
            line += 1
        }
        if let last { return last }
        // Not indented: a bracket left open at the end of the line, closed two or more lines further down.
        var index = contentsEnd(ofLine: header, in: ns) - 1
        while index >= 0, ns.character(at: index) == 0x20 || ns.character(at: index) == 0x09 { index -= 1 }
        guard index >= gutter.startOfLine(header), let partner = BracketPairs.partner(of: ns.character(at: index)), partner.isForward,
              let closer = textView.partner(ofBracketAt: index) else { return nil }
        let end = gutter.line(containing: closer).index - 1
        return end > header ? end : nil
    }

    private func hiddenRange(header: Int, end: Int, in ns: NSString) -> NSRange {
        let start = contentsEnd(ofLine: header, in: ns)
        return NSRange(location: start, length: max(0, contentsEnd(ofLine: end, in: ns) - start))
    }

    /// The header of the innermost block that holds `line` and can be folded: the line itself if it opens one.
    private func foldableHeader(around line: Int) -> Int? {
        guard let textView else { return nil }
        if blockEnd(ofHeader: line) != nil { return line }
        let ns = textView.textContents
        let tabWidth = Settings.shared.tabWidth
        var limit = indent(ofLine: line, in: ns, tabWidth: tabWidth) ?? Int.max
        var candidate = line - 1
        // Walking up, only a line indented less than everything passed so far can be a parent.
        while candidate >= 0, candidate > line - 20_000, limit > 0 {
            if let own = indent(ofLine: candidate, in: ns, tabWidth: tabWidth), own < limit {
                if let end = blockEnd(ofHeader: candidate), end >= line { return candidate }
                limit = own
            }
            candidate -= 1
        }
        return nil
    }

    // MARK: - Folding and unfolding

    private func index(ofFoldStartingAt location: Int) -> Int? {
        folds.firstIndex { $0.location == location }
    }

    func isFolded(line: Int) -> Bool {
        guard !folds.isEmpty, let textView else { return false }
        return index(ofFoldStartingAt: contentsEnd(ofLine: line, in: textView.textContents)) != nil
    }

    @discardableResult
    func fold(line: Int) -> Bool {
        guard let textView, let end = blockEnd(ofHeader: line) else { return false }
        let hidden = hiddenRange(header: line, end: end, in: textView.textContents)
        guard hidden.length > 0, index(ofFoldStartingAt: hidden.location) == nil else { return false }
        insert(hidden)
        moveSelectionOut(of: hidden)
        foldsDidChange(invalidating: hidden)
        return true
    }

    private func insert(_ hidden: NSRange) {
        let position = folds.firstIndex { $0.location > hidden.location } ?? folds.count
        folds.insert(hidden, at: position)
        mergedCache = nil
    }

    /// A caret inside what is about to disappear waits at the fold's doorstep instead.
    private func moveSelectionOut(of hidden: NSRange) {
        guard let textView else { return }
        let selection = textView.selectedRange()
        let reachesIn = NSMaxRange(selection) > hidden.location && selection.location <= NSMaxRange(hidden)
        if reachesIn || textView.isMultiCursor { textView.setSelectedRange(NSRange(location: min(selection.location, hidden.location), length: 0)) }
    }

    @discardableResult
    func unfold(line: Int) -> Bool {
        guard let textView, let index = index(ofFoldStartingAt: contentsEnd(ofLine: line, in: textView.textContents)) else { return false }
        let hidden = folds.remove(at: index)
        foldsDidChange(invalidating: hidden)
        return true
    }

    func toggle(line: Int) {
        if !unfold(line: line) { fold(line: line) }
    }

    /// Fold: the block the caret's line opens, or else the innermost block around it.
    func foldAtCaret() {
        guard let textView, let gutter else { return }
        let line = gutter.line(containing: textView.selectedRange().location).index
        guard let header = foldableHeader(around: line), fold(line: header) else { NSSound.beep(); return }
    }

    func unfoldAtCaret() {
        guard let textView, let gutter else { return }
        if !unfold(line: gutter.line(containing: textView.selectedRange().location).index) { NSSound.beep() }
    }

    /// Every block at every depth, so opening a class shows its methods still folded.
    func foldAll() {
        guard let textView else { return }
        let ns = textView.textContents
        let table = treeRegions?() ?? FoldRegions.compute(FoldingController.units(of: ns), tabWidth: Settings.shared.tabWidth)
        regions = table
        folds = (0..<table.count).compactMap { index in
            let region = table.region(at: index)
            let hidden = hiddenRange(header: region.header, end: region.end, in: ns)
            return hidden.length > 0 ? hidden : nil
        }
        mergedCache = nil
        if let first = merged.first { moveSelectionOut(of: hiddenRange(containing: textView.selectedRange().location) ?? first) }
        foldsDidChange(invalidating: NSRange(location: 0, length: ns.length))
    }

    func unfoldAll() {
        guard let first = folds.first, let textView else { return }
        folds = []
        foldsDidChange(invalidating: NSRange(location: first.location, length: textView.textContents.length - first.location))
    }

    /// Opens every fold that hides any of `range`, so what is about to be selected can be seen.
    func reveal(_ range: NSRange) {
        guard !folds.isEmpty else { return }
        let low = range.location, high = range.length == 0 ? range.location : NSMaxRange(range) - 1
        var opened: NSRange?
        folds.removeAll { fold in
            guard low <= NSMaxRange(fold), high > fold.location else { return false }
            opened = opened.map { NSUnionRange($0, fold) } ?? fold
            return true
        }
        if let opened { foldsDidChange(invalidating: opened) }
    }

    // MARK: - Edits

    /// Called from the storage's did-process-editing notification. Folds after the edit move with the text; a
    /// fold the edit reaches into is opened, and so is one whose header line is split by a Return at its end.
    func noteEdit(_ edited: NSRange, delta: Int) {
        guard !folds.isEmpty, let textView else { return }
        let ns = textView.textContents
        let oldEnd = NSMaxRange(edited) - delta
        var insertsNewline: Bool?
        var opened: NSRange?
        var kept: [NSRange] = []
        kept.reserveCapacity(folds.count)
        for fold in folds {
            if edited.location > NSMaxRange(fold) { kept.append(fold); continue }
            if oldEnd <= fold.location {
                let atDoorstep = oldEnd == fold.location && edited.length > 0
                if atDoorstep, insertsNewline == nil {
                    insertsNewline = NSMaxRange(edited) <= ns.length && ns.range(of: "\n", options: .literal, range: edited).location != NSNotFound
                }
                if !(atDoorstep && insertsNewline == true) {
                    kept.append(NSRange(location: fold.location + delta, length: fold.length))
                    continue
                }
            }
            // Opened. Its glyphs are made visible again once this edit is over.
            let start = min(fold.location, edited.location)
            let end = max(NSMaxRange(fold) + delta, NSMaxRange(edited))
            let range = NSRange(location: start, length: max(0, end - start))
            opened = opened.map { NSUnionRange($0, range) } ?? range
        }
        folds = kept
        mergedCache = nil
        guard let opened else { return }
        let alreadyWaiting = pendingInvalidation != nil
        pendingInvalidation = pendingInvalidation.map { NSUnionRange($0, opened) } ?? opened
        if alreadyWaiting { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let range = self.pendingInvalidation else { return }
            self.pendingInvalidation = nil
            self.foldsDidChange(invalidating: range)
        }
    }

    // MARK: - Remembering folds

    /// Puts back folds remembered from an earlier editor of the same tab. The text may have changed since, so a
    /// fold comes back only if its header still opens exactly the block that was hidden.
    func restore(_ remembered: [NSRange]) {
        guard let textView, let gutter, !remembered.isEmpty else { return }
        let ns = textView.textContents
        var restored: [NSRange] = []
        for hidden in remembered where NSMaxRange(hidden) <= ns.length && hidden.length > 0 {
            let header = gutter.line(containing: hidden.location).index
            guard let end = blockEnd(ofHeader: header), hiddenRange(header: header, end: end, in: ns) == hidden else { continue }
            restored.append(hidden)
        }
        guard !restored.isEmpty else { return }
        folds = restored.sorted { $0.location < $1.location }
        foldsDidChange(invalidating: NSRange(location: 0, length: ns.length))
    }

    // MARK: - The region table

    private static func units(of ns: NSString) -> [unichar] {
        let length = ns.length
        return [unichar](unsafeUninitializedCapacity: length) { buffer, count in
            if let base = buffer.baseAddress { ns.getCharacters(base, range: NSRange(location: 0, length: length)) }
            count = length
        }
    }

    /// The syntax tree's table, freshly built off the main thread.
    func adopt(_ table: FoldRegions) {
        guard table != regions else { return }
        regions = table
        onChange?()
    }

    /// Rebuilds the table once edits have stopped for a moment. The main thread only copies the characters out.
    func scheduleRegions(after delay: TimeInterval = 0.4) {
        regionsWork?.cancel()
        guard !usesTreeRegions else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let textView = self.textView else { return }
            let ns = textView.textContents
            guard ns.length <= FoldingController.regionsLimit else { return }
            self.regionsGeneration += 1
            let generation = self.regionsGeneration
            let text = FoldingController.units(of: ns)
            let tabWidth = Settings.shared.tabWidth
            FoldingController.queue.async {
                let table = FoldRegions.compute(text, tabWidth: tabWidth)
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.regionsGeneration else { return }
                    self.regions = table
                    self.onChange?()
                }
            }
        }
        regionsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - The "…" after a folded header

    private static let markerWidth: CGFloat = 22

    /// Where the header's text ends, in container coordinates. The hidden newline's own (null) glyph cannot be
    /// asked: it reports the place of the glyph before it.
    func doorstepX(of hidden: NSRange, layoutManager: NSLayoutManager, container: NSTextContainer) -> CGFloat {
        guard hidden.location > 0, let ns = textView?.textContents, ns.character(at: hidden.location - 1) != 0x0A else {
            return container.lineFragmentPadding
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: hidden.location - 1)
        return layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).maxX
    }

    private func markerRect(for hidden: NSRange, layoutManager: NSLayoutManager, container: NSTextContainer, origin: NSPoint) -> NSRect {
        let glyph = layoutManager.glyphIndexForCharacter(at: hidden.location)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let x = doorstepX(of: hidden, layoutManager: layoutManager, container: container)
        return NSRect(x: x + origin.x + 6, y: line.minY + origin.y + 2, width: FoldingController.markerWidth, height: max(4, line.height - 4))
    }

    /// The folds with a header in `rect`.
    private func markers(in rect: NSRect) -> [NSRect] {
        guard !folds.isEmpty, let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return [] }
        let origin = textView.textContainerOrigin
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let visible = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let ranges = merged
        var index = mergedIndex(startingBefore: visible.location) + 1
        var result: [NSRect] = []
        while index < ranges.count, ranges[index].location <= NSMaxRange(visible) {
            result.append(markerRect(for: ranges[index], layoutManager: layoutManager, container: container, origin: origin))
            index += 1
        }
        return result
    }

    func drawMarkers(in rect: NSRect) {
        guard !folds.isEmpty else { return }
        let theme = Settings.shared.theme
        for marker in markers(in: rect) {
            let box = NSBezierPath(roundedRect: marker, xRadius: 3, yRadius: 3)
            theme.foreground.withAlphaComponent(0.10).setFill()
            box.fill()
            theme.lineNumber.setFill()
            // Three dots, drawn rather than typed, so they sit in the middle whatever the font.
            for dot in 0..<3 {
                NSBezierPath(ovalIn: NSRect(x: marker.midX - 6.5 + CGFloat(dot) * 5.5, y: marker.midY - 1, width: 2, height: 2)).fill()
            }
        }
    }

    /// A click on the "…" opens the fold.
    func unfoldMarker(at point: NSPoint) -> Bool {
        guard !folds.isEmpty, let textView, let gutter else { return false }
        let strip = NSRect(x: 0, y: point.y - 1, width: textView.bounds.width, height: 2)
        guard markers(in: strip).contains(where: { $0.contains(point) }) else { return false }
        let index = textView.characterIndexForInsertion(at: point)
        let place = hiddenRange(containing: index)?.location ?? index
        return unfold(line: gutter.line(containing: place).index)
    }
}

// MARK: - Menu commands

extension CodeTextView {
    @objc func foldBlock(_ sender: Any?) { folds?.foldAtCaret() }

    @objc func unfoldBlock(_ sender: Any?) { folds?.unfoldAtCaret() }

    @objc func foldAllBlocks(_ sender: Any?) { folds?.foldAll() }

    @objc func unfoldAllBlocks(_ sender: Any?) { folds?.unfoldAll() }
}
