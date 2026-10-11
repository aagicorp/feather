import AppKit
import Darwin
import SwiftTerm

/// A terminal that accepts dropped files and folders by typing their paths, the way Terminal.app and VS Code
/// do. That is what makes "drag a file onto the Claude Code prompt" work.
final class DropTerminalView: LocalProcessTerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .string])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func payload(_ sender: NSDraggingInfo) -> String? {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map { DropTerminalView.shellQuoted($0.path) }.joined(separator: " ") + " "
        }
        return pasteboard.string(forType: .string)
    }

    /// Plain paths are left as they are; anything a shell would split or expand is single-quoted.
    static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+=:@%,")
        if !path.isEmpty, path.unicodeScalars.allSatisfy(safe.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        payload(sender) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        payload(sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let text = payload(sender) else { return false }
        send(txt: text)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        return true
    }

    // MARK: - ⌘-click on a file path

    /// Receives the file a ⌘-click pointed at, with the one-based line and column when the output gave them.
    var onOpenFile: ((URL, Int?, Int?) -> Void)?
    /// The folder open in the window: the fallback for relative paths, and where stack-frame file names are looked for.
    var projectRoot: URL?
    private var pressPoint: NSPoint?
    /// True while `super.mouseUp` runs for a click this class is opening itself, so SwiftTerm does not also hand
    /// the same path to the Finder's default app.
    private var isOpeningLink = false

    override func mouseDown(with event: NSEvent) {
        pressPoint = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        onFocus?()
    }

    /// Plain clicks, drags and clicks in programs that read the mouse themselves (vim, htop) go straight to
    /// SwiftTerm. Only a ⌘-click that did not move, on text that names a file, is taken here.
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        var link: TerminalLink?
        if event.modifierFlags.contains(.command), onOpenFile != nil, let pressPoint,
           abs(pressPoint.x - point.x) < 3, abs(pressPoint.y - point.y) < 3,
           !(allowMouseReporting && getTerminal().mouseMode != .off) {
            // A printed `curl` line is "Add to API" while the API client is on (APIDevTouches.swift); the
            // address in it must not open in the browser as well.
            if ExtensionRegistry.shared.isEnabled(APIClientExtension.self), let window, let command = curlCommand(at: point) {
                self.pressPoint = nil
                isOpeningLink = true
                super.mouseUp(with: event)
                isOpeningLink = false
                NotificationCenter.default.post(name: APIClientExtension.curlCommandClicked, object: self,
                                                userInfo: ["command": command, "window": window])
                return
            }
            link = self.link(at: point)
        }
        pressPoint = nil
        guard let link else {
            super.mouseUp(with: event)
            copySelectionIfWanted()
            return
        }
        let directories = workingDirectories() + [projectRoot].compactMap { $0 }
        isOpeningLink = true
        super.mouseUp(with: event)
        isOpeningLink = false
        TerminalLinkResolver.resolve(link, directories: directories, projectRoot: projectRoot) { [weak self] url in
            guard let url else { return }
            self?.onOpenFile?(url, link.line, link.column)
        }
    }

    /// Something was copied from this terminal: the text, so a "Copied …" note can say how much.
    var onCopied: ((String) -> Void)?

    /// Copy on Select (Terminal menu, Settings, Command Palette): what was just selected goes to the clipboard.
    private func copySelectionIfWanted() {
        guard Settings.shared.terminalCopyOnSelect, selectionActive, let text = getSelection(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        onCopied?(text)
    }

    /// ⌘C: SwiftTerm copies; the note is added.
    override func copy(_ sender: Any) {
        let text = selectionActive ? getSelection() : nil
        super.copy(sender)
        if let text, !text.isEmpty { onCopied?(text) }
    }

    /// SwiftTerm's own link detection: web addresses still open in the browser (the parser here never claims a
    /// word with `://` in it). A path it found is only passed on when this class is not already opening it.
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if isOpeningLink { return }
        super.requestOpenLink(source: source, link: link, params: params)
    }

    /// The file reference under `point`, provided it is not a folder (those keep SwiftTerm's behaviour).
    private func link(at point: NSPoint) -> TerminalLink? {
        guard let (text, index) = lineText(at: point), let link = TerminalLinkParser.link(in: text, at: index) else { return nil }
        let directories = workingDirectories() + [projectRoot].compactMap { $0 }
        if TerminalLinkResolver.resolveDirectly(link, directories: directories) != nil { return link }
        // Not there as printed. A confident link may still be found by name in the project (a stack frame, a
        // path relative to a sub-module); a bare word that is not a file is just a word.
        return link.isConfident && projectRoot != nil ? link : nil
    }

    /// The text of the line under `point`, with the lines it wrapped from and onto joined back together, and
    /// the UTF-16 offset of the clicked cell in it.
    func lineText(at point: NSPoint) -> (text: String, index: Int)? {
        guard let (row, column) = cell(at: point), let line = logicalLine(containing: row) else { return nil }
        let terminal = getTerminal()
        var index = 0
        for current in line.first..<row {
            index += (terminal.getLine(row: current)?.translateToString(trimRight: false) ?? "").utf16.count
        }
        index += (terminal.getLine(row: row)?.translateToString(startCol: 0, endCol: column) ?? "").utf16.count
        return (line.text, index)
    }

    /// The row and column of the cell under `point`, or nil below the last line.
    private func cell(at point: NSPoint) -> (row: Int, column: Int)? {
        let terminal = getTerminal()
        // The same arithmetic SwiftTerm uses for its cells, which it keeps to itself.
        let cellWidth = font.advancement(forGlyph: font.glyph(withName: "W")).width
        let cellHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let column = max(0, min(terminal.cols - 1, Int(point.x / cellWidth)))
        let row = Int((frame.height - point.y) / cellHeight)
        guard terminal.getLine(row: row) != nil else { return nil }
        return (row, column)
    }

    /// A line as the program printed it: the rows it wrapped over, joined back together.
    private func logicalLine(containing row: Int) -> (first: Int, last: Int, text: String)? {
        let terminal = getTerminal()
        guard row >= 0, terminal.getLine(row: row) != nil else { return nil }
        var first = row, last = row
        while first > 0, terminal.getLine(row: first)?.isWrapped == true { first -= 1 }
        while let next = terminal.getLine(row: last + 1), next.isWrapped { last += 1 }
        var text = ""
        for current in first...last {
            guard let line = terminal.getLine(row: current) else { continue }
            text += line.translateToString(trimRight: current == last)
        }
        return (first, last, text.replacingOccurrences(of: "\0", with: " "))
    }

    /// The `curl` command on the clicked line, with the lines it continues onto (a trailing backslash) and
    /// from, or nil when the line has none.
    private func curlCommand(at point: NSPoint) -> String? {
        guard let (row, _) = cell(at: point), let line = logicalLine(containing: row) else { return nil }
        func continues(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespaces).hasSuffix("\\") }
        var text = line.text
        var first = line.first, last = line.last
        var steps = 0
        while first > 0, steps < 40, let previous = logicalLine(containing: first - 1), continues(previous.text) {
            text = previous.text + "\n" + text
            first = previous.first
            steps += 1
        }
        while continues(text), steps < 80, let next = logicalLine(containing: last + 1) {
            text += "\n" + next.text
            last = next.last
            steps += 1
        }
        return CurlDetection.command(in: text)
    }

    /// Where the foreground program is running, then where the shell is: what a relative path in the output is
    /// relative to. Asked of the system at the moment of the click, so the shell needs no configuration.
    func workingDirectories() -> [URL] {
        guard let process, process.running else { return [] }
        var pids: [pid_t] = []
        if process.childfd >= 0 { pids.append(tcgetpgrp(process.childfd)) }
        pids.append(process.shellPid)
        var found: [URL] = []
        for pid in pids where pid > 0 {
            var info = proc_vnodepathinfo()
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { continue }
            let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let url = URL(fileURLWithPath: path)
            if !path.isEmpty, !found.contains(url) { found.append(url) }
        }
        return found
    }

    // MARK: - Watching the output (TerminalWatch.swift)

    /// Byte count and time of every chunk of output. Numbers only: this runs while `yes` floods the terminal.
    var onOutput: ((Int, CFAbsoluteTime) -> Void)?
    /// The user pressed a key (or pasted) in this terminal.
    var onUserInput: (() -> Void)?
    var onBell: (() -> Void)?
    /// A mark from the shell's own hooks (ShellIntegration.swift): a command started or finished.
    var onShellMark: ((ShellMark) -> Void)?
    /// The user pressed Return: in a shell at its prompt, a command is starting.
    var onReturnKey: (() -> Void)?
    /// The user clicked in this terminal, which gives it the keyboard: in a split group, it is the one in front now.
    var onFocus: (() -> Void)?
    private var urlDetector = LocalURLDetector()
    private var markScanner = ShellMarkScanner()

    override func dataReceived(slice: ArraySlice<UInt8>) {
        let now = CFAbsoluteTimeGetCurrent()
        onOutput?(slice.count, now)
        let urls = urlDetector.scan(slice, at: now)
        let marks = onShellMark == nil ? [] : markScanner.scan(slice)
        super.dataReceived(slice: slice)
        for mark in marks { onShellMark?(mark) }
        guard !urls.isEmpty, let window else { return }
        for url in urls {
            NotificationCenter.default.post(name: .terminalDidDetectURL, object: self, userInfo: ["url": url, "window": window])
        }
    }

    /// Everything sent to the program passes here, including the terminal's own replies to its queries; only
    /// what arrives during a key press is the user.
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if onUserInput != nil, NSApp.currentEvent?.type == .keyDown {
            onUserInput?()
            if data.first == 13, data.count == 1 { onReturnKey?() }
        }
        super.send(source: source, data: data)
    }

    override func bell(source: Terminal) {
        super.bell(source: source)
        onBell?()
    }

    /// The line the cursor is on (or the nearest one above it with text), and whether a selection menu is showing.
    /// Read only once the terminal has gone quiet.
    func lastLine() -> (text: String, showsMenu: Bool) {
        let terminal = getTerminal()
        var text = ""
        var row = terminal.getCursorLocation().y
        let lowest = max(0, row - 3)
        while row >= lowest {
            text = (terminal.getLine(row: row)?.translateToString(trimRight: true) ?? "")
                .replacingOccurrences(of: "\0", with: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { break }
            row -= 1
        }
        var showsMenu = false
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row)?.translateToString(trimRight: true), !line.isEmpty else { continue }
            if TerminalPrompt.isMenuRow(line.replacingOccurrences(of: "\0", with: " ")) { showsMenu = true; break }
        }
        return (text, showsMenu)
    }
}
