import XCTest
@testable import Feather

/// Covers Terminal/SendToTerminal.swift: the text Fix This types at the assistant's prompt, the file reference
/// Send File Reference types, and the project-relative path both are built from.
final class TerminalTextTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/proj")

    private func problem(_ message: String, severity: Int = 1, line: Int = 41, source: String? = "ts", code: String? = nil) -> ProblemItem {
        ProblemItem(url: root.appendingPathComponent("src/App.tsx"),
                    diagnostic: LSPDiagnostic(startLine: line, startCharacter: 4, endLine: line, endCharacter: 9,
                                              severity: severity, message: message, source: source, code: code))
    }

    func testRelativePathIsRelativeOnlyInsideTheProject() {
        XCTAssertEqual(TerminalText.relativePath(of: root.appendingPathComponent("src/a.ts"), root: root), "src/a.ts")
        XCTAssertEqual(TerminalText.relativePath(of: URL(fileURLWithPath: "/tmp/other/a.ts"), root: root), "/tmp/other/a.ts")
        XCTAssertEqual(TerminalText.relativePath(of: URL(fileURLWithPath: "/tmp/projects/a.ts"), root: root), "/tmp/projects/a.ts")
        XCTAssertEqual(TerminalText.relativePath(of: root.appendingPathComponent("a.ts"), root: nil), "/tmp/proj/a.ts")
    }

    func testFixRequestNamesThePlaceAndTheMessageOneBased() {
        XCTAssertEqual(TerminalText.fixRequest(for: problem("Type 'string' is not assignable to type 'number'."), root: root),
                       "Fix this error in src/App.tsx:42: Type 'string' is not assignable to type 'number'. ")
        XCTAssertEqual(TerminalText.fixRequest(for: problem("unused", severity: 2, line: 0), root: root),
                       "Fix this warning in src/App.tsx:1: unused ")
        XCTAssertEqual(TerminalText.fixRequest(for: problem("x"), root: nil), "Fix this error in /tmp/proj/src/App.tsx:42: x ")
    }

    func testFixRequestForAComment() {
        let todo = ProblemItem(url: root.appendingPathComponent("lib/util.py"), tag: "TODO", text: "handle the empty case", line: 6, character: 2)
        XCTAssertEqual(TerminalText.fixRequest(for: todo, root: root), "Take care of this TODO in lib/util.py:7: handle the empty case ")
        let bare = ProblemItem(url: root.appendingPathComponent("lib/util.py"), tag: "FIXME", text: "", line: 6, character: 2)
        XCTAssertEqual(TerminalText.fixRequest(for: bare, root: root), "Take care of this FIXME in lib/util.py:7. ")
    }

    func testFixRequestNeverContainsAKeyPress() {
        let text = TerminalText.fixRequest(for: problem("bad\tvalue \u{1B}[0m here  "), root: root)
        XCTAssertEqual(text, "Fix this error in src/App.tsx:42: bad value  [0m here ")
        XCTAssertFalse(text.contains("\t"))
        XCTAssertFalse(text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        // A diagnostic row keeps its first line only; a comment's text is kept whole, so it is where newlines can be.
        let todo = ProblemItem(url: root.appendingPathComponent("a.py"), tag: "TODO", text: "one\ntwo\r\nthree", line: 0, character: 0)
        XCTAssertEqual(TerminalText.fixRequest(for: todo, root: root), "Take care of this TODO in a.py:1: one two  three ")
        XCTAssertEqual(TerminalText.fixRequest(for: problem("   "), root: root), "Fix this error in src/App.tsx:42. ")
    }

    func testFixRequestKeepsNonASCIIText() {
        XCTAssertEqual(TerminalText.fixRequest(for: problem("Variable „größe“ ist nicht definiert – 😀"), root: root),
                       "Fix this error in src/App.tsx:42: Variable „größe“ ist nicht definiert – 😀 ")
    }

    func testFileReferenceWithoutATabOrAnEditor() {
        XCTAssertNil(TerminalText.fileReference(of: nil, root: root))
        let document = TextDocument()
        XCTAssertNil(TerminalText.fileReference(of: EditorTab(document: document, wire: { _ in }), root: root))
        document.url = root.appendingPathComponent("src/my file.ts")
        // No editor has been built for the tab, so no line numbers: just the path, quoted for the shell.
        XCTAssertEqual(TerminalText.fileReference(of: EditorTab(document: document, wire: { _ in }), root: root), "'src/my file.ts'")
        document.url = root.appendingPathComponent("src/plain.ts")
        XCTAssertEqual(TerminalText.fileReference(of: EditorTab(document: document, wire: { _ in }), root: root), "src/plain.ts")
        XCTAssertEqual(TerminalText.fileReference(of: EditorTab(document: document, wire: { _ in }), root: nil), "/tmp/proj/src/plain.ts")
    }

    func testSelectionOrLineWithoutAnEditorIsNil() {
        XCTAssertNil(TerminalText.selectionOrLine(of: nil))
        XCTAssertNil(TerminalText.selectionOrLine(of: EditorTab(document: TextDocument(), wire: { _ in })))
    }
}
