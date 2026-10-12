/// Covers Explorer/FileTree.swift: the FileNode tree (children from disk, folders first in Finder order, hidden
/// names left out, reloads that keep nodes, ignored folders dimming their contents, the rows for a name being
/// typed), the "name copy 2" rule, and the folder watcher.
import XCTest
@testable import Feather

final class FileNodeTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = TestSupport.temporaryDirectory("feather-tree")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeTree() throws -> FileNode {
        try TestSupport.write([
            "zeta.swift": "", "File10.txt": "", "file2.txt": "", "b-folder/inner.txt": "", "a-folder/.keep": "",
            ".gitignore": "build/\n", ".DS_Store": "", ".git/HEAD": "", "Ünïcode/ß.txt": "",
        ], under: root)
        return FileNode(url: root, isDirectory: true)
    }

    func testChildrenAreFoldersFirstInFinderOrderWithoutTheHiddenNames() throws {
        let node = try makeTree()
        XCTAssertFalse(node.isLoaded)
        let names = node.children.map(\.name)
        XCTAssertTrue(node.isLoaded)
        XCTAssertEqual(names.filter { !$0.hasPrefix(".") }, ["a-folder", "b-folder", "Ünïcode", "file2.txt", "File10.txt", "zeta.swift"])
        XCTAssertTrue(names.contains(".gitignore"))
        XCTAssertFalse(names.contains(".DS_Store"))
        XCTAssertFalse(names.contains(".git"))
        XCTAssertEqual(node.children.filter(\.isDirectory).map(\.name), ["a-folder", "b-folder", "Ünïcode"])
        XCTAssertEqual(node.name, root.lastPathComponent)
    }

    func testAFileHasNoChildren() {
        let file = FileNode(url: root.appendingPathComponent("x.txt"), isDirectory: false)
        XCTAssertEqual(file.children, [])
        XCTAssertFalse(file.reload())
        XCTAssertFalse(file.isLoaded)
    }

    func testReloadKeepsNodesAndReportsWhetherAnythingChanged() throws {
        let node = try makeTree()
        let before = node.children
        XCTAssertFalse(node.reload(), "nothing on disk changed")
        XCTAssertTrue(zip(before, node.children).allSatisfy { $0 === $1 })

        try TestSupport.write(["new.txt": ""], under: root)
        XCTAssertTrue(node.reload())
        XCTAssertTrue(node.children.contains { $0.name == "new.txt" })
        XCTAssertTrue(node.children.first { $0.name == "zeta.swift" } === before.first { $0.name == "zeta.swift" }, "the untouched nodes are the same objects")

        // A file replaced by a folder of the same name is a new node.
        try FileManager.default.removeItem(at: root.appendingPathComponent("file2.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("file2.txt"), withIntermediateDirectories: true)
        XCTAssertTrue(node.reload())
        let replaced = node.children.first { $0.name == "file2.txt" }
        XCTAssertEqual(replaced?.isDirectory, true)
        XCTAssertFalse(replaced === before.first { $0.name == "file2.txt" })

        try FileManager.default.removeItem(at: root.appendingPathComponent("new.txt"))
        XCTAssertTrue(node.reload())
        XCTAssertFalse(node.children.contains { $0.name == "new.txt" })
        XCTAssertFalse(node.ignoreChecked, "a changed listing asks git again")
    }

    func testAnIgnoredFolderDimsEverythingInsideIt() throws {
        let node = try makeTree()
        let folder = try XCTUnwrap(node.children.first { $0.name == "b-folder" })
        XCTAssertFalse(folder.isIgnored)
        folder.isIgnored = true
        XCTAssertEqual(folder.children.map(\.isIgnored), [true])
        try TestSupport.write(["b-folder/later.txt": ""], under: root)
        XCTAssertTrue(folder.reload())
        XCTAssertEqual(folder.children.map(\.isIgnored), [true, true], "children found later are dimmed too")
        XCTAssertFalse(node.children.first { $0.name == "zeta.swift" }?.isIgnored ?? true)
    }

    func testPlaceholdersGoWhereVSCodePutsThem() throws {
        let node = try makeTree()
        let newFolder = node.addPlaceholder(isDirectory: true)
        XCTAssertTrue(newFolder.isPlaceholder)
        XCTAssertEqual(newFolder.name, "")
        XCTAssertTrue(node.children.first === newFolder, "a new folder above the folders")

        let newFile = node.addPlaceholder(isDirectory: false)
        let firstFileIndex = node.children.firstIndex { !$0.isDirectory }
        XCTAssertTrue(node.children[firstFileIndex ?? -1] === newFile, "a new file above the files")
        XCTAssertEqual(node.children.filter(\.isPlaceholder).count, 2)

        node.removePlaceholders()
        XCTAssertEqual(node.children.filter(\.isPlaceholder).count, 0)
        XCTAssertFalse(node.reload(), "placeholders never reached the disk")

        // An empty folder: the file placeholder is simply last.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let empty = FileNode(url: root.appendingPathComponent("empty"), isDirectory: true)
        let onlyFile = empty.addPlaceholder(isDirectory: false)
        XCTAssertEqual(empty.children.count, 1)
        XCTAssertTrue(empty.children.last === onlyFile)
    }

    func testStandardPathHasOneSpellingForAnExistingFolder() throws {
        // Foundation folds /private/tmp into /tmp for paths that exist, so both spellings meet at "/tmp/…".
        let name = "feather-tree-\(UUID().uuidString)"
        let short = URL(fileURLWithPath: "/tmp/" + name)
        try FileManager.default.createDirectory(at: short, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: short) }
        XCTAssertEqual(FileNode(url: short, isDirectory: true).standardPath, "/tmp/" + name)
        XCTAssertEqual(FileNode(url: URL(fileURLWithPath: "/private/tmp/" + name + "/"), isDirectory: true).standardPath, "/tmp/" + name)
        XCTAssertEqual(FileNode(url: URL(fileURLWithPath: "/tmp/" + name + "/x/../y"), isDirectory: true).standardPath, "/tmp/" + name + "/y")
    }
}

final class FileTreeHelperTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = TestSupport.temporaryDirectory("feather-tree-helpers")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testAvailableNamesNeverOverwrite() throws {
        let sidebar = SidebarViewController()
        XCTAssertEqual(sidebar.availableURL(for: "a.txt", in: root).lastPathComponent, "a.txt")
        try TestSupport.write(["a.txt": "", "a copy.txt": "", "Makefile": "", ".env": "", "notes": ""], under: root)
        XCTAssertEqual(sidebar.availableURL(for: "a.txt", in: root).lastPathComponent, "a copy 2.txt")
        XCTAssertEqual(sidebar.availableURL(for: "Makefile", in: root).lastPathComponent, "Makefile copy")
        XCTAssertEqual(sidebar.availableURL(for: ".env", in: root).lastPathComponent, ".env copy")
        XCTAssertEqual(sidebar.availableURL(for: "notes", in: root).lastPathComponent, "notes copy")
        XCTAssertEqual(sidebar.availableURL(for: "a.txt", in: root).deletingLastPathComponent(), root)
        XCTAssertNil(sidebar.rootURL)
    }

    func testTheWatcherReportsAChangeUnderTheFolder() throws {
        var reported: [String] = []
        let watcher = DirectoryWatcher(path: root.path)
        watcher.onChange = { reported.append(contentsOf: $0) }
        // Give the stream a moment to start before the first change, so the event is not from before it began.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        try TestSupport.write(["sub/changed.txt": "x"], under: root)
        XCTAssertTrue(TestSupport.wait(upTo: 8) { !reported.isEmpty }, "no file-system event arrived")
        // Events name the real location (/private/var/…), whatever spelling the watcher was given.
        XCTAssertTrue(reported.contains { $0.contains("/" + root.lastPathComponent + "/") }, "\(reported)")
    }

    func testTwoWatchersOfOneFolderBothHear() throws {
        var first = 0, second = 0
        let one = DirectoryWatcher(path: root.path)
        let two = DirectoryWatcher(path: root.path)
        one.onChange = { _ in first += 1 }
        two.onChange = { _ in second += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        try TestSupport.write(["a.txt": "x"], under: root)
        XCTAssertTrue(TestSupport.wait(upTo: 8) { first > 0 && second > 0 })
        _ = (one, two)
    }
}

/// Compact folders: a chain of folders holding nothing but one folder is shown as one row.
final class CompactFoldersTests: XCTestCase {
    func testChainIsFoldedIntoTheLastLink() throws {
        let root = TestSupport.temporaryDirectory("feather-compact")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.write(["iam/src/main/java/com/aagicorp/iam/App.java": "", "iam/src/main/java/com/aagicorp/iam/Util.java": "",
                               "iam/pom.xml": "", "docs/readme.md": ""], under: root)
        let controller = SidebarViewController()
        _ = controller.view
        controller.setRoot(root)
        let outline = controller.outlineViewForTests
        let names = (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? FileNode)?.displayName }
        XCTAssertEqual(names, ["docs", "iam"])                       // docs holds a file, so it is not folded
        outline.expandItem(outline.item(atRow: 1))
        let expanded = (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? FileNode)?.displayName }
        XCTAssertEqual(expanded, ["docs", "iam", "src › main › java › com › aagicorp › iam", "pom.xml"])
        let chain = try XCTUnwrap(outline.item(atRow: 2) as? FileNode)
        XCTAssertEqual(chain.url.lastPathComponent, "iam")
        XCTAssertEqual(chain.compactedNames, ["src", "main", "java", "com", "aagicorp"])
        outline.expandItem(chain)
        XCTAssertEqual(outline.numberOfRows, 6)
        XCTAssertEqual((outline.item(atRow: 3) as? FileNode)?.displayName, "App.java")
    }

    func testRevealOpensThroughAChain() throws {
        let root = TestSupport.temporaryDirectory("feather-compact")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.write(["a/b/c/file.txt": "", "a/b/c/other.txt": ""], under: root)
        let controller = SidebarViewController()
        _ = controller.view
        controller.setRoot(root)
        controller.reveal(root.appendingPathComponent("a/b/c/other.txt"))
        let outline = controller.outlineViewForTests
        XCTAssertEqual((outline.item(atRow: outline.selectedRow) as? FileNode)?.name, "other.txt")
        XCTAssertEqual((outline.item(atRow: 0) as? FileNode)?.displayName, "a › b › c")
    }
}

/// Compact folders across a larger, mixed tree.
final class CompactFoldersMixedTreeTests: XCTestCase {
    private func rows(_ outline: NSOutlineView) -> [String] {
        (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? FileNode)?.displayName }
    }

    func testMixedTree() throws {
        let root = TestSupport.temporaryDirectory("feather-compact-mixed")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.write([
            "backend/src/main/java/com/acme/App.java": "", "backend/src/main/java/com/acme/Util.java": "",
            "backend/src/main/resources/application.yml": "",          // src/main has two folders: no fold past main
            "backend/pom.xml": "",
            "frontend/src/components/Button.tsx": "", "frontend/src/components/Input.tsx": "",
            "frontend/src/index.ts": "",                               // src holds a file: chain stops at src
            "frontend/package.json": "",
            "scripts/deploy.sh": "",
            "one/two/three/four/five/deep.txt": "",
            "README.md": "",
        ], under: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty/inner"), withIntermediateDirectories: true)

        let controller = SidebarViewController()
        _ = controller.view
        controller.setRoot(root)
        let outline = controller.outlineViewForTests
        XCTAssertEqual(rows(outline), ["backend", "empty › inner", "frontend", "one › two › three › four › five", "scripts", "README.md"])

        outline.expandItem(outline.item(atRow: 0))            // backend
        XCTAssertEqual(rows(outline).prefix(4).map { $0 }, ["backend", "src › main", "pom.xml", "empty › inner"])
        outline.expandItem(outline.item(atRow: 1))            // src › main
        XCTAssertEqual(rows(outline).prefix(5).map { $0 }, ["backend", "src › main", "java › com › acme", "resources", "pom.xml"])
        outline.expandItem(outline.item(atRow: 2))            // java › com › acme
        XCTAssertEqual(rows(outline).prefix(6).map { $0 }, ["backend", "src › main", "java › com › acme", "App.java", "Util.java", "resources"])

        let frontendRow = try XCTUnwrap(rows(outline).firstIndex(of: "frontend"))
        let frontend = try XCTUnwrap(outline.item(atRow: frontendRow) as? FileNode)
        outline.expandItem(frontend)
        let row = outline.row(forItem: frontend)
        XCTAssertEqual(rows(outline)[row + 1 ..< row + 3].map { $0 }, ["src", "package.json"])
        let src = try XCTUnwrap(outline.item(atRow: row + 1) as? FileNode)
        outline.expandItem(src)
        XCTAssertEqual(rows(outline)[row + 2 ..< row + 4].map { $0 }, ["components", "index.ts"])

        // Revealing a deep file opens exactly the rows that exist and keeps the chain labels intact.
        controller.reveal(root.appendingPathComponent("one/two/three/four/five/deep.txt"))
        XCTAssertEqual((outline.item(atRow: outline.selectedRow) as? FileNode)?.name, "deep.txt")
        XCTAssertTrue(rows(outline).contains("one › two › three › four › five"))
        controller.reveal(root.appendingPathComponent("backend/src/main/resources/application.yml"))
        XCTAssertEqual((outline.item(atRow: outline.selectedRow) as? FileNode)?.name, "application.yml")
        XCTAssertTrue(rows(outline).contains("java › com › acme"), rows(outline).joined(separator: " | "))
    }

    func testAChainUnfoldsWhenAFolderGainsASecondEntry() throws {
        let root = TestSupport.temporaryDirectory("feather-compact-change")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.write(["a/b/c/file.txt": ""], under: root)
        let controller = SidebarViewController()
        _ = controller.view
        controller.setRoot(root)
        let outline = controller.outlineViewForTests
        XCTAssertEqual(rows(outline), ["a › b › c"])
        try "".write(to: root.appendingPathComponent("a/note.md"), atomically: true, encoding: .utf8)
        let arrived = TestSupport.wait(upTo: 8) { self.rows(outline) == ["a"] }
        if !arrived { controller.refreshTreeForTests() }          // no file-system event in this sandbox: refresh by hand
        XCTAssertEqual(rows(outline), ["a"])
        outline.expandItem(outline.item(atRow: 0))
        XCTAssertEqual(rows(outline), ["a", "b › c", "note.md"])
    }
}

/// The explorer rows: the one column fits the sidebar however deep the tree is, so the git mark at the end of a
/// row is always in view; a changed file shows its letter and the folders above it a dot; a compact chain's
/// folded folders recede.
final class ExplorerRowTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window?.contentView = nil
        window = nil
        super.tearDown()
    }

    /// The sidebar at a typical width, in a window so rows and cells are laid out.
    private func sidebar(for root: URL, width: CGFloat = 240) -> SidebarViewController {
        let controller = SidebarViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = controller.view
        self.window = window
        controller.setRoot(root)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func badge(_ outline: NSOutlineView, row: Int) -> NSTextField? {
        outline.view(atColumn: 0, row: row, makeIfNecessary: true)?.subviews.first { $0.identifier == SidebarViewController.badgeIdentifier } as? NSTextField
    }

    private func rows(_ outline: NSOutlineView) -> [String] {
        (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? FileNode)?.displayName }
    }

    func testADeepTreeScrollsSidewaysWithTheMarksPinnedToTheVisibleEdge() throws {
        let root = TestSupport.temporaryDirectory("feather-fit")
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = "a-rather-long-folder-name/another-long-folder-name/yet-another-long-folder-name/deep"
        try TestSupport.write(["\(deep)/SomeVeryLongFileNameThatWouldNeverFitInTheSidebar.java": "", "\(deep)/Other.java": ""], under: root)
        let controller = sidebar(for: root)
        controller.reveal(root.appendingPathComponent("\(deep)/SomeVeryLongFileNameThatWouldNeverFitInTheSidebar.java"))
        let outline = controller.outlineViewForTests
        XCTAssertTrue(TestSupport.wait(upTo: 3) { (outline.tableColumns.first?.width ?? 0) > 240 }, "the column grows to the widest row")
        controller.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(outline.enclosingScrollView)
        let clip = scroll.contentView
        XCTAssertTrue(scroll.hasHorizontalScroller)
        XCTAssertEqual(outline.frame.width, outline.tableColumns.first?.width ?? 0, accuracy: 1)
        XCTAssertGreaterThan(outline.frame.width, clip.bounds.width)

        func marksArePinned(_ note: String) throws {
            for row in 0..<outline.numberOfRows {
                let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
                cell.layoutSubtreeIfNeeded()
                let mark = try XCTUnwrap(badge(outline, row: row))
                let rect = mark.convert(mark.bounds, to: clip)
                XCTAssertEqual(rect.maxX, clip.bounds.maxX - SidebarViewController.badgeInset, accuracy: 1, "row \(row) \(note)")
                XCTAssertGreaterThan(rect.width, 0, "row \(row)")
                // The name never runs into the slot the mark sits in when the row is scrolled all the way right.
                XCTAssertLessThanOrEqual(cell.textField?.frame.maxX ?? 0, cell.bounds.width - SidebarViewController.badgeInset - SidebarViewController.badgeWidth, "row \(row) \(note)")
            }
        }
        try marksArePinned("at the left edge")
        // Scrolled sideways, the marks stay where they were seen; the names move under them.
        clip.scroll(to: NSPoint(x: 120, y: clip.bounds.origin.y))
        scroll.reflectScrolledClipView(clip)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(clip.bounds.origin.x, 120)
        try marksArePinned("scrolled by 120")
        // Every row is drawn whole after a sideways scroll, so the bars leave no stripes behind; a vertical
        // scroll leaves the rows alone.
        var rows = 0
        outline.enumerateAvailableRowViews { _, _ in rows += 1 }
        XCTAssertGreaterThan(rows, 0)
        XCTAssertEqual(controller.sidewaysRedrawsForTests, rows, "a sideways scroll redraws every visible row")
        clip.scroll(to: NSPoint(x: 120, y: clip.bounds.origin.y + 10))
        scroll.reflectScrolledClipView(clip)
        XCTAssertEqual(controller.sidewaysRedrawsForTests, rows, "a vertical scroll redraws nothing extra")
        let changed = try XCTUnwrap(badge(outline, row: outline.selectedRow))
        XCTAssertTrue(changed.stringValue.isEmpty)
    }

    func testAChangedFileShowsItsLetterAndTheFoldersAboveItADot() throws {
        let root = try TestSupport.makeRepository(["src/main/java/App.java": "class App {}\n", "src/main/java/Util.java": "", "README.md": "# Test\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        try "class App { int x; }\n".write(to: root.appendingPathComponent("src/main/java/App.java"), atomically: true, encoding: .utf8)
        let controller = sidebar(for: root)
        let outline = controller.outlineViewForTests
        let changedPath = root.appendingPathComponent("src/main/java/App.java").standardizedFileURL.path
        XCTAssertTrue(TestSupport.wait(upTo: 15) { controller.decorations.kind(forFile: changedPath) == .modified }, "no marks arrived")
        controller.reveal(root.appendingPathComponent("src/main/java/App.java"))
        // The folders along the way load as the reveal descends; a slow machine (CI) takes a moment.
        XCTAssertTrue(TestSupport.wait(upTo: 15) { rows(outline).contains("src › main › java") }, rows(outline).joined(separator: " | "))
        let names = rows(outline)
        let chainRow = try XCTUnwrap(names.firstIndex(of: "src › main › java"), names.joined(separator: " | "))
        XCTAssertEqual(badge(outline, row: chainRow)?.stringValue, "•")
        XCTAssertEqual(badge(outline, row: outline.selectedRow)?.stringValue, "M")
        XCTAssertEqual(badge(outline, row: try XCTUnwrap(names.firstIndex(of: "README.md")))?.stringValue, "")
        XCTAssertEqual(badge(outline, row: try XCTUnwrap(names.firstIndex(of: "Util.java")))?.stringValue, "")
        let color = GitDecorations.Kind.modified.color(isDark: Settings.shared.theme.isDark)
        let chain = try XCTUnwrap(outline.view(atColumn: 0, row: chainRow, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(chain.toolTip, (outline.item(atRow: chainRow) as? FileNode)?.url.path.appending("\nContains changes"))
        XCTAssertEqual(chain.textField?.attributedStringValue.attribute(.foregroundColor, at: chain.textField!.attributedStringValue.length - 1, effectiveRange: nil) as? NSColor, color)
        let changed = try XCTUnwrap(outline.view(atColumn: 0, row: outline.selectedRow, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(changed.toolTip, "Modified")
        XCTAssertEqual(changed.textField?.textColor, color)
        XCTAssertEqual(badge(outline, row: outline.selectedRow)?.textColor, color)
    }

    func testAChainLabelFadesTheFoldedFoldersAndKeepsTheLastLink() throws {
        let root = TestSupport.temporaryDirectory("feather-chain-label")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.write(["src/main/java/App.java": ""], under: root)
        let controller = sidebar(for: root)
        let outline = controller.outlineViewForTests
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
        let label = try XCTUnwrap(cell.textField?.attributedStringValue)
        XCTAssertEqual(label.string, "src › main › java")
        let foreground = Settings.shared.theme.foreground
        let first = try XCTUnwrap(label.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let last = try XCTUnwrap(label.attribute(.foregroundColor, at: label.length - 1, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(last, foreground)
        XCTAssertLessThan(first.alphaComponent, foreground.alphaComponent)
        XCTAssertEqual(cell.toolTip, (outline.item(atRow: 0) as? FileNode)?.url.path)
        // A plain row, drawn in a cell that may have shown a chain before, is a plain string with no tooltip.
        outline.expandItem(outline.item(atRow: 0))
        let file = try XCTUnwrap(outline.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(file.textField?.stringValue, "App.java")
        XCTAssertEqual(file.textField?.textColor, foreground)
        XCTAssertNil(file.toolTip)
    }

    func testAChainCanBeUnfoldedIntoRowsAndFoldedBack() throws {
        let root = TestSupport.temporaryDirectory("feather-chain-unfold")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.write(["java/com/aagicorp/comms/A.java": "", "java/com/aagicorp/comms/B.java": "", "pom.xml": ""], under: root)
        let controller = sidebar(for: root)
        let outline = controller.outlineViewForTests
        XCTAssertEqual(rows(outline), ["java › com › aagicorp › comms", "pom.xml"])
        let chain = try XCTUnwrap(outline.item(atRow: 0) as? FileNode)
        outline.expandItem(chain)
        XCTAssertEqual(rows(outline), ["java › com › aagicorp › comms", "A.java", "B.java", "pom.xml"])

        // Unfolding opens the chain out, expanded down to where its row was, and keeps that folder selected.
        controller.unfoldForTests(chain)
        XCTAssertEqual(rows(outline), ["java", "com", "aagicorp", "comms", "A.java", "B.java", "pom.xml"])
        XCTAssertEqual((outline.item(atRow: outline.selectedRow) as? FileNode)?.name, "comms")
        XCTAssertEqual(outline.level(forRow: 3), 3)
        XCTAssertTrue(chain.keepUnfolded)

        // Folding the top of the chain brings the one row back, still expanded.
        let java = try XCTUnwrap(outline.item(atRow: 0) as? FileNode)
        controller.foldForTests(java)
        XCTAssertEqual(rows(outline), ["java › com › aagicorp › comms", "A.java", "B.java", "pom.xml"])
        XCTAssertEqual((outline.item(atRow: outline.selectedRow) as? FileNode)?.displayName, "java › com › aagicorp › comms")
        XCTAssertFalse(chain.keepUnfolded)

        // Folding a link in the middle folds from there down and leaves the rows above it alone.
        controller.unfoldForTests(chain)
        let com = try XCTUnwrap(outline.item(atRow: 1) as? FileNode)
        controller.foldForTests(com)
        XCTAssertEqual(rows(outline), ["java", "com › aagicorp › comms", "A.java", "B.java", "pom.xml"])
    }

    func testTheChangedFileCountIsReportedForTheSourceControlIcon() throws {
        let root = try TestSupport.makeRepository(["a.txt": "a\n", "b.txt": "b\n", "c.txt": "c\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        try "changed\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let controller = SidebarViewController()
        _ = controller.view
        var counts: [Int] = []
        controller.onGitChangeCount = { counts.append($0) }
        controller.setRoot(root)
        XCTAssertTrue(TestSupport.wait(upTo: 15) { counts.last == 2 }, "\(counts)")
        // Staging changes a mark (U to A) but not the number of files; a file both staged and changed is one file.
        TestSupport.git(["add", "new.txt"], in: root)
        try "changed twice\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        controller.refreshGitDecorations()
        let newPath = root.appendingPathComponent("new.txt").standardizedFileURL.path
        XCTAssertTrue(TestSupport.wait(upTo: 15) { controller.decorations.kind(forFile: newPath) == .added }, "\(counts)")
        XCTAssertEqual(counts.last, 2)
        XCTAssertGreaterThanOrEqual(counts.count, 2)
        controller.setRoot(TestSupport.temporaryDirectory("feather-no-repo"))
        XCTAssertTrue(TestSupport.wait(upTo: 5) { counts.last == 0 }, "closing the repository clears the count: \(counts)")
    }

    func testAnIgnoredFolderWithANonASCIINameIsDimmed() throws {
        let root = try TestSupport.makeRepository([".gitignore": "Ünïcode build/\n*.log\n", "src/a.txt": "a\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.write(["Ünïcode build/out.txt": "", "app log.log": "", "src/b.txt": ""], under: root)
        let controller = sidebar(for: root)
        let outline = controller.outlineViewForTests
        func node(_ name: String) -> FileNode? { (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? FileNode }.first { $0.name == name } }
        XCTAssertTrue(TestSupport.wait(upTo: 10) { node("Ünïcode build")?.isIgnored == true && node("app log.log")?.isIgnored == true }, rows(outline).joined(separator: " | "))
        XCTAssertEqual(node("src")?.isIgnored, false)
        XCTAssertEqual(node(".gitignore")?.isIgnored, false)
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: outline.row(forItem: node("Ünïcode build")), makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(cell.imageView?.alphaValue, 0.45)
        XCTAssertEqual(badge(outline, row: outline.row(forItem: node("Ünïcode build")))?.stringValue, "", "an ignored folder never carries a git mark")
    }

    func testRowsHaveHoverAndARoundedSelection() throws {
        let root = TestSupport.temporaryDirectory("feather-rows")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.write(["a/b/c/one.txt": "", "a/b/c/two.txt": "", "a/b/other.txt": "", "top.txt": ""], under: root)
        let controller = sidebar(for: root)
        let outline = controller.outlineViewForTests
        controller.reveal(root.appendingPathComponent("a/b/c/one.txt"))
        controller.view.layoutSubtreeIfNeeded()
        let selected = try XCTUnwrap(outline.rowView(atRow: outline.selectedRow, makeIfNecessary: true) as? ExplorerRowView)
        XCTAssertTrue(selected.isSelected)
        XCTAssertEqual(outline.level(forRow: outline.selectedRow), 2)
        let top = try XCTUnwrap(outline.rowView(atRow: outline.numberOfRows - 1, makeIfNecessary: true) as? ExplorerRowView)
        XCTAssertFalse(top.isSelected)

        // One hovered row for the whole tree: moving to another row clears the first, leaving clears all,
        // and a row reused for another item starts clear.
        let tree = try XCTUnwrap(outline as? ExplorerOutlineView)
        let lastRow = outline.numberOfRows - 1
        tree.setHoveredForTests(lastRow)
        XCTAssertTrue(top.isHovered)
        XCTAssertTrue(tree.isMouseInside)
        tree.setHoveredForTests(outline.selectedRow)
        XCTAssertFalse(top.isHovered)
        XCTAssertTrue(selected.isHovered)
        tree.setHoveredForTests(-1)
        XCTAssertFalse(selected.isHovered)
        XCTAssertFalse(tree.isMouseInside)
        tree.setHoveredForTests(lastRow)
        top.prepareForReuse()
        XCTAssertFalse(top.isHovered)
        XCTAssertEqual(tree.hoveredRow, lastRow)

        // Every row draws, selected or not, hovered or not, with and without emphasis.
        for row in [selected, top] {
            for (hovered, emphasized) in [(false, true), (true, false), (true, true)] {
                row.isHovered = hovered
                row.isEmphasized = emphasized
                let image = NSImage(size: NSSize(width: max(1, row.bounds.width), height: max(1, row.bounds.height)))
                image.lockFocus()
                row.drawBackground(in: row.bounds)
                if row.isSelected { row.drawSelection(in: row.bounds) }
                image.unlockFocus()
                XCTAssertNotNil(image.tiffRepresentation)
            }
        }
    }

    func testTheCellLaysItselfOutWithoutAutoLayout() throws {
        let cell = ExplorerCellView()
        cell.frame = NSRect(x: 0, y: 0, width: 200, height: 22)
        cell.label.stringValue = "AVeryLongFileNameThatNeedsCuttingShortSomewhere.swift"
        cell.mark.stringValue = "M"
        cell.layoutSubtreeIfNeeded()
        XCTAssertEqual(cell.icon.frame, NSRect(x: 2, y: 3, width: 16, height: 16))
        XCTAssertEqual(cell.mark.frame.maxX, 200 - SidebarViewController.badgeInset)
        XCTAssertGreaterThanOrEqual(cell.mark.frame.width, SidebarViewController.badgeWidth)
        XCTAssertEqual(cell.label.frame.minX, 23)
        XCTAssertLessThanOrEqual(cell.label.frame.maxX, cell.mark.frame.minX - 4)
        XCTAssertEqual(cell.subviews.count, 3, "icon, name and mark: nothing is drawn behind the mark, so the row's own background shows")
        XCTAssertTrue(cell.subviews.allSatisfy { !$0.wantsLayer || $0 === cell.icon }, "no coloured box of its own")
        XCTAssertTrue(cell.subviews.allSatisfy { $0.translatesAutoresizingMaskIntoConstraints }, "no constraints: frames are set by hand")
        XCTAssertTrue(cell.constraints.isEmpty)
        // A wider mark takes its room from the name, never from the edge.
        cell.mark.stringValue = "99+"
        cell.needsLayout = true
        cell.layoutSubtreeIfNeeded()
        XCTAssertEqual(cell.mark.frame.maxX, 200 - SidebarViewController.badgeInset)
        XCTAssertLessThanOrEqual(cell.label.frame.maxX, cell.mark.frame.minX - 4)
        let cutShort = cell.label.frame.maxX
        cell.mark.stringValue = ""
        cell.needsLayout = true
        cell.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(cell.label.frame.maxX, cutShort, "with no mark the name has the room back")
        XCTAssertTrue(cell.textField === cell.label && cell.imageView === cell.icon, "the outlets inline editing uses")
    }

    func testCompactFoldersCanBeTurnedOff() throws {
        let root = TestSupport.temporaryDirectory("feather-compact-off")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.write(["src/main/java/App.java": ""], under: root)
        let before = Settings.shared.compactFolders
        defer { Settings.shared.compactFolders = before }
        Settings.shared.compactFolders = false
        let controller = sidebar(for: root)
        let outline = controller.outlineViewForTests
        XCTAssertEqual(rows(outline), ["src"])
        outline.expandItem(outline.item(atRow: 0))
        XCTAssertEqual(rows(outline), ["src", "main"])
        Settings.shared.compactFolders = true
        controller.applySettings()
        XCTAssertEqual(rows(outline), ["src › main › java"])
    }
}
