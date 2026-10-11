import AppKit
import Darwin
import SwiftTerm

/// One shell inside the terminal pane.
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let view: DropTerminalView
    /// Task sessions (started by Run) stay open after their shell exits so the output can be read.
    let isTask: Bool
    let taskTitle: String?
    /// A name the user typed; it wins over everything detected.
    var customName: String?
    /// A colour and an icon the user chose for this terminal's row (Change Color / Change Icon in the list).
    var customColor: NSColor?
    var customIcon: String?
    private(set) var isRunning = false
    private(set) var programTitle = ""        // set by the running program through an escape sequence
    private(set) var processName = ""
    private(set) var directoryName = ""
    /// The branch checked out where this terminal's foreground program is, or nil outside a repository.
    private(set) var branch: String?
    var onExit: ((TerminalSession) -> Void)?
    var onChange: (() -> Void)?
    /// The AI assistant this terminal was opened for ("Claude Code"); nil for an ordinary shell.
    var aiToolName: String?
    /// Identifies this terminal to the notification that was posted about it.
    let token = UUID().uuidString
    /// It finished or asked something while nobody was looking; shown as a dot until the user comes back to it.
    var needsAttention = false
    /// How the program in a task terminal ended; nil while it runs or when the exit was not reported.
    private(set) var lastExitCode: Int32?

    enum WaitReason { case quiet, question(String), bell, finished(exitCode: Int32?) }
    /// When the running command started, by the shell's mark or the Return that launched it; 0 at the prompt.
    private(set) var commandStartedAt: CFAbsoluteTime = 0
    /// The command line as typed, read off the prompt when Return was pressed; nil when it could not be read.
    private(set) var commandText: String?
    /// How the last command ended and when, for the header's "finished in 14 s".
    private(set) var lastEnding: (exitCode: Int32?, seconds: TimeInterval, at: CFAbsoluteTime)?
    /// Without the shell's marks the end of a command is only known once the poll has seen it running.
    private var sawCommandRunning = false
    /// The terminal asked something or stopped after working, until the user types or output resumes.
    private(set) var waitingReason: WaitReason?
    private(set) var workedSeconds: TimeInterval = 0
    /// Something in the header's line changed: a command started or ended, a question appeared, the user typed.
    var onStatusChange: (() -> Void)?
    /// The user set the terminal to work: Return was pressed, or output started flowing after a quiet spell.
    var onWorkStarted: (() -> Void)?
    /// Terminals split side by side share a tag; 0 for a terminal on its own (TerminalGroups.swift).
    var groupTag = 0
    /// Output is flowing since the user last typed: since when, and in how many distinct seconds.
    var isBusy: Bool { activity.isArmed }
    var busySince: CFAbsoluteTime { activity.burstStart }
    var secondsWithOutput: Int { activity.secondsWithOutput }
    /// The shell has printed a mark, so the exact end of each command is known and silence means less.
    private(set) var hasShellIntegration = false
    /// The silence heuristic already spoke for this command; its end needs no second note.
    private var quietSpokeForCommand = false
    /// A command shorter than this is not worth a word when it ends.
    static let minimumNotableCommand: TimeInterval = 3
    /// The terminal went quiet after being busy, asked something, or rang the bell. Whether anyone needs telling
    /// is the pane's decision.
    var onWaiting: ((TerminalSession, WaitReason) -> Void)?
    private var activity = TerminalActivity()
    private var lastBell: CFAbsoluteTime = 0
    private var startedAt: CFAbsoluteTime = 0
    /// Something has been typed here, by the user or by Feather on their behalf (the `cd` on opening a folder
    /// does not count). Until then all the output is the shell starting up.
    private var wasGivenCommand = false

    init(taskTitle: String?) {
        self.taskTitle = taskTitle
        isTask = taskTitle != nil
        view = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        super.init()
        view.processDelegate = self
        view.onOutput = { [weak self] count, now in
            guard let self, self.activity.noteOutput(count, at: now) else { return }
            self.scheduleQuietCheck(after: TimeInterval(Settings.shared.terminalQuietDelay))
            if self.waitingReason != nil { self.waitingReason = nil }
            self.onWorkStarted?()
            self.onStatusChange?()
        }
        view.onUserInput = { [weak self] in
            guard let self else { return }
            self.wasGivenCommand = true
            self.activity.noteInput(at: CFAbsoluteTimeGetCurrent())
            if self.waitingReason != nil {
                self.waitingReason = nil
                self.onStatusChange?()
            }
        }
        view.onBell = { [weak self] in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastBell > 2 else { return }
            self.lastBell = now
            self.onWaiting?(self, .bell)
        }
        view.onReturnKey = { [weak self] in
            guard let self else { return }
            self.onWorkStarted?()
            guard self.commandStartedAt == 0 else { return }
            self.commandStartedAt = CFAbsoluteTimeGetCurrent()          // bash has no start mark; Return stands in
            // The prompt line still shows what was typed; the echo of the Return has not arrived yet.
            self.commandText = self.isAtShellPrompt ? TerminalCommandText.command(fromPromptLine: self.view.lastLine().text) : nil
            self.sawCommandRunning = false
            self.onStatusChange?()
        }
        view.onShellMark = { [weak self] in self?.shellMark($0) }
    }

    private func shellMark(_ mark: ShellMark) {
        hasShellIntegration = true
        let now = CFAbsoluteTimeGetCurrent()
        switch mark {
        case .commandStarted:
            commandStartedAt = now
            quietSpokeForCommand = false
            onStatusChange?()
        case .commandFinished(let code):
            let started = commandStartedAt
            commandStartedAt = 0
            commandText = nil
            if started > 0 { lastEnding = (code, now - started, now) }
            onStatusChange?()
            let spoke = quietSpokeForCommand
            quietSpokeForCommand = false
            guard started > 0, now - started >= TerminalSession.minimumNotableCommand, !spoke, isRunning,
                  Settings.shared.notifyWhenTerminalWaits else { return }
            onWaiting?(self, .finished(exitCode: code))
        }
    }

    /// One timer per burst of output, not per chunk: while output streams this runs once every quiet-delay, sees
    /// that output is still arriving, and sleeps again until the earliest moment the terminal could count as quiet.
    private func scheduleQuietCheck(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.quietCheck() }
    }

    private func quietCheck() {
        guard activity.isArmed else { return }
        let delay = TimeInterval(Settings.shared.terminalQuietDelay)
        let silence = CFAbsoluteTimeGetCurrent() - activity.lastOutput
        if silence < delay - 0.05 {
            scheduleQuietCheck(after: delay - silence)
            return
        }
        // A shell that takes a few seconds to start (and the `cd` typed into it) is not work that has finished;
        // nor is the welcome screen of an assistant Feather has just started.
        let isStartingUp = (!isTask && !wasGivenCommand && activity.burstStart - startedAt < 3)
            || activity.burstStart - assistantStartedAt < 3
        let wasBusy = activity.wasBusy
        let printedSomething = activity.bytes > 0
        activity.disarm()
        guard isRunning, printedSomething, !isStartingUp else { return }
        // With the shell's marks, silence at the prompt is just silence: the end of the command was announced
        // when it happened, and a background job's line is not "done".
        if hasShellIntegration, commandStartedAt == 0 { return }
        let last = view.lastLine()
        let reason: WaitReason
        if TerminalPrompt.isQuestion(last.text) || last.showsMenu {
            reason = .question(last.text)
        } else if wasBusy {
            reason = .quiet
        } else {
            return
        }
        // The header says so whether or not anyone is told.
        waitingReason = reason
        workedSeconds = CFAbsoluteTimeGetCurrent() - activity.burstStart
        onStatusChange?()
        guard Settings.shared.notifyWhenTerminalWaits, onWaiting != nil else { return }
        if case .quiet = reason { quietSpokeForCommand = true }
        onWaiting?(self, reason)
    }

    /// "Claude Code" for a terminal an assistant runs in, however it was started; otherwise the usual name.
    var speakerName: String {
        if let customName { return customName }
        if let tool = aiToolName ?? AITools.toolName(processName: processName, title: programTitle) { return tool }
        // "sleep is waiting" reads oddly; an ordinary program is named in passing.
        return isTask ? name : "The terminal (\(name))"
    }

    /// When the assistant's command was last typed here. The tool takes a moment to replace the shell in the
    /// foreground, and until then the terminal still counts as the assistant's.
    var assistantStartedAt: CFAbsoluteTime = 0

    /// Nothing but the shell is running in the foreground (as far as `refreshProcessInfo` last saw).
    var isAtShellPrompt: Bool { processName.isEmpty || processName == shellName }

    /// Whether an AI assistant is running here: one Feather started, or one the user started by hand. A terminal
    /// whose assistant has quit is a plain shell again, and sentences meant for an assistant must not be typed into it.
    var isAssistant: Bool {
        guard isRunning else { return false }
        if AITools.toolName(processName: processName, title: isAtShellPrompt ? "" : programTitle) != nil { return true }
        guard aiToolName != nil else { return false }
        return !isAtShellPrompt || CFAbsoluteTimeGetCurrent() - assistantStartedAt < 5
    }

    private var shellName: String {
        ((ProcessInfo.processInfo.environment["SHELL"] ?? "zsh") as NSString).lastPathComponent
    }

    var name: String {
        if let customName { return customName }
        if let taskTitle { return taskTitle }
        // A program that names its own window (Claude Code, vim, ssh…) knows best what it is doing.
        if !programTitle.isEmpty, processName != shellName { return programTitle }
        return processName.isEmpty ? shellName : processName
    }

    var detail: String { branch.map { directoryName + "  ⎇ " + $0 } ?? directoryName }

    func start(in directory: String) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        environment.append("TERM_PROGRAM=Feather")
        environment = ShellIntegration.environment(forShell: shell, from: environment)
        view.startProcess(executable: shell, args: [], environment: environment,
                          execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: directory)
        isRunning = true
        startedAt = CFAbsoluteTimeGetCurrent()
        view.getTerminal().setCursorStyle(Settings.shared.terminalCursorBlink ? .blinkBlock : .steadyBlock)
        directoryName = (directory as NSString).lastPathComponent
    }

    /// Asks the system what is running in the foreground of this terminal and where, so the list can say
    /// "node — frontend" without the shell having to be configured to report it.
    func refreshProcessInfo() {
        guard isRunning, let process = view.process, process.childfd >= 0 else { return }
        var pid = tcgetpgrp(process.childfd)
        if pid <= 0 { pid = process.shellPid }
        var nameBuffer = [CChar](repeating: 0, count: 256)
        var newName = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 ? String(cString: nameBuffer) : processName
        if newName.hasPrefix("-") { newName.removeFirst() }
        var info = proc_vnodepathinfo()
        var newDirectory = directoryName
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 {
            let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if !path.isEmpty { newDirectory = (path as NSString).lastPathComponent }
        }
        var newBranch = branch
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 {
            let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if !path.isEmpty { newBranch = Git.branchByReadingHEAD(nearPath: path) }
        }
        if newName != processName || newDirectory != directoryName || newBranch != branch {
            processName = newName
            directoryName = newDirectory
            branch = newBranch
            onChange?()
        }
        // A shell without marks: the command is over when the shell is back in the foreground, provided it was
        // seen away at all (a command over in a moment is not worth a word).
        if !hasShellIntegration, commandStartedAt > 0 {
            let now = CFAbsoluteTimeGetCurrent()
            if !isAtShellPrompt {
                sawCommandRunning = true
            } else if sawCommandRunning || now - commandStartedAt > 2 {
                if sawCommandRunning { lastEnding = (nil, now - commandStartedAt, now) }
                commandStartedAt = 0
                commandText = nil
                sawCommandRunning = false
                onStatusChange?()
            }
        }
    }

    func send(_ text: String, countsAsCommand: Bool = true) {
        guard isRunning else { return }
        if countsAsCommand { wasGivenCommand = true }
        view.send(txt: text)
    }

    /// Types `text` once the shell has drawn its first prompt: it has printed something and then been silent for
    /// a moment. Text typed into a shell that is still starting is echoed twice and, with a slow start-up script,
    /// can arrive in pieces; a command that starts a program must arrive whole. Gives up waiting after 4 seconds.
    func sendWhenShellIsReady(_ text: String, waited: TimeInterval = 0) {
        let now = CFAbsoluteTimeGetCurrent()
        let isSettled = activity.lastOutput > 0 && now - activity.lastOutput > 0.3
        if isSettled || waited >= 4 || !isRunning { return send(text) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.sendWhenShellIsReady(text, waited: waited + 0.15)
        }
    }

    func interrupt() { send("\u{03}") }

    func shutDown() {
        guard isRunning else { return }
        isRunning = false
        view.processDelegate = nil
        view.terminate()
    }

    func applySettings() {
        let settings = Settings.shared
        let theme = settings.theme
        view.font = settings.terminalFont
        view.nativeBackgroundColor = theme.background
        view.backgroundOpacity = Glass.isActive ? 0 : 1        // with glass the panel behind paints the background
        view.nativeForegroundColor = theme.foreground
        view.caretColor = theme.foreground
        view.selectedTextBackgroundColor = theme.selection
        // Steady unless the user asks for blinking. A program can still change it for itself (vim does).
        view.getTerminal().setCursorStyle(settings.terminalCursorBlink ? .blinkBlock : .steadyBlock)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Shells set the title on every prompt and some programs several times a second, usually to the same text.
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard trimmed != programTitle else { return }
        programTitle = trimmed
        onChange?()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
        lastExitCode = exitCode
        onExit?(self)
    }
}
