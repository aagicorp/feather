import AppKit

/// One keyboard shortcut as a menu item carries it: the key-equivalent string and its modifiers.
struct KeyBinding: Equatable {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        // An uppercase letter is AppKit's other way of saying "with Shift"; keep one spelling.
        if key.count == 1, let scalar = key.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(scalar) {
            self.key = key.lowercased()
            self.modifiers = modifiers.intersection(KeyBinding.relevantModifiers).union(.shift)
        } else {
            self.key = key
            self.modifiers = modifiers.intersection(KeyBinding.relevantModifiers)
        }
    }

    init?(item: NSMenuItem) {
        guard !item.keyEquivalent.isEmpty else { return nil }
        self.init(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
    }

    /// The keys a key-down event names, or nil for a bare modifier press.
    init?(event: NSEvent) {
        guard event.type == .keyDown, let typed = event.charactersIgnoringModifiers, !typed.isEmpty else { return nil }
        self.init(key: typed, modifiers: event.modifierFlags)
    }

    // MARK: Portable text, "cmd+shift+p", the form kept in the settings

    private static let names: [String: String] = [
        "\r": "enter", "\t": "tab", " ": "space", "\u{1B}": "escape", "\u{8}": "backspace", "\u{7F}": "backspace",
        "\u{F700}": "up", "\u{F701}": "down", "\u{F702}": "left", "\u{F703}": "right",
        "\u{F728}": "delete", "\u{F729}": "home", "\u{F72B}": "end", "\u{F72C}": "pageup", "\u{F72D}": "pagedown",
    ]
    private static let keysByName: [String: String] = {
        var table = Dictionary(uniqueKeysWithValues: names.filter { $0.key != "\u{7F}" }.map { ($0.value, $0.key) })
        for number in 1...19 { table["f\(number)"] = String(UnicodeScalar(0xF703 + number).map(Character.init) ?? "?") }
        return table
    }()

    var portable: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(KeyBinding.name(of: key))
        return parts.joined(separator: "+")
    }

    private static func name(of key: String) -> String {
        if let name = names[key] { return name }
        if let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1, (0xF704...0xF716).contains(scalar.value) {
            return "f\(scalar.value - 0xF703)"
        }
        return key
    }

    /// Nil for text that names no key. Modifier words may be spelt as VS Code, Electron or macOS users spell them.
    init?(portable text: String) {
        var parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "cmd++" is the plus key itself: the split leaves two empty pieces at the end.
        var key = parts.popLast() ?? ""
        if key.isEmpty, parts.last == "" { parts.removeLast(); key = "+" }
        guard !key.isEmpty else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts {
            switch part {
            case "cmd", "command", "meta", "⌘": modifiers.insert(.command)
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            case "alt", "opt", "option", "⌥": modifiers.insert(.option)
            case "shift", "⇧": modifiers.insert(.shift)
            default: return nil
            }
        }
        if let named = KeyBinding.keysByName[key] { key = named } else if key.count != 1 { return nil }
        self.init(key: key, modifiers: modifiers)
    }

    // MARK: On screen, "⇧⌘P"

    private static let symbols: [String: String] = [
        "\r": "↩", "\t": "⇥", " ": "Space", "\u{1B}": "Esc", "\u{8}": "⌫", "\u{7F}": "⌫",
        "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→",
        "\u{F728}": "⌦", "\u{F729}": "↖", "\u{F72B}": "↘", "\u{F72C}": "⇞", "\u{F72D}": "⇟",
        // Menu items keep a shifted character; people read the key on the cap.
        "|": "\\", "_": "-", "{": "[", "}": "]", "+": "=", "~": "`",
    ]

    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        if let symbol = KeyBinding.symbols[key] { return text + symbol }
        if let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1, (0xF704...0xF716).contains(scalar.value) {
            return text + "F\(scalar.value - 0xF703)"
        }
        return text + key.uppercased()
    }

    /// A shortcut without ⌘, ⌃ or ⌥ would take a key away from typing, unless it is a function key or Escape.
    var isUsable: Bool {
        if !modifiers.intersection([.command, .control, .option]).isEmpty { return true }
        guard let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1 else { return false }
        return (0xF704...0xF716).contains(scalar.value) || scalar.value == 0x1B
    }
}

/// The user's own shortcuts for menu commands, and the commands' default ones, gathered while the menu bar is
/// built. `Settings.keyBindings` holds the overrides; AppDelegate.buildMenu's `item` helper asks `apply(to:)` for
/// every item, and rebuilds the menu bar after a change so the new keys take effect at once.
final class KeyBindings {
    static let shared = KeyBindings()
    /// The value in the settings for a command that should have no shortcut at all.
    static let none = "none"

    private var overrides: [String: String]
    /// What each command's shortcut is before any override (so a row can be reset), by command id.
    private(set) var defaults: [String: KeyBinding?] = [:]
    /// What each command's shortcut is now, by command id. Kept here because an editor-only key (EditorOnlyKeys)
    /// reads as empty on the menu item itself while the editor does not have the keyboard.
    private(set) var effective: [String: KeyBinding?] = [:]

    init(overrides: [String: String] = Settings.shared.keyBindings) {
        self.overrides = overrides
    }

    /// A command is its action; the few items that share one (the Find items) are told apart by their tag.
    static func commandID(for action: Selector, tag: Int = 0) -> String {
        tag == 0 ? NSStringFromSelector(action) : NSStringFromSelector(action) + "#\(tag)"
    }

    static func commandID(of item: NSMenuItem) -> String? {
        item.action.map { commandID(for: $0, tag: item.tag) }
    }

    /// Notes the item's default shortcut and puts the user's own on it, if there is one.
    func apply(to item: NSMenuItem) {
        guard let id = KeyBindings.commandID(of: item) else { return }
        let standard = KeyBinding(item: item)
        if defaults[id] == nil { defaults[id] = standard }
        if let text = overrides[id] {
            let binding = text == KeyBindings.none ? nil : KeyBinding(portable: text)
            item.keyEquivalent = binding?.key ?? ""
            item.keyEquivalentModifierMask = binding?.modifiers ?? []
            effective[id] = binding
        } else {
            effective[id] = standard
        }
    }

    func isCustom(_ id: String) -> Bool { overrides[id] != nil }

    /// Nil restores the default; `.some(nil)` means no shortcut.
    func setBinding(_ binding: KeyBinding??, for id: String) {
        switch binding {
        case .none: overrides[id] = nil
        case .some(.none): overrides[id] = KeyBindings.none
        case .some(.some(let binding)): overrides[id] = binding.portable
        }
        Settings.shared.keyBindings = overrides
    }

    func resetAll() {
        overrides = [:]
        Settings.shared.keyBindings = [:]
    }

    /// Reread before the menu bar is rebuilt, so `defaults` and `effective` describe the new menu.
    func reload() {
        overrides = Settings.shared.keyBindings
        defaults = [:]
        effective = [:]
    }

    /// For every command whose shortcut another command also has: the ids of the others.
    static func conflicts(among bindings: [(id: String, binding: KeyBinding)]) -> [String: [String]] {
        var byKeys: [String: [String]] = [:]
        for entry in bindings { byKeys[entry.binding.portable, default: []].append(entry.id) }
        var result: [String: [String]] = [:]
        for ids in byKeys.values where ids.count > 1 {
            for id in ids { result[id] = ids.filter { $0 != id } }
        }
        return result
    }
}

// MARK: - Help ▸ Keyboard Shortcuts

/// Every menu command with its keys, as VS Code's Keyboard Shortcuts editor shows them. Double-click a row (or
/// Change), press the new keys, then Return.
final class KeyboardShortcutsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private struct Row {
        let id: String
        let title: String
        let binding: KeyBinding?
        let isCustom: Bool
        var conflicts: [String] = []
    }

    private var rows: [Row] = []
    private var shown: [Int] = []
    private let search = NSSearchField()
    private let table = NSTableView()
    private let changeButton = NSButton(title: "Change", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private let resetAllButton = NSButton(title: "Reset All", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let recorder = KeyRecorderView()
    /// The row being changed and the keys pressed so far, while recording.
    private var recording: (row: Int, pending: KeyBinding??)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = "Keyboard Shortcuts"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        search.placeholderString = "Type to search by command or keys"
        search.delegate = self

        for (identifier, title, width) in [("command", "Command", 360), ("keys", "Keys", 150), ("source", "Source", 90)] as [(String, String, CGFloat)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = 60
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.allowsMultipleSelection = false
        table.doubleAction = #selector(beginRecording)
        table.target = self
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        for button in [changeButton, resetButton, resetAllButton] {
            button.bezelStyle = .rounded
            button.target = self
        }
        changeButton.action = #selector(beginRecording)
        changeButton.keyEquivalent = ""
        resetButton.action = #selector(resetRow)
        resetAllButton.action = #selector(resetAll)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        recorder.onKey = { [weak self] binding in self?.recorded(binding) }
        recorder.isHidden = true

        let buttons = NSStackView(views: [changeButton, resetButton, NSView(), resetAllButton])
        buttons.spacing = 8
        let bottom = NSStackView(views: [recorder, hint, buttons])
        bottom.orientation = .vertical
        bottom.alignment = .leading
        bottom.spacing = 8
        for view in [search, scroll, bottom] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            bottom.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bottom.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            buttons.widthAnchor.constraint(equalTo: bottom.widthAnchor),
            recorder.widthAnchor.constraint(equalTo: bottom.widthAnchor),
            recorder.heightAnchor.constraint(equalToConstant: 34),
            hint.widthAnchor.constraint(equalTo: bottom.widthAnchor),
        ])
        window?.contentMinSize = NSSize(width: 520, height: 320)
        window?.initialFirstResponder = search
    }

    override func showWindow(_ sender: Any?) {
        reload()
        super.showWindow(sender)
    }

    // MARK: Rows

    /// Walks the menu bar as the Command Palette does, so every command is here without being listed twice.
    private func reload() {
        var found: [Row] = []
        let bindings = KeyBindings.shared
        func walk(_ menu: NSMenu, path: [String]) {
            for item in menu.items where !item.isSeparatorItem && !item.isHidden && !item.title.isEmpty {
                if let submenu = item.submenu {
                    if submenu.title == "Open Recent" || submenu.title == "Choose AI Assistant" { continue }
                    walk(submenu, path: path + [item.title])
                } else if let id = KeyBindings.commandID(of: item) {
                    let prefix = path.dropFirst(path.first == "Feather" ? 1 : 0).joined(separator: " ▸ ")
                    let binding = bindings.effective[id] ?? KeyBinding(item: item)
                    found.append(Row(id: id, title: prefix.isEmpty ? item.title : prefix + ": " + item.title,
                                     binding: binding, isCustom: bindings.isCustom(id)))
                }
            }
        }
        if let main = NSApp.mainMenu { walk(main, path: []) }
        let conflicts = KeyBindings.conflicts(among: found.compactMap { row in row.binding.map { (row.id, $0) } })
        let titles = Dictionary(found.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        rows = found.map { row in
            var row = row
            row.conflicts = (conflicts[row.id] ?? []).compactMap { titles[$0] }
            return row
        }
        filter()
    }

    private func filter() {
        let typed = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        shown = rows.indices.filter { index in
            typed.isEmpty || rows[index].title.lowercased().contains(typed) || rows[index].binding?.display.lowercased().contains(typed) == true
                || rows[index].binding?.portable.contains(typed) == true
        }
        table.reloadData()
        updateButtons()
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === search { filter() }
    }

    private var selectedRow: Row? {
        let index = table.selectedRow
        return shown.indices.contains(index) ? rows[shown[index]] : nil
    }

    private func updateButtons() {
        let row = selectedRow
        changeButton.isEnabled = row != nil && recording == nil
        resetButton.isEnabled = row?.isCustom == true && recording == nil
        resetAllButton.isEnabled = rows.contains { $0.isCustom } && recording == nil
        if recording == nil {
            hint.stringValue = rows.contains { !$0.conflicts.isEmpty }
                ? "Keys shown in red are used by more than one command; the first one in the menus wins."
                : "Double-click a command (or select it and choose Change), press the new keys, then Return."
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let tableColumn, shown.indices.contains(index) else { return nil }
        let row = rows[shown[index]]
        let identifier = NSUserInterfaceItemIdentifier("cell-" + tableColumn.identifier.rawValue)
        let cell = (table.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView) ?? makeCell(identifier)
        guard let field = cell.textField else { return cell }
        field.textColor = .labelColor
        field.toolTip = nil
        switch tableColumn.identifier.rawValue {
        case "command":
            field.stringValue = row.title
        case "keys":
            if let recording, recording.row == shown[index] {
                field.stringValue = recording.pending.map { $0?.display ?? "(no shortcut)" } ?? "Press the new keys…"
                field.textColor = .controlAccentColor
            } else {
                field.stringValue = row.binding?.display ?? ""
                if !row.conflicts.isEmpty {
                    field.textColor = .systemRed
                    field.toolTip = "Also used by: " + row.conflicts.joined(separator: ", ")
                }
            }
        default:
            field.stringValue = row.isCustom ? "Custom" : "Default"
            field.textColor = row.isCustom ? .labelColor : .secondaryLabelColor
        }
        return cell
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Changing a shortcut

    @objc private func beginRecording() {
        let index = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard shown.indices.contains(index) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        recording = (shown[index], nil)
        recorder.isHidden = false
        recorder.text = "Press the new keys for “\(rows[shown[index]].title)”"
        hint.stringValue = "Then press Return to save. Esc cancels; ⌫ leaves the command without a shortcut."
        window?.makeFirstResponder(recorder)
        table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(0..<table.numberOfColumns))
        updateButtons()
    }

    private func recorded(_ binding: KeyBinding) {
        guard let current = recording else { return }
        let bare = binding.modifiers.isEmpty
        switch (binding.key, bare) {
        case ("\u{1B}", true):
            endRecording()
        case ("\r", true):
            if let pending = current.pending { commit(pending, for: rows[current.row].id) } else { endRecording() }
        case ("\u{7F}", true), ("\u{8}", true):
            recording?.pending = .some(nil)
            recorder.text = "No shortcut. Press Return to save."
            refreshRecordingRow()
        default:
            guard binding.isUsable else {
                recorder.text = "\(binding.display) alone would stop you typing it. Add ⌘, ⌃ or ⌥."
                return
            }
            recording?.pending = .some(binding)
            let taken = rows.filter { $0.id != rows[current.row].id && $0.binding == binding }.map(\.title)
            recorder.text = taken.isEmpty
                ? "\(binding.display) — press Return to save"
                : "\(binding.display) is already used by \(taken.joined(separator: ", ")). Return saves it anyway."
            refreshRecordingRow()
        }
    }

    private func refreshRecordingRow() {
        guard let recording, let index = shown.firstIndex(of: recording.row) else { return }
        table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(0..<table.numberOfColumns))
    }

    private func commit(_ binding: KeyBinding?, for id: String) {
        KeyBindings.shared.setBinding(.some(binding), for: id)
        endRecording()
        applyToMenus()
    }

    private func endRecording() {
        recording = nil
        recorder.isHidden = true
        window?.makeFirstResponder(table)
        table.reloadData()
        updateButtons()
    }

    @objc private func resetRow() {
        guard let row = selectedRow else { return }
        KeyBindings.shared.setBinding(nil, for: row.id)
        applyToMenus()
    }

    @objc private func resetAll() {
        KeyBindings.shared.resetAll()
        applyToMenus()
    }

    /// The menu bar is built from scratch, so the keys change everywhere at once (menus, palette, this list).
    private func applyToMenus() {
        let selected = selectedRow?.id
        (NSApp.delegate as? AppDelegate)?.rebuildMenu()
        reload()
        if let selected, let index = shown.firstIndex(where: { rows[$0].id == selected }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
        updateButtons()
    }
}

/// Takes every key press, including ones the menu bar would otherwise claim, while a shortcut is being changed.
final class KeyRecorderView: NSView {
    var onKey: ((KeyBinding) -> Void)?
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let binding = KeyBinding(event: event) { onKey?(binding) }
    }

    /// ⌘-combinations reach the window before the menu bar; taking them here is what lets ⌘S be recorded.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !isHidden, window?.firstResponder === self, let binding = KeyBinding(event: event) else { return false }
        onKey?(binding)
        return true
    }
}
