import AppKit

/// Window-level checks that need a real window: run by `tools/uitest.sh`, never in normal use. With
/// `FEATHER_UITEST=<folder>` in the environment the app drives its first window through the scenarios below,
/// prints one `PASS name` or `FAIL name: why` line per check, writes a PNG of the window per scenario into the
/// folder, and exits (0 when everything passed). Everything happens in scratch folders under `FEATHER_UITEST`;
/// the raw binary uses its own defaults domain, so the user's settings are never touched.
///
/// The harness is a chain of steps with delays because layout, terminals and file watchers settle on the run
/// loop. Add a scenario by appending to `scenarios`; keep each one independent of the others' state.
enum UITestHarness {
    static var isRunning: Bool { ProcessInfo.processInfo.environment["FEATHER_UITEST"] != nil || ProcessInfo.processInfo.environment["FEATHER_SHOTS"] != nil }

    static var failures = 0
    static var output: URL!
    static weak var controller: MainWindowController?
    /// Screenshot mode (FEATHER_SHOTS): no checks, and no picture of the window after each scenario.
    static var isShots = false

    static func runIfRequested(_ controller: MainWindowController) {
        let environment = ProcessInfo.processInfo.environment
        let isPerf = environment["FEATHER_PERF"].map { !$0.isEmpty } ?? false
        // FEATHER_SHOTS=folder: no checks, just the screenshots for the website and the README (UITestHarness+Shots.swift).
        isShots = environment["FEATHER_SHOTS"].map { !$0.isEmpty } ?? false
        guard let path = environment["FEATHER_UITEST"] ?? environment["FEATHER_PERF"] ?? environment["FEATHER_SHOTS"], !path.isEmpty else { return }
        output = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        self.controller = controller
        controller.window?.setFrame(isShots ? NSRect(x: 60, y: 60, width: 1380, height: 860) : NSRect(x: 80, y: 80, width: 1100, height: 700), display: true)
        // A scenario that never finishes must not leave the app running for ever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { report("FAIL harness: timed out"); exit(2) }
        report("PERF window-ready \(Date().timeIntervalSince1970)")
        // FEATHER_UITEST_ONLY=name runs that one scenario, for working on it alone.
        let only = environment["FEATHER_UITEST_ONLY"].flatMap { $0.isEmpty ? nil : $0 }
        let chosen = (isShots ? shotScenarios : isPerf ? perfScenarios : scenarios).filter { only == nil || $0.name == only }
        run(chosen[...])
    }

    // MARK: - Measurements (tools/perf.sh)

    /// Resident memory of this process, in MB.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func perf(_ name: String, _ value: Double, _ unit: String) { report(String(format: "PERF %@ %.1f %@", name, value, unit)) }

    /// Processor time this process has used so far, user and system, in seconds; two readings give a CPU percentage.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    /// Runs `work`, then reports the wall time and the processor time it took under `name`.
    static func measure(_ name: String, _ work: () -> Void) {
        let cpu = cpuSeconds(), wall = CFAbsoluteTimeGetCurrent()
        work()
        perf("\(name)", (CFAbsoluteTimeGetCurrent() - wall) * 1000, "ms")
        perf("\(name)-cpu", (cpuSeconds() - cpu) * 1000, "ms")
    }

    /// Polls between turns of the run loop (a wait inside one main-queue block would stop other main-queue
    /// work, such as a parse result, from ever arriving).
    static func poll(every interval: TimeInterval = 0.05, upTo limit: TimeInterval, _ condition: @escaping () -> Bool,
                             then: @escaping (TimeInterval) -> Void) {
        let started = CFAbsoluteTimeGetCurrent()
        func step() {
            let elapsed = CFAbsoluteTimeGetCurrent() - started
            if condition() || elapsed > limit { then(elapsed); return }
            after(interval, step)
        }
        step()
    }

    /// A 3.8 MB TypeScript file: open, first colouring, one keystroke at a time in the middle of it, memory.
    static func measureEditor(_ controller: MainWindowController, treeSitter: Bool, lines: Int = 30_000, done: @escaping () -> Void) {
        let label = (treeSitter ? "tree" : "regex") + "-\(lines / 1000)k-lines"
        TreeSitterGrammar.isEnabled = treeSitter
        let project = output.appendingPathComponent("big")
        var text = ""
        for index in 0..<lines {
            text += "export function handler\(index)(request: Request<{ id: number }>, next: () => void): Promise<void> { return run(`item-${\(index)}`, next) }\n"
        }
        let file = project.appendingPathComponent("large-\(label).ts")
        try? text.write(to: file, atomically: true, encoding: .utf8)
        let before = footprintMB()
        let openStart = CFAbsoluteTimeGetCurrent()
        controller.editorArea.open(file)
        perf("\(label)-open-file", (CFAbsoluteTimeGetCurrent() - openStart) * 1000, "ms")
        guard let tab = controller.editorArea.currentTab, let editor = tab.editorIfLoaded else { return done() }
        let textView = editor.textView
        // Above the tree's size limit the file keeps regex colouring even when Tree-sitter is on.
        let hasTree = treeSitter && tab.document.syntaxTree != nil
        poll(upTo: 20, { !hasTree || tab.document.syntaxTreeIfLoaded?.current != nil }) { elapsed in
            if hasTree { perf("tree-first-parse-in-app", elapsed * 1000, "ms") } else if treeSitter { report("PERF tree-not-used-above-limit 1 file") }
            textView.setSelectedRange(NSRange(location: text.utf16.count / 2, length: 0))
            let keys = Array("const value = compute(items.map(x => x * 2));")
            var costs: [CFAbsoluteTime] = []
            func typeNext() {
                guard costs.count < keys.count else {
                    perf("\(label)-keystroke-average", costs.reduce(0, +) / Double(costs.count) * 1000, "ms")
                    perf("\(label)-keystroke-worst", (costs.max() ?? 0) * 1000, "ms")
                    perf("\(label)-keystroke-worst-index", Double(costs.firstIndex(of: costs.max() ?? 0) ?? -1), "th key")
                    after(1.5) {
                        perf("\(label)-memory-for-the-file", footprintMB() - before, "MB")
                        check("perf.\(label).keystroke", costs.reduce(0, +) / Double(costs.count) < 0.02)
                        controller.closeTab(nil)
                        TreeSitterGrammar.isEnabled = true
                        after(1) { done() }
                    }
                    return
                }
                let start = CFAbsoluteTimeGetCurrent()
                textView.insertText(String(keys[costs.count]), replacementRange: textView.selectedRange())
                textView.displayIfNeeded()
                costs.append(CFAbsoluteTimeGetCurrent() - start)
                after(0.04, typeNext)          // back to the run loop between keys, as real typing is
            }
            typeNext()
        }
    }

    /// Numbers, not pass/fail: what the release build costs at each step. Thresholds are generous and only
    /// catch a regression of a different order.
    static let perfScenarios: [Scenario] = [
        Scenario(name: "perf-idle") { _, done in
            // Six seconds of nothing, while tools/perf.sh samples the CPU from outside.
            after(6) {
                perf("idle-memory", footprintMB(), "MB")
                done()
            }
        },
        Scenario(name: "perf-extension") { controller, done in
            after(2) {                                           // let the editor scenario's memory settle first
                let before = footprintMB()
                ExtensionRegistry.shared.setEnabled(APIClientExtension.self, true)
                controller.apiShowPane(nil)
                after(1.5) {
                    perf("api-client-on-memory-delta", footprintMB() - before, "MB")
                    ExtensionRegistry.shared.setEnabled(APIClientExtension.self, false)
                    done()
                }
            }
        },
        Scenario(name: "perf-folder") { controller, done in
            let project = output.appendingPathComponent("big")
            try? FileManager.default.removeItem(at: project)
            var count = 0
            for module in 0..<20 {
                for package in ["api", "domain", "infra", "web", "test"] {
                    let folder = project.appendingPathComponent("module\(module)/src/main/java/com/aagicorp/m\(module)/\(package)")
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    for index in 0..<30 {
                        try? "public class C\(index) { int x = \(index); }\n".write(to: folder.appendingPathComponent("C\(index).java"), atomically: true, encoding: .utf8)
                        count += 1
                    }
                }
            }
            let started = CFAbsoluteTimeGetCurrent()
            controller.openFolder(project, asksAboutTrust: false)
            controller.showExplorer(nil)
            after(1.5) {
                perf("open-folder-\(count)-files", (CFAbsoluteTimeGetCurrent() - started - 1.5) * 1000, "ms-plus-settle")
                let outline = controller.sidebarContainer.explorer.outlineViewForTests
                let expandStart = CFAbsoluteTimeGetCurrent()
                var row = 0
                while row < outline.numberOfRows {
                    if let node = outline.item(atRow: row) as? FileNode, node.isDirectory, !outline.isItemExpanded(node) { outline.expandItem(node) }
                    row += 1
                }
                outline.displayIfNeeded()
                perf("expand-all-\(outline.numberOfRows)-rows", (CFAbsoluteTimeGetCurrent() - expandStart) * 1000, "ms")
                after(1) {
                    perf("memory-after-folder", footprintMB(), "MB")
                    check("perf.expand", outline.numberOfRows > count, "\(outline.numberOfRows)")
                    done()
                }
            }
        },
        // The folder from perf-folder is still open: what Feather costs while it just sits there with a project,
        // its tree expanded and a terminal running, which is most of a working day.
        Scenario(name: "perf-idle-project") { controller, done in
            controller.toggleTerminal(nil)
            after(2) {                                            // the shell starts, the first prompt lands
                let cpu = cpuSeconds()
                let seconds = 6.0
                after(seconds) {
                    perf("idle-cpu-with-project-and-terminal", (cpuSeconds() - cpu) / seconds * 100, "%")
                    perf("idle-memory-with-project-and-terminal", footprintMB(), "MB")
                    check("perf.idleCPU", (cpuSeconds() - cpu) / seconds < 0.05, "more than 5 % of a core while idle")
                    controller.toggleTerminal(nil)
                    done()
                }
            }
        },
        // Scrolling: the whole expanded tree a page at a time, and a 10,000-line file a page at a time.
        Scenario(name: "perf-scroll") { controller, done in
            let outline = controller.sidebarContainer.explorer.outlineViewForTests
            measure("scroll-explorer-\(outline.numberOfRows)-rows") {
                var row = 0
                while row < outline.numberOfRows {
                    outline.scrollRowToVisible(row)
                    outline.displayIfNeeded()
                    row += 25
                }
                outline.scrollRowToVisible(0)
                outline.displayIfNeeded()
            }
            let project = output.appendingPathComponent("big")
            var text = ""
            for index in 0..<10_000 { text += "public class Scroll\(index) { int field = \(index); String name = \"item-\(index)\"; }\n" }
            let file = project.appendingPathComponent("Scroll.java")
            try? text.write(to: file, atomically: true, encoding: .utf8)
            controller.editorArea.open(file)
            after(1.5) {
                guard let tab = controller.editorArea.currentTab, let editor = tab.editorIfLoaded else { return done() }
                measure("scroll-editor-10k-lines") {
                    for line in stride(from: 1, through: 10_000, by: 60) {
                        editor.goToLine(line)
                        editor.scrollView.displayIfNeeded()
                    }
                    editor.goToLine(1)
                }
                controller.closeTab(nil)
                after(0.5) { done() }
            }
        },
        // Tabs opened and closed by the dozen, three times over: the memory must come back each time.
        Scenario(name: "perf-tabs-churn") { controller, done in
            let project = output.appendingPathComponent("big")
            var files: [URL] = []
            for module in 0..<4 { for index in 0..<10 { files.append(project.appendingPathComponent("module\(module)/src/main/java/com/aagicorp/m\(module)/api/C\(index).java")) } }
            let before = footprintMB()
            var round = 0
            var peak = 0.0
            func nextRound() {
                guard round < 3 else {
                    after(1.5) {
                        perf("tabs-churn-memory-left-after-3x40", footprintMB() - before, "MB")
                        perf("tabs-churn-memory-peak", peak - before, "MB")
                        check("perf.tabsChurn", footprintMB() - before < 60, "\(footprintMB() - before) MB stayed behind")
                        done()
                    }
                    return
                }
                round += 1
                measure("tabs-open-40-round\(round)") { files.forEach { controller.editorArea.open($0) } }
                peak = max(peak, footprintMB())
                measure("tabs-close-40-round\(round)") { controller.editorArea.closeAllTabs() }
                after(0.8, nextRound)
            }
            nextRound()
        },
        Scenario(name: "perf-editor") { controller, done in
            measureEditor(controller, treeSitter: true, done: done)
        },
        Scenario(name: "perf-editor-medium") { controller, done in
            measureEditor(controller, treeSitter: true, lines: 7_000, done: done)
        },
        Scenario(name: "perf-editor-regex") { controller, done in
            measureEditor(controller, treeSitter: false, done: done)
        },
    ]
}

/// The same run-loop wait the tests use, for the harness.
enum TestSupportWait {
    @discardableResult
    static func wait(upTo seconds: TimeInterval, for condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }
}

extension UITestHarness {

    static func run(_ remaining: ArraySlice<Scenario>) {
        guard let scenario = remaining.first, let controller else {
            print(failures == 0 ? "UITEST: all passed" : "UITEST: \(failures) failed")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        scenario.body(controller) {
            if !isShots { snapshot(scenario.name) }          // the screenshot scenarios take their own pictures
            run(remaining.dropFirst())
        }
    }

    struct Scenario {
        let name: String
        /// Calls `done` when finished, on the main queue.
        let body: (MainWindowController, @escaping () -> Void) -> Void
    }

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition { report("PASS \(name)") } else {
            failures += 1
            let why = detail()
            report("FAIL \(name)" + (why.isEmpty ? "" : ": " + why))
        }
    }

    static func report(_ line: String) {
        print(line)
        fflush(stdout)
    }

    static func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// A fresh project folder with a couple of source files, for scenarios that need one.
    static func makeProject(_ name: String) -> URL {
        let root = output.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try? "export function loadUsers(id: number) { return id }\nexport class UserService {\n  fetchAll() { return [] }\n}\n"
            .write(to: root.appendingPathComponent("src/users.ts"), atomically: true, encoding: .utf8)
        try? "class Invoice:\n    def total(self):\n        return 0\n\ndef build_invoice(items):\n    return Invoice()\n"
            .write(to: root.appendingPathComponent("billing.py"), atomically: true, encoding: .utf8)
        return root
    }

    /// The window's layer, as the title bar and every pane (except the terminal's text, which renders white).
    static func snapshot(_ name: String, window given: NSWindow? = nil) {
        guard let window = given ?? controller?.window, let layer = window.contentView?.superview?.layer else { return }
        window.displayIfNeeded()
        // The window as the screen shows it, from the window server: the terminal (drawn with Metal) and the
        // glass are in it, which rendering the layer tree misses. An app may capture its own windows without
        // the Screen Recording permission. Rendering the layers is the fallback.
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
           image.width > 1 {
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
            return
        }
        let size = layer.bounds.size, scale = window.backingScaleFactor
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            layer.render(in: context.cgContext)
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
    }

    // MARK: - Scenarios

    static let scenarios: [Scenario] = [
        // Launched with --safe (or Shift held): nothing from last time reopened, and the notice says so.
        Scenario(name: "safe") { controller, done in
            guard CommandLine.arguments.contains("--safe") else { return done() }
            check("safe.noFolder", !controller.hasFolder)
            check("safe.noTabs", controller.editorArea.currentTab == nil)
            check("safe.notice", WindowNotices.cards(in: controller.window).contains { $0.kind == "safe-mode" })
            done()
        },
        Scenario(name: "header") { controller, done in
            let project = makeProject("header")
            controller.openFolder(project, asksAboutTrust: false)
            after(0.8) {
                guard let window = controller.window else { return done() }
                check("header.height", window.contentView?.frame.height == window.frame.height, "content view should fill the window")
                check("header.titleHidden", window.titleVisibility == .hidden)
                controller.editorArea.open(project.appendingPathComponent("src/users.ts"))
                after(0.5) {
                    check("header.tabOpened", controller.editorArea.currentTab?.url?.lastPathComponent == "users.ts")
                    controller.toggleSidebarPane(nil)
                    after(0.5) {
                        controller.toggleSidebarPane(nil)
                        after(0.5, done)
                    }
                }
            }
        },
        Scenario(name: "terminals") { controller, done in
            controller.toggleTerminal(nil)
            controller.newTerminal(nil)
            controller.newTerminal(nil)
            after(1.2) {
                let terminals = controller.terminals
                check("terminals.count", terminals.sessions.count == 3, "\(terminals.sessions.count)")
                terminals.sessions[2].customName = "third"
                // Pressing a row that is not selected (the press that begins a drag) must keep the row views: a
                // reload there replaces them under the pointer and the drag never starts.
                let table = terminals.listTable
                let rowsBefore = (0..<table.numberOfRows).map { table.rowView(atRow: $0, makeIfNecessary: true) }
                terminals.select(2)
                let rowsAfter = (0..<table.numberOfRows).map { table.rowView(atRow: $0, makeIfNecessary: false) }
                check("terminals.selectKeepsRows", rowsBefore.count == 3 && zip(rowsBefore, rowsAfter).allSatisfy { $0 === $1 } && table.selectedRow == 2,
                      "\(rowsBefore.count) rows, selected \(table.selectedRow)")
                let moved = terminals.move(terminalAt: 2, to: 0)          // the bottom row to the top
                check("terminals.reorder", moved && terminals.sessions.first?.customName == "third" && terminals.selectedIndex == 0,
                      "moved \(moved), first \(terminals.sessions.first?.customName ?? "-"), selected \(terminals.selectedIndex)")
                let height = terminals.view.frame.height
                controller.toggleTerminalMaximized(nil)
                after(0.5) {
                    check("terminals.maximized", controller.isTerminalMaximized && terminals.view.frame.height > height + 100,
                          "height \(terminals.view.frame.height) vs \(height)")
                    controller.toggleTerminalMaximized(nil)
                    after(0.5) {
                        check("terminals.restored", !controller.isTerminalMaximized && abs(terminals.view.frame.height - height) < 2,
                              "height \(terminals.view.frame.height) vs \(height)")
                        controller.splitTerminal(nil)
                        after(0.8) {
                            check("terminals.split", terminals.visibleSessions.count == 2, "\(terminals.visibleSessions.count) visible")
                            done()
                        }
                    }
                }
            }
        },
        // Dragging a terminal up or down the list with the mouse: a press on a row that is not selected changes
        // the selection, and whatever that does must not stop the drag from starting (terminals.selectKeepsRows
        // covers the rows; this is the whole path, with mouse events). The drop itself needs the system's drag
        // tracking, which these events cannot drive, so what is checked is that the drag begins.
        Scenario(name: "terminal-drag") { controller, done in
            // Three terminals in no groups, whatever the scenarios before left behind.
            controller.showTerminal()
            while controller.terminals.sessions.count > 1 { controller.terminals.remove(at: controller.terminals.sessions.count - 1) }
            while controller.terminals.sessions.count < 3 { controller.newTerminal(nil) }
            after(1.2) {
                let terminals = controller.terminals
                let table = terminals.listTable
                guard terminals.sessions.count == 3, let window = table.window else { check("terminalDrag.setup", false, "\(terminals.sessions.count) terminals"); return done() }
                terminals.select(0)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                // Activation lands a moment later; a press before it only brings the window forward.
                after(0.5) { run() }
            }
            func run() {
                let terminals = controller.terminals
                let table = terminals.listTable
                guard let window = table.window else { return done() }
                // Real mouse events need Feather in front; when someone is using the Mac meanwhile, the presses
                // go elsewhere. That is not a failure of the list, so the scenario stands down and says so.
                guard NSApp.isActive, window.isKeyWindow else {
                    report("SKIP terminal-drag: Feather is not the front app (the Mac is in use); run it alone with FEATHER_UITEST_ONLY=terminal-drag")
                    return done()
                }
                func point(row: Int, dy: CGFloat = 0) -> CGPoint {
                    let rect = table.rect(ofRow: row)
                    let onScreen = window.convertPoint(toScreen: table.convert(NSPoint(x: rect.minX + 40, y: rect.midY + dy), to: nil))
                    return CGPoint(x: onScreen.x, y: NSScreen.screens[0].frame.height - onScreen.y)      // CG: origin top-left
                }
                func post(_ type: CGEventType, _ at: CGPoint) {
                    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
                }
                func drag(from: Int, to: Int, then: @escaping () -> Void) {
                    let start = point(row: from), end = point(row: to, dy: from > to ? -8 : 8)
                    post(.leftMouseDown, start)
                    for step in 1...8 {
                        let t = CGFloat(step) / 8
                        after(0.03 * Double(step)) { post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)) }
                    }
                    after(0.4) { post(.leftMouseUp, end) }
                    after(0.9, then)
                }
                for (index, session) in terminals.sessions.enumerated() { session.customName = ["first", "second", "third"][index] }
                func names() -> [String] { terminals.sessions.map { $0.customName ?? "?" } }
                let begunBefore = terminals.dragsBegunForTests, dropsBefore = terminals.dropsForTests
                drag(from: 0, to: 2) {
                    check("terminalDrag.selectedRowBegins", terminals.dragsBegunForTests == begunBefore + 1, "\(terminals.dragsBegunForTests - begunBefore) drags began")
                    check("terminalDrag.selectedRowDropped", terminals.dropsForTests == dropsBefore + 1 && names() == ["second", "third", "first"],
                          "drops \(terminals.dropsForTests - dropsBefore), order \(names())")
                    let before = terminals.dragsBegunForTests, drops = terminals.dropsForTests
                    let bottom = terminals.sessions.count - 1
                    terminals.select(0)
                    drag(from: bottom, to: 0) {
                        check("terminalDrag.unselectedRowBegins", terminals.dragsBegunForTests == before + 1, "\(terminals.dragsBegunForTests - before) drags began")
                        check("terminalDrag.bottomToTop", terminals.dropsForTests == drops + 1 && names().first == "first",
                              "drops \(terminals.dropsForTests - drops), order \(names())")
                        // The pointer usually overshoots the first row into the header above the list, and past
                        // the last row below it: a drop there lands at the top and at the end.
                        let rowHeight = table.rect(ofRow: 0).height
                        let drops2 = terminals.dropsForTests
                        let start = point(row: bottom), above = point(row: 0, dy: -rowHeight * 1.5)
                        post(.leftMouseDown, start)
                        for step in 1...8 {
                            let t = CGFloat(step) / 8
                            after(0.03 * Double(step)) { post(.leftMouseDragged, CGPoint(x: start.x, y: start.y + (above.y - start.y) * t)) }
                        }
                        after(0.4) { post(.leftMouseUp, above) }
                        after(0.9) {
                            check("terminalDrag.aboveTheListLandsAtTheTop", terminals.dropsForTests == drops2 + 1 && names().first == "third",
                                  "drops \(terminals.dropsForTests - drops2), order \(names())")
                            done()
                        }
                    }
                }
            }
        },
        Scenario(name: "symbols") { controller, done in
            guard let root = controller.projectRoot else { check("symbols.root", false, "no folder"); return done() }
            controller.workspaceSymbols.entries(root: root) { entries in
                let names = entries.map(\.symbol.name)
                check("symbols.found", names.contains("loadUsers") && names.contains("build_invoice") && names.contains("fetchAll"), names.joined(separator: ","))
                NSApp.activate(ignoringOtherApps: true)          // the panel hides when another app is in front
                controller.showWorkspaceSymbols(typed: "")
                after(0.8) {
                    let panel = controller.workspaceSymbolPanel
                    if NSApp.isActive {
                        check("symbols.panel", panel.isVisible && !panel.matches(for: "inv").isEmpty)
                    } else {
                        report("SKIP symbols.panel: Feather is not the front app (the Mac is in use), and the panel hides then")
                    }
                    panel.onChoose?(panel.matches(for: "build").first ?? 0)
                    after(0.5) {
                        check("symbols.jump", controller.editorArea.currentTab?.url?.lastPathComponent == "billing.py"
                              && controller.editorArea.currentTab?.editorIfLoaded?.cursorPosition.line == 5,
                              "\(controller.editorArea.currentTab?.url?.lastPathComponent ?? "-") \(controller.editorArea.currentTab?.editorIfLoaded?.cursorPosition ?? (0, 0))")
                        done()
                    }
                }
            }
        },
        Scenario(name: "git") { controller, done in
            let repo = output.appendingPathComponent("repo")
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            func git(_ arguments: [String]) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = arguments
                process.currentDirectoryURL = repo
                try? process.run()
                process.waitUntilExit()
            }
            git(["init", "-q"])
            try? "hi\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            git(["add", "."])
            git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"])
            var refreshes = 0
            let observer = NotificationCenter.default.addObserver(forName: Git.repositoryDidChange, object: nil, queue: .main) { _ in refreshes += 1 }
            controller.openFolder(repo, asksAboutTrust: false)
            controller.showSourceControl(nil)                      // the pane's button only exists once the pane is shown
            after(2) {
                // A repository with no remote: the pane's one button offers to publish, as VS Code's does.
                check("git.publishOffered", controller.sourceControl.primaryTitleForTests == "Publish Branch", controller.sourceControl.primaryTitleForTests)
                let before = refreshes
                git(["checkout", "-q", "-b", "feature/x"])
                // Changes in the list: a header with its count, rows with name, folder and letter, actions on hover.
                try? FileManager.default.createDirectory(at: repo.appendingPathComponent("src/views"), withIntermediateDirectories: true)
                try? "changed\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
                try? "new\n".write(to: repo.appendingPathComponent("src/views/Panel.swift"), atomically: true, encoding: .utf8)
                try? "doc\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
                after(2.5) {
                    let pane = controller.sourceControl
                    let outline = pane.outlineViewForTests
                    func row(_ index: Int) -> ChangeRowView? { outline.view(atColumn: 0, row: index, makeIfNecessary: true) as? ChangeRowView }
                    check("git.changesHeader", row(0)?.label.stringValue == "Changes" && row(0)?.count.text == "3",
                          "\(row(0)?.label.stringValue ?? "none") \(row(0)?.count.text ?? "")")
                    let panel = (0..<outline.numberOfRows).compactMap(row).first { $0.label.stringValue == "Panel.swift" }
                    check("git.rowFolderAndLetter", panel?.detail.stringValue == "src/views" && panel?.letter.stringValue == "U",
                          "\(panel?.detail.stringValue ?? "none") \(panel?.letter.stringValue ?? "")")
                    check("git.actionsOnHoverOnly", panel?.actionsHiddenForTests == true, "shown without the pointer")
                    (outline as? ChangesOutlineView)?.setHovered(outline.numberOfRows - 1)
                    check("git.placeholderNamesBranch", pane.messagePlaceholderForTests.contains("feature/x"), pane.messagePlaceholderForTests)
                    check("git.badgeCount", controller.activityBar.badge(at: SidebarContainerViewController.sourceControlPane) == 3,
                          "\(controller.activityBar.badge(at: SidebarContainerViewController.sourceControlPane))")
                    snapshot("source-control")
                    (outline as? ChangesOutlineView)?.setHovered(-1)
                }
                after(2.5) {
                    NotificationCenter.default.removeObserver(observer)
                    check("git.refreshOnCheckout", refreshes > before, "\(refreshes) vs \(before)")
                    check("git.terminalBranch", controller.terminals.sessions.first?.branch == "feature/x",
                          controller.terminals.sessions.first?.branch ?? "nil")
                    done()
                }
            }
        },
        // A Mac without Xcode or the Command Line Tools: opening a repository must not hang (the system git
        // stub would block on Apple's install dialog), the panes say what is missing, and everything fills in
        // once git turns up.
        // A merge that git could not finish: the editor tints the block and offers the three Accept buttons,
        // the Source Control pane says what to do, and Accept Incoming resolves the file.
        Scenario(name: "conflict") { controller, done in
            let repo = output.appendingPathComponent("conflict")
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            func git(_ arguments: [String]) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + arguments
                process.currentDirectoryURL = repo
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }
            func write(_ text: String, _ name: String = "greeting.txt") { try? text.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8) }
            git(["init", "-q"])
            write("hello\nworld\n"); git(["add", "."]); git(["commit", "-qm", "start"])
            git(["checkout", "-qb", "feature/greeting"])
            write("hello there\nworld\n"); git(["commit", "-qam", "feature greeting"])
            git(["checkout", "-q", "main"])
            write("hello everyone\nworld\n"); git(["commit", "-qam", "main greeting"])
            git(["merge", "feature/greeting"])                        // conflicts; the merge stays in progress
            controller.openFolder(repo, asksAboutTrust: false)
            controller.showSourceControl(nil)
            after(1.0) {
                controller.editorArea.open(repo.appendingPathComponent("greeting.txt"))
                after(1.2) {
                    guard let tab = controller.editorArea.currentTab, let editor = tab.editorIfLoaded else { check("conflict.editorOpen", false); return done() }
                    editor.conflicts.update()
                    check("conflict.found", editor.conflicts.conflicts.count == 1, "\(editor.conflicts.conflicts.count)")
                    let actions = editor.conflicts.actionViews.first
                    let visible = actions.map { !$0.isHiddenOrHasHiddenAncestor && editor.textView.visibleRect.intersects($0.frame) } ?? false
                    check("conflict.buttonsOnScreen", visible, "\(actions?.frame ?? .zero) in \(editor.textView.visibleRect)")
                    check("conflict.tinted", editor.textView.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: editor.conflicts.conflicts.first?.current.location ?? 0, effectiveRange: nil) != nil)
                    let pane = controller.sourceControl
                    poll(upTo: 8, { pane.statusForTests.isMerging && pane.statusForTests.conflicts.count == 1 }) { _ in
                        check("conflict.paneSays", pane.primaryTitleForTests == "Resolve 1 Conflict First", pane.primaryTitleForTests)
                        snapshot("conflict-before")                 // the tinted block and its buttons, before resolving
                        editor.conflicts.resolve(0, .incoming)
                        check("conflict.resolved", editor.document.text == "hello there\nworld\n", editor.document.text)
                        check("conflict.buttonsGone", editor.conflicts.actionViews.isEmpty)
                        done()
                    }
                }
            }
        },
        Scenario(name: "nogit") { controller, done in
            let repo = output.appendingPathComponent("repo")           // left behind by the git scenario
            let savedPaths = Git.developerPaths, savedAsks = Git.asksXcodeSelect, savedExecutable = Git.executable
            Git.developerPaths = []
            Git.asksXcodeSelect = false
            Git.executable = nil
            var announced = false
            let observer = NotificationCenter.default.addObserver(forName: Git.availabilityDidChange, object: nil, queue: .main) { _ in announced = true }
            controller.openFolder(repo, asksAboutTrust: false)
            controller.editorArea.open(repo.appendingPathComponent("a.txt"))
            after(1.5) {
                check("nogit.opened", controller.editorArea.currentTab?.url?.lastPathComponent == "a.txt")
                check("nogit.noBranch", controller.statusBar.branch == nil)
                controller.showSourceControl(nil)
                controller.sourceControl.refresh()
                after(0.5) {
                    check("nogit.message", controller.sourceControl.emptyStateTextForTests == Git.notInstalledMessage,
                          controller.sourceControl.emptyStateTextForTests)
                    // The tools get installed while Feather runs.
                    Git.developerPaths = savedPaths
                    Git.asksXcodeSelect = savedAsks
                    Git.recheck()
                    check("nogit.recovered", Git.executable == savedExecutable && announced)
                    poll(upTo: 5, { controller.statusBar.branch != nil }) { _ in
                        NotificationCenter.default.removeObserver(observer)
                        check("nogit.branchBack", controller.statusBar.branch?.name == "feature/x", controller.statusBar.branch?.name ?? "nil")
                        poll(upTo: 5, { !controller.sourceControl.isShowingEmptyStateForTests }) { _ in
                            check("nogit.paneBack", !controller.sourceControl.isShowingEmptyStateForTests, "Source Control still shows the install message")
                            done()
                        }
                    }
                }
            }
        },
        // A Java-style tree: single-folder chains fold into one row, the column fits the sidebar however deep
        // the tree, and the git marks stay in view at the right edge.
        Scenario(name: "tree") { controller, done in
            let project = output.appendingPathComponent("deep")
            try? FileManager.default.removeItem(at: project)
            let deep = project.appendingPathComponent("iam/src/main/java/com/aagicorp/motorcoachx/iam/domain/membership/service")
            try? FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            for name in ["MembershipService.java", "MembershipValidationService.java", "MembershipLifecycleService.java"] {
                try? "class X {}\n".write(to: deep.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            try? "".write(to: project.appendingPathComponent("iam/pom.xml"), atomically: true, encoding: .utf8)
            // More shapes: a chain stopped by a file, a folder with two folders, an empty chain, many files.
            for path in ["frontend/src/index.ts", "frontend/src/components/Button.tsx", "frontend/src/components/Input.tsx", "frontend/package.json",
                         "iam/src/main/resources/application.yml", "scripts/deploy.sh", "scripts/backup.sh", "README.md", "one/two/three/notes.txt"] {
                let file = project.appendingPathComponent(path)
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? "".write(to: file, atomically: true, encoding: .utf8)
            }
            try? FileManager.default.createDirectory(at: project.appendingPathComponent("empty/inner"), withIntermediateDirectories: true)
            // A repository with everything committed and one deep file changed, so the marks can be checked.
            func git(_ arguments: [String]) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-c", "user.email=harness@example.com", "-c", "user.name=Harness", "-c", "commit.gpgsign=false"] + arguments
                process.currentDirectoryURL = project
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }
            git(["init", "-q"]); git(["add", "-A"]); git(["commit", "-q", "-m", "start"])
            try? "class X { int y; }\n".write(to: deep.appendingPathComponent("MembershipValidationService.java"), atomically: true, encoding: .utf8)
            controller.openFolder(project, asksAboutTrust: false)
            controller.showExplorer(nil)
            after(0.8) {
                controller.editorArea.open(deep.appendingPathComponent("MembershipValidationService.java"))
                after(1.0) {
                    let outline = controller.sidebarContainer.explorer.outlineViewForTests
                    let names = (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? FileNode)?.displayName }
                    let chain = "java › com › aagicorp › motorcoachx › iam › domain › membership › service"
                    check("tree.compactChain", names.contains(chain), names.joined(separator: " | "))
                    check("tree.stopsAtTwoFolders", names.contains("src › main") && names.contains("resources"), names.joined(separator: " | "))
                    check("tree.topLevel", names.contains("empty › inner") && names.contains("one › two › three") && names.contains("frontend") && names.contains("README.md"), names.joined(separator: " | "))
                    check("tree.revealed", (outline.item(atRow: outline.selectedRow) as? FileNode)?.name == "MembershipValidationService.java")
                    let clip = outline.enclosingScrollView?.contentView
                    let clipWidth = clip?.bounds.width ?? 0
                    check("tree.scrollsSideways", (outline.tableColumns.first?.width ?? 0) > clipWidth && abs(outline.frame.width - (outline.tableColumns.first?.width ?? 0)) < 1,
                          "column \(outline.tableColumns.first?.width ?? 0), outline \(outline.frame.width), visible \(clipWidth)")
                    func badge(_ row: Int) -> NSTextField? {
                        guard row >= 0 else { return nil }
                        return outline.view(atColumn: 0, row: row, makeIfNecessary: false)?.subviews.first { $0.identifier == SidebarViewController.badgeIdentifier } as? NSTextField
                    }
                    poll(upTo: 10, { badge(outline.selectedRow)?.stringValue == "M" }) { _ in
                        let mark = badge(outline.selectedRow)
                        let inView = mark.flatMap { mark -> Bool? in
                            guard let clip else { return nil }
                            let rect = mark.convert(mark.bounds, to: clip)
                            return rect.maxX <= clip.bounds.maxX + 0.5 && rect.minX >= clip.bounds.minX
                        } ?? false
                        check("tree.gitMarkVisible", mark?.stringValue == "M" && inView, "mark '\(mark?.stringValue ?? "none")' at \(mark.map { $0.convert($0.bounds, to: clip) } ?? .zero) in \(clip?.bounds ?? .zero)")
                        let chainRow = names.firstIndex(of: chain) ?? -1
                        check("tree.folderDot", badge(chainRow)?.stringValue == "•", "'\(badge(chainRow)?.stringValue ?? "none")'")
                        let count = controller.activityBar.badge(at: SidebarContainerViewController.sourceControlPane)
                        check("tree.sourceControlCount", count == 1, "\(count)")
                        done()
                    }
                }
            }
        },
        // Switching the API client extension on adds its pane and menu; off takes them away.
        Scenario(name: "extensions") { controller, done in
            let registry = ExtensionRegistry.shared
            // The Requests pane is on when nothing was ever switched: with no stored choice the default lists
            // it, and switching it on from there gives the window its menu. (An earlier run of this scenario may
            // have left a choice stored; it is cleared first.)
            UserDefaults.standard.removeObject(forKey: "enabledExtensions")
            check("extensions.onByDefault", Settings.shared.enabledExtensions == [APIClientExtension.id], Settings.shared.enabledExtensions.joined(separator: ","))
            registry.setEnabled(APIClientExtension.self, true)
            let menuTitles = NSApp.mainMenu?.items.map(\.title) ?? []
            check("extensions.onGivesTheMenu", controller.apiClient != nil && menuTitles.contains("Requests"),
                  "controller \(controller.apiClient == nil ? "missing" : "present"), menus \(menuTitles.joined(separator: "|")), active \(NSApp.isActive)")
            registry.setEnabled(APIClientExtension.self, false)
            let before = NSApp.mainMenu?.items.map(\.title) ?? []
            check("extensions.switchedOff", controller.apiClient == nil && !before.contains("Requests"))
            registry.setEnabled(APIClientExtension.self, true)
            after(0.5) {
                let titles = NSApp.mainMenu?.items.map(\.title) ?? []
                check("extensions.menuAdded", titles.contains("Requests"), titles.joined(separator: ","))
                check("extensions.controller", controller.apiClient?.pane != nil)
                controller.apiShowPane(nil)
                after(0.5) {
                    check("extensions.paneShown", controller.apiClient?.pane?.view.window != nil)
                    // A collection with one request, opened in a tab, for the render.
                    if let client = controller.apiClient {
                        client.workspace.load()
                        var request = APIRequest(name: "Validate session", url: "http://localhost:8080/api/v1/user/validate")
                        request.headers = [APIKeyValue("Accept", "application/json")]
                        client.workspace.save(APICollection(name: "MotorCoach API", items: [.request(request)]))
                        client.pane?.openScratchRequest(request)
                    }
                    after(0.8) {
                        // The redesigned request screen: tabs with counts, the environment chip, the answer header waiting.
                        if let view = controller.apiClient?.pane?.frontRequestView {
                            let items = view.sectionsForTests.items
                            check("extensions.tabCounts", items.map(\.title) == ["Params", "Headers", "Body", "Auth", "Checks", "Variables"] && items[1].badge == "1",
                                  items.map { "\($0.title) \($0.badge ?? "-")" }.joined(separator: ", "))
                            check("extensions.environmentChip", view.environmentChipTitleForTests == "No environment", view.environmentChipTitleForTests)
                            check("extensions.answerHeaderHidden", view.response.isHeaderHiddenForTests)
                        } else {
                            check("extensions.requestOpen", false, "no request tab in front")
                        }
                        snapshot("extensions-api")
                        registry.setEnabled(APIClientExtension.self, false)
                        after(0.5) {
                            let titles = NSApp.mainMenu?.items.map(\.title) ?? []
                            check("extensions.removed", controller.apiClient == nil && !titles.contains("Requests"))
                            registry.setEnabled(APIClientExtension.self, true)
                            done()
                        }
                    }
                }
            }
        },
        // A small history with a side branch and a merge, shown in the Source Control pane's graph: the rows'
        // text should start right after each row's own lanes (ragged), not after the widest row.
        Scenario(name: "graph") { controller, done in
            let repo = output.appendingPathComponent("repo")
            @discardableResult
            func git(_ arguments: [String]) -> String {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-c", "user.email=t@t", "-c", "user.name=t"] + arguments
                process.currentDirectoryURL = repo
                let pipe = Pipe()
                process.standardOutput = pipe
                try? process.run()
                process.waitUntilExit()
                return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            for step in 1...3 {
                try? "b\(step)\n".write(to: repo.appendingPathComponent("b\(step).txt"), atomically: true, encoding: .utf8)
                git(["add", "."]); git(["commit", "-qm", "On the feature branch, commit \(step)"])
            }
            // A main line from the first commit, whatever the default branch is called on this machine.
            git(["checkout", "-q", "-b", "mainline", git(["rev-list", "--max-parents=0", "HEAD"])])
            try? "m\n".write(to: repo.appendingPathComponent("m.txt"), atomically: true, encoding: .utf8)
            git(["add", "."]); git(["commit", "-qm", "A change on the main line while the branch was open"])
            git(["merge", "-q", "--no-edit", "feature/x"])
            for step in 1...4 {
                try? "n\(step)\n".write(to: repo.appendingPathComponent("n\(step).txt"), atomically: true, encoding: .utf8)
                git(["add", "."]); git(["commit", "-qm", "After the merge, commit \(step) on one lane"])
            }
            controller.window?.setFrame(NSRect(x: 80, y: 40, width: 1100, height: 900), display: true)
            controller.showSourceControl(nil)
            after(6) {
                check("graph.paneShown", controller.window?.contentView?.subviews.isEmpty == false)
                done()
            }
        },
    ]
}
