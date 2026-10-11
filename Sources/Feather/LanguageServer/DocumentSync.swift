import Foundation

/// One replacement that turns the text a language server has into the text the editor has now. Lines and
/// characters are positions in the OLD text, counted in UTF-16 code units, which is what the protocol asks for.
struct DocumentEdit {
    let startLine: Int, startCharacter: Int
    let endLine: Int, endCharacter: Int
    let text: String
    /// The same edit as plain offsets: `oldRange` of the old text was replaced by `newLength` units.
    let oldRange: NSRange
    let newLength: Int

    var contentChange: [String: Any] {
        ["range": ["start": ["line": startLine, "character": startCharacter],
                   "end": ["line": endLine, "character": endCharacter]],
         "text": text]
    }
}

/// Incremental document sync. Typing changes a few characters of a file that may be thousands of lines long, so
/// the server is sent only what lies between the unchanged beginning and the unchanged end.
enum DocumentSync {
    /// Texts are compared as flat UTF-16 arrays: no Character decoding, and no bridging call per unit.
    static func utf16(_ text: String) -> [unichar] {
        let string = text as NSString
        let length = string.length
        return [unichar](unsafeUninitializedCapacity: length) { buffer, count in
            if let base = buffer.baseAddress { string.getCharacters(base, range: NSRange(location: 0, length: length)) }
            count = length
        }
    }

    /// Nil when the two texts are the same.
    static func edit(from old: [unichar], to new: [unichar]) -> DocumentEdit? {
        old.withUnsafeBufferPointer { old in new.withUnsafeBufferPointer { new in edit(from: old, to: new) } }
    }

    private static func edit(from old: UnsafeBufferPointer<unichar>, to new: UnsafeBufferPointer<unichar>) -> DocumentEdit? {
        let shorter = min(old.count, new.count)
        var prefix = 0
        while prefix < shorter, old[prefix] == new[prefix] { prefix += 1 }
        if prefix == old.count, prefix == new.count { return nil }

        // The edit must not start right after a carriage return: in "\r\n" that position is inside a line ending
        // and has no line/character, and after a lone "\r" servers disagree about which line it is on. Nor may it
        // start inside a surrogate pair (an emoji whose second half changed), which is half a character.
        if prefix > 0, old[prefix - 1] == 0x0D { prefix -= 1 }
        if prefix > 0, isHighSurrogate(old[prefix - 1]) { prefix -= 1 }

        var suffix = 0
        while suffix < shorter - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        // The same two rules for where the edit ends.
        if suffix > 0, isLowSurrogate(old[old.count - suffix]) { suffix -= 1 }
        if suffix > 0, old[old.count - suffix] == 0x0A, old.count - suffix > 0, old[old.count - suffix - 1] == 0x0D { suffix -= 1 }

        let oldEnd = old.count - suffix, newEnd = new.count - suffix
        // Only the text before the end of the edit is scanned for line breaks; the unchanged tail never is.
        var line = 0, lineStart = 0
        advance(in: old, from: 0, to: prefix, line: &line, lineStart: &lineStart)
        let startLine = line, startCharacter = prefix - lineStart
        advance(in: old, from: prefix, to: oldEnd, line: &line, lineStart: &lineStart)

        let replacement = new.baseAddress.map { String(utf16CodeUnits: $0 + prefix, count: newEnd - prefix) } ?? ""
        return DocumentEdit(startLine: startLine, startCharacter: startCharacter,
                            endLine: line, endCharacter: oldEnd - lineStart, text: replacement,
                            oldRange: NSRange(location: prefix, length: oldEnd - prefix), newLength: newEnd - prefix)
    }

    /// The protocol counts "\n", "\r\n" and a lone "\r" as one line ending each.
    private static func advance(in text: UnsafeBufferPointer<unichar>, from: Int, to end: Int,
                                line: inout Int, lineStart: inout Int) {
        var index = from
        while index < end {
            let unit = text[index]
            index += 1
            if unit == 0x0D, index < end, text[index] == 0x0A { index += 1 }
            if unit == 0x0A || unit == 0x0D {
                line += 1
                lineStart = index
            }
        }
    }

    private static func isHighSurrogate(_ unit: unichar) -> Bool { unit & 0xFC00 == 0xD800 }
    private static func isLowSurrogate(_ unit: unichar) -> Bool { unit & 0xFC00 == 0xDC00 }
}
