import AppKit

/// What git says about the files in the explorer, the way VS Code shows it: a letter at the end of a changed
/// file's row, its name in the matching colour, and the folders above it tinted so a change deep in the tree can
/// be found from the top. One `git status` per repository under the opened folder, run off the main thread.
final class GitDecorations {
    /// Ordered by how loudly a folder should show it when it contains several kinds.
    enum Kind: Int, Comparable {
        case untracked = 1, added, renamed, modified, deleted, conflict

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        var letter: String {
            switch self {
            case .untracked: return "U"
            case .added: return "A"
            case .renamed: return "R"
            case .modified: return "M"
            case .deleted: return "D"
            case .conflict: return "!"
            }
        }

        var tip: String {
            switch self {
            case .untracked: return "Untracked"
            case .added: return "Added"
            case .renamed: return "Renamed"
            case .modified: return "Modified"
            case .deleted: return "Deleted"
            case .conflict: return "Conflict"
            }
        }

        /// VS Code's git decoration colours, for a dark and a light ground.
        func color(isDark: Bool) -> NSColor {
            let hex: String
            switch self {
            case .untracked, .renamed: hex = isDark ? "#73C991" : "#007100"
            case .added: hex = isDark ? "#81B88B" : "#587C0C"
            case .modified: hex = isDark ? "#E2C08D" : "#895503"
            case .deleted: hex = isDark ? "#C74E39" : "#AD0707"
            case .conflict: hex = isDark ? "#E4676B" : "#AD0707"
            }
            return NSColor(hexString: hex) ?? .labelColor
        }
    }

    /// Called on the main queue when the marks changed.
    var onChange: (() -> Void)?

    private(set) var files: [String: Kind] = [:]            // by standardised path
    private(set) var folders: [String: Kind] = [:]
    private var root: URL?
    private var repositories: [URL] = []
    private var generation = 0
    private var pending: DispatchWorkItem?

    func kind(forFile path: String) -> Kind? { files[path] }
    func kind(forFolder path: String) -> Kind? { folders[path] }

    /// A new folder was opened (or trust changed): find the repositories again, then read their status.
    func setRoot(_ url: URL?) {
        root = url?.standardizedFileURL
        repositories = []
        generation += 1
        apply(files: [:], folders: [:])
        guard let root else { return }
        let expected = generation
        Git.discoverRepositories(under: root) { [weak self] found in
            guard let self, self.generation == expected else { return }
            self.repositories = found.map(\.standardizedFileURL)
            self.refreshNow()
        }
    }

    /// Saves, builds and checkouts arrive in bursts; one status run shortly after the last of them is enough.
    func scheduleRefresh() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshNow() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// A repository may have been created or removed (git init, a clone into the folder).
    func repositoriesMayHaveChanged() {
        guard let root else { return }
        let expected = generation
        Git.discoverRepositories(under: root) { [weak self] found in
            guard let self, self.generation == expected else { return }
            self.repositories = found.map(\.standardizedFileURL)
            self.refreshNow()
        }
    }

    private func refreshNow() {
        pending?.cancel()
        guard let root, !repositories.isEmpty else { apply(files: [:], folders: [:]); return }
        generation += 1
        let expected = generation, rootPath = root.path
        var remaining = repositories.count
        var newFiles: [String: Kind] = [:], newFolders: [String: Kind] = [:]
        for repository in repositories {
            Git.status(in: repository) { [weak self] status in
                guard let self, self.generation == expected else { return }
                for change in (status?.staged ?? []) + (status?.unstaged ?? []) {
                    let kind = GitDecorations.kind(of: change)
                    var path = repository.path + "/" + change.path
                    while path.hasSuffix("/") { path.removeLast() }          // git lists an untracked folder as "dir/"
                    if let old = newFiles[path], old >= kind { continue }
                    newFiles[path] = kind
                    // Every folder on the way up to the opened folder shows that something inside changed. A folder
                    // is calmer than a file: red only for a conflict, green when all that is inside is new, and the
                    // "modified" colour for any other change (a deletion inside should not paint the folder red).
                    let folderKind: Kind = kind == .conflict ? .conflict : (kind == .untracked ? .untracked : .modified)
                    var folder = (path as NSString).deletingLastPathComponent
                    while folder.count >= rootPath.count, folder.hasPrefix(rootPath) {
                        if let old = newFolders[folder], old >= folderKind { break }
                        newFolders[folder] = folderKind
                        if folder == rootPath { break }
                        folder = (folder as NSString).deletingLastPathComponent
                    }
                }
                remaining -= 1
                if remaining == 0 { self.apply(files: newFiles, folders: newFolders) }
            }
        }
    }

    static func kindForTests(of change: GitFileChange) -> Kind { kind(of: change) }

    private static func kind(of change: GitFileChange) -> Kind {
        switch change.status {
        case "!": return .conflict
        case "U": return .untracked
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        default: return .modified
        }
    }

    private func apply(files: [String: Kind], folders: [String: Kind]) {
        guard files != self.files || folders != self.folders else { return }
        self.files = files
        self.folders = folders
        onChange?()
    }
}
