import AppKit

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

struct Theme {
    let name: String
    let isDark: Bool
    let background: NSColor
    let foreground: NSColor
    let lineNumber: NSColor
    let activeLineNumber: NSColor
    let selection: NSColor
    let chrome: NSColor
    let border: NSColor
    let comment: NSColor
    let string: NSColor
    let number: NSColor
    let keyword: NSColor
    let type: NSColor
    let function: NSColor
    /// An imported theme's own accent (VS Code's `focusBorder`); the built-ins use VS Code's focus blue.
    var accentColor: NSColor? = nil

    /// Behind a bracket and its partner: the text colour, faint enough to sit under any syntax colour.
    var bracketMatch: NSColor { foreground.withAlphaComponent(isDark ? 0.22 : 0.16) }

    /// The one bright colour of the chrome: the icons in the list of terminals, its selected row, the dot on a
    /// terminal that wants attention. VS Code's focus blue on the dark themes.
    var accent: NSColor { accentColor ?? (isDark ? NSColor(hex: 0x3794FF) : NSColor(hex: 0x005FB8)) }

    func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .comment: return comment
        case .string: return string
        case .number: return number
        case .keyword: return keyword
        case .type: return type
        case .function: return function
        }
    }

    /// Built-ins first, then the themes imported from VS Code (ThemeStore). The first one is the default.
    static var all: [Theme] { builtIns + ThemeStore.shared.themes }

    static func named(_ name: String) -> Theme? { all.first { $0.name == name } }

    var isBuiltIn: Bool { Theme.builtIns.contains { $0.name == name } }

    static let builtIns: [Theme] = [
        Theme(name: "Dark", isDark: true,
              background: NSColor(hex: 0x1E1E1E), foreground: NSColor(hex: 0xD4D4D4),
              lineNumber: NSColor(hex: 0x6E7681), activeLineNumber: NSColor(hex: 0xC6C6C6),
              selection: NSColor(hex: 0x264F78), chrome: NSColor(hex: 0x252526), border: NSColor(hex: 0x3A3A3A),
              comment: NSColor(hex: 0x6A9955), string: NSColor(hex: 0xCE9178), number: NSColor(hex: 0xB5CEA8),
              keyword: NSColor(hex: 0x569CD6), type: NSColor(hex: 0x4EC9B0), function: NSColor(hex: 0xDCDCAA)),
        Theme(name: "Light", isDark: false,
              background: NSColor(hex: 0xFFFFFF), foreground: NSColor(hex: 0x1F1F1F),
              lineNumber: NSColor(hex: 0x9A9A9A), activeLineNumber: NSColor(hex: 0x0B216F),
              selection: NSColor(hex: 0xADD6FF), chrome: NSColor(hex: 0xF3F3F3), border: NSColor(hex: 0xDDDDDD),
              comment: NSColor(hex: 0x008000), string: NSColor(hex: 0xA31515), number: NSColor(hex: 0x098658),
              keyword: NSColor(hex: 0x0000FF), type: NSColor(hex: 0x267F99), function: NSColor(hex: 0x795E26)),
        Theme(name: "Midnight", isDark: true,
              background: NSColor(hex: 0x282C34), foreground: NSColor(hex: 0xABB2BF),
              lineNumber: NSColor(hex: 0x4B5263), activeLineNumber: NSColor(hex: 0xABB2BF),
              selection: NSColor(hex: 0x3E4451), chrome: NSColor(hex: 0x21252B), border: NSColor(hex: 0x181A1F),
              comment: NSColor(hex: 0x5C6370), string: NSColor(hex: 0x98C379), number: NSColor(hex: 0xD19A66),
              keyword: NSColor(hex: 0xC678DD), type: NSColor(hex: 0xE5C07B), function: NSColor(hex: 0x61AFEF)),
        // Ethan Schoonover's Solarized palette, as VS Code's bundled Solarized Dark maps it.
        Theme(name: "Solarized Dark", isDark: true,
              background: NSColor(hex: 0x002B36), foreground: NSColor(hex: 0x839496),
              lineNumber: NSColor(hex: 0x566C75), activeLineNumber: NSColor(hex: 0x93A1A1),
              selection: NSColor(hex: 0x274642), chrome: NSColor(hex: 0x00212B), border: NSColor(hex: 0x003847),
              comment: NSColor(hex: 0x586E75), string: NSColor(hex: 0x2AA198), number: NSColor(hex: 0xD33682),
              keyword: NSColor(hex: 0x859900), type: NSColor(hex: 0xB58900), function: NSColor(hex: 0x268BD2)),
        // GitHub's Primer syntax colours, as github.com and the GitHub Light theme show code.
        Theme(name: "GitHub Light", isDark: false,
              background: NSColor(hex: 0xFFFFFF), foreground: NSColor(hex: 0x1F2328),
              lineNumber: NSColor(hex: 0x8C959F), activeLineNumber: NSColor(hex: 0x1F2328),
              selection: NSColor(hex: 0xB6D9FD), chrome: NSColor(hex: 0xF6F8FA), border: NSColor(hex: 0xD0D7DE),
              comment: NSColor(hex: 0x6E7781), string: NSColor(hex: 0x0A3069), number: NSColor(hex: 0x0550AE),
              keyword: NSColor(hex: 0xCF222E), type: NSColor(hex: 0x953800), function: NSColor(hex: 0x8250DF),
              accentColor: NSColor(hex: 0x0969DA)),
    ]
}

final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("FeatherSettingsDidChange")
    static let systemMonoName = "System Mono"

    private let defaults: UserDefaults
    private static let initial: [String: Any] = [
        "fontName": systemMonoName,
        "fontSize": 13,
        "theme": "Dark",
        "tabWidth": 4,
        "useSpaces": true,
        "wrapLines": false,
        "showLineNumbers": true,
        "terminalFontSize": 12,
        "confirmBeforeQuit": true,
        "autoSuggest": true,
        "commandClickNavigation": true,
        "terminalCursorBlink": false,
        "restoreSession": true,
        "revealInExplorer": true,
        "scrollBarSize": 11,
        "autoCloseBrackets": true,
        "matchBrackets": true,
        "trimTrailingWhitespace": false,
        "insertFinalNewline": false,
        "formatOnSave": false,
        "autoSave": "off",
        "showBlame": true,
        "stickyScroll": true,
        "followChanges": false,
        "autoCheckpoint": true,
        "previewReloadsOnChange": true,
        "checkOnSave": true,
    ]

    private convenience init() { self.init(defaults: .standard) }

    /// Tests build their own on a throwaway suite; the app has `shared` on the standard defaults.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        defaults.register(defaults: Settings.initial)
    }

    /// What a change affects, so observers redo only that. Settings that are simply read at the moment they
    /// matter (ask before quitting, suggestions, ⌘-click, …) change nothing on screen and notify no one.
    struct Change: OptionSet {
        let rawValue: Int
        static let theme = Change(rawValue: 1)
        static let editor = Change(rawValue: 2)          // font, tab width, wrapping, line numbers
        static let terminal = Change(rawValue: 4)
        static let scrollBars = Change(rawValue: 8)
        static let explorer = Change(rawValue: 16)       // compact folders
        static let everything: Change = [.theme, .editor, .terminal, .scrollBars, .explorer]
    }

    private var pendingChange: Change = []
    private var cachedTheme: Theme?

    /// Writes that do not change the value are dropped, and several changes in one turn of the run loop (a slider
    /// drag, Reset to Defaults) reach observers as a single notification naming everything that changed.
    private func set(_ value: Any?, _ key: String, _ change: Change = []) {
        if let old = defaults.object(forKey: key) as? NSObject, let new = value as? NSObject, old.isEqual(new) { return }
        defaults.set(value, forKey: key)
        if key == "theme" { cachedTheme = nil }
        announce(change)
    }

    private func announce(_ change: Change) {
        guard !change.isEmpty else { return }
        if pendingChange.isEmpty {
            DispatchQueue.main.async { [self] in
                let change = pendingChange
                pendingChange = []
                NotificationCenter.default.post(name: Settings.didChange, object: nil, userInfo: ["change": change.rawValue])
            }
        }
        pendingChange.formUnion(change)
    }

    /// What a `didChange` notification says changed.
    static func change(in notification: Notification) -> Change {
        (notification.userInfo?["change"] as? Int).map(Change.init(rawValue:)) ?? .everything
    }

    var fontName: String {
        get { defaults.string(forKey: "fontName") ?? Settings.systemMonoName }
        set { set(newValue, "fontName", [.editor, .terminal]) }
    }
    var fontSize: Int {
        get { max(8, min(40, defaults.integer(forKey: "fontSize"))) }
        set { set(max(8, min(40, newValue)), "fontSize", .editor) }
    }
    var themeName: String {
        get { defaults.string(forKey: "theme") ?? "Dark" }
        set { set(newValue, "theme", .everything) }
    }
    var tabWidth: Int {
        get { max(1, min(16, defaults.integer(forKey: "tabWidth"))) }
        set { set(newValue, "tabWidth", .editor) }
    }
    var useSpaces: Bool {
        get { defaults.bool(forKey: "useSpaces") }
        set { set(newValue, "useSpaces") }
    }
    var wrapLines: Bool {
        get { defaults.bool(forKey: "wrapLines") }
        set { set(newValue, "wrapLines", .editor) }
    }
    var showLineNumbers: Bool {
        get { defaults.bool(forKey: "showLineNumbers") }
        set { set(newValue, "showLineNumbers", .editor) }
    }
    var terminalFontSize: Int {
        get { max(8, min(32, defaults.integer(forKey: "terminalFontSize"))) }
        set { set(newValue, "terminalFontSize", .terminal) }
    }
    var confirmBeforeQuit: Bool {
        get { defaults.bool(forKey: "confirmBeforeQuit") }
        set { set(newValue, "confirmBeforeQuit") }
    }

    /// Suggestions appear on their own while typing. When off, ⌃Space still asks for them.
    var autoSuggest: Bool {
        get { defaults.bool(forKey: "autoSuggest") }
        set { set(newValue, "autoSuggest") }
    }

    /// Typing an opening bracket or quote also types its partner. Read at the keystroke, so it notifies no one.
    var autoCloseBrackets: Bool {
        get { defaults.bool(forKey: "autoCloseBrackets") }
        set { set(newValue, "autoCloseBrackets") }
    }
    /// Tint the bracket next to the caret and its partner. Turning it off takes effect at the next caret move.
    var matchBrackets: Bool {
        get { defaults.bool(forKey: "matchBrackets") }
        set { set(newValue, "matchBrackets") }
    }

    // What happens to a file on its way to disk. All three are read at the moment of saving.
    var trimTrailingWhitespace: Bool {
        get { defaults.bool(forKey: "trimTrailingWhitespace") }
        set { set(newValue, "trimTrailingWhitespace") }
    }
    var insertFinalNewline: Bool {
        get { defaults.bool(forKey: "insertFinalNewline") }
        set { set(newValue, "insertFinalNewline") }
    }
    /// Needs a language server that can format; without one, saving simply saves.
    var formatOnSave: Bool {
        get { defaults.bool(forKey: "formatOnSave") }
        set { set(newValue, "formatOnSave") }
    }

    /// "off", "afterDelay" or "onFocusChange". Asked on every edit, so the answer is kept rather than looked up.
    var autoSaveMode: AutoSaveController.Mode {
        get {
            if let cachedAutoSaveMode { return cachedAutoSaveMode }
            let mode = AutoSaveController.Mode(rawValue: defaults.string(forKey: "autoSave") ?? "") ?? .off
            cachedAutoSaveMode = mode
            return mode
        }
        set {
            cachedAutoSaveMode = newValue
            set(newValue.rawValue, "autoSave")
        }
    }
    private var cachedAutoSaveMode: AutoSaveController.Mode?
    /// Who last changed the caret's line, in the status bar. Read when the status bar is next brought up to date.
    var showBlame: Bool {
        get { defaults.bool(forKey: "showBlame") }
        set { set(newValue, "showBlame") }
    }
    /// Keep the opening lines of the blocks around the top of the editor pinned there while scrolling.
    var stickyScroll: Bool {
        get { defaults.bool(forKey: "stickyScroll") }
        set { set(newValue, "stickyScroll", .editor) }
    }

    // MARK: Web preview

    /// The preview loads its page again when a project file is saved or changes on disk. Read when that happens.
    var previewReloadsOnChange: Bool {
        get { defaults.bool(forKey: "previewReloadsOnChange") }
        set { set(newValue, "previewReloadsOnChange") }
    }

    static let defaultPreviewAddress = "http://localhost:3000"

    /// The address last previewed in a project, offered again by View ▸ Open Preview…. Keyed by folder path.
    func previewAddress(for folder: URL?) -> String {
        let saved = defaults.dictionary(forKey: "previewAddresses") as? [String: String]
        return saved?[folder?.standardizedFileURL.path ?? ""] ?? Settings.defaultPreviewAddress
    }

    func setPreviewAddress(_ address: String, for folder: URL?) {
        var saved = defaults.dictionary(forKey: "previewAddresses") as? [String: String] ?? [:]
        saved[folder?.standardizedFileURL.path ?? ""] = address
        defaults.set(saved, forKey: "previewAddresses")
    }

    static let scrollBarSizeRange = 5...22

    /// Thickness of the app's scroll bars, in points.
    var scrollBarSize: Int {
        get { max(Settings.scrollBarSizeRange.lowerBound, min(Settings.scrollBarSizeRange.upperBound, defaults.integer(forKey: "scrollBarSize"))) }
        set { set(newValue, "scrollBarSize", .scrollBars) }
    }

    /// Posted when follow mode is switched; the Activity pane, the status bar and the menu show it.
    static let followChangesDidChange = Notification.Name("FeatherSettingsFollowChangesDidChange")

    /// Follow mode (Activity.swift): show each file as something other than Feather changes it.
    var followChanges: Bool {
        get { defaults.bool(forKey: "followChanges") }
        set {
            guard newValue != followChanges else { return }
            set(newValue, "followChanges")
            NotificationCenter.default.post(name: Settings.followChangesDidChange, object: self)
        }
    }

    /// Run the project's compiler or linter a moment after a file is saved, for the Problems pane. See ProjectChecker.swift.
    var checkOnSave: Bool {
        get { defaults.bool(forKey: "checkOnSave") }
        set { set(newValue, "checkOnSave") }
    }

    /// Save a checkpoint of the project when its folder is opened (at most one an hour). See Checkpoints.swift.
    var autoCheckpoint: Bool {
        get { defaults.bool(forKey: "autoCheckpoint") }
        set { set(newValue, "autoCheckpoint") }
    }

    /// macOS 26: the sidebar, activity bar, header and status bar sit on Liquid Glass with the theme colour over
    /// it, and the floating panels are glass. Off, everything is the plain theme colour, as on earlier systems.
    var glassChrome: Bool {
        get { defaults.object(forKey: "glassChrome") as? Bool ?? true }
        set { set(newValue, "glassChrome", .theme) }
    }

    /// Explorer: a chain of folders holding nothing but one folder is one row ("src › main › java"), as VS Code's
    /// compact folders are. Off, every folder is its own row.
    var compactFolders: Bool {
        get { defaults.object(forKey: "compactFolders") as? Bool ?? true }
        set { set(newValue, "compactFolders", .explorer) }
    }

    /// Keep the Explorer's selection on the file being edited, expanding folders as needed.
    var revealInExplorer: Bool {
        get { defaults.bool(forKey: "revealInExplorer") }
        set { set(newValue, "revealInExplorer") }
    }

    /// Reopen the windows, files and terminals that were open when Feather last quit.
    var restoreSession: Bool {
        get { defaults.bool(forKey: "restoreSession") }
        set { set(newValue, "restoreSession") }
    }

    /// One dictionary per window; see MainWindowController.sessionState().
    var savedSession: [[String: Any]] {
        get { defaults.array(forKey: "session") as? [[String: Any]] ?? [] }
        set { defaults.set(newValue, forKey: "session") }
    }

    var terminalCursorBlink: Bool {
        get { defaults.bool(forKey: "terminalCursorBlink") }
        set { set(newValue, "terminalCursorBlink", .terminal) }
    }
    var commandClickNavigation: Bool {
        get { defaults.bool(forKey: "commandClickNavigation") }
        set { set(newValue, "commandClickNavigation") }
    }

    static let maxRecentFolders = 12

    /// Most recent first; folders that no longer exist are left out.
    var recentFolders: [URL] {
        (defaults.stringArray(forKey: "recentFolders") ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    func noteRecentFolder(_ url: URL) {
        var paths = defaults.stringArray(forKey: "recentFolders") ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        defaults.set(Array(paths.prefix(Settings.maxRecentFolders)), forKey: "recentFolders")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)      // the Dock menu's recent list
    }

    func clearRecentFolders() {
        defaults.removeObject(forKey: "recentFolders")
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    var lastFolder: String? {
        get { defaults.string(forKey: "lastFolder") }
        set { defaults.set(newValue, forKey: "lastFolder") }
    }

    // MARK: - AI assistant and terminal attention (all read at the moment they matter, so they notify no one)

    private static let assistantKeys = ["aiTool", "aiToolCustomCommand", "notifyWhenTerminalWaits", "terminalQuietDelay",
                                        "terminalSound", "terminalListIconColor", "terminalListTextColor", "terminalCopyOnSelect"]

    /// Selecting text in the terminal copies it, as VS Code's "copy on selection" does. Read at each mouse-up.
    var terminalCopyOnSelect: Bool {
        get { defaults.bool(forKey: "terminalCopyOnSelect") }
        set { set(newValue, "terminalCopyOnSelect") }
    }

    /// Ids of the extensions switched on (`FeatherExtension.id`; Extensions.swift). The Requests pane (the API
    /// client) is on from the first launch; switching it off is remembered.
    var enabledExtensions: [String] {
        get { defaults.stringArray(forKey: "enabledExtensions") ?? [APIClientExtension.id] }
        set { set(newValue, "enabledExtensions") }
    }

    /// A short sound when a terminal finishes or asks something, whether or not a notification is shown.
    var terminalSound: Bool {
        get { defaults.object(forKey: "terminalSound") as? Bool ?? false }
        set { set(newValue, "terminalSound") }
    }

    // MARK: - The list of terminals: its own colours, or the theme's

    /// The colour of the icons in the list of terminals, as "#RRGGBB"; nil means the theme's accent.
    var terminalListIconColor: String? {
        get { defaults.string(forKey: "terminalListIconColor") }
        set { set(newValue, "terminalListIconColor", .terminal) }
    }
    /// The colour of the names in the list of terminals; nil means the theme's text colour.
    var terminalListTextColor: String? {
        get { defaults.string(forKey: "terminalListTextColor") }
        set { set(newValue, "terminalListTextColor", .terminal) }
    }
    var terminalListIcon: NSColor { terminalListIconColor.flatMap(NSColor.init(hexString:)) ?? theme.accent }
    var terminalListText: NSColor { terminalListTextColor.flatMap(NSColor.init(hexString:)) ?? theme.foreground }

    /// "auto" (the first tool found), a tool's id from `AITools.all`, or "custom".
    var aiTool: String {
        get { defaults.string(forKey: "aiTool") ?? AITools.automatic }
        set { set(newValue, "aiTool"); NotificationCenter.default.post(name: AITools.didChange, object: nil) }
    }
    /// Typed into a new terminal when `aiTool` is "custom".
    var aiToolCustomCommand: String {
        get { defaults.string(forKey: "aiToolCustomCommand") ?? "" }
        set { set(newValue, "aiToolCustomCommand"); NotificationCenter.default.post(name: AITools.didChange, object: nil) }
    }
    /// Tell the user when a terminal they are not looking at has finished or is asking something. Off until
    /// switched on in Preferences or the Command Palette: a notification for every finished command is more
    /// than most people want.
    var notifyWhenTerminalWaits: Bool {
        get { defaults.object(forKey: "notifyWhenTerminalWaits") as? Bool ?? false }
        set { set(newValue, "notifyWhenTerminalWaits") }
    }
    static let terminalQuietDelays = [2, 4, 8, 15, 30]
    /// Seconds without output before a busy terminal counts as waiting.
    var terminalQuietDelay: Int {
        get { max(1, min(120, defaults.object(forKey: "terminalQuietDelay") as? Int ?? 4)) }
        set { set(newValue, "terminalQuietDelay") }
    }
    /// Where a new window puts its terminal: the user's last choice. Each window's own choice is in its session.
    var terminalOnRight: Bool {
        get { defaults.bool(forKey: "terminalOnRight") }
        set { defaults.set(newValue, forKey: "terminalOnRight") }
    }
    /// The right-hand layout is suggested once, the first time an AI assistant is started.
    var didOfferTerminalOnRight: Bool {
        get { defaults.bool(forKey: "didOfferTerminalOnRight") }
        set { defaults.set(newValue, forKey: "didOfferTerminalOnRight") }
    }

    func resetToDefaults() {
        for key in Settings.initial.keys + Settings.assistantKeys { defaults.removeObject(forKey: key) }
        cachedTheme = nil
        cachedAutoSaveMode = nil
        announce(.everything)
    }

    /// Read in drawing code and per table cell, so it is looked up once, not on every call.
    var theme: Theme {
        if let cachedTheme { return cachedTheme }
        let theme = Theme.named(themeName) ?? Theme.builtIns[0]
        cachedTheme = theme
        return theme
    }

    /// The list of imported themes changed (ThemeStore): the chosen theme may be new, edited or gone.
    func themesDidChange() {
        cachedTheme = nil
        announce(.everything)
    }

    /// Custom keyboard shortcuts, keyed by the menu command (KeyBindings.commandID) with a portable encoding such
    /// as "cmd+shift+p" as the value, or "none" for a command that should have no shortcut. Read once when the
    /// menu bar is built, so a change notifies no one; the menu is rebuilt by whoever changed it.
    var keyBindings: [String: String] {
        get { defaults.dictionary(forKey: "keyBindings") as? [String: String] ?? [:] }
        set { defaults.set(newValue.isEmpty ? nil : newValue, forKey: "keyBindings") }
    }

    var editorFont: NSFont { Settings.monoFont(name: fontName, size: CGFloat(fontSize)) }
    var terminalFont: NSFont { Settings.monoFont(name: fontName, size: CGFloat(terminalFontSize)) }

    static func monoFont(name: String, size: CGFloat) -> NSFont {
        if name != systemMonoName,
           let font = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
