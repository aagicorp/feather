import Foundation

enum ProjectFiles {
    static let ignoredDirectories: Set<String> = [
        "node_modules", "build", "Build", "DerivedData", "Pods", "dist", "target", "vendor", "__pycache__", "venv",
    ]

    private struct Listing {
        let paths: [String]
        let limit: Int
        let date: Date
    }
    private static let lock = NSLock()
    private static var cache: [String: Listing] = [:]
    /// Walking a big project costs up to a second, and used to happen on every search keystroke, every ⌘P and
    /// every ⌘-hover lookup. The listing is now kept until the file tree reports a change (or for this long).
    private static let maxAge: TimeInterval = 60

    /// Called by the file tree's watcher when files are added, removed or renamed under `root`.
    static func invalidate(root: URL) {
        lock.lock(); cache[root.standardizedFileURL.path] = nil; lock.unlock()
    }

    /// Relative paths of every file under `root`, skipping hidden files, packages, and dependency/build folders.
    /// If `isCancelled` says to stop, whatever was found so far is returned and nothing is cached.
    static func list(root: URL, limit: Int = 40_000, isCancelled: () -> Bool = { false }) -> [String] {
        let rootPath = root.standardizedFileURL.path
        lock.lock()
        let cached = cache[rootPath]
        lock.unlock()
        if let cached, cached.limit >= limit || cached.paths.count < cached.limit, Date().timeIntervalSince(cached.date) < maxAge {
            return cached.paths.count > limit ? Array(cached.paths.prefix(limit)) : cached.paths
        }

        var found: [String] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        // Paths come back under the root exactly as it was given (which may differ from its standardised form,
        // e.g. /tmp vs /private/tmp), so that is the prefix to drop.
        // Usually. For a root under /tmp or /var the enumerator answers with the real location (/private/tmp/…)
        // whichever spelling it was given, so both are accepted and each path drops the prefix it actually has.
        func trimmed(_ path: String) -> String {
            var path = path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        // (Foundation's own path resolving removes "/private" rather than adding it, hence the two by hand.)
        var spellings = Set([trimmed(root.path), trimmed(root.standardizedFileURL.path)])
        for path in spellings {
            if path.hasPrefix("/private/") { spellings.insert(String(path.dropFirst("/private".count))) }
            else { spellings.insert("/private" + path) }
        }
        // Longest first, so "/private/tmp/x" is tried before "/tmp/x" could match by accident.
        let basePaths = spellings.sorted { $0.count > $1.count }
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited % 512 == 0, isCancelled() { return found }          // abandoned: do not cache a partial listing
            let isDirectory = (try? url.resourceValues(forKeys: keys))?.isDirectory ?? false
            if isDirectory {
                if ignoredDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            // The enumerator hands back paths under the root as given, so the prefix can simply be dropped; the
            // per-file URL standardisation this replaces was most of the cost of the walk.
            let path = url.path
            guard let basePath = basePaths.first(where: { path.count > $0.count + 1 && path.hasPrefix($0 + "/") }) else { continue }
            found.append(String(path.dropFirst(basePath.count + 1)))
            if found.count >= limit { break }
        }
        lock.lock()
        cache[rootPath] = Listing(paths: found, limit: limit, date: Date())
        lock.unlock()
        return found
    }
}
