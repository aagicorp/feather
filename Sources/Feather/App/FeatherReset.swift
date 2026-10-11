import AppKit

/// Puts Feather back to a first install: its defaults domain and the state it keeps under Application Support,
/// but never a project's own files. Used by Feather ▸ Reset Feather… and by `Feather --reset` from a terminal
/// (for the case where the app does not come up at all).
enum FeatherReset {
    /// What is removed from Application Support/Feather. Language servers the person installed are kept: they
    /// are large downloads, and never the cause of a bad start.
    static let stateFolders = ["checkpoints", "api", "shell", "themes"]

    static func perform(defaults: UserDefaults = .standard, applicationSupport: URL? = nil) {
        if let bundle = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundle)
        } else {
            for key in defaults.dictionaryRepresentation().keys { defaults.removeObject(forKey: key) }
        }
        defaults.synchronize()
        let support = applicationSupport ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")).appendingPathComponent("Feather")
        for folder in stateFolders {
            try? FileManager.default.removeItem(at: support.appendingPathComponent(folder))
        }
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("Feather"))
    }
}
