import AppKit

/// The project colour: the tint on the title bar, status bar and dividers, and the Project Color menu's actions.
extension MainWindowController {
    /// Tints the title bar, status bar and the dividers between panes (which show the window background).
    /// Reads the project's settings from disk (once), then applies them.
    func applyProjectColor() {
        let settings = sidebar.rootURL.map { ProjectSettings.load(from: $0) }
        projectBorderEnabled = settings?.border ?? false
        let tint = sidebar.rootURL.flatMap { ProjectColor.color(for: $0, settings: settings) }
        applyTint(tint, border: projectBorderEnabled)
    }

    /// Purely in memory, so it is cheap enough to call on every tick of a colour-panel drag.
    func applyTint(_ chosen: NSColor?, border wantsBorder: Bool) {
        let theme = Settings.shared.theme
        let tint = chosen.map { ProjectColor.chromeTint($0, over: theme.chrome) }     // dyed into the chrome, not painted
        window?.backgroundColor = tint ?? theme.chrome
        rootBackdrop?.tint(tint ?? theme.chrome, solid: tint != nil)       // the ground the panels float on takes the project colour, like the bars
        // A layer's border is drawn over its sublayers, so this frames every pane down both sides of the window.
        rootView?.layer?.borderColor = tint?.cgColor
        rootView?.layer?.borderWidth = tint != nil && wantsBorder ? 3 : 0
        statusBar.tint = tint
        header.tint = tint
        activityBar.tint = tint
        currentTint = tint
        updateTitleSearch()
        statusBar.update(tab: editorArea.currentTab, lsp: lsp)
    }

    private func setProjectColor(_ value: String?) {
        guard let root = sidebar.rootURL else { NSSound.beep(); return }
        ProjectSettings.update(in: root, ["color": value])
        store.syncWithDisk(refreshGitBases: false)     // in case .feather/settings.json is open in a tab
        applyProjectColor()
    }

    /// "Use Color from .vscode/settings.json" (no value: the key is removed) and "No Color" ("none").
    @objc func chooseProjectColor(_ sender: NSMenuItem) {
        NSColorPanel.shared.close()
        setProjectColor(sender.representedObject as? String)
    }

    /// A swatch in the palette; its identifier carries the colour.
    @objc func chooseProjectColorFromPalette(_ sender: NSButton) {
        sender.enclosingMenuItem?.menu?.cancelTracking()
        NSColorPanel.shared.close()
        setProjectColor(sender.identifier?.rawValue)
    }

    @objc func toggleProjectBorder(_ sender: Any?) {
        guard let root = sidebar.rootURL else { NSSound.beep(); return }
        ProjectSettings.update(in: root, ["border": !projectBorderEnabled])
        store.syncWithDisk(refreshGitBases: false)
        applyProjectColor()
    }

    @objc func openProjectSettings(_ sender: Any?) {
        guard let root = sidebar.rootURL else { NSSound.beep(); return }
        editorArea.open(ProjectSettings.createIfMissing(in: root, currentColor: ProjectColor.color(for: root)))
    }

    @objc func chooseCustomProjectColor(_ sender: Any?) {
        guard let root = sidebar.rootURL else { NSSound.beep(); return }
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = ProjectColor.color(for: root) ?? NSColor(hex: 0x3B0764)
        panel.setTarget(self)
        panel.setAction(#selector(customProjectColorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func customProjectColorChanged(_ sender: NSColorPanel) {
        guard window?.isMainWindow == true || window?.isKeyWindow == true, sidebar.rootURL != nil else { return }
        // The panel fires continuously while dragging: show the colour at once, write the file when the drag settles.
        applyTint(sender.color, border: projectBorderEnabled)
        let hex = sender.color.hexString
        colorWriteWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setProjectColor(hex) }
        colorWriteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
