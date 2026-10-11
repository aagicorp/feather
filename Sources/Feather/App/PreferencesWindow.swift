import AppKit

/// Settings, laid out as VS Code's: a search box at the top that narrows the list as you type, and the settings
/// below it in headed sections. Every control is built once; searching only hides rows.
final class PreferencesWindowController: NSWindowController, NSSearchFieldDelegate {
    private let searchField = NSSearchField()
    private let noMatches = NSTextField(labelWithString: "")
    private let themePopup = NSPopUpButton()
    private let importThemeButton = NSButton(title: "Import VS Code Theme…", target: nil, action: nil)
    private let deleteThemeButton = NSButton(title: "Delete", target: nil, action: nil)
    private let fontPopup = NSPopUpButton()
    private let fontSizePopup = NSPopUpButton()
    private let terminalSizePopup = NSPopUpButton()
    private let tabWidthPopup = NSPopUpButton()
    private let spacesCheckbox = NSButton(checkboxWithTitle: "Insert spaces when pressing Tab", target: nil, action: nil)
    private let wrapCheckbox = NSButton(checkboxWithTitle: "Wrap long lines", target: nil, action: nil)
    private let lineNumbersCheckbox = NSButton(checkboxWithTitle: "Show line numbers", target: nil, action: nil)
    private let confirmQuitCheckbox = NSButton(checkboxWithTitle: "Ask before quitting or closing a window", target: nil, action: nil)
    private let suggestCheckbox = NSButton(checkboxWithTitle: "Show suggestions while typing", target: nil, action: nil)
    private let scrollSlider = NSSlider(value: 11, minValue: Double(Settings.scrollBarSizeRange.lowerBound),
                                        maxValue: Double(Settings.scrollBarSizeRange.upperBound), target: nil, action: nil)
    private let scrollValue = NSTextField(labelWithString: "")
    private let revealCheckbox = NSButton(checkboxWithTitle: "Reveal the open file in the Explorer", target: nil, action: nil)
    private let compactFoldersCheckbox = NSButton(checkboxWithTitle: "Compact folders: show src › main › java as one row", target: nil, action: nil)
    private let glassCheckbox = NSButton(checkboxWithTitle: "Glass window chrome: the sidebar and bars show the desktop through the theme (macOS 26)", target: nil, action: nil)
    private let restoreCheckbox = NSButton(checkboxWithTitle: "Reopen windows, files and terminals on launch", target: nil, action: nil)
    private let cursorBlinkCheckbox = NSButton(checkboxWithTitle: "Blinking cursor in the terminal", target: nil, action: nil)
    private let commandClickCheckbox = NSButton(checkboxWithTitle: "⌘-click goes to the definition", target: nil, action: nil)
    private let autoCloseCheckbox = NSButton(checkboxWithTitle: "Close brackets and quotes as you type", target: nil, action: nil)
    private let matchBracketsCheckbox = NSButton(checkboxWithTitle: "Highlight matching brackets", target: nil, action: nil)
    private let trimCheckbox = NSButton(checkboxWithTitle: "Trim trailing whitespace on save", target: nil, action: nil)
    private let finalNewlineCheckbox = NSButton(checkboxWithTitle: "End files with a newline on save", target: nil, action: nil)
    private let formatOnSaveCheckbox = NSButton(checkboxWithTitle: "Format on save (needs a language server)", target: nil, action: nil)
    private let autoSavePopup = NSPopUpButton()
    private let blameCheckbox = NSButton(checkboxWithTitle: "Show git blame for the current line in the status bar", target: nil, action: nil)
    private let stickyScrollCheckbox = NSButton(checkboxWithTitle: "Sticky scroll: pin the enclosing blocks’ first lines", target: nil, action: nil)

    private let notifyCheckbox = NSButton(checkboxWithTitle: "Tell me when a terminal is waiting,", target: nil, action: nil)
    private let quietDelayPopup = NSPopUpButton()
    private let soundCheckbox = NSButton(checkboxWithTitle: "Play a sound when a terminal finishes or asks something", target: nil, action: nil)
    private let copyOnSelectCheckbox = NSButton(checkboxWithTitle: "Copy on select in the terminal", target: nil, action: nil)
    private let listIconWell = NSColorWell()
    private let listTextWell = NSColorWell()
    private let listColorsReset = NSButton(title: "Use Theme Colors", target: nil, action: nil)
    private let aiToolPopup = NSPopUpButton()
    private let aiCommandField = NSTextField()
    /// The popup's rows: Automatic, each known tool, then a command of the user's own.
    private static let aiToolOptions = [AITools.automatic] + AITools.all.map(\.id) + [AITools.custom]
    private let followCheckbox = NSButton(checkboxWithTitle: "Follow changes: show each file as it is changed", target: nil, action: nil)
    private let autoCheckpointCheckbox = NSButton(checkboxWithTitle: "Save a checkpoint when a folder is opened", target: nil, action: nil)
    private let previewReloadCheckbox = NSButton(checkboxWithTitle: "Reload the preview when a file changes", target: nil, action: nil)
    private let shortcutsButton = NSButton(title: "Keyboard Shortcuts…", target: nil, action: nil)

    private static let fontSizes = [10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24]
    private static let tabWidths = [2, 4, 8]

    /// One line of the settings list: a section heading or a setting, with the words a search matches against.
    private struct Row {
        let gridRow: NSGridRow
        let section: String
        let text: String            // lowercased; empty for a heading
        var isHeading: Bool { text.isEmpty }
    }
    private var rows: [Row] = []
    private var aiCommandRow: NSGridRow?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        window.center()
        NotificationCenter.default.addObserver(self, selector: #selector(themesChanged), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI() {
        fillThemePopup()

        var families = Set<String>()
        for name in NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [] {
            if let family = NSFont(name: name, size: 12)?.familyName, !family.hasPrefix(".") { families.insert(family) }
        }
        fontPopup.addItems(withTitles: [Settings.systemMonoName] + families.sorted())

        fontSizePopup.addItems(withTitles: Self.fontSizes.map { "\($0) pt" })
        terminalSizePopup.addItems(withTitles: Self.fontSizes.map { "\($0) pt" })
        tabWidthPopup.addItems(withTitles: Self.tabWidths.map { "\($0) spaces" })
        autoSavePopup.addItems(withTitles: AutoSaveController.Mode.allCases.map(\.title))

        let controls: [NSControl] = [themePopup, fontPopup, fontSizePopup, terminalSizePopup, tabWidthPopup,
                                     spacesCheckbox, wrapCheckbox, lineNumbersCheckbox, suggestCheckbox,
                                     commandClickCheckbox, autoCloseCheckbox, matchBracketsCheckbox, trimCheckbox,
                                     finalNewlineCheckbox, formatOnSaveCheckbox, stickyScrollCheckbox, cursorBlinkCheckbox, revealCheckbox, compactFoldersCheckbox, glassCheckbox, restoreCheckbox, confirmQuitCheckbox,
                                     autoSavePopup, blameCheckbox, notifyCheckbox, quietDelayPopup, soundCheckbox, aiToolPopup, aiCommandField,
                                     followCheckbox, autoCheckpointCheckbox, previewReloadCheckbox, listIconWell, listTextWell, listColorsReset,
                                     copyOnSelectCheckbox, importThemeButton, deleteThemeButton, shortcutsButton]
        for well in [listIconWell, listTextWell] {
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        for button in [listColorsReset, importThemeButton, deleteThemeButton, shortcutsButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        shortcutsButton.controlSize = .regular
        quietDelayPopup.addItems(withTitles: Settings.terminalQuietDelays.map { "after \($0) s of silence" })
        aiToolPopup.addItems(withTitles: ["Automatic (the first one installed)"] + AITools.all.map(\.name) + ["My own command:"])
        aiCommandField.placeholderString = "command to start it"
        aiCommandField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        for control in controls {
            control.target = self
            control.action = #selector(controlChanged)
        }

        scrollSlider.target = self
        scrollSlider.action = #selector(scrollSizeChanged)
        scrollSlider.isContinuous = true
        scrollSlider.widthAnchor.constraint(equalToConstant: 170).isActive = true
        func barIcon(_ thickness: CGFloat) -> NSImageView {
            let image = NSImage(size: NSSize(width: 14, height: 16), flipped: false) { rect in
                NSColor.secondaryLabelColor.setFill()
                let bar = NSRect(x: rect.midX - thickness / 2, y: 1, width: thickness, height: rect.height - 2)
                NSBezierPath(roundedRect: bar, xRadius: thickness / 2, yRadius: thickness / 2).fill()
                return true
            }
            return NSImageView(image: image)
        }
        scrollValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        scrollValue.textColor = .secondaryLabelColor
        let scrollRow = NSStackView(views: [barIcon(2.5), scrollSlider, barIcon(9), scrollValue])
        scrollRow.spacing = 8

        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.alignment = .right
            return field
        }
        let empty = NSGridCell.emptyContentView
        let themeRow = NSStackView(views: [themePopup, importThemeButton, deleteThemeButton])
        themeRow.spacing = 6
        let notifyRow = NSStackView(views: [notifyCheckbox, quietDelayPopup])
        notifyRow.spacing = 6
        let listColorsRow = NSStackView(views: [listIconWell, label("icons"), listTextWell, label("names"), listColorsReset])
        listColorsRow.spacing = 6
        listColorsRow.setCustomSpacing(14, after: listColorsRow.arrangedSubviews[1])
        listColorsRow.setCustomSpacing(14, after: listColorsRow.arrangedSubviews[3])

        // The sections, in VS Code's order. A row is (label, control); what a search matches is both, and any
        // checkbox title inside the control.
        let sections: [(String, [(String, NSView)])] = [
            ("Appearance", [
                ("Theme:", themeRow),
                ("Font:", fontPopup),
                ("Editor font size:", fontSizePopup),
                ("Scroll bar size:", scrollRow),
            ]),
            ("Editor", [
                ("Tab width:", tabWidthPopup),
                ("", spacesCheckbox),
                ("", wrapCheckbox),
                ("", lineNumbersCheckbox),
                ("", suggestCheckbox),
                ("", commandClickCheckbox),
                ("", autoCloseCheckbox),
                ("", matchBracketsCheckbox),
                ("", stickyScrollCheckbox),
            ]),
            ("Files & Saving", [
                ("Auto save:", autoSavePopup),
                ("", trimCheckbox),
                ("", finalNewlineCheckbox),
                ("", formatOnSaveCheckbox),
            ]),
            ("Terminal", [
                ("Terminal font size:", terminalSizePopup),
                ("", cursorBlinkCheckbox),
                ("", copyOnSelectCheckbox),
                ("Terminal list:", listColorsRow),
                ("", soundCheckbox),
                ("", notifyRow),
            ]),
            ("AI Assistant", [
                ("AI assistant:", aiToolPopup),
                ("", aiCommandField),
            ]),
            ("Git", [
                ("", blameCheckbox),
            ]),
            ("Preview", [
                ("", previewReloadCheckbox),
            ]),
            ("General", [
                ("", revealCheckbox),
                ("", compactFoldersCheckbox),
                ("", glassCheckbox),
                ("", restoreCheckbox),
                ("", confirmQuitCheckbox),
                ("", followCheckbox),
                ("", autoCheckpointCheckbox),
                ("Keyboard shortcuts:", shortcutsButton),
            ]),
        ]
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        for (section, entries) in sections {
            let heading = NSTextField(labelWithString: section)
            heading.font = .systemFont(ofSize: 15, weight: .semibold)
            let headingRow = grid.addRow(with: [heading, empty])
            grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: grid.numberOfRows - 1, length: 1))
            grid.cell(atColumnIndex: 0, rowIndex: grid.numberOfRows - 1).xPlacement = .leading
            rows.append(Row(gridRow: headingRow, section: section, text: ""))
            for (title, control) in entries {
                let gridRow = grid.addRow(with: [title.isEmpty ? empty : label(title), control])
                rows.append(Row(gridRow: gridRow, section: section, text: (title + " " + Self.words(in: control)).lowercased()))
                if control === aiCommandField { aiCommandRow = gridRow }          // takes no room unless "My own command" is chosen
            }
        }

        guard let content = window?.contentView else { return }
        searchField.placeholderString = "Search settings"
        searchField.delegate = self
        noMatches.textColor = .secondaryLabelColor
        noMatches.alignment = .center
        noMatches.isHidden = true
        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .rounded

        // The list of settings has outgrown a small screen, so it scrolls between the search box and the button.
        let document = FlippedSettingsView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(grid)
        document.addSubview(noMatches)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = document
        for view in [searchField, scroll, reset, noMatches] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        content.addSubview(searchField)
        content.addSubview(scroll)
        content.addSubview(reset)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: reset.topAnchor, constant: -10),
            reset.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            reset.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 20),
            grid.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            grid.topAnchor.constraint(equalTo: document.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -22),
            noMatches.topAnchor.constraint(equalTo: document.topAnchor, constant: 30),
            noMatches.centerXAnchor.constraint(equalTo: document.centerXAnchor),
        ])
        window?.contentMinSize = NSSize(width: 520, height: 360)
        window?.initialFirstResponder = searchField
        syncFromSettings()
    }

    /// The text a search can match inside a control: a checkbox's title, a button's, or the titles of a row of them.
    private static func words(in view: NSView) -> String {
        if let button = view as? NSButton, !(button is NSPopUpButton) { return button.title }
        if let stack = view as? NSStackView { return stack.arrangedSubviews.map(words(in:)).joined(separator: " ") }
        if let field = view as? NSTextField { return field.stringValue }
        return ""
    }

    private func fillThemePopup() {
        themePopup.removeAllItems()
        let builtIns = Theme.builtIns.map(\.name), imported = ThemeStore.shared.themes.map(\.name)
        themePopup.addItems(withTitles: builtIns)
        if !imported.isEmpty {
            themePopup.menu?.addItem(.separator())
            themePopup.addItems(withTitles: imported)
        }
    }

    @objc private func themesChanged() {
        fillThemePopup()
        syncFromSettings()
    }

    // MARK: - Searching

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        filterRows()
    }

    /// Hides every setting whose label, checkbox title or section says nothing like what was typed. A heading
    /// stays only while one of its settings does.
    private func filterRows() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let words = query.split(separator: " ").map(String.init)
        var visibleSections = Set<String>()
        for row in rows where !row.isHeading {
            let haystack = row.text + " " + row.section.lowercased()
            let matches = words.allSatisfy { haystack.contains($0) }
            row.gridRow.isHidden = !matches || (row.gridRow === aiCommandRow && Settings.shared.aiTool != AITools.custom)
            if matches { visibleSections.insert(row.section) }
        }
        // A hidden row's padding would still take room, so only the headings on show get theirs, and not the first.
        var isFirstHeading = true
        for row in rows where row.isHeading {
            row.gridRow.isHidden = !visibleSections.contains(row.section)
            row.gridRow.topPadding = row.gridRow.isHidden || isFirstHeading ? 0 : 14
            if !row.gridRow.isHidden { isFirstHeading = false }
        }
        noMatches.stringValue = "No settings match “\(searchField.stringValue)”"
        noMatches.isHidden = !visibleSections.isEmpty
    }

    // MARK: - Values

    private func syncFromSettings() {
        let settings = Settings.shared
        themePopup.selectItem(withTitle: settings.themeName)
        if themePopup.selectedItem == nil { themePopup.selectItem(at: 0) }
        deleteThemeButton.isEnabled = !settings.theme.isBuiltIn
        fontPopup.selectItem(withTitle: settings.fontName)
        if fontPopup.selectedItem == nil { fontPopup.selectItem(at: 0) }
        fontSizePopup.selectItem(at: Self.nearestIndex(of: settings.fontSize, in: Self.fontSizes))
        terminalSizePopup.selectItem(at: Self.nearestIndex(of: settings.terminalFontSize, in: Self.fontSizes))
        tabWidthPopup.selectItem(at: Self.nearestIndex(of: settings.tabWidth, in: Self.tabWidths))
        spacesCheckbox.state = settings.useSpaces ? .on : .off
        wrapCheckbox.state = settings.wrapLines ? .on : .off
        lineNumbersCheckbox.state = settings.showLineNumbers ? .on : .off
        confirmQuitCheckbox.state = settings.confirmBeforeQuit ? .on : .off
        suggestCheckbox.state = settings.autoSuggest ? .on : .off
        commandClickCheckbox.state = settings.commandClickNavigation ? .on : .off
        autoCloseCheckbox.state = settings.autoCloseBrackets ? .on : .off
        matchBracketsCheckbox.state = settings.matchBrackets ? .on : .off
        trimCheckbox.state = settings.trimTrailingWhitespace ? .on : .off
        finalNewlineCheckbox.state = settings.insertFinalNewline ? .on : .off
        formatOnSaveCheckbox.state = settings.formatOnSave ? .on : .off
        autoSavePopup.selectItem(at: AutoSaveController.Mode.allCases.firstIndex(of: settings.autoSaveMode) ?? 0)
        stickyScrollCheckbox.state = settings.stickyScroll ? .on : .off
        cursorBlinkCheckbox.state = settings.terminalCursorBlink ? .on : .off
        restoreCheckbox.state = settings.restoreSession ? .on : .off
        revealCheckbox.state = settings.revealInExplorer ? .on : .off
        compactFoldersCheckbox.state = settings.compactFolders ? .on : .off
        glassCheckbox.state = settings.glassChrome ? .on : .off
        if #available(macOS 26, *) { glassCheckbox.isEnabled = true } else { glassCheckbox.isEnabled = false }
        blameCheckbox.state = settings.showBlame ? .on : .off
        followCheckbox.state = settings.followChanges ? .on : .off
        autoCheckpointCheckbox.state = settings.autoCheckpoint ? .on : .off
        previewReloadCheckbox.state = settings.previewReloadsOnChange ? .on : .off
        scrollSlider.integerValue = settings.scrollBarSize
        scrollValue.stringValue = "\(settings.scrollBarSize) pt"
        notifyCheckbox.state = settings.notifyWhenTerminalWaits ? .on : .off
        quietDelayPopup.selectItem(at: Self.nearestIndex(of: settings.terminalQuietDelay, in: Settings.terminalQuietDelays))
        quietDelayPopup.isEnabled = settings.notifyWhenTerminalWaits
        soundCheckbox.state = settings.terminalSound ? .on : .off
        copyOnSelectCheckbox.state = settings.terminalCopyOnSelect ? .on : .off
        listIconWell.color = settings.terminalListIcon
        listTextWell.color = settings.terminalListText
        listColorsReset.isEnabled = settings.terminalListIconColor != nil || settings.terminalListTextColor != nil
        aiToolPopup.selectItem(at: Self.aiToolOptions.firstIndex(of: settings.aiTool) ?? 0)
        aiCommandField.stringValue = settings.aiToolCustomCommand
        filterRows()
    }

    private static func nearestIndex(of value: Int, in options: [Int]) -> Int {
        options.enumerated().min { abs($0.element - value) < abs($1.element - value) }?.offset ?? 0
    }

    override func showWindow(_ sender: Any?) {
        syncFromSettings()
        super.showWindow(sender)
    }

    @objc private func controlChanged(_ sender: NSControl) {
        let settings = Settings.shared
        switch sender {
        case themePopup:
            settings.themeName = themePopup.titleOfSelectedItem ?? "Dark"
            deleteThemeButton.isEnabled = !settings.theme.isBuiltIn
        case importThemeButton: (NSApp.delegate as? AppDelegate)?.importVSCodeTheme(sender)
        case deleteThemeButton: deleteTheme()
        case shortcutsButton: (NSApp.delegate as? AppDelegate)?.showKeyboardShortcuts(sender)
        case fontPopup: settings.fontName = fontPopup.titleOfSelectedItem ?? Settings.systemMonoName
        case fontSizePopup: settings.fontSize = Self.fontSizes[fontSizePopup.indexOfSelectedItem]
        case terminalSizePopup: settings.terminalFontSize = Self.fontSizes[terminalSizePopup.indexOfSelectedItem]
        case tabWidthPopup: settings.tabWidth = Self.tabWidths[tabWidthPopup.indexOfSelectedItem]
        case spacesCheckbox: settings.useSpaces = spacesCheckbox.state == .on
        case wrapCheckbox: settings.wrapLines = wrapCheckbox.state == .on
        case lineNumbersCheckbox: settings.showLineNumbers = lineNumbersCheckbox.state == .on
        case confirmQuitCheckbox: settings.confirmBeforeQuit = confirmQuitCheckbox.state == .on
        case suggestCheckbox: settings.autoSuggest = suggestCheckbox.state == .on
        case commandClickCheckbox: settings.commandClickNavigation = commandClickCheckbox.state == .on
        case autoCloseCheckbox: settings.autoCloseBrackets = autoCloseCheckbox.state == .on
        case matchBracketsCheckbox: settings.matchBrackets = matchBracketsCheckbox.state == .on
        case trimCheckbox: settings.trimTrailingWhitespace = trimCheckbox.state == .on
        case finalNewlineCheckbox: settings.insertFinalNewline = finalNewlineCheckbox.state == .on
        case formatOnSaveCheckbox: settings.formatOnSave = formatOnSaveCheckbox.state == .on
        case autoSavePopup: settings.autoSaveMode = AutoSaveController.Mode.allCases[max(0, autoSavePopup.indexOfSelectedItem)]
        case stickyScrollCheckbox: settings.stickyScroll = stickyScrollCheckbox.state == .on
        case cursorBlinkCheckbox: settings.terminalCursorBlink = cursorBlinkCheckbox.state == .on
        case restoreCheckbox: settings.restoreSession = restoreCheckbox.state == .on
        case revealCheckbox: settings.revealInExplorer = revealCheckbox.state == .on
        case compactFoldersCheckbox: settings.compactFolders = compactFoldersCheckbox.state == .on
        case glassCheckbox: settings.glassChrome = glassCheckbox.state == .on
        case blameCheckbox: settings.showBlame = blameCheckbox.state == .on
        case notifyCheckbox:
            settings.notifyWhenTerminalWaits = notifyCheckbox.state == .on
            quietDelayPopup.isEnabled = settings.notifyWhenTerminalWaits
        case quietDelayPopup: settings.terminalQuietDelay = Settings.terminalQuietDelays[max(0, quietDelayPopup.indexOfSelectedItem)]
        case soundCheckbox: settings.terminalSound = soundCheckbox.state == .on
        case copyOnSelectCheckbox: settings.terminalCopyOnSelect = copyOnSelectCheckbox.state == .on
        case listIconWell: settings.terminalListIconColor = listIconWell.color.hexString; listColorsReset.isEnabled = true
        case listTextWell: settings.terminalListTextColor = listTextWell.color.hexString; listColorsReset.isEnabled = true
        case listColorsReset:
            settings.terminalListIconColor = nil
            settings.terminalListTextColor = nil
            syncFromSettings()
        case aiToolPopup:
            settings.aiTool = Self.aiToolOptions[max(0, aiToolPopup.indexOfSelectedItem)]
            filterRows()
        case aiCommandField: settings.aiToolCustomCommand = aiCommandField.stringValue
        case followCheckbox: settings.followChanges = followCheckbox.state == .on
        case autoCheckpointCheckbox: settings.autoCheckpoint = autoCheckpointCheckbox.state == .on
        case previewReloadCheckbox: settings.previewReloadsOnChange = previewReloadCheckbox.state == .on
        default: break
        }
    }

    /// Removes the chosen imported theme's file; the editor goes back to the default theme.
    private func deleteTheme() {
        let theme = Settings.shared.theme
        guard !theme.isBuiltIn else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the theme “\(theme.name)”?"
        alert.informativeText = "It can be imported again from its VS Code theme file."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Settings.shared.themeName = Theme.builtIns[theme.isDark ? 0 : 1].name
        ThemeStore.shared.delete(named: theme.name)
    }

    @objc private func scrollSizeChanged() {
        let size = scrollSlider.integerValue
        guard size != Settings.shared.scrollBarSize else { return }
        Settings.shared.scrollBarSize = size            // every window re-lays out its scroll bars as you drag
        scrollValue.stringValue = "\(size) pt"
    }

    @objc private func resetDefaults() {
        Settings.shared.resetToDefaults()
        syncFromSettings()
    }
}

/// The scrolling settings list starts at the top, not the bottom.
private final class FlippedSettingsView: NSView {
    override var isFlipped: Bool { true }
}
