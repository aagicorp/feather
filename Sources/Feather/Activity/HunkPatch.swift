import Foundation

/// Taking one block of changes back out of a file without asking git: the block's "+" lines are looked for where
/// the block says they are and, if they are all there, swapped for its "-" lines. Everything is bytes, so line
/// endings ("\r\n" stays "\r\n") and a missing newline at the end of the file come through untouched, and a
/// block that no longer matches the file is refused rather than landing somewhere else.
enum HunkPatch {
    struct Result: Equatable {
        /// The whole file with the block undone.
        let data: Data
        /// The bytes of the input that were swapped out (empty for a block that only added nothing, i.e. the
        /// place the old lines went back in).
        let replaced: Range<Int>
        /// The bytes that went in instead: the block's old lines.
        let replacement: Data
    }

    /// The block's old ("-") and new ("+") lines, each with the newline it had in the file. A "\ No newline at end
    /// of file" note takes the newline off the line above it.
    static func sides(of patch: Data) -> (old: [Data], new: [Data])? {
        var old: [Data] = [], new: [Data] = []
        var lastWasNew: Bool?
        var start = patch.startIndex
        var isFirst = true
        while start < patch.endIndex {
            let end = patch[start...].firstIndex(of: 0x0A).map { $0 + 1 } ?? patch.endIndex
            let line = patch.subdata(in: start..<end)
            start = end
            if isFirst {
                isFirst = false
                guard line.starts(with: Array("@@ -".utf8)) else { return nil }
                continue
            }
            var body = line.dropFirst()
            if body.last != 0x0A { body.append(0x0A) }          // the patch itself may stop without a newline
            switch line.first {
            case UInt8(ascii: "+"): new.append(Data(body)); lastWasNew = true
            case UInt8(ascii: "-"): old.append(Data(body)); lastWasNew = false
            case UInt8(ascii: "\\"):
                switch lastWasNew {
                case true?: new[new.count - 1].removeLast()
                case false?: old[old.count - 1].removeLast()
                case nil: return nil
                }
            default: return nil
            }
        }
        return (old, new)
    }

    /// Where each line begins, and one more entry for the end of the data, splitting on the newline byte alone
    /// (the same cut `FileDiff.lines` makes, so line numbers agree with the diff).
    private static func lineStarts(of data: Data) -> [Int] {
        var starts = [0]
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for (index, byte) in bytes.enumerated() where byte == 0x0A { starts.append(index + 1) }
        }
        // "a\nb\n" has two lines, not three: a final newline does not start another one.
        if let last = data.last, last == 0x0A { starts.removeLast() }
        starts.append(data.count)
        return starts
    }

    /// The file with the block undone, or nil when the block's new lines are not where it says they are.
    static func undo(_ hunk: DiffHunk, in data: Data) -> Result? {
        guard let (old, new) = sides(of: hunk.patch), old.count == hunk.oldCount, new.count == hunk.newCount else { return nil }
        let starts = lineStarts(of: data)
        let lineCount = starts.count - 1
        // A block that only takes lines away names the line it goes in front of; one with new lines names its first.
        let first = hunk.newStart
        guard first >= 0, first + hunk.newCount <= lineCount || (hunk.newCount == 0 && first <= lineCount) else { return nil }
        let lower = starts[first]
        let upper = hunk.newCount == 0 ? lower : starts[first + hunk.newCount]
        let current = data.subdata(in: (data.startIndex + lower)..<(data.startIndex + upper))
        guard current == new.reduce(Data(), +) else { return nil }
        let replacement = old.reduce(Data(), +)
        var result = Data(capacity: data.count - current.count + replacement.count)
        result.append(data.prefix(lower))
        result.append(replacement)
        result.append(data.suffix(from: data.startIndex + upper))
        return Result(data: result, replaced: lower..<upper, replacement: replacement)
    }

    /// The same undo as one edit to an open document's text, in UTF-16 offsets, so the editor can make it as a step
    /// of its own undo history. Nil when the text does not hold the block as the disk does (unsaved edits around it),
    /// or for an encoding where a newline is not one byte.
    static func edit(for hunk: DiffHunk, in text: String, encoding: String.Encoding) -> RangeEdit? {
        guard [.utf8, .ascii, .isoLatin1].contains(encoding), let data = text.data(using: encoding),
              let result = undo(hunk, in: data),
              let before = String(data: data.prefix(result.replaced.lowerBound), encoding: encoding),
              let removed = String(data: data.subdata(in: result.replaced), encoding: encoding),
              let inserted = String(data: result.replacement, encoding: encoding) else { return nil }
        return RangeEdit(range: NSRange(location: before.utf16.count, length: removed.utf16.count), text: inserted)
    }
}
