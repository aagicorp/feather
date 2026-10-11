import AppKit

/// An AI command-line tool Feather knows how to start in its terminal. Feather never talks to an AI service
/// itself; it only finds the tool the user installed and types its name into a shell.
struct AITool: Equatable {
    /// What the setting stores.
    let id: String
    /// What the user reads: "Claude Code".
    let name: String
    /// The program looked for on the PATH, and what is typed to start it.
    let executable: String
    /// The maker's own install command, shown as text to copy. Feather installs nothing.
    let installCommand: String
    let website: String
}

enum AITools {
    /// In the order "Automatic" prefers them. Adding a tool is adding a row.
    static let all: [AITool] = [
        AITool(id: "claude", name: "Claude Code", executable: "claude",
               installCommand: "curl -fsSL https://claude.ai/install.sh | bash", website: "https://claude.com/claude-code"),
        AITool(id: "codex", name: "Codex", executable: "codex",
               installCommand: "npm install -g @openai/codex", website: "https://developers.openai.com/codex/cli"),
        AITool(id: "gemini", name: "Gemini CLI", executable: "gemini",
               installCommand: "npm install -g @google/gemini-cli", website: "https://github.com/google-gemini/gemini-cli"),
        AITool(id: "aider", name: "aider", executable: "aider",
               installCommand: "python -m pip install aider-install && aider-install", website: "https://aider.chat"),
        AITool(id: "cursor-agent", name: "Cursor Agent", executable: "cursor-agent",
               installCommand: "curl https://cursor.com/install -fsS | bash", website: "https://cursor.com/cli"),
        AITool(id: "opencode", name: "opencode", executable: "opencode",
               installCommand: "curl -fsSL https://opencode.ai/install | bash", website: "https://opencode.ai"),
    ]

    static let automatic = "auto"
    static let custom = "custom"

    /// What Start would run: the name for the button and the terminal, and the text typed into the shell.
    struct Choice: Equatable {
        let name: String
        let command: String
    }

    /// The tools found in `directories`, in table order. The folders are a parameter so this can run off the main
    /// thread on a copy of the shell's PATH, and so tests can point it at a folder of fake programs.
    /// `tools` is a parameter only so tests can look for a made-up tool rather than a real one.
    static func installed(in directories: [String], tools: [AITool] = all) -> [AITool] {
        tools.filter { tool in
            directories.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + tool.executable) }
        }
    }

    /// Applies the `aiTool` setting to what is installed. A chosen tool that is not installed falls back to the
    /// first one that is, so the button never offers something that cannot start.
    static func choice(setting: String, customCommand: String, installed: [AITool]) -> Choice? {
        let command = customCommand.trimmingCharacters(in: .whitespaces)
        if setting == custom, !command.isEmpty {
            // "FOO=bar /opt/tools/aider --model x" is named after aider: settings of the form NAME=value come first.
            let words = command.split(separator: " ").map(String.init)
            let first = words.first { !($0.contains("=") && !$0.hasPrefix("/") && !$0.hasPrefix(".")) } ?? command
            let program = (first as NSString).lastPathComponent
            return Choice(name: all.first { $0.executable == program }?.name ?? program, command: command)
        }
        let tool = installed.first { $0.id == setting } ?? installed.first
        return tool.map { Choice(name: $0.name, command: $0.executable) }
    }

    /// Whether a terminal whose foreground program is `processName`, or which titled itself `title`, is running
    /// one of the tools. This is how a tool the user started by hand is recognised.
    static func toolName(processName: String, title: String) -> String? {
        if let tool = all.first(where: { $0.executable == processName }) { return tool.name }
        return all.first { title.range(of: $0.name, options: .caseInsensitive) != nil }?.name
    }

    // MARK: - Looking, off the main thread

    /// The last answer, so the title bar button can be drawn without touching the disk.
    private(set) static var lastInstalled: [AITool] = []
    static let didChange = Notification.Name("FeatherAIToolsDidChange")
    private static var generation = 0

    /// Looks along the shell's PATH in the background and announces the answer if it changed. Called at launch
    /// and when Feather comes to the front, which is when a tool may just have been installed.
    static func refresh(completion: (([AITool]) -> Void)? = nil) {
        ShellEnvironment.shared.whenReady {
            let directories = ShellEnvironment.shared.pathDirectories
            generation += 1
            let mine = generation
            DispatchQueue.global(qos: .utility).async {
                let found = installed(in: directories)
                DispatchQueue.main.async {
                    // An older look that finishes late still answers its caller; it just does not overwrite newer news.
                    if mine == generation, found != lastInstalled {
                        lastInstalled = found
                        NotificationCenter.default.post(name: didChange, object: nil)
                    }
                    completion?(found)
                }
            }
        }
    }

    static var currentChoice: Choice? {
        choice(setting: Settings.shared.aiTool, customCommand: Settings.shared.aiToolCustomCommand, installed: lastInstalled)
    }

    // MARK: - When nothing is installed

    /// Explains what these tools are and how to get one. Everything in it is text; Feather runs none of it.
    static func makeInstallHelp() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "No AI assistant was found on this Mac"
        alert.informativeText = "An AI assistant is a program that runs in the terminal, reads your project and writes code when you ask it to in plain words. Feather works with whichever one you install: it starts it for you, and shows you what it changed.\n\nTo install one, copy its command, paste it into a terminal and press Return. Then choose Start AI Assistant again."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open a Terminal")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for tool in all {
            let name = NSTextField(labelWithString: tool.name)
            name.font = .systemFont(ofSize: 12, weight: .semibold)
            let command = NSTextField(labelWithString: tool.installCommand)
            command.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            command.isSelectable = true
            command.lineBreakMode = .byTruncatingMiddle
            command.toolTip = tool.installCommand + "\n" + tool.website
            command.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let copy = CopyButton(text: tool.installCommand)
            let row = NSStackView(views: [copy, command])
            row.spacing = 6
            stack.addArrangedSubview(name)
            stack.addArrangedSubview(row)
            stack.setCustomSpacing(2, after: name)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 440, height: CGFloat(all.count) * 46)
        alert.accessoryView = stack
        return alert
    }
}

/// "Copy" next to an install command.
private final class CopyButton: NSButton {
    private let text: String

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        title = "Copy"
        bezelStyle = .recessed
        controlSize = .small
        font = .systemFont(ofSize: 11)
        target = self
        action = #selector(copyText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        title = "Copied"
    }
}

/// "Which assistant?" as a menu: every tool Feather knows (the ones not installed are greyed out), Automatic, and
/// a command of the user's own, so any command-line AI tool can be the one Start AI Assistant runs. It sits in the
/// Terminal menu.
final class AssistantChooser: NSObject, NSMenuDelegate {
    static let shared = AssistantChooser()

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Choose AI Assistant")
        menu.delegate = self
        menu.autoenablesItems = false
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = Settings.shared, installed = AITools.lastInstalled
        func add(_ title: String, id: String, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.isEnabled = enabled
            item.state = settings.aiTool == id ? .on : .off
            menu.addItem(item)
        }
        add("Automatic (the first one installed)", id: AITools.automatic)
        menu.addItem(.separator())
        for tool in AITools.all {
            let found = installed.contains(tool)
            add(found ? tool.name : tool.name + "  (not installed)", id: tool.id, enabled: found)
        }
        menu.addItem(.separator())
        let own = settings.aiToolCustomCommand.trimmingCharacters(in: .whitespaces)
        if !own.isEmpty { add("My command:  " + own, id: AITools.custom) }
        let edit = NSMenuItem(title: own.isEmpty ? "Use Another Command…" : "Change My Command…", action: #selector(editCommand(_:)), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
    }

    @objc private func choose(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { Settings.shared.aiTool = id }
    }

    /// Any program that runs in a terminal will do: another AI tool, a wrapper script, a tool with its own flags.
    @objc private func editCommand(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Which command starts your AI assistant?"
        alert.informativeText = "Type what you would type in the terminal, for example “claude --model opus”, “ollama run qwen3-coder” or the path to your own script. Feather runs it in a new terminal in your project folder."
        alert.addButton(withTitle: "Use This Command")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = Settings.shared.aiToolCustomCommand
        field.placeholderString = "command"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let command = field.stringValue.trimmingCharacters(in: .whitespaces)
        Settings.shared.aiToolCustomCommand = command
        Settings.shared.aiTool = command.isEmpty ? AITools.automatic : AITools.custom
    }
}
