import AppKit

/// Which lines of a file are new, from the text as it was to the text as it is: zero-based, half-open line
/// ranges in the new text, the way `CheckpointStore.changedLines` reports them. A line that was only taken away
/// is an empty range at the place it was.
enum ChangedLines {
    /// Beyond this many differing lines the middle is flashed as one block rather than diffed line by line.
    static let maxDiffedLines = 2000

    static func ranges(from old: String, to new: String) -> [Range<Int>] {
        guard old != new else { return [] }
        // By newline of any kind: Swift reads "\r\n" as one Character, so splitting on "\n" alone would see a
        // CRLF file as a single line.
        let a = old.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let b = new.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let oldMiddle = a[prefix..<(a.count - suffix)]
        let newMiddle = b[prefix..<(b.count - suffix)]
        if newMiddle.isEmpty { return oldMiddle.isEmpty ? [] : [prefix..<prefix] }
        if oldMiddle.isEmpty || oldMiddle.count > maxDiffedLines || newMiddle.count > maxDiffedLines {
            return [prefix..<(prefix + newMiddle.count)]
        }
        let difference = Array(newMiddle).difference(from: Array(oldMiddle))
        var inserted = Set<Int>(), removed = Set<Int>()
        for change in difference {
            switch change {
            case .insert(let offset, _, _): inserted.insert(offset)
            case .remove(let offset, _, _): removed.insert(offset)
            }
        }
        // Walk both sides together: the lines neither side changed pair up in order, which places each removal
        // at the line of the new text where it used to be (removals first, so a replaced line is one range).
        var lines = Set<Int>(), deletions = Set<Int>()
        var i = 0, j = 0
        while i < oldMiddle.count || j < newMiddle.count {
            if i < oldMiddle.count, removed.contains(i) { deletions.insert(prefix + j); i += 1; continue }
            if j < newMiddle.count, inserted.contains(j) { lines.insert(prefix + j); j += 1; continue }
            i += 1; j += 1
        }
        var result: [Range<Int>] = []
        for line in lines.sorted() {
            if let last = result.last, last.upperBound == line {
                result[result.count - 1] = last.lowerBound..<(line + 1)
            } else {
                result.append(line..<(line + 1))
            }
        }
        for place in deletions where !result.contains(where: { $0.contains(place) || $0.lowerBound == place }) {
            result.append(place..<place)
        }
        return result.sorted { $0.lowerBound < $1.lowerBound }
    }
}

extension Notification.Name {
    /// The assistant in a terminal was given something to do (userInfo: "window"). What the file in front says
    /// now is remembered, so what the assistant changes in it can be shown afterwards.
    static let assistantDidStartWorking = Notification.Name("FeatherAssistantDidStartWorking")
    /// The assistant stopped: quiet after working, or its program ended (userInfo: "window", "name", "since" Date).
    static let assistantDidStop = Notification.Name("FeatherAssistantDidStop")
}

/// The text of the document in front when the assistant set to work, for the flash when it stops.
struct FrontDocumentSnapshot {
    let document: ObjectIdentifier
    let changeCount: Int
    let text: String
}

extension ActivityCoordinator {
    static let assistantCardKind = "assistantChanges"
    /// A document bigger than this is not copied for the flash.
    static let maxSnapshotBytes = 2_000_000

    // MARK: - Files changed since a moment

    /// Called with every batch of folder events (already free of noisy folders) so the folders that saw
    /// changes, and when, are known.
    func noteDirectoryEvents(_ paths: [String]) {
        let now = Date()
        for path in paths { recentDirectoryEvents[path] = now }
        if recentDirectoryEvents.count > 400 {
            recentDirectoryEvents = recentDirectoryEvents.filter { now.timeIntervalSince($0.value) < 600 }
        }
    }

    /// The files under the project folder written at or after `date`, newest first, by looking only in the
    /// folders that reported a change since then. Feather's own saves are not counted.
    func filesChanged(since date: Date) -> [URL] {
        guard store != nil else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]
        var found: [(URL, Date)] = []
        for (directory, when) in recentDirectoryEvents where when >= date.addingTimeInterval(-1) {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for name in names where name != ".DS_Store" {
                let file = url.appendingPathComponent(name)
                guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                      let modified = values.contentModificationDate ?? values.creationDate, modified >= date else { continue }
                if let own = ownWrites[file.standardizedFileURL.path], abs(own.timeIntervalSince(modified)) < 2 { continue }
                found.append((file.standardizedFileURL, modified))
                if found.count >= 200 { break }
            }
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    // MARK: - The assistant at work

    @objc func assistantStartedWorking(_ notification: Notification) {
        guard notification.userInfo?["window"] as? NSWindow === controller?.window else { return }
        rememberFrontDocument()
    }

    /// Copies the text of the document in front, unless the copy from last time is still current.
    func rememberFrontDocument() {
        guard let tab = controller?.editorArea.currentTab, tab.preview == nil, !tab.document.isMedia else { return }
        let document = tab.document
        if let snapshot = frontSnapshot, snapshot.document == ObjectIdentifier(document), snapshot.changeCount == document.changeCount { return }
        guard document.storage.length <= ActivityCoordinator.maxSnapshotBytes else { frontSnapshot = nil; return }
        frontSnapshot = FrontDocumentSnapshot(document: ObjectIdentifier(document), changeCount: document.changeCount, text: document.text)
    }

    @objc func assistantStopped(_ notification: Notification) {
        guard notification.userInfo?["window"] as? NSWindow === controller?.window,
              let since = notification.userInfo?["since"] as? Date else { return }
        assistantStopped(name: notification.userInfo?["name"] as? String ?? "The assistant", since: since)
    }

    /// The assistant went quiet: if files changed since it set to work, the changed lines of the file in front
    /// light up and a card says how many files there are to review. Nothing is opened and the keyboard stays
    /// where it is.
    @discardableResult
    func assistantStopped(name: String, since: Date) -> Int {
        let changed = filesChanged(since: since)
        guard !changed.isEmpty, let controller else { return 0 }
        controller.store.syncWithDisk(refreshGitBases: false)
        flashFrontDocument(if: changed)
        if let window = controller.window {
            let count = changed.count
            let card = NoticeCard(kind: ActivityCoordinator.assistantCardKind, symbol: "sparkles",
                                  text: "\(name) changed \(count) file\(count == 1 ? "" : "s")",
                                  actions: [.init(title: "Review in Activity", isProminent: true) { [weak controller] in controller?.showActivity(nil) }],
                                  dismissTitle: "OK")
            WindowNotices.show(card, in: window)
        }
        return changed.count
    }

    private func flashFrontDocument(if changed: [URL]) {
        guard let controller, let tab = controller.editorArea.currentTab, tab.preview == nil,
              let url = tab.url?.standardizedFileURL, changed.contains(url), let textView = tab.editorIfLoaded?.textView else { return }
        let document = tab.document
        defer { frontSnapshot = nil }
        if let snapshot = frontSnapshot, snapshot.document == ObjectIdentifier(document) {
            guard snapshot.changeCount != document.changeCount else { return }
            flash(ChangedLines.ranges(from: snapshot.text, to: document.text), in: textView)
        } else if let store, let checkpoint = target, let path = relativePath(of: url) {
            // No copy of the text from before: the lines that differ from the checkpoint are the next best thing.
            store.changedLines(of: path, since: checkpoint) { [weak self, weak textView] lines in
                guard let self, let textView else { return }
                self.flash(lines, in: textView)
            }
        }
    }

    private func flash(_ lines: [Range<Int>], in textView: NSTextView) {
        let ranges = ActivityCoordinator.characterRanges(of: lines, in: textView.string as NSString)
        guard let first = ranges.first else { return }
        textView.scrollRangeToVisible(NSRange(location: first.location, length: 0))
        FollowFlash.show(ranges, in: textView)
    }
}
