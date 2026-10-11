import AppKit

/// ⇧⌘P: every menu command and every setting, found by typing a few letters of its name.
final class CommandPaletteController {
    struct Command {
        let title: String
        let detail: String          // a shortcut such as "⌘B", or a setting's state such as "On"
        let run: () -> Void
    }

    private let panel = FilterPanelController(placeholder: "Type a command or setting")
    private weak var hostWindow: NSWindow?

    func show(over window: NSWindow) {
        hostWindow = window
        // Gathered afresh each time: menus and settings may have changed since the palette was last up.
        let commands = settingCommands() + menuCommands()
        panel.show(over: window, items: commands.map { FilterPanelController.Item(title: $0.title, detail: $0.detail) }) {
            commands[$0].run()
        }
    }

    // MARK: - Commands

    /// Walks the menu bar, so anything added to a menu is in the palette without being listed twice in code.
    /// Takes the menu as a parameter so a test can hand it a small one.
    func menuCommands(in main: NSMenu? = NSApp.mainMenu) -> [Command] {
        var found: [Command] = []
        func walk(_ menu: NSMenu, path: [String]) {
            for item in menu.items where !item.isSeparatorItem && !item.isHidden {
                if let submenu = item.submenu {
                    // The app menu's title is the app name, which says nothing; and recent folders come and go.
                    if submenu.title == "Open Recent" { continue }
                    walk(submenu, path: path + [item.title])
                } else if let action = item.action, !item.title.isEmpty {
                    let prefix = path.dropFirst(path.first == "Feather" ? 1 : 0).joined(separator: " ▸ ")
                    let title = prefix.isEmpty ? item.title : prefix + ": " + item.title
                    found.append(Command(title: title, detail: CommandPaletteController.shortcut(of: item)) { [weak self] in
                        // Send it down the main window's responder chain, exactly as if the menu had been used.
                        self?.hostWindow?.makeKeyAndOrderFront(nil)
                        NSApp.sendAction(action, to: item.target, from: item)
                    })
                }
            }
        }
        if let main { walk(main, path: []) }
        return found
    }

    func settingCommands() -> [Command] {
        let settings = Settings.shared
        func toggle(_ name: String, _ value: Bool, _ flip: @escaping () -> Void) -> Command {
            Command(title: "Settings: " + name, detail: value ? "On  — press ↩ to turn off" : "Off  — press ↩ to turn on", run: flip)
        }
        var list = [
            toggle("Ask Before Quitting or Closing a Window", settings.confirmBeforeQuit) { settings.confirmBeforeQuit.toggle() },
            toggle("Ask Before Trusting a New Folder (Restricted Mode)", WorkspaceTrust.shared.isEnabled) { WorkspaceTrust.shared.isEnabled.toggle() },
            toggle("Reopen Windows, Files and Terminals on Launch", settings.restoreSession) { settings.restoreSession.toggle() },
            toggle("Reveal the Open File in the Explorer", settings.revealInExplorer) { settings.revealInExplorer.toggle() },
            toggle("Show Suggestions While Typing", settings.autoSuggest) { settings.autoSuggest.toggle() },
            toggle("⌘-Click Goes to the Definition", settings.commandClickNavigation) { settings.commandClickNavigation.toggle() },
            toggle("Close Brackets and Quotes as You Type", settings.autoCloseBrackets) { settings.autoCloseBrackets.toggle() },
            toggle("Highlight Matching Brackets", settings.matchBrackets) { settings.matchBrackets.toggle() },
            toggle("Trim Trailing Whitespace on Save", settings.trimTrailingWhitespace) { settings.trimTrailingWhitespace.toggle() },
            toggle("End Files with a Newline on Save", settings.insertFinalNewline) { settings.insertFinalNewline.toggle() },
            toggle("Format on Save", settings.formatOnSave) { settings.formatOnSave.toggle() },
            toggle("Blinking Cursor in the Terminal", settings.terminalCursorBlink) { settings.terminalCursorBlink.toggle() },
            toggle("Terminal: Copy on Select", settings.terminalCopyOnSelect) { settings.terminalCopyOnSelect.toggle() },
            toggle("Play a Sound When a Terminal Finishes", settings.terminalSound) { settings.terminalSound.toggle() },
            toggle("Wrap Long Lines", settings.wrapLines) { settings.wrapLines.toggle() },
            toggle("Show Line Numbers", settings.showLineNumbers) { settings.showLineNumbers.toggle() },
            toggle("Insert Spaces When Pressing Tab", settings.useSpaces) { settings.useSpaces.toggle() },
            toggle("Show Git Blame for the Current Line", settings.showBlame) { settings.showBlame.toggle() },
            toggle("Sticky Scroll (Pin the Enclosing Blocks' First Lines)", settings.stickyScroll) { settings.stickyScroll.toggle() },
            toggle("Tell Me When a Terminal Finishes or Asks Something", settings.notifyWhenTerminalWaits) { settings.notifyWhenTerminalWaits.toggle() },
            toggle("Follow Changes (Show Each File as It Is Changed)", settings.followChanges) { settings.followChanges.toggle() },
            toggle("Save a Checkpoint When a Folder Is Opened", settings.autoCheckpoint) { settings.autoCheckpoint.toggle() },
            toggle("Reload the Preview When a File Changes", settings.previewReloadsOnChange) { settings.previewReloadsOnChange.toggle() },
            toggle("Check the Project for Errors After Saving", settings.checkOnSave) { settings.checkOnSave.toggle() },
        ]
        for option in [AITools.automatic] + AITools.all.map(\.id) {
            let name = AITools.all.first { $0.id == option }?.name ?? "Automatic (the first one installed)"
            list.append(Command(title: "Settings: AI Assistant — " + name, detail: option == settings.aiTool ? "Current" : "") {
                settings.aiTool = option
            })
        }
        for mode in AutoSaveController.Mode.allCases {
            list.append(Command(title: "Settings: Auto Save — " + mode.title, detail: mode == settings.autoSaveMode ? "Current" : "") {
                settings.autoSaveMode = mode
            })
        }
        for theme in Theme.all {
            list.append(Command(title: "Theme: " + theme.name, detail: theme.name == settings.themeName ? "Current" : "") {
                settings.themeName = theme.name
            })
        }
        return list
    }

    static func shortcut(of item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let flags = item.keyEquivalentModifierMask
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        switch item.keyEquivalent {
        case " ": text += "Space"
        case "\t": text += "⇥"
        case "\r": text += "↩"
        case "|": text += "\\"         // ⇧⌘\ is stored as its shifted character
        case "\u{F700}": text += "↑"            // NSUpArrowFunctionKey
        case "\u{F701}": text += "↓"
        case "_": text += "-"          // ⌃⇧- is stored as its shifted character
        case "{": text += "["
        case "}": text += "]"
        default:
            if let scalar = item.keyEquivalent.unicodeScalars.first, (0xF704...0xF70F).contains(scalar.value) {
                text += "F\(scalar.value - 0xF703)"
            } else {
                text += item.keyEquivalent.uppercased()
            }
        }
        return text
    }
}
