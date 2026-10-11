import AppKit

/// Feather's own per-project settings, kept in `<project>/.feather/settings.json` so they can be committed and
/// shared with the team. Comments and trailing commas are tolerated when reading.
///
///     { "color": "#3B0764", "border": true, "run": "./mvnw spring-boot:run" }
struct ProjectSettings {
    /// "#RRGGBB", or "none" to switch the tint off even if `.vscode/settings.json` defines one.
    var color: String?
    /// Draw a frame in the project colour around the whole window.
    var border = true
    /// The command ⌘R runs, when automatic detection is not what you want.
    var run: String?
    /// The project's own entries for Run ▸ Run Task…: `"tasks": [{ "name": "Seed", "command": "make seed", "cwd": "backend" }]`.
    /// `cwd` is relative to the project folder and may be left out.
    var tasks: [CustomTask] = []

    struct CustomTask {
        let name: String
        let command: String
        let cwd: String?
    }

    static func fileURL(in root: URL) -> URL { root.appendingPathComponent(".feather/settings.json") }

    private static func dictionary(in root: URL) -> [String: Any] {
        guard let text = try? String(contentsOf: fileURL(in: root), encoding: .utf8),
              let data = ProjectColor.stripJSONComments(text).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return object
    }

    static func load(from root: URL) -> ProjectSettings {
        let values = dictionary(in: root)
        var settings = ProjectSettings()
        settings.color = (values["color"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        settings.border = values["border"] as? Bool ?? true
        settings.run = (values["run"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        // Entries that are not an object with a name and a command are skipped, not fatal.
        settings.tasks = (values["tasks"] as? [Any] ?? []).compactMap { entry in
            guard let entry = entry as? [String: Any],
                  let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let command = (entry["command"] as? String)?.trimmingCharacters(in: .whitespaces), !command.isEmpty else { return nil }
            return CustomTask(name: name, command: command, cwd: (entry["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        return settings
    }

    /// Changes only the given keys and keeps anything else already in the file. A nil value removes its key.
    static func update(in root: URL, _ changes: [String: Any?]) {
        var values = dictionary(in: root)
        for (key, value) in changes { values[key] = value }
        write(values, in: root)
    }

    private static func write(_ values: [String: Any], in root: URL) {
        let file = fileURL(in: root)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? (String(decoding: data, as: UTF8.self) + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// Makes sure the file exists, with every option spelled out, so it can be opened and edited by hand.
    static func createIfMissing(in root: URL, currentColor: NSColor?) -> URL {
        let file = fileURL(in: root)
        if !FileManager.default.fileExists(atPath: file.path) {
            write(["$help": "Feather project settings. color: \"#RRGGBB\" or \"none\". border: true or false. run: the command for Cmd-R (empty = detect automatically). tasks: your own entries for Run Task, [{ \"name\": \"Seed\", \"command\": \"make seed\", \"cwd\": \"backend\" }] (cwd is optional).",
                   "color": currentColor?.hexString ?? "#3B0764", "border": true, "run": ""], in: root)
        }
        return file
    }
}

/// A per-project accent colour that tints the window's title bar, status bar, dividers and border, so several
/// open projects can be told apart at a glance. It comes from `.feather/settings.json`, or else from the
/// project's `.vscode/settings.json`, which is where VS Code and Peacock keep theirs.
enum ProjectColor {
    /// Written as the colour when the user wants no tint even though the project's VS Code settings define one.
    static let none = "none"

    /// Every hue in five shades, light to dark, plus greys. The shades are kept off full saturation: a colour
    /// is worn by the whole window chrome, where a vivid one is garish; these read as dyed, not painted.
    static let palette: [[String]] = {
        let hues: [CGFloat] = [0, 18, 38, 85, 140, 172, 195, 215, 240, 268, 292, 328]
        let shades: [(saturation: CGFloat, brightness: CGFloat)] = [(0.40, 0.95), (0.52, 0.82), (0.58, 0.66), (0.62, 0.50), (0.66, 0.34)]
        var rows = shades.map { shade in
            hues.map { NSColor(calibratedHue: $0 / 360, saturation: shade.saturation, brightness: shade.brightness, alpha: 1).hexString }
        }
        rows.append((0..<hues.count).map { index in
            NSColor(calibratedWhite: 0.92 - CGFloat(index) * 0.075, alpha: 1).hexString
        })
        return rows
    }()

    /// The colour as the window wears it: dyed into the theme's chrome rather than painted over it, so the
    /// bars and the ground under the panels take the hue without turning into a block of paint. A dark chrome
    /// takes a little more of the colour than a light one, which would wash out.
    static func chromeTint(_ color: NSColor, over chrome: NSColor) -> NSColor {
        color.withAlphaComponent(chrome.isLight ? 0.42 : 0.55).blended(over: chrome)
    }

    /// Feather's own setting first, then whatever VS Code or Peacock set for this project.
    static func color(for root: URL, settings: ProjectSettings? = nil) -> NSColor? {
        if let chosen = (settings ?? ProjectSettings.load(from: root)).color {
            return chosen.lowercased() == none ? nil : NSColor(hexString: chosen)
        }
        return vscodeColor(in: root)
    }

    /// The first window colour VS Code would show, in the order people notice them.
    static func vscodeColor(in root: URL) -> NSColor? {
        let file = root.appendingPathComponent(".vscode/settings.json")
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let data = stripJSONComments(text).data(using: .utf8),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let customizations = settings["workbench.colorCustomizations"] as? [String: Any] ?? [:]
        let candidates: [Any?] = [settings["peacock.color"], customizations["titleBar.activeBackground"],
                                  customizations["statusBar.background"], customizations["activityBar.background"],
                                  customizations["window.activeBorder"]]
        return candidates.lazy.compactMap { ($0 as? String).flatMap(NSColor.init(hexString:)) }.first
    }

    /// VS Code settings are "JSON with comments": `//` and `/* */` comments and trailing commas are allowed.
    static func stripJSONComments(_ text: String) -> String {
        var output = ""
        var characters = text.makeIterator()
        var inString = false, escaped = false
        var pending: Character?
        while let character = pending ?? characters.next() {
            pending = nil
            if inString {
                output.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
                output.append(character)
            } else if character == "/" {
                guard let next = characters.next() else { output.append(character); break }
                if next == "/" {
                    while let skipped = characters.next(), skipped != "\n" {}
                    output.append("\n")
                } else if next == "*" {
                    var previous: Character = " "
                    while let skipped = characters.next() {
                        if previous == "*" && skipped == "/" { break }
                        previous = skipped
                    }
                } else {
                    output.append(character)
                    pending = next
                }
            } else {
                output.append(character)
            }
        }
        return output.replacingOccurrences(of: #",(\s*[}\]])"#, with: "$1", options: .regularExpression)
    }

    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

extension NSColor {
    /// "#RGB", "#RRGGBB" or "#RRGGBBAA".
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let rgb = hex.count == 8 ? value >> 8 : value
        let alpha = hex.count == 8 ? CGFloat(value & 0xFF) / 255 : 1
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }

    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(color.redComponent * 255)), Int(round(color.greenComponent * 255)),
                      Int(round(color.blueComponent * 255)))
    }

    /// Perceived brightness, used to pick readable text on top of a tint.
    var isLight: Bool {
        let color = usingColorSpace(.sRGB) ?? self
        return 0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent > 0.6
    }
}

/// The swatch grid shown inside the Project Color menu.
final class ColorPaletteView: NSView {
    private static let swatch: CGFloat = 18, gap: CGFloat = 4, margin: CGFloat = 14

    init(action: Selector) {
        let rows = ProjectColor.palette
        let columns = rows.first?.count ?? 0
        let step = ColorPaletteView.swatch + ColorPaletteView.gap
        super.init(frame: NSRect(x: 0, y: 0, width: ColorPaletteView.margin * 2 + CGFloat(columns) * step - ColorPaletteView.gap,
                                 height: CGFloat(rows.count) * step + 6))
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, hex) in row.enumerated() {
                let button = NSButton(title: "", target: nil, action: action)      // nil target: goes to the front window
                button.isBordered = false
                button.wantsLayer = true
                button.layer?.backgroundColor = NSColor(hexString: hex)?.cgColor
                button.layer?.cornerRadius = 4
                button.layer?.borderWidth = 0.5
                button.layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
                button.identifier = NSUserInterfaceItemIdentifier(hex)
                button.toolTip = hex
                button.frame = NSRect(x: ColorPaletteView.margin + CGFloat(columnIndex) * step,
                                      y: frame.height - 3 - CGFloat(rowIndex + 1) * step + ColorPaletteView.gap,
                                      width: ColorPaletteView.swatch, height: ColorPaletteView.swatch)
                addSubview(button)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
