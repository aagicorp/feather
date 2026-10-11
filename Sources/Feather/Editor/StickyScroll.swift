import AppKit

/// The strip at the top of an editor that keeps the opening lines of the blocks you are inside in view
/// (`class Foo {`, `void bar() {`, `if (…) {`) once they have scrolled away. It draws a few ready-made strings;
/// everything that decides what they are lives in `EditorView.updateStickyScroll`.
final class StickyHeaderView: NSView {
    struct Line: Equatable {
        let number: Int                     // zero-based
        let text: NSAttributedString
    }

    var lines: [Line] = [] { didSet { if lines != oldValue { needsDisplay = true } } }
    var theme = Settings.shared.theme { didSet { needsDisplay = true } }
    var numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular) { didSet { needsDisplay = true } }
    var lineHeight: CGFloat = 16
    /// Where the editor's text starts, and how far it is scrolled sideways.
    var gutterWidth: CGFloat = 0 { didSet { if gutterWidth != oldValue { needsDisplay = true } } }
    var textInset: CGFloat = 9
    var scrollX: CGFloat = 0 { didSet { if scrollX != oldValue { needsDisplay = true } } }
    var onClick: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        theme.background.setFill()
        bounds.fill()
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: theme.lineNumber]
        for (row, line) in lines.enumerated() {
            let y = CGFloat(row) * lineHeight
            if gutterWidth > 0 {
                let label = String(line.number + 1) as NSString
                let size = label.size(withAttributes: numberAttributes)
                label.draw(at: NSPoint(x: gutterWidth - size.width - GutterView.chevronStrip, y: y + (lineHeight - size.height) / 2),
                           withAttributes: numberAttributes)
            }
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: gutterWidth, y: y, width: bounds.width - gutterWidth, height: lineHeight).clip()
            line.text.draw(at: NSPoint(x: gutterWidth + textInset - scrollX, y: y))
            NSGraphicsContext.restoreGraphicsState()
        }
        theme.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let row = Int(convert(event.locationInWindow, from: nil).y / max(1, lineHeight))
        if lines.indices.contains(row) { onClick?(lines[row].number) }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

extension EditorView {
    static let stickyLineLimit = 3

    /// The line laid out at height `y` of the text; a folded line counts as its header.
    private func line(atTextY y: CGFloat, layoutManager: NSLayoutManager, container: NSTextContainer) -> Int {
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: y), in: container)
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        return gutter.line(containing: folding.hiddenRange(containing: character)?.location ?? character).index
    }

    /// Called on every scroll event, so it does next to nothing until the line at the top of the view changes:
    /// one glyph lookup and a binary search. Typing never comes here.
    func updateStickyScroll(force: Bool = false) {
        guard Settings.shared.stickyScroll, !folding.regions.isEmpty, window != nil,
              let layoutManager = textView.layoutManager, let container = textView.textContainer else { return showSticky([]) }
        let clip = scrollView.contentView.bounds
        let top = clip.minY - textView.textContainerOrigin.y
        guard top > 0 else { stickyTopLine = -1; return showSticky([]) }
        stickyHeader.scrollX = clip.minX
        let topLine = line(atTextY: top, layoutManager: layoutManager, container: container)
        if !force, topLine == stickyTopLine { return }
        stickyTopLine = topLine

        // The pinned lines cover the top of the text, so the blocks that count are those of the first line left
        // uncovered, which depends on how many are pinned. Take the most lines for which that works out: k lines
        // pinned, and the line below them inside at least k blocks.
        let lineHeight = stickyHeader.lineHeight
        var pinned: [Int] = []
        for count in stride(from: EditorView.stickyLineLimit, to: 0, by: -1) {
            let line = line(atTextY: top + CGFloat(count) * lineHeight, layoutManager: layoutManager, container: container)
            let chain = folding.regions.enclosing(line)
            if chain.count >= count { pinned = Array(chain.prefix(count)); break }
        }
        showSticky(pinned)
    }

    private func showSticky(_ pinned: [Int]) {
        if pinned.isEmpty {
            if !stickyHeader.isHidden { stickyHeader.isHidden = true; stickyHeader.lines = [] }
            return
        }
        let ns = textView.textContents
        let attributes = textView.typingAttributes
        stickyHeader.lines = pinned.map { number in
            // The strings are only made again for lines that were not already pinned.
            let start = gutter.startOfLine(number)
            var contentsEnd = start
            ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: min(start, ns.length), length: 0))
            let text = ns.substring(with: NSRange(location: start, length: min(contentsEnd - start, 400)))
            if let shown = stickyHeader.lines.first(where: { $0.number == number && $0.text.string == text }) { return shown }
            return StickyHeaderView.Line(number: number, text: EditorView.colored(text, attributes: attributes, language: language))
        }
        stickyHeader.gutterWidth = gutter.isHidden ? 0 : gutter.frame.width
        stickyHeight.constant = CGFloat(pinned.count) * stickyHeader.lineHeight + 1
        stickyHeader.isHidden = false
    }

    /// One line coloured the way the editor colours it. The editor's own colours are temporary attributes on a
    /// layout manager, and in a big file only exist near what is on screen, so they cannot simply be copied.
    private static func colored(_ text: String, attributes: [NSAttributedString.Key: Any], language: Language?) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        guard let language, let regex = language.regex else { return result }
        let rules = language.rules
        let theme = Settings.shared.theme
        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: result.length)) { match, _, _ in
            guard let match else { return }
            for index in 0..<rules.count where match.range(at: index + 1).location != NSNotFound {
                result.addAttribute(.foregroundColor, value: theme.color(for: rules[index].0), range: match.range(at: index + 1))
                break
            }
        }
        return result
    }

    func applyStickySettings() {
        let font = Settings.shared.editorFont
        stickyHeader.theme = Settings.shared.theme
        stickyHeader.numberFont = .monospacedDigitSystemFont(ofSize: max(9, font.pointSize - 2), weight: .regular)
        stickyHeader.lineHeight = textView.layoutManager?.defaultLineHeight(for: font) ?? 16
        stickyHeader.textInset = textView.textContainerInset.width + (textView.textContainer?.lineFragmentPadding ?? 5)
        stickyHeader.lines = []
        updateStickyScroll(force: true)
    }

    /// After a jump or an arrow key: a caret that ended up underneath the pinned lines is scrolled clear of them.
    func keepCaretBelowStickyHeader() {
        updateStickyScroll()
        guard !stickyHeader.isHidden else { return }
        let caret = textView.caretRect(at: textView.selectedRange().location)
        let clip = scrollView.contentView.bounds
        let overlap = clip.minY + stickyHeight.constant - caret.minY
        guard overlap > 0, caret.maxY > clip.minY else { return }
        scrollView.contentView.scroll(to: NSPoint(x: clip.minX, y: max(0, clip.minY - overlap)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
