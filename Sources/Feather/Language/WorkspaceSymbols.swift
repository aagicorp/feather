import AppKit

/// Go to Symbol in Workspace (⌘T): every function, class and type in the project in one list, found the way
/// Go to Symbol in File finds them without a language server: by the shape of the line (SymbolOutline). So it
/// works for TypeScript, Python and Java with nothing installed, which is how most of Feather's users run it.
///
/// The index is built on a background queue the first time it is asked for and kept per file by modification
/// date, so a later search re-reads only the files that changed. A window has one; it is dropped with the window.
final class WorkspaceSymbolIndex {
    struct Entry {
        let symbol: LSPSymbol
        /// Relative to the project folder.
        let path: String
    }

    private struct FileEntry {
        let modified: Date
        let symbols: [LSPSymbol]
    }

    private var files: [String: FileEntry] = [:]          // touched on `queue` only
    private let queue = DispatchQueue(label: "feather.workspace-symbols", qos: .userInitiated)
    private var generation = 0

    /// Files bigger than this are skipped: they are generated or data, and a scan of them is slow for nothing.
    static let maxFileSize = 512 * 1024
    static let maxFiles = 8000
    /// What SymbolOutline has patterns for. Markdown is left out: its headings are not what ⌘T is for.
    static let extensions: Set<String> = ["ts", "tsx", "js", "jsx", "mjs", "cjs", "vue", "svelte", "py", "pyw", "rb", "go",
                                          "java", "kt", "kts", "scala", "swift", "rs", "c", "cc", "cpp", "h", "hpp", "m", "mm",
                                          "cs", "php", "dart", "sh", "bash", "zsh", "lua", "ex", "exs", "pl"]

    /// Every symbol in the project, sorted by file, on the main queue. A newer call supersedes an older one
    /// that has not answered yet; only the newest answers.
    func entries(root: URL, completion: @escaping ([Entry]) -> Void) {
        generation += 1
        let generation = self.generation
        queue.async { [weak self] in
            guard let self else { return }
            let entries = self.scan(root: root) { self.generation != generation }
            DispatchQueue.main.async { if self.generation == generation { completion(entries) } }
        }
    }

    /// Runs on `queue`. `isStale` lets a superseded scan give up early.
    private func scan(root: URL, isStale: () -> Bool) -> [Entry] {
        let paths = ProjectFiles.list(root: root, limit: 40_000).filter {
            WorkspaceSymbolIndex.extensions.contains(($0 as NSString).pathExtension.lowercased())
        }
        let manager = FileManager.default
        var seen = Set<String>()
        var entries: [Entry] = []
        for (index, path) in paths.prefix(WorkspaceSymbolIndex.maxFiles).enumerated() {
            if index % 64 == 0, isStale() { return [] }
            let url = root.appendingPathComponent(path)
            guard let attributes = try? manager.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date,
                  (attributes[.size] as? Int ?? 0) <= WorkspaceSymbolIndex.maxFileSize else { continue }
            seen.insert(path)
            let symbols: [LSPSymbol]
            if let cached = files[path], cached.modified == modified {
                symbols = cached.symbols
            } else {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                symbols = SymbolOutline.scan(text, fileExtension: url.pathExtension)
                files[path] = FileEntry(modified: modified, symbols: symbols)
            }
            for symbol in symbols { entries.append(Entry(symbol: symbol, path: path)) }
        }
        files = files.filter { seen.contains($0.key) }        // deleted files leave the index
        return entries
    }

    /// The row for a symbol: its name, then its kind, file and line in grey.
    static func item(for entry: Entry) -> FilterPanelController.Item {
        var detail = SymbolOutline.kindName(entry.symbol.kind)
        if let container = entry.symbol.container, !container.isEmpty { detail += " in " + container }
        detail += (detail.isEmpty ? "" : "  ") + entry.path + ":\(entry.symbol.line + 1)"
        return FilterPanelController.Item(title: entry.symbol.name, detail: detail)
    }
}

extension MainWindowController {
    /// Go ▸ Go to Symbol in Workspace… (⌘T), and what "#" in Quick Open opens.
    @objc func goToSymbolInWorkspace(_ sender: Any?) { showWorkspaceSymbols(typed: "") }

    func showWorkspaceSymbols(typed: String) {
        guard let window, let root = projectRoot else { NSSound.beep(); return }
        let panel = workspaceSymbolPanel
        panel.show(over: window, items: [FilterPanelController.Item(title: "Looking through the project…", detail: "")],
                   typed: typed) { _ in }
        workspaceSymbols.entries(root: root) { [weak self, weak panel] entries in
            guard let self, let panel, panel.isVisible else { return }
            let items = entries.map(WorkspaceSymbolIndex.item)
            panel.setItems(items.isEmpty ? [FilterPanelController.Item(title: "No functions or types found in this project", detail: "")] : items)
            panel.onChoose = { [weak self] index in
                guard let self, entries.indices.contains(index) else { return }
                let entry = entries[index]
                let symbol = entry.symbol
                let end = symbol.character + (symbol.name as NSString).length
                self.navigate(to: LSPLocation(url: root.appendingPathComponent(entry.path), line: symbol.line, character: symbol.character,
                                              endLine: symbol.line, endCharacter: end))
            }
        }
    }

    /// What typing "#", "@" or ":" first in Quick Open means, as in VS Code: a symbol anywhere, a symbol in this
    /// file, a line number. The rest of what was typed carries over.
    func quickOpenPrefix(_ prefix: Character, typed: String) {
        switch prefix {
        case "#": showWorkspaceSymbols(typed: typed)
        case "@": editorArea.showSymbolPicker(typed: typed)
        case ":": goToLine(typed: typed)
        default: break
        }
    }
}
