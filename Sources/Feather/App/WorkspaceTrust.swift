import AppKit

/// Which folders the user has said they trust. Opening a project is not the same as trusting it: a folder that
/// was cloned or downloaded can carry a run command, a language-server plugin or a git hook that executes as
/// soon as an editor helps with it. In an untrusted folder ("Restricted Mode") Feather only reads and edits:
/// no language servers, no Run, no git. The terminal stays available, because there the user types the commands.
final class WorkspaceTrust {
    static let shared = WorkspaceTrust()
    static let didChange = Notification.Name("FeatherWorkspaceTrustDidChange")

    enum Answer { case trust, trustParent, restricted }

    private let defaults: UserDefaults
    private let lock = NSLock()
    /// Guarded by `lock`: git asks from background queues.
    private var trusted: Set<String>
    private var restrictedRoots = Set<String>()
    private var isEnabledCached: Bool

    private convenience init() { self.init(defaults: .standard) }

    /// Tests build their own on a throwaway suite; the app has `shared` on the standard defaults.
    init(defaults: UserDefaults, recentFolders: [URL] = Settings.shared.recentFolders) {
        self.defaults = defaults
        defaults.register(defaults: ["workspaceTrustEnabled": true])
        isEnabledCached = defaults.bool(forKey: "workspaceTrustEnabled")
        trusted = Set(defaults.stringArray(forKey: "trustedFolders") ?? [])
        // The first launch with this feature: folders already worked in are not strangers.
        if !defaults.bool(forKey: "trustedFoldersSeeded") {
            defaults.set(true, forKey: "trustedFoldersSeeded")
            trusted.formUnion(recentFolders.map { WorkspaceTrust.key($0.path) })
            defaults.set(Array(trusted).sorted(), forKey: "trustedFolders")
        }
    }

    /// One spelling per folder. Foundation only folds /private/tmp into /tmp for paths that exist, and a folder
    /// asked about may not exist (yet, or any more), so that part is done here.
    static func key(_ path: String) -> String {          // internal so the spelling rule can be tested
        var path = URL(fileURLWithPath: path).standardizedFileURL.path
        for prefix in ["/private/tmp", "/private/var", "/private/etc"] where path == prefix || path.hasPrefix(prefix + "/") {
            path.removeFirst("/private".count)
        }
        return path
    }

    var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isEnabledCached }
        set {
            lock.lock(); isEnabledCached = newValue; lock.unlock()
            defaults.set(newValue, forKey: "workspaceTrustEnabled")
            NotificationCenter.default.post(name: WorkspaceTrust.didChange, object: nil)
        }
    }

    /// A folder is trusted when it, or a folder above it, was trusted. A window without a folder is trusted:
    /// there is no project there to run anything from.
    func isTrusted(_ folder: URL?) -> Bool {
        guard let folder else { return true }
        let path = WorkspaceTrust.key(folder.path)
        lock.lock(); defer { lock.unlock() }
        guard isEnabledCached else { return true }
        return trusted.contains { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
    }

    func trust(_ folder: URL) {
        lock.lock()
        trusted.insert(WorkspaceTrust.key(folder.path))
        let list = Array(trusted).sorted()
        lock.unlock()
        defaults.set(list, forKey: "trustedFolders")
        NotificationCenter.default.post(name: WorkspaceTrust.didChange, object: nil)
    }

    func revoke(_ folder: URL) {
        lock.lock()
        trusted.remove(WorkspaceTrust.key(folder.path))
        let list = Array(trusted).sorted()
        lock.unlock()
        defaults.set(list, forKey: "trustedFolders")
        NotificationCenter.default.post(name: WorkspaceTrust.didChange, object: nil)
    }

    var trustedFolders: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(trusted).sorted()
    }

    /// Windows report the folder they have open, so git can be refused below an untrusted one without every
    /// caller having to know about trust.
    func noteOpen(_ folder: URL, restricted: Bool) {
        let path = WorkspaceTrust.key(folder.path)
        lock.lock()
        if restricted { restrictedRoots.insert(path) } else { restrictedRoots.remove(path) }
        lock.unlock()
    }

    func noteClosed(_ folder: URL) {
        lock.lock(); restrictedRoots.remove(WorkspaceTrust.key(folder.path)); lock.unlock()
    }

    /// True when `directory` lies in a folder that is open in Restricted Mode. Safe from any thread.
    func blocksExecution(in directory: URL) -> Bool {
        let path = WorkspaceTrust.key(directory.path)
        lock.lock(); defer { lock.unlock() }
        guard isEnabledCached, !restrictedRoots.isEmpty else { return false }
        guard restrictedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return false }
        return !trusted.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    // MARK: - Asking

    /// The question VS Code asks, with the same three answers.
    func ask(about folder: URL, in window: NSWindow?) -> Answer {
        let parent = folder.deletingLastPathComponent()
        let alert = NSAlert()
        alert.messageText = "Do you trust the files in “\(folder.lastPathComponent)”?"
        alert.informativeText = """
            \(folder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))

            If you trust this folder, Feather can run the project for you, check the code for mistakes as you \
            type, and keep track of what changes. Doing so can run code that came with the project.

            If you are not sure where these files came from, open it in Restricted Mode: you can still look \
            around, search and edit, and you can trust it later from the bottom of the window.
            """
        alert.addButton(withTitle: "Trust Folder")
        alert.addButton(withTitle: "Restricted Mode")
        if parent.path != "/" && parent.path != FileManager.default.homeDirectoryForCurrentUser.path {
            alert.addButton(withTitle: "Trust Everything in “\(parent.lastPathComponent)”")
        }
        alert.icon = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 40, weight: .regular))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .trust
        case .alertThirdButtonReturn: return .trustParent
        default: return .restricted
        }
    }
}
