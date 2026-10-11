import AppKit
import TreeSitter

/// A tree-sitter tree. Copies share their nodes and are cheap, so the parser can work from one on another thread
/// while this one is read; only the controller's private base copy is ever edited.
final class SyntaxTree {
    /// The `TSTree`.
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) { self.pointer = pointer }

    deinit { ts_tree_delete(pointer) }

    func copy() -> SyntaxTree { SyntaxTree(pointer: ts_tree_copy(pointer)) }

    var root: TSNode { ts_tree_root_node(pointer) }

    func edit(_ edit: TSInputEdit) {
        var edit = edit
        ts_tree_edit(pointer, &edit)
    }
}

/// The document's characters, copied out on the main thread so the parser can read them on another. UTF-16, as
/// the text storage keeps them, so tree-sitter's byte offsets are twice the storage's character offsets.
final class TextSnapshot {
    let units: [UInt16]
    var length: Int { units.count }

    init(_ ns: NSString) {
        let length = ns.length
        units = [UInt16](unsafeUninitializedCapacity: length) { buffer, count in
            if let base = buffer.baseAddress { ns.getCharacters(base, range: NSRange(location: 0, length: length)) }
            count = length
        }
    }

    init(units: [UInt16]) { self.units = units }

    func text(in range: NSRange) -> String {
        let start = max(0, min(range.location, units.count)), end = max(start, min(NSMaxRange(range), units.count))
        return String(utf16CodeUnits: Array(units[start..<end]), count: end - start)
    }

    /// Offset at which each line starts; worked out once, on first use.
    private(set) lazy var lineStarts: [Int] = {
        var starts = [0]
        for (index, unit) in units.enumerated() where unit == 0x0A { starts.append(index + 1) }
        return starts
    }()

    /// Zero-based line of a character offset.
    func line(containing offset: Int) -> Int {
        let starts = lineStarts
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Row and column (in bytes) of a character offset, for the ranges handed to an injected language's parser.
    func point(at offset: Int) -> TSPoint {
        let line = line(containing: offset)
        return TSPoint(row: UInt32(line), column: UInt32((offset - lineStarts[line]) * 2))
    }

    /// The parser reads straight from the buffer: the whole rest of the text in one go, nothing copied.
    func parse(with parser: OpaquePointer, from base: SyntaxTree?) -> SyntaxTree? {
        var context = ReadContext(base: nil, byteCount: 0)
        return units.withUnsafeBufferPointer { buffer -> SyntaxTree? in
            context = ReadContext(base: UnsafeRawPointer(buffer.baseAddress), byteCount: buffer.count * 2)
            return withUnsafeMutablePointer(to: &context) { pointer -> SyntaxTree? in
                let input = TSInput(payload: UnsafeMutableRawPointer(pointer), read: readChunk, encoding: TSInputEncodingUTF16LE, decode: nil)
                return ts_parser_parse(parser, base?.pointer, input).map { SyntaxTree(pointer: $0) }
            }
        }
    }
}

private struct ReadContext {
    let base: UnsafeRawPointer?
    let byteCount: Int
}

private let readChunk: @convention(c) (UnsafeMutableRawPointer?, UInt32, TSPoint, UnsafeMutablePointer<UInt32>?) -> UnsafePointer<CChar>? = { payload, byteIndex, _, bytesRead in
    guard let payload, let base = payload.assumingMemoryBound(to: ReadContext.self).pointee.base else { bytesRead?.pointee = 0; return nil }
    let byteCount = payload.assumingMemoryBound(to: ReadContext.self).pointee.byteCount
    guard Int(byteIndex) < byteCount else { bytesRead?.pointee = 0; return nil }
    bytesRead?.pointee = UInt32(byteCount - Int(byteIndex))
    return base.advanced(by: Int(byteIndex)).assumingMemoryBound(to: CChar.self)
}

/// One language's tree over a document: the whole file for the root layer, or the stretches an injection query
/// found written in another language (`<script>` in HTML, a css`…` template in JavaScript).
final class SyntaxLayer {
    let grammar: TreeSitterGrammar
    let tree: SyntaxTree
    /// Empty for the root layer.
    let ranges: [NSRange]

    init(grammar: TreeSitterGrammar, tree: SyntaxTree, ranges: [NSRange]) {
        self.grammar = grammar
        self.tree = tree
        self.ranges = ranges
    }
}

/// Everything known about one version of the text: its trees and, once worked out, its fold table.
final class SyntaxSnapshot {
    /// The document's edit count this was parsed from; the controller only lets it be used while that still holds.
    let version: Int
    let text: TextSnapshot
    let root: SyntaxLayer
    let layers: [SyntaxLayer]
    var foldRegions: FoldRegions?
    /// How many of the controller's outstanding edits this parse took in.
    let editCount: Int

    init(version: Int, text: TextSnapshot, root: SyntaxLayer, layers: [SyntaxLayer], foldRegions: FoldRegions?, editCount: Int) {
        self.version = version
        self.text = text
        self.root = root
        self.layers = layers
        self.foldRegions = foldRegions
        self.editCount = editCount
    }
}

/// Keeps a document's syntax tree up to date: every edit to the text storage is applied to the tree at once and a
/// reparse runs on a background queue from a copy of the text, so typing never waits for the parser. The result
/// is published only if no further edit happened meanwhile; otherwise the edits that did are applied to it and it
/// is parsed again. Editors colour and fold from `current`, which is nil while a fresh tree is on its way.
final class SyntaxTreeController {
    /// Posted on the main thread with the controller as object when a tree matching the text is ready.
    static let didUpdate = Notification.Name("FeatherSyntaxTreeDidUpdate")
    /// Beyond this many characters a file keeps the regex colouring: a tree of it costs more than it gives.
    /// Measured (tools/perf.sh): the tree of a 3.8 MB file holds 260 MB against 45 MB for regex colouring, and
    /// a keystroke costs the same either way; at 1 MB the tree is about 50 MB, which is worth it.
    static let sizeLimit = 1_000_000
    /// A file up to this size is parsed on the spot the first time, so it does not open uncoloured for a moment.
    static let immediateParseLimit = 48_000
    /// Fold tables are rebuilt with every parse up to this size; above it, once typing pauses.
    static let regionsWithParseLimit = 200_000
    /// Injections are looked for up to this size.
    static let injectionsLimit = 600_000

    let grammar: TreeSitterGrammar
    private let storage: NSTextStorage
    /// The parsers, used only on `queue`; a running job keeps them alive after the controller is gone.
    private let parsers: ParserSet
    private static let queue = DispatchQueue(label: "feather.syntax", qos: .userInitiated)

    // Main-thread state.
    /// The storage's characters, kept in step edit by edit: a parse takes a copy-on-write reference to them, which
    /// costs nothing until the next edit, instead of reading the whole text out of the storage every keystroke.
    private var mirror: [UInt16]
    private(set) var version = 0
    /// The newest tree, as parsed; the next parse starts from a copy of it with `edits` applied. The edits are
    /// applied on the queue: editing a tree that shares its nodes with a copy clones the nodes on the way down,
    /// and the root of a big file has thousands of children.
    private var latest: SyntaxTree?
    /// Edits since `latest` was parsed.
    private var edits: [TSInputEdit] = []
    private(set) var isParsing = false
    private var regionsWork: DispatchWorkItem?
    /// The latest result, current or not.
    private(set) var snapshot: SyntaxSnapshot?

    /// For tests: the mirror must always read as the storage does.
    var mirrorMatchesStorage: Bool { mirror == TextSnapshot(storage.mutableString).units }

    /// The trees for the text as it is right now, or nil while they are being rebuilt.
    var current: SyntaxSnapshot? {
        guard let snapshot, snapshot.version == version else { return nil }
        return snapshot
    }

    /// The controller for a document, if its language has a grammar and the file is not too big.
    static func make(for storage: NSTextStorage, language: Language?) -> SyntaxTreeController? {
        guard TreeSitterGrammar.isEnabled, let id = language?.treeSitterLanguage, storage.length <= sizeLimit,
              let grammar = TreeSitterGrammar.grammar(for: id) else { return nil }
        return SyntaxTreeController(storage: storage, grammar: grammar)
    }

    private init(storage: NSTextStorage, grammar: TreeSitterGrammar) {
        self.storage = storage
        self.grammar = grammar
        parsers = ParserSet(grammar: grammar)
        mirror = TextSnapshot(storage.mutableString).units
        NotificationCenter.default.addObserver(self, selector: #selector(storageDidChange(_:)),
                                               name: NSTextStorage.didProcessEditingNotification, object: storage)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Edits

    @objc private func storageDidChange(_ notification: Notification) {
        guard storage.editedMask.contains(.editedCharacters) else { return }
        let edited = storage.editedRange, delta = storage.changeInLength
        // Points are not tracked (a line table for them would cost more per keystroke than the tree does); the
        // parser goes by byte offsets, which are exact, and lines are worked out from the text where needed.
        let zero = TSPoint(row: 0, column: 0)
        let edit = TSInputEdit(start_byte: UInt32(edited.location * 2), old_end_byte: UInt32((NSMaxRange(edited) - delta) * 2),
                               new_end_byte: UInt32(NSMaxRange(edited) * 2), start_point: zero, old_end_point: zero, new_end_point: zero)
        version += 1
        let ns = storage.mutableString
        let typed = [UInt16](unsafeUninitializedCapacity: edited.length) { buffer, count in
            if let address = buffer.baseAddress, edited.length > 0 { ns.getCharacters(address, range: edited) }
            count = edited.length
        }
        mirror.replaceSubrange(edited.location..<(NSMaxRange(edited) - delta), with: typed)
        edits.append(edit)
        scheduleParse()
    }

    // MARK: - Parsing

    private func scheduleParse() {
        guard !isParsing else { return }
        isParsing = true
        let job = makeJob()
        SyntaxTreeController.queue.async {
            let result = job.run()
            DispatchQueue.main.async { [weak self] in self?.finished(result, version: job.version) }
        }
    }

    /// The first parse, when an editor first wants colours: a small file is parsed right here, so its first screen
    /// is already coloured; a big one on the queue.
    func startIfNeeded() {
        guard snapshot == nil, !isParsing else { return }
        if storage.length <= SyntaxTreeController.immediateParseLimit {
            let job = makeJob()
            finished(job.run(), version: job.version, wasSynchronous: true)
        } else {
            scheduleParse()
        }
    }

    private func makeJob() -> ParseJob {
        ParseJob(version: version, text: TextSnapshot(units: mirror), base: latest?.copy(), edits: edits, grammar: grammar,
                 parsers: parsers, tabWidth: Settings.shared.tabWidth)
    }

    private func finished(_ result: SyntaxSnapshot?, version parsed: Int, wasSynchronous: Bool = false) {
        if !wasSynchronous { isParsing = false }
        // A result older than the one in hand would put the edits it never saw beyond reach.
        guard let result, result.version >= (snapshot?.version ?? -1) else { return }
        snapshot = result
        latest = result.root.tree
        // The edits the job already knew are in its tree; the ones since stay for the next.
        edits.removeFirst(min(edits.count, result.editCount))
        if parsed == version {
            NotificationCenter.default.post(name: SyntaxTreeController.didUpdate, object: self)
            if result.foldRegions == nil { scheduleRegions() }
        } else {
            scheduleParse()
        }
    }

    /// For a big file the fold table is not rebuilt on every keystroke, but once typing pauses.
    private func scheduleRegions() {
        regionsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let snapshot = self.current, snapshot.foldRegions == nil else { return }
            let tabWidth = Settings.shared.tabWidth
            SyntaxTreeController.queue.async {
                let regions = ParseJob.foldRegions(of: snapshot.root, text: snapshot.text, tabWidth: tabWidth)
                DispatchQueue.main.async { [weak self] in
                    guard let self, snapshot === self.snapshot else { return }
                    snapshot.foldRegions = regions
                    NotificationCenter.default.post(name: SyntaxTreeController.didUpdate, object: self)
                }
            }
        }
        regionsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// For tests: parse a string once, with its fold table.
    static func parse(_ text: String, as id: TreeSitterLanguage) -> SyntaxSnapshot? {
        guard let grammar = TreeSitterGrammar.grammar(for: id) else { return nil }
        return ParseJob(version: 0, text: TextSnapshot(text as NSString), base: nil, edits: [], grammar: grammar,
                        parsers: ParserSet(grammar: grammar), tabWidth: 4).run()
    }
}

/// A document's `TSParser` and those for the languages injected into it. Used on one thread at a time.
private final class ParserSet {
    let parser: OpaquePointer
    private var children: [TreeSitterLanguage: OpaquePointer] = [:]

    init(grammar: TreeSitterGrammar) {
        parser = ts_parser_new()
        ts_parser_set_language(parser, grammar.language)
    }

    deinit {
        ts_parser_delete(parser)
        for parser in children.values { ts_parser_delete(parser) }
    }

    func child(for id: TreeSitterLanguage) -> OpaquePointer? {
        if let existing = children[id] { return existing }
        guard let grammar = TreeSitterGrammar.grammar(for: id) else { return nil }
        let parser = ts_parser_new()
        ts_parser_set_language(parser, grammar.language)
        children[id] = parser
        return parser
    }
}

/// One parse: the text as it was, the tree to start from, and what to do after. Runs off the main thread.
private struct ParseJob {
    let version: Int
    let text: TextSnapshot
    /// The last tree, and what happened to the text since it was parsed.
    let base: SyntaxTree?
    let edits: [TSInputEdit]
    let grammar: TreeSitterGrammar
    let parsers: ParserSet
    let tabWidth: Int

    func run() -> SyntaxSnapshot? {
        for edit in edits { base?.edit(edit) }
        guard let tree = text.parse(with: parsers.parser, from: base) ?? text.parse(with: parsers.parser, from: nil) else { return nil }
        let root = SyntaxLayer(grammar: grammar, tree: tree, ranges: [])
        let layers = text.length <= SyntaxTreeController.injectionsLimit ? injectedLayers(in: root) : []
        let regions = text.length <= SyntaxTreeController.regionsWithParseLimit ? ParseJob.foldRegions(of: root, text: text, tabWidth: tabWidth) : nil
        return SyntaxSnapshot(version: version, text: text, root: root, layers: layers, foldRegions: regions, editCount: edits.count)
    }

    // MARK: Injections

    private func injectedLayers(in root: SyntaxLayer) -> [SyntaxLayer] {
        guard let query = grammar.injections else { return [] }
        let contentID = query.captureNames.firstIndex(of: "injection.content").map(UInt32.init)
        let languageID = query.captureNames.firstIndex(of: "injection.language").map(UInt32.init)
        guard let contentID else { return [] }
        let cursor = ts_query_cursor_new()
        defer { ts_query_cursor_delete(cursor) }
        ts_query_cursor_exec(cursor, query.pointer, root.tree.root)
        var match = TSQueryMatch()
        // Separate documents, in order, and the "combined" ones: every css`…` in a file is one CSS document (and
        // a template with `${…}` holes in it matches once per piece, so its pieces meet again here).
        var separate: [(TreeSitterLanguage, [NSRange])] = []
        var combined: [String: (TreeSitterLanguage, [NSRange])] = [:]
        while ts_query_cursor_next_match(cursor, &match) {
            let pattern = Int(match.pattern_index)
            let settings = query.settings[pattern]
            guard query.allows(match, text: text.text(in:)) else { continue }
            let captures = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
            var name = settings["injection.language"]
            if name == nil, let languageID, let capture = captures.first(where: { $0.index == languageID }) {
                name = text.text(in: range(of: capture.node))
            }
            guard let name, let id = TreeSitterLanguage.named(name), id != grammar.id else { continue }
            let ranges = captures.filter { $0.index == contentID }.map { range(of: $0.node) }.filter { $0.length > 0 }
            guard !ranges.isEmpty else { continue }
            if settings["injection.combined"] != nil {
                combined["\(pattern) \(id.rawValue)", default: (id, [])].1 += ranges
            } else {
                separate.append((id, ranges))
            }
        }
        var layers: [SyntaxLayer] = []
        for (id, ranges) in separate + combined.values.map({ $0 }) {
            guard let grammar = TreeSitterGrammar.grammar(for: id), let parser = parsers.child(for: id) else { continue }
            let sorted = ranges.sorted { $0.location < $1.location }
            var included = sorted.map { range in
                TSRange(start_point: text.point(at: range.location), end_point: text.point(at: NSMaxRange(range)),
                        start_byte: UInt32(range.location * 2), end_byte: UInt32(NSMaxRange(range) * 2))
            }
            guard ts_parser_set_included_ranges(parser, &included, UInt32(included.count)),
                  let tree = text.parse(with: parser, from: nil) else { continue }
            layers.append(SyntaxLayer(grammar: grammar, tree: tree, ranges: sorted))
        }
        return layers.sorted { ($0.ranges.first?.location ?? 0) < ($1.ranges.first?.location ?? 0) }
    }

    private func range(of node: TSNode) -> NSRange {
        let start = Int(ts_node_start_byte(node)) / 2
        return NSRange(location: start, length: Int(ts_node_end_byte(node)) / 2 - start)
    }

    // MARK: Folding

    /// The fold table: the tree's blocks (a function's body, a class, an object literal, a `<div>`…) laid over
    /// the indentation-based one, so what the grammar does not know as a block still folds.
    static func foldRegions(of root: SyntaxLayer, text: TextSnapshot, tabWidth: Int) -> FoldRegions {
        var endOf = FoldRegions.lineEnds(text.units, tabWidth: tabWidth)
        let lineCount = endOf.count
        let symbols = root.grammar.foldSymbols
        var cursor = ts_tree_cursor_new(root.tree.root)
        defer { ts_tree_cursor_delete(&cursor) }

        /// Notes the node's block, if it is one, and says whether anything inside could be one too.
        func visit(_ node: TSNode) -> Bool {
            let start = Int(ts_node_start_byte(node)) / 2, end = Int(ts_node_end_byte(node)) / 2
            guard end > start else { return false }
            let startLine = text.line(containing: start), lastLine = text.line(containing: end - 1)
            // A node on one line holds nothing to fold, and neither does anything inside it.
            guard lastLine > startLine else { return false }
            let childCount = Int(ts_node_child_count(node))
            let symbol = ts_node_symbol(node)
            var header = startLine, endLine = lastLine
            var isBlock = false
            if childCount >= 2, symbols.openers.contains(ts_node_symbol(ts_node_child(node, 0))) {
                isBlock = true
            } else if symbols.blocks.contains(symbol) {
                isBlock = true
                if symbol == symbols.indentedBlock {
                    // Python: the body starts on the line after "def f():"; the header is where the statement began.
                    let parent = ts_node_parent(node)
                    header = ts_node_is_null(parent) ? startLine - 1 : text.line(containing: Int(ts_node_start_byte(parent)) / 2)
                    if header >= startLine { header = startLine - 1 }
                }
            }
            guard isBlock else { return true }
            if childCount >= 1 {
                let last = ts_node_child(node, UInt32(childCount - 1))
                // The closing bracket's line stays in view, as with indentation folding.
                if symbols.closers.contains(ts_node_symbol(last)) { endLine = text.line(containing: Int(ts_node_start_byte(last)) / 2) - 1 }
            }
            if header >= 0, header < lineCount, endLine > header { endOf[header] = max(endOf[header], Int32(endLine)) }
            return true
        }

        // A walk of the whole tree without recursion: a long chain of expressions makes a very deep tree.
        walk: while true {
            if visit(ts_tree_cursor_current_node(&cursor)), ts_tree_cursor_goto_first_child(&cursor) { continue }
            if ts_tree_cursor_goto_next_sibling(&cursor) { continue }
            while true {
                guard ts_tree_cursor_goto_parent(&cursor) else { break walk }
                if ts_tree_cursor_goto_next_sibling(&cursor) { continue walk }
            }
        }
        return FoldRegions.build(endOf: endOf)
    }
}

/// Colours text from the trees, the way `SyntaxHighlighter` does from regular expressions.
enum TreeSitterHighlighter {
    struct Token: Hashable {
        let range: NSRange
        let kind: TokenKind
    }

    /// The coloured stretches of one layer inside `range`, in order. The first pattern to name a node decides its
    /// colour (the queries are written for that); a node inside another comes later and overrides it.
    static func tokens(of layer: SyntaxLayer, in range: NSRange, text: (NSRange) -> String) -> [Token] {
        let query = layer.grammar.highlights
        let cursor = ts_query_cursor_new()
        defer { ts_query_cursor_delete(cursor) }
        ts_query_cursor_set_byte_range(cursor, UInt32(range.location * 2), UInt32(NSMaxRange(range) * 2))
        ts_query_cursor_exec(cursor, query.pointer, layer.tree.root)
        var match = TSQueryMatch()
        var captureIndex: UInt32 = 0
        var tokens: [Token] = []
        var lastNode = NSRange(location: NSNotFound, length: 0)
        var lastMatch: (id: UInt32, allowed: Bool) = (.max, true)
        while ts_query_cursor_next_capture(cursor, &match, &captureIndex) {
            let capture = match.captures[Int(captureIndex)]
            guard let kind = query.kinds[Int(capture.index)] else { continue }
            let start = Int(ts_node_start_byte(capture.node)) / 2
            let node = NSRange(location: start, length: Int(ts_node_end_byte(capture.node)) / 2 - start)
            if node == lastNode { continue }
            if !query.predicates[Int(match.pattern_index)].isEmpty {
                if match.id != lastMatch.id { lastMatch = (match.id, query.allows(match, text: text)) }
                guard lastMatch.allowed else { continue }
            }
            lastNode = node
            let clipped = NSIntersectionRange(node, range)
            guard clipped.length > 0 else { continue }
            if let last = tokens.last, last.kind == kind, NSMaxRange(last.range) == clipped.location {
                tokens[tokens.count - 1] = Token(range: NSUnionRange(last.range, clipped), kind: kind)
            } else {
                tokens.append(Token(range: clipped, kind: kind))
            }
        }
        return tokens
    }

    /// What `range` should look like: the root layer's tokens with, where another language is injected, that
    /// layer's tokens in place of them (plain text between them, so a string's colour does not show through).
    /// In order, not overlapping.
    static func paint(_ snapshot: SyntaxSnapshot, in range: NSRange, text: (NSRange) -> String) -> [Token] {
        var result = tokens(of: snapshot.root, in: range, text: text)
        for layer in snapshot.layers {
            let stretches = layer.ranges.map { NSIntersectionRange($0, range) }.filter { $0.length > 0 }
            guard !stretches.isEmpty else { continue }
            var cut: [Token] = []
            for token in result {
                var pieces = [token.range]
                for stretch in stretches where NSIntersectionRange(stretch, token.range).length > 0 {
                    pieces = pieces.flatMap { piece -> [NSRange] in
                        guard NSIntersectionRange(stretch, piece).length > 0 else { return [piece] }
                        var left: [NSRange] = []
                        if piece.location < stretch.location { left.append(NSRange(location: piece.location, length: stretch.location - piece.location)) }
                        if NSMaxRange(piece) > NSMaxRange(stretch) { left.append(NSRange(location: NSMaxRange(stretch), length: NSMaxRange(piece) - NSMaxRange(stretch))) }
                        return left
                    }
                }
                cut += pieces.map { Token(range: $0, kind: token.kind) }
            }
            result = (cut + tokens(of: layer, in: range, text: text)).sorted { $0.range.location < $1.range.location }
        }
        return result
    }
}

/// What one editor has coloured from its trees, so a pass touches only what changed. Almost nothing in view
/// changes colour with a keystroke, and putting every token back costs far more than the parse does; a
/// keystroke now costs a handful of attribute changes.
final class TreeHighlightState {
    typealias Token = TreeSitterHighlighter.Token

    /// In order, not overlapping.
    private var applied: [Token] = []
    /// The stretch `applied` speaks for; outside it the layout manager may hold anything.
    private var covered: NSRange?
    /// Edited text, and the tokens that were over it, whose colour is stale until the next pass.
    private var dirty: [NSRange] = []

    /// Everything must be put back: another theme, another language.
    func reset() {
        applied = []
        covered = nil
        dirty = []
    }

    /// Called from the storage's did-process-editing notification, so what was coloured moves with the text.
    func noteEdit(_ edited: NSRange, delta: Int) {
        guard covered != nil else { return }
        let oldEnd = NSMaxRange(edited) - delta
        func shifted(_ range: NSRange) -> NSRange {
            if NSMaxRange(range) <= edited.location { return range }
            if range.location >= oldEnd { return NSRange(location: range.location + delta, length: range.length) }
            let end = max(NSMaxRange(edited), NSMaxRange(range) + delta)
            return NSRange(location: min(range.location, edited.location), length: end - min(range.location, edited.location))
        }
        var stale = edited
        var kept: [Token] = []
        kept.reserveCapacity(applied.count)
        for token in applied {
            if NSMaxRange(token.range) <= edited.location {
                kept.append(token)
            } else if token.range.location >= oldEnd {
                kept.append(Token(range: NSRange(location: token.range.location + delta, length: token.range.length), kind: token.kind))
            } else {
                // Over the edit: dropped, and its old colour cleared with the edit's.
                stale = NSUnionRange(stale, shifted(token.range))
            }
        }
        applied = kept
        dirty = dirty.map(shifted) + [stale]
        // Edits all over the file: one stretch covering them costs a little more colouring, not bookkeeping.
        if dirty.count > 16 { dirty = [dirty.dropFirst().reduce(dirty[0], NSUnionRange)] }
        covered = covered.map(shifted)
    }

    /// Colours `range` from the snapshot, changing only what differs from the last pass.
    func apply(_ snapshot: SyntaxSnapshot, storage: NSTextStorage, layoutManager: NSLayoutManager, range: NSRange, theme: Theme) {
        guard range.length > 0 else { return }
        let ns = storage.mutableString
        // A token reaching across the edge of `range` (a long comment) is taken whole, so it is compared whole.
        var range = range
        for token in applied where NSIntersectionRange(token.range, range).length > 0 { range = NSUnionRange(range, token.range) }
        let fresh = TreeSitterHighlighter.paint(snapshot, in: range, text: { ns.substring(with: $0) })

        // What may still show a colour nobody vouches for: the edited stretch, and what was never coloured.
        var clear: [NSRange] = []
        for stale in dirty { clear.append(NSIntersectionRange(stale, range)) }
        dirty.removeAll { NSIntersectionRange($0, range) == $0 }
        if let covered {
            if range.location < covered.location { clear.append(NSRange(location: range.location, length: min(NSMaxRange(range), covered.location) - range.location)) }
            if NSMaxRange(range) > NSMaxRange(covered) { clear.append(NSRange(location: max(range.location, NSMaxRange(covered)), length: NSMaxRange(range) - max(range.location, NSMaxRange(covered)))) }
        } else {
            clear.append(range)
        }
        for stretch in clear where stretch.length > 0 && NSMaxRange(stretch) <= ns.length {
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: stretch)
        }

        let before = applied.filter { NSMaxRange($0.range) <= range.location }
        let inside = applied.filter { NSIntersectionRange($0.range, range).length > 0 }
        let after = applied.filter { $0.range.location >= NSMaxRange(range) }
        let wanted = Set(fresh)
        // A token just cleared along with an edited stretch no longer counts as coloured.
        let had = Set(inside.filter { token in !clear.contains { NSIntersectionRange($0, token.range).length > 0 } })
        for token in inside where !wanted.contains(token) && NSMaxRange(token.range) <= ns.length {
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: token.range)
        }
        for token in fresh where !had.contains(token) && NSMaxRange(token.range) <= ns.length {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: theme.color(for: token.kind), forCharacterRange: token.range)
        }
        applied = before + fresh + after
        covered = covered.map { NSUnionRange($0, range) } ?? range
    }
}
