import AppKit

/// The command the user just entered, read off the prompt line as Return was pressed.
enum TerminalCommandText {
    /// What shells end their prompts with, most telling first. "> " and "# " come last because a command can
    /// contain them ("echo a > b"); the others hardly ever appear inside one.
    private static let markers = ["❯ ", "➜ ", "» ", "% ", "$ ", "> ", "# "]
    /// A right-hand prompt (the time, the branch) sits after a stretch of blank cells; a typed command never has
    /// three spaces in a row.
    private static let rightPrompt = try! NSRegularExpression(pattern: #"\s{3,}\S.*$"#)
    static let maxLength = 60

    /// The text after the prompt, or nil when the line holds no command (an empty Return, or no prompt found).
    static func command(fromPromptLine line: String) -> String? {
        var text = line.replacingOccurrences(of: "\0", with: " ")
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        // The first marker of the most telling kind: a prompt comes before the command, and a command that
        // contains a marker of its own comes after it.
        var cut: String.Index?
        for marker in markers {
            if let range = text.range(of: marker) { cut = range.upperBound; break }
        }
        guard let cut else { return nil }
        text = String(text[cut...])
        text = rightPrompt.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: text.utf16.count), withTemplate: "")
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// A command shortened to fit the header.
    static func shortened(_ command: String) -> String {
        command.count <= maxLength ? command : String(command.prefix(maxLength - 1)) + "…"
    }
}

/// What the terminal in front is doing, as one short line for the header: the running command and how long it
/// has run, how the last one ended, or what the assistant is up to. Pure: the pane feeds it numbers.
struct TerminalStatusInput: Equatable {
    struct Ending: Equatable {
        var exitCode: Int32?
        var seconds: TimeInterval
        /// How long ago it ended; the note is shown for a while, then goes.
        var age: TimeInterval
    }

    /// "Claude Code" when an assistant runs here; the assistant's states then win over the shell's marks.
    var assistantName: String?
    /// Output is flowing (since the user last typed): in how many distinct seconds, and for how long.
    var isBusy = false
    var secondsWithOutput = 0
    var busySeconds: TimeInterval = 0
    /// The assistant asked something (nil seconds) or went quiet after working (how long it worked).
    var isWaiting = false
    var workedSeconds: TimeInterval?
    var command: String?
    var commandSeconds: TimeInterval = 0
    var ending: Ending?
}

enum TerminalStatusText {
    enum Tone { case neutral, good, bad }
    /// How long "finished" and "exit 1" stay in the header.
    static let endingLingers: TimeInterval = 10
    /// A command over in less than this (and successfully) is not worth a word.
    static let minimumNotableSeconds: TimeInterval = 1
    /// Output in fewer distinct seconds than this is an echo, not the assistant working.
    static let minimumWorkingSeconds = 2

    static func describe(_ input: TerminalStatusInput) -> (text: String, tone: Tone)? {
        if let name = input.assistantName {
            if input.isWaiting {
                guard let worked = input.workedSeconds else { return ("\(name) · waiting for you", .neutral) }
                return ("\(name) · stopped after \(duration(worked))", .neutral)
            }
            if input.isBusy, input.secondsWithOutput >= minimumWorkingSeconds { return ("\(name) · working \(duration(input.busySeconds))", .neutral) }
            return nil
        }
        if let command = input.command {
            return ("▶ \(TerminalCommandText.shortened(command)) · \(duration(input.commandSeconds))", .neutral)
        }
        if let ending = input.ending, ending.age < endingLingers {
            switch ending.exitCode {
            case .some(0):
                guard ending.seconds >= minimumNotableSeconds else { return nil }
                return ("✓ finished in \(duration(ending.seconds))", .good)
            case .some(let code):
                return ("✕ exit \(code) · \(duration(ending.seconds))", .bad)
            case .none:
                guard ending.seconds >= minimumNotableSeconds else { return nil }
                return ("finished in \(duration(ending.seconds))", .neutral)
            }
        }
        return nil
    }

    /// Whether the line changes as the clock runs, so the pane knows when a timer is worth having.
    static func isLive(_ input: TerminalStatusInput) -> Bool {
        if input.assistantName != nil { return input.isBusy && !input.isWaiting }
        if input.command != nil { return true }
        if let ending = input.ending { return ending.age < endingLingers }
        return false
    }

    /// "12 s", "2 m 14 s", "1 h 05 m".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        if total < 60 { return "\(total) s" }
        if total < 3600 {
            let rest = total % 60
            return rest == 0 ? "\(total / 60) m" : "\(total / 60) m \(rest) s"
        }
        return "\(total / 3600) h " + String(format: "%02d m", total % 3600 / 60)
    }
}

/// The label in the terminal header that carries the line, and the one-second clock behind it. The clock runs
/// only while the line has a time in it and the pane is on screen; the pane calls `refresh` on every event that
/// could change the line and the clock keeps it current in between.
final class TerminalStatusStrip {
    let label = NSTextField(labelWithString: "")
    /// What to show now; nil means nothing is going on.
    var input: () -> TerminalStatusInput? = { nil }
    var isOnScreen: () -> Bool = { false }
    private var timer: Timer?
    private var lastText: String?

    init() {
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    func refresh() {
        let current = isOnScreen() ? input() : nil
        let described = current.flatMap(TerminalStatusText.describe)
        let text = described?.text ?? ""
        if text != lastText {
            lastText = text
            let theme = Settings.shared.theme
            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: theme.lineNumber])
            if let tone = described?.tone, tone != .neutral, !text.isEmpty {
                let color = tone == .good ? NSColor(hex: 0x3FB950) : NSColor(hex: 0xF14C4C)
                attributed.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: 1))
            }
            label.attributedStringValue = attributed
            label.toolTip = text.isEmpty ? nil : text
        }
        if let current, TerminalStatusText.isLive(current), isOnScreen() {
            startClock()
        } else {
            stopClock()
        }
    }

    private func startClock() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.2
    }

    private func stopClock() {
        timer?.invalidate()
        timer = nil
    }
}
