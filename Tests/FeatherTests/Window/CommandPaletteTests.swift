/// Covers Window/CommandPalette.swift: the command list built from a menu (titles with their menu path,
/// shortcuts, what is left out) and the setting toggles that sit alongside the menu commands.
import XCTest
@testable import Feather

final class CommandPaletteTests: XCTestCase {
    private func item(_ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [], hidden: Bool = false,
                      action: Selector? = Selector(("doSomething:"))) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.isHidden = hidden
        return item
    }

    /// A menu bar the shape of Feather's: the app menu, File with a submenu, and things the palette must skip.
    private func fixture() -> NSMenu {
        let main = NSMenu(title: "MainMenu")
        let app = NSMenuItem(title: "Feather", action: nil, keyEquivalent: "")
        app.submenu = NSMenu(title: "Feather")
        app.submenu?.addItem(item("About Feather"))
        app.submenu?.addItem(item("Settings…", ",", [.command]))
        main.addItem(app)

        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        file.submenu = NSMenu(title: "File")
        file.submenu?.addItem(item("New File", "n", [.command]))
        file.submenu?.addItem(.separator())
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recent.submenu = NSMenu(title: "Open Recent")
        recent.submenu?.addItem(item("/Users/somebody/project"))
        file.submenu?.addItem(recent)
        let export = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        export.submenu = NSMenu(title: "Export")
        export.submenu?.addItem(item("As PDF…", "p", [.command, .shift]))
        file.submenu?.addItem(export)
        file.submenu?.addItem(item("Hidden Alias", "w", [.command, .option], hidden: true))
        file.submenu?.addItem(item("No Action", action: nil))
        file.submenu?.addItem(item("", "x", [.command]))
        file.submenu?.addItem(item("Close Window", "w", [.command, .shift]))
        main.addItem(file)
        return main
    }

    func testMenuCommandsCarryTheirPathAndShortcut() {
        let commands = CommandPaletteController().menuCommands(in: fixture())
        XCTAssertEqual(commands.map(\.title), ["About Feather", "Settings…", "File: New File", "File ▸ Export: As PDF…", "File: Close Window"])
        XCTAssertEqual(commands.map(\.detail), ["", "⌘,", "⌘N", "⇧⌘P", "⇧⌘W"])
    }

    func testNoMenuMeansNoCommands() {
        XCTAssertTrue(CommandPaletteController().menuCommands(in: nil).isEmpty)
        XCTAssertTrue(CommandPaletteController().menuCommands(in: NSMenu(title: "Empty")).isEmpty)
    }

    func testShortcutsAreWrittenAsTheMenuShowsThem() {
        typealias C = CommandPaletteController
        XCTAssertEqual(C.shortcut(of: item("x", "p", [.command, .shift])), "⇧⌘P")
        XCTAssertEqual(C.shortcut(of: item("x", "\r", [.command])), "⌘↩")
        XCTAssertEqual(C.shortcut(of: item("x", " ", [.control])), "⌃Space")
        XCTAssertEqual(C.shortcut(of: item("x", "\t", [.control, .shift])), "⌃⇧⇥")
        XCTAssertEqual(C.shortcut(of: item("x", "|", [.command, .shift])), "⇧⌘\\")
        XCTAssertEqual(C.shortcut(of: item("x", "_", [.control, .shift])), "⌃⇧-")
        XCTAssertEqual(C.shortcut(of: item("x", "{", [.command, .shift])), "⇧⌘[")
        XCTAssertEqual(C.shortcut(of: item("x", "\u{F700}", [.option, .command])), "⌥⌘↑")
        XCTAssertEqual(C.shortcut(of: item("x", "\u{F701}", [.option])), "⌥↓")
        XCTAssertEqual(C.shortcut(of: item("x", String(UnicodeScalar(NSF5FunctionKey)!), [])), "F5")
        XCTAssertEqual(C.shortcut(of: item("x", String(UnicodeScalar(NSF12FunctionKey)!), [.shift])), "⇧F12")
        XCTAssertEqual(C.shortcut(of: item("x", "`", [.control])), "⌃`")
        XCTAssertEqual(C.shortcut(of: item("x")), "")
    }

    func testSettingTogglesAreListed() {
        let commands = CommandPaletteController().settingCommands()
        let titles = commands.map(\.title)
        XCTAssertTrue(titles.contains("Settings: Wrap Long Lines"))
        XCTAssertTrue(titles.contains("Settings: Show Line Numbers"))
        XCTAssertTrue(titles.contains("Settings: Ask Before Trusting a New Folder (Restricted Mode)"))
        XCTAssertTrue(titles.contains("Settings: AI Assistant — Automatic (the first one installed)"))
        XCTAssertTrue(titles.contains("Settings: Auto Save — After a Delay"))
        XCTAssertTrue(titles.allSatisfy { $0.hasPrefix("Settings: ") || $0.hasPrefix("Theme: ") })
        XCTAssertEqual(Set(titles).count, titles.count, "no command is listed twice")

        // A toggle says what it will do; a choice says which one is current.
        let wrap = commands.first { $0.title == "Settings: Wrap Long Lines" }
        XCTAssertEqual(wrap?.detail, Settings.shared.wrapLines ? "On  — press ↩ to turn off" : "Off  — press ↩ to turn on")
        let current = commands.filter { $0.title.hasPrefix("Theme: ") && $0.detail == "Current" }
        XCTAssertLessThanOrEqual(current.count, 1)
        XCTAssertEqual(current.first?.title, current.isEmpty ? nil : "Theme: " + Settings.shared.themeName)
        XCTAssertEqual(commands.filter { $0.title.hasPrefix("Theme: ") }.count, Theme.all.count)
        XCTAssertEqual(commands.filter { $0.title.hasPrefix("Settings: Auto Save — ") }.count, AutoSaveController.Mode.allCases.count)
    }

    func testRunningAToggleFlipsTheSetting() {
        let before = Settings.shared.confirmBeforeQuit
        defer { Settings.shared.confirmBeforeQuit = before }
        let command = CommandPaletteController().settingCommands().first { $0.title == "Settings: Ask Before Quitting or Closing a Window" }
        XCTAssertNotNil(command)
        command?.run()
        XCTAssertEqual(Settings.shared.confirmBeforeQuit, !before)
        // The list is gathered afresh each time, so the new state shows.
        let again = CommandPaletteController().settingCommands().first { $0.title == command?.title }
        XCTAssertEqual(again?.detail.hasPrefix("On"), !before)
    }
}
