import XCTest
@testable import Feather

/// The explorer against many generated trees: every file shows exactly once, folded chains are exactly the
/// single-folder runs on disk, reveal finds every file, and adding or removing entries keeps that true.
final class FileTreeRandomTests: XCTestCase {
    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
        mutating func chance(_ percent: Int) -> Bool { int(1...100) <= percent }
    }

    private let names = ["src", "main", "java", "com", "aagicorp", "iam", "domain", "service", "api", "web", "resources", "test",
                         "config", "util", "model", "controller", "docs", "scripts", "assets", "images", "lib", "core", "内部", "données", "with space"]
    private let files = ["App.java", "Util.java", "index.ts", "Button.tsx", "pom.xml", "package.json", "README.md", "notes.txt",
                         "application.yml", "deploy.sh", "logo.png", "Résumé.md", "a b.txt"]

    /// Makes a random tree under `root`; returns every file path (relative).
    private func makeTree(_ generator: inout Generator, at root: URL, depth: Int = 0, relative: String = "") throws -> [String] {
        var made: [String] = []
        let folderCount = depth == 0 ? generator.int(3...6) : (depth > 6 ? 0 : generator.int(0...3))
        let fileCount = depth == 0 ? generator.int(1...4) : (generator.chance(45) ? generator.int(1...5) : 0)
        var used = Set<String>()
        for _ in 0..<folderCount {
            let name = names[generator.int(0...(names.count - 1))]
            guard used.insert(name).inserted else { continue }
            let path = relative.isEmpty ? name : relative + "/" + name
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
            // Long single-folder runs are what compact folders exist for: often a folder holds just one folder.
            made += try makeTree(&generator, at: root, depth: depth + 1, relative: path)
        }
        for _ in 0..<fileCount {
            let name = files[generator.int(0...(files.count - 1))]
            guard used.insert(name).inserted else { continue }
            let path = relative.isEmpty ? name : relative + "/" + name
            try "".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
            made.append(path)
        }
        return made
    }

    private func filesOnDisk(_ root: URL) -> Set<String> {
        var found = Set<String>()
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])!
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false {
            found.insert(String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)))
        }
        return found
    }

    private func expandAll(_ outline: NSOutlineView) {
        var row = 0
        while row < outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileNode, node.isDirectory, !outline.isItemExpanded(node) { outline.expandItem(node) }
            row += 1
        }
    }

    /// Every file once; every chain row's folded ancestors had exactly one folder and nothing else.
    private func checkInvariants(_ outline: NSOutlineView, root: URL, seed: UInt64, file: StaticString = #filePath, line: UInt = #line) {
        expandAll(outline)
        var shown: [String] = []
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? FileNode else { continue }
            let relative = String(node.url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            if !node.isDirectory { shown.append(relative) }
            for name in node.compactedNames {
                var ancestor = node.parent
                while let folder = ancestor, folder.name != name { ancestor = folder.parent }
                guard let folded = ancestor else { XCTFail("seed \(seed): folded folder \(name) is not above \(relative)", file: file, line: line); continue }
                let entries = (try? FileManager.default.contentsOfDirectory(atPath: folded.url.path))?.filter { !$0.hasPrefix(".") } ?? []
                XCTAssertEqual(entries.count, 1, "seed \(seed): \(folded.url.lastPathComponent) folded with \(entries)", file: file, line: line)
            }
            XCTAssertFalse(node.isHiddenInChain, "seed \(seed): a folded folder is a row: \(relative)", file: file, line: line)
        }
        XCTAssertEqual(Set(shown), filesOnDisk(root), "seed \(seed)", file: file, line: line)
        XCTAssertEqual(shown.count, Set(shown).count, "seed \(seed): a file is shown twice", file: file, line: line)
    }

    func testManyRandomTrees() throws {
        for seed in UInt64(1)...12 {
            var generator = Generator(state: seed &* 0x9E3779B97F4A7C15)
            let root = TestSupport.temporaryDirectory("feather-random-tree")
            defer { try? FileManager.default.removeItem(at: root) }
            let made = try makeTree(&generator, at: root)
            XCTAssertFalse(made.isEmpty)
            let controller = SidebarViewController()
            _ = controller.view
            controller.setRoot(root)
            let outline = controller.outlineViewForTests
            checkInvariants(outline, root: root, seed: seed)

            // Reveal every file: the selection lands on it, whatever chains lie above.
            for path in made.shuffled().prefix(8) {
                controller.reveal(root.appendingPathComponent(path))
                let selected = outline.item(atRow: outline.selectedRow) as? FileNode
                XCTAssertEqual(selected?.url.standardizedFileURL.path, root.appendingPathComponent(path).standardizedFileURL.path, "seed \(seed): reveal \(path)")
            }

            // Mutations: a file into some folder (folded or not), a folder deleted, a new single-folder run.
            for step in 0..<3 {
                let folders = Set(made.map { ($0 as NSString).deletingLastPathComponent }).filter { !$0.isEmpty }.sorted()
                if let target = folders.isEmpty ? nil : folders[generator.int(0...(folders.count - 1))] {
                    try "".write(to: root.appendingPathComponent(target + "/added\(step).txt"), atomically: true, encoding: .utf8)
                }
                if step == 1, let victim = folders.first(where: { $0.contains("/") }) {
                    try FileManager.default.removeItem(at: root.appendingPathComponent(victim))
                }
                try FileManager.default.createDirectory(at: root.appendingPathComponent("run\(step)/only/one/here"), withIntermediateDirectories: true)
                try "".write(to: root.appendingPathComponent("run\(step)/only/one/here/end.txt"), atomically: true, encoding: .utf8)
                controller.refreshTreeForTests()
                checkInvariants(outline, root: root, seed: seed)
                XCTAssertTrue((0..<outline.numberOfRows).contains { (outline.item(atRow: $0) as? FileNode)?.displayName == "run\(step) › only › one › here" },
                              "seed \(seed): the new run is folded")
            }
        }
    }

    func testALargeMonorepoExpandsQuickly() throws {
        let root = TestSupport.temporaryDirectory("feather-large-tree")
        defer { try? FileManager.default.removeItem(at: root) }
        var count = 0
        for module in ["iam", "gateway", "finance", "comms", "operations", "platform", "mobile-bff", "shared-kernel"] {
            for layer in ["api", "domain", "infrastructure", "application"] {
                let folder = root.appendingPathComponent("\(module)/src/main/java/com/aagicorp/motorcoachx/\(module)/\(layer)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for index in 0..<12 {
                    try "".write(to: folder.appendingPathComponent("\(layer.capitalized)Class\(index).java"), atomically: true, encoding: .utf8)
                    count += 1
                }
            }
            try "".write(to: root.appendingPathComponent("\(module)/pom.xml"), atomically: true, encoding: .utf8)
            count += 1
        }
        let controller = SidebarViewController()
        _ = controller.view
        let started = Date()
        controller.setRoot(root)
        let outline = controller.outlineViewForTests
        expandAll(outline)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(outline.numberOfRows, 8 + 8 + 8 * 4 + count, "modules + chain rows + layers + files and poms")
        XCTAssertLessThan(elapsed, 2, "expanding \(outline.numberOfRows) rows took \(elapsed)s")
        XCTAssertTrue((0..<outline.numberOfRows).contains { (outline.item(atRow: $0) as? FileNode)?.displayName == "src › main › java › com › aagicorp › motorcoachx › iam" })
    }
}
