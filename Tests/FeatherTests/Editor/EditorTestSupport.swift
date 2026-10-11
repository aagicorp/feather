import AppKit
import XCTest
@testable import Feather

/// A `CodeTextView` that lives without a window: its own storage, layout manager and container, and an undo
/// manager handed to it through the delegate, the way `EditorView` hands it the document's. Enough for every
/// command that only reads and edits the text; nothing here is ever drawn.
final class HeadlessEditor: NSObject, NSTextViewDelegate {
    let storage: NSTextStorage
    let layoutManager = NSLayoutManager()
    let container: NSTextContainer
    let textView: CodeTextView
    let gutter = GutterView(frame: NSRect(x: 0, y: 0, width: 44, height: 600))
    let undo = UndoManager()
    let folding: FoldingController

    init(_ text: String) {
        storage = NSTextStorage(string: text)
        storage.addLayoutManager(layoutManager)
        container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        folding = FoldingController(textView: textView, gutter: gutter)
        super.init()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.delegate = self
        textView.folds = folding
        gutter.textView = textView
        gutter.folding = folding
        layoutManager.delegate = folding
        // What EditorView does for the gutter: keep its line table in step with every edit.
        NotificationCenter.default.addObserver(self, selector: #selector(storageDidChange(_:)),
                                               name: NSTextStorage.didProcessEditingNotification, object: storage)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func storageDidChange(_ notification: Notification) {
        guard storage.editedMask.contains(.editedCharacters) else { return }
        gutter.applyEdit(storage.editedRange, delta: storage.changeInLength)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    var text: String { storage.string }
    var selection: NSRange { textView.selectedRange() }

    func select(_ location: Int, _ length: Int = 0) { textView.setSelectedRange(NSRange(location: location, length: length)) }

    /// Types `text` the way a key press does, through `insertText`, so pairing and multi-cursor apply.
    func type(_ text: String) { textView.insertText(text, replacementRange: textView.selectedRange()) }

    /// Sends a key command the way the responder chain does.
    func command(_ name: String) { textView.doCommand(by: NSSelectorFromString(name)) }
}
