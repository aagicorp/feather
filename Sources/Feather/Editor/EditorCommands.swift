import AppKit

// Commands of an editor group that talk to the language server about the whole file: formatting, and the
// outline behind Go to Symbol.

extension EditorAreaViewController {
    // MARK: - Formatting

    /// How long Save waits for the formatter. A server that has hung must not stand between you and your file.
    private static let formatOnSaveTimeout: TimeInterval = 2

    /// Asks the server to format the current file (or the selected lines of it) and makes its edits as one undo
    /// step. `isStillWanted` is asked when the answer arrives; `completion` hears whether anything was applied.
    func formatCurrentDocument(selectionOnly: Bool, isStillWanted: @escaping () -> Bool = { true },
                               completion: ((Bool) -> Void)? = nil) {
        guard let tab = currentTab, !tab.isPreviewing, let url = tab.url, lsp.canFormat(url, selection: selectionOnly) else {
            // No server for this language, or one that does not format: say so rather than seem to have worked.
            if completion == nil { NSSound.beep() }
            completion?(false)
            return
        }
        let document = tab.document
        var range: (startLine: Int, startCharacter: Int, endLine: Int, endCharacter: Int)?
        if selectionOnly {
            // With nothing selected, the line the caret is on.
            let editor = tab.editor
            let ns = document.storage.mutableString
            var selection = editor.textView.selectedRange()
            if selection.length == 0 { selection = ns.lineRange(for: selection) }
            let start = editor.position(of: selection.location), end = editor.position(of: NSMaxRange(selection))
            range = (start.line, start.character, end.line, end.character)
        }
        let version = document.changeCount
        lsp.formatting(url, range: range) { [weak self, weak tab] edits in
            // Edits are positions in the text that was sent. If it has changed since, they point at the wrong places.
            guard let self, let edits, isStillWanted(), document.changeCount == version,
                  let batch = DocumentEdits.normalised(TextEdits.ranges(for: edits, in: document.storage.mutableString),
                                                       in: document.storage.mutableString) else {
                if completion == nil, edits == nil { NSSound.beep() }
                completion?(false)
                return
            }
            let name = selectionOnly ? "Format Selection" : "Format Document"
            if let editor = tab?.editorIfLoaded ?? self.tabs.first(where: { $0.document === document })?.editorIfLoaded {
                editor.apply(batch, named: name)
            } else {
                document.apply(batch)
            }
            completion?(!batch.isEmpty)
        }
    }

    /// ⌘S arrives here before it reaches the window, because the group sits between the text view and the window
    /// in the responder chain. Formatting needs an answer from the server, so only this deliberate, one-file
    /// save waits for it; Save All, closing and quitting save at once, as they must.
    @objc func saveDocument(_ sender: Any?) {
        guard let document = currentTab?.document else { return }
        guard Settings.shared.formatOnSave, lsp.canFormat(document.url) else {
            store.save(document)
            return
        }
        var isWaiting = true
        let finish = { [weak self] in
            guard isWaiting else { return }
            isWaiting = false
            self?.store.save(document)
        }
        formatCurrentDocument(selectionOnly: false, isStillWanted: { isWaiting }) { _ in finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + EditorAreaViewController.formatOnSaveTimeout, execute: finish)
    }

    // MARK: - Go to Symbol

    func showSymbolPicker(typed: String = "") {
        guard let tab = currentTab, !tab.document.isMedia, let window = view.window else { NSSound.beep(); return }
        let document = tab.document
        var isShown = false
        let show: ([LSPSymbol]) -> Void = { [weak self, weak tab] symbols in
            guard let self, let tab, !isShown, self.currentTab === tab else { return }
            isShown = true
            guard !symbols.isEmpty else { NSSound.beep(); return }
            self.symbolPanel.show(over: window, items: symbols.map(EditorAreaViewController.pickerItem), typed: typed) { [weak self, weak tab] index in
                guard let self, let tab else { return }
                self.jump(to: symbols[index], in: tab)
            }
        }
        let scan = { SymbolOutline.scan(document.text, fileExtension: document.url?.pathExtension ?? "") }
        guard let url = document.url, lsp.canListSymbols(url) else { return show(scan()) }
        lsp.documentSymbols(url) { symbols in
            if let symbols, !symbols.isEmpty { show(symbols) } else { show(scan()) }
        }
        // A server busy indexing can take seconds; the file's own text can answer meanwhile.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if !isShown { show(scan()) } }
    }

    static func pickerItem(for symbol: LSPSymbol) -> FilterPanelController.Item {
        var detail = SymbolOutline.kindName(symbol.kind)
        if let container = symbol.container, !container.isEmpty { detail += (detail.isEmpty ? "" : " in ") + container }
        detail += (detail.isEmpty ? "" : "  ") + ":\(symbol.line + 1)"
        return FilterPanelController.Item(title: symbol.name, detail: detail, indent: symbol.depth)
    }

    /// The same road Go to Definition takes, so Back returns to where you were.
    private func jump(to symbol: LSPSymbol, in tab: EditorTab) {
        // A server may call a function "load(from:)"; only a plain name is known to be what stands in the text.
        let isPlainName = !symbol.name.contains { $0 == "(" || $0 == " " }
        let end = symbol.character + (isPlainName ? (symbol.name as NSString).length : 0)
        if let url = tab.url {
            onOpenLocation?(LSPLocation(url: url, line: symbol.line, character: symbol.character, endLine: symbol.line, endCharacter: end))
        } else if let index = tabs.firstIndex(where: { $0 === tab }) {
            // An untitled file has no address for the history to remember, but the jump itself still works.
            select(index)
            tab.editor.select(line: symbol.line, character: symbol.character, endLine: symbol.line, endCharacter: end)
        }
    }
}
