import AppKit

/// One open file. Split editors showing the same file share a single document, so they share
/// its text storage, undo history, unsaved state, diagnostics and git baseline.
final class TextDocument {
    static let stateDidChange = Notification.Name("FeatherDocumentStateDidChange")           // dirty flag, URL
    static let diagnosticsDidChange = Notification.Name("FeatherDocumentDiagnosticsDidChange")
    static let gitBaseDidChange = Notification.Name("FeatherDocumentGitBaseDidChange")

    let storage = NSTextStorage()
    let undoManager = UndoManager()
    var encoding: String.Encoding = .utf8
    /// True for an image, PDF, audio or video file. Such a document has no text: it only gives the tab an identity,
    /// and saving it would replace the file with nothing, so every save path refuses it.
    fileprivate(set) var isMedia = false
    fileprivate(set) var useCount = 0
    fileprivate var onTextChange: (() -> Void)?
    private var isLoading = false

    var url: URL? {
        didSet {
            language = url.flatMap(Language.detect)
            post(TextDocument.stateDidChange)
        }
    }
    /// Worked out when the URL changes, not on every highlight pass and cursor move.
    private(set) var language: Language? {
        didSet {
            // Another grammar (or none) for the file: the old tree is no use to it.
            if language?.treeSitterLanguage != oldValue?.treeSitterLanguage { syntaxTreeIfLoaded = nil; syntaxTreeTried = false }
        }
    }

    /// The syntax tree behind colouring and folding, for a language with a grammar. Made the first time an editor
    /// asks, so a window with nothing open loads no grammar; ask for `syntaxTreeIfLoaded` where making it is not wanted.
    private(set) var syntaxTreeIfLoaded: SyntaxTreeController?
    private var syntaxTreeTried = false
    var syntaxTree: SyntaxTreeController? {
        if !syntaxTreeTried {
            syntaxTreeTried = true
            syntaxTreeIfLoaded = isMedia ? nil : SyntaxTreeController.make(for: storage, language: language)
        }
        return syntaxTreeIfLoaded
    }
    /// The file's modification date and size when it was last read or written, so checking for outside changes
    /// is a stat call rather than reading the file again.
    fileprivate var diskStamp: (date: Date, size: Int)?
    /// Which font/theme/tab-width the storage's base attributes were last set for. Several panes share one
    /// storage; only the first needs to style it, and re-styling invalidates the layout of all of them.
    var attributeSignature: String?
    var isDirty = false { didSet { if isDirty != oldValue { post(TextDocument.stateDidChange) } } }
    var diagnostics: [LSPDiagnostic] = [] { didSet { post(TextDocument.diagnosticsDidChange) } }
    /// Only announced when it really changed; every pane re-runs its line diff when it does.
    var gitBaseLines: [String]? { didSet { if gitBaseLines != oldValue { post(TextDocument.gitBaseDidChange) } } }

    /// What `.editorconfig` says about this file, worked out when it is opened, moved or saved. Nil for an untitled
    /// file and wherever no `.editorconfig` applies; then the user's settings decide. See `indentation`.
    var editorConfig: EditorConfigProperties? {
        didSet { if editorConfig != oldValue { post(TextDocument.stateDidChange) } }
    }
    /// The window's store, so an edit can reach its auto save without anyone observing every keystroke.
    fileprivate(set) weak var store: DocumentStore?

    /// Goes up with every edit. An answer that took a while to arrive (formatting) compares it with the value it
    /// set out with, and is dropped if the text has moved on.
    private(set) var changeCount = 0

    /// Set for a tab that is not a file of its own (a diff tab): what its tab says instead of a file name.
    var displayTitle: String?
    /// What the tab and the breadcrumb show in place of a file icon, for a document that is not a file (an API
    /// request shows its method). Wider than 16 points is fine; the tab makes room.
    var tabIcon: NSImage? { didSet { post(TextDocument.stateDidChange) } }
    var title: String { displayTitle ?? url?.lastPathComponent ?? "Untitled" }
    var text: String { storage.string }

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(storageDidProcessEditing(_:)),
                                               name: NSTextStorage.didProcessEditingNotification, object: storage)
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: self)
    }

    @objc private func storageDidProcessEditing(_ notification: Notification) {
        guard storage.editedMask.contains(.editedCharacters) else { return }
        changeCount += 1
        guard !isLoading else { return }
        isDirty = true
        onTextChange?()
        store?.autoSave.documentEdited(self)
    }

    fileprivate func load(_ text: String) {
        isLoading = true
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        isLoading = false
        attributeSignature = nil            // fresh text carries no styling yet
        undoManager.removeAllActions()
    }

    /// Replaces the whole text as a single undoable step. Used for edits that do not come from a text view.
    func replaceAll(with text: String) {
        let previous = storage.string
        guard previous != text else { return }
        undoManager.registerUndo(withTarget: self) { $0.replaceAll(with: previous) }
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
    }

    /// Makes a batch of edits (normalised: in order, not overlapping) as one undoable step, without a text view.
    /// For a document no editor is showing; one that has an editor goes through `EditorView.apply`, so the
    /// text view's own undo and caret handling stay in charge.
    func apply(_ edits: [RangeEdit]) {
        guard !edits.isEmpty else { return }
        let inverse = DocumentEdits.inverse(of: edits, in: storage.mutableString)
        undoManager.registerUndo(withTarget: self) { $0.apply(inverse) }
        storage.beginEditing()
        // Bottom-up, so each edit's offsets still mean what they meant when it was worked out.
        for edit in edits.reversed() { storage.replaceCharacters(in: edit.range, with: edit.text) }
        storage.endEditing()
    }
}

enum FileLoadError: LocalizedError {
    case tooLarge, binary

    var errorDescription: String? {
        switch self {
        case .tooLarge: return "This file is larger than 50 MB, which Feather does not open yet."
        case .binary: return "This looks like a binary file, so it cannot be shown as text."
        }
    }
}

/// All documents open in one window, shared by that window's editor groups.
final class DocumentStore {
    static let didSaveDocument = Notification.Name("FeatherDocumentStoreDidSave")
    let lsp: LSPManager
    var projectRoot: URL?
    /// Runs just before a document is written, from every path that saves: ⌘S, Save All, closing a tab, running.
    /// The editor groups use it to tidy the text (trailing whitespace, final newline) as an undoable edit.
    var willSave: ((TextDocument) -> Void)?
    private var documents: [TextDocument] = []
    /// Saves on its own, when the setting asks for it. See `AutoSave.swift`.
    private(set) lazy var autoSave = AutoSaveController(store: self)
    /// True while a save was started by auto save rather than by the user, for `willSave` to go easy: the tidy
    /// leaves the line being typed on alone.
    private(set) var isAutoSaving = false

    init(lsp: LSPManager) {
        self.lsp = lsp
        lsp.onDiagnostics = { [weak self] url, items in self?.existingDocument(at: url)?.diagnostics = items }
        NotificationCenter.default.addObserver(forName: EditorConfigStore.didInvalidate, object: nil, queue: .main) { [weak self] _ in
            self?.documents.forEach { self?.resolveEditorConfig($0) }
        }
        _ = autoSave            // it listens for the app going to the background from the start
    }

    var dirtyDocuments: [TextDocument] { documents.filter(\.isDirty) }

    func existingDocument(at url: URL) -> TextDocument? {
        documents.first { $0.url == url }
    }

    func text(of url: URL) -> String? {
        existingDocument(at: url)?.text ?? (try? String(contentsOf: url, encoding: .utf8))
    }

    // MARK: - Opening and closing

    /// Each tab showing a document holds one use of it; the document closes when the last tab does.
    func open(_ url: URL) throws -> TextDocument {
        let url = url.standardizedFileURL
        if let existing = existingDocument(at: url) {
            existing.useCount += 1
            return existing
        }
        let (text, encoding) = try DocumentStore.read(url)
        let document = TextDocument()
        document.encoding = encoding
        document.load(text)
        document.url = url
        document.diskStamp = DocumentStore.stamp(of: url)
        document.useCount = 1
        document.store = self
        documents.append(document)
        connect(document)
        return document
    }

    /// A tab for a file that is looked at rather than edited.
    func openMedia(_ url: URL) -> TextDocument {
        let url = url.standardizedFileURL
        if let existing = existingDocument(at: url) {
            existing.useCount += 1
            return existing
        }
        let document = TextDocument()
        document.isMedia = true
        document.url = url
        document.useCount = 1
        documents.append(document)
        return document
    }

    /// The identity of a tab that shows a view rather than a file, such as a diff. It has no text and is never
    /// saved, like a media document; `url` only tells one such tab from another and need not exist on disk.
    func openVirtual(_ url: URL, title: String) -> TextDocument {
        if let existing = existingDocument(at: url) {
            existing.useCount += 1
            return existing
        }
        let document = TextDocument()
        document.isMedia = true
        document.displayTitle = title
        document.url = url
        document.useCount = 1
        documents.append(document)
        return document
    }

    func newUntitled() -> TextDocument {
        let document = TextDocument()
        document.useCount = 1
        document.store = self
        documents.append(document)
        return document
    }

    func retain(_ document: TextDocument) {
        document.useCount += 1
    }

    func release(_ document: TextDocument) {
        document.useCount -= 1
        guard document.useCount <= 0 else { return }
        if let url = document.url { lsp.close(url) }
        document.onTextChange = nil
        documents.removeAll { $0 === document }
    }

    /// Registers the file with the language server and loads its committed version for change markers.
    private func connect(_ document: TextDocument) {
        guard let url = document.url else { return }
        resolveEditorConfig(document)
        lsp.open(url, length: document.storage.length) { [weak document] in document?.text }
        document.onTextChange = { [weak self, weak document] in
            guard let url = document?.url else { return }
            self?.lsp.changed(url)
        }
        refreshGitBase(document)
    }

    /// After a pull, merge or checkout the files on disk may have changed underneath us. Documents without
    /// unsaved edits are reloaded; ones with edits are left alone so nothing the user typed is lost.
    func syncWithDisk(refreshGitBases: Bool = true) {
        for document in documents where !document.isMedia {
            guard let url = document.url else { continue }
            // A stat first: the file is only read again when its date or size says it changed.
            if !document.isDirty, let stamp = DocumentStore.stamp(of: url),
               document.diskStamp.map({ $0.date != stamp.date || $0.size != stamp.size }) ?? true {
                document.diskStamp = stamp
                if let (text, encoding) = try? DocumentStore.read(url), text != document.text {
                    document.encoding = encoding
                    document.load(text)
                    lsp.changed(url)
                }
            }
            if refreshGitBases { refreshGitBase(document) }
        }
    }

    /// Gives up a document's unsaved edits for what is on disk now (the user agreed to that in Undo All). It is
    /// one undoable step, so ⌘Z in the file still brings the edits back.
    func revertToDisk(_ document: TextDocument) {
        guard !document.isMedia, let url = document.url, let (text, encoding) = try? DocumentStore.read(url) else { return }
        document.encoding = encoding
        document.replaceAll(with: text)
        document.isDirty = false
        document.diskStamp = DocumentStore.stamp(of: url)
        lsp.changed(url)
    }

    /// Feather itself wrote the file with the document's knowledge (a review undid one block of it, in the file
    /// and in the document alike): the disk holds nothing the document does not know, so a later save is not
    /// warned about a change from outside.
    func noteWrittenToDisk(_ document: TextDocument) {
        guard let url = document.url else { return }
        document.diskStamp = DocumentStore.stamp(of: url)
    }

    /// Looks up what `.editorconfig` says for the document's file. Cheap: the parsed files are cached.
    func resolveEditorConfig(_ document: TextDocument) {
        guard !document.isMedia else { return }
        document.editorConfig = document.url.flatMap { EditorConfigStore.shared.properties(for: $0) }
    }

    /// True when the file is gone, or is no longer the one that was read or written last: someone else changed it.
    /// Saving over that is a decision for the user (⌘S), never for auto save.
    func isChangedOnDisk(_ document: TextDocument) -> Bool {
        guard let url = document.url, let known = document.diskStamp, let now = DocumentStore.stamp(of: url) else { return true }
        return known.date != now.date || known.size != now.size
    }

    private static func stamp(of url: URL) -> (date: Date, size: Int)? {
        // A URL remembers the values it was last asked for until the run loop turns; a file written a moment ago
        // by someone else must not be answered from memory.
        var url = url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let date = values.contentModificationDate else { return nil }
        return (date, values.fileSize ?? 0)
    }

    func refreshGitBase(_ document: TextDocument?) {
        guard let document, let url = document.url else { return }
        // Split into lines on the background thread; the assignment is a no-op when nothing changed.
        Git.headLines(of: url) { [weak document] lines in document?.gitBaseLines = lines }
    }

    private static func read(_ url: URL) throws -> (String, String.Encoding) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 50_000_000 else { throw FileLoadError.tooLarge }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return (text, .utf16)
        }
        guard !data.prefix(8192).contains(0) else { throw FileLoadError.binary }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        if let text = String(data: data, encoding: .isoLatin1) { return (text, .isoLatin1) }
        throw FileLoadError.binary
    }

    // MARK: - Saving

    /// What auto save calls: no format on save, no panels, no alerts. A save that fails leaves the document
    /// dirty, and the user's own ⌘S will say why.
    @discardableResult
    func saveQuietly(_ document: TextDocument) -> Bool {
        guard !document.isMedia, document.url != nil else { return false }
        isAutoSaving = true
        defer { isAutoSaving = false }
        return save(document, showsErrors: false)
    }

    /// The text as it goes to disk: with the line endings `.editorconfig` asks for, if it asks.
    static func textForDisk(_ text: String, lineEnding: EditorConfigProperties.LineEnding?) -> String {
        guard let lineEnding else { return text }
        // The common case, a file already in Unix line endings that should be, is a scan and no copy.
        if lineEnding == .lf, !text.utf16.contains(0x0D) { return text }
        let unix = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return lineEnding == .lf ? unix : unix.replacingOccurrences(of: "\n", with: lineEnding.string)
    }

    @discardableResult
    func save(_ document: TextDocument, showsErrors: Bool = true) -> Bool {
        guard !document.isMedia else { return true }
        guard let url = document.url else { return saveAs(document) }
        resolveEditorConfig(document)
        willSave?(document)
        do {
            let text = DocumentStore.textForDisk(document.text, lineEnding: document.editorConfig?.lineEnding)
            let wanted = document.editorConfig?.encoding ?? document.encoding
            let encoding = text.canBeConverted(to: wanted) ? wanted : .utf8
            try text.write(to: url, atomically: true, encoding: encoding)
            document.encoding = encoding
            document.isDirty = false
            lsp.saved(url)
            document.diskStamp = DocumentStore.stamp(of: url)
            // Every open file below it may now be indented differently.
            if url.lastPathComponent == ".editorconfig" { EditorConfigStore.shared.invalidate() }
            NotificationCenter.default.post(name: DocumentStore.didSaveDocument, object: self, userInfo: ["url": url])
            return true
        } catch {
            if showsErrors { NSAlert(error: error).runModal() }
            return false
        }
    }

    @discardableResult
    func saveAs(_ document: TextDocument) -> Bool {
        guard !document.isMedia else { NSSound.beep(); return false }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.title
        panel.directoryURL = document.url?.deletingLastPathComponent() ?? projectRoot
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL else { return false }
        if let other = existingDocument(at: url), other !== document {
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)” is already open in this window."
            alert.informativeText = "Close that tab first, or choose a different name."
            alert.runModal()
            return false
        }
        if let old = document.url { lsp.close(old) }
        document.url = url
        guard save(document) else { return false }
        connect(document)
        return true
    }

    /// A file or folder was renamed or moved in the explorer: the open documents that lived there follow it,
    /// keeping their unsaved changes and undo history, instead of pointing at a file that is gone.
    func fileMoved(from old: URL, to new: URL) {
        let oldPath = old.standardizedFileURL.path, newPath = new.standardizedFileURL.path
        for document in documents {
            guard let path = document.url?.standardizedFileURL.path else { continue }
            let moved: String
            if path == oldPath { moved = newPath }
            else if path.hasPrefix(oldPath + "/") { moved = newPath + path.dropFirst(oldPath.count) }
            else { continue }
            if let url = document.url { lsp.close(url) }
            document.url = URL(fileURLWithPath: moved)
            if !document.isMedia { connect(document) }
        }
    }

    func saveAll() -> Bool {
        for document in dirtyDocuments where !save(document) { return false }
        return true
    }

    /// Applies a language-server workspace edit. Open files change in memory (undoable, left unsaved);
    /// files that are not open are rewritten on disk.
    func apply(_ changes: [URL: [LSPTextEdit]]) {
        for (url, edits) in changes {
            if let document = existingDocument(at: url) {
                document.replaceAll(with: TextEdits.apply(edits, to: document.text))
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                try? TextEdits.apply(edits, to: text).write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
