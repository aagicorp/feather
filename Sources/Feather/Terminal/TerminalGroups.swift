import AppKit

/// The arithmetic of split terminals. A group is a run of adjacent terminals that share a tag (0 means "not in a
/// group"); the pane keeps the members next to each other in its list, and everything here relies on that.
enum TerminalGroups {
    /// How many terminals one group can hold side by side.
    static let maxMembers = 4

    /// The indices of the run of terminals that share `index`'s tag; just `index` for an ungrouped terminal.
    static func members(of index: Int, tags: [Int]) -> Range<Int> {
        guard tags.indices.contains(index) else { return index..<index }
        let tag = tags[index]
        guard tag != 0 else { return index..<(index + 1) }
        var first = index, last = index
        while first > 0, tags[first - 1] == tag { first -= 1 }
        while last + 1 < tags.count, tags[last + 1] == tag { last += 1 }
        return first..<(last + 1)
    }

    /// A tag no terminal has yet.
    static func freshTag(_ tags: [Int]) -> Int { (tags.max() ?? 0) + 1 }

    /// Groups of one are not groups: their tag goes back to 0.
    static func normalised(_ tags: [Int]) -> [Int] {
        var result = tags
        var index = 0
        while index < result.count {
            let run = members(of: index, tags: result)
            if run.count == 1 { result[index] = 0 }
            index = run.upperBound
        }
        return result
    }

    /// What the session file stores for each terminal: its group's number, counted in order of first appearance,
    /// or nil for a terminal on its own. Groups of one are dropped, so the stored form is always meaningful.
    static func groupIndices(forTags tags: [Int]) -> [Int?] {
        let clean = normalised(tags)
        var numbers: [Int: Int] = [:]
        return clean.map { tag in
            guard tag != 0 else { return nil }
            if let number = numbers[tag] { return number }
            numbers[tag] = numbers.count
            return numbers.count - 1
        }
    }

    /// Tags for terminals restored from the stored numbers. Only adjacent terminals with the same number form a
    /// group (the list is stored in order, so anything else is a damaged file), and no group exceeds the cap.
    static func tags(forGroupIndices numbers: [Int?]) -> [Int] {
        var tags = [Int](repeating: 0, count: numbers.count)
        var nextTag = 1
        var index = 0
        while index < numbers.count {
            guard let number = numbers[index] else { index += 1; continue }
            var end = index
            while end + 1 < numbers.count, numbers[end + 1] == number, end + 1 - index < maxMembers { end += 1 }
            if end > index {
                for member in index...end { tags[member] = nextTag }
                nextTag += 1
            }
            index = end + 1
        }
        return tags
    }

    /// Moving a terminal in the list moves its whole group, and nothing is ever dropped into the middle of another
    /// group. `to` is a drop row as the table reports it: an index in the list before the move, from 0 to count.
    /// The result is the new order as old indices, or nil when nothing would change.
    static func reorder(tags: [Int], from: Int, to: Int) -> [Int]? {
        guard tags.indices.contains(from), (0...tags.count).contains(to) else { return nil }
        let block = members(of: from, tags: tags)
        // A drop inside a group lands before it.
        var target = to
        if target < tags.count, tags[target] != 0 {
            let run = members(of: target, tags: tags)
            if target > run.lowerBound { target = run.lowerBound }
        }
        if block.contains(target) || target == block.upperBound { return nil }
        var rest = Array(tags.indices)
        rest.removeSubrange(block)
        let insertion = target > block.upperBound ? target - block.count : target
        rest.insert(contentsOf: block, at: insertion)
        return rest
    }
}

/// The split view that holds a group's terminals side by side: thin dividers in the theme's border colour, and
/// positions that are applied once the view has a width to apply them to.
final class TerminalGroupSplitView: NSSplitView {
    /// No column narrower than this.
    static let minimumColumn: CGFloat = 120
    /// Fractions of the width, one per column, waiting for the first layout that has a width.
    var pendingFractions: [CGFloat]?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isVertical = true
        dividerStyle = .thin
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var dividerThickness: CGFloat { 1 }
    override var dividerColor: NSColor { Settings.shared.theme.border }

    /// Each column's share of the width.
    var fractions: [CGFloat] {
        let width = max(1, bounds.width - dividerThickness * CGFloat(max(0, arrangedSubviews.count - 1)))
        return arrangedSubviews.map { $0.frame.width / width }
    }

    override func layout() {
        super.layout()
        guard let fractions = pendingFractions, bounds.width > 0, fractions.count == arrangedSubviews.count else { return }
        pendingFractions = nil
        let width = bounds.width - dividerThickness * CGFloat(fractions.count - 1)
        var position: CGFloat = 0
        for (index, fraction) in fractions.dropLast().enumerated() {
            position += (fraction * width).rounded()
            setPosition(position, ofDividerAt: index)
            position += dividerThickness
        }
    }
}

extension MainWindowController {
    /// Terminal ▸ Split Terminal (⌃⇧5): a new shell beside the one in front.
    @objc func splitTerminal(_ sender: Any?) {
        showTerminal()
        terminals.splitTerminal()
    }
}
