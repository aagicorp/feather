import AppKit

/// Who last changed one line.
struct BlameCommit {
    let hash: String
    let author: String
    let email: String
    let date: Date
    let summary: String

    /// Git blames lines that are in the file but in no commit on a commit of all zeros.
    var isUncommitted: Bool { hash.allSatisfy { $0 == "0" } }
}

/// `git blame` for the files being edited, asked once per saved version of a file and then only looked up.
/// Moving the caret is an array index. Typing marks the line map stale and, once the typing pauses, one
/// background line diff brings it up to date; nothing here reads the document on the keystroke itself.
final class BlameStore {
    /// New blame arrived, or the line map caught up with the text: whoever shows blame should look again.
    var onUpdate: (() -> Void)?

    private final class Entry {
        weak var document: TextDocument?
        var commits: [BlameCommit] = []
        /// For each line of the blamed file: an index into `commits`, and the line's text for mapping edits.
        var lineCommits: [Int] = []
        var lineTexts: [String] = []
        var userEmail = ""
        var root: URL?
        var isLoading = false
        var isLoaded = false
        /// Set by a save or a repository change: what is here is still shown while the new answer is on its way.
        var isStale = false
        /// The file itself was written, so HEAD being where it was is no reason to keep the old answer.
        var fileChanged = false
        var head = ""
        var generation = 0
        /// Buffer line → blamed line (or -1), for `mappedChange`; nil means the two are the same text.
        var map: [Int]?
        var mappedChange = -1
        var mapScheduled = false
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private static let mapQueue = DispatchQueue(label: "feather.blame.map", qos: .utility)
    private static let maxLength = 6_000_000
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    struct Info {
        let commit: BlameCommit
        let isYou: Bool
        let root: URL?

        var text: String {
            if commit.isUncommitted { return "Not committed yet" }
            let when = BlameStore.relative.localizedString(for: commit.date, relativeTo: Date())
            let summary = commit.summary.count > 60 ? String(commit.summary.prefix(60)) + "…" : commit.summary
            return "\(isYou ? "You" : commit.author), \(when) · \(summary)"
        }
    }

    /// Blame for a zero-based line of the document as it is in the editor now, or nil when there is none (yet).
    func info(for document: TextDocument, line: Int) -> Info? {
        guard Settings.shared.showBlame, !document.isMedia, let url = document.url, document.storage.length <= BlameStore.maxLength else { return nil }
        let key = ObjectIdentifier(document)
        let entry = entries[key] ?? {
            let entry = Entry()
            entry.document = document
            entries[key] = entry
            return entry
        }()
        if (!entry.isLoaded || entry.isStale) && !entry.isLoading { load(entry, url: url) }
        guard entry.isLoaded, !entry.lineCommits.isEmpty else { return nil }
        if entry.mappedChange != document.changeCount {
            scheduleMap(entry)
            return nil
        }
        let blamed = entry.map.map { $0.indices.contains(line) ? $0[line] : -1 } ?? line
        guard entry.lineCommits.indices.contains(blamed) else { return nil }
        let commit = entry.commits[entry.lineCommits[blamed]]
        return Info(commit: commit, isYou: !entry.userEmail.isEmpty && commit.email.caseInsensitiveCompare(entry.userEmail) == .orderedSame, root: entry.root)
    }

    /// The file was saved: its blame is asked for again the next time it is wanted.
    func invalidate(_ url: URL) {
        for entry in entries.values where entry.document?.url == url {
            entry.isStale = true
            entry.fileChanged = true
        }
    }

    /// HEAD may have moved (commit, checkout, pull). Also the moment to forget documents that were closed.
    func invalidateAll() {
        entries = entries.filter { $0.value.document != nil }
        entries.values.forEach { $0.isStale = true }
    }

    // MARK: - Loading

    private func load(_ entry: Entry, url: URL) {
        // Coming back to the app marks everything stale, and usually nothing happened: when HEAD has not moved and
        // the file was not saved, the answer in hand is still the answer.
        let knownHead = entry.isLoaded && !entry.fileChanged ? entry.head : nil
        entry.isLoading = true
        entry.isStale = false
        entry.fileChanged = false
        entry.generation += 1
        let generation = entry.generation
        let directory = url.deletingLastPathComponent()
        Git.perform(changesIndex: false, { () -> (parsed: BlameStore.Parsed?, email: String, root: URL?, head: String, unchanged: Bool) in
            let head = Git.runSync(["rev-parse", "HEAD"], in: directory).output.trimmingCharacters(in: .whitespacesAndNewlines)
            if let knownHead, knownHead == head { return (nil, "", nil, head, true) }
            let blame = Git.runSync(["blame", "--porcelain", "--", url.lastPathComponent], in: directory)
            guard blame.ok else { return (nil, "", nil, head, false) }           // untracked, not a repository, Restricted Mode
            let email = Git.runSync(["config", "user.email"], in: directory).output.trimmingCharacters(in: .whitespacesAndNewlines)
            let top = Git.runSync(["rev-parse", "--show-toplevel"], in: directory).output.trimmingCharacters(in: .whitespacesAndNewlines)
            return (BlameStore.parse(blame.output), email, top.isEmpty ? nil : URL(fileURLWithPath: top), head, false)
        }, completion: { [weak self, weak entry] result in
            guard let self, let entry, entry.generation == generation else { return }
            entry.isLoading = false
            guard !result.unchanged else { return }
            entry.isLoaded = true
            entry.head = result.head
            entry.commits = result.parsed?.commits ?? []
            entry.lineCommits = result.parsed?.lineCommits ?? []
            entry.lineTexts = result.parsed?.lineTexts ?? []
            entry.userEmail = result.email
            entry.root = result.root
            entry.map = nil
            // Blame read the file on disk. With no unsaved edits that is the text in the editor, line for line.
            if let document = entry.document, !document.isDirty {
                entry.mappedChange = document.changeCount
            } else {
                entry.mappedChange = -1
            }
            self.onUpdate?()
        })
    }

    struct Parsed {
        var commits: [BlameCommit] = []
        var lineCommits: [Int] = []
        var lineTexts: [String] = []
    }

    /// The porcelain format: a header line per source line ("<hash> <original> <final> [<count>]"), the commit's
    /// details the first time that commit appears, then the line itself after a tab.
    static func parse(_ output: String) -> Parsed {
        var parsed = Parsed()
        var indexOfCommit: [String: Int] = [:]
        var fields: [String: [String: String]] = [:]
        var current = ""
        var order: [String] = []
        output.enumerateLines { line, _ in
            if line.hasPrefix("\t") {
                if indexOfCommit[current] == nil {
                    indexOfCommit[current] = order.count
                    order.append(current)
                }
                parsed.lineCommits.append(indexOfCommit[current] ?? 0)
                parsed.lineTexts.append(String(line.dropFirst()))
            } else if let space = line.firstIndex(of: " ") {
                let word = line[..<space]
                if word.count == 40, word.allSatisfy(\.isHexDigit) {
                    current = String(word)
                } else {
                    fields[current, default: [:]][String(word)] = String(line[line.index(after: space)...])
                }
            }
        }
        parsed.commits = order.map { hash in
            let details = fields[hash] ?? [:]
            return BlameCommit(hash: hash, author: details["author"] ?? "", email: (details["author-mail"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "<>")),
                               date: Date(timeIntervalSince1970: TimeInterval(details["author-time"] ?? "") ?? 0), summary: details["summary"] ?? "")
        }
        return parsed
    }

    // MARK: - Unsaved edits

    /// One line diff, off the main thread, once the typing has paused. While it is pending there is simply no blame
    /// to show, which is better than blame for the wrong line.
    private func scheduleMap(_ entry: Entry) {
        guard !entry.mapScheduled else { return }
        entry.mapScheduled = true
        let changeWhenScheduled = entry.document?.changeCount ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak entry] in
            guard let self, let entry, let document = entry.document else { return }
            entry.mapScheduled = false
            // Still typing: wait for the next pause rather than diffing text that is about to change again.
            guard document.changeCount == changeWhenScheduled else { return self.scheduleMap(entry) }
            let change = document.changeCount, generation = entry.generation
            let text = document.text
            let blamed = entry.lineTexts
            BlameStore.mapQueue.async {
                let map = BlameStore.lineMap(from: blamed, to: text)
                DispatchQueue.main.async {
                    guard entry.generation == generation, entry.document?.changeCount == change else { return }
                    entry.map = map
                    entry.mappedChange = change
                    self.onUpdate?()
                }
            }
        }
    }

    /// For each line of `text`, the line of `old` it came from, or -1 for a line that is new or was edited.
    static func lineMap(from old: [String], to text: String) -> [Int] {
        var lines: [String] = []
        text.enumerateLines { line, _ in lines.append(line) }
        guard old.count <= LineDiff.maxLines, lines.count <= LineDiff.maxLines else { return Array(repeating: -1, count: lines.count) }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in lines.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var map = Array(repeating: -1, count: lines.count)
        var i = 0
        for j in 0..<lines.count where !inserted.contains(j) {
            while removed.contains(i) { i += 1 }
            map[j] = i
            i += 1
        }
        return map
    }
}

/// The status bar's blame text. A click, or the pointer resting on it, shows the commit's card.
final class BlameStatusButton: NSButton {
    private var info: BlameStore.Info?
    private var popover: NSPopover?
    private var shownHash: String?
    private var hoverWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var pointerInsideCard = false
    private(set) var shownText = ""
    private var shownColour: NSColor?

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        font = .systemFont(ofSize: 11)
        lineBreakMode = .byTruncatingTail
        setContentCompressionResistancePriority(.defaultLow - 20, for: .horizontal)
        target = self
        action = #selector(clicked)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Runs on every caret move, so it only touches what changed.
    func show(_ info: BlameStore.Info?, colour: NSColor) {
        let text = info?.text ?? ""
        if text != shownText || shownColour != colour {
            attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: colour])
            toolTip = text.isEmpty ? nil : "Click to see the commit"
            shownText = text
            shownColour = colour
        }
        if isHidden != text.isEmpty { isHidden = text.isEmpty }
        if info?.commit.hash != self.info?.commit.hash, popover != nil { closeCard() }
        self.info = info
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        closeWork?.cancel()
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showCard() }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        hoverWork?.cancel()
        scheduleClose()
    }

    @objc private func clicked() {
        hoverWork?.cancel()
        showCard()
    }

    private func scheduleClose() {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerInsideCard else { return }
            self.closeCard()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func closeCard() {
        popover?.close()
        popover = nil
        shownHash = nil
        pointerInsideCard = false
    }

    /// The same card the commit graph shows. A line that is in no commit yet has no card.
    func showCard() {
        guard let info, !info.commit.isUncommitted, let root = info.root, window != nil, shownHash != info.commit.hash else { return }
        let hash = info.commit.hash
        GitCommitDetails.load(hash, in: root) { [weak self] details in
            guard let self, let details, self.info?.commit.hash == hash, self.window != nil else { return }
            self.closeCard()
            let theme = Settings.shared.theme
            let card = CommitHoverView(details: details, theme: theme)
            card.onPointerInside = { [weak self] inside in
                self?.pointerInsideCard = inside
                if inside { self?.closeWork?.cancel() } else { self?.scheduleClose() }
            }
            let controller = NSViewController()
            controller.view = card
            let popover = NSPopover()
            popover.contentViewController = controller
            popover.behavior = .semitransient
            popover.animates = false
            popover.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
            popover.show(relativeTo: self.bounds, of: self, preferredEdge: .maxY)
            self.popover = popover
            self.shownHash = hash
        }
    }

    /// For checking that the card came up.
    var isShowingCard: Bool { popover?.isShown == true }
}
