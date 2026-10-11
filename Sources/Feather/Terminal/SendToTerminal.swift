import AppKit

/// What the two Send to Terminal commands type. Both read the editor that is already on screen; neither builds one.
enum TerminalText {
    /// The selected text, or the whole line the caret is on, ending in exactly one Return.
    static func selectionOrLine(of tab: EditorTab?) -> String? {
        guard let tab, !tab.isPreviewing, let textView = tab.editorIfLoaded?.textView else { return nil }
        let ns = textView.textContents
        var range = textView.selectedRange()
        if range.length == 0 { range = ns.lineRange(for: range) }
        var text = ns.substring(with: range).replacingOccurrences(of: "\r\n", with: "\n")
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return text + "\n"
    }

    /// `src/App.tsx:12-30` for a selection, `src/App.tsx:12` for a caret; relative to the project when the file is
    /// inside it, and quoted if a shell would otherwise split it.
    static func fileReference(of tab: EditorTab?, root: URL?) -> String? {
        guard let tab, let url = tab.url else { return nil }
        var reference = relativePath(of: url, root: root)
        if !tab.isPreviewing, let editor = tab.editorIfLoaded {
            let range = editor.textView.selectedRange()
            let first = editor.position(of: range.location).line + 1
            var last = editor.position(of: NSMaxRange(range)).line + 1
            // A selection of whole lines ends at the start of the line after them; that line is not part of it.
            if range.length > 0, last > first, editor.position(of: NSMaxRange(range)).character == 0 { last -= 1 }
            reference += last > first ? ":\(first)-\(last)" : ":\(first)"
        }
        return DropTerminalView.shellQuoted(reference)
    }

    static func relativePath(of url: URL, root: URL?) -> String {
        let path = url.standardizedFileURL.path
        guard let rootPath = root?.standardizedFileURL.path, path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    /// What Fix This types at the assistant's prompt: one plain sentence naming the place and the message, e.g.
    /// `Fix this error in src/App.tsx:42: Type 'string' is not assignable to type 'number'.` and then a space.
    /// It is never entered, so the user can add to it; anything that could act as a key press (a newline, a
    /// tab, an escape) is flattened to a space.
    static func fixRequest(for problem: ProblemItem, root: URL?) -> String {
        let place = relativePath(of: problem.url, root: root) + ":\(problem.line + 1)"
        let lead: String
        if let tag = problem.tag {
            lead = "Take care of this \(tag) in \(place)"
        } else {
            lead = "Fix this \(problem.severity == 1 ? "error" : "warning") in \(place)"
        }
        let message = String(String.UnicodeScalarView(problem.message.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
        })).trimmingCharacters(in: .whitespaces)
        return (message.isEmpty ? lead + "." : lead + ": " + message) + " "
    }
}
