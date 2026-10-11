import XCTest
@testable import Feather

/// Covers the pure parts of LanguageServer/LSPManager.swift: the server table and how a file is matched to it
/// (Dockerfiles by name), parsing what servers answer (symbols in both shapes, text edits, capabilities),
/// applying edits by line and character, and what a manager says before any server has been started.
final class LSPServerConfigTests: XCTestCase {
    func testKeysAreExtensionsExceptForFilesKnownByName() {
        func key(_ path: String) -> String { LSPServerConfig.key(for: URL(fileURLWithPath: path)) }
        XCTAssertEqual(key("/p/Main.SWIFT"), "swift")
        XCTAssertEqual(key("/p/Dockerfile"), "dockerfile")
        XCTAssertEqual(key("/p/dockerfile"), "dockerfile")
        XCTAssertEqual(key("/p/Dockerfile.dev"), "dockerfile")
        XCTAssertEqual(key("/p/api.dockerfile"), "dockerfile")
        XCTAssertEqual(key("/p/Containerfile"), "dockerfile")
        XCTAssertEqual(key("/p/Makefile"), "")
        XCTAssertEqual(key("/p/archive.tar.gz"), "gz")
    }

    func testConfigForAFile() {
        XCTAssertEqual(LSPServerConfig.config(for: URL(fileURLWithPath: "/p/App.tsx"))?.name, "TypeScript")
        XCTAssertEqual(LSPServerConfig.config(for: URL(fileURLWithPath: "/p/Dockerfile.prod"))?.name, "Docker")
        XCTAssertEqual(LSPServerConfig.config(for: URL(fileURLWithPath: "/p/a.h"))?.name, "C/C++")
        XCTAssertEqual(LSPServerConfig.config(for: URL(fileURLWithPath: "/p/pom.xml"))?.name, "XML")
        XCTAssertNil(LSPServerConfig.config(for: URL(fileURLWithPath: "/p/notes.feather")))
        XCTAssertNil(LSPServerConfig.config(for: URL(fileURLWithPath: "/p/Makefile")))
    }

    func testTheTableIsConsistent() {
        let names = LSPServerConfig.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "server names are unique")
        var seen: [String: String] = [:]
        for config in LSPServerConfig.all {
            XCTAssertFalse(config.commands.isEmpty, config.name)
            XCTAssertFalse(config.installHint.isEmpty, config.name)
            XCTAssertFalse(config.languageIDs.isEmpty, config.name)
            for (key, languageID) in config.languageIDs {
                XCTAssertEqual(key, key.lowercased(), "\(config.name): keys are looked up lowercased")
                XCTAssertFalse(languageID.isEmpty)
                XCTAssertNil(seen[key], "\(key) is claimed by both \(seen[key] ?? "") and \(config.name)")
                seen[key] = config.name
            }
            for command in config.commands {
                XCTAssertFalse(command.executable.isEmpty, config.name)
                XCTAssertFalse(command.executable.contains(" "), config.name)
            }
        }
    }
}

final class LSPParsingTests: XCTestCase {
    private func range(_ sl: Int, _ sc: Int, _ el: Int, _ ec: Int) -> [String: Any] {
        ["start": ["line": sl, "character": sc], "end": ["line": el, "character": ec]]
    }

    func testNestedDocumentSymbolsComeOutFlatInFileOrder() {
        let raw: [[String: Any]] = [
            ["name": "Later", "kind": 5, "range": range(20, 0, 30, 1), "selectionRange": range(20, 6, 20, 11)],
            ["name": "Shape", "kind": 5, "range": range(0, 0, 10, 1), "selectionRange": range(0, 6, 0, 11),
             "children": [
                ["name": "area", "kind": 6, "range": range(2, 4, 4, 5), "selectionRange": range(2, 9, 2, 13),
                 "children": [["name": "cache", "kind": 13, "range": range(3, 8, 3, 20)]]],
                ["name": "init", "kind": 9, "range": range(1, 4, 1, 30)],
             ]],
        ]
        let symbols = LSPManager.parseSymbols(raw)
        XCTAssertEqual(symbols.map(\.name), ["Shape", "init", "area", "cache", "Later"])
        XCTAssertEqual(symbols.map(\.depth), [0, 1, 1, 2, 0])
        XCTAssertEqual(symbols.map(\.container), [nil, "Shape", "Shape", "area", nil])
        XCTAssertEqual(symbols.map(\.line), [0, 1, 2, 3, 20])
        XCTAssertEqual(symbols[0].character, 6, "the selection range, where the name is, wins over the whole range")
        XCTAssertEqual(symbols[1].character, 4)
        XCTAssertEqual(symbols.map(\.kind), [5, 9, 6, 13, 5])
    }

    func testFlatSymbolInformation() {
        let raw: [[String: Any]] = [
            ["name": "main", "kind": 12, "containerName": "cmd", "location": ["uri": "file:///p/a.go", "range": range(5, 5, 7, 1)]],
            ["name": "nameless", "location": ["uri": "file:///p/a.go", "range": range(1, 0, 1, 1)]],
            ["kind": 12, "location": ["uri": "file:///p/a.go", "range": range(2, 0, 2, 1)]],            // no name
            ["name": "nowhere", "kind": 12],                                                             // no range
        ]
        let symbols = LSPManager.parseSymbols(raw)
        XCTAssertEqual(symbols.map(\.name), ["nameless", "main"])
        XCTAssertEqual(symbols[1].container, "cmd")
        XCTAssertEqual(symbols[0].kind, 0)
        XCTAssertEqual(symbols[1].depth, 0)
        XCTAssertTrue(LSPManager.parseSymbols([]).isEmpty)
    }

    func testAMalformedlyDeepTreeIsCutOff() {
        var item: [String: Any] = ["name": "leaf", "range": range(0, 0, 0, 1)]
        for depth in 1...30 { item = ["name": "n\(depth)", "range": range(0, 0, 0, 1), "children": [item]] }
        XCTAssertEqual(LSPManager.parseSymbols([item]).count, 13)
    }

    func testTextEdits() {
        let edit = LSPManager.parseTextEdit(["range": range(1, 2, 3, 4), "newText": "x"])
        XCTAssertEqual(edit.map { [$0.startLine, $0.startCharacter, $0.endLine, $0.endCharacter] }, [1, 2, 3, 4])
        XCTAssertEqual(edit?.newText, "x")
        XCTAssertNil(LSPManager.parseTextEdit(["range": range(1, 2, 3, 4)]))
        XCTAssertNil(LSPManager.parseTextEdit(["newText": "x"]))
        XCTAssertNil(LSPManager.parseTextEdit(["range": ["start": ["line": 1]], "newText": "x"]))
    }

    func testCapabilities() {
        XCTAssertTrue(LSPManager.isProvided(true))
        XCTAssertTrue(LSPManager.isProvided(["triggerCharacters": ["."]]))
        XCTAssertFalse(LSPManager.isProvided(false))
        XCTAssertFalse(LSPManager.isProvided(nil))
        XCTAssertFalse(LSPManager.isProvided(NSNull()))
        XCTAssertFalse(LSPManager.isProvided(1))
    }
}

final class TextEditsTests: XCTestCase {
    private func edit(_ sl: Int, _ sc: Int, _ el: Int, _ ec: Int, _ text: String) -> LSPTextEdit {
        LSPTextEdit(startLine: sl, startCharacter: sc, endLine: el, endCharacter: ec, newText: text)
    }

    func testRangesAreOffsetsIntoTheText() {
        let text = "ab\ncd\nef" as NSString
        let ranges = TextEdits.ranges(for: [edit(0, 1, 0, 2, "X"), edit(1, 0, 2, 1, "Y"), edit(2, 2, 2, 2, "Z")], in: text)
        XCTAssertEqual(ranges.map(\.0), [NSRange(location: 1, length: 1), NSRange(location: 3, length: 4), NSRange(location: 8, length: 0)])
    }

    func testSeveralEditsApplyAsIfAtOnce() {
        let formatted = TextEdits.apply([edit(0, 0, 0, 0, "// header\n"), edit(1, 0, 1, 1, "  "), edit(2, 0, 2, 0, "\n")],
                                        to: "let a = 1\n\tb()\nend")
        XCTAssertEqual(formatted, "// header\nlet a = 1\n  b()\n\nend")
    }

    func testPositionsBeyondTheTextAreClamped() {
        XCTAssertEqual(TextEdits.apply([edit(0, 50, 0, 60, "!")], to: "ab\ncd"), "ab!\ncd")
        XCTAssertEqual(TextEdits.apply([edit(9, 0, 9, 0, "!")], to: "ab\ncd"), "ab\ncd!")
        XCTAssertEqual(TextEdits.apply([edit(1, 1, 0, 1, "!")], to: "ab\ncd"), "ab\nc!d", "a backwards range is empty")
        XCTAssertEqual(TextEdits.apply([], to: "same"), "same")
    }

    func testCharactersAreUTF16() {
        XCTAssertEqual(TextEdits.apply([edit(0, 3, 0, 4, "b")], to: "😀 a"), "😀 b")
    }

    func testAWholeDocumentReplacement() {
        XCTAssertEqual(TextEdits.apply([edit(0, 0, 2, 0, "new\n")], to: "one\ntwo\n"), "new\n")
    }
}

final class LSPManagerStatusTests: XCTestCase {
    func testBeforeAnyServerHasStarted() {
        let manager = LSPManager()
        let file = URL(fileURLWithPath: "/tmp/p/a.ts")
        XCTAssertNil(manager.statusText(for: nil))
        XCTAssertNil(manager.statusText(for: file))
        XCTAssertNil(manager.statusText(for: URL(fileURLWithPath: "/tmp/p/notes.feather")))
        XCTAssertNil(manager.installHint(for: file))
        XCTAssertFalse(manager.isReady(for: file))
        XCTAssertFalse(manager.hasServer(for: file))
        XCTAssertFalse(manager.canFormat(file))
        XCTAssertFalse(manager.canFormat(file, selection: true))
        XCTAssertFalse(manager.canListSymbols(file))
        XCTAssertEqual(manager.triggerCharacters(for: file), [])
        manager.stopAll()
    }
}
