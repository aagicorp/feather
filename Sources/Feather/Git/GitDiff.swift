import Foundation

/// Which pair of versions a diff tab compares, with git's own meanings: what is not staged yet is the index
/// against the working tree, and what is staged is HEAD against the index.
enum DiffSide: String {
    case workingTree, index

    var label: String { self == .workingTree ? "Working Tree" : "Index" }
}

/// One block of changed lines, exactly as `git diff -U0` cut it.
struct DiffHunk {
    /// Zero-based index of the first old line in the block (or of the line the new ones go in front of).
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    /// The "@@" line and the lines under it, byte for byte, ready to go back to `git apply`.
    let patch: Data
}

struct DiffRow {
    enum Kind { case context, removed, added, changed, fold }
    var kind: Kind
    /// Zero-based line on each side, or -1 where that side is blank.
    var old: Int
    var new: Int
    /// The block the row belongs to, or -1.
    var hunk = -1
    /// For a fold: how many unchanged lines it stands for, starting at `old` / `new`.
    var count = 0
}

/// Both versions of one file and the blocks that differ. Built off the main thread; never changed afterwards.
struct FileDiff {
    enum Problem: Error, Equatable {
        case binary, tooLarge, restricted, failed(String)

        var message: String {
            switch self {
            case .binary: return "This is a binary file, so there are no lines to compare."
            case .tooLarge: return "This file is too large to compare here. Use “git diff” in the terminal."
            case .restricted: return "Git is off in Restricted Mode. Trust this folder to see changes."
            case .failed(let text): return text
            }
        }
    }

    static let maxBytes = 4_000_000
    static let maxLines = 60_000
    static let contextLines = 3

    var oldLines: [String] = []
    var newLines: [String] = []
    var hunks: [DiffHunk] = []
    /// Everything `git diff` printed before the first block: the "diff --git", "---" and "+++" lines.
    var header = Data()
    /// False when a single block cannot be applied on its own (a rename, a new file, a deleted file).
    var canPatchBlocks = false
    var insertions = 0
    var deletions = 0

    // MARK: - Loading

    /// Runs git and reads the file on the calling thread, which must not be the main thread.
    static func load(root: URL, path: String, originalPath: String?, side: DiffSide) -> Result<FileDiff, Problem> {
        if WorkspaceTrust.shared.blocksExecution(in: root) { return .failure(.restricted) }
        let oldData: Data, newData: Data
        var arguments = ["diff", "--no-color", "--no-ext-diff", "-U0"]
        switch side {
        case .workingTree:
            let indexed = Git.runSyncData(["show", ":" + path], in: root)
            oldData = indexed.status == 0 ? indexed.output : Data()
            newData = (try? Data(contentsOf: root.appendingPathComponent(path), options: .mappedIfSafe)) ?? Data()
            arguments += ["--", path]
        case .index:
            let committed = Git.runSyncData(["show", "HEAD:" + (originalPath ?? path)], in: root)
            oldData = committed.status == 0 ? committed.output : Data()
            let indexed = Git.runSyncData(["show", ":" + path], in: root)
            newData = indexed.status == 0 ? indexed.output : Data()
            arguments += ["--cached", "-M", "--"] + [originalPath, path].compactMap { $0 }
        }
        guard oldData.count <= maxBytes, newData.count <= maxBytes else { return .failure(.tooLarge) }
        guard !oldData.prefix(8192).contains(0), !newData.prefix(8192).contains(0) else { return .failure(.binary) }
        let result = Git.runSyncData(arguments, in: root)
        guard result.status == 0 else { return .failure(.failed(result.error.trimmingCharacters(in: .whitespacesAndNewlines))) }

        var diff = FileDiff()
        diff.oldLines = lines(of: oldData)
        diff.newLines = lines(of: newData)
        guard diff.oldLines.count <= maxLines, diff.newLines.count <= maxLines else { return .failure(.tooLarge) }
        let (header, hunks) = parse(result.output)
        if String(decoding: header, as: UTF8.self).contains("\nBinary files ") { return .failure(.binary) }
        diff.header = header
        diff.hunks = hunks
        if hunks.isEmpty, oldData != newData, oldData.isEmpty || newData.isEmpty {
            // A file git does not track yet has no diff to parse; it is one block of new lines.
            diff.hunks = [DiffHunk(oldStart: 0, oldCount: diff.oldLines.count, newStart: 0, newCount: diff.newLines.count, patch: Data())]
        } else {
            let text = String(decoding: header, as: UTF8.self)
            let special = ["\nrename from ", "\nnew file mode", "\ndeleted file mode", "\ncopy from "].contains { text.contains($0) }
            diff.canPatchBlocks = !hunks.isEmpty && !special
        }
        diff.insertions = diff.hunks.reduce(0) { $0 + $1.newCount }
        diff.deletions = diff.hunks.reduce(0) { $0 + $1.oldCount }
        return .success(diff)
    }

    /// Split on the newline byte, so "\r\n" (one Character to Swift) cannot confuse the line numbers. The carriage
    /// return is dropped from what is shown.
    static func lines(of data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        var pieces = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if pieces.last?.isEmpty == true { pieces.removeLast() }          // the file ended with a newline
        return pieces.map { piece in
            let trimmed = piece.last == 0x0D ? piece.dropLast() : piece
            return String(decoding: trimmed, as: UTF8.self)
        }
    }

    /// Cuts `git diff -U0` output into its header and its blocks.
    static func parse(_ output: Data) -> (header: Data, hunks: [DiffHunk]) {
        var starts: [Int] = []
        let marker = Array("@@ -".utf8)
        output.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var lineStart = 0
            for index in 0...bytes.count {
                guard index == bytes.count || bytes[index] == 0x0A else { continue }
                if index - lineStart >= marker.count, (0..<marker.count).allSatisfy({ bytes[lineStart + $0] == marker[$0] }) {
                    starts.append(lineStart)
                }
                lineStart = index + 1
            }
        }
        guard let first = starts.first else { return (output, []) }
        let base = output.startIndex
        var hunks: [DiffHunk] = []
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1] : output.count
            let patch = output.subdata(in: (base + start)..<(base + end))
            let lineEnd = patch.firstIndex(of: 0x0A) ?? patch.endIndex
            let headerLine = String(decoding: patch[patch.startIndex..<lineEnd], as: UTF8.self)
            // "@@ -12,3 +14,2 @@ optional function name"
            let fields = headerLine.split(separator: " ")
            guard fields.count >= 3, let old = range(fields[1]), let new = range(fields[2]) else { continue }
            hunks.append(DiffHunk(oldStart: old.count == 0 ? old.start : old.start - 1, oldCount: old.count,
                                  newStart: new.count == 0 ? new.start : new.start - 1, newCount: new.count, patch: patch))
        }
        return (output.subdata(in: base..<(base + first)), hunks)
    }

    /// "-12,3" or "+14" (a count of one is left out).
    private static func range(_ field: Substring) -> (start: Int, count: Int)? {
        let numbers = field.dropFirst().split(separator: ",")
        guard let first = numbers.first, let start = Int(first) else { return nil }
        return (start, numbers.count > 1 ? Int(numbers[1]) ?? 1 : 1)
    }

    // MARK: - Rows

    /// The side-by-side rows: each block, a few lines around it, and one fold row for every long unchanged stretch.
    func rows() -> [DiffRow] {
        var rows: [DiffRow] = []
        var old = 0, new = 0
        func unchanged(upTo oldEnd: Int, isFirst: Bool, isLast: Bool) {
            let count = oldEnd - old
            guard count > 0 else { return }
            let context = FileDiff.contextLines
            let head = isFirst ? 0 : context, tail = isLast ? 0 : context
            if count <= head + tail + 4 {
                for offset in 0..<count { rows.append(DiffRow(kind: .context, old: old + offset, new: new + offset)) }
            } else {
                for offset in 0..<head { rows.append(DiffRow(kind: .context, old: old + offset, new: new + offset)) }
                let folded = count - head - tail
                rows.append(DiffRow(kind: .fold, old: old + head, new: new + head, count: folded))
                for offset in (count - tail)..<count { rows.append(DiffRow(kind: .context, old: old + offset, new: new + offset)) }
            }
            old += count
            new += count
        }
        for (index, hunk) in hunks.enumerated() {
            unchanged(upTo: hunk.oldStart, isFirst: index == 0, isLast: false)
            for offset in 0..<max(hunk.oldCount, hunk.newCount) {
                let hasOld = offset < hunk.oldCount, hasNew = offset < hunk.newCount
                rows.append(DiffRow(kind: hasOld && hasNew ? .changed : (hasOld ? .removed : .added),
                                    old: hasOld ? hunk.oldStart + offset : -1, new: hasNew ? hunk.newStart + offset : -1, hunk: index))
            }
            old = hunk.oldStart + hunk.oldCount
            new = hunk.newStart + hunk.newCount
        }
        unchanged(upTo: oldLines.count, isFirst: hunks.isEmpty, isLast: true)
        return rows
    }

    /// The rows a fold row stands for.
    static func expanded(_ fold: DiffRow) -> [DiffRow] {
        (0..<fold.count).map { DiffRow(kind: .context, old: fold.old + $0, new: fold.new + $0) }
    }

    /// The parts of two lines that differ, as UTF-16 ranges: the words one side has and the other does not. A very
    /// long line falls back to "everything between what the two share at each end".
    static func changedSpans(_ old: String, _ new: String) -> (old: [NSRange], new: [NSRange]) {
        let a = tokens(of: old), b = tokens(of: new)
        guard a.count <= 400, b.count <= 400 else {
            let x = old as NSString, y = new as NSString
            let limit = min(x.length, y.length)
            var prefix = 0
            while prefix < limit, x.character(at: prefix) == y.character(at: prefix) { prefix += 1 }
            var suffix = 0
            while suffix < limit - prefix, x.character(at: x.length - 1 - suffix) == y.character(at: y.length - 1 - suffix) { suffix += 1 }
            return ([NSRange(location: prefix, length: x.length - prefix - suffix)], [NSRange(location: prefix, length: y.length - prefix - suffix)])
        }
        var removed: [NSRange] = [], inserted: [NSRange] = []
        for change in b.map(\.text).difference(from: a.map(\.text)) {
            switch change {
            case .remove(let offset, _, _): removed.append(a[offset].range)
            case .insert(let offset, _, _): inserted.append(b[offset].range)
            }
        }
        return (merged(removed), merged(inserted))
    }

    /// Words, runs of spaces, and every other character by itself.
    private static func tokens(of line: String) -> [(text: Substring, range: NSRange)] {
        var result: [(Substring, NSRange)] = []
        var location = 0
        var index = line.startIndex
        func kind(_ character: Character) -> Int { character.isLetter || character.isNumber || character == "_" ? 0 : (character == " " ? 1 : 2) }
        while index < line.endIndex {
            let first = kind(line[index])
            var end = line.index(after: index)
            if first != 2 { while end < line.endIndex, kind(line[end]) == first { end = line.index(after: end) } }
            let piece = line[index..<end]
            let length = piece.utf16.count
            result.append((piece, NSRange(location: location, length: length)))
            location += length
            index = end
        }
        return result
    }

    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = result.last, NSMaxRange(last) == range.location {
                result[result.count - 1].length += range.length
            } else {
                result.append(range)
            }
        }
        return result
    }

    // MARK: - Patching one block

    enum BlockAction {
        case stage, unstage, revert

        var arguments: [String] {
            switch self {
            case .stage, .unstage: return ["apply", "--cached", "--unidiff-zero", "--whitespace=nowarn"]
            case .revert: return ["apply", "--unidiff-zero", "--whitespace=nowarn"]
            }
        }
    }

    /// One block made ready to be applied by itself, forwards or turned around (what it added is taken away and
    /// what it took away is put back).
    ///
    /// Without context lines `git apply` puts a block where its *new-side* line number says, and that number, as
    /// `git diff` wrote it, counts every block above as applied too. Applied alone the block belongs somewhere
    /// else, so the number is worked out again from the old side, which is the file the patch is being applied
    /// to. (`git apply -R` has the same trouble, which is why the block is turned around here instead.)
    static func standalone(_ patch: Data, reversed: Bool) -> Data? {
        var lines: [Data] = []
        var start = patch.startIndex
        while start < patch.endIndex {
            let end = patch[start...].firstIndex(of: 0x0A).map { $0 + 1 } ?? patch.endIndex
            lines.append(patch.subdata(in: start..<end))
            start = end
        }
        guard let first = lines.first else { return nil }
        let fields = String(decoding: first, as: UTF8.self).split(separator: " ")
        guard fields.count >= 3, fields[0] == "@@", fields[1].hasPrefix("-"), fields[2].hasPrefix("+"),
              let old = range(fields[1]), let new = range(fields[2]) else { return nil }
        // A "\ No newline at end of file" note belongs to the line above it and travels with it.
        var minus: [Data] = [], plus: [Data] = []
        var lastWasPlus = false
        for line in lines.dropFirst() {
            switch line.first {
            case UInt8(ascii: "+"): plus.append(line); lastWasPlus = true
            case UInt8(ascii: "-"): minus.append(line); lastWasPlus = false
            case UInt8(ascii: "\\"): if lastWasPlus { plus.append(line) } else { minus.append(line) }
            default: return nil
            }
        }
        func flipped(_ lines: [Data], to sign: Character) -> [Data] {
            lines.map { $0.first == UInt8(ascii: "\\") ? $0 : Data([sign.asciiValue ?? 0]) + $0.dropFirst() }
        }
        let from = reversed ? new : old, to = reversed ? old : new
        // "-a,0" means "after line a"; a side with lines names its first line.
        let target = to.count == 0 ? (from.count == 0 ? from.start : from.start - 1) : (from.count == 0 ? from.start + 1 : from.start)
        let header = "@@ -\(from.start),\(from.count) +\(target),\(to.count) @@\n"
        let body = reversed ? flipped(plus, to: "-") + flipped(minus, to: "+") : minus + plus
        return ([Data(header.utf8)] + body).reduce(Data(), +)
    }

    /// Applies one block through a patch file holding the diff's own header and that block alone.
    /// Runs on the calling thread, which must not be the main thread.
    func apply(_ action: BlockAction, hunk index: Int, root: URL) -> GitResult {
        guard canPatchBlocks, hunks.indices.contains(index) else {
            return GitResult(status: -1, output: "", error: "This block cannot be applied on its own.")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("feather-\(UUID().uuidString).patch")
        defer { try? FileManager.default.removeItem(at: file) }
        guard let block = FileDiff.standalone(hunks[index].patch, reversed: action != .stage) else {
            return GitResult(status: -1, output: "", error: "This block could not be made into a patch of its own.")
        }
        do { try (header + block).write(to: file) } catch {
            return GitResult(status: -1, output: "", error: error.localizedDescription)
        }
        return Git.runSync(action.arguments + [file.path], in: root)
    }
}
