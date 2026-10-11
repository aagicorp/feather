import Foundation

/// One replacement in a document, in UTF-16 offsets into the text as it was before any of them is made.
struct RangeEdit: Equatable {
    let range: NSRange
    let text: String
}

/// Turning a batch of edits (from a formatter, or the tidying done on save) into something that can be applied
/// in one go without losing the caret.
enum DocumentEdits {
    /// In document order, with edits that change nothing dropped and the rest cut down to the part that really
    /// differs: some formatters answer with one edit replacing the entire file, and replacing text with itself
    /// would throw the caret to the end and mark every line as changed. Nil when the edits overlap or point
    /// outside the text, which means they were made for a different version of it.
    static func normalised(_ edits: [(NSRange, String)], in text: NSString) -> [RangeEdit]? {
        var result: [RangeEdit] = []
        var reach = 0
        // Stable, so several insertions at one place keep the order the server gave them.
        let ordered = edits.enumerated().sorted {
            $0.element.0.location != $1.element.0.location ? $0.element.0.location < $1.element.0.location : $0.offset < $1.offset
        }
        for (_, (range, replacement)) in ordered {
            guard range.location >= reach, NSMaxRange(range) <= text.length else { return nil }
            reach = NSMaxRange(range)
            let new = replacement as NSString
            var prefix = 0
            let shorter = min(range.length, new.length)
            while prefix < shorter, text.character(at: range.location + prefix) == new.character(at: prefix) { prefix += 1 }
            var suffix = 0
            while suffix < shorter - prefix,
                  text.character(at: NSMaxRange(range) - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
            let trimmed = NSRange(location: range.location + prefix, length: range.length - prefix - suffix)
            let changed = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
            if trimmed.length == 0, changed.isEmpty { continue }
            // Two insertions at one place are one insertion.
            if let last = result.last, last.range.length == 0, trimmed.length == 0, last.range.location == trimmed.location {
                result[result.count - 1] = RangeEdit(range: trimmed, text: last.text + changed)
            } else {
                result.append(RangeEdit(range: trimmed, text: changed))
            }
        }
        return result
    }

    /// Where a caret at `location` ends up once `edits` (normalised) are made. `rewritten` is true when the caret
    /// stood inside text that was replaced by several lines, where an offset no longer means anything and the
    /// caller does better keeping the caret's line and column.
    static func map(_ location: Int, through edits: [RangeEdit]) -> (location: Int, rewritten: Bool) {
        var shift = 0
        for edit in edits {
            if location <= edit.range.location { break }
            let newLength = (edit.text as NSString).length
            if location >= NSMaxRange(edit.range) {
                shift += newLength - edit.range.length
            } else {
                let inside = min(location - edit.range.location, newLength)
                return (edit.range.location + shift + inside, edit.text.contains("\n"))
            }
        }
        return (location + shift, false)
    }

    /// The reverse batch: applied to the edited text, it gives back the original.
    static func inverse(of edits: [RangeEdit], in text: NSString) -> [RangeEdit] {
        var shift = 0
        return edits.map { edit in
            let newLength = (edit.text as NSString).length
            defer { shift += newLength - edit.range.length }
            return RangeEdit(range: NSRange(location: edit.range.location + shift, length: newLength),
                             text: text.substring(with: edit.range))
        }
    }

    /// What saving changes: spaces and tabs at the ends of lines go, and a file that does not end in a newline
    /// gets one. No line is added or removed above the caret, so the caret stays on its line.
    static func tidyingForSave(_ text: NSString, trimTrailingWhitespace: Bool, insertFinalNewline: Bool) -> [RangeEdit] {
        var edits: [RangeEdit] = []
        if trimTrailingWhitespace {
            var lineStart = 0
            while lineStart < text.length {
                var lineEnd = 0, contentsEnd = 0
                text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: lineStart, length: 0))
                var keep = contentsEnd
                while keep > lineStart, text.character(at: keep - 1) == 0x20 || text.character(at: keep - 1) == 0x09 { keep -= 1 }
                if keep < contentsEnd { edits.append(RangeEdit(range: NSRange(location: keep, length: contentsEnd - keep), text: "")) }
                lineStart = lineEnd
            }
        }
        if insertFinalNewline, text.length > 0, text.character(at: text.length - 1) != 0x0A {
            edits.append(RangeEdit(range: NSRange(location: text.length, length: 0), text: "\n"))
        }
        return edits
    }
}
