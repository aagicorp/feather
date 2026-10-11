import XCTest
@testable import Feather

/// Covers `TextDocument` and `DocumentStore` (Editor/TextDocument.swift): reading files and their encoding,
/// the dirty flag and change count, undoable whole-text and batch edits, saving with the line endings and
/// encoding `.editorconfig` asks for, noticing outside changes by modification date and size, following moved
/// files, and the media/virtual documents that must never be written.
final class TextDocumentTests: XCTestCase {
    private var root: URL!
    private var store: DocumentStore!

    override func setUp() {
        super.setUp()
        root = TestSupport.temporaryDirectory("feather-document")
        let lsp = LSPManager()
        lsp.isAllowed = false                   // no language server is ever started from here
        store = DocumentStore(lsp: lsp)
        store.projectRoot = root
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func file(_ name: String, _ text: String) throws -> URL {
        try TestSupport.write([name: text], under: root)
        return root.appendingPathComponent(name)
    }

    private func edit(_ document: TextDocument, _ range: NSRange, _ text: String) {
        document.storage.replaceCharacters(in: range, with: text)
    }

    // MARK: - Opening

    func testOpenReadsTextDetectsLanguageAndStartsClean() throws {
        let url = try file("a.rb", "puts 1\n")
        let document = try store.open(url)
        XCTAssertEqual(document.text, "puts 1\n")
        XCTAssertEqual(document.encoding, .utf8)
        XCTAssertEqual(document.language?.name, "Ruby")
        XCTAssertEqual(document.title, "a.rb")
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(document.isMedia)
        XCTAssertEqual(document.useCount, 1)
        XCTAssertFalse(document.undoManager.canUndo)
        XCTAssertTrue(store.existingDocument(at: url) === document)
    }

    func testOpeningTheSameFileTwiceSharesOneDocument() throws {
        let url = try file("a.txt", "x")
        let first = try store.open(url)
        let second = try store.open(URL(fileURLWithPath: url.path))       // a different spelling of the same URL
        XCTAssertTrue(first === second)
        XCTAssertEqual(first.useCount, 2)
        store.release(first)
        XCTAssertNotNil(store.existingDocument(at: url))
        store.release(first)
        XCTAssertNil(store.existingDocument(at: url))
        XCTAssertFalse(try store.open(url) === first)
    }

    func testRetainCountsAUse() throws {
        let document = try store.open(try file("a.txt", "x"))
        store.retain(document)
        XCTAssertEqual(document.useCount, 2)
    }

    func testEditsMarkTheDocumentDirtyAndCountChanges() throws {
        let document = try store.open(try file("a.txt", "abc"))
        let before = document.changeCount
        let changes = expectation(forNotification: TextDocument.stateDidChange, object: document)
        edit(document, NSRange(location: 3, length: 0), "d")
        edit(document, NSRange(location: 0, length: 1), "")
        wait(for: [changes], timeout: 1)                    // once: the flag flipped one time for two edits
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(document.changeCount, before + 2)
        XCTAssertEqual(document.text, "bcd")
        XCTAssertEqual(store.dirtyDocuments.map(\.title), ["a.txt"])
    }

    func testTextOfPrefersTheOpenDocumentOverTheDisk() throws {
        let url = try file("a.txt", "disk")
        let other = try file("b.txt", "other")
        let document = try store.open(url)
        edit(document, NSRange(location: 0, length: 4), "memory")
        XCTAssertEqual(store.text(of: url), "memory")
        XCTAssertEqual(store.text(of: other), "other")
        XCTAssertNil(store.text(of: root.appendingPathComponent("missing.txt")))
    }

    func testUntitledDocument() {
        let document = store.newUntitled()
        XCTAssertNil(document.url)
        XCTAssertNil(document.language)
        XCTAssertEqual(document.title, "Untitled")
        XCTAssertFalse(store.saveQuietly(document))         // it would need a name
    }

    // MARK: - Encodings and refusals

    func testUTF16WithByteOrderMarkIsReadAndWrittenBackAsUTF16() throws {
        let url = root.appendingPathComponent("wide.txt")
        try XCTUnwrap("héllo wörld\n".data(using: .utf16)).write(to: url)
        let document = try store.open(url)
        XCTAssertEqual(document.encoding, .utf16)
        XCTAssertEqual(document.text, "héllo wörld\n")
        edit(document, NSRange(location: 0, length: 0), "¡")
        XCTAssertTrue(store.save(document, showsErrors: false))
        let data = try Data(contentsOf: url)
        XCTAssertTrue(data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]))
        XCTAssertEqual(String(data: data, encoding: .utf16), "¡héllo wörld\n")
    }

    func testLatin1IsKeptUntilTheTextNeedsMore() throws {
        let url = root.appendingPathComponent("latin.txt")
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: url)          // "café\n" in ISO Latin 1
        let document = try store.open(url)
        XCTAssertEqual(document.encoding, .isoLatin1)
        XCTAssertEqual(document.text, "café\n")
        edit(document, NSRange(location: 4, length: 0), "!")
        XCTAssertTrue(store.save(document, showsErrors: false))
        XCTAssertEqual([UInt8](try Data(contentsOf: url)), [0x63, 0x61, 0x66, 0xE9, 0x21, 0x0A])
        // A character Latin 1 cannot hold: the file quietly becomes UTF-8 rather than losing it.
        edit(document, NSRange(location: 0, length: 0), "€")
        XCTAssertTrue(store.save(document, showsErrors: false))
        XCTAssertEqual(document.encoding, .utf8)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "€café!\n")
    }

    func testBinaryAndOversizedFilesAreRefused() throws {
        let binary = root.appendingPathComponent("blob.bin")
        try Data([0x41, 0x00, 0x42]).write(to: binary)
        XCTAssertThrowsError(try store.open(binary)) { XCTAssertEqual($0 as? FileLoadError, .binary) }
        let huge = root.appendingPathComponent("huge.txt")
        try Data(count: 50_000_001).write(to: huge)
        XCTAssertThrowsError(try store.open(huge)) { XCTAssertEqual($0 as? FileLoadError, .tooLarge) }
        XCTAssertNil(store.existingDocument(at: binary))
        XCTAssertFalse(FileLoadError.binary.errorDescription?.isEmpty ?? true)
    }

    // MARK: - Undoable edits

    func testReplaceAllIsOneUndoStep() throws {
        let document = try store.open(try file("a.txt", "one\n"))
        document.replaceAll(with: "one\n")                  // nothing changed: nothing to undo
        XCTAssertFalse(document.undoManager.canUndo)
        document.replaceAll(with: "two\n")
        XCTAssertEqual(document.text, "two\n")
        XCTAssertTrue(document.isDirty)
        document.undoManager.undo()
        XCTAssertEqual(document.text, "one\n")
        document.undoManager.redo()
        XCTAssertEqual(document.text, "two\n")
    }

    func testApplyMakesABatchAsOneUndoStep() throws {
        let document = try store.open(try file("a.txt", "alpha beta gamma"))
        document.apply([])
        XCTAssertFalse(document.undoManager.canUndo)
        document.apply([RangeEdit(range: NSRange(location: 0, length: 5), text: "A"),
                        RangeEdit(range: NSRange(location: 11, length: 0), text: "δ")])
        XCTAssertEqual(document.text, "A beta δgamma")
        document.undoManager.undo()
        XCTAssertEqual(document.text, "alpha beta gamma")
        document.undoManager.redo()
        XCTAssertEqual(document.text, "A beta δgamma")
    }

    // MARK: - Saving

    func testSaveWritesClearsDirtyAndAnnounces() throws {
        let url = try file("a.txt", "old")
        let document = try store.open(url)
        edit(document, NSRange(location: 0, length: 3), "new")
        var sawWillSave = false
        store.willSave = { sawWillSave = $0 === document }
        let saved = expectation(forNotification: DocumentStore.didSaveDocument, object: store) { ($0.userInfo?["url"] as? URL) == url }
        XCTAssertTrue(store.save(document, showsErrors: false))
        wait(for: [saved], timeout: 1)
        XCTAssertTrue(sawWillSave)
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
        XCTAssertFalse(store.isChangedOnDisk(document))
        XCTAssertTrue(store.saveAll())
    }

    func testTextForDiskLineEndings() {
        XCTAssertEqual(DocumentStore.textForDisk("a\r\nb\rc\n", lineEnding: nil), "a\r\nb\rc\n")
        XCTAssertEqual(DocumentStore.textForDisk("a\nb\n", lineEnding: .lf), "a\nb\n")
        XCTAssertEqual(DocumentStore.textForDisk("a\r\nb\rc\n", lineEnding: .lf), "a\nb\nc\n")
        XCTAssertEqual(DocumentStore.textForDisk("a\nb\r\nc", lineEnding: .crlf), "a\r\nb\r\nc")
        XCTAssertEqual(DocumentStore.textForDisk("a\nb\n", lineEnding: .cr), "a\rb\r")
        XCTAssertEqual(DocumentStore.textForDisk("", lineEnding: .crlf), "")
    }

    func testSaveFollowsEditorConfigLineEndingsAndCharset() throws {
        try TestSupport.write([".editorconfig": "root = true\n[*.txt]\nend_of_line = crlf\ncharset = latin1\nindent_style = tab\ntab_width = 3\n"], under: root)
        let url = try file("a.txt", "one\ntwo\n")
        let document = try store.open(url)
        XCTAssertEqual(document.editorConfig?.lineEnding, .crlf)
        XCTAssertEqual(document.indentation.useSpaces, false)
        XCTAssertEqual(document.indentation.width, 3)
        XCTAssertEqual(document.indentation.unit, "\t")
        edit(document, NSRange(location: 0, length: 0), "é")
        XCTAssertTrue(store.save(document, showsErrors: false))
        XCTAssertEqual(document.text, "éone\ntwo\n")              // the document keeps its Unix line endings
        XCTAssertEqual([UInt8](try Data(contentsOf: url)), [0xE9, 0x6F, 0x6E, 0x65, 0x0D, 0x0A, 0x74, 0x77, 0x6F, 0x0D, 0x0A])
        XCTAssertEqual(document.encoding, .isoLatin1)
    }

    func testIndentationFallsBackToTheUserSettings() throws {
        let document = try store.open(try file("plain.txt", ""))
        XCTAssertNil(document.editorConfig)
        XCTAssertEqual(document.indentation.useSpaces, Settings.shared.useSpaces)
        XCTAssertEqual(document.indentation.width, Settings.shared.tabWidth)
    }

    func testSavingTheEditorConfigReachesTheOtherOpenFiles() throws {
        let config = try file(".editorconfig", "root = true\n[*]\nindent_size = 2\n")
        let document = try store.open(try file("a.txt", "x"))
        XCTAssertEqual(document.editorConfig?.tabWidth, 2)
        let configDocument = try store.open(config)
        configDocument.replaceAll(with: "root = true\n[*]\nindent_size = 8\n")
        let invalidated = expectation(forNotification: EditorConfigStore.didInvalidate, object: nil)
        XCTAssertTrue(store.save(configDocument, showsErrors: false))
        wait(for: [invalidated], timeout: 1)
        XCTAssertEqual(document.editorConfig?.tabWidth, 8)
    }

    // MARK: - The disk changing underneath

    func testIsChangedOnDiskNoticesOutsideWritesAndDeletion() throws {
        let url = try file("a.txt", "one")
        let document = try store.open(url)
        XCTAssertFalse(store.isChangedOnDisk(document))
        try "one more".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(store.isChangedOnDisk(document))
        store.noteWrittenToDisk(document)                    // Feather wrote it itself: not an outside change
        XCTAssertFalse(store.isChangedOnDisk(document))
        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(store.isChangedOnDisk(document))
        XCTAssertTrue(store.isChangedOnDisk(store.newUntitled()))
    }

    func testSyncWithDiskReloadsCleanDocumentsAndLeavesDirtyOnesAlone() throws {
        let clean = try store.open(try file("clean.txt", "one"))
        let dirty = try store.open(try file("dirty.txt", "one"))
        edit(dirty, NSRange(location: 3, length: 0), " typed")
        try "one\ntwo".write(to: root.appendingPathComponent("clean.txt"), atomically: true, encoding: .utf8)
        try "one\ntwo".write(to: root.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)
        store.syncWithDisk(refreshGitBases: false)
        XCTAssertEqual(clean.text, "one\ntwo")
        XCTAssertFalse(clean.isDirty)
        XCTAssertFalse(clean.undoManager.canUndo)
        XCTAssertFalse(store.isChangedOnDisk(clean))
        XCTAssertEqual(dirty.text, "one typed")
        XCTAssertTrue(dirty.isDirty)
        XCTAssertTrue(store.isChangedOnDisk(dirty))
    }

    func testRevertToDiskIsUndoable() throws {
        let url = try file("a.txt", "disk")
        let document = try store.open(url)
        edit(document, NSRange(location: 0, length: 4), "typed")
        store.revertToDisk(document)
        XCTAssertEqual(document.text, "disk")
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(store.isChangedOnDisk(document))
        document.undoManager.undo()
        XCTAssertEqual(document.text, "typed")
        XCTAssertTrue(document.isDirty)
    }

    // MARK: - Moving

    func testFileMovedFollowsFilesAndFoldersKeepingEdits() throws {
        let inFolder = try store.open(try file("src/a.txt", "a"))
        let renamed = try store.open(try file("b.txt", "b"))
        let lookalike = try store.open(try file("srcfile.txt", "c"))     // "src" is a prefix of its name, not its folder
        edit(inFolder, NSRange(location: 1, length: 0), "!")
        store.fileMoved(from: root.appendingPathComponent("src"), to: root.appendingPathComponent("lib"))
        store.fileMoved(from: root.appendingPathComponent("b.txt"), to: root.appendingPathComponent("b.rb"))
        XCTAssertEqual(inFolder.url?.path, root.appendingPathComponent("lib/a.txt").path)
        XCTAssertEqual(inFolder.text, "a!")
        XCTAssertTrue(inFolder.isDirty)
        XCTAssertEqual(renamed.url?.lastPathComponent, "b.rb")
        XCTAssertEqual(renamed.language?.name, "Ruby")
        XCTAssertEqual(lookalike.url?.lastPathComponent, "srcfile.txt")
        XCTAssertTrue(store.existingDocument(at: root.appendingPathComponent("lib/a.txt")) === inFolder)
    }

    func testFileMovedUnderstandsTmpAndPrivateTmpAsOnePlace() throws {
        let document = try store.open(try file("a.txt", "a"))
        // The explorer may report the move with the /tmp spelling while the document holds /private/tmp.
        let spelledOld = URL(fileURLWithPath: root.path.replacingOccurrences(of: "/private/", with: "/")).appendingPathComponent("a.txt")
        store.fileMoved(from: spelledOld, to: root.appendingPathComponent("z.txt"))
        XCTAssertEqual(document.url?.lastPathComponent, "z.txt")
    }

    // MARK: - Media and virtual documents

    func testMediaDocumentsAreNeverWritten() throws {
        let url = try file("picture.png", "not really a picture")
        let media = store.openMedia(url)
        XCTAssertTrue(media.isMedia)
        XCTAssertEqual(media.text, "")
        XCTAssertTrue(store.openMedia(url) === media)
        XCTAssertEqual(media.useCount, 2)
        XCTAssertTrue(store.save(media, showsErrors: false))          // "saved", without touching the file
        XCTAssertFalse(store.saveQuietly(media))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not really a picture")
        XCTAssertNil(media.syntaxTree)
        store.syncWithDisk(refreshGitBases: false)                    // skips media, so nothing is read into it
        XCTAssertEqual(media.text, "")
    }

    func testVirtualDocumentHasItsOwnTitle() {
        let identity = URL(fileURLWithPath: "/nowhere/diff/a.txt")
        let virtual = store.openVirtual(identity, title: "a.txt (Working Tree)")
        XCTAssertEqual(virtual.title, "a.txt (Working Tree)")
        XCTAssertTrue(virtual.isMedia)
        XCTAssertTrue(store.openVirtual(identity, title: "other") === virtual)
        XCTAssertEqual(virtual.title, "a.txt (Working Tree)")
    }

    // MARK: - Workspace edits

    func testWorkspaceEditChangesOpenFilesInMemoryAndOthersOnDisk() throws {
        let open = try file("open.txt", "hello world\n")
        let closed = try file("closed.txt", "hello world\n")
        let document = try store.open(open)
        let edit = LSPTextEdit(startLine: 0, startCharacter: 6, endLine: 0, endCharacter: 11, newText: "there")
        store.apply([open: [edit], closed: [edit]])
        XCTAssertEqual(document.text, "hello there\n")
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(try String(contentsOf: open, encoding: .utf8), "hello world\n")
        XCTAssertEqual(try String(contentsOf: closed, encoding: .utf8), "hello there\n")
        document.undoManager.undo()
        XCTAssertEqual(document.text, "hello world\n")
    }

    // MARK: - Notifications

    func testURLAndDiagnosticsAnnounceThemselves() throws {
        let document = try store.open(try file("a.txt", ""))
        let state = expectation(forNotification: TextDocument.stateDidChange, object: document)
        document.url = root.appendingPathComponent("b.txt")
        let diagnostics = expectation(forNotification: TextDocument.diagnosticsDidChange, object: document)
        document.diagnostics = []
        wait(for: [state, diagnostics], timeout: 1)
        let gitBase = expectation(forNotification: TextDocument.gitBaseDidChange, object: document)
        gitBase.isInverted = true
        document.gitBaseLines = nil                          // unchanged: nobody is told
        wait(for: [gitBase], timeout: 0.2)
    }
}
