import AppKit
import UniformTypeIdentifiers

// MARK: - Feather's own theme file

extension Theme {
    /// The fifteen colours by the names they carry in a saved theme file.
    private static let colorKeys = ["background", "foreground", "lineNumber", "activeLineNumber", "selection", "chrome", "border",
                                    "comment", "string", "number", "keyword", "type", "function"]

    /// `{ "name": "Nord", "type": "dark", "colors": { "background": "#2E3440", … } }`. Any colour left out
    /// comes from the built-in of the same darkness, so a hand-edited file with a missing key still loads.
    init?(featherJSON object: [String: Any]) {
        guard let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              let colors = object["colors"] as? [String: Any] else { return nil }
        let given = colors.compactMapValues { ($0 as? String).flatMap(NSColor.init(hexString:)) }
        let isDark = (object["type"] as? String).map { $0 != "light" } ?? (given["background"].map { !$0.isLight } ?? true)
        self.init(name: name, isDark: isDark, colors: given)
    }

    /// Builds a theme from whatever colours are known, taking the rest from the nearest built-in.
    init(name: String, isDark: Bool, colors: [String: NSColor]) {
        let base = isDark ? Theme.builtIns[0] : Theme.builtIns[1]
        func pick(_ key: String, _ fallback: NSColor) -> NSColor { colors[key] ?? fallback }
        self.init(name: name, isDark: isDark,
                  background: pick("background", base.background), foreground: pick("foreground", base.foreground),
                  lineNumber: pick("lineNumber", base.lineNumber), activeLineNumber: pick("activeLineNumber", base.activeLineNumber),
                  selection: pick("selection", base.selection), chrome: pick("chrome", base.chrome), border: pick("border", base.border),
                  comment: pick("comment", base.comment), string: pick("string", base.string), number: pick("number", base.number),
                  keyword: pick("keyword", base.keyword), type: pick("type", base.type), function: pick("function", base.function),
                  accentColor: colors["accent"])
    }

    var featherJSON: [String: Any] {
        let values = [background, foreground, lineNumber, activeLineNumber, selection, chrome, border,
                      comment, string, number, keyword, type, function]
        var colors = Dictionary(uniqueKeysWithValues: zip(Theme.colorKeys, values.map(\.hexString)))
        if let accentColor { colors["accent"] = accentColor.hexString }
        return ["name": name, "type": isDark ? "dark" : "light", "colors": colors]
    }
}

// MARK: - Reading a VS Code theme

/// Turns a VS Code colour theme (`*-color-theme.json`, JSON with comments) into a Feather theme. VS Code themes
/// name hundreds of colours; Feather keeps the handful it draws with and fills the rest from the nearest built-in.
enum VSCodeTheme {
    /// Which VS Code workbench colours feed each Feather colour, first choice first.
    static let colorSources: [(key: String, vscode: [String])] = [
        ("background", ["editor.background"]),
        ("foreground", ["editor.foreground", "foreground"]),
        ("lineNumber", ["editorLineNumber.foreground"]),
        ("activeLineNumber", ["editorLineNumber.activeForeground", "editorLineNumber.foreground"]),
        ("selection", ["editor.selectionBackground"]),
        ("chrome", ["sideBar.background", "editorGroupHeader.tabsBackground", "activityBar.background"]),
        ("border", ["editorGroup.border", "panel.border", "sideBar.border", "contrastBorder"]),
        ("accent", ["focusBorder"]),
    ]

    /// Which TextMate scopes feed each syntax colour, first choice first.
    static let tokenSources: [(key: String, scopes: [String])] = [
        ("comment", ["comment"]),
        ("string", ["string"]),
        ("number", ["constant.numeric", "constant"]),
        ("keyword", ["keyword", "storage"]),
        ("type", ["entity.name.type", "support.type", "support.class", "entity.name.class"]),
        ("function", ["entity.name.function", "support.function"]),
    ]

    enum ImportError: LocalizedError {
        case notATheme
        var errorDescription: String? { "This file is not a VS Code colour theme: it has no “colors” or “tokenColors”." }
    }

    static func theme(from text: String, fallbackName: String) throws -> Theme {
        guard let data = ProjectColor.stripJSONComments(text).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ImportError.notATheme }
        return try theme(from: object, fallbackName: fallbackName)
    }

    static func theme(from object: [String: Any], fallbackName: String) throws -> Theme {
        let colors = object["colors"] as? [String: Any] ?? [:]
        let tokens = object["tokenColors"] as? [[String: Any]] ?? []
        guard !colors.isEmpty || !tokens.isEmpty else { throw ImportError.notATheme }

        var found: [String: NSColor] = [:]
        for source in colorSources {
            for name in source.vscode {
                if let color = (colors[name] as? String).flatMap(NSColor.init(hexString:)) { found[source.key] = color; break }
            }
        }
        for source in tokenSources {
            if let color = tokenColor(for: source.scopes, in: tokens) { found[source.key] = color }
        }
        let background = found["background"]
        let isDark: Bool
        switch (object["type"] as? String)?.lowercased() {
        case "dark", "hc-black", "hcdark": isDark = true
        case "light", "hc-light", "hclight": isDark = false
        default: isDark = background.map { !$0.isLight } ?? true
        }
        // A translucent selection or chrome is drawn over the editor in VS Code; Feather paints them flat.
        let base = isDark ? Theme.builtIns[0] : Theme.builtIns[1]
        let solidBackground = (background ?? base.background).flattened(over: base.background)
        for key in ["background", "chrome", "border", "selection"] {
            if let color = found[key] { found[key] = color.flattened(over: solidBackground) }
        }
        let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespaces)
        return Theme(name: name.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName, isDark: isDark, colors: found)
    }

    /// The foreground of the most specific rule for any of the wanted scopes. A rule for "comment" serves
    /// "comment.line"; a rule for "comment.line" is taken for "comment" only when no rule for "comment" exists.
    static func tokenColor(for wanted: [String], in tokens: [[String: Any]]) -> NSColor? {
        for scope in wanted {
            var best: (color: NSColor, distance: Int)?
            for rule in tokens {
                guard let settings = rule["settings"] as? [String: Any],
                      let color = (settings["foreground"] as? String).flatMap(NSColor.init(hexString:)) else { continue }
                for ruleScope in scopes(of: rule["scope"]) {
                    guard let distance = distance(from: ruleScope, to: scope), distance < (best?.distance ?? .max) else { continue }
                    best = (color, distance)
                }
            }
            if let best { return best.color }
        }
        return nil
    }

    /// `"scope"` is a string, a comma-separated string, or an array of either.
    private static func scopes(of value: Any?) -> [String] {
        let strings: [String]
        if let one = value as? String { strings = [one] } else if let many = value as? [String] { strings = many } else { return [] }
        return strings.flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 0 for an exact match, small for a rule for a parent scope ("comment" for "comment.line"), larger for a rule
    /// for a child scope, nil when unrelated. A rule with several space-separated selectors counts by its last.
    static func distance(from ruleScope: String, to wanted: String) -> Int? {
        let rule = ruleScope.split(separator: " ").last.map(String.init) ?? ruleScope
        if rule == wanted { return 0 }
        if wanted.hasPrefix(rule + ".") { return 1 + rule.split(separator: ".").count }          // a parent: prefer the nearest
        if rule.hasPrefix(wanted + ".") { return 100 + rule.split(separator: ".").count }        // a child: any will do
        return nil
    }
}

private extension NSColor {
    /// The colour as it looks painted over `background`, so a translucent VS Code colour keeps its look.
    func flattened(over background: NSColor) -> NSColor {
        guard let color = usingColorSpace(.sRGB), color.alphaComponent < 1,
              let base = background.usingColorSpace(.sRGB) else { return self }
        let alpha = color.alphaComponent
        return NSColor(srgbRed: color.redComponent * alpha + base.redComponent * (1 - alpha),
                       green: color.greenComponent * alpha + base.greenComponent * (1 - alpha),
                       blue: color.blueComponent * alpha + base.blueComponent * (1 - alpha), alpha: 1)
    }
}

// MARK: - Imported themes on disk

/// The themes the user imported, one JSON file each under Application Support/Feather/themes. Loaded once and
/// kept, because `Theme.all` is read whenever a theme popup or the Command Palette is built.
final class ThemeStore {
    /// A test may put a store on a scratch folder here, so `Theme.all` sees its imports.
    static var shared = ThemeStore()
    /// Posted on the main thread when a theme was added or removed (object: the store).
    static let didChange = Notification.Name("FeatherThemeStoreDidChange")

    /// Where the theme files live. A test points this somewhere else before the store is first read.
    static var baseDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Feather/themes", isDirectory: true)
    }()

    let directory: URL
    private var loaded: [Theme]?

    init(directory: URL = ThemeStore.baseDirectory) {
        self.directory = directory
    }

    /// Sorted by name; a file that is not a theme is skipped.
    var themes: [Theme] {
        if let loaded { return loaded }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let themes = files.filter { $0.pathExtension == "json" }.compactMap { file -> Theme? in
            guard let data = try? Data(contentsOf: file), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return Theme(featherJSON: object)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        loaded = themes
        return themes
    }

    /// A built-in's name is left alone: an import called "Dark" becomes "Dark (imported)". Replaces an earlier
    /// import of the same name, which is what re-importing an edited theme should do.
    @discardableResult
    func save(_ theme: Theme) throws -> Theme {
        var theme = theme
        if Theme.builtIns.contains(where: { $0.name == theme.name }) {
            theme = Theme(name: theme.name + " (imported)", isDark: theme.isDark, colors: colors(of: theme))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: theme.featherJSON, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fileURL(for: theme.name), options: .atomic)
        loaded = nil
        noteChange()
        return theme
    }

    func delete(named name: String) {
        try? FileManager.default.removeItem(at: fileURL(for: name))
        loaded = nil
        noteChange()
    }

    private func noteChange() {
        // Only the app's own store drives the settings; a test's store on a scratch folder must not.
        if self === ThemeStore.shared { Settings.shared.themesDidChange() }
        NotificationCenter.default.post(name: ThemeStore.didChange, object: self)
    }

    func fileURL(for name: String) -> URL {
        let safe = name.map { "/:".contains($0) ? "-" : $0 }
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    private func colors(of theme: Theme) -> [String: NSColor] {
        (theme.featherJSON["colors"] as? [String: String] ?? [:]).compactMapValues(NSColor.init(hexString:))
    }
}

// MARK: - The menu command

extension AppDelegate {
    /// Feather ▸ Import VS Code Theme… (also the button beside the theme popup in Settings): pick a
    /// `*-color-theme.json` file, save its colours as a Feather theme and switch to it.
    @objc func importVSCodeTheme(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Import VS Code Theme"
        panel.message = "Choose a VS Code colour theme file (usually named something-color-theme.json)."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        let run = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            self?.importTheme(at: url)
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: run) } else { run(panel.runModal()) }
    }

    func importTheme(at url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-color-theme", with: "")
            let theme = try ThemeStore.shared.save(VSCodeTheme.theme(from: text, fallbackName: name))
            Settings.shared.themeName = theme.name
        } catch {
            let alert = NSAlert()
            alert.messageText = "The theme could not be imported."
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
