/// Covers App/ThemeImport.swift (VS Code theme import, the Feather theme file, ThemeStore), App/KeyBindings.swift
/// (portable shortcuts, conflicts, overrides) and App/Settings.swift (the settings store, further down).
import XCTest
import AppKit
@testable import Feather

final class VSCodeThemeImportTests: XCTestCase {
    /// A cut-down theme in the shape VS Code ships them: JSON with comments, a trailing comma, scopes given
    /// as strings, comma-separated strings and arrays, and a translucent selection.
    private let sample = """
    {
        // Ocean-ish test theme
        "name": "Ocean Test",
        "type": "dark",
        "colors": {
            "editor.background": "#0B1622",
            "editor.foreground": "#C0CAF5",
            "editorLineNumber.foreground": "#3B4261",
            "editorLineNumber.activeForeground": "#737AA2",
            "editor.selectionBackground": "#FFFFFF80",
            "sideBar.background": "#16161E",
            "panel.border": "#101014",
            "focusBorder": "#7AA2F7",
        },
        "tokenColors": [
            { "scope": "comment.line", "settings": { "foreground": "#111111" } },
            { "scope": "comment", "settings": { "foreground": "#565F89" } },
            { "scope": "string, constant.character", "settings": { "foreground": "#9ECE6A" } },
            { "scope": ["constant.numeric", "constant.language"], "settings": { "foreground": "#FF9E64" } },
            { "scope": "keyword.control", "settings": { "foreground": "#BB9AF7" } },
            { "scope": "source.js entity.name.function", "settings": { "foreground": "#7AA2F7" } },
            { "scope": "support.class", "settings": { "fontStyle": "italic" } }
        ]
    }
    """

    private func hex(_ color: NSColor) -> String { color.hexString }

    func testMapsColoursAndScopes() throws {
        let theme = try VSCodeTheme.theme(from: sample, fallbackName: "fallback")
        XCTAssertEqual(theme.name, "Ocean Test")
        XCTAssertTrue(theme.isDark)
        XCTAssertEqual(hex(theme.background), "#0B1622")
        XCTAssertEqual(hex(theme.foreground), "#C0CAF5")
        XCTAssertEqual(hex(theme.lineNumber), "#3B4261")
        XCTAssertEqual(hex(theme.activeLineNumber), "#737AA2")
        XCTAssertEqual(hex(theme.chrome), "#16161E")
        XCTAssertEqual(hex(theme.border), "#101014")
        XCTAssertEqual(theme.accentColor.map(hex), "#7AA2F7")
        XCTAssertEqual(hex(theme.comment), "#565F89")          // the rule for "comment" beats the one for "comment.line"
        XCTAssertEqual(hex(theme.string), "#9ECE6A")
        XCTAssertEqual(hex(theme.number), "#FF9E64")
        XCTAssertEqual(hex(theme.keyword), "#BB9AF7")          // a child scope serves when there is no rule for the parent
        XCTAssertEqual(hex(theme.function), "#7AA2F7")         // the last selector of a descendant selector counts
        XCTAssertEqual(hex(theme.type), hex(Theme.builtIns[0].type))     // no foreground given: filled from Dark
    }

    func testTranslucentSelectionIsPaintedOverTheBackground() throws {
        let theme = try VSCodeTheme.theme(from: sample, fallbackName: "x")
        let selection = try XCTUnwrap(theme.selection.usingColorSpace(.sRGB))
        XCTAssertEqual(selection.alphaComponent, 1)
        XCTAssertEqual(hex(theme.selection), "#858B91")        // white at 50 % over #0B1622
    }

    func testDarknessComesFromTheBackgroundWhenTypeIsMissing() throws {
        let theme = try VSCodeTheme.theme(from: ##"{ "colors": { "editor.background": "#FAFAFA" } }"##, fallbackName: "Paper")
        XCTAssertFalse(theme.isDark)
        XCTAssertEqual(theme.name, "Paper")
        XCTAssertEqual(hex(theme.keyword), hex(Theme.builtIns[1].keyword))
    }

    func testNotAThemeIsRefused() {
        XCTAssertThrowsError(try VSCodeTheme.theme(from: ##"{ "color": "#123456" }"##, fallbackName: "x"))
        XCTAssertThrowsError(try VSCodeTheme.theme(from: "not json", fallbackName: "x"))
    }

    func testFeatherFormatRoundTripsThroughTheStore() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("feather-theme-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ThemeStore(directory: folder)
        let imported = try VSCodeTheme.theme(from: sample, fallbackName: "x")
        try store.save(imported)
        XCTAssertEqual(store.themes.map(\.name), ["Ocean Test"])
        let reloaded = try XCTUnwrap(ThemeStore(directory: folder).themes.first)
        for (a, b) in zip([imported.background, imported.foreground, imported.selection, imported.comment, imported.function, imported.type],
                          [reloaded.background, reloaded.foreground, reloaded.selection, reloaded.comment, reloaded.function, reloaded.type]) {
            XCTAssertEqual(hex(a), hex(b))
        }
        XCTAssertEqual(reloaded.accentColor.map(hex), "#7AA2F7")
        XCTAssertFalse(reloaded.isBuiltIn)

        // A built-in's name is not taken over.
        let clash = try store.save(Theme(name: "Dark", isDark: true, colors: [:]))
        XCTAssertEqual(clash.name, "Dark (imported)")
        XCTAssertEqual(store.themes.map(\.name), ["Dark (imported)", "Ocean Test"])
        store.delete(named: "Ocean Test")
        XCTAssertEqual(store.themes.map(\.name), ["Dark (imported)"])
    }

    func testBuiltInsAreFiveAndTheDefaultIsFirst() {
        XCTAssertEqual(Theme.builtIns.map(\.name), ["Dark", "Light", "Midnight", "Solarized Dark", "GitHub Light"])
        XCTAssertTrue(Theme.all.count >= 5)
        XCTAssertTrue(Theme.builtIns.allSatisfy(\.isBuiltIn))
    }
}

final class KeyBindingTests: XCTestCase {
    func testPortableRoundTrip() {
        let cases: [(KeyBinding, String)] = [
            (KeyBinding(key: "p", modifiers: [.command, .shift]), "shift+cmd+p"),
            (KeyBinding(key: "\r", modifiers: [.command]), "cmd+enter"),
            (KeyBinding(key: "\u{F700}", modifiers: [.option]), "alt+up"),
            (KeyBinding(key: "`", modifiers: [.control, .shift]), "ctrl+shift+`"),
            (KeyBinding(key: String(UnicodeScalar(NSF12FunctionKey)!), modifiers: []), "f12"),
            (KeyBinding(key: "+", modifiers: [.command]), "cmd++"),
            (KeyBinding(key: " ", modifiers: [.control]), "ctrl+space"),
        ]
        for (binding, text) in cases {
            XCTAssertEqual(binding.portable, text)
            XCTAssertEqual(KeyBinding(portable: text), binding, text)
        }
    }

    func testOtherSpellingsAreUnderstood() {
        XCTAssertEqual(KeyBinding(portable: "Cmd+Shift+P"), KeyBinding(key: "p", modifiers: [.command, .shift]))
        XCTAssertEqual(KeyBinding(portable: "command+option+f2"), KeyBinding(key: String(UnicodeScalar(NSF2FunctionKey)!), modifiers: [.command, .option]))
        XCTAssertNil(KeyBinding(portable: "cmd+"))
        XCTAssertNil(KeyBinding(portable: "hyper+p"))
        XCTAssertNil(KeyBinding(portable: "cmd+nosuchkey"))
    }

    func testUppercaseLetterMeansShift() {
        let binding = KeyBinding(key: "P", modifiers: [.command])
        XCTAssertEqual(binding, KeyBinding(key: "p", modifiers: [.command, .shift]))
        XCTAssertEqual(binding.display, "⇧⌘P")
    }

    func testDisplay() {
        XCTAssertEqual(KeyBinding(key: "|", modifiers: [.command, .shift]).display, "⇧⌘\\")
        XCTAssertEqual(KeyBinding(key: "\u{F701}", modifiers: [.command, .option]).display, "⌥⌘↓")
        XCTAssertEqual(KeyBinding(key: String(UnicodeScalar(NSF12FunctionKey)!), modifiers: [.shift]).display, "⇧F12")
        XCTAssertEqual(KeyBinding(key: " ", modifiers: [.control]).display, "⌃Space")
    }

    func testBareKeysAreNotUsableExceptFunctionKeysAndEscape() {
        XCTAssertFalse(KeyBinding(key: "a", modifiers: []).isUsable)
        XCTAssertFalse(KeyBinding(key: "a", modifiers: [.shift]).isUsable)
        XCTAssertTrue(KeyBinding(key: "a", modifiers: [.command]).isUsable)
        XCTAssertTrue(KeyBinding(key: String(UnicodeScalar(NSF5FunctionKey)!), modifiers: []).isUsable)
        XCTAssertTrue(KeyBinding(key: "\u{1B}", modifiers: []).isUsable)
    }

    func testConflicts() {
        let save = KeyBinding(key: "s", modifiers: [.command])
        let conflicts = KeyBindings.conflicts(among: [
            ("saveDocument:", save),
            ("gitSync:", KeyBinding(key: "S", modifiers: [.command, .control])),
            ("stashChanges:", save),
            ("runProject:", KeyBinding(key: "r", modifiers: [.command])),
        ])
        XCTAssertEqual(conflicts["saveDocument:"], ["stashChanges:"])
        XCTAssertEqual(conflicts["stashChanges:"], ["saveDocument:"])
        XCTAssertNil(conflicts["gitSync:"])
        XCTAssertNil(conflicts["runProject:"])
    }

    func testOverridesAreAppliedToMenuItemsAndDefaultsRemembered() {
        let bindings = KeyBindings(overrides: ["showCommandPalette:": "ctrl+alt+p", "closeTab:": "none",
                                               "performTextFinderAction:#1": "cmd+shift+f"])
        let palette = NSMenuItem(title: "Command Palette…", action: Selector(("showCommandPalette:")), keyEquivalent: "p")
        palette.keyEquivalentModifierMask = [.command, .shift]
        let close = NSMenuItem(title: "Close Tab", action: Selector(("closeTab:")), keyEquivalent: "w")
        let find = NSMenuItem(title: "Find…", action: Selector(("performTextFinderAction:")), keyEquivalent: "f")
        find.tag = 1
        let findNext = NSMenuItem(title: "Find Next", action: Selector(("performTextFinderAction:")), keyEquivalent: "g")
        findNext.tag = 2
        for item in [palette, close, find, findNext] { bindings.apply(to: item) }

        XCTAssertEqual(palette.keyEquivalent, "p")
        XCTAssertEqual(palette.keyEquivalentModifierMask, [.control, .option])
        XCTAssertEqual(close.keyEquivalent, "")
        XCTAssertEqual(find.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(findNext.keyEquivalent, "g")                  // a different tag is a different command
        XCTAssertEqual(bindings.defaults["showCommandPalette:"] ?? nil, KeyBinding(key: "p", modifiers: [.command, .shift]))
        XCTAssertEqual(bindings.effective["closeTab:"] ?? nil, nil)
        XCTAssertTrue(bindings.isCustom("closeTab:"))
        XCTAssertFalse(bindings.isCustom("performTextFinderAction:#2"))
    }
}

// MARK: - The settings store

/// Settings.swift: registered defaults, clamping, how changes reach observers (coalesced per turn of the run
/// loop, nothing for a value that did not change), reset, recent folders, the saved session, theme lookup and
/// the terminal list's colour fallbacks. Every case has its own UserDefaults suite, so nothing is shared.
final class SettingsStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var settings: Settings!
    private var received: [Settings.Change] = []
    private var observer: NSObjectProtocol?

    override func setUp() {
        super.setUp()
        // Let a notification still pending from an earlier case land before this one starts counting.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        suiteName = "feather-tests-settings-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = Settings(defaults: defaults)
        observer = NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: nil) { [weak self] note in
            self?.received.append(Settings.change(in: note))
        }
    }

    override func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Pumps the run loop until the coalesced notification arrives (or a short while, when none is expected).
    private func settle() {
        _ = TestSupport.wait(upTo: 1) { !self.received.isEmpty }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testDefaultsAreRegistered() {
        XCTAssertEqual(settings.fontName, Settings.systemMonoName)
        XCTAssertEqual(settings.fontSize, 13)
        XCTAssertEqual(settings.themeName, "Dark")
        XCTAssertEqual(settings.tabWidth, 4)
        XCTAssertTrue(settings.useSpaces)
        XCTAssertFalse(settings.wrapLines)
        XCTAssertTrue(settings.showLineNumbers)
        XCTAssertEqual(settings.terminalFontSize, 12)
        XCTAssertEqual(settings.scrollBarSize, 11)
        XCTAssertEqual(settings.autoSaveMode, .off)
        XCTAssertTrue(settings.confirmBeforeQuit)
        XCTAssertTrue(settings.restoreSession)
        XCTAssertFalse(settings.followChanges)
        // Values without a registered default fall back in the getter; the terminal's notification and sound
        // stay off until someone switches them on.
        XCTAssertFalse(settings.terminalSound)
        XCTAssertFalse(settings.notifyWhenTerminalWaits)
        XCTAssertEqual(settings.enabledExtensions, [APIClientExtension.id], "the Requests pane is on from the first launch")
        XCTAssertEqual(settings.terminalQuietDelay, 4)
        XCTAssertEqual(settings.aiTool, AITools.automatic)
        XCTAssertEqual(settings.aiToolCustomCommand, "")
        XCTAssertEqual(settings.keyBindings, [:])
        XCTAssertEqual(settings.savedSession.count, 0)
        XCTAssertEqual(settings.recentFolders, [])
    }

    func testFontSizesAndTabWidthAreClamped() {
        settings.fontSize = 3
        XCTAssertEqual(settings.fontSize, 8)
        settings.fontSize = 99
        XCTAssertEqual(settings.fontSize, 40)
        settings.terminalFontSize = 100
        XCTAssertEqual(settings.terminalFontSize, 32)
        settings.terminalFontSize = 1
        XCTAssertEqual(settings.terminalFontSize, 8)
        settings.tabWidth = 0
        XCTAssertEqual(settings.tabWidth, 1)
        settings.tabWidth = 99
        XCTAssertEqual(settings.tabWidth, 16)
        settings.scrollBarSize = 1
        XCTAssertEqual(settings.scrollBarSize, Settings.scrollBarSizeRange.lowerBound)
        settings.scrollBarSize = 100
        XCTAssertEqual(settings.scrollBarSize, Settings.scrollBarSizeRange.upperBound)
        settings.terminalQuietDelay = 0
        XCTAssertEqual(settings.terminalQuietDelay, 1)
        settings.terminalQuietDelay = 1000
        XCTAssertEqual(settings.terminalQuietDelay, 120)
    }

    func testSeveralChangesInOneTurnReachObserversAsOneNotification() {
        settings.fontSize = 15
        settings.wrapLines = true
        settings.terminalFontSize = 14
        settings.scrollBarSize = 8
        XCTAssertTrue(received.isEmpty, "nothing is posted until the next turn of the run loop")
        settle()
        XCTAssertEqual(received, [[.editor, .terminal, .scrollBars]])
    }

    func testAnUnchangedValueNotifiesNoOne() {
        settings.fontSize = 13                  // the registered default
        settings.themeName = "Dark"
        settings.wrapLines = false
        settle()
        XCTAssertEqual(received, [])
    }

    func testSettingsReadAtTheMomentTheyMatterNotifyNoOne() {
        settings.confirmBeforeQuit = false
        settings.autoSuggest = false
        settings.trimTrailingWhitespace = true
        settings.autoSaveMode = .afterDelay
        settle()
        XCTAssertEqual(received, [])
        XCTAssertFalse(settings.confirmBeforeQuit)
        XCTAssertEqual(settings.autoSaveMode, .afterDelay)
        // The mode is cached; a second store on the same suite reads what was written.
        XCTAssertEqual(Settings(defaults: defaults).autoSaveMode, .afterDelay)
    }

    func testThemeChangeSaysEverything() {
        settings.themeName = "Light"
        settle()
        XCTAssertEqual(received, [.everything])
        XCTAssertEqual(settings.theme.name, "Light")
        XCTAssertFalse(settings.theme.isDark)
    }

    func testResetToDefaultsRestoresValuesAndPostsOnce() {
        settings.fontSize = 20
        settings.themeName = "Midnight"
        settings.tabWidth = 2
        settings.terminalQuietDelay = 30
        settings.aiToolCustomCommand = "my-assistant --resume"
        settle()
        received = []

        settings.resetToDefaults()
        settle()
        XCTAssertEqual(received, [.everything])
        XCTAssertEqual(settings.fontSize, 13)
        XCTAssertEqual(settings.themeName, "Dark")
        XCTAssertEqual(settings.theme.name, "Dark")
        XCTAssertEqual(settings.tabWidth, 4)
        XCTAssertEqual(settings.terminalQuietDelay, 4)
        XCTAssertEqual(settings.aiToolCustomCommand, "")
    }

    func testRecentFoldersAreCappedAndDeDuplicated() {
        var folders: [URL] = []
        for _ in 0..<(Settings.maxRecentFolders + 2) { folders.append(TestSupport.temporaryDirectory("feather-recent")) }
        defer { folders.forEach { try? FileManager.default.removeItem(at: $0) } }
        for folder in folders { settings.noteRecentFolder(folder) }
        XCTAssertEqual(settings.recentFolders.count, Settings.maxRecentFolders)
        XCTAssertEqual(settings.recentFolders.first, folders.last)
        XCTAssertFalse(settings.recentFolders.contains(folders[0]), "the oldest ones fall off the end")

        // Opening a folder again moves it to the front rather than listing it twice.
        settings.noteRecentFolder(folders[5])
        XCTAssertEqual(settings.recentFolders.first, folders[5])
        XCTAssertEqual(settings.recentFolders.filter { $0 == folders[5] }.count, 1)
        XCTAssertEqual(settings.recentFolders.count, Settings.maxRecentFolders)
    }

    func testRecentFoldersThatNoLongerExistAreLeftOut() {
        let kept = TestSupport.temporaryDirectory("feather-recent")
        let gone = TestSupport.temporaryDirectory("feather-recent")
        defer { try? FileManager.default.removeItem(at: kept) }
        settings.noteRecentFolder(gone)
        settings.noteRecentFolder(kept)
        try? FileManager.default.removeItem(at: gone)
        XCTAssertEqual(settings.recentFolders, [kept])
        settings.clearRecentFolders()
        XCTAssertEqual(settings.recentFolders, [])
    }

    func testSavedSessionRoundTrips() {
        let session: [[String: Any]] = [
            ["folder": "/tmp/one", "tabs": ["a.swift", "b.swift"], "terminalOnRight": true],
            ["folder": "/tmp/twö", "tabs": [String](), "width": 640],
        ]
        settings.savedSession = session
        XCTAssertEqual(settings.savedSession as NSArray, session as NSArray)
        XCTAssertEqual(Settings(defaults: defaults).savedSession as NSArray, session as NSArray)
        settings.savedSession = []
        XCTAssertEqual(settings.savedSession.count, 0)
    }

    func testThemeLookupFallsBackToTheFirstBuiltIn() {
        settings.themeName = "No Such Theme"
        XCTAssertEqual(settings.theme.name, Theme.builtIns[0].name)
        XCTAssertEqual(settings.themeName, "No Such Theme", "the name is kept: the theme may be imported later")
        XCTAssertNil(Theme.named("No Such Theme"))
        XCTAssertEqual(Theme.named("Solarized Dark")?.name, "Solarized Dark")
    }

    func testAnImportedThemeIsFoundByName() throws {
        let folder = TestSupport.temporaryDirectory("feather-themes")
        defer { try? FileManager.default.removeItem(at: folder) }
        let previous = ThemeStore.shared
        ThemeStore.shared = ThemeStore(directory: folder)
        defer { ThemeStore.shared = previous; settings.themesDidChange() }

        settings.themeName = "Ocean Imported"
        XCTAssertEqual(settings.theme.name, "Dark", "not imported yet")
        try ThemeStore.shared.save(Theme(name: "Ocean Imported", isDark: false, colors: ["background": NSColor(hex: 0xFAFAFA)]))
        settings.themesDidChange()                                 // the app's store tells Settings.shared; this one is ours
        XCTAssertEqual(Theme.named("Ocean Imported")?.isBuiltIn, false)
        XCTAssertEqual(settings.theme.name, "Ocean Imported")
        XCTAssertFalse(settings.theme.isDark)
        XCTAssertEqual(settings.theme.background.hexString, "#FAFAFA")
        XCTAssertEqual(Theme.all.map(\.name), Theme.builtIns.map(\.name) + ["Ocean Imported"])
    }

    func testTerminalListColoursFallBackToTheTheme() {
        settings.themeName = "Dark"
        XCTAssertNil(settings.terminalListIconColor)
        XCTAssertEqual(settings.terminalListIcon.hexString, settings.theme.accent.hexString)
        XCTAssertEqual(settings.terminalListText.hexString, settings.theme.foreground.hexString)

        settings.terminalListIconColor = "#FF0000"
        settings.terminalListTextColor = "#00FF00"
        XCTAssertEqual(settings.terminalListIcon.hexString, "#FF0000")
        XCTAssertEqual(settings.terminalListText.hexString, "#00FF00")

        // Something that is not a colour is as good as nothing.
        settings.terminalListIconColor = "red"
        settings.terminalListTextColor = ""
        XCTAssertEqual(settings.terminalListIcon.hexString, settings.theme.accent.hexString)
        XCTAssertEqual(settings.terminalListText.hexString, settings.theme.foreground.hexString)

        settings.terminalListIconColor = nil
        settle()
        XCTAssertEqual(received, [.terminal])
    }

    func testPreviewAddressIsRememberedPerFolder() {
        let one = URL(fileURLWithPath: "/tmp/feather-preview-one")
        let two = URL(fileURLWithPath: "/tmp/feather-preview-two")
        XCTAssertEqual(settings.previewAddress(for: one), Settings.defaultPreviewAddress)
        settings.setPreviewAddress("http://localhost:5173", for: one)
        XCTAssertEqual(settings.previewAddress(for: one), "http://localhost:5173")
        XCTAssertEqual(settings.previewAddress(for: two), Settings.defaultPreviewAddress)
        XCTAssertEqual(settings.previewAddress(for: nil), Settings.defaultPreviewAddress)
    }

    func testFollowChangesPostsItsOwnNotificationOnlyWhenItChanges() {
        var posts = 0
        let token = NotificationCenter.default.addObserver(forName: Settings.followChangesDidChange, object: settings, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        settings.followChanges = true
        settings.followChanges = true
        settings.followChanges = false
        XCTAssertEqual(posts, 2)
        XCTAssertFalse(settings.followChanges)
    }

    func testKeyBindingsAreRemovedWhenEmptied() {
        settings.keyBindings = ["saveDocument:": "cmd+shift+s"]
        XCTAssertEqual(settings.keyBindings, ["saveDocument:": "cmd+shift+s"])
        settings.keyBindings = [:]
        XCTAssertNil(defaults.object(forKey: "keyBindings"))
    }

    func testChangeInNotificationWithoutUserInfoMeansEverything() {
        XCTAssertEqual(Settings.change(in: Notification(name: Settings.didChange)), .everything)
        XCTAssertEqual(Settings.change(in: Notification(name: Settings.didChange, object: nil, userInfo: ["change": Settings.Change.terminal.rawValue])), .terminal)
    }

    func testMonoFontFallsBackToTheSystemFont() {
        let system = Settings.monoFont(name: Settings.systemMonoName, size: 13)
        XCTAssertEqual(system, .monospacedSystemFont(ofSize: 13, weight: .regular))
        XCTAssertEqual(Settings.monoFont(name: "No Such Font Family 9000", size: 13), system)
        XCTAssertEqual(Settings.monoFont(name: "Menlo", size: 11).familyName, "Menlo")
    }
}

// MARK: - Gaps in the theme import coverage

final class ThemeFileTests: XCTestCase {
    func testFeatherJSONNeedsANameAndColours() {
        XCTAssertNil(Theme(featherJSON: ["colors": ["background": "#000000"]]))
        XCTAssertNil(Theme(featherJSON: ["name": "  ", "colors": ["background": "#000000"]]))
        XCTAssertNil(Theme(featherJSON: ["name": "X"]))
        XCTAssertNotNil(Theme(featherJSON: ["name": "X", "colors": [:]]))
    }

    func testMissingColoursComeFromTheBuiltInOfTheSameDarkness() throws {
        let dark = try XCTUnwrap(Theme(featherJSON: ["name": "D", "type": "dark", "colors": ["keyword": "#123456", "bogus": "nope"]]))
        XCTAssertTrue(dark.isDark)
        XCTAssertEqual(dark.keyword.hexString, "#123456")
        XCTAssertEqual(dark.background.hexString, Theme.builtIns[0].background.hexString)
        XCTAssertNil(dark.accentColor)

        let light = try XCTUnwrap(Theme(featherJSON: ["name": "L", "type": "light", "colors": ["accent": "#ABCDEF"]]))
        XCTAssertFalse(light.isDark)
        XCTAssertEqual(light.string.hexString, Theme.builtIns[1].string.hexString)
        XCTAssertEqual(light.accentColor?.hexString, "#ABCDEF")
        XCTAssertEqual(light.accent.hexString, "#ABCDEF")

        // No "type": the background decides.
        let paper = try XCTUnwrap(Theme(featherJSON: ["name": "P", "colors": ["background": "#FFFFFF"]]))
        XCTAssertFalse(paper.isDark)
        XCTAssertTrue(try XCTUnwrap(Theme(featherJSON: ["name": "N", "colors": [:]])).isDark)
    }

    func testFeatherJSONRoundTrips() throws {
        let theme = Theme.builtIns[3]
        let copy = try XCTUnwrap(Theme(featherJSON: theme.featherJSON))
        XCTAssertEqual(copy.name, theme.name)
        XCTAssertEqual(copy.isDark, theme.isDark)
        for kind in [TokenKind.comment, .string, .number, .keyword, .type, .function] {
            XCTAssertEqual(copy.color(for: kind).hexString, theme.color(for: kind).hexString)
        }
        XCTAssertEqual(copy.selection.hexString, theme.selection.hexString)
        XCTAssertEqual((theme.featherJSON["colors"] as? [String: String])?.count, 13)
        XCTAssertEqual((Theme.builtIns[4].featherJSON["colors"] as? [String: String])?["accent"], "#0969DA")
    }

    func testStoreSkipsFilesThatAreNotThemesAndSortsByName() throws {
        let folder = TestSupport.temporaryDirectory("feather-themes")
        defer { try? FileManager.default.removeItem(at: folder) }
        try TestSupport.write([
            "notes.txt": "not a theme",
            "broken.json": "{ not json",
            "other.json": #"{"name": "Not A Theme"}"#,
            "zeta.json": #"{"name": "zeta", "colors": {}}"#,
            "alpha.json": ##"{"name": "Alpha", "type": "light", "colors": {"background": "#FFFFFF"}}"##,
        ], under: folder)
        let store = ThemeStore(directory: folder)
        XCTAssertEqual(store.themes.map(\.name), ["Alpha", "zeta"])
        XCTAssertEqual(ThemeStore(directory: folder.appendingPathComponent("missing")).themes.count, 0)
    }

    func testFileNamesAreMadeSafe() {
        let store = ThemeStore(directory: URL(fileURLWithPath: "/tmp/feather-themes"))
        XCTAssertEqual(store.fileURL(for: "Night: Owl/Blue").lastPathComponent, "Night- Owl-Blue.json")
        XCTAssertEqual(store.fileURL(for: "Nörd").lastPathComponent, "Nörd.json")
    }

    func testReImportingReplacesTheEarlierImport() throws {
        let folder = TestSupport.temporaryDirectory("feather-themes")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ThemeStore(directory: folder)
        try store.save(Theme(name: "Same", isDark: true, colors: ["keyword": NSColor(hex: 0x111111)]))
        try store.save(Theme(name: "Same", isDark: true, colors: ["keyword": NSColor(hex: 0x222222)]))
        XCTAssertEqual(store.themes.count, 1)
        XCTAssertEqual(store.themes.first?.keyword.hexString, "#222222")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
    }

    func testScopeDistance() {
        XCTAssertEqual(VSCodeTheme.distance(from: "comment", to: "comment"), 0)
        XCTAssertEqual(VSCodeTheme.distance(from: "comment", to: "comment.line"), 2)
        XCTAssertEqual(VSCodeTheme.distance(from: "comment.line", to: "comment.line.double-slash"), 3)
        XCTAssertEqual(VSCodeTheme.distance(from: "comment.line", to: "comment"), 102)
        XCTAssertNil(VSCodeTheme.distance(from: "commentary", to: "comment"))
        XCTAssertNil(VSCodeTheme.distance(from: "string", to: "comment"))
        XCTAssertEqual(VSCodeTheme.distance(from: "source.js comment", to: "comment"), 0, "a descendant selector counts by its last part")
    }

    func testHighContrastTypesAndFallbackScopes() throws {
        let dark = try VSCodeTheme.theme(from: ##"{ "type": "hc-black", "colors": { "editor.background": "#FFFFFF" } }"##, fallbackName: "hc")
        XCTAssertTrue(dark.isDark, "the declared type wins over the background")
        let light = try VSCodeTheme.theme(from: ##"{ "type": "hc-light", "colors": { "editor.background": "#000000" } }"##, fallbackName: "hc")
        XCTAssertFalse(light.isDark)
        XCTAssertEqual(light.name, "hc")

        // "storage" serves for keywords, "constant" for numbers, when the first choices are missing.
        let tokens = """
            { "tokenColors": [
                { "scope": "storage.type", "settings": { "foreground": "#AA0000" } },
                { "scope": "constant", "settings": { "foreground": "#00AA00" } },
                { "scope": "keyword", "settings": { "fontStyle": "bold" } } ] }
            """
        let theme = try VSCodeTheme.theme(from: tokens, fallbackName: "t")
        XCTAssertEqual(theme.keyword.hexString, "#AA0000")
        XCTAssertEqual(theme.number.hexString, "#00AA00")
    }
}

// MARK: - Gaps in the key binding coverage

final class KeyBindingsStoreTests: XCTestCase {
    func testCommandIDsTellSharedActionsApartByTag() {
        XCTAssertEqual(KeyBindings.commandID(for: Selector(("saveDocument:"))), "saveDocument:")
        XCTAssertEqual(KeyBindings.commandID(for: Selector(("performTextFinderAction:")), tag: 2), "performTextFinderAction:#2")
        let item = NSMenuItem(title: "Find Next", action: Selector(("performTextFinderAction:")), keyEquivalent: "g")
        item.tag = 2
        XCTAssertEqual(KeyBindings.commandID(of: item), "performTextFinderAction:#2")
        XCTAssertNil(KeyBindings.commandID(of: NSMenuItem(title: "Nothing", action: nil, keyEquivalent: "")))
    }

    func testBindingFromAKeyEvent() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift, .numericPad], timestamp: 0,
                                                   windowNumber: 0, context: nil, characters: "P", charactersIgnoringModifiers: "p",
                                                   isARepeat: false, keyCode: 35))
        XCTAssertEqual(KeyBinding(event: event), KeyBinding(key: "p", modifiers: [.command, .shift]))
        let flags = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [.command], timestamp: 0,
                                                   windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                                   isARepeat: false, keyCode: 55))
        XCTAssertNil(KeyBinding(event: flags))
    }

    func testSettingAndResettingBindingsWritesTheOverrides() {
        let saved = Settings.shared.keyBindings
        defer { Settings.shared.keyBindings = saved }
        let bindings = KeyBindings(overrides: [:])
        bindings.setBinding(.some(KeyBinding(key: "s", modifiers: [.command, .option])), for: "stashChanges:")
        bindings.setBinding(.some(nil), for: "closeTab:")
        XCTAssertEqual(Settings.shared.keyBindings, ["stashChanges:": "alt+cmd+s", "closeTab:": "none"])
        XCTAssertTrue(bindings.isCustom("closeTab:"))
        bindings.setBinding(nil, for: "closeTab:")
        XCTAssertEqual(Settings.shared.keyBindings, ["stashChanges:": "alt+cmd+s"])
        XCTAssertFalse(bindings.isCustom("closeTab:"))
        bindings.resetAll()
        XCTAssertEqual(Settings.shared.keyBindings, [:])
        XCTAssertFalse(bindings.isCustom("stashChanges:"))
    }

    func testReloadForgetsWhatTheOldMenuTaught() {
        let saved = Settings.shared.keyBindings
        defer { Settings.shared.keyBindings = saved }
        Settings.shared.keyBindings = ["closeTab:": "cmd+shift+w"]
        let bindings = KeyBindings(overrides: [:])
        let close = NSMenuItem(title: "Close Tab", action: Selector(("closeTab:")), keyEquivalent: "w")
        bindings.apply(to: close)
        XCTAssertEqual(close.keyEquivalent, "w")
        XCTAssertEqual(bindings.defaults.count, 1)
        bindings.reload()
        XCTAssertTrue(bindings.defaults.isEmpty)
        XCTAssertTrue(bindings.effective.isEmpty)
        bindings.apply(to: close)
        XCTAssertEqual(close.keyEquivalentModifierMask, [.command, .shift], "the overrides are reread from the settings")
    }
}
