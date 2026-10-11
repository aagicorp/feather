import AppKit

/// "What's New": the project's CHANGELOG.md, which build.sh puts inside the app and release.sh turns into the
/// notes shown in the update window, so the two can never disagree.
enum ReleaseNotes {
    private static let seenKey = "releaseNotesSeenVersion"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
    }

    private static var source: URL? {
        if let bundled = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md") { return bundled }
        // The bare binary run from the repository during development.
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("CHANGELOG.md")
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    /// Opens the notes as a rendered page. It is a copy in the temporary folder: the original is inside the signed
    /// app, where an accidental edit and save would break the signature.
    static func show(in controller: MainWindowController) {
        guard let source, let text = try? String(contentsOf: source, encoding: .utf8) else { NSSound.beep(); return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Feather", isDirectory: true)
        let copy = folder.appendingPathComponent("What's New in Feather.md")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try page(from: text, version: version).write(to: copy, atomically: true, encoding: .utf8)
        } catch { NSSound.beep(); return }
        controller.open(copy)
        if controller.editorArea.currentTab?.isPreviewing == false { controller.toggleMarkdownPreview(nil) }
        if let window = controller.window {
            let card = NoticeCard(kind: "whats-new", symbol: "arrow.down.circle",
                                  text: "You have Feather \(version). Updates arrive by themselves once a day; this checks right now.",
                                  actions: [.init(title: "Check for Updates", isProminent: true) { AppUpdater.shared.checkForUpdates(nil) }],
                                  dismissTitle: "OK")
            WindowNotices.show(card, in: window)
        }
    }

    /// The notes with a line at the top saying which version this is and where to check for a newer one. The link
    /// is a feather:// address the app itself answers (AppDelegate), so it works inside the rendered page.
    static func page(from changelog: String, version: String) -> String {
        let header = "> **You have Feather \(version).** [Check for Updates](feather://check-updates) · Updates also arrive by themselves, once a day.\n\n"
        guard let title = changelog.range(of: "\n", options: []), changelog.hasPrefix("# ") else { return header + changelog }
        // Under the title, above the first version.
        return String(changelog[..<title.upperBound]) + "\n" + header + String(changelog[title.upperBound...]).trimmingCharacters(in: .newlines) + "\n"
    }

    /// Once after an update. A first install is greeted by the welcome page instead.
    static func showIfUpdated(in controller: MainWindowController) {
        guard Bundle.main.bundleIdentifier != nil, notesAreDue() else { return }
        show(in: controller)
    }

    /// Remembers that `version` has run and says whether its notes are due: only when an earlier version was
    /// seen before. Kept apart from the window so it can be tested.
    static func notesAreDue(defaults: UserDefaults = .standard, version: String = version) -> Bool {
        let seen = defaults.string(forKey: seenKey)
        guard seen != version else { return false }
        defaults.set(version, forKey: seenKey)
        return seen != nil
    }
}
