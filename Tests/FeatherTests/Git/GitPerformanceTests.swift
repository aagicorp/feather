/// How long the git-facing parts take at the sizes a big project reaches: status output with tens of thousands
/// of rows, the explorer's marks over thousands of changed files in deep folders, a folder of thousands of
/// entries in the explorer, and a very deep single-folder chain. Each check has a generous limit, so a slow CI
/// machine passes while a regression (quadratic work, a main-thread stall) fails; the time taken is printed.
import XCTest
@testable import Feather

final class GitPerformanceTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    @discardableResult
    /// A shared CI runner is several times slower than a Mac on a desk; its budgets are widened, the numbers
    /// are still printed, and a real regression still goes well past them.
    private static let budgetScale: Double = ProcessInfo.processInfo.environment["CI"] == nil ? 1 : 4

    private func timed(_ label: String, limit nominal: TimeInterval, file: StaticString = #filePath, line: UInt = #line, _ work: () throws -> Void) rethrows -> TimeInterval {
        let limit = nominal * GitPerformanceTests.budgetScale
        let started = CFAbsoluteTimeGetCurrent()
        try work()
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        print(String(format: "PERF %@: %.0f ms (limit %.0f ms)", label, elapsed * 1000, limit * 1000))
        XCTAssertLessThan(elapsed, limit, "\(label) took \(Int(elapsed * 1000)) ms", file: file, line: line)
        return elapsed
    }

    func testParsingTwentyThousandStatusRows() {
        var output = "## main...origin/main [ahead 1]\0"
        for index in 0..<20_000 {
            switch index % 5 {
            case 0: output += " M src/module\(index % 97)/package\(index % 13)/File\(index).swift\0"
            case 1: output += "?? assets/new\(index)/image \(index).png\0"
            case 2: output += "R  lib/renamed\(index).txt\0lib/original\(index).txt\0"
            case 3: output += "UU conflicts/Ünïcode \(index).md\0"
            default: output += "AM staged/then/edited\(index).json\0"
            }
        }
        var status = GitStatus()
        timed("parse 20k status rows", limit: 1.0) { status = Git.parseStatus(output) }
        XCTAssertEqual(status.staged.count + status.unstaged.count, 20_000 + 4_000, "AM rows are two entries")
        XCTAssertEqual(status.conflicts.count, 4_000)
    }

    func testUnquotingTwentyThousandNames() {
        let quoted = (0..<20_000).map { "\"\\303\\234n\\303\\257code \\\"\($0)\\\" \\360\\237\\232\\200.md\"" }
        var names: [String] = []
        timed("unquote 20k names", limit: 1.0) { names = quoted.map(Git.unquotePath) }
        XCTAssertEqual(names.first, "Ünïcode \"0\" 🚀.md")
        XCTAssertEqual(Set(names).count, 20_000)
    }

    /// Thousands of new files, in folders up to six deep: one `git status`, then every folder on the way up
    /// from each file is marked. The marking must stay linear in the number of files and folders.
    func testMarksForThousandsOfChangedFilesInDeepFolders() throws {
        let root = try TestSupport.makeRepository()
        roots.append(root)
        var files: [String: String] = [:]
        for index in 0..<3_000 {
            files["src/area\(index % 30)/module\(index % 17)/part\(index % 7)/deep\(index % 3)/File\(index).swift"] = "x\n"
        }
        try TestSupport.write(files, under: root)
        let decorations = GitDecorations()
        var arrived = false
        decorations.onChange = { arrived = true }
        timed("marks for 3,000 new files (git status included)", limit: 10) {
            decorations.setRoot(root)
            XCTAssertTrue(TestSupport.wait(upTo: 30) { arrived }, "no marks arrived")
        }
        XCTAssertEqual(decorations.files.count, 3_000)
        XCTAssertEqual(decorations.kind(forFolder: root.appendingPathComponent("src").path), .untracked)
        XCTAssertEqual(decorations.kind(forFolder: root.appendingPathComponent("src/area3/module4").path), .untracked)
        XCTAssertGreaterThan(decorations.folders.count, 30 * 17)

        // A refresh that finds the same marks announces nothing and costs one status run.
        arrived = false
        timed("refresh with nothing changed", limit: 10) {
            decorations.scheduleRefresh()
            XCTAssertFalse(TestSupport.wait(upTo: 2) { arrived }, "identical marks must not be announced again")
        }
    }

    /// A folder with thousands of entries: listing it, folding chains, and the first rows' cells.
    func testAFolderOfThousandsOfEntriesInTheExplorer() throws {
        let root = TestSupport.temporaryDirectory("feather-perf-tree")
        roots.append(root)
        var files: [String: String] = [:]
        for index in 0..<2_000 { files["file\(index).txt"] = "" }
        for index in 0..<300 { files["folder\(index)/only/inner/leaf\(index).txt"] = "" }      // 300 chains to fold
        try TestSupport.write(files, under: root)
        let controller = SidebarViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = controller.view
        defer { window.contentView = nil }
        let outline = controller.outlineViewForTests
        timed("list 2,300 entries with 300 chains", limit: 2.0) {
            controller.setRoot(root)
            controller.view.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(outline.numberOfRows, 2_300)
        XCTAssertEqual((outline.item(atRow: 0) as? FileNode)?.displayName, "folder0 › only › inner")
        // What scrolling costs: every page of rows, each made (or reused) and laid out as it comes into view.
        var pages = 0
        timed("scroll through 2,300 rows page by page", limit: 2.0) {
            var row = 0
            while row < outline.numberOfRows {
                outline.scrollRowToVisible(row)
                outline.layoutSubtreeIfNeeded()
                let visible = outline.rows(in: outline.visibleRect)
                for index in visible.location..<(visible.location + visible.length) { _ = outline.view(atColumn: 0, row: index, makeIfNecessary: true) }
                row += max(1, visible.length)
                pages += 1
            }
        }
        XCTAssertGreaterThan(pages, 50)
        // What a git refresh costs: the visible rows are configured again, a hundred times over.
        timed("100 redraws of the visible rows", limit: 1.0) {
            for _ in 0..<100 { controller.redrawRowsForTests() }
        }
        // Making a cell outright, as the first scroll into a folder does, is a small fixed cost per row.
        timed("1,000 cells made and configured", limit: 0.5) {
            for index in 0..<1_000 {
                let cell = ExplorerCellView()
                cell.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
                cell.label.stringValue = "file\(index).txt"
                cell.mark.stringValue = index % 3 == 0 ? "M" : ""
                cell.layoutSubtreeIfNeeded()
            }
        }
        timed("reveal the last file", limit: 1.0) {
            controller.reveal(root.appendingPathComponent("folder299/only/inner/leaf299.txt"))
        }
        XCTAssertEqual((outline.item(atRow: outline.selectedRow) as? FileNode)?.name, "leaf299.txt")
    }

    func testAVeryDeepChainFoldsAndLabelsQuickly() throws {
        let root = TestSupport.temporaryDirectory("feather-perf-chain")
        roots.append(root)
        let path = (0..<120).map { "d\($0)" }.joined(separator: "/")          // short names: paths are limited to 1024 bytes
        try TestSupport.write(["\(path)/leaf.txt": ""], under: root)
        let controller = SidebarViewController()
        _ = controller.view
        var label = NSAttributedString()
        timed("fold and label a 120-level chain", limit: 1.0) {
            controller.setRoot(root)
            let chain = controller.outlineViewForTests.item(atRow: 0) as! FileNode
            XCTAssertEqual(chain.compactedNames.count, 119)
            label = SidebarViewController.chainLabel(for: chain, color: .white)
        }
        XCTAssertTrue(label.string.hasPrefix("d0 › d1 › "))
        XCTAssertTrue(label.string.hasSuffix(" › d119"))
        timed("reveal through the chain", limit: 1.0) {
            controller.reveal(root.appendingPathComponent("\(path)/leaf.txt"))
        }
        XCTAssertEqual(controller.outlineViewForTests.numberOfRows, 2)
    }

    func testDrawingTheCountBadgeAThousandTimes() {
        let bar = ActivityBar()
        bar.setItems(SidebarContainerViewController.builtInItems)
        let index = SidebarContainerViewController.sourceControlPane
        let button = bar.subviews.compactMap { $0 as? NSStackView }.first!.arrangedSubviews[index] as! ActivityButton
        let image = NSImage(size: button.bounds.size)
        timed("1,000 badge draws", limit: 2.0) {
            for count in 1...1_000 {
                bar.setBadge(count, at: index)
                image.lockFocus()
                button.draw(button.bounds)
                image.unlockFocus()
            }
        }
        XCTAssertEqual(button.badge, 1_000)
    }
}
